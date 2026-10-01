export const meta = {
  name: 'test-and-close',
  description: 'Test tracker tasks against tester guides on a test environment (web pool + API pool + Android lanes), audit notes, verify failures independently, publish docs, close tasks, raise bug tasks',
  whenToUse: 'A batch of tasks is deployed to a test environment and each has a tester guide (or a how-to-test comment) to execute',
  phases: [
    { title: 'Test', detail: 'one agent per guide: web/API pool in parallel, app guides one per phone' },
    { title: 'Verify', detail: 'note audit + independent re-test of every FAIL' },
    { title: 'Close', detail: 'Drive + Google Doc + tracker comment/close + bug task for confirmed failures' },
    { title: 'Learn', detail: 'signals + LESSONS.md updates from this run' },
  ],
}

/*
args = the run's run.json (write it to <runDir>\run.json too — finalize.ps1 reads it), plus runDir:
{
  runDir: 'C:\\work\\.claude-runtime\\qa-runs\\2026-10-01-epic-x',
  kitDir: 'C:\\work\\.claude',               // optional: absolute path of this kit (recommended); default '.claude' = relative to the workspace root
  title: 'Product X epic',                   // used in doc names and bug titles
  target: 'my-staging',                      // name in skills\qa-kit\targets.local.json
  tester: 'Full Name',
  mandate: ['<the user request, verbatim>', '...'],   // why the agents are doing this; stops them declining
  context: 'deployed builds, tenants/accounts to use, existing test data, known changed screens ...',
  contextFiles: ['C:\\...\\product-rules.md'],        // optional: files every tester reads first
  envLines: ['Web: ...', 'API: ...'],                  // shown in the report
  tracker: { list: '<id>', parent: '<epic id>', owner: '<user id>', closeStatus: 'Closed' },
  webParallel: 5, apiParallel: 5,
  lanes: [ { n: 1, name: 'Falcon', serial: 'emulator-5556', user: 'driver1', notes: 'own vehicle 57' } ],
  items: [ { code: 'F2', title: '...', guideFile: 'C:\\...\\F2.txt', lane: 'web'|'api'|'app',
             subtasks: [ { id: '<task id>', name: '...', mrs: '!12, !34' } ],
             retest: false, only: ['L3','L4'], skipClose: false, alsoWeb: false, extra: '...', taskFiles: [] } ],
}
*/
const R = args || {}
const KIT = (R.kitDir || '.claude').replace(/[\\/]+$/, '')     // the .claude folder of the workspace
const ABS = /^([A-Za-z]:|[\\/])/.test(KIT)
const PATHS = ABS ? '' : '\nKit paths below are relative to the workspace root (the directory this session started in); make them absolute before reading files.'
const QA = `${KIT}\\skills\\qa-kit`                 // SKILL.md = QA rules, targets.local.json = environments
const Q = `${QA}\\scripts`
const SWARM = `${KIT}\\skills\\android-swarm`
const ORCH = `${KIT}\\skills\\orchestrate\\scripts`
const RT = (R.runtimeDir || `${KIT}\\..\\.claude-runtime`).replace(/[\\/]+$/, '')
// ES module imports need a file:// URL of the absolute path
const BROWSER = ABS ? 'file:///' + `${KIT}/skills/qa-kit/scripts/web/browser.mjs`.replace(/\\/g, '/').replace(/^\/+/, '')
  : `<file:/// URL of the absolute path of ${KIT}\\skills\\qa-kit\\scripts\\web\\browser.mjs>`
if (!R.runDir || !Array.isArray(R.items)) throw new Error('args.runDir and args.items[] are required (see the header of this file)')
const outDir = (it) => `${R.runDir}\\${it.code}`
const LANES = R.lanes || []

