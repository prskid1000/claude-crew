#Requires -Version 7
<#
workflows.tests.ps1: buildy.js and testy.js sims (agents mocked; node runs the real script body).
Usage: pwsh -NoProfile -File <kit>/tests/workflows.tests.ps1 (or tests/kit-tests.ps1 -Area workflows).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
# workflow sims: shared fixtures + $js; __BODY__ = the workflow source
$jsLib = @'
const _ck = (id, result, extra = {}) => ({ id, subtask_id: 'T1', screen: 's', result, what_was_done: 'w', observed: `o ${id}`, evidence: [], attempts: 1, ...extra })
const _res = (code, checks) => ({ code, checks, findings: [], setup_changes: [], data_created: [] })
const _rep = (localTest, extra = {}) => ({ mrs: [{ url: 'https://h/g/api/-/merge_requests/1', repo: 'api', merged: false }], worktrees: ['C:/wt/x1'], done: ['A1'], deferred: [], needsDecision: [], needsEnvFix: [], localTest, needsLiveCheck: [], seed: [], foreignHooks: [], summary: 's', testerGuide: 'https://doc', ...extra })
const _merged = (n) => ({ mrs: [{ url: `https://h/g/api/-/merge_requests/${n}`, repo: 'api', merged: true, mergeState: 'MERGED' }] })
const _rec = () => ({ ok: true, output: 'RECORDED' })
const _ok = (output) => ({ ok: true, output, signals: 0, lessonsChanged: [] })
const _err = (e) => console.log('error:' + e)
const _n = () => {}
const run = async (args, agent, log, phase, pipeline, parallel) => { __BODY__ }
const pipeline = async (items, ...stages) => Promise.all(items.map(async (a) => { let x = await stages[0](a); for (const s of stages.slice(1)) x = await s(x, a); return x }))
'@
function Invoke-Js($name, $js, $wf) { $f = Join-Path (Kd) "$name.mjs"; [IO.File]::WriteAllText($f, ($jsLib + "`n" + $js).Replace('__BODY__', $wf)); @(node $f 2>&1) }
$k = New-TestKit workflows; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
# buildy local loop: BLOCKED = FAIL; still FAIL -> ONE stronger round; ENV-FIX waits
$wfd = [IO.File]::ReadAllText((Join-Path $src 'workflows/buildy.js')) -replace '^export const meta', 'const meta'
$jsd = @'
const lt = (status, extra = {}) => ({ status, env: 'shop r1', rounds: 3, failing: status === 'PASS' ? [] : ['G1 still 500'], goalsDoc: 'g.md', ...extra })
const rep = (status, extra = {}) => _rep(lt(status), extra)
const mk = (envfix) => { const calls = []; return { calls, agent: async (prompt, o) => {
 calls.push({ label: o.label, model: o.model, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^build:/.test(o.label)) return envfix ? rep('FAIL', { done: [], needsEnvFix: [{ item: 'A1', envFixId: 'e-20260101000000-x1', need: 'refresh the release' }] }) : rep('BLOCKED', { localTest: lt('BLOCKED', { blockedReason: 'local DB missing a table' }) })
 if (/^local:/.test(o.label)) return rep('FAIL')
 if (/^envfix:/.test(o.label)) return { ok: true, output: 'ANSWERED e-20260101000000-x1: done: refreshed r2' }
 if (/^(local-strong|envfix-resume):/.test(o.label)) return rep('PASS')
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ci:/.test(o.label)) return { done: true, mrs: [{ mr: '1', status: 'success' }] }
 if (/^ship:/.test(o.label)) return rep('PASS', _merged(1))
 return _ok('[]') } } }
