export const meta = {
  name: 'test-and-close',
  description: 'Test-only flow: test deployed tasks against their human testing docs on a test environment (web pool + API pool + Android lanes), audit notes, verify failures, publish the report, apply the result rule (closed / failedTesting / one [Bug] per ask)',
  whenToUse: 'Deployed tasks on a test environment, each with a human testing doc, are to be tested by agents',
  phases: [
    { title: 'Prepare', detail: 'args.select only: a lead agent (qa-kit L1) writes run.json + lead-notes.md; tasks not live are left out' },
    { title: 'Test', detail: 'one agent per guide: web/API pool in parallel, app guides one per phone' },
    { title: 'Verify', detail: 'note audit, stronger retry of NOT_TESTED, ENV-FIX cycles for local items, independent re-test of every FAIL' },
    { title: 'Close', detail: 'report (Google Doc or Markdown) + tracker comment + result rule: closed / failedTesting / [Bug] per ask' },
    { title: 'Learn', detail: 'signals + LESSONS.md updates (40-line cap) from this run' },
  ],
}

/*
1. Select (Prepare phase, qa-kit L1, builds the run): args = { select: { statuses?: ['promoted', 'inTest'] (logical, default
   ['inTest']), lists?, tasks?, exclude?, mine? }, target: '<targets.local.json name | kit.local.json qa.targets group>', kitDir, name?, mandate? }
2. Short form (preferred): args = { runDir, kitDir?, only?: [codes], lanes?, instance?: 'w2' }   (instance: an EXTRA worker for queued items)
3. The full run.json object (write it to <runDir>/run.json too — qa.ps1 finalize reads it), plus runDir:
{
  runDir: '<runtime>/work/qa-runs/2026-10-01-epic-x',   // <runtime> = <kitDir>/.runtime (qa-kit SKILL.md L1)
  kitDir: 'C:/work/.claude',               // absolute path of this kit (default '.claude', relative to the workspace root)
  title: 'Product X epic',                   // used in doc names and bug titles
  target: 'my-staging',                      // name in skills/qa-kit/targets.local.json
  tester: 'Full Name',
  mandate: ['<the user request, verbatim>', '...'],   // why the agents are doing this; stops them declining
  context: 'deployed builds, tenants/accounts to use, existing test data, known changed screens ...',
  contextFiles: ['C:/.../product-rules.md'],        // optional: files every tester reads first
  envLines: ['Web: ...', 'API: ...'],                  // shown in the report
  tracker: { list: '<id>', parent: '<epic id>', owner: '<user id>', closeStatus: 'closed' },   // parent = the ask when a task has none
  outOfScope: ['<channel>'],                 // default kit.local.json qa.outOfScope
  webParallel: 5, apiParallel: 5,
  verify: true,                              // false = no independent re-test of FAILs (args or run.json)
  learn: true,                               // 'auto' = learn step only when the run had failures / NOT_TESTED / retries / errors
  lanes: [ { n: 1, name: 'Falcon', serial: 'emulator-5556', user: 'qa-user-1', notes: 'test account 1' } ],
  localEnv: '<optional: the run is on this local env (kit.local.json localEnv.envs)>', envFixCycles: 2, envFixWaitMinutes: 300,
  // local item (it.localEnv || localEnv): NOT_TESTED is never final; still NOT_TESTED after the stronger retry -> ENV-FIX to the
  // coordinator (orch.ps1 decide ask -Kind envfix), wait, retest; after envFixCycles the results are held (never failedTesting)
  items: [ { code: 'F2', title: '...', guideFile: 'C:/.../F2.txt', lane: 'web'|'api'|'app', target: '<optional: the env of this item, default run.json target>', localEnv: '<optional>',
             subtasks: [ { id: '<task id>', name: '...', mrs: '!12, !34' } ],
             retest: false, only: ['L3','L4'], skipClose: false, alsoWeb: false, extra: '...', taskFiles: [],
             model: 'sonnet'|'opus'|'haiku', effort: 'low'|'medium'|'high',     // optional, the TEST step; default: retests on web/api -> sonnet
             verifyModel: 'opus' } ],                                           // optional, the VERIFY step (default models.verify)
  models: { verify: 'sonnet', audit: 'sonnet', close: 'haiku', hold: 'haiku', learn: 'haiku', retest: 'opus', retestEffort: 'high' },   // '' = session default (retest '' = off)
  // skipClose: test + verify only, the lead publishes (qa.ps1 finalize -Code); items sharing a task do not need it
}
*/
// kit paths by name: the same names and values as skills/dev-kit/paths.json (kit-lint RUNTIME-MAP keeps them equal)
const KP = {"runtime": {"cleanup-log": "logs/cleanup.log", "launches": "work/launches/", "qa-runs": "work/qa-runs/"}, "durable": {"tracking": "tracking.json"}}
let ARGS0 = args || {}   // recorded for a resume (recordArgs)
let R = ARGS0
// PREPARE (args.select, no runDir): one lead agent builds the run (qa-kit L1), then the short form
if (R.select && !R.runDir && !Array.isArray(R.items)) {
  phase('Prepare')
  const { select: S, name: N, target: T, ...rest } = R   // T may be a group name, never an env: run.json holds the real target(s)
  if (!T) throw new Error('args.select needs args.target (a targets.local.json name or a qa.targets group)')
  const K0 = (R.kitDir || '.claude').replace(/[\\/]+$/, '')
  const statuses = [].concat(S.statuses && S.statuses.length ? S.statuses : ['inTest'])
  const job = { runFolder: `${(R.runtimeDir || `${K0}/.runtime`).replace(/[\\/]+$/, '')}/${KP.runtime['qa-runs']}<yyyy-MM-dd>-${String(N || `${T}-${statuses.join('-')}`).replace(/[^\w.-]+/g, '-').toLowerCase()}`,
    statuses, lists: S.lists || [], tasks: S.tasks || [], exclude: S.exclude || [], mine: !!S.mine, target: T, kitDir: K0, tracking: `${K0}/.state/${KP.durable.tracking}`, runSettings: rest }
  const prep = await agent(`You are the QA lead: build a test-only run, test nothing. PowerShell = pwsh 7 (the PowerShell tool); Python -X utf8.
Follow ${K0}/skills/qa-kit/SKILL.md "Lead steps" L1 (selection) with this job (JSON): ${JSON.stringify(job)}
Return runDir (absolute, forward slashes), items (count in run.json), left [{ id, reason }] and a one-line summary.`,
    { label: 'prepare', phase: 'Prepare', schema: { type: 'object', properties: { runDir: { type: 'string' }, items: { type: 'number' },
      left: { type: 'array', items: { type: 'object' } },
      summary: { type: 'string' } }, required: ['runDir', 'items', 'left', 'summary'] } })
  if (!prep || !prep.runDir) throw new Error('Prepare returned no runDir: build the run by hand (qa-kit L1), launch with { runDir }')
  for (const l of prep.left || []) log(`left out ${l.id}: ${l.reason}`)
  log(`prepared ${prep.runDir}: ${prep.items} item(s), ${(prep.left || []).length} left out (${prep.summary})`)
  if (!prep.items) return { prepared: prep.runDir, left: prep.left || [], results: [], next: 'nothing live to test (see left)' }
  ARGS0 = R = { ...rest, runDir: prep.runDir }   // recorded for a resume: reuses the prepared run instead of preparing again
}
if (R.runDir && !Array.isArray(R.items)) {
  // a small model once returned run.json truncated: validate, retry once on a stronger model
  const loadRun = async (model, label) => {
    const got = await agent(`Read the file ${R.runDir}/run.json with the Read tool and return its complete content, byte for byte unchanged (no summarising, no trimming, every item), as the string field "json". Do nothing else.`,
      { label, phase: 'Test', schema: { type: 'object', properties: { json: { type: 'string' } }, required: ['json'] }, model, effort: 'low' })
    try { const f = JSON.parse((got && got.json) || ''); return Array.isArray(f.items) && f.items.length ? f : null } catch (e) { return null }
  }
  const file = (await loadRun('haiku', 'load-run')) || (await loadRun('sonnet', 'load-run-retry'))
  if (!file) throw new Error(`could not read a valid ${R.runDir}/run.json (items[] missing after retry) - pass the full run.json object as args instead`)
  R = { ...file, ...R, items: file.items, lanes: R.lanes || file.lanes }
}
if (R.only && R.only.length) R = { ...R, items: R.items.filter((it) => R.only.includes(it.code)) }
// run-level skipClose holds every item (once read per item only, so it was silently ignored)
if (R.skipClose) R = { ...R, items: R.items.map((it) => ({ ...it, skipClose: true })) }
if (!R.mandate || !R.mandate.length) log('WARNING: no mandate (the task owner words) in args or run.json: testers may decline or drift')
const KIT = (R.kitDir || '.claude').replace(/[\\/]+$/, '')     // the .claude folder of the workspace
const ABS = /^([A-Za-z]:|[\\/])/.test(KIT)
const PATHS = (ABS ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
  '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const QA = `${KIT}/skills/qa-kit`                 // SKILL.md = QA rules, targets.local.json = environments
const Q = `${QA}/qa.ps1`
const SWARM = `${KIT}/skills/android-swarm`
const ORCH = `${KIT}/skills/orchestrate/orch.ps1`
const RT = (R.runtimeDir || `${KIT}/.runtime`).replace(/[\\/]+$/, '')
const rp = (n) => (n in KP.durable ? `${KIT}/.state/${KP.durable[n]}` : `${RT}/${KP.runtime[n]}`).replace(/\/$/, '')
// ES module imports need a file:// URL of the absolute path
const BROWSER = ABS ? 'file:///' + `${KIT}/skills/qa-kit/browser.mjs`.replace(/\\/g, '/').replace(/^\/+/, '')
  : `<file:/// URL of the absolute path of ${KIT}/skills/qa-kit/browser.mjs>`
if (!R.runDir || !Array.isArray(R.items) || !R.items.length) throw new Error('args.runDir and items are required: args.items[], a <runDir>/run.json or args.select (header)')
const outDir = (it) => `${R.runDir}/${it.code}`
const LANES = R.lanes || []
const OWNER = R.instance || 'w1'
const VERIFY = R.verify !== false
const LEARN = R.learn === undefined ? true : R.learn
// local env items: we own data, config, services: NOT_TESTED is never final (ENV-FIX cycles, bounded; then the coordinator decides)
const LOCALENV = (it) => (it && it.localEnv) || R.localEnv || ''
const ENV_FIX_CYCLES = Number.isFinite(R.envFixCycles) ? R.envFixCycles : 2
const ENV_FIX_TRIES = Math.max(1, Math.ceil((Number.isFinite(R.envFixWaitMinutes) ? R.envFixWaitMinutes : 300) / 9))   // 9 min slices: the tool timeout is 10
const RUNNAME = String(R.runDir).split(/[\\/]/).filter(Boolean).pop() || 'qa-run'
// Memory seat + item claim (qa.ps1 seat): the run's webParallel/apiParallel are only caps; real concurrency follows free memory.
function seatBlock(it, label) {
  const kind = it.lane === 'api' ? 'api' : it.lane === 'app' ? 'app' : 'web'
  return `
AGENT NAME: start every shell command with  $env:CLAUDE_AGENT='${label}'; $env:KIT_QA_TARGETS='${[tgt(it), ...[].concat(R.alsoTargets || [])].filter(Boolean).join(',')}';  (Bash: export the same) - qa.ps1 api refuses other targets; the build/memory
gate queues your work under this owner name (shell state does not persist between commands).
SEAT (memory + item claim) - your FIRST command, before anything else:
  & ${Q} seat acquire -Agent "${label}" -Kind ${kind} -RunDir "${R.runDir}" -Code ${it.code} -Owner ${OWNER}
  exit 0 = go. exit 2 = still waiting for memory: run the SAME command again until it returns 0 (other agents are finishing).
  exit 3 / "ALREADY" = another worker owns or finished this item: stop immediately and return { code: "${it.code}", skipped: true, checks: [] }.
  Your LAST command before returning (also on errors): & ${Q} seat release -Agent "${label}"`
}
// Model by stage (R.models overrides): verify + audit = sonnet; close, hold, release, follow-ups, learn = haiku.
const MODELS = { verify: 'sonnet', audit: 'sonnet', close: 'haiku', hold: 'haiku', learn: 'haiku', retest: 'opus', retestEffort: 'high', ...(R.models || {}) }
const pick = (stage) => (MODELS[stage] ? { model: MODELS[stage] } : {})
// TEST step: it.model / it.effort win; a web/API retest -> sonnet; first-time guides and app lanes keep the default model
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
          defect: { type: 'string', enum: ['own', 'new'], description: 'FAIL only: own = this task\'s expected behaviour failed (the task goes to failedTesting and back to its developer); new = a defect outside what the task changed (a regression, found on the way; X checks) - it becomes the ask\'s [Bug] task' },
          cause: { type: 'string', enum: ['no-mail-sandbox', 'phone-only', 'undeployed', 'env-data', 'tool-down'], description: 'NOT_TESTED only: why' },
          env_fix: { type: 'string', description: 'local env only, NOT_TESTED: the exact fix only the coordinator may do (refresh, up, drop, shared DB repair)' },
          what_was_done: { type: 'string' },
          observed: { type: 'string', description: 'what you saw; for FAIL the failing call (method, URL, status, body excerpt) or message' },
          evidence: { type: 'array', items: { type: 'string' }, description: 'file names (not paths) that exist in shots/ or evidence/' },
          attempts: { type: 'integer', description: 'how many times you ran this check (1 for a single run; LLM-driven / timing checks: 5+)' },
          window: { type: 'string', description: 'when it ran, as conditions + UTC times: e.g. "first 5 min after a restart, 14:02-14:10 UTC", "after 2 h idle"' },
        },
        required: ['id', 'subtask_id', 'screen', 'result', 'what_was_done', 'observed', 'evidence', 'attempts'],
      },
    },
    findings: { type: 'array', items: { type: 'string' } },
    setup_changes: { type: 'array', items: { type: 'string' } },
    data_created: { type: 'array', items: { type: 'string' } },
  },
  required: ['code', 'checks', 'findings', 'setup_changes', 'data_created'],
}
const VERIFY_SCHEMA = {
  type: 'object',
  properties: { verdicts: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' },
    outcome: { type: 'string', enum: ['confirmed', 'refuted', 'inconclusive'], description: 'confirmed = the defect is real; refuted = not reproduced UNDER the first tester\'s conditions (same login/session type, time window, at least as many attempts); inconclusive = those conditions could not be recreated' },
    confirmed: { type: 'boolean', description: 'false ONLY when outcome is refuted (older readers use this field)' },
    attempts: { type: 'integer', description: 'how many times you ran the check' },
    observed: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } },
    basis: { type: 'string', description: 'what the verdict rests on: the _verify evidence files you saved, the server log / observability window you read (UTC), or the code path (file:line) that explains the behaviour; none when there is nothing' } },
    required: ['id', 'outcome', 'confirmed', 'attempts', 'observed', 'evidence', 'basis'] } } },
  required: ['verdicts'],
}
const AUDIT_SCHEMA = {
  type: 'object',
  properties: {
    reclassify: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, defect: { type: 'boolean' },
      notExercised: { type: 'boolean', description: 'true when part of the check\'s Expected was never exercised (not a defect, not a pass)' },
      unreachable: { type: 'boolean', description: 'with notExercised: the screen/endpoint that part needs is missing or unreachable (-> FAIL)' },
      own: { type: 'boolean', description: 'with defect: true = the task\'s own expected behaviour, false = a new defect outside it' },
      part: { type: 'string', description: 'with notExercised: the part of Expected that was not exercised' },
      reason: { type: 'string' } }, required: ['id', 'defect', 'reason'] } },
    newDefects: { type: 'array', items: { type: 'object', properties: { screen: { type: 'string' }, what_was_done: { type: 'string' }, observed: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } } }, required: ['screen', 'what_was_done', 'observed', 'evidence'] } },
  },
  required: ['reclassify', 'newDefects'],
}
const LEARN_SCHEMA = { type: 'object', properties: { signals: { type: 'number' }, lessonsChanged: { type: 'array', items: { type: 'string' } } }, required: ['signals', 'lessonsChanged'] }
const FINAL_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' }, output: { type: 'string' } }, required: ['ok', 'output'] }
// Crash recovery: the FULL args go to the launch record (orch.ps1 launch -Self, FNV-1a checked): a resume needs them byte-exact
const fnv = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0 } return h.toString(16).padStart(8, '0') }
async function recordArgs(wf, run, a, phaseName) {
  const json = JSON.stringify(a)
  const file = `${rp('launches')}/args-${wf}-${run.replace(/[^\w.-]/g, '_')}.json`
  const prompt = `Record this workflow's launch args (crash recovery). Do exactly this, nothing else:${PATHS}
1. Write the line between the markers to ${file} with the Write tool, byte for byte (one line of JSON; no markers, nothing added):
<<<ARGS
${json}
ARGS>>>
2. Run in PowerShell: & ${ORCH} launch -Self -Script ${wf}.js -Run '${run}' -ArgsFile '${file}' -Fnv ${fnv(json)}
Return ok=true when it prints RECORDED, else ok=false with its output (MISMATCH = the file differs: write it again once, re-run).`
  for (const [label, model] of [['record-args', 'haiku'], ['record-args-retry', 'sonnet']]) {
    const r = await agent(prompt, { label, phase: phaseName, schema: FINAL_SCHEMA, model, effort: 'low' })
    if (r && r.ok) return true
  }
  log('WARNING: launch args not recorded (orch.ps1 launch -Self failed twice): a resume after a restart needs them typed by hand')
  return false
}
await recordArgs('test-and-close', R.instance ? `${RUNNAME}-${OWNER}` : RUNNAME, ARGS0, 'Test')