const CHECKS_SCHEMA = {
  type: 'object',
  properties: {
    code: { type: 'string' },
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

AGENT BOARD — join first: & ${ORCH}\\board.ps1 join -Agent <CODE> -Run ${(R.runDir || '').split(/[\\/]/).pop()} -Claims <your phone serial / chrome ports>; stop on CLAIM/DUPLICATE; leave when done.

RULES — read ${QA}\\SKILL.md first (verdicts, evidence, shared-environment etiquette). The key points:
- PASS only when you saw the expected behaviour. Any defect is FAIL — inside or outside the guide's steps (off-script defects
  become extra checks X1, X2 ...). PASS_WITH_NOTE only for out-of-date guide text whose intent still holds, or purely cosmetic
  differences. findings are context only, never defects. NOT_TESTED only when truly impossible here (say why and what you tried).
- If a check fails, first confirm its change is actually deployed; not deployed = NOT_TESTED "not deployed yet", not FAIL.
- Evidence per ${QA}\\reference\\evidence-standard.md: names <CODE>-<checkId>_<nn>_<what>.<ext> (e.g. F2-T4_01_order-saved.jpeg); UI -> JPEG in <outDir>\\shots (mark() the element, look at it with Read);
  backend -> api.ps1 -Save <CODE>-<checkId>_<desc> -OutDir <outDir>\\evidence. List only files that exist.
- Shared environment: create your own data prefixed "QA-<CODE>", delete only what you created, restore any setting you change
  (list it in setup_changes). Never deactivate or re-password test logins.
- Time box ~10 min per check; keep each script run under ~2 min and print progress.

ENVIRONMENT AND CONTEXT
- Target "${R.target || '(default)'}" in ${QA}\\targets.local.json (URLs, users; passwords only there).
${R.context || ''}
${(R.contextFiles || []).length ? `- Read these first: ${R.contextFiles.join(' , ')}` : ''}

TOOLS
- API as any configured user: PowerShell & '${Q}\\api.ps1' -Target ${R.target || '<target>'} -As <user> [-Tenant <t>] -Method GET|POST|PUT|PATCH|DELETE -Path '/...' [-Body '<json>'] [-Save <name> -OutDir <dir>]
  (prints "HTTP <status>" then the body).
- Code: read the CURRENT code on the deployed branch (the guide may describe screens later work changed). If a literal step no longer
  applies, test the same intent on the current screen and record PASS_WITH_NOTE explaining it.
- Run scripts from PowerShell (node, python, gws, clickup, glab are on its PATH).`

const WEB = (ports) => `
BROWSER (web)
- Do NOT use the chrome-devtools MCP tools; do NOT touch Android emulators / adb.
- Drive your own headless Chrome via ${Q}\\web\\browser.mjs — read its header first. Put .mjs scripts in <outDir>\\scripts, run: node <file>.mjs
  import { session, go, text, clickText, clickSel, hoverSel, setInput, shot, settle, token, killSession } from '${BROWSER}'
  const s = await session({ port, target: '${R.target || ''}', tenant, as })  -> {page, net, done}. One port per tenant+user; end scripts with await s.done().
  s.net.failed = 4xx/5xx API calls + JS errors (failure evidence).
- Your Chrome ports: ${ports}. Memory is shared: at most 2 ports open at once; killSession() each port when you finish.`

function appBlock(L) {
  return `
ANDROID APP — YOUR PHONE: lane ${L.n} "${L.name}", adb serial ${L.serial}${L.user ? `, test login ${L.user}` : ''}. ${L.notes || ''}
Other agents test on other phones at the same time. You own this phone through a lease — nobody else boots or shuts it for you:
- FIRST get it:  & ${SWARM}\\phone.ps1 acquire -Agent qa-${L.name} -Lane ${L.name}
  It returns at once if the phone is yours already; otherwise it waits its fair turn and boots the phone when memory allows (about a minute),
  installs the current test APK if the phone has an older one ("installed: updated" = log in again), and prints {serial,...}.
- START EVERY PowerShell command with  $env:ANDROID_SERIAL='${L.serial}';  — never touch other serials, never run swarm-up/down/app-mode,
  never kill emulators or processes you didn't start, never adb kill-server.
- UI: ${Q}\\android\\ui.ps1 (dump | tap <text> | tapid <id> | tapxy x y | type <text> | key <code> | swipe | shot <name> <dir> | wait <text> | log <tag>).
  shot straight into <outDir>\\shots with the <CODE>-<checkId>_ prefix. Relaunch / clear the app: & ${SWARM}\\app-launch.ps1 -Serial ${L.serial} [-Clear]
- Phone etiquette: keep OUR APP open only while you test on the phone. Before long non-phone work (> 10 min: API calls, web UI in the
  browser, reading code, preparing data) hand the phone back:  & ${SWARM}\\phone.ps1 release -Agent qa-${L.name}
  (closes the app; the phone shuts down to free memory unless another agent is waiting for it). When you need it again, acquire it again
  (same command as above; the app stays installed and logged in). The workflow releases it after the lane's last item.
- Prefix your data "QA-L${L.n}-<CODE>". Don't change environment-wide settings from an app lane (other phones depend on them):
  prove such checks via the API and record PASS_WITH_NOTE instead.`
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
Package code: ${it.code}. Output folder: ${outDir(it)} (create shots\\, evidence\\, scripts\\). Reuse valid evidence already there.
Tasks covered (tag each check with its task id):
${(it.subtasks || []).map((s) => `  - ${s.id}: ${s.name}${s.mrs ? `  (MRs: ${s.mrs})` : ''}`).join('\n')}
${it.retest ? 'This is a RETEST of a fix: re-run the failed checks named in the task plus a short regression around them.' : ''}
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
${R.tracker && R.tracker.parent ? `- Skip issues already tracked by an existing [Bug] task under ${R.tracker.parent} (clickup task view ${R.tracker.parent} --json).` : ''}
- Return {id, defect, reason} per note check; defects that sit only in findings -> newDefects (screen, what_was_done, observed with the exact
  failing call/message, evidence file names that exist in ${outDir(it)}\\shots or evidence).
- You may read evidence, code, or call the API read-only (GET). Change nothing.

PASS_WITH_NOTE checks:
${notes || '(none)'}

Findings:
${finds || '(none)'}`
}