const args = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
const a = mk(false), b = mk(true)
run(args, a.agent, _n, _n, pipeline).then((oa) => run(args, b.agent, _n, _n, pipeline).then((ob) => {
 const s = a.calls.find((c) => c.label === 'local-strong:X1')
 console.log(`blocked-is-fail:${a.calls.some((c) => c.label === 'local:X1') && !oa.blocked.length}`)
 console.log(`strong-round:${!!s && s.model === 'opus' && /STRONGER FIX ROUND/.test(s.prompt) && a.calls.some((c) => c.label === 'ship:X1')}`)
 console.log(`envfix:${b.calls.some((c) => c.label === 'envfix:X1' && /decide wait -Id e-20260101000000-x1/.test(c.prompt)) && b.calls.some((c) => c.label === 'envfix-resume:X1' && /done: refreshed r2/.test(c.prompt)) && ob.envFixes.length === 1 && b.calls.some((c) => c.label === 'ship:X1')}`)
 console.log(`flow-text:${/decide ask -Kind envfix/.test(a.calls.find((c) => c.label === 'build:X1').prompt)}`)
})).catch(_err)
'@
Expect-Each (Invoke-Js dw-local $jsd $wfd) 'buildy local loop: #' 'blocked-is-fail', 'strong-round', 'envfix', 'flow-text' -Show 5
# buildy: blocking finding -> fix -> ONE re-review; deferred item holds promotion
$jsr = @'
const lt = { status: 'PASS', env: 'shop r1', rounds: 1, failing: [], goalsDoc: 'g.md' }
const rep = (extra = {}) => _rep(lt, extra)
const calls = []
let reviews = 0
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^build:/.test(o.label)) return rep({ deferred: [{ id: 'A2', reason: 'needs data' }] })
 if (/^review:/.test(o.label)) return { findings: reviews++ ? [] : [{ mr: '1', file: 'a.ts', line: 3, severity: 'blocking', problem: 'null check missing', fix: 'add it' }] }
 if (/^fix:/.test(o.label)) return rep()
 if (/^ci:/.test(o.label)) return { done: true, mrs: [{ mr: '1', status: 'success' }] }
 if (/^ship:/.test(o.label)) return rep(_merged(1))
 return _ok('[]')
}
const args = { brief: 'C:/b/wave-x.md', agents: [{ id: 'X1', items: 'A1, A2', area: 'a' }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
run(args, agent, _n, _n, pipeline).then(() => {
 const rv = calls.filter((c) => c.label === 'review:X1'), ti = calls.findIndex((c) => c.label === 'track:X1'), si = calls.findIndex((c) => c.label === 'ship:X1')
 console.log(`re-review:${rv.length === 2 && /RE-REVIEW after the fix round/.test(rv[1].prompt) && /null check missing/.test(rv[1].prompt) && si > calls.indexOf(rv[1])}`)
 console.log(`hold:${ti >= 0 && /-HoldPromotion 'deferred items: A2'/.test(calls[ti].prompt)}`)
 const m = /-Run '([^']+)'/.exec(calls.find((c) => c.label === 'record-args').prompt)
 console.log(`run:${m ? m[1] : 'none'}`)
}).catch(_err)
'@
$res = Invoke-Js dw-review $jsr $wfd
$want = & { . $O; Get-LaunchRunName ([pscustomobject]@{ brief = 'C:/b/wave-x.md' }) }
Expect-Each $res 'buildy: #' 're-review', 'hold' -Show 5
Expect 'buildy: default run name = orch.ps1 Get-LaunchRunName' (@($res | Where-Object { "$_" -eq "run:$want" }).Count -eq 1 -and $want -match '^wave-x-[0-9a-f]{4}$')
# buildy: a batch's next run drops producers outside its list
$jsn = @'
const agent = async (p, o) => /^record-args/.test(o.label) ? _rec() : /^(build|ship):/.test(o.label) ? _rep({ status: 'PASS', failing: [] }, _merged(1)) : _ok('[]')
const o1 = await run({ brief: 'C:/b/w.md', kitDir: 'C:/kit', learn: false, batch: 1, agents: [{ id: 'X0', items: 'A1' }, { id: 'X1', items: 'A2', dependsOn: ['X0'] }] }, agent, _n, _n, pipeline)
console.log(`batch-next:${!!(await run(o1.next.args, agent, _n, _n, pipeline).catch(_err))}`)
'@
Expect-Each (Invoke-Js dw-next $jsn $wfd) 'buildy: #' 'batch-next' -Show 5
# buildy: mode duel is an extra (refused, names the extra); a removed arg is warned about, not silently ignored
$jso = @'
const agent = async (p, o) => /^record-args/.test(o.label) ? _rec() : /^(build|ship):/.test(o.label) ? _rep({ status: 'PASS', failing: [] }, _merged(1)) : _ok('[]')
const logs = [], base = { brief: 'C:/b/w.md', kitDir: 'C:/kit', learn: false, agents: [{ id: 'X1', items: 'A1' }] }
const e = await run({ ...base, mode: 'duel' }, agent, _n, _n, pipeline).then(() => '', (x) => x.message)
await run({ ...base, review: false }, agent, (m) => logs.push(m), _n, pipeline)
console.log(`duel-refused:${/duel is an extra: run kittool.py extra add duel/.test(e)}`)
console.log(`removed-arg:${logs.some((l) => /args.review was removed/.test(l))}`)
'@
Expect-Each (Invoke-Js dw-args $jso $wfd) 'buildy: #' 'duel-refused', 'removed-arg' -Show 5
$wf = [IO.File]::ReadAllText((Join-Path $src 'workflows/testy.js')) -replace '^export const meta', 'const meta'
$js = @'
const calls = []
const ck = _ck
async function agent(prompt, o) {
 calls.push({ label: o.label, model: o.model, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^(test|retest):/.test(o.label)) return _res('A1', [ck('C1', 'NOT_TESTED', { cause: 'env-data' }), ck('C2', 'PASS'), ck('C3', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('A1', [ck('C1', 'PASS')])
 if (/^close/.test(o.label)) return { ok: true, output: 'published' }
 return _ok('')
}
const args = { runDir: 'C:/runs/R1', kitDir: 'C:/kit', learn: false, items: [{ code: 'A1', title: 'A one', guideFile: 'g.md', lane: 'web', subtasks: [{ id: 'T1' }] }] }
run(args, agent, _n, _n, null).then(() => {
 const s = calls.find((c) => c.label === 'retest-strong:A1'), cl = calls.find((c) => c.label === 'close:A1')
 console.log(`strong:${!!s && s.model === 'opus' && /blocked by env-data/.test(s.prompt) && /ONLY these checks: C1/.test(s.prompt)}`)
 console.log(`closed-pass:${!!cl && /"id":"C1"[^}]*"result":"PASS"/.test(cl.prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-retry $js $wf
Expect 'testy: NOT_TESTED gets one stronger retry, told its blocker' (@($res | Where-Object { "$_" -eq 'strong:true' }).Count -eq 1)
Expect 'testy: the retry''s PASS is what gets published' (@($res | Where-Object { "$_" -eq 'closed-pass:true' }).Count -eq 1)
# testy local: NOT_TESTED -> ENV-FIX + retest; 2 cycles: held
$js3 = @'
const ck = _ck
const mk = (fixWorks) => { const calls = []; return { calls, agent: async (prompt, o) => {
 calls.push({ label: o.label, model: o.model, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^(test|retest|retest-strong):/.test(o.label)) return _res('A1', [ck('C1', 'NOT_TESTED', { cause: 'undeployed', env_fix: 'refresh the release' }), ...(/^retest-strong/.test(o.label) ? [] : [ck('C2', 'PASS'), ck('C3', 'PASS'), ck('C4', 'PASS')])])
 if (/^envfix-ask:/.test(o.label)) return { ok: true, output: `ENV-FIX e-20260101000000-qa-a1 pending` }
 if (/^envfix-wait:/.test(o.label)) return { ok: true, output: 'ANSWERED e-20260101000000-qa-a1: done: refreshed' }
 if (/^envfix-retest:/.test(o.label)) return _res('A1', [ck('C1', fixWorks ? 'PASS' : 'NOT_TESTED', { cause: 'env-data' })])
 return _ok('') } } }
const args = { runDir: 'C:/runs/R1', kitDir: 'C:/kit', learn: false, localEnv: 'shop', items: [{ code: 'A1', title: 'A one', guideFile: 'g.md', lane: 'api', subtasks: [{ id: 'T1' }] }] }
const a = mk(true), b = mk(false)
run(args, a.agent, _n, _n, null).then(() => run(args, b.agent, _n, _n, null)).then((out) => {
 const ask = a.calls.find((c) => c.label === 'envfix-ask:A1'), cl = a.calls.find((c) => c.label === 'close:A1')
 console.log(`envfix-ask:${!!ask && /decide ask -Kind envfix/.test(ask.prompt) && /refresh the release/.test(ask.prompt)}`)
 console.log(`envfix-pass:${!!cl && /"id":"C1"[^}]*"result":"PASS"/.test(cl.prompt) && /LOCAL ENV "shop"/.test(a.calls.find((c) => c.label === 'test:A1').prompt)}`)
 console.log(`envfix-held:${b.calls.filter((c) => c.label === 'envfix-ask:A1').length === 2 && !b.calls.some((c) => /^close/.test(c.label)) && b.calls.some((c) => c.label === 'hold:A1' && /ENV-FIX/.test(c.prompt)) && out.envFixOpen.includes('A1')}`)
}).catch(_err)
'@
$res = Invoke-Js tc-envfix $js3 $wf
Expect-Each $res 'testy local: #' 'envfix-ask', 'envfix-pass', 'envfix-held' -Show 5
# testy retries per check: fewer checks keep the first FAIL; a duplicate (C5b) retries as C5
$js4 = @'
const calls = []
const ck = _ck
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^test:/.test(o.label)) return _res('A1', [ck('C1', 'FAIL', { defect: 'own' }), ck('C2', 'NOT_TESTED'), ck('C3', 'NOT_TESTED'), ck('C4', 'PASS'), ck('C5', 'PASS'), ck('C5', 'NOT_TESTED')])
 if (/^retest:/.test(o.label)) return _res('A1', [ck('C2', 'PASS'), ck('C3', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('A1', [ck('C5', 'PASS')])
 if (/^verify:/.test(o.label)) return { verdicts: [{ id: 'C1', outcome: 'confirmed', confirmed: true, attempts: 1, observed: 'again', evidence: [], basis: 'none' }] }
 return _ok('published')
}
const args = { runDir: 'C:/runs/R4', kitDir: 'C:/kit', learn: false, items: [{ code: 'A1', title: 'A', guideFile: 'g.md', lane: 'api', subtasks: [{ id: 'T1' }] }] }
run(args, agent, _n, _n, null).then(() => {
 const cl = calls.find((c) => c.label === 'close:A1'), s = calls.find((c) => c.label === 'retest-strong:A1')
 console.log(`keeps-fail:${!!cl && /"id":"C1"[^}]*"result":"FAIL"/.test(cl.prompt) && /"id":"C3"[^}]*"result":"PASS"/.test(cl.prompt)}`)
 console.log(`guide-id:${!!s && /ONLY these checks: C5\./.test(s.prompt) && /"id":"C5b"[^}]*"result":"PASS"/.test(cl.prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-merge $js4 $wf
Expect-Each $res 'testy retries: #' 'keeps-fail', 'guide-id' -Show 5
$js2 = @'
const calls = []
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (o.label === 'prepare') return { runDir: 'C:/rt/work/qa-runs/2026-01-01-local', items: 1, left: [{ id: 'T9', reason: 'not live' }], summary: 's' }
 if (/^load-run/.test(o.label)) return { json: JSON.stringify({ target: 'local-a', items: [{ code: 'A1', title: 'A', guideFile: 'g.md', lane: 'api', target: 'local-b', subtasks: [{ id: 'T1' }] }] }) }
 if (/^record-args/.test(o.label)) return _rec()
 if (/^test:/.test(o.label)) return _res('A1', [{ id: 'C1', subtask_id: 'T1', screen: 's', result: 'PASS', what_was_done: 'w', observed: 'o', evidence: [], attempts: 1 }])
 return _ok('')
}
const args = { select: { statuses: ['promoted', 'inTest'], exclude: ['T7'] }, target: 'local', kitDir: 'C:/kit', learn: false }
const logs = []
run(args, agent, (m) => logs.push(m), () => {}, null).then(() => {
 const p = calls.find((c) => c.label === 'prepare'), t = calls.find((c) => c.label === 'test:A1'), recs = calls.filter((c) => c.label === 'record-args'), orig = JSON.stringify(args)
 // the launch record == the original args (before Prepare), then the same args + the resolved runDir
 const rec = recs.length === 2 && calls.indexOf(recs[0]) < calls.indexOf(p) && recs.every((r) => r.prompt.includes(`<<<ARGS\n${orig}\nARGS>>>`) && /-Run 'select-local'/.test(r.prompt)) &&
  !/-RunDir/.test(recs[0].prompt) && recs[1].prompt.includes("-RunDir 'C:/rt/work/qa-runs/2026-01-01-local'")
 console.log(`prepare:${!!p && /"statuses":\["promoted","inTest"\]/.test(p.prompt) && /"target":"local"/.test(p.prompt) && /"exclude":\["T7"\]/.test(p.prompt) && /qa-runs\/<yyyy-MM-dd>-local-promoted-intest/.test(p.prompt)}`)
 console.log(`record:${rec}`)
 console.log(`item-target:${!!t && /KIT_QA_TARGETS='local-b'/.test(t.prompt) && logs.some((l) => /left out T9: not live/.test(l))}`)
}).catch(_err)
'@
$res = Invoke-Js tc-select $js2 $wf
Expect-Each $res 'testy select: #' 'prepare', 'record', 'item-target' -Show 5
# testy runDir: args recorded first; next keeps only, lanes, instance
$js7 = @'
let first
const mk = (rec) => async (p, o) => { first = first || { l: o.label, p }
 return /^load-run/.test(o.label) ? { json: JSON.stringify({ items: [1, 2, 3, 4].map((n) => ({ code: `F${n}`, lane: 'api' })) }) }
  : /^record-args/.test(o.label) ? _ok(rec) : /^test:/.test(o.label) ? _res(o.label.slice(5, 7), [_ck('C1', 'PASS')]) : _ok('') }
const args = { runDir: 'C:/runs/R9', kitDir: 'C:/kit', learn: false, only: ['F1', 'F2', 'F3'], lanes: ['L'], instance: 'w2', batch: 1 }
const keep = (n, only) => !!n && n.args.lanes[0] === 'L' && n.args.instance === 'w2' && n.args.only.join() === only
run(args, mk('RECORDED'), _n, _n, null).then(async (o) => {
 const r = await run(args, mk('RECORDED BUDGET {"cap":100,"estimate":1000}'), _n, _n, null)
 console.log(`kept:${first.l === 'record-args' && first.p.includes("-RunDir 'C:/runs/R9'") && keep(o.next, 'F2,F3') && r.refused && keep(r.next, 'F1,F2,F3')}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-next $js7 $wf) 'testy runDir: #' 'kept' -Show 5
# testy: web testers share the per-user Chrome; scoped retries -> results-retry.json; publish -ExpectChecks
$js5 = @'
const ports = []
const ck = (id, result) => ({ id, subtask_id: 'T1', screen: 's', result, what_was_done: 'w', observed: 'o', evidence: [], attempts: 1 })
const mk = () => { const calls = []; return { calls, agent: async (prompt, o) => {
 calls.push({ label: o.label, prompt })
 if (/^test:/.test(o.label)) ports.push(/SHARED logged-in Chrome/.test(prompt) && /relogin\(s\)/.test(prompt) && !/killSession\(\)/.test(prompt) && !/session\(\{ port/.test(prompt))
 if (/^record-args/.test(o.label)) return _rec()
 if (o.label === 'test:W0') return _res('W0', [ck('C1', 'NOT_TESTED'), ck('C2', 'PASS'), ck('C3', 'PASS'), ck('C4', 'PASS')])
 if (/^(test|retest):/.test(o.label)) return _res('x', [ck('C1', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('W0', [ck('C1', 'PASS')])
 return _ok('published') } } }
const items = Array.from({ length: 45 }, (_, i) => ({ code: `W${i}`, title: 't', guideFile: 'g.md', lane: 'web', subtasks: [{ id: 'T1' }] }))
const a = mk(), b = mk()
run({ runDir: 'C:/runs/P1', kitDir: 'C:/kit', learn: false, items }, a.agent, _n, _n, null)
 .then(() => run({ runDir: 'C:/runs/P1', kitDir: 'C:/kit', learn: false, instance: 'w1', items }, b.agent, _n, _n, null)).then(() => {
 console.log(`ports:${ports.length === 90 && ports.every(Boolean)}`)   // shared per-user Chrome (owner 2026-10-16): no per-run ports
 const s = a.calls.find((c) => c.label === 'retest-strong:W0'), cl = a.calls.find((c) => c.label === 'close:W0')
 console.log(`retry-file:${!!s && /results-retry\.json/.test(s.prompt) && /-Results results-retry\.json/.test(s.prompt) && /Never write/.test(s.prompt)}`)
 console.log(`expect:${!!cl && /-ExpectChecks 4/.test(cl.prompt) && /exit 4 = still waiting/.test(a.calls.find((c) => c.label === 'test:W0').prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-ports $js5 $wf
Expect-Each $res 'testy: #' 'ports', 'retry-file', 'expect' -Show 5
# a FAIL with evidence one re-test misses stays FAIL; without evidence it may pass
$js6 = @'
const calls = []
const ck = _ck
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^test:/.test(o.label)) return _res('A1', [ck('C1', 'FAIL', { defect: 'own', evidence: ['A1-C1_01_500.json'] }), ck('C2', 'FAIL', { defect: 'own' }), ck('C3', 'PASS')])
 if (/^verify:/.test(o.label)) return { verdicts: ['C1', 'C2'].map((id) => ({ id, outcome: 'refuted', confirmed: false, attempts: 1, observed: 'fine now', evidence: [`A1-${id}_verify_01_ok.json`], basis: 'saved _verify files' })) }
 return _ok('published')
}
const args = { runDir: 'C:/runs/R6', kitDir: 'C:/kit', learn: false, items: [{ code: 'A1', title: 'A', guideFile: 'g.md', lane: 'api', subtasks: [{ id: 'T1' }] }] }
run(args, agent, _n, _n, null).then(() => {
 const cl = calls.find((c) => c.label === 'close:A1')
 console.log(`flaky:${!!cl && /"id":"C1"[^}]*"result":"FAIL"[^}]*"verify":"not reproduced \(flaky\)","flaky":true/.test(cl.prompt)}`)
 console.log(`no-evidence:${!!cl && /"id":"C2"[^}]*"result":"PASS_WITH_NOTE"/.test(cl.prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-flaky $js6 $wf
Expect-Each $res 'testy verify: #' 'flaky', 'no-evidence' -Show 5
$wsim = @'
import { readFileSync } from 'node:fs'
const mk = (out, spent, handoff) => { const calls = []; return { calls, agent: async (p, o) => { calls.push({ label: o.label, prompt: p })
  if (/^record-args/.test(o.label)) return { ok: true, output: `RECORDED x\nBUDGET ${out}` }
  if (o.label === 'budget') return { ok: true, output: JSON.stringify({ spent }) }
  if (/^(build|handoff):/.test(o.label)) return { mrs: [], worktrees: [], done: ['A1'], deferred: [], needsDecision: [], needsEnvFix: [], localTest: { status: 'PASS', env: 'e', rounds: 1, failing: [], goalsDoc: 'g' }, needsLiveCheck: [], seed: [], foreignHooks: [], summary: 's', testerGuide: 'd', handoff: o.label.startsWith('build') ? handoff : '' }
  if (/^(test|handoff|retest)/.test(o.label)) return { code: o.label.split(':')[1], checks: [{ id: 'C1', subtask_id: 't', screen: 's', result: 'PASS', what_was_done: 'x', observed: 'y', evidence: [], attempts: 1 }], findings: [], setup_changes: [], data_created: [], handoff: '' }
  return { ok: true, output: '[]', signals: 0, lessonsChanged: [], json: '' } } } }
const pipeline = async (items, ...st) => Promise.all(items.map(async (a) => { let x = await st[0](a); for (const s of st.slice(1)) x = await s(x, a); return x }))
const run = (src, args, m) => new Function('args', 'agent', 'pipeline', 'parallel', 'log', 'phase', `return (async () => {\n${src}\n})()`)(args, m.agent, pipeline, async (f) => Promise.all(f.map((g) => g())), () => {}, () => {})
const B = readFileSync(process.argv[2], 'utf8'), T = readFileSync(process.argv[3], 'utf8')
const ba = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }, { id: 'X2', items: 'A2' }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
const m1 = mk('{"cap":100000,"estimate":500000,"stopAt":0.8}'); const o1 = await run(B, ba, m1)
console.log(`refuse:${o1.refused === true && o1.batch === 1 && o1.next.args.batch === 1 && !m1.calls.some((c) => /^build:/.test(c.label))}`)
const m2 = mk('{"cap":10000000,"estimate":100000,"stopAt":0.8}', 0, 'C:/b/handoff-X1.md'); const o2 = await run(B, { ...ba, agents: [ba.agents[0]] }, m2)
console.log(`handoff:${m2.calls.some((c) => c.label === 'handoff:X1' && /resume brief C:\/b\/handoff-X1\.md/.test(c.prompt)) && !o2.next}`)
const items = ['W1', 'W2', 'W3'].map((c) => ({ code: c, title: c, guideFile: 'g', lane: 'web', subtasks: [{ id: 't' }], skipClose: true }))
const m3 = mk('{"cap":1000000,"estimate":750000,"stopAt":0.8}', 900000); const o3 = await run(T, { runDir: 'C:/r/run1', kitDir: 'C:/kit', items, webParallel: 1, mandate: ['m'], learn: false, verify: false }, m3)
console.log(`stop-next:${o3.next && o3.next.args.only.join(',') === 'W2,W3' && m3.calls.some((c) => c.label === 'budget') && !m3.calls.some((c) => c.label === 'test:W2')}`)
'@
$wsf = Join-Path (Kd) 'wf-budget.mjs'; [IO.File]::WriteAllText($wsf, $wsim)
$strip = { param($n) [IO.File]::ReadAllText((Join-Path $src "workflows/$n")) -replace '(?m)^export const meta', 'const meta' }
$bsf = Join-Path (Kd) 'b.js'; $tsf = Join-Path (Kd) 't.js'; [IO.File]::WriteAllText($bsf, (& $strip 'buildy.js')); [IO.File]::WriteAllText($tsf, (& $strip 'testy.js'))
$res = @(node $wsf $bsf $tsf 2>&1)
Expect-Each $res 'workflow budget: #' @('refuse', 'handoff', 'stop-next') -Show 5
Remove-TestKit $k
Complete-Tests
