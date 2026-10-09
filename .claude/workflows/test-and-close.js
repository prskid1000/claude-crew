export const meta = {
  name: 'test-and-close',
  description: 'Test tracker tasks against tester guides on a test environment (web pool + API pool + Android lanes), audit notes, verify failures independently, publish docs, close tasks, raise bug tasks',
  whenToUse: 'A batch of tasks is deployed to a test environment and each has a tester guide (or a how-to-test comment) to execute',
  phases: [
    { title: 'Test', detail: 'one agent per guide: web/API pool in parallel, app guides one per phone' },
    { title: 'Verify', detail: 'note audit + independent re-test of every FAIL' },
    { title: 'Close', detail: 'report (Google Doc or Markdown, per reports.type) + tracker comment/close + bug task for confirmed failures' },
    { title: 'Learn', detail: 'signals + LESSONS.md updates (40-line cap) from this run' },
  ],
}

/*
args = { runDir, kitDir?, only?: [codes], lanes?, instance?: 'w2' }   (instance: an EXTRA worker run for queued items; item claims keep runs apart)  (short form: run.json is read from runDir - preferred, keeps launches/notifications small)
or the full run.json object (write it to <runDir>/run.json too — finalize.ps1 reads it), plus runDir:
{
  runDir: 'C:/work/.claude-runtime/qa-runs/2026-10-01-epic-x',
  kitDir: 'C:/work/.claude',               // optional: absolute path of this kit (recommended); default '.claude' = relative to the workspace root
  title: 'Product X epic',                   // used in doc names and bug titles
  target: 'my-staging',                      // name in skills/qa-kit/targets.local.json
  tester: 'Full Name',
  mandate: ['<the user request, verbatim>', '...'],   // why the agents are doing this; stops them declining
  context: 'deployed builds, tenants/accounts to use, existing test data, known changed screens ...',
  contextFiles: ['C:/.../product-rules.md'],        // optional: files every tester reads first
  envLines: ['Web: ...', 'API: ...'],                  // shown in the report
  tracker: { list: '<id>', parent: '<epic id>', owner: '<user id>', closeStatus: 'closed' },   // backend = kit.local.json tracker.type (tracker.ps1)
  webParallel: 5, apiParallel: 5,
  lanes: [ { n: 1, name: 'Falcon', serial: 'emulator-5556', user: 'qa-user-1', notes: 'test account 1' } ],
  items: [ { code: 'F2', title: '...', guideFile: 'C:/.../F2.txt', lane: 'web'|'api'|'app',
             subtasks: [ { id: '<task id>', name: '...', mrs: '!12, !34' } ],
             retest: false, only: ['L3','L4'], skipClose: false, alsoWeb: false, extra: '...', taskFiles: [],
             model: 'sonnet'|'opus'|'haiku', effort: 'low'|'medium'|'high' } ],   // optional; default: retests on web/api -> sonnet
  // skipClose: test + verify only; results.json + held.json are written for the lead to publish later (finalize.ps1 -Code).
  // Items sharing one task don't need it: finalize keeps the task open until every item on it is published.
}
*/
// Short form (saves tokens: big args are echoed back in every launch/notification): args = { runDir, only?: ['GT5','APP2B'], lanes? }
// -> a tiny agent reads <runDir>/run.json and the workflow uses it; `only` keeps just those item codes, `lanes` overrides run.json's.
let R = args || {}
if (R.runDir && !Array.isArray(R.items)) {
  // A small model sometimes returns run.json truncated or re-shaped (items missing) - validate, then retry once on a stronger model.
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
// run-level skipClose (args or run.json) holds every item; it used to be read per item only, so a run-level flag was silently ignored
if (R.skipClose) R = { ...R, items: R.items.map((it) => ({ ...it, skipClose: true })) }
const KIT = (R.kitDir || '.claude').replace(/[\\/]+$/, '')     // the .claude folder of the workspace
const ABS = /^([A-Za-z]:|[\\/])/.test(KIT)
const PATHS = (ABS ? '' : '\nKit paths below are relative to the workspace root (where this session started); make them absolute.') +
  '\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const QA = `${KIT}/skills/qa-kit`                 // SKILL.md = QA rules, targets.local.json = environments
const Q = `${QA}/scripts`
const SWARM = `${KIT}/skills/android-swarm`
const ORCH = `${KIT}/skills/orchestrate/scripts`
const RT = (R.runtimeDir || `${KIT}/../.claude-runtime`).replace(/[\\/]+$/, '')
// ES module imports need a file:// URL of the absolute path
const BROWSER = ABS ? 'file:///' + `${KIT}/skills/qa-kit/scripts/web/browser.mjs`.replace(/\\/g, '/').replace(/^\/+/, '')
  : `<file:/// URL of the absolute path of ${KIT}/skills/qa-kit/scripts/web/browser.mjs>`
if (!R.runDir || !Array.isArray(R.items) || !R.items.length) throw new Error('args.runDir and items are required: either args.items[] or a <runDir>/run.json (see the header of this file)')
const outDir = (it) => `${R.runDir}/${it.code}`
const LANES = R.lanes || []
const OWNER = R.instance || 'w1'   // worker instance: extra test-and-close runs for queued items use w2, w3 ... (item claims keep them apart)
// Memory seat + item claim (qa-seat.ps1): the run's webParallel/apiParallel are only caps; real concurrency follows free memory.
function seatBlock(it, label) {
  const kind = it.lane === 'api' ? 'api' : it.lane === 'app' ? 'app' : 'web'
  return `
SEAT (memory + item claim) - your FIRST command, before anything else:
  & ${Q}/qa-seat.ps1 acquire -Agent "${label}" -Kind ${kind} -RunDir "${R.runDir}" -Code ${it.code} -Owner ${OWNER}
  exit 0 = go. exit 2 = still waiting for memory: run the SAME command again until it returns 0 (other agents are finishing).
  exit 3 / "ALREADY" = another worker owns or finished this item: stop immediately and return { code: "${it.code}", skipped: true, checks: [] }.
  Your LAST command before returning (also on errors): & ${Q}/qa-seat.ps1 release -Agent "${label}"`
}
// Model per item: it.model / it.effort win; otherwise a narrow web/API retest (re-running named failed checks) is routine -> sonnet,
// first-time guides and app lanes keep the default (strongest) model.
function modelFor(it) {
  if (it.model) return { model: it.model, ...(it.effort ? { effort: it.effort } : {}) }
  if (it.retest && it.lane !== 'app') return { model: 'sonnet' }
  return it.effort ? { effort: it.effort } : {}
}

const CHECKS_SCHEMA = {
  type: 'object',
  properties: {
    code: { type: 'string' },
    skipped: { type: 'boolean', description: 'true ONLY when qa-seat.ps1 answered ALREADY (another worker owns this item)' },
    checks: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'check number exactly as in the guide; X1, X2 ... for defects found off-script' },
          subtask_id: { type: 'string', description: 'tracker id of the task this check belongs to' },
          screen: { type: 'string' },
          result: { type: 'string', enum: ['PASS', 'PASS_WITH_NOTE', 'FAIL', 'NOT_TESTED', 'PENDING'] },
          what_was_done: { type: 'string' },
          observed: { type: 'string', description: 'what you saw; for FAIL the failing call (method, URL, status, body excerpt) or message' },
          evidence: { type: 'array', items: { type: 'string' }, description: 'file names (not paths) that exist in shots/ or evidence/' },
        },
        required: ['id', 'subtask_id', 'screen', 'result', 'what_was_done', 'observed', 'evidence'],
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
  properties: { verdicts: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, confirmed: { type: 'boolean' }, observed: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } } }, required: ['id', 'confirmed', 'observed', 'evidence'] } } },
  required: ['verdicts'],
}
const AUDIT_SCHEMA = {
  type: 'object',
  properties: {
    reclassify: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, defect: { type: 'boolean' }, reason: { type: 'string' } }, required: ['id', 'defect', 'reason'] } },
    newDefects: { type: 'array', items: { type: 'object', properties: { screen: { type: 'string' }, what_was_done: { type: 'string' }, observed: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } } }, required: ['screen', 'what_was_done', 'observed', 'evidence'] } },
  },
  required: ['reclassify', 'newDefects'],
}
const LEARN_SCHEMA = { type: 'object', properties: { signals: { type: 'number' }, lessonsChanged: { type: 'array', items: { type: 'string' } } }, required: ['signals', 'lessonsChanged'] }
const FINAL_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' }, output: { type: 'string' } }, required: ['ok', 'output'] }