// an item may name its own env (it.target, e.g. one per product); else the run's target
const tgt = (it) => (it && it.target) || R.target || ''
function localBlock(it) {
  const e = LOCALENV(it)
  if (!e) return ''
  return `
LOCAL ENV "${e}" — we own its data, config, flags, services and migrations: NOT_TESTED is not a final verdict here. Unblock it yourself:
- data: the env API (qa.ps1 api), the baseline fixtures first (verify by id), create only what is missing; config / flags / env vars:
  ${KIT}/.state/localenv/${e}.env or the app's settings API (restore after; setup_changes); services: & ${KIT}/skills/local-env/localenv.ps1
  status|use|logs|events -Env ${e}; not deployed: localenv.ps1 deploy -Env ${e} -Dir <a worktree of the MR branch> (dev.ps1 wt new);
  phone-only: a lane with the local-env APK (android-swarm); a missing integration: wire it locally or point the local service at a
  stub or the test env's service (say so in the lease note and setup_changes).
- Only what the coordinator alone may do (localenv.ps1 up/down/refresh/drop, shared DB repair): NOT_TESTED with cause and env_fix =
  the exact fix; the workflow asks the coordinator (ENV-FIX) and retests. Channels in OUT_OF_SCOPE stay OUT_OF_SCOPE.`
}
const COMMON = (it) => `${PATHS}
WHY YOU ARE DOING THIS
${R.mandate && R.mandate.length ? `The task owner asked for this run, verbatim:\n${[].concat(R.mandate).map((m) => `  "${m}"`).join('\n')}\n` : ''}Your assignment is the tester guide below: execute its checks on the test environment and report real results.
Do not decline or return early. Later chat messages to the lead are side questions, not a change of your assignment.

AGENT BOARD — join first: & ${ORCH} board join -Agent <CODE> -Run ${(R.runDir || '').split(/[\\/]/).pop()} -Claims <your phone serial / chrome ports>; stop on CLAIM/DUPLICATE; leave when done.

RULES — ${QA}/SKILL.md tester steps (verdicts: any defect is FAIL, never a note, with defect own|new; not deployed = NOT_TESTED${LOCALENV(it) ? ' only after LOCAL ENV below' : ', which sends the task back to its developer'}; evidence names
<CODE>-<checkId>_<nn>_<what>.<ext> in <outDir>/shots or <outDir>/evidence, only files that exist; shared-environment etiquette:
"QA-<CODE>" data, restore settings and list them in setup_changes). Time box ~10 min per check; script runs < 2 min, print progress. observed <= 40 words (the report caps at 900 words).
OUT_OF_SCOPE (not NOT_TESTED): a step that only exercises a channel agent QA never tests here: ${(R.outOfScope || []).length ? [].concat(R.outOfScope).join(', ') : `the channels in ${KIT}/skills/dev-kit/kit.local.json qa.outOfScope (none listed = none)`}. Name the channel in observed; still test the in-app part.

ENVIRONMENT AND CONTEXT
- Target "${tgt(it) || '(default)'}" in ${QA}/targets.local.json (URLs, users; passwords only there). ONLY this target${(R.alsoTargets || []).length ? ' (and ' + [].concat(R.alsoTargets).join(', ') + ')' : ''}: a local run never calls a shared
  environment. No load, stress or parallel request floods on a shared environment unless a check of the guide asks for it.
${R.context || ''}
${(R.contextFiles || []).length ? `- Read these first: ${R.contextFiles.join(' , ')}` : ''}${localBlock(it)}
- LEAD NOTES: ${R.runDir}/lead-notes.md (may not exist yet). The lead answers your questions there (logins, tenants, scope) -
  you cannot be messaged directly. Re-read it before each check and whenever you are blocked; if you asked the lead something,
  continue with other checks and look there again before marking anything NOT_TESTED for that reason.

TOOLS (details: SKILL.md step 3)
- API: & '${Q}' api -Target ${tgt(it) || '<target>'} -As <user> [-Tenant <t>] -Method <M> -Path '/...' [-Body '<json>'] [-Save <name> -OutDir <dir>]
- Code: read the CURRENT code on the deployed branch; a step a later change made obsolete -> test the same intent, PASS_WITH_NOTE.
- Tracker: & '${KIT}/skills/dev-kit/dev.ps1' tracker view|comments <id> (never a tracker CLI directly).`

