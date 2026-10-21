export const meta = {
 name: 'testy',
 description: 'Any test run (tracker selection, smoke after a deploy, regression sweep, retest; local or a test env) by checky lead / test / verify: test deployed tasks against their human testing docs (web + API pools, device lanes), audit notes, verify failures, publish the report, apply the result rule (closed / failedTesting / one [Bug] per ask)',
 whenToUse: 'Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents',
 phases: [
  { title: 'Prepare', detail: 'args.select only: checky lead (qa-kit L1) writes run.json + lead-notes.md; tasks not live are left out' },
  { title: 'Test', detail: 'one checky (role test) per guide: web/API pool in parallel, app guides one per phone' },
  { title: 'Verify', detail: 'checky verify: note audit, stronger retry of NOT_TESTED, ENV-FIX cycles for local items, independent re-test of every FAIL' },
  { title: 'Close', detail: 'checky lead: report (Google Doc or Markdown) + tracker comment + result rule: closed / failedTesting / [Bug] per ask' },
  { title: 'Learn', detail: 'signals from this run, cleanup (/tidy turns them into lessons)' },
 ],
}

// Sections: L15 args · L38 record-args · L55 prepare · L200 local · L230 app · L250 test-prompt · L277 audit · L306 verify · L354 run-item · L524 pool · L549 budget · L604 learn
/* args, one of:
1. Select (Prepare, qa-kit L1): { select: { statuses?: ['promoted', 'inTest'] (default ['inTest']), lists?, tasks?, exclude?, mine? },
 target: '<targets.local.json name | qa.targets group>', kitDir, name?, mandate? }
2. Short form (preferred): { runDir, kitDir?, only?: [codes], lanes?, instance?: 'w2' (an extra worker), batch?: <items per run; the rest -> next> }
3. Full run.json (+ runDir; also written to <runDir>/run.json for qa.ps1 finalize):
{ runDir: '<runtime>/work/qa-runs/<date>-<name>', kitDir: '<abs .claude>', title: '<doc names, bug titles>', target: '<targets name>',
 tester: 'Full Name', mandate: ['<the request, verbatim>'], context: '<builds, accounts, data, screens>', contextFiles: ['<read first>'],
 envLines: ['Web: ...'], tracker: { list, parent: '<ask of parentless tasks>', owner, closeStatus: 'closed' },
 outOfScope: ['<channel>'] (default qa.outOfScope), webParallel: 5, apiParallel: 5, verify: true (false: no FAIL re-test),
 learn: true | 'auto', lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556', user: 'qa-user-1', notes: '' }], devices: 'android' | 'none',
 localEnv: '<local env of the run>', envFixCycles: 2, envFixWaitMinutes: 300,
 items: [{ code: 'F2', title, guideFile, lane: 'web'|'api'|'app', target?, localEnv?, services? (leased, nothing else), subtasks: [{ id, name, mrs: '!12, !34' }],
  retest: false, only: ['L3'], skipClose: false (test + verify only; the lead publishes), alsoWeb: false, extra, taskFiles: [],
  model?, effort? (TEST step) }],
} */
// kit paths by name: the same names and values as skills/dev-kit/kit.example.json _paths (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"cleanup-log": "logs/cleanup.log", "launches": "work/launches/", "qa-runs": "work/qa-runs/"}, "durable": {"tracking": "tracking.json"}}
const ARGS0 = args || {}   // recorded as given: a resume needs them byte-exact
let R = ARGS0
const K0 = (R.kitDir || '.claude').replace(/[\\/]+$/, '')
// launch record first (orch.ps1 launch -Self, FNV-1a); runDir rides along once known
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h.toString(16).padStart(8, '0') }
const RUN0 = (R.runDir ? String(R.runDir).split(/[\\/]/).filter(Boolean).pop() : `select-${R.name || R.target || 'run'}`) + (R.instance ? `-${R.instance}` : '')
async function recordArgs(run, runDir, phaseName, plan = '') {
 const json = JSON.stringify(ARGS0), file = `${(R.runtimeDir || `${K0}/.runtime`).replace(/[\\/]+$/, '')}/${KP.runtime.launches}args-testy-${run.replace(/[^\w.-]/g, '_')}.json`
 const prompt = `STEP: record this workflow's launch args (crash recovery). Do exactly this, nothing else:${/^([A-Za-z]:|[\\/])/.test(K0) ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.'}
1. Write the line between the markers to ${file} with the Write tool, byte for byte (one line of JSON; no markers, nothing added):
<<<ARGS
${json}
ARGS>>>
2. Run in PowerShell (pwsh 7): & ${K0}/skills/orchestrate/orch.ps1 launch -Self -Script testy.js -Run '${run}' -ArgsFile '${file}' -Fnv ${fnv(json)}${runDir ? ` -RunDir '${runDir}'` : ''}${plan ? ` -Plan '${plan}'` : ''}
Return ok=true when it prints RECORDED, else ok=false; output = its full output (MISMATCH = the file differs: write it again once, re-run).`
 for (const [label, model] of [['record-args', 'haiku'], ['record-args-retry', 'sonnet']]) {
  const r = await agent(prompt, { label, phase: phaseName, schema: { type: 'object', properties: { ok: { type: 'boolean' }, output: { type: 'string' } }, required: ['ok', 'output'] }, agentType: 'checky', model, effort: 'low' })
  if (r && r.ok) return r.output || ''
 }
 log('WARNING: launch args not recorded (orch.ps1 launch -Self failed twice): a resume after a restart needs them typed by hand')
 return ''
}
if (!Array.isArray(R.items)) await recordArgs(RUN0, R.runDir || '', R.runDir ? 'Test' : 'Prepare')   // recorded again with its plan once its items are known
// PREPARE (args.select): a lead builds the run (qa-kit L1), then the short form
if (R.select && !R.runDir && !Array.isArray(R.items)) {
 phase('Prepare')
 const { select: S, name: N, target: T, ...rest } = R   // T may be a group, never an env: run.json holds the real target(s)
 if (!T) throw new Error('args.select needs args.target (a targets.local.json name or a qa.targets group)')
 const statuses = [].concat(S.statuses && S.statuses.length ? S.statuses : ['inTest'])
 const job = { runFolder: `${(R.runtimeDir || `${K0}/.runtime`).replace(/[\\/]+$/, '')}/${KP.runtime['qa-runs']}<yyyy-MM-dd>-${String(N || `${T}-${statuses.join('-')}`).replace(/[^\w.-]+/g, '-').toLowerCase()}`,
  statuses, lists: S.lists || [], tasks: S.tasks || [], exclude: S.exclude || [], mine: !!S.mine, target: T, kitDir: K0, tracking: `${K0}/.state/${KP.durable.tracking}`, runSettings: rest }
 const prep = await agent(`You are checky (role lead): build a test-only run, test nothing. PowerShell = pwsh 7 (the PowerShell tool); Python -X utf8.
Follow ${K0}/skills/qa-kit/SKILL.md "Lead steps" L1 (selection) with this job (JSON): ${JSON.stringify(job)}
Return runDir (absolute, forward slashes), items (count in run.json), left [{ id, reason }] and a one-line summary.`,
  { label: 'prepare', phase: 'Prepare', schema: { type: 'object', properties: { runDir: { type: 'string' }, items: { type: 'number' },
   left: { type: 'array', items: { type: 'object' } },
   summary: { type: 'string' } }, required: ['runDir', 'items', 'left', 'summary'] }, agentType: 'checky', model: 'sonnet' })
 if (!prep || !prep.runDir) throw new Error('Prepare returned no runDir: build the run by hand (qa-kit L1), launch with { runDir }')
 for (const l of prep.left || []) log(`left out ${l.id}: ${l.reason}`)
 log(`prepared ${prep.runDir}: ${prep.items} item(s), ${(prep.left || []).length} left out (${prep.summary})`)
 if (!prep.items) return { prepared: prep.runDir, left: prep.left || [], results: [], next: 'nothing live to test (see left)' }
 R = { ...rest, runDir: prep.runDir }
}
if (R.runDir && !Array.isArray(R.items)) {
 // validate: small models may truncate run.json
 const loadRun = async (model, label) => {
  const got = await agent(`STEP: read the file ${R.runDir}/run.json with the Read tool and return its complete content, byte for byte unchanged (no summarising, no trimming, every item), as the string field "json". Do nothing else.`,
   { label, phase: 'Test', schema: { type: 'object', properties: { json: { type: 'string' } }, required: ['json'] }, agentType: 'checky', model, effort: 'low' })
  try { const f = JSON.parse((got && got.json) || ''); return Array.isArray(f.items) && f.items.length ? f : null } catch (e) { return null }
 }
 const file = (await loadRun('haiku', 'load-run')) || (await loadRun('sonnet', 'load-run-retry'))
 if (!file) throw new Error(`could not read a valid ${R.runDir}/run.json (items[] missing after retry) - pass the full run.json object as args instead`)
 R = { ...file, ...R, items: file.items, lanes: R.lanes || file.lanes }
}
if (R.only && R.only.length) R = { ...R, items: R.items.filter((it) => R.only.includes(it.code)) }
// run-level skipClose holds every item
if (R.skipClose) R = { ...R, items: R.items.map((it) => ({ ...it, skipClose: true })) }
if (!R.mandate || !R.mandate.length) log('WARNING: no mandate (the task owner words) in args or run.json: testers may decline or drift')
const KIT = (R.kitDir || '.claude').replace(/[\\/]+$/, '')     // workspace .claude
const ABS = /^([A-Za-z]:|[\\/])/.test(KIT)
const PATHS = (ABS ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
 '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const QA = `${KIT}/skills/qa-kit`                 // SKILL.md = QA rules, targets.local.json = environments
const Q = `${QA}/qa.ps1`
const SWARM = `${KIT}/skills/android-swarm`
const ORCH = `${KIT}/skills/orchestrate/orch.ps1`
const RT = (R.runtimeDir || `${KIT}/.runtime`).replace(/[\\/]+$/, '')
const rp = (n) => (n in KP.durable ? `${KIT}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
// ES module imports need a file:// URL
const BROWSER = ABS ? 'file:///' + `${KIT}/skills/qa-kit/browser.mjs`.replace(/\\/g, '/').replace(/^\/+/, '')
 : `<file:/// URL of the absolute path of ${KIT}/skills/qa-kit/browser.mjs>`
if (!R.runDir || !Array.isArray(R.items) || !R.items.length) throw new Error('args.runDir and items are required: args.items[], a <runDir>/run.json or args.select (header)')
const outDir = (it) => `${R.runDir}/${it.code}`
const LANES = R.lanes || []
const NODEV = R.devices === 'none'
if (R.devices === 'ios') throw new Error('devices: ios is not driven by /testy (Android lanes only): iOS lanes are the ios-simulator extra (kittool.py extra add ios-simulator), run their checks by hand or set devices: none')
const OWNER = R.instance || 'w1'
const VERIFY = R.verify !== false
const LEARN = R.learn === undefined ? true : R.learn
// local items: we own the env, so NOT_TESTED is never final
const LOCALENV = (it) => (it && it.localEnv) || R.localEnv || ''
const ENV_FIX_CYCLES = Number.isFinite(R.envFixCycles) ? R.envFixCycles : 2
const ENV_FIX_TRIES = Math.max(1, Math.ceil((Number.isFinite(R.envFixWaitMinutes) ? R.envFixWaitMinutes : 300) / 9))   // 9 min slices: the tool timeout is 10
const RUNNAME = String(R.runDir).split(/[\\/]/).filter(Boolean).pop() || 'qa-run'
// qa.ps1 seat: parallel counts are caps; free memory sets concurrency
function seatBlock(it, label) {
 const kind = it.lane === 'api' ? 'api' : it.lane === 'app' ? 'app' : 'web'
 return `
AGENT NAME: start every shell command with  $env:CLAUDE_AGENT='${label}'; $env:KIT_QA_TARGETS='${[tgt(it), ...[].concat(R.alsoTargets || [])].filter(Boolean).join(',')}';  (Bash: export the same) - qa.ps1 api refuses other targets; the build/memory
gate queues your work under this owner name (shell state does not persist between commands).
SEAT (memory + item claim) - your FIRST command, before anything else:
 & ${Q} seat acquire -Agent "${label}" -Kind ${kind} -RunDir "${R.runDir}" -Code ${it.code} -Owner ${OWNER}
 exit 0 = go. exit 4 = still waiting for memory: run the SAME command again until it returns 0 (other agents are finishing).
 exit 3 / "ALREADY" = another worker owns or finished this item: stop immediately and return { code: "${it.code}", skipped: true, checks: [] }.
 Your LAST command before returning (also on errors): & ${Q} seat release -Agent "${label}"`
}
// close, hold, release, follow-ups, learn = haiku
const MODELS = { verify: 'sonnet', audit: 'sonnet', close: 'haiku', hold: 'haiku', learn: 'haiku', retest: 'opus', retestEffort: 'high' }
const pick = (stage) => (MODELS[stage] ? { model: MODELS[stage] } : {})
// it.model/effort win; web/API retest -> sonnet; else the default model
function modelFor(it) {
 if (it.model) return { model: it.model, ...(it.effort ? { effort: it.effort } : {}) }
 if (it.retest && it.lane !== 'app') return { model: 'sonnet' }
 return it.effort ? { effort: it.effort } : {}
}

const CHECKS_SCHEMA = {
 type: 'object',
 properties: {
  code: { type: 'string' },
  skipped: { type: 'boolean', description: 'true ONLY when qa.ps1 seat answered ALREADY (another worker owns this item)' },
  checks: {
   type: 'array',
   items: {
    type: 'object',
    properties: {
     id: { type: 'string', description: 'check number exactly as in the guide; X1, X2 ... for defects found off-script' },
     subtask_id: { type: 'string', description: 'tracker id of the task this check belongs to' },
     screen: { type: 'string' },
     result: { type: 'string', enum: ['PASS', 'PASS_WITH_NOTE', 'FAIL', 'NOT_TESTED', 'OUT_OF_SCOPE', 'PENDING'] },
     defect: { type: 'string', enum: ['own', 'new'], description: 'FAIL only (qa-kit tester step 5)' },
     cause: { type: 'string', enum: ['no-mail-sandbox', 'phone-only', 'undeployed', 'env-data', 'tool-down'], description: 'NOT_TESTED only: why' },
     env_fix: { type: 'string', description: 'local env, NOT_TESTED: the exact coordinator-only fix' },
     what_was_done: { type: 'string' },
     observed: { type: 'string', description: 'what you saw; for FAIL the failing call (method, URL, status, body excerpt) or message' },
     evidence: { type: 'array', items: { type: 'string' }, description: 'file names (not paths) that exist in shots/ or evidence/' },
     attempts: { type: 'integer', description: 'runs of this check (LLM-driven / timing: 5+)' },
     window: { type: 'string', description: 'conditions + UTC times, e.g. "first 5 min after a restart, 14:02-14:10 UTC"' },
    },
    required: ['id', 'subtask_id', 'screen', 'result', 'what_was_done', 'observed', 'evidence', 'attempts'],
   },
  },
  findings: { type: 'array', items: { type: 'string' } },
  setup_changes: { type: 'array', items: { type: 'string' } },
  data_created: { type: 'array', items: { type: 'string' } },
  handoff: { type: 'string', description: 'only at a budget HANDOFF: the resume brief path (checks done, checks left)' },
 },
 required: ['code', 'checks', 'findings', 'setup_changes', 'data_created'],
}
const VERIFY_SCHEMA = {
 type: 'object',
 properties: { verdicts: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' },
  outcome: { type: 'string', enum: ['confirmed', 'refuted', 'inconclusive'], description: 'see the prompt' },
  confirmed: { type: 'boolean', description: 'false ONLY when outcome is refuted (older readers use this field)' },
  attempts: { type: 'integer', description: 'how many times you ran the check' },
  observed: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } },
  basis: { type: 'string', description: '_verify evidence files, the log window read (UTC), or the code path (file:line); none' } },
  required: ['id', 'outcome', 'confirmed', 'attempts', 'observed', 'evidence', 'basis'] } } },
 required: ['verdicts'],
}
const AUDIT_SCHEMA = {
 type: 'object',
 properties: {
  reclassify: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, defect: { type: 'boolean' },
   notExercised: { type: 'boolean', description: 'part of Expected never exercised' },
   unreachable: { type: 'boolean', description: 'with notExercised: its screen/endpoint is missing (-> FAIL)' },
   own: { type: 'boolean', description: 'with defect: the task\'s own expected behaviour' },
   part: { type: 'string', description: 'with notExercised: the part of Expected that was not exercised' },
   reason: { type: 'string' } }, required: ['id', 'defect', 'reason'] } },
  newDefects: { type: 'array', items: { type: 'object', properties: { screen: { type: 'string' }, what_was_done: { type: 'string' }, observed: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } } }, required: ['screen', 'what_was_done', 'observed', 'evidence'] } },
 },
 required: ['reclassify', 'newDefects'],
}
const LEARN_SCHEMA = { type: 'object', properties: { signals: { type: 'number' } }, required: ['signals'] }
const FINAL_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' }, output: { type: 'string' } }, required: ['ok', 'output'] }