function verifyPrompt(it, fails, ports, L) {
  return `You are an independent QA verifier. Another tester reported these checks as FAILED. Re-test each from scratch and decide if the failure is real.
Be skeptical of the first tester (wrong control, wrong record, stale screen, script error) — read the current code to know what should happen —
but if the behaviour really differs from the guide's Expected, confirm it.

GUIDE: ${it.title}   Guide text: ${it.guideFile}
Package ${it.code}. Output folder ${outDir(it)}; name new evidence <CODE>-<checkId>_verify_<desc>.jpeg/.json.
Tasks and MRs: ${(it.subtasks || []).map((s) => `${s.id}${s.mrs ? ` (MRs: ${s.mrs})` : ''}`).join('; ')}

FAILED CHECKS:
${fails.map((c) => `- ${c.id} (${c.screen}) — first tester did: ${c.what_was_done}\n  saw: ${c.observed}`).join('\n')}
${COMMON}
${laneBlock(it, ports, L)}
Return one verdict per check id.`
}

function finalPrompt(it, res) {
  return `Publish the test results of package ${it.code}.${PATHS}
1. Write this JSON exactly as given to ${outDir(it)}\\results.json (Write tool; change nothing):
${JSON.stringify(res)}
2. Run in PowerShell (timeout 600000): & '${Q}\\finalize.ps1' -RunDir '${R.runDir}' -Code ${it.code}
   It uploads evidence to Drive, builds the shared Google Doc, comments on and closes the tasks, and opens a bug task for confirmed failures.
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
  let res = await agent(testPrompt(it, ports, L), { label: `test:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'qa-tester' })
  if (!res || ntShare(res) > 0.25) {
    log(`${it.code}: ${res ? Math.round(ntShare(res) * 100) + '% NOT_TESTED' : 'no result'} — re-running`)
    const prior = res ? `\nA previous attempt left these NOT_TESTED — they MUST now be executed: ${res.checks.filter((c) => c.result === 'NOT_TESTED').map((c) => c.id).join(', ')}. Reuse its valid evidence.` : ''
    const again = await agent(testPrompt(it, vports, L) + prior, { label: `retest:${it.code}${tag(L)}`, phase, schema: CHECKS_SCHEMA, agentType: 'qa-tester' })
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
    const v = await agent(verifyPrompt(it, fails, vports, L), { label: `verify:${it.code}${tag(L)}`, phase: 'Verify', schema: VERIFY_SCHEMA, agentType: 'qa-verifier' })
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
  if (it.skipClose) { log(`${line} (publish left to the lead)`); return { code: it.code, summary: line, result: res } }
  const fin = await agent(finalPrompt(it, res), { label: `close:${it.code}`, phase: 'Close', schema: FINAL_SCHEMA, model: 'sonnet', effort: 'low' })
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
      await agent(`Run exactly this in PowerShell and report its output, nothing else: & ${SWARM}\\phone.ps1 release -Agent qa-${L.name}`,
        { label: `release:${L.name}`, phase: 'Close', model: 'sonnet', effort: 'low' }).catch(() => null)
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
  app.length ? pool(app, LANES.length, 200, (w) => LANES[w]) : [],
])
const all = parts.flat().filter(Boolean)
log('DONE: ' + all.map((r) => r.summary || `${r.code}: ${r.error}`).join(' | '))

// LEARN: turn this run's outcome into signals, and recurring ones into LESSONS.md (self-improving kit)
phase('Learn')
const learned = await agent(`You maintain the kit's memory. This QA run just finished.${PATHS}
Outcome (JSON):
${JSON.stringify(all).slice(0, 60000)}

1. For every notable event (failures, retries, NOT_TESTED causes, audit reclassifications, verify "not reproduced", review findings,
   deferrals, anything that cost time or worked unusually well) append ONE signal line with
   & ${ORCH}\\learn.ps1 -Skill <skill> -Kind <kind> -Text "<what + fix>" -Ref <id> -Source workflow
   (skill: qa-kit or another kit skill / project name; kinds: friction, failure, defect-missed, false-positive, stale-env, flaky, idea, win).
2. Read ${QA}\\LESSONS.md and the recent signals (learn.ps1 -Show -Last 200). If a pattern now
   occurred ≥ 2 times and isn't a lesson yet, add it (newest first, one actionable line, "(n×)" count, project heading if project-specific);
   if an existing lesson recurred, bump its count. Keep the file under ~40 lines. Don't touch SKILL.md (that's /kit-retro's job).
3. Clean up what this run produced: & ${ORCH}\\cleanup.ps1 -Quiet  (kills leftover headless browsers > 3 h, expired logins/tokens,
   stale temp, finished worktrees; only kit-created things). Then: Get-Content (Join-Path ${RT} cleanup.log) -Tail 15 and mention what was freed.
Return how many signals you recorded and which lessons changed.`, { label: 'learn', phase: 'Learn', schema: LEARN_SCHEMA, model: 'sonnet', effort: 'low' })
if (learned) log(`learn: ${learned.signals} signal(s), lessons changed: ${learned.lessonsChanged.join('; ') || 'none'}`)
return all