const WEB = (ports, it) => `
BROWSER (web)
- Your own headless Chrome via ${QA}/browser.mjs (read its header); no chrome-devtools MCP, no emulators/adb. Scripts in <outDir>/scripts:
  import { session, go, text, clickText, clickSel, hoverSel, setInput, shot, mark, saveNet, settle, token, killSession } from '${BROWSER}'
  const s = await session({ port, target: '${tgt(it)}', tenant, as }) -> {page, net, done}; one port per tenant+user; end with await s.done().
  s.net.failed = 4xx/5xx calls + JS errors (failure evidence).
- Your Chrome ports: ${ports}; at most 2 open at once; killSession() each when you finish.`

// Lease id per worker instance: two workers on one lane must not share a lease (both drove the phone); distinct ids queue
const LEASE = (L) => `qa-${OWNER}-${L.name}`
// Extra workers start on another lane (w2 -> lane 2 ...)
const LANE_OFFSET = Math.max(0, (parseInt(String(OWNER).replace(/\D/g, ''), 10) || 1) - 1)
const laneFor = (w) => LANES[(w + LANE_OFFSET) % LANES.length]
function appBlock(L) {
  return `
ANDROID APP — YOUR PHONE: lane ${L.n} "${L.name}", adb serial ${L.serial}${L.user ? `, test login ${L.user}` : ''}. ${L.notes || ''}
Your phone is leased (rules: ${SWARM}/SKILL.md steps A1-A4):
- FIRST: & ${SWARM}/swarm.ps1 acquire -Agent ${LEASE(L)} -Lane ${L.name}   (waits its turn, boots, installs the current APK; "installed: updated" = log in again)
- START EVERY PowerShell command with  $env:ANDROID_SERIAL='${L.serial}';  — never other serials, swarm-up/down/app-mode, adb kill-server,
  or killing emulators/processes you didn't start.
- UI: & ${Q} ui (dump | tap | tapid | tapxy | type | key | swipe | shot | shotmark | wait | log); shots into <outDir>/shots with the
  <CODE>-<checkId>_ prefix. Relaunch/clear: & ${SWARM}/swarm.ps1 launch -Serial ${L.serial} [-Clear]
- Before > 10 min of non-phone work: & ${SWARM}/swarm.ps1 release -Agent ${LEASE(L)}; acquire again when needed (app stays installed).
  The workflow releases it after the lane's last item.
- Data prefix "QA-L${L.n}-<CODE>". No environment-wide setting changes from an app lane: prove those via the API (PASS_WITH_NOTE).`
}
const API = `
API-ONLY LANE
- No browser, no emulator: test through qa.ps1 api (and read-only DB access if available). Save request/response evidence for every check.`