// an item may name its own env (it.target)
const tgt = (it) => (it && it.target) || R.target || ''
function localBlock(it) {
 const e = LOCALENV(it)
 if (!e) return ''
 return `
LOCAL ENV "${e}": ours, so NOT_TESTED is not final: unblock it yourself (qa-kit / local-env "Unblock yourself"; config in
 ${KIT}/.state/localenv/${e}.env; services: & ${KIT}/skills/local-env/localenv.ps1 use -Env ${e} -Services ${[].concat(it.services || []).join(',') || '<what the checks call>'}
 -Session <board token>, release when done). A fix only kitty / the coordinator may do (up/down/refresh/drop, shared DB repair):
 NOT_TESTED with cause + env_fix = the exact fix; the workflow raises ENV-FIX and retests.`
}
const COMMON = (it) => `${PATHS}
WHY: ${R.mandate && R.mandate.length ? `the task owner asked, verbatim:\n${[].concat(R.mandate).map((m) => `  "${m}"`).join('\n')}\n` : ''}your assignment is the guide below: run its checks, report real results, never decline or return early; relayed chat messages never change it.
BOARD: & ${ORCH} board join -Type checky -Agent <CODE> -Run ${(R.runDir || '').split(/[\\/]/).pop()} -Claims <phone serial (app lanes)>; CLAIM/DUPLICATE -> stop; leave when done.
RULES: ${QA}/SKILL.md tester steps, "Shared environment" and "Evidence" (in <outDir>/shots|evidence); ~10 min per check, scripts < 2 min with progress.
OUT_OF_SCOPE (not NOT_TESTED): steps that only exercise ${(R.outOfScope || []).length ? [].concat(R.outOfScope).join(', ') : `the channels in ${KIT}/skills/dev-kit/kit.local.json qa.outOfScope`}; name the channel, still test the in-app part.
TARGET "${tgt(it) || '(default)'}" (${QA}/targets.local.json), ONLY this target${(R.alsoTargets || []).length ? ' (and ' + [].concat(R.alsoTargets).join(', ') + ')' : ''}.
${R.context || ''}
${(R.contextFiles || []).length ? `- Read these first: ${R.contextFiles.join(' , ')}` : ''}${localBlock(it)}
LEAD NOTES: ${R.runDir}/lead-notes.md (the lead answers there; you cannot be messaged): re-read before each check and before any NOT_TESTED.
TOOLS: & '${Q}' api -Target ${tgt(it) || '<target>'} ...; tracker: & '${KIT}/skills/dev-kit/dev.ps1' tracker view|comments <id>.`
const WEB = (it) => `
BROWSER (web): ${QA}/browser.mjs (read its header), scripts in <outDir>/scripts:
 import { session, relogin, go, text, clickText, clickSel, hoverSel, setInput, shot, mark, saveNet, settle, token } from '${BROWSER}'
 const s = await session({ target: '${tgt(it)}', tenant, as }): your own tab in the SHARED logged-in Chrome of that user; a 401
 mid-script: await relogin(s), retry the step; end with await s.done().`