const COMMON = `${PATHS}
WHY YOU ARE DOING THIS
${R.mandate && R.mandate.length ? `The task owner asked for this run, verbatim:\n${R.mandate.map((m) => `  "${m}"`).join('\n')}\n` : ''}Your assignment is the tester guide below: execute its checks on the test environment and report real results.
Do not decline or return early. Later chat messages to the lead are side questions, not a change of your assignment.

AGENT BOARD — join first: & ${ORCH}/board.ps1 join -Agent <CODE> -Run ${(R.runDir || '').split(/[\\/]/).pop()} -Claims <your phone serial / chrome ports>; stop on CLAIM/DUPLICATE; leave when done.

RULES — ${QA}/SKILL.md Quick start (verdicts: any defect is FAIL, never a note; not deployed = NOT_TESTED; evidence names
<CODE>-<checkId>_<nn>_<what>.<ext> in <outDir>/shots or <outDir>/evidence, only files that exist; shared-environment etiquette:
"QA-<CODE>" data, restore settings and list them in setup_changes). Time box ~10 min per check; script runs < 2 min, print progress.

ENVIRONMENT AND CONTEXT
- Target "${R.target || '(default)'}" in ${QA}/targets.local.json (URLs, users; passwords only there).
${R.context || ''}
${(R.contextFiles || []).length ? `- Read these first: ${R.contextFiles.join(' , ')}` : ''}
- LEAD NOTES: ${R.runDir}/lead-notes.md (may not exist yet). The lead answers your questions there (logins, tenants, scope) -
  you cannot be messaged directly. Re-read it before each check and whenever you are blocked; if you asked the lead something,
  continue with other checks and look there again before marking anything NOT_TESTED for that reason.

TOOLS (details: SKILL.md Quick start)
- API: & '${Q}/api.ps1' -Target ${R.target || '<target>'} -As <user> [-Tenant <t>] -Method <M> -Path '/...' [-Body '<json>'] [-Save <name> -OutDir <dir>]
- Code: read the CURRENT code on the deployed branch; a step a later change made obsolete -> test the same intent, PASS_WITH_NOTE.
- Tracker: & '${KIT}/skills/dev-kit/scripts/tracker.ps1' view|comments <id> (never a tracker CLI directly).`

