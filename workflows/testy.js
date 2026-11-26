export const meta = {
 name: 'testy',
 description: 'Any test run (tracker selection, smoke after a deploy, regression sweep, retest; local or a test env) by checky lead / test / verify: test deployed tasks against their human testing docs (a pool per test lane, device lanes), audit notes, verify failures, publish the report, apply the result rule (closed / failedTesting / one [Bug] per ask)',
 whenToUse: 'Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents',
 phases: [
  { title: 'Prepare', detail: 'args.select only: pokey.ps1 prepare (L1 selection) writes run.json + lead-notes.md; tasks not live are left out' },
  { title: 'Test', detail: 'one checky (role test) per guide: a pool per qa.lanes lane in parallel, device lanes one guide per device' },
  { title: 'Verify', detail: 'checky verify: note audit, stronger retry of NOT_TESTED, ENV-FIX cycles for local items, independent re-test of every FAIL' },
  { title: 'Close', detail: 'checky lead: report (Google Doc or Markdown) + tracker comment + result rule: closed / failedTesting / [Bug] per ask' },
  { title: 'Learn', detail: 'signals from this run, cleanup (/tidy turns them into lessons)' },
 ],
}

// Sections: L16 args · L72 record-args · L92 prepare · L122 config · L151 prompts · L240 local · L268 app · L298 test-prompt ·
//   L356 verify · L418 run-item · L597 pool · L619 budget · L660 run · L714 learn
// ---- args: the run's input
/* args, one of:
1. Select (Prepare, pokey L1): { select: { statuses?: ['promoted', 'inTest'] (default inTest, else the next on-role), lists?, tasks?, exclude?, mine? },
 target: '<targets.local.json name | qa.targets group>', kitDir, name?, mandate? }
2. Short form (preferred): { runDir, kitDir (absolute: every form), only?: [codes], lanes?, instance?: 'w2' (an extra worker), batch?: <items per run; the rest -> next>, maxMinutes?: <wall clock>, config?: { tiers, models } (bossy.ps1 recover: a resume) }
3. Full run.json (+ runDir; also written to <runDir>/run.json for pokey.ps1 finalize):
{ runDir: '<runtime>/work/qa-runs/<run>', kitDir: '<abs .claude>', title: '<doc names, bug titles>', target: '<targets name>',
 tester: 'Full Name', mandate: ['<the request, verbatim>'], context: '<builds, accounts, data, screens>', contextFiles: ['<read first>'],
 envLines: ['Web: ...'], tracker: { list, parent: '<ask of parentless tasks>', owner, closeStatus: 'closed' },
 outOfScope: ['<channel>'] (default qa.outOfScope), <lane>Parallel (webParallel, apiParallel): a lane's parallel cap, verify: true (false: no FAIL re-test),
 learn: true | 'auto', lanes: [{ n, name, serial, user, notes }] (phoney), devices: 'android' | 'none',
 localEnv: '<local env of the run>' (envy), envFixCycles: 2, envFixWaitMinutes: 300,
 items: [{ code: 'F2', title, guideFile, lane: '<qa.lanes name>' (default: the first; unknown: refused), target?, localEnv?, localParts? (MRs with no build on the target: their checks run on the local env), services? (leased, nothing else), subtasks: [{ id, name, mrs: '!12, !34' }],
  retest: false, only: ['L3'], skipClose: false (test + verify only; the lead publishes), alsoWeb: false, extra, taskFiles: [],
  model?, effort? (TEST step), role? (its seat login's role; default qa.userRecipes seats.roles.<lane>) }],
} */
// kit paths by name: the same names and values as skills/crafty/kit.example.json _paths (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"launches": "work/launches/", "qa-runs": "work/qa-runs/"}, "durable": {"tasks": "tasks/"}}
const say = (it, s) => log(`${it.code}: ${s}`)
const _S = { type: 'string' }, _B = { type: 'boolean' }, _I = { type: 'integer' }, _SA = { type: 'array', items: _S }, dsc = (d, t = _S) => ({ ...t, description: d }), FINAL_SCHEMA = { type: 'object', properties: { ok: _B, output: _S }, required: ['ok', 'output'] }
// a tester step, no result (2026-11-25 login race): one retry, <label>~retry1; close/hold never
const agent1 = agent, TRY2 = /^([\w-]*test|retest-strong|handoff|verify|audit):/
// a model's usage limit: once on the next tier, <label>@up (buildy.js the same)
const LIMIT = /\b(weekly|usage|session|daily) limit\b|usage_limit_reached/i, agentUp = async (p, o) => { const t = [TIERS.fast, TIERS.balanced, TIERS.strong], up = t.slice(t.indexOf(o.model) + 1 || 3).find((m) => m && m !== o.model)
 try { return await agent1(p, o) } catch (e) { if (!up || !LIMIT.test(String(e.message || e))) throw e; log(`${o.label}: ${o.model} usage limit: once on ${up}`); return agent1(p, { ...o, model: up, label: `${o.label}@up` }) } }