function laneBlock(it, ports, L) {
  if (it.lane === 'app') return appBlock(L) + (it.alsoWeb ? WEB(ports, it) + '\nThis package also has web/API checks: test those with the browser helper too.' : '')
  if (it.lane === 'api') return API
  return WEB(ports, it)
}

function testPrompt(it, ports, L) {
  return `You are a QA tester. Test ONE tester guide on the test environment and return a verdict per check.

GUIDE: ${it.title}
Guide text (read it fully first): ${it.guideFile}
Package code: ${it.code}. Output folder: ${outDir(it)} (create shots/, evidence/, scripts/). Reuse valid evidence already there.
Tasks covered (tag each check with its task id):
${(it.subtasks || []).map((s) => `  - ${s.id}: ${s.name}${s.mrs ? `  (MRs: ${s.mrs})` : ''}`).join('\n')}
${it.retest ? 'This is a RETEST of a fix: re-run the failed checks named in the task plus a short regression around them.' : ''}
${seatBlock(it, `test:${it.code}`)}
${COMMON(it)}
${laneBlock(it, ports, L)}
${(it.taskFiles || []).length ? 'Task details (fix description, how-to-test comments, earlier evidence): ' + it.taskFiles.join(' , ') : ''}
${it.extra || ''}
${it.only ? `SCOPE: test ONLY these checks: ${it.only.join(', ')}. Return only those.` : 'Work through ALL checks in the guide. Return every check with the guide\'s own numbers.'}
Return checks, findings, setup_changes and data_created.
For a check you ran more than once (LLM-driven / timing: 5+), set attempts and window (conditions + UTC times): a verifier must
recreate them before it may refute your FAIL.
LAST STEP before returning: write that same result as ${outDir(it)}/results.json (Write tool) and run
  & '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code} -Check -FixNames
  (publishes nothing; renames off-standard evidence to <CODE>-<checkId>_<nn>_<what> and rewrites results.json). Exit 1 = evidence
  named in results.json is missing, a name it could not fix, or duplicate check ids: save the file or drop the name, give each check
  its own id, and re-run until exit 0. Return the checks as results.json now has them (fixed names).

NON-NEGOTIABLE: there is no session time limit and nobody is waiting on you. "No time" or "not executed" are not valid NOT_TESTED reasons;
returning early with untested checks will be rejected and re-run.`
}