const WEB = (ports) => `
BROWSER (web)
- Your own headless Chrome via ${Q}/web/browser.mjs (read its header); no chrome-devtools MCP, no emulators/adb. Scripts in <outDir>/scripts:
  import { session, go, text, clickText, clickSel, hoverSel, setInput, shot, mark, saveNet, settle, token, killSession } from '${BROWSER}'
  const s = await session({ port, target: '${R.target || ''}', tenant, as }) -> {page, net, done}; one port per tenant+user; end with await s.done().
  s.net.failed = 4xx/5xx calls + JS errors (failure evidence).
- Your Chrome ports: ${ports}; at most 2 open at once; killSession() each when you finish.`

// Phone lease id per worker instance: two test-and-close workers mapping an item to the same lane must not share one lease
// (both "own" the phone and drive it at once). With distinct ids the second waits in phone.ps1's fair queue.
const LEASE = (L) => `qa-${OWNER}-${L.name}`
// Extra workers start on a different lane (w2 -> lane 2, w3 -> lane 3 ...) so they rarely queue behind w1's phones.
const LANE_OFFSET = Math.max(0, (parseInt(String(OWNER).replace(/\D/g, ''), 10) || 1) - 1)
const laneFor = (w) => LANES[(w + LANE_OFFSET) % LANES.length]
function appBlock(L) {
  return `
ANDROID APP — YOUR PHONE: lane ${L.n} "${L.name}", adb serial ${L.serial}${L.user ? `, test login ${L.user}` : ''}. ${L.notes || ''}
Your phone is leased (rules: ${SWARM}/SKILL.md Quick start):
- FIRST: & ${SWARM}/phone.ps1 acquire -Agent ${LEASE(L)} -Lane ${L.name}   (waits its turn, boots, installs the current APK; "installed: updated" = log in again)
- START EVERY PowerShell command with  $env:ANDROID_SERIAL='${L.serial}';  — never other serials, swarm-up/down/app-mode, adb kill-server,
  or killing emulators/processes you didn't start.
- UI: ${Q}/android/ui.ps1 (dump | tap | tapid | tapxy | type | key | swipe | shot | shotmark | wait | log); shots into <outDir>/shots with the
  <CODE>-<checkId>_ prefix. Relaunch/clear: & ${SWARM}/app-launch.ps1 -Serial ${L.serial} [-Clear]
- Before > 10 min of non-phone work: & ${SWARM}/phone.ps1 release -Agent ${LEASE(L)}; acquire again when needed (app stays installed).
  The workflow releases it after the lane's last item.
- Data prefix "QA-L${L.n}-<CODE>". No environment-wide setting changes from an app lane: prove those via the API (PASS_WITH_NOTE).`
}
const API = `
API-ONLY LANE
- No browser, no emulator: test through api.ps1 (and read-only DB access if available). Save request/response evidence for every check.`