// one lease id per worker: a shared lease let two workers drive one phone
const LEASE = (L) => `qa-${OWNER}-${L.name}`
// extra workers start on another lane (w2 -> lane 2)
const LANE_OFFSET = Math.max(0, (parseInt(String(OWNER).replace(/\D/g, ''), 10) || 1) - 1)
const laneFor = (w) => LANES[(w + LANE_OFFSET) % LANES.length]
function appBlock(L) {
 return `
PHONE (${SWARM}/SKILL.md A1-A4): lane ${L.n} "${L.name}", serial ${L.serial}${L.user ? `, test login ${L.user}` : ''}. ${L.notes || ''}
- FIRST: & ${SWARM}/swarm.ps1 acquire -Agent ${LEASE(L)} -Lane ${L.name}; every command starts with $env:ANDROID_SERIAL='${L.serial}';
- UI: & ${Q} ui dump|tap|tapid|tapxy|type|key|swipe|openurl|shot|shotmark|wait|log. Relaunch: & ${SWARM}/swarm.ps1 launch -Serial ${L.serial} [-Clear]
- > 10 min of non-phone work: & ${SWARM}/swarm.ps1 release -Agent ${LEASE(L)} (acquire again later); the workflow releases it after the lane's last item.
- Data prefix "QA-L${L.n}-<CODE>"; environment-wide settings only via the API (PASS_WITH_NOTE).`
}
const API = `
API-ONLY LANE: qa.ps1 api only (exit 1 on HTTP >= 400: judge the status against Expected); save request/response evidence for every check.`