function auditPrompt(it, res) {
  const notes = res.checks.filter((c) => c.result === 'PASS_WITH_NOTE').map((c) => `- ${c.id} (${c.screen}): ${c.observed}`).join('\n')
  const finds = (res.findings || []).map((f, i) => `- F${i + 1}: ${f}`).join('\n')
  return `You are a strict QA note auditor. Testers sometimes hide real defects in notes; catch them. Package ${it.code} (${it.title}).
- PASS_WITH_NOTE is legitimate ONLY for (a) guide text out of date because later intended work changed the flow and the intent holds,
  or (b) a purely cosmetic difference while behaviour is correct.
- A DEFECT is: 5xx or unexpected 4xx; crash; stuck/blocking flow; data changed wrongly or not saved; wrong records affected; broken
  navigation; a missing screen the feature needs — whether or not it's in the guide's scope.
- NOT defects: test-data/setup notes, tester mistakes, intended product decisions, platform limits, config missing on the test environment,
  and guide-conditional checks (the guide itself says the step may not apply: "if the tenant has X", "conditional step") whose condition
  does not hold on the target - unless the condition being false is itself the defect.
- NOT EXERCISED (third class, neither defect nor pass): a part of the check's Expected the tester never exercised (a second theme not
  rendered, a timeout/error path not triggered, verified through the API only because the UI path was not reached). Return it with
  defect=false, notExercised=true, part=<that part>, and unreachable=true when the screen/endpoint that part needs is missing or
  unreachable. The workflow turns it into its own check (<id>n): NOT_TESTED, or FAIL when unreachable. Never leave it inside a note.
${R.tracker && R.tracker.parent ? `- Skip issues already tracked by an existing [Bug] task under ${R.tracker.parent} (& '${KIT}/skills/dev-kit/dev.ps1' tracker view ${R.tracker.parent} lists its subtasks).` : ''}
- Return {id, defect, reason, own} (own = true when the defect is in this task's expected behaviour; false = outside what the task changed) plus notExercised/part/unreachable when it applies, per note check; defects that sit only in findings -> newDefects (screen, what_was_done, observed with the exact
  failing call/message, evidence file names that exist in ${outDir(it)}/shots or evidence).
- You may read evidence, code, or call the API read-only (GET). Change nothing.

PASS_WITH_NOTE checks:
${notes || '(none)'}

Findings:
${finds || '(none)'}`
}

// Attempts a refutation needs: the first tester's own count; when it is missing on an intermittent-looking FAIL (timeout, 50x,
// cold start, stall, LLM-driven), 5, so one clean warm re-run comes out inconclusive instead of refuting it.
const INTERMITTENT = /time[d ]?out|took too long|\b50[234]\b|cold[- ]start|stall|intermittent|flak|busy|rate[- ]limit|LLM|assistant/i
function attemptsNeeded(c) {
  return Math.max(c.attempts || 1, INTERMITTENT.test(`${c.observed || ''} ${c.what_was_done || ''}`) ? 5 : 1)
}

function verifyPrompt(it, fails, ports, L) {
  return `Verify these FAILED checks from scratch (your agent definition: be skeptical of the first tester, confirm a real difference from Expected).

GUIDE: ${it.title}   Guide text: ${it.guideFile}
Package ${it.code}. Output folder ${outDir(it)}; name new evidence <CODE>-<checkId>_verify_<desc>.jpeg/.json.
Tasks and MRs: ${(it.subtasks || []).map((s) => `${s.id}${s.mrs ? ` (MRs: ${s.mrs})` : ''}`).join('; ')}

FAILED CHECKS:
${fails.map((c) => `- ${c.id} (${c.screen}) — first tester did: ${c.what_was_done}\n  saw: ${c.observed}\n  conditions of the first tester: ${c.attempts ? `${c.attempts} attempt(s)` : attemptsNeeded(c) > 1 ? `attempts not recorded on an intermittent-looking failure: run it ${attemptsNeeded(c)} times` : '1 attempt'}${c.window ? `, window: ${c.window}` : ', window: not recorded (read the evidence timestamps)'}`).join('\n')}
${seatBlock(it, `verify:${it.code}`)}
${COMMON(it)}
${laneBlock(it, ports, L)}
Return one verdict per check id, with attempts (how many times you ran it) and outcome:
- confirmed: the behaviour really differs from Expected (confirmed=true).
- refuted: not reproduced UNDER the first tester's conditions above (same login/session type, same time window - e.g. right after a
  restart, deploy or idle period - and at least as many attempts; one clean run never refutes a FAIL) (confirmed=false).
- inconclusive: you could not recreate those conditions; say which one in observed (confirmed=true: the FAIL stays).
Every verdict needs basis: the _verify evidence files you saved, the log window you read, or the code path (file:line). A refuted
verdict with no _verify evidence and no code basis is counted as inconclusive.`
}

function finalPrompt(it, res) {
  return `Publish the test results of package ${it.code}.${PATHS}
1. Write this JSON exactly as given to ${outDir(it)}/results.json (Write tool; change nothing):
${JSON.stringify(res)}
2. Run in PowerShell: & '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code} -Check -FixNames   (publishes nothing; renames
   off-standard evidence files and rewrites results.json to match). Exit 1 = evidence named in results.json is missing, a name it
   could not fix, or duplicate check ids: fix that data (step 3) and re-run it until exit 0.
   Then (timeout 600000): & '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code}
   It refuses to publish while evidence listed in results.json is missing. It publishes the report (Google Doc + Drive evidence, or report.md in the run folder - kit.local.json reports.type), comments on the
   tasks (dev.ps1 tracker) and applies the result rule: closed / failedTesting / one [Bug] per ask for new defects.
3. If it errors, fix only data problems in results.json (drop a missing evidence file name, suffix a duplicate check id; an off-standard
   file name: re-run -Check -FixNames) and run it once more. Don't edit qa.ps1.
Return ok=true/false and the script's output.`
}

const ntShare = (r) => (r && r.checks.length ? r.checks.filter((c) => c.result === 'NOT_TESTED').length / r.checks.length : 1)
const tag = (L) => (L ? '@' + L.name : '')