try { agent = async (p, o = {}) => { let r; for (let n = 0; n < (TRY2.test(o.label) ? 2 : 1) && r == null; n++) { if (n) log(`RETRY ${o.label}: no result`); r = await agentUp(p, n ? { ...o, label: `${o.label}~retry${n}` } : o) } return r } } catch { log('WARNING: no retry') }
const ARGS0 = args || {}   // recorded as given: a resume needs them byte-exact
let R = ARGS0
// an unknown arg is refused, never dropped: forms 1-3 + run.json keys (STATE.md qa-runs:run)
const ARG_KEYS = 'maxMinutes select name label started only instance batch runtimeDir envFixWaitMinutes title runDir items kitDir tracker target mandate left lanes tester envLines localEnv envFixCycles webParallel apiParallel verify learn context contextFiles alsoTargets outOfScope runSettings devices skipClose driveParent config'.split(' ')
const badArgs = Object.keys(ARGS0).filter((k) => !ARG_KEYS.includes(k))
if (badArgs.length) throw new Error(`testy.js args refused: unknown ${badArgs.join(', ')}; free text for testers goes in args.context`)
const K0 = (R.kitDir || '.claude').replace(/[\\/]+$/, '')
// a relative runDir is from the workspace root, never the kit folder (2026-11-23)
const ABS0 = /^([A-Za-z]:|[\\/])/
// a relative kitDir broke every step path (2026-11-23)
if (!ABS0.test(K0)) throw new Error(`testy.js args.kitDir '${K0}': the absolute <workspace>/.claude path (bossy SKILL "Launch")`)
if (R.runDir && !ABS0.test(R.runDir) && ABS0.test(K0)) R = { ...R, runDir: `${K0.replace(/[\\/][^\\/]+$/, '')}/${String(R.runDir).replace(/^\.[\\/]/, '')}` }
// tier (fast | balanced | strong | inherit) -> model, never the session model; CONFIG tiers + models.<phase> win
const TIERS = { fast: 'haiku', balanced: 'sonnet', strong: 'opus', inherit: '' }, [TF, TB, TS] = ['fast', 'balanced', 'strong']
const MT = { test: TB, verify: TS, audit: TS, close: TF, hold: TF, learn: TF, retest: TS, retestEffort: 'high', step: TF, stepRetry: TB }
const MODELS = {}, setStr = (o, src) => { for (const [k, v] of Object.entries(src || {})) if (typeof v === 'string') o[k] = v }
const tierModels = () => { for (const [k, v] of Object.entries(MT)) MODELS[k] = v in TIERS ? TIERS[v] : v }
setStr(TIERS, (ARGS0.config || {}).tiers); tierModels()
// test lanes: qa.lanes { <lane>: { kind, parallel, followUp, devices } }; unset = one web lane
let QL = { web: { kind: 'web', parallel: 5 } }
const jl = (k, s) => { try { return JSON.parse(new RegExp(`^${k} (\\{.*\\})`, 'm').exec(s)[1]) } catch { } }
// SUM = launch -Self's fnv of its BUDGET / CONFIG lines
const recOk = (s, plan) => /^RECORDED\b/m.test(s) && jl('CONFIG', s) && (!plan || jl('BUDGET', s)) && (/^SUM (\w+)/m.exec(s) || [])[1] === fnv((s.match(/^(BUDGET|CONFIG) \{.*\}/gm) || []).join('\n'))
function takeConfig(out) {
 const c = jl('CONFIG', out)
 // args.config wins: a resume replays the cached CONFIG step; bossy.ps1 recover passes today's tiers / models
 const ov = ARGS0.config || {}; setStr(TIERS, c.tiers); setStr(MT, c.models); setStr(TIERS, ov.tiers); setStr(MT, ov.models); tierModels()
 if (c.qaLanes && typeof c.qaLanes === 'object' && Object.keys(c.qaLanes).length) QL = c.qaLanes
 if (typeof c.intermittentRx === 'string' && c.intermittentRx) { try { INTERMITTENT = new RegExp(c.intermittentRx, 'i') } catch (e) { log(`WARNING: qa.intermittentRx is no regex (${e.message}): the default stays`) } }
}
// ---- record-args: the launch record (a resume needs it byte-exact)
// launch record first (bossy.ps1 launch -Self, FNV-1a); runDir rides along once known
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h.toString(16).padStart(8, '0') }
const RUN0 = (R.runDir ? String(R.runDir).split(/[\\/]/).filter(Boolean).pop() : String(R.name || R.target || 'run').replace(/^(?!testy-)/, 'testy-')) + (R.instance ? `-${R.instance}` : '')
async function recordArgs(run, runDir, phaseName, plan = '') {
 const json = JSON.stringify(ARGS0), file = `${(R.runtimeDir || `${K0}/.runtime`).replace(/[\\/]+$/, '')}/${KP.runtime.launches}args-testy-${run.replace(/[^\w.-]/g, '_')}.json`
 const prompt = `STEP: record this workflow's launch args (crash recovery). Do exactly this, nothing else:
1. Write the line between the markers to ${file} with the Write tool, byte for byte (one line of JSON; no markers, nothing added):
<<<ARGS
${json}
ARGS>>>
2. Run in PowerShell (pwsh 7): & ${K0}/skills/bossy/bossy.ps1 launch -Self -Script testy.js -Run '${run}' -ArgsFile '${file}' -Fnv ${fnv(json)}${runDir ? ` -RunDir '${runDir}'` : ''}${plan ? ` -Plan '${plan}'` : ''}
Return ok=true when it prints RECORDED, else ok=false; output = its output verbatim (its SUM is checked: never re-word) (MISMATCH = the file differs: write it again once, re-run).`
 for (const [label, model] of [['record-args', MODELS.step], ['record-args-retry', MODELS.stepRetry]]) {
  const r = await agent(prompt, { label, phase: phaseName, schema: FINAL_SCHEMA, agentType: 'kitty', model, effort: 'low' })
  if (r && r.ok && recOk(r.output, plan)) return r.output
 }
 throw new Error('launch -Self output re-worded twice: not started')
}
if (!Array.isArray(R.items)) await recordArgs(RUN0, R.runDir || '', R.runDir ? 'Test' : 'Prepare')   // recorded again with its plan once its items are known
// ---- prepare: pokey.ps1 prepare builds the run (args.select, pokey L1) or prints one (runDir); one STEP, last line RUN <json>
const q0 = (s) => String(s).replace(/'/g, "''")
const prepStep = async (cmd, label) => {
 for (const [lb, model] of [[label, MODELS.step], [`${label}-retry`, MODELS.stepRetry]]) {
  const got = await agent(`STEP: run exactly this in PowerShell (pwsh 7; tool timeout 600000) and return ok=true when it exits 0 (else ok=false) with its LAST output line (it starts with "RUN "), unchanged, as output; nothing else (a <yyyy-...> placeholder stays as typed: the script fills it):\n${cmd}`,
   { label: lb, phase: 'Prepare', schema: FINAL_SCHEMA, agentType: 'kitty', model, effort: 'low' })
  try { const f = JSON.parse(String((got && got.output) || '').trim().replace(/^RUN /, '')); if (f && Array.isArray(f.items)) return f } catch (e) { /* retried once */ }
 }
 return null
}
if (R.select && !R.runDir && !Array.isArray(R.items)) {
 phase('Prepare')
 const { select: S, name: N, target: T, ...rest } = R   // T may be a group, never an env: run.json holds the real target(s)
 if (!T) throw new Error('args.select needs args.target (a targets.local.json name or a qa.targets group)')
 const statuses = [].concat(S.statuses && S.statuses.length ? S.statuses : [])   // none: pokey prepare picks inTest, else the next on-role
 // the folder is the run name testy-<words> (pokey fills <testy-id>); the name rides in run.json
 const job = { runFolder: `${(R.runtimeDir || `${K0}/.runtime`).replace(/[\\/]+$/, '')}/${KP.runtime['qa-runs']}<testy-id>`, name: String(N || `${T}-${statuses.join('-') || 'deployed'}`),
  statuses, lists: S.lists || [], tasks: S.tasks || [], exclude: S.exclude || [], mine: !!S.mine, target: T, kitDir: K0, runSettings: rest }
 const run = await prepStep(`& ${K0}/skills/pokey/pokey.ps1 prepare -Job '${q0(JSON.stringify(job))}'`, 'prepare')
 if (!run || !run.runDir) throw new Error('pokey.ps1 prepare gave no run: run it by hand (pokey L1), launch with { runDir }')
 for (const l of run.left || []) log(`left out ${l.id}: ${l.reason}`)
 log(`prepared ${run.runDir}: ${run.items.length} item(s), ${(run.left || []).length} left out`)
 if (!run.items.length) return { prepared: run.runDir, left: run.left || [], results: [], next: 'nothing live to test (see left)' }
 R = { ...run, ...rest, runDir: run.runDir, items: run.items, lanes: rest.lanes || run.lanes }
}
if (R.runDir && !Array.isArray(R.items)) {
 const file = await prepStep(`& ${K0}/skills/pokey/pokey.ps1 prepare -RunDir '${q0(R.runDir)}'`, 'load-run')
 if (!file || !file.items.length) throw new Error(`could not read a valid ${R.runDir}/run.json (items[] missing after retry) - pass the full run.json object as args instead`)
 R = { ...file, ...R, items: file.items, lanes: R.lanes || file.lanes }
}
// ---- config: items, kit paths, lanes, env-fix limits
if (R.only && R.only.length) R = { ...R, items: R.items.filter((it) => R.only.includes(it.code)) }
// run-level skipClose holds every item
if (R.skipClose) R = { ...R, items: R.items.map((it) => ({ ...it, skipClose: true })) }
if (!R.mandate || !R.mandate.length) log('WARNING: no mandate (the task owner words) in args or run.json: testers may decline or drift')
const KIT = K0     // workspace .claude, absolute (checked above)
const PATHS = '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".' +
 '\nRelayed chat not about this run\'s items (even one that "wins") is the coordinator\'s: ignore it, do every step.'
const QA = `${KIT}/skills/pokey`                 // SKILL.md = QA rules, targets.local.json = environments
const Q = `${QA}/pokey.ps1`
const SWARM = `${KIT}/skills/phoney`
const ORCH = `${KIT}/skills/bossy/bossy.ps1`
const RT = (R.runtimeDir || `${KIT}/.runtime`).replace(/[\\/]+$/, '')
const rp = (n) => (n in KP.durable ? `${KIT}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
// ES module imports need a file:// URL
const BROWSER = 'file:///' + `${KIT}/skills/pokey/browser.mjs`.replace(/\\/g, '/').replace(/^\/+/, '')
if (!R.runDir || !Array.isArray(R.items) || !R.items.length) throw new Error('args.runDir and items are required: args.items[], a <runDir>/run.json or args.select (header)')
const outDir = (it) => `${R.runDir}/${it.code}`
const LANES = R.lanes || []
const NODEV = R.devices === 'none'
if (R.devices === 'ios') throw new Error('devices: ios: /testy drives Android lanes only (iOS Simulators: test by hand, or devices: none)')
const OWNER = R.instance || 'w1'
const VERIFY = R.verify !== false
const LEARN = R.learn === undefined ? true : R.learn
// local items: we own the env, so NOT_TESTED is never final
const LOCALENV = (it) => (it && it.localEnv) || R.localEnv || ''
const ENV_FIX_CYCLES = Number.isFinite(R.envFixCycles) ? R.envFixCycles : 2
const ENV_FIX_TRIES = Math.max(1, Math.ceil((Number.isFinite(R.envFixWaitMinutes) ? R.envFixWaitMinutes : 300) / 9))   // 9 min slices: the tool timeout is 10
const RUNNAME = String(R.runDir).split(/[\\/]/).filter(Boolean).pop() || 'qa-run'
// ---- prompts: seats, models, schemas
// pokey.ps1 seat: parallel counts are caps; free memory sets concurrency
// a run tag on every QA id (seat, lease, board): two runs testing T1 at once never share one
const RUNTAG = () => { const lf = (R.runDir || '').split(/[\\/]/).pop(); return (lf.match(/^\d{4}-\d\d-\d\d-(\d{4,6})/) || [])[1] || lf }
function seatBlock(it, label0) {
 const kind = kindOf(it), label = `${label0}@${RUNTAG()}`, sT = tgt(it) ? ` -Target "${tgt(it)}"${it.role ? ` -Role ${it.role}` : ''}` : ''
 return `
AGENT NAME: start every shell command with  $env:CLAUDE_AGENT='${label}'; $env:KIT_QA_TARGETS='${[tgt(it), ...[].concat(R.alsoTargets || [])].filter(Boolean).join(',')}';  (Bash: export the same) - pokey.ps1 api refuses other targets; the build/memory
gate queues your work under this owner name (shell state does not persist between commands).
SEAT (memory + item claim) - your FIRST command, before anything else:
 & ${Q} seat acquire -Agent "${label}" -Kind ${kind} -RunDir "${R.runDir}" -Code ${it.code} -Owner ${OWNER}${sT}
 exit 0 = go. exit 4 = still waiting for memory: run the SAME command again until it returns 0 (other agents are finishing).
 SEAT_USER <login>: your own login for this item (api -As, session({ as }), ui login -As) unless the guide names another; SEAT_USER shared: the target's default login.
 exit 3 / "ALREADY" = another worker owns or finished this item: stop immediately and return { code: "${it.code}", skipped: true, checks: [] }.
 Your LAST command before returning (also on errors): & ${Q} seat release -Agent "${label}"`
}
const pick = (stage) => (MODELS[stage] ? { model: MODELS[stage] } : {})
const PM = (stage) => `@${stage}=${MODELS[stage] || ''}`   // plan token
// it.model/effort win; else MODELS.test
const modelFor = (it) => ({ model: it.model || MODELS.test, ...(it.effort ? { effort: it.effort } : {}) })

const CHECKS_SCHEMA = {
 type: 'object',
 properties: {
  code: _S,
  skipped: dsc('true ONLY when pokey.ps1 seat answered ALREADY (another worker owns this item)', _B),
  checks: {
   type: 'array',
   items: {
    type: 'object',
    properties: {
     id: dsc('check number exactly as in the guide; X1, X2 ... for defects found off-script'),
     case: dsc('variants of one guide row (ids V1, V2 ...): that row id, e.g. T1; fills its Result / Evidence in the human testing doc'),
     subtask_id: dsc('tracker id of the task this check belongs to'),
     screen: _S,
     result: { type: 'string', enum: ['PASS', 'PASS_WITH_NOTE', 'FAIL', 'NOT_TESTED', 'OUT_OF_SCOPE', 'PENDING'] },
     defect: { type: 'string', enum: ['own', 'new'], description: 'FAIL only (pokey tester step 5)' },
     knownBug: dsc('FAIL only: tracker id of the open task that already tracks this defect (not a tested task); no new [Bug], not the task\'s own failure'),
     signature: dsc('new defect: file:line, exact error text or URL pattern (the open collector [Bug] dedupes on it)'),
     cause: { type: 'string', enum: ['no-mail-sandbox', 'phone-only', 'undeployed', 'env-data', 'tool-down'], description: 'NOT_TESTED only: why' },
     env_fix: dsc('local env, NOT_TESTED: the exact coordinator-only fix'),
     what_was_done: _S,
     observed: dsc('what you saw; for FAIL the failing call (method, URL, status, body excerpt) or message'),
     evidence: dsc('file names (not paths) that exist in shots/ or evidence/; a human testing doc check (PASS / note / FAIL): at least one screenshot; JSON only from the UI action (network / app log)', _SA),
     attempts: dsc('runs of this check (LLM-driven / timing: 5+)', _I),
     window: dsc('conditions + UTC times, e.g. "first 5 min after a restart, 14:02-14:10 UTC"'),
    },
    required: ['id', 'subtask_id', 'screen', 'result', 'what_was_done', 'observed', 'evidence', 'attempts'],
   },
  },
  findings: _SA,
  setup_changes: _SA,
  data_created: _SA,
  handoff: dsc('only at a budget HANDOFF: the resume brief path (checks done, checks left)'),
 },
 required: ['code', 'checks', 'findings', 'setup_changes', 'data_created'],
}
const VERIFY_SCHEMA = {
 type: 'object',
 properties: { verdicts: { type: 'array', items: { type: 'object', properties: { id: _S,
  outcome: { type: 'string', enum: ['confirmed', 'refuted', 'inconclusive'], description: 'see the prompt' },
  attempts: dsc('how many times you ran the check', _I),
  observed: _S, evidence: _SA,
  basis: dsc('_verify evidence files, the log window read (UTC), or the code path (file:line); none'),
  knownBug: dsc('confirmed FAIL already tracked by an open task (not a tested task): its tracker id; empty = keep the class'),
  defect: { type: 'string', enum: ['own', 'new', ''], description: 'confirmed FAIL: own = the task\'s own expected behaviour, new = another defect; empty = keep' } },
  required: ['id', 'outcome', 'attempts', 'observed', 'evidence', 'basis'] } } },
 required: ['verdicts'],
}
const AUDIT_SCHEMA = {
 type: 'object',
 properties: {
  reclassify: { type: 'array', items: { type: 'object', properties: { id: _S, defect: _B,
   notExercised: dsc('part of Expected never exercised', _B),
   unreachable: dsc('with notExercised: its screen/endpoint is missing (-> FAIL)', _B),
   own: dsc('with defect: the task\'s own expected behaviour', _B),
   part: dsc('with notExercised: the part of Expected that was not exercised'),
   reason: _S }, required: ['id', 'defect', 'reason'] } },
  newDefects: { type: 'array', items: { type: 'object', properties: { screen: _S, what_was_done: _S, observed: dsc('<= 40 words: <observed> vs <expected>; <evidence>'), detail: dsc('the rest, no cap'), evidence: _SA }, required: ['screen', 'what_was_done', 'observed', 'evidence'] } },
 },
 required: ['reclassify', 'newDefects'],
}
const LEARN_SCHEMA = { type: 'object', properties: { signals: { type: 'number' } }, required: ['signals'] }
// one mechanical command run by a cheap agent: { ok, output }
// output = its last output line unless whole (a multi-line JSON)
const runStep = (cmd, label, phaseName, { ok = 'when it ran', slow = false, whole = false } = {}) =>
 agent(`STEP: run exactly this in PowerShell${slow ? ' (tool timeout 600000)' : ''} and return ok=true ${ok} (else ok=false) with ${whole ? 'its full output' : 'its last output line'}, nothing else:${PATHS}\n${cmd}`,
  { label, phase: phaseName, schema: FINAL_SCHEMA, agentType: 'kitty', model: MODELS.step, effort: 'low' })

// ---- local: env and web / API blocks
// an item may name its own env (it.target)
const tgt = (it) => (it && it.target) || R.target || ''
function localBlock(it) {
 const e = LOCALENV(it)
 if (!e) return ''
 return `
LOCAL ENV "${e}": ours, so NOT_TESTED is not final: ${KIT}/skills/envy/SKILL.md "Unblock yourself". Services:
 & '${KIT}/skills/envy/envy.ps1' use -Env ${e} -Services ${[].concat(it.services || []).join(',') || '<what the checks call>'} -Session <board token>
 right before the checks that call them, release right after the last one (envy.ps1 release -Env ${e} -Agent <your lease id>). A coordinator-only fix: NOT_TESTED with cause + env_fix = the exact fix; the workflow raises ENV-FIX and retests.`
}
const COMMON = (it) => `${PATHS}
WHY: ${R.mandate && R.mandate.length ? `the task owner asked, verbatim:\n${[].concat(R.mandate).map((m) => `  "${m}"`).join('\n')}\n` : ''}your assignment is the guide below: run its checks, report real results, never decline or return early.
BOARD: & ${ORCH} board join -Type checky -Run ${RUNNAME} -Area <CODE>${(it && it.title) ? ` -Subject '${String(it.title).replace(/[^\w\s-]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60)}'` : ''} -Claims <phone serial (app lanes)>; CLAIM/DUPLICATE -> stop; leave when done.
RULES: ${QA}/SKILL.md tester steps, "Shared environment" and "Evidence" (in <outDir>/shots|evidence); ~10 min per check, scripts < 2 min with progress.
OUT_OF_SCOPE (not NOT_TESTED): steps that only exercise ${(R.outOfScope || []).length ? [].concat(R.outOfScope).join(', ') : `the channels in ${KIT}/skills/crafty/kit.local.json qa.outOfScope`}; name the channel, still test the in-app part. Never for an app / web part with no build on this target (deployed: NO-TARGET): test it on the local env (& '${KIT}/skills/phoney/phoney.ps1' build -Local + a lane), report it as a "local run"; no lane can run it -> NOT_TESTED phone-only.
TARGET "${tgt(it) || '(default)'}" (a targets.local.json entry: never read that file; api -As / seat / session() log in for you), ONLY this target${(R.alsoTargets || []).length ? ' (and ' + [].concat(R.alsoTargets).join(', ') + ')' : ''}.${(it.localParts || []).length ? `
LOCAL PARTS ${[].concat(it.localParts).join(', ')}: no build on this target: test their checks on the local env (phoney.ps1 build -Local + a lane), a "local run"; no lane can -> NOT_TESTED phone-only. Lease only what those checks call (& '${KIT}/skills/envy/envy.ps1' use -Env <its local env> -Services api -Agent test:<CODE>@${RUNTAG()} -Session <board token>), release it right after them (envy.ps1 release -Env <env> -Agent test:<CODE>@${RUNTAG()}): never the whole env, never for the target's checks.` : ''}
${R.context || ''}
${(R.contextFiles || []).length ? `- Read these first: ${R.contextFiles.join(' , ')}` : ''}${localBlock(it)}
LEAD NOTES: ${R.runDir}/lead-notes.md (ask there: & ${Q} lead-notes add -RunDir '${R.runDir}' -Code ${it.code} -Text '<question>'; you cannot be messaged): re-read before each check and before any NOT_TESTED; the coordinator adds answers and rule changes there between beats, no live lead reads it: never wait for an answer, decide within your TARGET and guide, note what you decided.
TOOLS: & '${Q}' api -Target ${tgt(it) || '<target>'} ...; tracker: & '${KIT}/skills/crafty/crafty.ps1' tracker view|comments <id>.`
const WEB = (it) => `
BROWSER (web): ${QA}/browser.mjs (read its header), scripts in <outDir>/scripts:
 import { session, relogin, go, text, clickText, clickSel, hoverSel, setInput, shot, mark, saveNet, settle, token } from '${BROWSER}'
 const s = await session({ target: '${tgt(it)}', tenant, as }): your own tab in the SHARED logged-in Chrome of that user; a 401
 mid-script: await relogin(s), retry the step; end with await s.done().`

// ---- app: phone lanes
// one lease id per worker: a shared lease let two workers drive one phone
const LEASE = (L) => `qa-${OWNER}-${L.name}`
// extra workers start on another lane (w2 -> lane 2)
const LANE_OFFSET = Math.max(0, (parseInt(String(OWNER).replace(/\D/g, ''), 10) || 1) - 1)
const laneFor = (w) => LANES[(w + LANE_OFFSET) % LANES.length]
function appBlock(L) {
 return `
PHONE lane ${L.n} "${L.name}", serial ${L.serial}${L.user ? `, test login ${L.user} (a SEAT_USER login replaces it)` : ''}. ${L.notes || ''}
- ${SWARM}/SKILL.md A1-A4 with lease id ${LEASE(L)}: acquire right before your first phone check (web / API checks and reading first),
  release right after your last one (the workflow's release after the lane's last item is only the backstop):
  & '${SWARM}/phoney.ps1' acquire -Agent ${LEASE(L)} -Lane ${L.name}   ...   & '${SWARM}/phoney.ps1' release -Agent ${LEASE(L)}
  every command starts with $env:ANDROID_SERIAL='${L.serial}';
- UI: & ${Q} ui <verb> (verbs: pokey.ps1 -h). Data prefix "QA-L${L.n}-<CODE>"; environment-wide settings only via the API (PASS_WITH_NOTE).`
}
const API = `
API-ONLY LANE: pokey.ps1 api only (exit 1 on HTTP >= 400: judge the status against Expected); save request/response evidence for every check. A human testing doc row with UI steps needs a web or app lane (its screenshot): NOT_TESTED tool-down naming it; a "No UI trigger" row: its log excerpt.`

// an item's lane (default: the first qa.lanes entry), config and kind; a devices lane runs one item per device
const laneOf = (it) => (it && it.lane) || Object.keys(QL)[0]
const laneCfg = (it) => QL[laneOf(it)] || {}
const kindOf = (it) => laneCfg(it).kind || laneOf(it)
function laneBlock(it, L) {
 const k = kindOf(it)
 if (L) return appBlock(L) + (it.alsoWeb ? WEB(it) + '\nThis package also has web/API checks: test those with the browser helper too.' : '')
 if (k === 'api') return API
 if (k === 'web') return WEB(it)
 return `
LANE "${laneOf(it)}" (kind ${k}): drive it with the tools ${QA}/SKILL.md names for this kind; save evidence for every check.`
}
// ---- test-prompt: test and audit prompts
// finalize -Check publishes nothing: renames evidence to <CODE>-<checkId>_<nn>_<what>, rewrites the results file
const CHECK = (it, extra = '') => `& '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code} -Check -FixNames${extra}`
const CHECK_FAILS = 'It prints EXIT=1 (plus a FAILED line: it crashed, read the error) =evidence named in it is missing, a name it could not fix, duplicate check ids, a human testing doc row no check covers (give a check its row id or case), or a doc check without a screenshot (run it from the UI and capture it)'

function testPrompt(it, L) {
 return `You are checky (role test, kind ${it.retest ? 'regression' : 'task'}). Test ONE tester guide on the test environment and return a verdict per check.

GUIDE: ${it.title}
Guide text (the task's human testing doc; read it fully first): ${it.guideFile}
UI ONLY: run each guide check as a person would, from its UI steps (a backend change through the UI action that triggers it; the API only for setup data); a screenshot of the visible result per check; request / response JSON only as captured from that action (saveNet, app log), never a hand-made call. A "No UI trigger" row: check the visible effect it names (screen or log).
Package code: ${it.code}. Output folder: ${outDir(it)} (create shots/, evidence/, scripts/). Reuse valid evidence already there.
Tasks covered (tag each check with its task id):
${(it.subtasks || []).map((s) => `  - ${s.id}: ${s.name}${s.mrs ? `  (MRs: ${s.mrs})` : ''}`).join('\n')}
${it.retest ? 'This is a RETEST of a fix: re-run the failed checks named in the task plus a short regression around them.' : ''}
${seatBlock(it, `test:${it.code}`)}
${COMMON(it)}
${laneBlock(it, L)}
${(it.taskFiles || []).length ? 'Task details (fix description, how-to-test comments, earlier evidence): ' + it.taskFiles.join(' , ') + '\nEvidence links in them (videos, recordings, screenshots): pokey.ps1 evidence index <link> first; frames marked unread: run vidy -> spawn vidy (R19) with the task, its testing doc and your question; use its report (read-chunk only to check one point).' : ''}
${it.extra || ''}
${it.only ? `SCOPE: test ONLY these checks: ${it.only.join(', ')}. Return only those.` : 'Work through ALL checks in the guide. Return every check with the guide\'s own numbers.'}
Return checks, findings, setup_changes and data_created.
For a check you ran more than once (LLM-driven / timing: 5+), set attempts and window (conditions + UTC times): a verifier must
recreate them before it may refute your FAIL.
LAST STEP before returning: write that same result, only its schema keys (no title: run.json holds it), as ${outDir(it)}/${it.scoped ? 'results-retry.json' : 'results.json'} (Write tool) and run
 ${CHECK(it, it.scoped ? ' -Results results-retry.json' : '')} (publishes nothing). ${CHECK_FAILS}: save the file or drop
 the name, give each check its own id, re-run until exit 0. Return the checks as the file now has them (fixed names).${it.scoped ? `
 Never write ${outDir(it)}/results.json: it holds the other checks of this item.` : ''}

PROGRESS: at the start of each check (phone checks too) & ${ORCH} board beat -Session <token> -Status 'check <id> (<n>/<total>)';
 waiting for a phone lane or the local env (phoney.ps1 / envy.ps1 status name the holder): -Status 'waiting for <resource> held by <holder>'.
 Supervise flags a package past its learned time (QA SLOW) with that status; never stop for time.
NON-NEGOTIABLE: no time limit, nobody waits on you: "no time" / "not executed" are never NOT_TESTED reasons; an early return is re-run.`
}

function auditPrompt(it, res) {
 const notes = res.checks.filter((c) => c.result === 'PASS_WITH_NOTE').map((c) => `- ${c.id} (${c.screen}): ${c.observed}`).join('\n')
 const finds = (res.findings || []).map((f, i) => `- F${i + 1}: ${f}`).join('\n')
 return `You are checky (role verify: the note audit): catch real defects hidden in notes. Package ${it.code} (${it.title}).${PATHS}
- PASS_WITH_NOTE is legitimate ONLY for (a) guide text outdated by later intended work while the intent holds, or (b) a purely
 cosmetic difference with correct behaviour.
- DEFECT: 5xx or unexpected 4xx, crash, stuck flow, data changed wrongly or not saved, wrong records, broken navigation, a missing
 screen the feature needs, in the guide's scope or not. NOT defects: test-data/setup notes, tester mistakes, intended decisions,
 platform limits, config missing on the target, guide-conditional checks whose condition does not hold (unless that is the defect).
- NOT EXERCISED (neither defect nor pass): a part of Expected never exercised (a path not triggered, API-only because the UI was not
 reached): defect=false, notExercised=true, part, unreachable=true when the needed screen/endpoint is missing; it becomes its own
 check (<id>n: NOT_TESTED, FAIL when unreachable). Never leave it inside a note.
${R.tracker && R.tracker.parent ? `- Skip issues already tracked by a [Bug] task under ${R.tracker.parent} (& '${KIT}/skills/crafty/crafty.ps1' tracker view ${R.tracker.parent}).` : ''}
- Return per note check {id, defect, reason, own (true = this task's expected behaviour)} plus notExercised/part/unreachable;
 defects only in findings -> newDefects (screen, what_was_done, observed with the failing call, evidence names in ${outDir(it)}/shots|evidence).
- Read evidence and code, GET-only API calls; change nothing.
PASS_WITH_NOTE checks:
${notes || '(none)'}

Findings:
${finds || '(none)'}`
}

// ---- verify: retries, verify and final prompts
// the tester's own count, else 5 for flaky-looking FAILs: one warm re-run is inconclusive (qa.intermittentRx replaces it)
let INTERMITTENT = /time[d ]?out|took too long|\b50[234]\b|cold[- ]start|stall|intermittent|flak|busy|rate[- ]limit/i
function attemptsNeeded(c) {
 return Math.max(c.attempts || 1, INTERMITTENT.test(`${c.observed || ''} ${c.what_was_done || ''}`) ? 5 : 1)
}

function verifyPrompt(it, fails, L) {
 return `You are checky (role verify). Verify these FAILED checks from scratch (your agent definition: be skeptical of the first tester, confirm a real difference from Expected).

GUIDE: ${it.title}   Guide text: ${it.guideFile}
Package ${it.code}. Output folder ${outDir(it)}; name new evidence <CODE>-<checkId>_verify_<desc>.jpeg/.json (re-run from the UI as the guide says: a screenshot each, JSON only from that action).
Tasks and MRs: ${(it.subtasks || []).map((s) => `${s.id}${s.mrs ? ` (MRs: ${s.mrs})` : ''}`).join('; ')}

FAILED CHECKS:
${fails.map((c) => `- ${c.id} (${c.screen}) — first tester did: ${c.what_was_done}\n  saw: ${c.observed}\n  conditions of the first tester: ${c.attempts ? `${c.attempts} attempt(s)` : attemptsNeeded(c) > 1 ? `attempts not recorded on an intermittent-looking failure: run it ${attemptsNeeded(c)} times` : '1 attempt'}${c.window ? `, window: ${c.window}` : ', window: not recorded (read the evidence timestamps)'}`).join('\n')}
${seatBlock(it, `verify:${it.code}`)}
${COMMON(it)}
${laneBlock(it, L)}
Per check id one verdict with attempts and outcome:
- confirmed: really differs from Expected.
- refuted: not reproduced UNDER the first tester's conditions (same login/session type, same window, e.g. right after a restart,
 deploy or idle; at least as many attempts; one clean run never refutes); a FAIL with saved evidence then stays FAIL, marked
 flaky: save your _verify evidence too.
- inconclusive: those conditions could not be recreated; say which in observed (the FAIL stays).
basis = your _verify evidence, the log window read, or the code path (file:line); a refutation without _verify evidence or code
basis counts as inconclusive. Read the CURRENT code of the failing path; intermittent server failures: read the server log for the
first tester's UTC window first. Keep or correct each FAIL's defect class (own / new / knownBug: <task id> when an open task already
tracks the same defect: check its text and signature; never a tested task).`
}

// results.json = the last unscoped tester's; close and hold send only this run's changes (pokey.ps1 results patch)
const uniq = (checks) => { const seen = new Set(); return checks.map((c0) => { const c = { ...c0 }, id0 = String(c.id || 'check'); let id = id0, k = 1
 while (seen.has(id)) id = `${id0}${String.fromCharCode(97 + k++)}`
 if (id !== id0) c.guideId = id0
 c.id = id; seen.add(id); return c }) }
function resultsPatch(written, res) {
 const same = (a, b) => JSON.stringify(a) === JSON.stringify(b), base = new Map(uniq((written && written.checks) || []).map((c) => [c.id, c])), set = {}, add = [], top = {}
 for (const c of res.checks) {
  const b = base.get(c.id), d = {}
  if (!b) { add.push(c); continue }
  for (const k of Object.keys(c)) if (!same(c[k], b[k])) d[k] = c[k]
  if (Object.keys(d).length) set[c.id] = d
 }
 for (const k of ['findings', 'setup_changes', 'data_created']) if (!same(res[k] || [], (written && written[k]) || [])) top[k] = res[k] || []
 const p = { ...(Object.keys(set).length ? { set } : {}), ...(add.length ? { add } : {}), ...(Object.keys(top).length ? { top } : {}) }
 return Object.keys(p).length ? `& '${Q}' results patch -RunDir '${R.runDir}' -Code ${res.code} -Patch '${JSON.stringify(p).replace(/'/g, "''")}'` : ''
}
function finalPrompt(it, res, written) {
 const patch = resultsPatch(written, res)
 return `STEP (checky, role lead): publish the test results of package ${it.code}.${PATHS}
1. ${patch ? `Run in PowerShell, exactly as given (the workflow's changes to ${outDir(it)}/results.json; never rewrite the file):\n${patch}` : `${outDir(it)}/results.json is final: nothing to change.`}
2. Run in PowerShell: ${CHECK(it, ` -ExpectChecks ${res.checks.length}`)} (publishes nothing). ${CHECK_FAILS}, or a count
 other than sent: fix that data (step 3) and re-run it until exit 0.
 Then (timeout 600000): & '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code} -ExpectChecks ${res.checks.length} (last line EXIT=0 = published)
 It publishes the report (kit.local.json reports.type), comments on the tasks and applies the result rule (closed /
 failedTesting / one [Bug] per ask); it refuses while evidence listed in results.json is missing.
3. If it errors, fix only data problems in results.json (drop a missing evidence file name, suffix a duplicate check id; an off-standard
 file name: re-run -Check -FixNames) and run it once more. Don't edit pokey.ps1.
Return ok=true/false and the script's output.`
}

// ---- run-item: one guide end to end
// NOT_TESTED: stronger retry, then ENV-FIX (local) or failedTesting (shared env)
const CAUSE_NEXT = {
 'no-mail-sandbox': 'check what the app sent through its API or job log (the delivery channel itself is out of scope)',
 'phone-only': 'take a device lane (phoney.ps1 acquire); no build on the target: the local-env APK (phoney.ps1 build -Local) on a lane, a "local run"; else a web screen showing the same result',
 'undeployed': 'run pokey.ps1 deployed again; still not live -> NOT_TESTED undeployed (the task goes back to its developer)',
 'env-data': 'create the data through the API (prefixed QA-<CODE>) or ask the lead in lead-notes.md',
 'tool-down': 'use another tool (another screen, read endpoints, logs) instead of the one that is down; a doc check still needs its screenshot' }
const causeHint = (c) => CAUSE_NEXT[c.cause] || 'find another way in (data, user, path, the API, the lead notes)'
const retryable = (c) => c.result === 'NOT_TESTED'
const ntShare = (r) => (r && r.checks.length ? r.checks.filter(retryable).length / r.checks.length : 1)
const retryIds = (r) => [...new Set(r.checks.filter(retryable).map((c) => c.guideId || c.id))]
const tag = (L) => (L ? '@' + L.name : '')
// a scoped retry's results replace the NOT_TESTED checks it ran (a split id answers to its guide id)
// a check's verify: '<status> | <re-test text> | <note audit text>' (pokey.ps1 VerifyStatus reads the status)
const vJoin = (...parts) => parts.filter(Boolean).join(' | ')
function adoptRetry(res, retry, note) {
 for (const c2 of (retry && !retry.skipped && retry.checks) || []) {
  const i = res.checks.findIndex((c) => (c.id === c2.id || c.guideId === c2.id) && c.result === 'NOT_TESTED')
  if (i < 0 || c2.result === 'NOT_TESTED') continue
  // the Saw cell shows the retry's view; the blocked first attempt stays in the results file
  res.checks[i] = { ...c2, id: res.checks[i].id, observed: `${c2.observed} (${note})`, firstAttempt: res.checks[i].observed }
 }
}

async function runItem(it, idx, L) {
 const phase = 'Test'
 let retried = false
 let res = await agent(testPrompt(it, L), { label: `test:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'checky', ...modelFor(it) })
 if (res && res.skipped) { say(it, `skipped - another worker owns or finished it`); return { code: it.code, skipped: true } }
 let written = res && JSON.parse(JSON.stringify(res))   // what results.json holds (scoped testers write results-retry.json)
 for (let h = 0; res && res.handoff && h < 3; h++) {   // budget handoff -> a fresh tester
  say(it, `HANDOFF at its budget (${res.handoff}): a fresh tester continues`)
  const more = await agent(testPrompt({ ...it, scoped: true }, L) + `\nHANDOFF: a previous tester reached its budget; read its resume brief ${res.handoff} first and test only the checks it lists as left.`, { label: `handoff:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'checky', ...modelFor(it) })
  res = more && !more.skipped ? { ...res, handoff: more.handoff || '', checks: [...res.checks.filter((c) => !more.checks.some((m) => m.id === c.id)), ...more.checks], findings: [...new Set([...(res.findings || []), ...(more.findings || [])])] } : { ...res, handoff: '' }
 }
 if ((!res || ntShare(res) > 0.25) && !(CAPMIN && await late(phase))) {
  say(it, `${res ? Math.round(ntShare(res) * 100) + '% NOT_TESTED' : 'no result'} — re-running${res ? ' only those' : ''}`)
  // owner 2026-11-19: a retest re-runs only the NOT_TESTED checks (a whole phone-package rerun took 97 min)
  const open = res ? retryIds(res) : [], full = !open.length   // no result or no checks: the whole guide again
  const prior = full ? '' : `\nA previous attempt left these NOT_TESTED — they MUST now be executed: ${open.join(', ')}. Reuse its valid evidence.`
  const again = await agent(testPrompt(full ? it : { ...it, only: open, scoped: true }, L) + prior, { label: `retest:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'checky', ...modelFor(it) })
  if (again && !again.skipped && full) { written = JSON.parse(JSON.stringify(again)); res = again }   // an unscoped tester wrote results.json anew
  else if (again && !again.skipped && res) {
   for (const c2 of again.checks || []) {
    const i = res.checks.findIndex((c) => c.id === c2.id)
    if (i < 0) res.checks.push(c2)
    else if (res.checks[i].result === 'NOT_TESTED' && c2.result !== 'NOT_TESTED') res.checks[i] = c2
   }
   res.findings = [...new Set([...(res.findings || []), ...(again.findings || [])])]
  }
  retried = true
 }
 if (!res) return { code: it.code, error: 'test agent returned nothing' }
 res.code = it.code
 res.checks = uniq(res.checks)   // unique ids before audit/verify (a shared id shares one verdict)

 // Note audit: defects hidden in notes become FAIL (own, or new X checks)
 if (res.checks.some((c) => c.result === 'PASS_WITH_NOTE') || (res.findings || []).length) {
  const a = await agent(auditPrompt(it, res), { label: `audit:${it.code}`, phase: 'Verify', schema: AUDIT_SCHEMA, agentType: 'checky', ...pick('audit') })
  for (const d of (a && a.reclassify) || []) {
   const c = res.checks.find((x) => x.id === d.id)
   if (c && d.defect && c.result === 'PASS_WITH_NOTE') { c.result = 'FAIL'; c.defect = d.own === false ? 'new' : 'own'; c.verify = vJoin(c.verify, `Note audit: a defect, not a note: ${d.reason}`) }
   else if (c && d.notExercised) {
    // NOT EXERCISED: untested Expected -> check <id>n (NOT_TESTED; FAIL if unreachable)
    let nid = `${c.id}n`, k = 1
    while (res.checks.some((x) => x.id === nid)) nid = `${c.id}n${++k}`
    res.checks.push({ id: nid, subtask_id: c.subtask_id, screen: c.screen, result: d.unreachable ? 'FAIL' : 'NOT_TESTED', ...(d.unreachable ? { defect: 'own' } : { cause: 'env-data' }),
     what_was_done: `Split from ${c.id} by the note audit: this part of its Expected was never exercised: ${d.part || '(see reason)'}`,
     observed: `${d.unreachable ? 'The screen/endpoint this part needs was missing or unreachable' : 'Not exercised by the tester'}: ${d.reason} (raised by the note audit)`, evidence: [] })
    c.verify = vJoin(c.verify, `Note audit: the unexercised part moved to ${nid}`)
   }
  }
  // new audit checks continue after the highest X id
  let n = Math.max(0, ...res.checks.map((c) => +((/^X(\d+)$/.exec(c.id) || [])[1] || 0)))
  for (const d of (a && a.newDefects) || []) {
   res.checks.push({ id: `X${++n}`, subtask_id: ((it.subtasks || [])[0] || {}).id || '', screen: d.screen, result: 'FAIL', defect: 'new', what_was_done: d.what_was_done, observed: d.observed, verify: vJoin('Note audit: raised this new defect', d.detail), evidence: d.evidence || [] })
  }
  if (a) say(it, `audit -> ${(a.reclassify || []).filter((d) => d.defect).length} note(s) reclassified, ${(a.reclassify || []).filter((d) => !d.defect && d.notExercised).length} not exercised, ${(a.newDefects || []).length} new defect(s)`)
 }

 // Stronger retry (owner rule): ONE scoped MODELS.retest attempt before the result rule
 const blocked = res.checks.filter(retryable)
 if (blocked.length && MODELS.retest && !(CAPMIN && await late('Verify'))) {
  say(it, `${blocked.length} check(s) NOT_TESTED -> one retry on ${MODELS.retest} (${blocked.map((c) => c.id).join(', ')})`)
  const why = blocked.map((c) => `- ${c.id} (${c.screen}): blocked by ${c.cause || 'unknown'}: ${c.observed} -> ${causeHint(c)}`).join('\n')
  const r2 = await agent(testPrompt({ ...it, only: [...new Set(blocked.map((c) => c.guideId || c.id))], scoped: true }, L) +
   `\nSTRONGER RETRY: a first tester could not complete these checks. What blocked it:\n${why}\nWork around each blocker (other data, user, path, the API, the lead notes) and execute the check; NOT_TESTED again only when truly impossible, with the cause.`,
   { label: `retest-strong:${it.code}${tag(L)}`, phase: 'Verify', schema: CHECKS_SCHEMA, agentType: 'checky', model: MODELS.retest, effort: MODELS.retestEffort || 'high' })
  adoptRetry(res, r2, 'stronger retry')
  retried = true
 }
 // ENV-FIX (bossy E4): coordinator fixes the env, we retest; after ENV_FIX_CYCLES held, never failedTesting
 let envFix = null
 for (let cyc = 1; LOCALENV(it) && cyc <= ENV_FIX_CYCLES && !(CAPMIN && await late('Verify')); cyc++) {
  const open = res.checks.filter(retryable)
  if (!open.length) break
  const need = open.map((c) => `${c.id}: ${c.env_fix || c.cause || 'unknown'}: ${c.observed}`).join(' | ').slice(0, 1200).replace(/'/g, "''").replace(/[\r\n]+/g, ' ')
  const asked = await runStep(`& ${ORCH} decide ask -Kind envfix -Run '${RUNNAME}' -Agent 'qa-${it.code}' -Item '${it.code}' -Contracts '${R.runDir}/lead-notes.md' -Question 'Local env ${LOCALENV(it)}, item ${it.code}: fix so these checks can run: ${need}'`,
   `envfix-ask:${it.code}`, 'Verify')
  const id = (/\b(envfix-[a-z0-9]+(?:-[a-z0-9]+)*|e-\d{14}-[\w-]+)/.exec((asked && asked.output) || '') || [])[1]
  if (!id) { envFix = { cycles: cyc, state: 'not raised', output: asked ? asked.output : 'agent returned nothing' }; break }
  say(it, `ENV-FIX ${id} (cycle ${cyc}/${ENV_FIX_CYCLES}) -> the coordinator: ${open.map((c) => c.id).join(', ')}`)
  let ans = null
  for (let t = 0; t < ENV_FIX_TRIES && !ans; t++) {
   const w = await runStep(`& ${ORCH} decide wait -Id ${id} -MaxMinutes 9`, `envfix-wait:${it.code}`, 'Verify', { ok: 'when it prints ANSWERED', slow: true })
   if (w && w.ok) ans = w.output
  }
  envFix = { id, cycles: cyc, state: !ans ? 'no answer' : /:\s*cannot\b/i.test(ans) ? 'coordinator cannot' : 'fixed', answer: ans || '' }
  if (envFix.state !== 'fixed') break
  const r3 = await agent(testPrompt({ ...it, only: [...new Set(open.map((c) => c.guideId || c.id))], scoped: true }, L) +
   `\nENV FIX DONE: the coordinator fixed the local env for these checks (${id}): ${ans}\nExecute each check now; NOT_TESTED again only with cause and env_fix.`,
   { label: `envfix-retest:${it.code}${tag(L)}`, phase: 'Verify', schema: CHECKS_SCHEMA, agentType: 'checky', ...(MODELS.retest ? { model: MODELS.retest, effort: MODELS.retestEffort || 'high' } : {}) })
  adoptRetry(res, r3, `after ENV-FIX ${id}`)
  retried = true
 }
 // still mostly NOT_TESTED after the stronger retry, shared env: a broken run, not a verdict (local items: ENV-FIX)
 if (CAPMIN && await late('Verify')) for (const c of res.checks.filter(retryable)) c.observed = `${c.observed} (run time cap: not retried)`
 const broken = ntShare(res) > 0.5 && !LOCALENV(it) ? `${Math.round(ntShare(res) * 100)}% NOT_TESTED after the stronger retry on a shared env: a broken run, not a verdict - results held, the coordinator decides (retest or close)` : ''
 if (broken) say(it, `${broken}`)   // held below (held.json: supervise asks), never dropped unpublished
 const envFixOpen = !!LOCALENV(it) && res.checks.some(retryable)
 if (envFixOpen) say(it, `ENV-FIX UNRESOLVED (${envFix ? `${envFix.state}, ${envFix.cycles} cycle(s)` : 'no cycle'}): results held, not failedTesting - the coordinator decides (bossy E4)`)
 const fails = res.checks.filter((c) => c.result === 'FAIL')
 const capped = fails.length && VERIFY && CAPMIN && await late('Verify')
 if (fails.length && (!VERIFY || capped)) for (const c of fails) c.verify = vJoin(`not re-tested (${capped ? 'run time cap' : 'verify: false'})`, c.verify)
 if (fails.length && VERIFY && !capped) {
  const v = await agent(verifyPrompt(it, fails, L), { label: `verify:${it.code}${tag(L)}`, phase: 'Verify', schema: VERIFY_SCHEMA, agentType: 'checky', ...pick('verify'), ...(it.effort ? { effort: it.effort } : {}) })
  const byId = Object.fromEntries(((v && v.verdicts) || []).map((x) => [x.id, x]))
  for (const c of fails) {
   const x = byId[c.id]
   if (!x) { c.verify = vJoin('not re-tested', c.verify); continue }
   let outcome = x.outcome || 'inconclusive'
   // fewer attempts than the first tester never refutes an intermittent FAIL (attemptsNeeded)
   const need = attemptsNeeded(c)
   if (outcome === 'refuted' && need > 1 && (x.attempts || 1) < need) {
    outcome = 'inconclusive'
    x.observed = `${x.observed} (${x.attempts || 1} attempt(s) against ${c.attempts ? `${need} by the first tester` : `${need} needed for an intermittent failure`})`
   }
   // a refutation needs own _verify evidence or a code / log basis
   const basis = String(x.basis || '').trim()
   const verifyEv = (x.evidence || []).some((e) => /_verify[_.]/i.test(String(e)))
   const codeBasis = (/[\w-]+\.(java|kt|ts|tsx|js|mjs|py|cs|go|rb|php|sql|xml|html)(:\d+)?\b/i.test(basis) ||
    (/\blogs?\b|observability/i.test(basis) && /\b\d{1,2}:\d{2}/.test(basis))) && !/^none\b|\b(no|not|without|never)\b[^.;]{0,30}\b(logs?|code|file)\b/i.test(basis)
   if (outcome === 'refuted' && !verifyEv && !codeBasis) { outcome = 'inconclusive'; x.observed = `${x.observed} (no verify evidence or basis recorded)` }
   if (basis && !/^none\b/i.test(basis)) x.observed = `${x.observed} [basis: ${basis}]`
   const firstEv = (c.evidence || []).length > 0   // the first run's own evidence (before the verifier's)
   c.evidence = [...c.evidence, ...(x.evidence || [])]
   // re-test + audit text in verify (rendered outside the Results cell); observed stays within the note cap
   const audit = c.verify
   if (outcome === 'confirmed' && String(x.knownBug || '').trim()) c.knownBug = String(x.knownBug).trim()   // pokey finalize checks the id exists
   if (outcome === 'confirmed' && ['own', 'new'].includes(x.defect)) c.defect = x.defect   // the verifier corrects the class
   if (outcome === 'confirmed') c.verify = vJoin('confirmed', `Independent re-test confirmed: ${x.observed}`, audit)
   else if (outcome === 'inconclusive') c.verify = vJoin('inconclusive', `Re-test inconclusive (conditions not recreated): ${x.observed}`, audit)
   else if (firstEv) { c.verify = vJoin('not reproduced (flaky)', `An independent re-test under the same conditions did not reproduce it; the first run's evidence stands. Re-test: ${x.observed}`, audit); c.flaky = true }
   else { delete c.knownBug; c.verify = vJoin('not reproduced', `Re-test: ${x.observed}`, `First run: ${c.observed}`, audit); c.result = 'PASS_WITH_NOTE'; c.observed = 'First run reported a failure with no saved evidence; an independent re-test under the same conditions did not reproduce it.' }   // knownBug: FAIL only
  }
 }
 const n = (k) => res.checks.filter((c) => c.result === k).length
 const line =`${it.code}: pass ${n('PASS') + n('PASS_WITH_NOTE')}/${res.checks.length - n('OUT_OF_SCOPE')}, fail ${n('FAIL')}, not tested ${n('NOT_TESTED')}, out of scope ${n('OUT_OF_SCOPE')}, pending ${n('PENDING')}`
 const holdLocal = envFixOpen && !res.checks.some((c) => c.result === 'FAIL' && c.defect !== 'new' && !c.knownBug)
 if (it.skipClose || holdLocal || broken) {
  // verdicts stay on disk for the lead (finalize -Code); held.json tells supervise + workers
  const why = broken || (holdLocal ? `local env: checks still NOT_TESTED after ENV-FIX (${envFix ? `${envFix.id || '-'} ${envFix.state}` : 'none raised'}): the coordinator fixes the env + pokey.ps1 retest (never failedTesting for an env reason)` : 'publish left to the lead (skipClose)')
  const q = (s) => String(s).replace(/'/g, "''"), patch = resultsPatch(written, res)
  await agent(`STEP (checky, role lead): run these in PowerShell, exactly as given, then return ok=true with their output.
${patch ? `${patch}\n` : ''}& '${Q}' results hold -RunDir '${R.runDir}' -Code ${it.code} -Why '${q(why)}' -Summary '${q(line)}'${envFix ? ` -EnvFix '${q(JSON.stringify(envFix))}'` : ''}
${CHECK(it, ` -ExpectChecks ${res.checks.length}`)} (publishes nothing). Exit 1: return ok=true anyway with that output (the lead fixes
 them before publishing).`,
   { label: `hold:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, agentType: 'checky', ...pick('hold'), effort: 'low' })
  log(`${line} (results saved; ${broken ? 'broken run: the coordinator decides' : holdLocal ? 'ENV-FIX unresolved: the coordinator decides' : 'publish left to the lead'})`)
  return { code: it.code, summary: line, result: res, eventful: true, envFix, envFixOpen: holdLocal, pending: res.checks.filter((c) => c.result === 'PENDING').map((c) => c.id) }
 }
 let fin = await agent(finalPrompt(it, res, written), { label: `close:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, agentType: 'checky', ...pick('close'), effort: 'low' })
 if (!(fin && fin.ok)) fin = await agent(finalPrompt(it, res, written), { label: `close-retry:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, agentType: 'checky', model: MODELS.stepRetry })
 log(line + (fin && fin.ok ? '' : ' [NOT PUBLISHED - the coordinator runs pokey.ps1 finalize for it (pokey L3)]'))
 const eventful = retried || n('FAIL') > 0 || n('NOT_TESTED') > 0 || res.checks.some((c) => /Note audit|not reproduce|inconclusive/.test(`${c.observed || ''} ${c.verify || ''}`)) || !(fin && fin.ok)
 return { code: it.code, summary: line, finalize: fin, eventful, envFix, unpublished: !(fin && fin.ok), result: fin && fin.ok ? undefined : res, pending: res.checks.filter((c) => c.result === 'PENDING').map((c) => c.id) }
}

// ---- pool: one worker per slot
// web and API pools run in parallel; app guides run one per phone
async function pool(list, size, offset, deviceOf) {
 const out = []
 let next = 0
 const worker = async (w) => {
  while (next < list.length) {
   const k = next++
   if (!(await gate('Test'))) { STOPPED.push(list[k].code); continue }
   out[k] = await runItem(list[k], offset + k, deviceOf ? deviceOf(w) : null).catch((e) => ({ code: list[k].code, error: String(e) }))
  }
  // app lane done: every lease of its id goes (phone unless someone waits, env, GPU, builds, tabs; leases.jsonl)
  const L = deviceOf ? deviceOf(w) : null
  if (L && L.name) {
   await runStep(`& ${ORCH} release -Agent '${LEASE(L)}' -Reason 'agent finished'`, `release-${L.name}`, 'Close').catch(() => null)
   log(`lane ${L.name} (${L.serial}) released`)
  }
 }
 await Promise.all(Array.from({ length: Math.max(1, Math.min(size, list.length)) }, (_, w) => worker(w)))
 return out
}

// ---- budget: batch, plan cap, stop line
// BUDGET (README "Configuration"): over the plan's cap -> refused + split; at stopAt no new item, rest -> next
const BATCH = R.batch > 0 && R.items.length > R.batch ? R.batch : 0
const LATER = BATCH ? R.items.slice(BATCH).map((it) => it.code) : [], STOPPED = []
if (BATCH) R = { ...R, items: R.items.slice(0, BATCH) }
const BUD = { cap: 0, estimate: 0, stopAt: 0.8, spent: 0, guess: 0, stop: false, unit: 0 }
const PLAN = [...R.items.map((it) => `checky/${it.model || PM('test')}:1,checky/${PM('verify')}:1,step/${PM('close')}:1,item:1`), `step/${PM('step')}:6,kitty/${PM('learn')}:1`].join(',')
const REC = await recordArgs(RUN0, R.runDir, 'Test', PLAN)
takeConfig(REC)
Object.assign(BUD, jl('BUDGET', REC)); BUD.unit = BUD.estimate / R.items.length
// the caller's run options carry into next (a short-form call reads the rest from run.json)
const OPTS = Object.fromEntries('maxMinutes devices verify learn webParallel apiParallel skipClose context contextFiles outOfScope envFixCycles envFixWaitMinutes alsoTargets'.split(' ').filter((k) => ARGS0[k] !== undefined).map((k) => [k, ARGS0[k]]))
const nextCall = (only, extra) => ({ scriptPath: `${KIT}/workflows/testy.js`, args: { runDir: R.runDir, kitDir: K0, ...OPTS, ...(only && { only }), ...(ARGS0.lanes && { lanes: ARGS0.lanes }), ...(ARGS0.instance && { instance: ARGS0.instance }), ...extra } })
if (BUD.cap && BUD.estimate > BUD.stopAt * BUD.cap) {
 const batch = Math.max(1, Math.floor(R.items.length * BUD.stopAt * BUD.cap / BUD.estimate))
 log(`REFUSED: estimate ${BUD.estimate} > ${BUD.stopAt * 100}% of the cap ${BUD.cap}: test ${batch} item(s) per run (args.batch)`)
 return { refused: true, estimate: BUD.estimate, cap: BUD.cap, batch, next: nextCall(ARGS0.only, { batch }) }
}
// the run's spend (its agents' transcripts): gate() near the stop line, and once for the outcome
async function measure(phaseName) {
 const r = await runStep(`& ${ORCH} budget -Run '${RUN0}' -Json`, 'budget', phaseName).catch(() => null)
 try { const j = JSON.parse(r.output); BUD.spent = j.spent; BUD.min = j.minutes; BUD.guess = 0 } catch (e) {}
}
// wall-clock cap per launch (2026-11-25: "90 min" ran 4.5 h): args.maxMinutes, else budget.runMinutes
const CAPMIN = +R.maxMinutes || +BUD.runMinutes || 0
async function late(ph) {
 if (!CAPMIN || BUD.late) return !!BUD.late
 BUD.m = BUD.m || measure(ph).then(() => { BUD.m = null }); await BUD.m
 if (BUD.min >= CAPMIN && !BUD.late) { BUD.late = true; log(`TIME CAP ${BUD.min}/${CAPMIN} min: no new step; unstarted items -> next`) }
 return !!BUD.late
}
async function gate(phaseName) {   // before a new item; measures only near the stop line
 if (CAPMIN && await late(phaseName)) return false
 if (BUD.stop || !BUD.cap) return !BUD.stop
 BUD.guess += BUD.unit
 if (BUD.spent + BUD.guess < 0.6 * BUD.stopAt * BUD.cap) return true
 BUD.m = BUD.m || measure(phaseName).then(() => { BUD.m = null })
 await BUD.m
 if (BUD.spent >= BUD.stopAt * BUD.cap && !BUD.stop) { BUD.stop = true; log(`BUDGET: spent ${BUD.spent} of the cap ${BUD.cap}: running items finish, no new one starts; the rest -> next`) }
 return !BUD.stop
}
// ---- run: one pool per qa.lanes lane (parallel), device lanes one item per device (in turn); follow-ups
const LN = Object.keys(QL)
const odd = R.items.filter((it) => !(laneOf(it) in QL))
if (odd.length) throw new Error(`testy.js: unknown lane(s) ${[...new Set(odd.map(laneOf))].join(', ')} (items ${odd.map((it) => it.code).join(', ')}): qa.lanes has ${LN.join(', ')}`)
const lanes = LN.map((n, i) => ({ n, i, c: QL[n], items: R.items.filter((it) => laneOf(it) === n) }))
// a lane's cap: args <lane>Parallel, else qa.lanes.<lane>.parallel, else free RAM (seat capacity), never login count
const CAP = {}
for (const l of lanes.filter((x) => x.items.length > 1 && !x.c.devices && !R[`${x.n}Parallel`] && !x.c.parallel)) {
 const r = await runStep(`& ${Q} seat capacity -Kind ${l.n}`, `capacity-${l.n}`, 'Test').catch(() => null)
 CAP[l.n] = +((/CAPACITY \S+ (\d+)/.exec((r && r.output) || '') || [])[1]) || 0
}
const par = (l) => R[`${l.n}Parallel`] || l.c.parallel || CAP[l.n] || 5
const devLanes = lanes.filter((l) => l.c.devices && l.items.length)
if (devLanes.length && !LANES.length && !NODEV) throw new Error(`${devLanes.map((l) => l.n).join(', ')} items need args.lanes (one per device + its login; agents lease and boot them) or devices: none`)
log(`verify ${VERIFY ? 'on' : 'off'}, learn ${LEARN}`)
log(`run ${R.runDir}: ${lanes.map((l) => `${l.n} ${l.items.length} (${l.c.devices ? `${LANES.length} devices` : `x${par(l)}`})`).join(', ')}`)

const devicePools = async () => { const out = []; for (const l of NODEV ? [] : devLanes) out.push(...await pool(l.items, LANES.length, l.i * 100, laneFor)); return out }   // in turn: one lease per device
const parts = await Promise.all([...lanes.filter((l) => !l.c.devices && l.items.length).map((l) => pool(l.items, par(l), l.i * 100)), devicePools()])
const all = parts.flat().filter(Boolean)
if (NODEV && devLanes.length) log(`NOT_TESTED (devices none; tasks stay open): ${devLanes.flatMap((l) => l.items.map((it) => it.code)).join(', ')}`)

// follow-ups: PENDING checks -> an item <code><Lane initial> on its followUp lane, in run.json first (finalize reads it)
const fuLane = (it) => { const t = laneCfg(it).followUp; return t && t in QL ? t : '' }
const pend = all.filter((x) => x.pending && x.pending.length).map((r) => ({ r, it: R.items.find((x) => x.code === r.code) })).filter((p) => p.it)
for (const { r, it } of pend.filter((p) => !fuLane(p.it) || (QL[fuLane(p.it)].devices && !LANES.length))) {
 if (fuLane(it)) log(`${r.code}: PENDING ${r.pending.join(', ')} need a device lane, args.lanes is empty: the task stays open (add lanes, pokey.ps1 retest)`)
 else if (!laneCfg(it).devices) log(`${r.code}: PENDING ${r.pending.join(', ')}: lane ${laneOf(it)} has no followUp lane (qa.lanes): the task stays open (pokey.ps1 retest)`)
}
const followUps = pend.filter((p) => fuLane(p.it) && !(QL[fuLane(p.it)].devices && !LANES.length)).map(({ r, it }) => {
 const t = fuLane(it), code = `${it.code}${t[0].toUpperCase()}`, dev = !!QL[t].devices
 if (R.items.some((x) => x.code === code)) return null
 return { ...it, code, title: `${it.title} — ${t} checks ${r.pending.join(', ')}`, lane: t, only: r.pending,
  taskFiles: [...(it.taskFiles || []), `${outDir(it)}/results.json`],
  extra: `${it.extra || ''} The ${laneOf(it)} pass (${it.code}) left ${r.pending.join(', ')} PENDING for ${dev ? 'a device' : `the ${t} lane`}: test exactly those${dev ? ' on your phone' : ''}. Earlier results: ${outDir(it)}/results.json.` }
}).filter(Boolean)
if (followUps.length) {
 await agent(`STEP: append these items to the "items" array of ${R.runDir}/run.json without changing anything else, in PowerShell:
$f = '${R.runDir}/run.json'; $j = Get-Content $f -Raw | ConvertFrom-Json; $new = '${JSON.stringify(followUps).replace(/'/g, "''")}' | ConvertFrom-Json
foreach ($n in $new) { if (-not ($j.items | Where-Object code -eq $n.code)) { $j.items += $n } }
[IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 20))
Then return ok=true and the list of item codes now in the file.`, { label: 'add-followups', phase: 'Test', schema: FINAL_SCHEMA, agentType: 'kitty', model: MODELS.step, effort: 'low' })
 log(`follow-ups for PENDING checks: ${followUps.map((f) => `${f.code} (${f.only.join(', ')})`).join('; ')}`)
 for (const [j, t] of [...new Set(followUps.map((f) => f.lane))].entries()) {
  const fl = followUps.filter((f) => f.lane === t)
  all.push(...(await (QL[t].devices ? pool(fl, LANES.length, (LN.length + j) * 100, laneFor) : pool(fl, par({ n: t, c: QL[t] }), (LN.length + j) * 100))).filter(Boolean))
 }
}
await measure('Test')
if (LANES.length) await runStep(`& ${ORCH} release -Agent '${LANES.map(LEASE).join(',')}' -Reason 'agent finished'`, 'release-lanes', 'Close').catch(() => null)   // backstop: idempotent
// the run's seat logins are deactivated (a crashed run: bossy.ps1 cleanup deactivates idle ones)
await runStep(`& ${Q} seat cleanup -RunDir '${R.runDir}'`, 'seat-logins', 'Close').catch(() => null)
log('DONE: ' + all.map((r) => r.summary || (r.skipped ? `${r.code}: skipped (other worker)` : `${r.code}: ${r.error}`)).join(' | '))

// ---- learn: signals for /tidy
// LEARN 'auto': only after something eventful; a clean run gets the cleanup
phase('Learn')
// every finished run ends with a retro (bossy E10)
const retroDue = (results) => { log('RETRO DUE: run /tidy (bossy E10) once no other workflow of this session runs'); return { results, unpublished: results.filter((r) => r.unpublished || r.error).map((r) => r.code), envFixOpen: results.filter((r) => r.envFixOpen).map((r) => r.code), retroDue: true,
 budget: { cap: BUD.cap, estimate: BUD.estimate, spent: BUD.spent, stopped: BUD.stop, ...(CAPMIN && { minutes: BUD.min, capMinutes: CAPMIN, timeCapped: !!BUD.late }) }, ...(STOPPED.length + LATER.length ? { next: nextCall([...STOPPED, ...LATER]) } : {}) } }
const eventful = all.some((r) => r.error || r.eventful)
if (LEARN === false || (LEARN === 'auto' && !eventful)) {
 await runStep(`& ${ORCH} cleanup -Quiet`, 'cleanup', 'Learn')
 log(`learn: skipped (${LEARN === false ? 'learn: false' : 'auto: clean run'}); cleanup ran`)
 return retroDue(all)
}
// signals only: /tidy (run after every finished run) turns them into lessons
const learned = await agent(`Kind retro (learn step): record this /testy run's signals.${PATHS}
Outcome (JSON):
${JSON.stringify(all).slice(0, 60000)}

1. One signal per notable event (failures, retries, budget stops / handoffs, NOT_TESTED causes, audit reclassifications / not-exercised splits, verify "not reproduced" or "inconclusive", anything that
 cost time or worked unusually well):
 & ${ORCH} learn -Skill <pokey|other skill> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. & ${ORCH} cleanup (only kit-created leftovers): mention what it freed.
Return how many signals you recorded.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, agentType: 'kitty', ...pick('learn'), effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s)`)
return retroDue(all)