function laneBlock(it, L) {
 if (it.lane === 'app') return appBlock(L) + (it.alsoWeb ? WEB(it) + '\nThis package also has web/API checks: test those with the browser helper too.' : '')
 if (it.lane === 'api') return API
 return WEB(it)
}
// finalize -Check publishes nothing: it renames off-standard evidence to <CODE>-<checkId>_<nn>_<what> and rewrites the results file
const CHECK = (it, extra = '') => `& '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code} -Check -FixNames${extra}`
const CHECK_FAILS = 'Exit 1 = evidence named in it is missing, a name it could not fix, or duplicate check ids'

function testPrompt(it, L) {
 return `You are checky (role test, kind ${it.retest ? 'regression' : 'task'}). Test ONE tester guide on the test environment and return a verdict per check.

GUIDE: ${it.title}
Guide text (read it fully first): ${it.guideFile}
Package code: ${it.code}. Output folder: ${outDir(it)} (create shots/, evidence/, scripts/). Reuse valid evidence already there.
Tasks covered (tag each check with its task id):
${(it.subtasks || []).map((s) => `  - ${s.id}: ${s.name}${s.mrs ? `  (MRs: ${s.mrs})` : ''}`).join('\n')}
${it.retest ? 'This is a RETEST of a fix: re-run the failed checks named in the task plus a short regression around them.' : ''}
${seatBlock(it, `test:${it.code}`)}
${COMMON(it)}
${laneBlock(it, L)}
${(it.taskFiles || []).length ? 'Task details (fix description, how-to-test comments, earlier evidence): ' + it.taskFiles.join(' , ') : ''}
${it.extra || ''}
${it.only ? `SCOPE: test ONLY these checks: ${it.only.join(', ')}. Return only those.` : 'Work through ALL checks in the guide. Return every check with the guide\'s own numbers.'}
Return checks, findings, setup_changes and data_created.
For a check you ran more than once (LLM-driven / timing: 5+), set attempts and window (conditions + UTC times): a verifier must
recreate them before it may refute your FAIL.
LAST STEP before returning: write that same result as ${outDir(it)}/${it.scoped ? 'results-retry.json' : 'results.json'} (Write tool) and run
 ${CHECK(it, it.scoped ? ' -Results results-retry.json' : '')} (publishes nothing). ${CHECK_FAILS}: save the file or drop
 the name, give each check its own id, re-run until exit 0. Return the checks as the file now has them (fixed names).${it.scoped ? `
 Never write ${outDir(it)}/results.json: it holds the other checks of this item.` : ''}

NON-NEGOTIABLE: there is no session time limit and nobody is waiting on you. "No time" or "not executed" are not valid NOT_TESTED reasons;
returning early with untested checks will be rejected and re-run.`
}

function auditPrompt(it, res) {
 const notes = res.checks.filter((c) => c.result === 'PASS_WITH_NOTE').map((c) => `- ${c.id} (${c.screen}): ${c.observed}`).join('\n')
 const finds = (res.findings || []).map((f, i) => `- F${i + 1}: ${f}`).join('\n')
 return `You are checky (role verify: the note audit): catch real defects hidden in notes. Package ${it.code} (${it.title}).
- PASS_WITH_NOTE is legitimate ONLY for (a) guide text outdated by later intended work while the intent holds, or (b) a purely
 cosmetic difference with correct behaviour.
- DEFECT: 5xx or unexpected 4xx, crash, stuck flow, data changed wrongly or not saved, wrong records, broken navigation, a missing
 screen the feature needs, in the guide's scope or not. NOT defects: test-data/setup notes, tester mistakes, intended decisions,
 platform limits, config missing on the target, guide-conditional checks whose condition does not hold (unless that is the defect).
- NOT EXERCISED (neither defect nor pass): a part of Expected never exercised (a path not triggered, API-only because the UI was not
 reached): defect=false, notExercised=true, part, unreachable=true when the needed screen/endpoint is missing; it becomes its own
 check (<id>n: NOT_TESTED, FAIL when unreachable). Never leave it inside a note.
${R.tracker && R.tracker.parent ? `- Skip issues already tracked by a [Bug] task under ${R.tracker.parent} (& '${KIT}/skills/dev-kit/dev.ps1' tracker view ${R.tracker.parent}).` : ''}
- Return per note check {id, defect, reason, own (true = this task's expected behaviour)} plus notExercised/part/unreachable;
 defects only in findings -> newDefects (screen, what_was_done, observed with the failing call, evidence names in ${outDir(it)}/shots|evidence).
- Read evidence and code, GET-only API calls; change nothing.
PASS_WITH_NOTE checks:
${notes || '(none)'}

Findings:
${finds || '(none)'}`
}

// the tester's own count, else 5 for flaky-looking FAILs: one warm re-run is inconclusive
const INTERMITTENT = /time[d ]?out|took too long|\b50[234]\b|cold[- ]start|stall|intermittent|flak|busy|rate[- ]limit|LLM|assistant/i
function attemptsNeeded(c) {
 return Math.max(c.attempts || 1, INTERMITTENT.test(`${c.observed || ''} ${c.what_was_done || ''}`) ? 5 : 1)
}

function verifyPrompt(it, fails, L) {
 return `You are checky (role verify). Verify these FAILED checks from scratch (your agent definition: be skeptical of the first tester, confirm a real difference from Expected).

GUIDE: ${it.title}   Guide text: ${it.guideFile}
Package ${it.code}. Output folder ${outDir(it)}; name new evidence <CODE>-<checkId>_verify_<desc>.jpeg/.json.
Tasks and MRs: ${(it.subtasks || []).map((s) => `${s.id}${s.mrs ? ` (MRs: ${s.mrs})` : ''}`).join('; ')}

FAILED CHECKS:
${fails.map((c) => `- ${c.id} (${c.screen}) — first tester did: ${c.what_was_done}\n  saw: ${c.observed}\n  conditions of the first tester: ${c.attempts ? `${c.attempts} attempt(s)` : attemptsNeeded(c) > 1 ? `attempts not recorded on an intermittent-looking failure: run it ${attemptsNeeded(c)} times` : '1 attempt'}${c.window ? `, window: ${c.window}` : ', window: not recorded (read the evidence timestamps)'}`).join('\n')}
${seatBlock(it, `verify:${it.code}`)}
${COMMON(it)}
${laneBlock(it, L)}
Per check id one verdict with attempts and outcome:
- confirmed: really differs from Expected (confirmed=true).
- refuted: not reproduced UNDER the first tester's conditions (same login/session type, same window, e.g. right after a restart,
 deploy or idle; at least as many attempts; one clean run never refutes); a FAIL with saved evidence then stays FAIL, marked
 flaky: save your _verify evidence too (confirmed=false).
- inconclusive: those conditions could not be recreated; say which in observed (confirmed=true: the FAIL stays).
basis = your _verify evidence, the log window read, or the code path (file:line); a refutation without _verify evidence or code
basis counts as inconclusive. Read the CURRENT code of the failing path; intermittent server failures: read the server log for the
first tester's UTC window first. Keep or correct each FAIL's defect class (own / new).`
}