async function runItem(it, idx, L) {
  // pools at 0/100/200/300, % 400: own ports per pool; the worker instance shifts the base (w1 + w2 once shared 9600-9604)
  const inst = parseInt(String(R.instance || 'w0').replace(/\D/g, ''), 10) || 0
  const p = 9600 + ((inst * 40 + idx) % 400) * 10
  const ports = `${p}-${p + 4}`
  const vports = `${p + 5}-${p + 9}`
  const phase = 'Test'
  let retried = false
  let res = await agent(testPrompt(it, ports, L), { label: `test:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'qa-tester', ...modelFor(it) })
  if (res && res.skipped) { log(`${it.code}: skipped - another worker owns or finished it`); return { code: it.code, skipped: true } }
  if (!res || ntShare(res) > 0.25) {
    log(`${it.code}: ${res ? Math.round(ntShare(res) * 100) + '% NOT_TESTED' : 'no result'} — re-running`)
    const prior = res ? `\nA previous attempt left these NOT_TESTED — they MUST now be executed: ${res.checks.filter((c) => c.result === 'NOT_TESTED').map((c) => c.id).join(', ')}. Reuse its valid evidence.` : ''
    const again = await agent(testPrompt(it, vports, L) + prior, { label: `retest:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'qa-tester', ...modelFor(it) })
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
  // unique check ids before audit and verify (two checks sharing an id would share one verdict): repeats get a b, c, ... suffix
  const seenIds = new Set()
  for (const c of res.checks) {
    let id = String(c.id || 'check'), k = 1
    while (seenIds.has(id)) id = `${c.id || 'check'}${String.fromCharCode(97 + k++)}`
    if (id !== String(c.id || 'check')) c.guideId = String(c.id || 'check')
    c.id = id; seenIds.add(id)
  }

  // Note audit: real defects hidden in notes/findings become FAIL (own or new; new X checks) so they get verified and follow the result rule.
  if (res.checks.some((c) => c.result === 'PASS_WITH_NOTE') || (res.findings || []).length) {
    const a = await agent(auditPrompt(it, res), { label: `audit:${it.code}`, phase: 'Verify', schema: AUDIT_SCHEMA, agentType: 'qa-verifier', ...pick('audit') })
    for (const d of (a && a.reclassify) || []) {
      const c = res.checks.find((x) => x.id === d.id)
      if (c && d.defect && c.result === 'PASS_WITH_NOTE') { c.result = 'FAIL'; c.defect = d.own === false ? 'new' : 'own'; c.observed = `${c.observed} | Note audit: a defect, not a note: ${d.reason}` }
      else if (c && d.notExercised) {
        // NOT EXERCISED: the untested part of Expected becomes its own check <id>n (NOT_TESTED; FAIL when its screen/endpoint is unreachable)
        let nid = `${c.id}n`, k = 1
        while (res.checks.some((x) => x.id === nid)) nid = `${c.id}n${++k}`
        res.checks.push({ id: nid, subtask_id: c.subtask_id, screen: c.screen, result: d.unreachable ? 'FAIL' : 'NOT_TESTED', ...(d.unreachable ? { defect: 'own' } : { cause: 'env-data' }),
          what_was_done: `Split from ${c.id} by the note audit: this part of its Expected was never exercised: ${d.part || '(see reason)'}`,
          observed: `${d.unreachable ? 'The screen/endpoint this part needs was missing or unreachable' : 'Not exercised by the tester'}: ${d.reason} (raised by the note audit)`, evidence: [] })
        c.observed = `${c.observed} | Note audit: the unexercised part moved to ${nid}`
      }
    }
    // new audit checks continue after the highest X id already used (the guide's X1..Xn -> X(n+1))
    let n = Math.max(0, ...res.checks.map((c) => +((/^X(\d+)$/.exec(c.id) || [])[1] || 0)))
    for (const d of (a && a.newDefects) || []) {
      res.checks.push({ id: `X${++n}`, subtask_id: ((it.subtasks || [])[0] || {}).id || '', screen: d.screen, result: 'FAIL', defect: 'new', what_was_done: d.what_was_done, observed: `${d.observed} (raised by the note audit)`, evidence: d.evidence || [] })
    }
    if (a) log(`${it.code}: audit -> ${(a.reclassify || []).filter((d) => d.defect).length} note(s) reclassified, ${(a.reclassify || []).filter((d) => !d.defect && d.notExercised).length} not exercised, ${(a.newDefects || []).length} new defect(s)`)
  }

  // Stronger retry (owner rule): every check still NOT_TESTED gets ONE more attempt by a qa-tester on models.retest (default the
  // strongest, effort high), scoped to those checks, told what blocked the first attempt; only then does the result rule apply.
  const blocked = res.checks.filter((c) => c.result === 'NOT_TESTED')
  if (blocked.length && MODELS.retest) {
    log(`${it.code}: ${blocked.length} check(s) NOT_TESTED -> one retry on ${MODELS.retest} (${blocked.map((c) => c.id).join(', ')})`)
    const why = blocked.map((c) => `- ${c.id} (${c.screen}): blocked by ${c.cause || 'unknown'}: ${c.observed}`).join('\n')
    const r2 = await agent(testPrompt({ ...it, only: [...new Set(blocked.map((c) => c.guideId || c.id))] }, vports, L) +
      `\nSTRONGER RETRY: a first tester could not complete these checks. What blocked it:\n${why}\nWork around each blocker (other data, user, path, the API, the lead notes) and execute the check; NOT_TESTED again only when truly impossible, with the cause.`,
      { label: `retest-strong:${it.code}${tag(L)}`, phase: 'Verify', schema: CHECKS_SCHEMA, agentType: 'qa-tester', model: MODELS.retest, effort: MODELS.retestEffort || 'high' })
    for (const c2 of (r2 && !r2.skipped && r2.checks) || []) {
      const i = res.checks.findIndex((c) => (c.id === c2.id || c.guideId === c2.id) && c.result === 'NOT_TESTED')
      if (i < 0 || c2.result === 'NOT_TESTED') continue
      res.checks[i] = { ...c2, id: res.checks[i].id, observed: `${c2.observed} (stronger retry; first attempt: ${res.checks[i].observed})` }
    }
    retried = true
  }
  // ENV-FIX (local items): checks still NOT_TESTED -> the coordinator fixes the env (orch.ps1 decide ask -Kind envfix, orchestrate
  // E4), the workflow waits, then retests them; at most ENV_FIX_CYCLES, then the results are held for the coordinator (never failedTesting)
  let envFix = null
  for (let cyc = 1; LOCALENV(it) && cyc <= ENV_FIX_CYCLES; cyc++) {
    const open = res.checks.filter((c) => c.result === 'NOT_TESTED')
    if (!open.length) break
    const need = open.map((c) => `${c.id}: ${c.env_fix || c.cause || 'unknown'}: ${c.observed}`).join(' | ').slice(0, 1200).replace(/'/g, "''").replace(/[\r\n]+/g, ' ')
    const asked = await agent(`Run exactly this in PowerShell and return ok=true with the line it printed, nothing else:${PATHS}
& ${ORCH} decide ask -Kind envfix -Run '${RUNNAME}' -Agent 'qa-${it.code}' -Item '${it.code}' -Contracts '${R.runDir}/lead-notes.md' -Question 'Local env ${LOCALENV(it)}, item ${it.code}: fix so these checks can run: ${need}'`,
      { label: `envfix-ask:${it.code}`, phase: 'Verify', schema: FINAL_SCHEMA, model: 'haiku', effort: 'low' })
    const id = (/\b(e-\d{14}-[\w-]+)/.exec((asked && asked.output) || '') || [])[1]
    if (!id) { envFix = { cycles: cyc, state: 'not raised', output: asked ? asked.output : 'agent returned nothing' }; break }
    log(`${it.code}: ENV-FIX ${id} (cycle ${cyc}/${ENV_FIX_CYCLES}) -> the coordinator: ${open.map((c) => c.id).join(', ')}`)
    let ans = null
    for (let t = 0; t < ENV_FIX_TRIES && !ans; t++) {
      const w = await agent(`Run exactly this in PowerShell (tool timeout 600000) and return ok=true with its last line when it prints ANSWERED, else ok=false with its last line:${PATHS}
& ${ORCH} decide wait -Id ${id} -MaxMinutes 9`, { label: `envfix-wait:${it.code}`, phase: 'Verify', schema: FINAL_SCHEMA, model: 'haiku', effort: 'low' })
      if (w && w.ok) ans = w.output
    }
    envFix = { id, cycles: cyc, state: !ans ? 'no answer' : /:\s*cannot\b/i.test(ans) ? 'coordinator cannot' : 'fixed', answer: ans || '' }
    if (envFix.state !== 'fixed') break
    const r3 = await agent(testPrompt({ ...it, only: [...new Set(open.map((c) => c.guideId || c.id))] }, vports, L) +
      `\nENV FIX DONE: the coordinator fixed the local env for these checks (${id}): ${ans}\nExecute each check now; NOT_TESTED again only with cause and env_fix.`,
      { label: `envfix-retest:${it.code}${tag(L)}`, phase: 'Verify', schema: CHECKS_SCHEMA, agentType: 'qa-tester', ...(MODELS.retest ? { model: MODELS.retest, effort: MODELS.retestEffort || 'high' } : {}) })
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
    const v = await agent(verifyPrompt(it, fails, vports, L), { label: `verify:${it.code}${tag(L)}`, phase: 'Verify', schema: VERIFY_SCHEMA, agentType: 'qa-verifier', ...(it.verifyModel ? { model: it.verifyModel } : pick('verify')), ...(it.effort ? { effort: it.effort } : {}) })
    const byId = Object.fromEntries(((v && v.verdicts) || []).map((x) => [x.id, x]))
    for (const c of fails) {
      const x = byId[c.id]
      if (!x) { c.verify = 'not re-tested'; continue }
      let outcome = x.outcome || (x.confirmed ? 'confirmed' : 'refuted')
      // fewer attempts than the first tester never refutes an intermittent FAIL (LLM-driven / timing checks).
    // (no apostrophes inside nested template literals: kit-lint's string stripper loses track of them)
      // attempts missing on an intermittent-looking FAIL counts as 5 (attemptsNeeded), so one warm re-run is inconclusive.
      const need = attemptsNeeded(c)
      if (outcome === 'refuted' && need > 1 && (x.attempts || 1) < need) {
        outcome = 'inconclusive'
        x.observed = `${x.observed} (${x.attempts || 1} attempt(s) against ${c.attempts ? `${need} by the first tester` : `${need} needed for an intermittent failure`})`
      }
      // a refutation needs something to stand on: its own _verify evidence or a code / log basis (refutations without either were wrong)
      const basis = String(x.basis || '').trim()
      const verifyEv = (x.evidence || []).some((e) => /_verify[_.]/i.test(String(e)))
      const codeBasis = (/[\w-]+\.(java|kt|ts|tsx|js|mjs|py|cs|go|rb|php|sql|xml|html)(:\d+)?\b/i.test(basis) ||
        (/\blogs?\b|observability/i.test(basis) && /\b\d{1,2}:\d{2}/.test(basis))) && !/^none\b|\b(no|not|without|never)\b[^.;]{0,30}\b(logs?|code|file)\b/i.test(basis)
      if (outcome === 'refuted' && !verifyEv && !codeBasis) { outcome = 'inconclusive'; x.observed = `${x.observed} (no verify evidence or basis recorded)` }
      if (basis && !/^none\b/i.test(basis)) x.observed = `${x.observed} [basis: ${basis}]`
      c.evidence = [...c.evidence, ...(x.evidence || [])]
      if (outcome === 'confirmed') { c.verify = 'confirmed'; c.observed = `${c.observed} | Independent re-test confirmed: ${x.observed}` }
      else if (outcome === 'inconclusive') { c.verify = 'inconclusive'; c.observed = `${c.observed} | Re-test inconclusive (conditions not recreated): ${x.observed}` }
      else { c.verify = 'not reproduced'; c.result = 'PASS_WITH_NOTE'; c.observed = `First run reported a failure; an independent re-test under the same conditions did not reproduce it. Re-test: ${x.observed}. First run: ${c.observed}` }
    }
  }
  const n = (k) => res.checks.filter((c) => c.result === k).length
  const line =`${it.code}: pass ${n('PASS') + n('PASS_WITH_NOTE')}/${res.checks.length - n('OUT_OF_SCOPE')}, fail ${n('FAIL')}, not tested ${n('NOT_TESTED')}, out of scope ${n('OUT_OF_SCOPE')}, pending ${n('PENDING')}`
  const holdLocal = envFixOpen && !res.checks.some((c) => c.result === 'FAIL' && c.defect !== 'new')
  if (it.skipClose || holdLocal) {
    // verdicts stay on disk for the lead (qa.ps1 finalize -Code); held.json = finished for supervise and workers
    const why = holdLocal ? `local env: checks still NOT_TESTED after ENV-FIX (${envFix ? `${envFix.id || '-'} ${envFix.state}` : 'none raised'}): the coordinator decides (fix + qa.ps1 retest, or finalize -AcceptNotTested)` : 'publish left to the lead (skipClose)'
    await agent(`Write two files with the Write tool, content exactly as given, change nothing, run step 3, then return ok=true.
1. ${outDir(it)}/results.json:
${JSON.stringify(res)}
2. ${outDir(it)}/held.json:
${JSON.stringify({ code: it.code, held: why, envFix, summary: line, at: '<now>' })}
Replace <now> with the current UTC time (ISO 8601) when you write it (workflow scripts can't read the clock: Date.now()/new Date() throw).
3. Run in PowerShell: & '${Q}' finalize -RunDir '${R.runDir}' -Code ${it.code} -Check -FixNames   (publishes nothing; renames
   off-standard evidence files and rewrites results.json to match) and return its output. Exit 1 = evidence named in results.json is
   missing, a name it could not fix, or duplicate check ids: return ok=true anyway with that output (the lead fixes them before publishing).`,
      { label: `hold:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, ...pick('hold'), effort: 'low' })
    log(`${line} (results saved; ${holdLocal ? 'ENV-FIX unresolved: the coordinator decides' : 'publish left to the lead'})`)
    return { code: it.code, summary: line, result: res, eventful: true, envFix, envFixOpen: holdLocal, pending: res.checks.filter((c) => c.result === 'PENDING').map((c) => c.id) }
  }
  let fin = await agent(finalPrompt(it, res), { label: `close:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, ...pick('close'), effort: 'low' })
  if (!(fin && fin.ok)) fin = await agent(finalPrompt(it, res), { label: `close-retry:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, model: 'sonnet' })
  log(line + (fin && fin.ok ? '' : ' [NOT PUBLISHED - the coordinator runs qa.ps1 finalize for it (qa-kit L3)]'))
  const eventful = retried || n('FAIL') > 0 || n('NOT_TESTED') > 0 || res.checks.some((c) => /Note audit|not reproduce|inconclusive/.test(c.observed || '')) || !(fin && fin.ok)
  return { code: it.code, summary: line, finalize: fin, eventful, envFix, unpublished: !(fin && fin.ok), result: fin && fin.ok ? undefined : res, pending: res.checks.filter((c) => c.result === 'PENDING').map((c) => c.id) }
}

// Simple worker pools: web and API pools run in parallel; app guides run one per phone.
async function pool(list, size, offset, laneOf) {
  const out = []
  let next = 0
  const worker = async (w) => {
    while (next < list.length) {
      const k = next++
      out[k] = await runItem(list[k], offset + k, laneOf ? laneOf(w) : null).catch((e) => ({ code: list[k].code, error: String(e) }))
    }
    // App lane has nothing left to test: give its phone lease back now (the phone shuts down unless another agent waits for it)
    const L = laneOf ? laneOf(w) : null
    if (L && L.name) {
      await agent(`Run exactly this in PowerShell and report its output, nothing else: & ${SWARM}/swarm.ps1 release -Agent ${LEASE(L)}`,
        { label: `release:${L.name}`, phase: 'Close', model: 'haiku', effort: 'low' }).catch(() => null)
      log(`lane ${L.name} (${L.serial}) released`)
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, Math.min(size, list.length)) }, (_, w) => worker(w)))
  return out
}

const web = R.items.filter((it) => (it.lane || 'web') === 'web')
const api = R.items.filter((it) => it.lane === 'api')
const app = R.items.filter((it) => it.lane === 'app')
if (app.length && !LANES.length) throw new Error('app items need args.lanes (one per phone lane + its login); phones need not be running: agents lease and boot them (swarm.ps1 acquire)')
log(`verify ${VERIFY ? 'on' : 'off'}, learn ${LEARN}`)
log(`run ${R.runDir}: web ${web.length} (x${R.webParallel || 5}), api ${api.length} (x${R.apiParallel || 5}), app ${app.length} (${LANES.length} phones)`)

const parts = await Promise.all([
  web.length ? pool(web, R.webParallel || 5, 0) : [],
  api.length ? pool(api, R.apiParallel || 5, 100) : [],
  app.length ? pool(app, LANES.length, 200, laneFor) : [],
])
const all = parts.flat().filter(Boolean)

// App follow-ups: PENDING web/api checks get an app item <code>A on the phones now, appended to run.json first (finalize reads it)
for (const r of LANES.length ? [] : all.filter((x) => x.pending && x.pending.length)) log(`${r.code}: PENDING ${r.pending.join(', ')} need a phone lane, but args.lanes is empty: the task stays open (add lanes, qa.ps1 retest)`)
const followUps = LANES.length ? all.filter((r) => r.pending && r.pending.length).map((r) => {
  const it = R.items.find((x) => x.code === r.code)
  if (!it || it.lane === 'app' || R.items.some((x) => x.code === `${it.code}A`)) return null
  return { ...it, code: `${it.code}A`, title: `${it.title} — app checks ${r.pending.join(', ')}`, lane: 'app', only: r.pending,
    taskFiles: [...(it.taskFiles || []), `${outDir(it)}/results.json`],
    extra: `${it.extra || ''} The web/API pass (${it.code}) left ${r.pending.join(', ')} PENDING for a device: test exactly those on your phone. Earlier results: ${outDir(it)}/results.json.` }
}).filter(Boolean) : []
if (followUps.length) {
  await agent(`Append these items to the "items" array of ${R.runDir}/run.json without changing anything else, in PowerShell:
$f = '${R.runDir}/run.json'; $j = Get-Content $f -Raw | ConvertFrom-Json; $new = '${JSON.stringify(followUps).replace(/'/g, "''")}' | ConvertFrom-Json
foreach ($n in $new) { if (-not ($j.items | Where-Object code -eq $n.code)) { $j.items += $n } }
[IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 20))
Then return ok=true and the list of item codes now in the file.`, { label: 'add-followups', phase: 'Test', schema: FINAL_SCHEMA, model: 'haiku', effort: 'low' })
  log(`app follow-ups for PENDING checks: ${followUps.map((f) => `${f.code} (${f.only.join(', ')})`).join('; ')}`)
  all.push(...(await pool(followUps, LANES.length, 300, laneFor)).filter(Boolean))
}
log('DONE: ' + all.map((r) => r.summary || (r.skipped ? `${r.code}: skipped (other worker)` : `${r.code}: ${r.error}`)).join(' | '))

// LEARN: signals + LESSONS.md; learn 'auto' = only after something eventful (a clean run gets the cleanup)
phase('Learn')
// every finished run ends with a kit retro (orchestrate E10)
const retroDue = (results) => { log('RETRO DUE: run /kit-retro (orchestrate E10) once no other workflow of this session runs'); return { results, unpublished: results.filter((r) => r.unpublished || r.error).map((r) => r.code), envFixOpen: results.filter((r) => r.envFixOpen).map((r) => r.code), retroDue: true, next: '/kit-retro (orchestrate E10)' } }
const eventful = all.some((r) => r.error || r.eventful)
if (LEARN === false || (LEARN === 'auto' && !eventful)) {
  await agent(`Run exactly this in PowerShell and report its last output line, nothing else:${PATHS}
& ${ORCH} cleanup -Quiet`, { label: 'cleanup', phase: 'Learn', model: 'haiku', effort: 'low' })
  log(`learn: skipped (${LEARN === false ? 'learn: false' : 'auto: clean run'}); cleanup ran`)
  return retroDue(all)
}
const learned = await agent(`You maintain the kit's memory. This QA run just finished.${PATHS}
Outcome (JSON):
${JSON.stringify(all).slice(0, 60000)}

1. One signal per notable event (failures, retries, NOT_TESTED causes, audit reclassifications / not-exercised splits, verify "not reproduced" or "inconclusive", anything that
   cost time or worked unusually well):
   & ${ORCH} learn -Skill <qa-kit|other skill> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. & ${ORCH} learn -Read -Skill qa-kit and the recent signals (learn -Show -Last 200). A pattern seen >= 2 times that is not a lesson yet:
   learn -Skill <skill> -Lesson "(n×) <one actionable line>" (an org-specific one goes to LESSONS.local.md by itself); a recurring one:
   learn -Bump "<words>"; a lesson the kit now handles: learn -Fixed "<words>"; then learn -Skill <skill> -Trim. Don't touch SKILL.md.
3. & ${ORCH} cleanup -Quiet (only kit-created leftovers), then Get-Content ${rp('cleanup-log')} -Tail 15: mention what was freed.
Return how many signals you recorded and which lessons changed.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, ...pick('learn'), effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s), lessons changed: ${learned.lessonsChanged.join('; ') || 'none'}`)
return retroDue(all)