function laneBlock(it, ports, L) {
  if (it.lane === 'app') return appBlock(L) + (it.alsoWeb ? WEB(ports) + '\nThis package also has web/API checks: test those with the browser helper too.' : '')
  if (it.lane === 'api') return API
  return WEB(ports)
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
${COMMON}
${laneBlock(it, ports, L)}
${(it.taskFiles || []).length ? 'Task details (fix description, how-to-test comments, earlier evidence): ' + it.taskFiles.join(' , ') : ''}
${it.extra || ''}
${it.only ? `SCOPE: test ONLY these checks: ${it.only.join(', ')}. Return only those.` : 'Work through ALL checks in the guide. Return every check with the guide\'s own numbers.'}
Return checks, findings, setup_changes and data_created.

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
- NOT defects: test-data/setup notes, tester mistakes, intended product decisions, platform limits, config missing on the test environment.
${R.tracker && R.tracker.parent ? `- Skip issues already tracked by an existing [Bug] task under ${R.tracker.parent} (the tracker (tracker.ps1): & '${KIT}/skills/dev-kit/scripts/tracker.ps1' view ${R.tracker.parent} lists its subtasks).` : ''}
- Return {id, defect, reason} per note check; defects that sit only in findings -> newDefects (screen, what_was_done, observed with the exact
  failing call/message, evidence file names that exist in ${outDir(it)}/shots or evidence).
- You may read evidence, code, or call the API read-only (GET). Change nothing.

PASS_WITH_NOTE checks:
${notes || '(none)'}

Findings:
${finds || '(none)'}`
}

function verifyPrompt(it, fails, ports, L) {
  return `Verify these FAILED checks from scratch (your agent definition: be skeptical of the first tester, confirm a real difference from Expected).

GUIDE: ${it.title}   Guide text: ${it.guideFile}
Package ${it.code}. Output folder ${outDir(it)}; name new evidence <CODE>-<checkId>_verify_<desc>.jpeg/.json.
Tasks and MRs: ${(it.subtasks || []).map((s) => `${s.id}${s.mrs ? ` (MRs: ${s.mrs})` : ''}`).join('; ')}

FAILED CHECKS:
${fails.map((c) => `- ${c.id} (${c.screen}) — first tester did: ${c.what_was_done}\n  saw: ${c.observed}`).join('\n')}
${seatBlock(it, `verify:${it.code}`)}
${COMMON}
${laneBlock(it, ports, L)}
Return one verdict per check id.`
}

function finalPrompt(it, res) {
  return `Publish the test results of package ${it.code}.${PATHS}
1. Write this JSON exactly as given to ${outDir(it)}/results.json (Write tool; change nothing):
${JSON.stringify(res)}
2. Run in PowerShell (timeout 600000): & '${Q}/finalize.ps1' -RunDir '${R.runDir}' -Code ${it.code}
   It publishes the report (Google Doc + Drive evidence, or report.md in the run folder - kit.local.json reports.type), comments on
   and closes the tasks through the tracker (tracker.ps1), and opens a bug task for confirmed failures.
3. If it errors, fix only data problems in results.json (e.g. drop a missing evidence file name) and run it once more. Don't edit finalize.ps1.
Return ok=true/false and the script's output.`
}