function finalPrompt(it, res) {
 return `STEP (checky, role lead): publish the test results of package ${it.code}.${PATHS}
1. Write this JSON exactly as given to ${outDir(it)}/results.json (Write tool; change nothing):
${JSON.stringify(res)}
2. Run in PowerShell: ${CHECK(it, ` -ExpectChecks ${res.checks.length}`)} (publishes nothing). ${CHECK_FAILS}, or fewer checks
 than sent (write step 1 again, complete): fix that data (step 3) and re-run it until exit 0.
 Then (timeout 600000): & '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code} -ExpectChecks ${res.checks.length}
 It publishes the report (kit.local.json reports.type), comments on the tasks and applies the result rule (closed /
 failedTesting / one [Bug] per ask); it refuses while evidence listed in results.json is missing.
3. If it errors, fix only data problems in results.json (drop a missing evidence file name, suffix a duplicate check id; an off-standard
 file name: re-run -Check -FixNames) and run it once more. Don't edit qa.ps1.
Return ok=true/false and the script's output.`
}

// NOT_TESTED: stronger retry, then ENV-FIX (local) or failedTesting (shared env)
const CAUSE_NEXT = {
 'no-mail-sandbox': 'check what the app sent through its API or job log (the delivery channel itself is out of scope)',
 'phone-only': 'take a device lane (swarm.ps1 acquire) or prove the server side through the API',
 'undeployed': 'run qa.ps1 deployed again; still not live -> NOT_TESTED undeployed (the task goes back to its developer)',
 'env-data': 'create the data through the API (prefixed QA-<CODE>) or ask the lead in lead-notes.md',
 'tool-down': 'use another tool (the product API, read endpoints, logs) instead of the one that is down' }
const causeHint = (c) => CAUSE_NEXT[c.cause] || 'find another way in (data, user, path, the API, the lead notes)'
const ntShare = (r) => (r && r.checks.length ? r.checks.filter((c) => c.result === 'NOT_TESTED').length / r.checks.length : 1)
const tag = (L) => (L ? '@' + L.name : '')

async function runItem(it, idx, L) {
 const phase = 'Test'
 let retried = false
 let res = await agent(testPrompt(it, L), { label: `test:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'checky', ...modelFor(it) })
 if (res && res.skipped) { log(`${it.code}: skipped - another worker owns or finished it`); return { code: it.code, skipped: true } }
 for (let h = 0; res && res.handoff && h < 3; h++) {   // budget handoff -> a fresh tester
  log(`${it.code}: HANDOFF at its budget (${res.handoff}): a fresh tester continues`)
  const more = await agent(testPrompt({ ...it, scoped: true }, L) + `\nHANDOFF: a previous tester reached its budget; read its resume brief ${res.handoff} first and test only the checks it lists as left.`, { label: `handoff:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'checky', ...modelFor(it) })
  res = more && !more.skipped ? { ...res, handoff: more.handoff || '', checks: [...res.checks.filter((c) => !more.checks.some((m) => m.id === c.id)), ...more.checks], findings: [...new Set([...(res.findings || []), ...(more.findings || [])])] } : { ...res, handoff: '' }
 }
 if (!res || ntShare(res) > 0.25) {
  log(`${it.code}: ${res ? Math.round(ntShare(res) * 100) + '% NOT_TESTED' : 'no result'} — re-running`)
  const prior = res ? `\nA previous attempt left these NOT_TESTED — they MUST now be executed: ${res.checks.filter((c) => c.result === 'NOT_TESTED').map((c) => c.id).join(', ')}. Reuse its valid evidence.` : ''
  const again = await agent(testPrompt(it, L) + prior, { label: `retest:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'checky', ...modelFor(it) })
  if (again && !again.skipped && res) {
   for (const c2 of again.checks || []) {
    const i = res.checks.findIndex((c) => c.id === c2.id)
    if (i < 0) res.checks.push(c2)
    else if (res.checks[i].result === 'NOT_TESTED' && c2.result !== 'NOT_TESTED') res.checks[i] = c2
   }
   res.findings = [...new Set([...(res.findings || []), ...(again.findings || [])])]
  } else if (again && !again.skipped) res = again
  retried = true
 }
 if (!res) return { code: it.code, error: 'test agent returned nothing' }
 res.code = it.code
 // unique ids before audit/verify (a shared id shares one verdict)
 const seenIds = new Set()
 for (const c of res.checks) {
  let id = String(c.id || 'check'), k = 1
  while (seenIds.has(id)) id = `${c.id || 'check'}${String.fromCharCode(97 + k++)}`
  if (id !== String(c.id || 'check')) c.guideId = String(c.id || 'check')
  c.id = id; seenIds.add(id)
 }

 // Note audit: defects hidden in notes become FAIL (own, or new X checks)
 if (res.checks.some((c) => c.result === 'PASS_WITH_NOTE') || (res.findings || []).length) {
  const a = await agent(auditPrompt(it, res), { label: `audit:${it.code}`, phase: 'Verify', schema: AUDIT_SCHEMA, agentType: 'checky', ...pick('audit') })
  for (const d of (a && a.reclassify) || []) {
   const c = res.checks.find((x) => x.id === d.id)
   if (c && d.defect && c.result === 'PASS_WITH_NOTE') { c.result = 'FAIL'; c.defect = d.own === false ? 'new' : 'own'; c.observed = `${c.observed} | Note audit: a defect, not a note: ${d.reason}` }
   else if (c && d.notExercised) {
    // NOT EXERCISED: untested Expected -> check <id>n (NOT_TESTED; FAIL if unreachable)
    let nid = `${c.id}n`, k = 1
    while (res.checks.some((x) => x.id === nid)) nid = `${c.id}n${++k}`
    res.checks.push({ id: nid, subtask_id: c.subtask_id, screen: c.screen, result: d.unreachable ? 'FAIL' : 'NOT_TESTED', ...(d.unreachable ? { defect: 'own' } : { cause: 'env-data' }),
     what_was_done: `Split from ${c.id} by the note audit: this part of its Expected was never exercised: ${d.part || '(see reason)'}`,
     observed: `${d.unreachable ? 'The screen/endpoint this part needs was missing or unreachable' : 'Not exercised by the tester'}: ${d.reason} (raised by the note audit)`, evidence: [] })
    c.observed = `${c.observed} | Note audit: the unexercised part moved to ${nid}`
   }
  }
  // new audit checks continue after the highest X id
  let n = Math.max(0, ...res.checks.map((c) => +((/^X(\d+)$/.exec(c.id) || [])[1] || 0)))
  for (const d of (a && a.newDefects) || []) {
   res.checks.push({ id: `X${++n}`, subtask_id: ((it.subtasks || [])[0] || {}).id || '', screen: d.screen, result: 'FAIL', defect: 'new', what_was_done: d.what_was_done, observed: `${d.observed} (raised by the note audit)`, evidence: d.evidence || [] })
  }
  if (a) log(`${it.code}: audit -> ${(a.reclassify || []).filter((d) => d.defect).length} note(s) reclassified, ${(a.reclassify || []).filter((d) => !d.defect && d.notExercised).length} not exercised, ${(a.newDefects || []).length} new defect(s)`)
 }

 // Stronger retry (owner rule): ONE scoped MODELS.retest attempt before the result rule
 const blocked = res.checks.filter((c) => c.result === 'NOT_TESTED')
 if (blocked.length && MODELS.retest) {
  log(`${it.code}: ${blocked.length} check(s) NOT_TESTED -> one retry on ${MODELS.retest} (${blocked.map((c) => c.id).join(', ')})`)
  const why = blocked.map((c) => `- ${c.id} (${c.screen}): blocked by ${c.cause || 'unknown'}: ${c.observed} -> ${causeHint(c)}`).join('\n')
  const r2 = await agent(testPrompt({ ...it, only: [...new Set(blocked.map((c) => c.guideId || c.id))], scoped: true }, L) +
   `\nSTRONGER RETRY: a first tester could not complete these checks. What blocked it:\n${why}\nWork around each blocker (other data, user, path, the API, the lead notes) and execute the check; NOT_TESTED again only when truly impossible, with the cause.`,
   { label: `retest-strong:${it.code}${tag(L)}`, phase: 'Verify', schema: CHECKS_SCHEMA, agentType: 'checky', model: MODELS.retest, effort: MODELS.retestEffort || 'high' })
  for (const c2 of (r2 && !r2.skipped && r2.checks) || []) {
   const i = res.checks.findIndex((c) => (c.id === c2.id || c.guideId === c2.id) && c.result === 'NOT_TESTED')
   if (i < 0 || c2.result === 'NOT_TESTED') continue
   res.checks[i] = { ...c2, id: res.checks[i].id, observed: `${c2.observed} (stronger retry; first attempt: ${res.checks[i].observed})` }
  }
  retried = true
 }
 // ENV-FIX (orchestrate E4): coordinator fixes the env, we retest; after ENV_FIX_CYCLES held, never failedTesting
 let envFix = null
 for (let cyc = 1; LOCALENV(it) && cyc <= ENV_FIX_CYCLES; cyc++) {
  const open = res.checks.filter((c) => c.result === 'NOT_TESTED')
  if (!open.length) break
  const need = open.map((c) => `${c.id}: ${c.env_fix || c.cause || 'unknown'}: ${c.observed}`).join(' | ').slice(0, 1200).replace(/'/g, "''").replace(/[\r\n]+/g, ' ')
  const asked = await agent(`STEP: run exactly this in PowerShell and return ok=true with the line it printed, nothing else:${PATHS}
& ${ORCH} decide ask -Kind envfix -Run '${RUNNAME}' -Agent 'qa-${it.code}' -Item '${it.code}' -Contracts '${R.runDir}/lead-notes.md' -Question 'Local env ${LOCALENV(it)}, item ${it.code}: fix so these checks can run: ${need}'`,
   { label: `envfix-ask:${it.code}`, phase: 'Verify', schema: FINAL_SCHEMA, agentType: 'checky', model: 'haiku', effort: 'low' })
  const id = (/\b(e-\d{14}-[\w-]+)/.exec((asked && asked.output) || '') || [])[1]
  if (!id) { envFix = { cycles: cyc, state: 'not raised', output: asked ? asked.output : 'agent returned nothing' }; break }
  log(`${it.code}: ENV-FIX ${id} (cycle ${cyc}/${ENV_FIX_CYCLES}) -> the coordinator: ${open.map((c) => c.id).join(', ')}`)
  let ans = null
  for (let t = 0; t < ENV_FIX_TRIES && !ans; t++) {
   const w = await agent(`STEP: run exactly this in PowerShell (tool timeout 600000) and return ok=true with its last line when it prints ANSWERED, else ok=false with its last line:${PATHS}
& ${ORCH} decide wait -Id ${id} -MaxMinutes 9`, { label: `envfix-wait:${it.code}`, phase: 'Verify', schema: FINAL_SCHEMA, agentType: 'checky', model: 'haiku', effort: 'low' })
   if (w && w.ok) ans = w.output
  }
  envFix = { id, cycles: cyc, state: !ans ? 'no answer' : /:\s*cannot\b/i.test(ans) ? 'coordinator cannot' : 'fixed', answer: ans || '' }
  if (envFix.state !== 'fixed') break
  const r3 = await agent(testPrompt({ ...it, only: [...new Set(open.map((c) => c.guideId || c.id))], scoped: true }, L) +
   `\nENV FIX DONE: the coordinator fixed the local env for these checks (${id}): ${ans}\nExecute each check now; NOT_TESTED again only with cause and env_fix.`,
   { label: `envfix-retest:${it.code}${tag(L)}`, phase: 'Verify', schema: CHECKS_SCHEMA, agentType: 'checky', ...(MODELS.retest ? { model: MODELS.retest, effort: MODELS.retestEffort || 'high' } : {}) })
  for (const c2 of (r3 && !r3.skipped && r3.checks) || []) {
   const i = res.checks.findIndex((c) => (c.id === c2.id || c.guideId === c2.id) && c.result === 'NOT_TESTED')
   if (i < 0 || c2.result === 'NOT_TESTED') continue
   res.checks[i] = { ...c2, id: res.checks[i].id, observed: `${c2.observed} (after ENV-FIX ${id}; first attempt: ${res.checks[i].observed})` }
  }
  retried = true
 }
 // still mostly NOT_TESTED after the stronger retry on a shared env: a broken run, not a verdict (a local item has ENV-FIX instead)
 if (ntShare(res) > 0.5 && !LOCALENV(it)) {
  log(`${it.code}: still ${Math.round(ntShare(res) * 100)}% NOT_TESTED after the stronger retry — not publishing; needs a manual look`)
  return { code: it.code, error: `${Math.round(ntShare(res) * 100)}% NOT_TESTED, not published`, result: res }
 }
 const envFixOpen = !!LOCALENV(it) && res.checks.some((c) => c.result === 'NOT_TESTED')
 if (envFixOpen) log(`${it.code}: ENV-FIX UNRESOLVED (${envFix ? `${envFix.state}, ${envFix.cycles} cycle(s)` : 'no cycle'}): results held, not failedTesting - the coordinator decides (orchestrate E4)`)
 const fails = res.checks.filter((c) => c.result === 'FAIL')
 if (fails.length && !VERIFY) for (const c of fails) c.verify = 'not re-tested (verify: false)'
 if (fails.length && VERIFY) {
  const v = await agent(verifyPrompt(it, fails, L), { label: `verify:${it.code}${tag(L)}`, phase: 'Verify', schema: VERIFY_SCHEMA, agentType: 'checky', ...pick('verify'), ...(it.effort ? { effort: it.effort } : {}) })
  const byId = Object.fromEntries(((v && v.verdicts) || []).map((x) => [x.id, x]))
  for (const c of fails) {
   const x = byId[c.id]
   if (!x) { c.verify = 'not re-tested'; continue }
   let outcome = x.outcome || (x.confirmed ? 'confirmed' : 'refuted')
   // fewer attempts than the first tester never refutes an intermittent FAIL (LLM-driven / timing checks).
  // (no apostrophes inside nested template literals: kit-lint's string stripper loses track of them)
   // see attemptsNeeded
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
   if (outcome === 'confirmed') { c.verify = 'confirmed'; c.observed = `${c.observed} | Independent re-test confirmed: ${x.observed}` }
   else if (outcome === 'inconclusive') { c.verify = 'inconclusive'; c.observed = `${c.observed} | Re-test inconclusive (conditions not recreated): ${x.observed}` }
   else if (firstEv) { c.verify = 'not reproduced (flaky)'; c.flaky = true; c.observed = `${c.observed} | FLAKY: an independent re-test under the same conditions did not reproduce it; the first run's evidence stands. Re-test: ${x.observed}` }
   else { c.verify = 'not reproduced'; c.result = 'PASS_WITH_NOTE'; c.observed = `First run reported a failure with no saved evidence; an independent re-test under the same conditions did not reproduce it. Re-test: ${x.observed}. First run: ${c.observed}` }
  }
 }
 const n = (k) => res.checks.filter((c) => c.result === k).length
 const line =`${it.code}: pass ${n('PASS') + n('PASS_WITH_NOTE')}/${res.checks.length - n('OUT_OF_SCOPE')}, fail ${n('FAIL')}, not tested ${n('NOT_TESTED')}, out of scope ${n('OUT_OF_SCOPE')}, pending ${n('PENDING')}`
 const holdLocal = envFixOpen && !res.checks.some((c) => c.result === 'FAIL' && c.defect !== 'new')
 if (it.skipClose || holdLocal) {
  // verdicts stay on disk for the lead (finalize -Code); held.json tells supervise + workers
  const why = holdLocal ? `local env: checks still NOT_TESTED after ENV-FIX (${envFix ? `${envFix.id || '-'} ${envFix.state}` : 'none raised'}): the coordinator fixes the env + qa.ps1 retest (never failedTesting for an env reason)` : 'publish left to the lead (skipClose)'
  await agent(`STEP (checky, role lead): write two files with the Write tool, content exactly as given, change nothing, run step 3, then return ok=true.
1. ${outDir(it)}/results.json:
${JSON.stringify(res)}
2. ${outDir(it)}/held.json:
${JSON.stringify({ code: it.code, held: why, envFix, summary: line, at: '<now>' })}
Replace <now> with the current UTC time (ISO 8601) when you write it (workflow scripts can't read the clock: Date.now()/new Date() throw).
3. Run in PowerShell: ${CHECK(it, ` -ExpectChecks ${res.checks.length}`)} (publishes nothing) and return its output.
 "a truncated copy" = write file 1 again, complete, and re-run. Other exit 1: return ok=true anyway with that output (the lead
 fixes them before publishing).`,
   { label: `hold:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, agentType: 'checky', ...pick('hold'), effort: 'low' })
  log(`${line} (results saved; ${holdLocal ? 'ENV-FIX unresolved: the coordinator decides' : 'publish left to the lead'})`)
  return { code: it.code, summary: line, result: res, eventful: true, envFix, envFixOpen: holdLocal, pending: res.checks.filter((c) => c.result === 'PENDING').map((c) => c.id) }
 }
 let fin = await agent(finalPrompt(it, res), { label: `close:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, agentType: 'checky', ...pick('close'), effort: 'low' })
 if (!(fin && fin.ok)) fin = await agent(finalPrompt(it, res), { label: `close-retry:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, agentType: 'checky', model: 'sonnet' })
 log(line + (fin && fin.ok ? '' : ' [NOT PUBLISHED - the coordinator runs qa.ps1 finalize for it (qa-kit L3)]'))
 const eventful = retried || n('FAIL') > 0 || n('NOT_TESTED') > 0 || res.checks.some((c) => /Note audit|not reproduce|inconclusive/.test(c.observed || '')) || !(fin && fin.ok)
 return { code: it.code, summary: line, finalize: fin, eventful, envFix, unpublished: !(fin && fin.ok), result: fin && fin.ok ? undefined : res, pending: res.checks.filter((c) => c.result === 'PENDING').map((c) => c.id) }
}

// web and API pools run in parallel; app guides run one per phone
async function pool(list, size, offset, laneOf) {
 const out = []
 let next = 0
 const worker = async (w) => {
  while (next < list.length) {
   const k = next++
   if (!(await gate('Test'))) { STOPPED.push(list[k].code); continue }
   out[k] = await runItem(list[k], offset + k, laneOf ? laneOf(w) : null).catch((e) => ({ code: list[k].code, error: String(e) }))
  }
  // app lane done: return the lease (phone shuts down unless someone waits)
  const L = laneOf ? laneOf(w) : null
  if (L && L.name) {
   await agent(`STEP: run exactly this in PowerShell and report its output, nothing else: & ${SWARM}/swarm.ps1 release -Agent ${LEASE(L)}`,
    { label: `release:${L.name}`, phase: 'Close', agentType: 'checky', model: 'haiku', effort: 'low' }).catch(() => null)
   log(`lane ${L.name} (${L.serial}) released`)
  }
 }
 await Promise.all(Array.from({ length: Math.max(1, Math.min(size, list.length)) }, (_, w) => worker(w)))
 return out
}

// BUDGET (README "Configuration" budget): cap = the plan's budgets; over it -> refused + split; at stopAt no new item, rest -> next
const BATCH = R.batch > 0 && R.items.length > R.batch ? R.batch : 0
const LATER = BATCH ? R.items.slice(BATCH).map((it) => it.code) : [], STOPPED = []
if (BATCH) R = { ...R, items: R.items.slice(0, BATCH) }
const BUD = { cap: 0, estimate: 0, stopAt: 0.8, spent: 0, guess: 0, stop: false, unit: 0 }
const PLAN = [...R.items.map((it) => `checky/${modelFor(it).model || ''}:1,checky/${MODELS.verify}:1,step/${MODELS.close}:1,item:1`), `step/haiku:3,kitty/${MODELS.learn}:1`].join(',')
try { Object.assign(BUD, JSON.parse((/BUDGET (\{.*\})/.exec(await recordArgs(RUN0, R.runDir, 'Test', PLAN)) || [])[1])); BUD.unit = BUD.estimate / R.items.length } catch (e) { log('WARNING: no BUDGET line from launch -Self: this run is not budget-gated') }
const nextCall = (only, extra) => ({ scriptPath: `${KIT}/workflows/testy.js`, args: { runDir: R.runDir, kitDir: K0, ...(only && { only }), ...(ARGS0.lanes && { lanes: ARGS0.lanes }), ...(ARGS0.instance && { instance: ARGS0.instance }), ...extra } })
if (BUD.cap && BUD.estimate > BUD.stopAt * BUD.cap) {
 const batch = Math.max(1, Math.floor(R.items.length * BUD.stopAt * BUD.cap / BUD.estimate))
 log(`REFUSED: estimate ${BUD.estimate} > ${BUD.stopAt * 100}% of the cap ${BUD.cap}: test ${batch} item(s) per run (args.batch)`)
 return { refused: true, estimate: BUD.estimate, cap: BUD.cap, batch, next: nextCall(ARGS0.only, { batch }) }
}
async function gate(phaseName) {   // before a new item; measures only near the stop line
 if (BUD.stop || !BUD.cap) return !BUD.stop
 BUD.guess += BUD.unit
 if (BUD.spent + BUD.guess < 0.6 * BUD.stopAt * BUD.cap) return true
 BUD.m = BUD.m || agent(`STEP: run exactly this in PowerShell and return ok=true with its output line:${PATHS}\n& ${ORCH} budget -Run '${RUN0}' -Json`,
  { label: 'budget', phase: phaseName, schema: FINAL_SCHEMA, agentType: 'checky', model: 'haiku', effort: 'low' }).catch(() => null).then((r) => { try { BUD.spent = JSON.parse(r.output).spent; BUD.guess = 0 } catch (e) {} BUD.m = null })
 await BUD.m
 if (BUD.spent >= BUD.stopAt * BUD.cap && !BUD.stop) { BUD.stop = true; log(`BUDGET: spent ${BUD.spent} of the cap ${BUD.cap}: running items finish, no new one starts; the rest -> next`) }
 return !BUD.stop
}
const web = R.items.filter((it) => (it.lane || 'web') === 'web')
const api = R.items.filter((it) => it.lane === 'api')
const app = R.items.filter((it) => it.lane === 'app')
if (app.length && !LANES.length && !NODEV) throw new Error('app items need args.lanes (one per lane + its login; agents lease and boot them) or devices: none')
log(`verify ${VERIFY ? 'on' : 'off'}, learn ${LEARN}`)
log(`run ${R.runDir}: web ${web.length} (x${R.webParallel || 5}), api ${api.length} (x${R.apiParallel || 5}), app ${app.length} (${LANES.length} phones)`)

const parts = await Promise.all([
 web.length ? pool(web, R.webParallel || 5, 0) : [],
 api.length ? pool(api, R.apiParallel || 5, 100) : [],
 app.length && !NODEV ? pool(app, LANES.length, 200, laneFor) : [],
])
const all = parts.flat().filter(Boolean)
if (NODEV && app.length) log(`NOT_TESTED (devices none; tasks stay open): ${app.map((it) => it.code).join(', ')}`)

// App follow-ups: PENDING web/api checks -> app item <code>A, in run.json first (finalize reads it)
for (const r of LANES.length ? [] : all.filter((x) => x.pending && x.pending.length)) log(`${r.code}: PENDING ${r.pending.join(', ')} need a device lane, args.lanes is empty: the task stays open (add lanes, qa.ps1 retest)`)
const followUps = LANES.length ? all.filter((r) => r.pending && r.pending.length).map((r) => {
 const it = R.items.find((x) => x.code === r.code)
 if (!it || it.lane === 'app' || R.items.some((x) => x.code === `${it.code}A`)) return null
 return { ...it, code: `${it.code}A`, title: `${it.title} — app checks ${r.pending.join(', ')}`, lane: 'app', only: r.pending,
  taskFiles: [...(it.taskFiles || []), `${outDir(it)}/results.json`],
  extra: `${it.extra || ''} The web/API pass (${it.code}) left ${r.pending.join(', ')} PENDING for a device: test exactly those on your phone. Earlier results: ${outDir(it)}/results.json.` }
}).filter(Boolean) : []
if (followUps.length) {
 await agent(`STEP: append these items to the "items" array of ${R.runDir}/run.json without changing anything else, in PowerShell:
$f = '${R.runDir}/run.json'; $j = Get-Content $f -Raw | ConvertFrom-Json; $new = '${JSON.stringify(followUps).replace(/'/g, "''")}' | ConvertFrom-Json
foreach ($n in $new) { if (-not ($j.items | Where-Object code -eq $n.code)) { $j.items += $n } }
[IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 20))
Then return ok=true and the list of item codes now in the file.`, { label: 'add-followups', phase: 'Test', schema: FINAL_SCHEMA, agentType: 'checky', model: 'haiku', effort: 'low' })
 log(`app follow-ups for PENDING checks: ${followUps.map((f) => `${f.code} (${f.only.join(', ')})`).join('; ')}`)
 all.push(...(await pool(followUps, LANES.length, 300, laneFor)).filter(Boolean))
}
log('DONE: ' + all.map((r) => r.summary || (r.skipped ? `${r.code}: skipped (other worker)` : `${r.code}: ${r.error}`)).join(' | '))

// LEARN 'auto': only after something eventful; a clean run gets the cleanup
phase('Learn')
// every finished run ends with a retro (orchestrate E10)
const retroDue = (results) => { log('RETRO DUE: run /tidy (orchestrate E10) once no other workflow of this session runs'); return { results, unpublished: results.filter((r) => r.unpublished || r.error).map((r) => r.code), envFixOpen: results.filter((r) => r.envFixOpen).map((r) => r.code), retroDue: true,
 budget: { cap: BUD.cap, estimate: BUD.estimate, spent: BUD.spent, stopped: BUD.stop }, ...(STOPPED.length + LATER.length ? { next: nextCall([...STOPPED, ...LATER]) } : {}) } }
const eventful = all.some((r) => r.error || r.eventful)
if (LEARN === false || (LEARN === 'auto' && !eventful)) {
 await agent(`STEP: run exactly this in PowerShell and report its last output line, nothing else:${PATHS}
& ${ORCH} cleanup -Quiet`, { label: 'cleanup', phase: 'Learn', agentType: 'kitty', model: 'haiku', effort: 'low' })
 log(`learn: skipped (${LEARN === false ? 'learn: false' : 'auto: clean run'}); cleanup ran`)
 return retroDue(all)
}
// signals only: /tidy (run after every finished run) turns them into lessons
const learned = await agent(`Kind retro (learn step): record this /testy run's signals.${PATHS}
Outcome (JSON):
${JSON.stringify(all).slice(0, 60000)}

1. One signal per notable event (failures, retries, budget stops / handoffs, NOT_TESTED causes, audit reclassifications / not-exercised splits, verify "not reproduced" or "inconclusive", anything that
 cost time or worked unusually well):
 & ${ORCH} learn -Skill <qa-kit|other skill> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. & ${ORCH} cleanup -Quiet (only kit-created leftovers), then Get-Content ${rp('cleanup-log')} -Tail 15: mention what was freed.
Return how many signals you recorded.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, agentType: 'kitty', ...pick('learn'), effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s)`)
return retroDue(all)