const ntShare = (r) => (r && r.checks.length ? r.checks.filter((c) => c.result === 'NOT_TESTED').length / r.checks.length : 1)
const tag = (L) => (L ? '@' + L.name : '')

async function runItem(it, idx, L) {
  const p = 9600 + (idx % 40) * 10
  const ports = `${p}-${p + 4}`
  const vports = `${p + 5}-${p + 9}`
  const phase = 'Test'
  let res = await agent(testPrompt(it, ports, L), { label: `test:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'qa-tester', ...modelFor(it) })
  if (res && res.skipped) { log(`${it.code}: skipped - another worker owns or finished it`); return { code: it.code, skipped: true } }
  if (!res || ntShare(res) > 0.25) {
    log(`${it.code}: ${res ? Math.round(ntShare(res) * 100) + '% NOT_TESTED' : 'no result'} — re-running`)
    const prior = res ? `\nA previous attempt left these NOT_TESTED — they MUST now be executed: ${res.checks.filter((c) => c.result === 'NOT_TESTED').map((c) => c.id).join(', ')}. Reuse its valid evidence.` : ''
    const again = await agent(testPrompt(it, vports, L) + prior, { label: `retest:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'qa-tester', ...modelFor(it) })
    if (again && ntShare(again) < ntShare(res)) res = again
  }
  if (!res) return { code: it.code, error: 'test agent returned nothing' }
  if (ntShare(res) > 0.5) {
    log(`${it.code}: still ${Math.round(ntShare(res) * 100)}% NOT_TESTED — not publishing; needs a manual look`)
    return { code: it.code, error: `${Math.round(ntShare(res) * 100)}% NOT_TESTED, not published`, result: res }
  }
  res.code = it.code

  // Note audit: real defects hidden in notes/findings become FAIL (or new X checks) so they get verified and a bug task.
  if (res.checks.some((c) => c.result === 'PASS_WITH_NOTE') || (res.findings || []).length) {
    const a = await agent(auditPrompt(it, res), { label: `audit:${it.code}`, phase: 'Verify', schema: AUDIT_SCHEMA, agentType: 'qa-verifier', model: 'sonnet' })
    for (const d of (a && a.reclassify) || []) {
      const c = res.checks.find((x) => x.id === d.id)
      if (c && d.defect && c.result === 'PASS_WITH_NOTE') { c.result = 'FAIL'; c.observed = `${c.observed} | Note audit: a defect, not a note: ${d.reason}` }
    }
    let n = res.checks.filter((c) => /^X\d+$/.test(c.id)).length
    for (const d of (a && a.newDefects) || []) {
      res.checks.push({ id: `X${++n}`, subtask_id: ((it.subtasks || [])[0] || {}).id || '', screen: d.screen, result: 'FAIL', what_was_done: d.what_was_done, observed: `${d.observed} (raised by the note audit)`, evidence: d.evidence || [] })
    }
    if (a) log(`${it.code}: audit -> ${(a.reclassify || []).filter((d) => d.defect).length} note(s) reclassified, ${(a.newDefects || []).length} new defect(s)`)
  }

  const fails = res.checks.filter((c) => c.result === 'FAIL')
  if (fails.length) {
    const v = await agent(verifyPrompt(it, fails, vports, L), { label: `verify:${it.code}${tag(L)}`, phase: 'Verify', schema: VERIFY_SCHEMA, agentType: 'qa-verifier', ...modelFor(it) })
    const byId = Object.fromEntries(((v && v.verdicts) || []).map((x) => [x.id, x]))
    for (const c of fails) {
      const x = byId[c.id]
      if (!x) { c.verify = 'not re-tested'; continue }
      c.verify = x.confirmed ? 'confirmed' : 'not reproduced'
      c.evidence = [...c.evidence, ...x.evidence]
      if (x.confirmed) c.observed = `${c.observed} | Independent re-test confirmed: ${x.observed}`
      else { c.result = 'PASS_WITH_NOTE'; c.observed = `First run reported a failure; an independent re-test did not reproduce it. Re-test: ${x.observed}. First run: ${c.observed}` }
    }
  }
  const n = (k) => res.checks.filter((c) => c.result === k).length
  const line = `${it.code}: pass ${n('PASS') + n('PASS_WITH_NOTE')}/${res.checks.length}, fail ${n('FAIL')}, not tested ${n('NOT_TESTED')}, pending ${n('PENDING')}`
  if (it.skipClose) {
    // keep the verdicts on disk for the lead (several items can share one task; the lead publishes them together with
    // finalize.ps1 -Code <code> once all are in). held.json marks the item finished for the supervisor and other workers.
    await agent(`Write two files with the Write tool, content exactly as given, change nothing, then return ok=true.
1. ${outDir(it)}/results.json:
${JSON.stringify(res)}
2. ${outDir(it)}/held.json:
${JSON.stringify({ code: it.code, held: 'publish left to the lead (skipClose)', summary: line, at: '<now>' })}
Replace <now> with the current UTC time (ISO 8601) when you write it (workflow scripts can't read the clock: Date.now()/new Date() throw).`,
      { label: `hold:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, model: 'haiku', effort: 'low' })
    log(`${line} (results saved; publish left to the lead)`)
    return { code: it.code, summary: line, result: res }
  }
  const fin = await agent(finalPrompt(it, res), { label: `close:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, model: 'haiku', effort: 'low' })
  log(line + (fin && fin.ok ? '' : ' [FINALIZE FAILED — autoclose.ps1 or the lead publishes it]'))
  return { code: it.code, summary: line, finalize: fin, pending: res.checks.filter((c) => c.result === 'PENDING').map((c) => c.id) }
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
      await agent(`Run exactly this in PowerShell and report its output, nothing else: & ${SWARM}/phone.ps1 release -Agent ${LEASE(L)}`,
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
if (app.length && !LANES.length) throw new Error('app items need args.lanes (one per phone lane + its login); phones need not be running: agents lease and boot them (phone.ps1)')
log(`run ${R.runDir}: web ${web.length} (x${R.webParallel || 5}), api ${api.length} (x${R.apiParallel || 5}), app ${app.length} (${LANES.length} phones)`)

const parts = await Promise.all([
  web.length ? pool(web, R.webParallel || 5, 0) : [],
  api.length ? pool(api, R.apiParallel || 5, 100) : [],
  app.length ? pool(app, LANES.length, 200, laneFor) : [],
])
const all = parts.flat().filter(Boolean)

// App follow-ups: a web/api item whose checks came back PENDING (device steps) gets an app item for exactly those checks,
// run on the phones now instead of waiting for the lead. It is appended to run.json first (finalize looks items up there).
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

// LEARN: turn this run's outcome into signals, and recurring ones into LESSONS.md (self-improving kit)
phase('Learn')
const learned = await agent(`You maintain the kit's memory. This QA run just finished.${PATHS}
Outcome (JSON):
${JSON.stringify(all).slice(0, 60000)}

1. One signal per notable event (failures, retries, NOT_TESTED causes, audit reclassifications, verify "not reproduced", anything that
   cost time or worked unusually well):
   & ${ORCH}/learn.ps1 -Skill <qa-kit|other skill|project> -Kind <friction|failure|defect-missed|false-positive|stale-env|flaky|idea|win> -Text "<what + fix>" -Ref <id> -Source workflow
2. Read ${QA}/LESSONS.md (active rules; never HISTORY.md) and the recent signals (learn.ps1 -Show -Last 200). A pattern seen ≥ 2 times
   that isn't a lesson yet: & ${ORCH}/learn.ps1 -Skill <skill> -Lesson "(n×) <one actionable line>" [-Project <name>]; a recurring
   lesson: bump its "(n×)" count with Edit. A lesson the kit now handles: learn.ps1 -Skill <skill> -Fixed "<words of it>". Finish with
   learn.ps1 -Skill <skill> -Trim for each LESSONS.md you changed (≤ 40 lines; moves fixed/oldest lines to HISTORY.md). Don't touch SKILL.md.
3. & ${ORCH}/cleanup.ps1 -Quiet (only kit-created leftovers), then Get-Content (Join-Path ${RT} cleanup.log) -Tail 15: mention what was freed.
Return how many signals you recorded and which lessons changed.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, model: 'sonnet', effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s), lessons changed: ${learned.lessonsChanged.join('; ') || 'none'}`)
return all
