#Requires -Version 7
<#
workflows-2.tests.ps1: buildy.js / testy.js step wrappers and resume config (workflows-generic.tests.ps1 is at its cap): a usage
limit runs a step once on the next tier (<label>@up), args.config (bossy.ps1 recover) beats the cached CONFIG tiers, the
tracker step is one track add (script groups MRs by title), a tester step with no result retries once.
Usage: pwsh -NoProfile -File <kit>/tests/workflows-2.tests.ps1 (or tests/kit-tests.ps1 -Area workflows-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit workflows-2
$wfd = Join-Path $src 'workflows/buildy.js'; $wf = Join-Path $src 'workflows/testy.js'
# owner 2026-11-26 (Sonnet weekly limit): a usage limit on a tier -> the step once on the next tier, not the stage failing
$jsb = @'
const mr = (r) => ({ url: `https://github.com/o/${r}/pull/4`, repo: '', merged: false }), lt = { status: 'PASS' }
const go = async (cfg, ex = {}, pre = null) => { const m = _mock((p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`) : /^(build|ship):G1/.test(o.label) ? _rep(lt, { mrs: [mr('storefront'), mr('core')] }) : /^review/.test(o.label) ? { findings: [] } : undefined, '[]')
 const a = async (p, o) => /^record-args/.test(o.label) ? (m.calls.push({ label: o.label, model: o.model, prompt: p }), _ok(`RECORDED\n${cfg}`)) : (pre && pre(o)) || m.agent(p, o)
 await run({ brief: 'C:/b/g.md', ..._kl, agents: [{ id: 'G1' }], ...ex }, a, _n, _n, pipeline); return m.calls }
const lim = (o) => { if (o.label === 'build:G1') throw new Error("You've hit your weekly limit · resets Dec 2, 8:30am") }
const up = await go('CONFIG {"tiers":{"balanced":"t-b","strong":"t-s"},"roles":{},"qaLanes":null}', {}, lim)
console.log(`limit-up:${(up.find((c) => c.label === 'build:G1@up') || {}).model === 't-s'}`)
// one model in every tier (a models.override): no next tier, the limit error surfaces, no @up retry on the same model
const same = await go('CONFIG {"tiers":{"fast":"t-x","balanced":"t-x","strong":"t-x"},"roles":{},"qaLanes":null}', {}, lim).catch((e) => e.message)
console.log(`limit-same-tier:${/weekly limit/.test(String(same))}`)
const no = await go('CONFIG {"roles":{},"qaLanes":null}', {}, (o) => { if (o.label === 'build:G1') throw new Error('socket hang up') }).catch((e) => e.message)
console.log(`other-error:${no === 'socket hang up'}`)
// a resume replays the cached CONFIG step (balanced = sonnet then): args.config (today's kit.local.json) wins
const rz = await go('CONFIG {"tiers":{"balanced":"sonnet"},"roles":{},"qaLanes":null}', { config: { tiers: { balanced: 'opus' } } })
console.log(`resume-tiers:${rz.find((c) => c.label === 'build:G1').model === 'opus'}`)
const tr = (rz.find((c) => c.label === 'track:G1') || {}).prompt || ''
console.log(`track-script:${/track add -Discover -Mrs 'https:\/\/github\.com\/o\/storefront\/pull\/4,https:\/\/github\.com\/o\/core\/pull\/4'/.test(tr) && !/group the MRs/.test(tr)}`)
// 2026-11-26 (two runs on default models under a models.override): a record-args step that re-words the CONFIG line is asked again on
// the retry model; twice = the run stops, never default models; args.config tiers hold from step 0
const rw = [], mw = _mock((p, o) => /^(build|ship):G1/.test(o.label) ? _rep(lt, { mrs: [mr('core')] }) : /^review/.test(o.label) ? { findings: [] } : undefined, '[]')
const aw = async (p, o) => /^record-args/.test(o.label) ? (rw.push(`${o.label}=${o.model}`), _ok(rw.length > 1 ? 'RECORDED\nCONFIG {"tiers":{"balanced":"t-b"},"roles":{}}' : 'RECORDED x (fnv 1).\nCONFIG models: strong/balanced/fast all map to t-b; humanDoc true.')) : mw.agent(p, o)
await run({ brief: 'C:/b/g.md', ..._kl, agents: [{ id: 'G1' }], config: { tiers: { fast: 't-f0' } } }, aw, _n, _n, pipeline)
const dead = await run({ brief: 'C:/b/g.md', ..._kl, agents: [{ id: 'G1' }] }, async (p, o) => /^record-args/.test(o.label) ? _ok('RECORDED x (fnv 1).\nCONFIG models: strong/balanced/fast all map to t-b; humanDoc true.') : _ok('[]'), _n, _n, pipeline).then(() => 'ran', (e) => String(e.message))
console.log(`config-reworded:${rw.join(',') === 'record-args=t-f0,record-args-retry=sonnet' && mw.calls.find((c) => c.label === 'build:G1').model === 't-b' && /re-worded twice: not started/.test(dead)}`)
// 2026-11-26 (review of the CONFIG fix): a re-worded BUDGET line, a shortened CONFIG (valid JSON, another SUM), a dropped BUDGET or
// RECORDED line is asked again, twice = stop: never a run without its budget gate; the lines relayed whole pass
const _B = 'BUDGET {"cap":1000000,"estimate":10,"stopAt":0.8}', _C = 'CONFIG {"tiers":{"balanced":"t-b"},"roles":{"api":"producer"}}', _S = `SUM ${_sum(`${_B}\n${_C}`)}`
const _stop = (out) => run({ brief: 'C:/b/g.md', ..._kl, agents: [{ id: 'G1' }] }, async (p, o) => /^record-args/.test(o.label) ? _ok(out) : _ok('[]'), _n, _n, pipeline).then(() => 'ran', (e) => String(e.message))
const _sb = [await _stop(`RECORDED x\nBUDGET cap 1000000, estimate 10 (80%)\n${_C}\n${_S}`), await _stop(`RECORDED x\n${_B}\nCONFIG {"tiers":{"balanced":"t-b"}}\n${_S}`), await _stop(`RECORDED x\n${_C}\n${_S}`), await _stop(`${_B}\n${_C}\n${_S}`)]
console.log(`budget-reworded:${_sb.every((x) => /re-worded twice: not started/.test(x)) && !/re-worded/.test(await _stop(`RECORDED x\n${_B}\n${_C}\n${_S}`))}`)
'@
Expect-Each (Invoke-Js w2-buildy $jsb $wfd) 'buildy: #' 'limit-up', 'limit-same-tier', 'other-error', 'resume-tiers', 'track-script', 'config-reworded', 'budget-reworded' -Show 6
# owner 2026-11-26: a pending decision on A2 never holds the review of A1's MR (mrs[].items); a changed head is reviewed again
$jse = @'
const mA = { url: 'https://h/g/api/-/merge_requests/1', repo: 'api', merged: false, items: ['A1'], head: 'h1' }, mB = { ...mA, url: 'https://h/g/api/-/merge_requests/2', items: ['A2'], head: 'h2' }
const P = { status: 'PASS', failing: [] }, mrOf = (l) => [1, 2].filter((n) => new RegExp(`merge_requests/${n}\\b`).test(l.prompt))
const go = async (fix) => { const calls = [], n = (l) => calls.filter((c) => c.label === l).length
 const agent = async (p, o) => { calls.push({ label: o.label, prompt: p })
  if (/^record-args/.test(o.label)) return _rec()
  if (o.label === 'build:E1') return _rep(P, { mrs: [mA, mB], needsDecision: [{ item: 'A2', decisionId: 'd-20260101000000-x', question: 'q' }] })
  if (/^decide:/.test(o.label)) return { ok: true, output: 'ANSWERED d-20260101000000-x: A' }
  if (/^fix:E1/.test(o.label)) return _rep(P, { mrs: [mA, { ...mB, head: 'h4' }] })
  if (/^(resume|ship):E1/.test(o.label)) return _rep(P, { mrs: [mA, { ...mB, head: 'h3' }] })
  if (o.label === 'review:E1' && n('review:E1') === 1) return { findings: [{ mr: 'api!1', file: 'a.ts', severity: 'nit', problem: 'p', fix: 'f' }] }
  if (o.label === 'review:E1' && n('review:E1') === 2 && fix) return { findings: [{ mr: 'api!2', file: 'b.ts', severity: 'blocking', problem: 'p', fix: 'f' }] }
  return /^review/.test(o.label) ? { findings: [] } : /^ci:/.test(o.label) ? { done: true, mrs: [] } : _ok('[]') }
 return { calls, out: await run({ brief: 'C:/b/e.md', ..._kl, agents: [{ id: 'E1', items: 'A1,A2' }] }, agent, _n, _n, pipeline) } }
const sp = (c) => (c.find((x) => x.label === 'ship:E1') || {}).prompt || '', pin = /merge_requests\/1 \([^)]*; merge --head h1\)/
go(false).then(async ({ calls, out }) => {
 const rv = calls.filter((c) => c.label === 'review:E1'), fs = (out.agents[0] || {}).findings || []
 console.log(`early-review:${rv.length === 2 && mrOf(rv[0]) + '' === '1' && mrOf(rv[1]) + '' === '2' && fs.some((f) => f.mr === 'api!1')}`)
 console.log(`head-pin:${pin.test(sp(calls)) && !/--head h3/.test(sp(calls))}`)
 const f = (await go(true)).calls
 console.log(`head-pin-fix:${f.some((c) => /^fix:E1/.test(c.label)) && pin.test(sp(f)) && !/--head h[34]/.test(sp(f))}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js w2-early $jse $wfd) 'buildy decision wait: # (review:E1 MRs: early !1, after the answer only !2, its head changed; an early finding naming api!1 kept; the ship prompt pins !1 to its reviewed head)' 'early-review', 'head-pin', 'head-pin-fix' -Show 8
$jst = @'
const go = async (cfg, ex = {}, pre = null) => { const { calls, agent } = _mock((p, o) => /^test:/.test(o.label) ? _res('W1', [_ck('C2', 'PASS')]) : /^close/.test(o.label) ? _ok('published') : undefined)
 await run({ runDir: 'C:/runs/G', ..._kl, items: [_item('W1', '')], ...ex }, async (p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`) : (pre && pre(o)) || agent(p, o), _n, _n, null)
 return calls }
const rz = await go('CONFIG {"models":{"test":"strong"},"tiers":{"strong":"t-old"},"roles":{},"qaLanes":null}', { config: { tiers: { strong: 't-new' } } })
console.log(`resume-tiers:${(rz.find((x) => x.label === 'test:W1') || {}).model === 't-new'}`)
const lim = (o) => { if (o.label === 'test:W1') throw new Error('usage_limit_reached: weekly limit') }
const lu = await go('CONFIG {"models":{"test":"balanced"},"tiers":{"balanced":"t-b","strong":"t-s"},"roles":{},"qaLanes":null}', {}, lim)
console.log(`limit-up:${(lu.find((x) => x.label === 'test:W1@up') || {}).model === 't-s'}`)
const ls = await go('CONFIG {"tiers":{"fast":"t-x","balanced":"t-x","strong":"t-x"},"models":{"test":"balanced"},"roles":{},"qaLanes":null}', {}, lim).then((x) => x, (e) => [])
console.log(`limit-same-tier:${!ls.some((x) => x.label === 'test:W1@up')}`)
const tw = [], bad = async (p, o) => /^record-args/.test(o.label) ? (tw.push(`${o.label}=${o.model}`), _ok('RECORDED x (fnv 1).\nCONFIG models: strong/balanced/fast all map to t-b; humanDoc true.')) : _ok('[]')
const td = await run({ runDir: 'C:/runs/G', ..._kl, items: [_item('W1', '')], config: { tiers: { fast: 't-f0', balanced: 't-b0' } } }, bad, _n, _n, null).then(() => 'ran', (e) => String(e.message))
console.log(`config-reworded:${tw.join(',') === 'record-args=t-f0,record-args-retry=t-b0' && /re-worded twice: not started/.test(td)}`)
// 2026-11-26 (review of the CONFIG fix): a re-worded BUDGET line, a shortened CONFIG (valid JSON, another SUM), a dropped BUDGET or
// RECORDED line is asked again, twice = stop: never a run without its budget gate; the lines relayed whole pass
const _B = 'BUDGET {"cap":1000000,"estimate":10,"stopAt":0.8}', _C = 'CONFIG {"tiers":{"balanced":"t-b"},"roles":{"api":"producer"}}', _S = `SUM ${_sum(`${_B}\n${_C}`)}`
const _stop = (out) => run({ runDir: 'C:/runs/G', ..._kl, items: [_item('W1', '')] }, async (p, o) => /^record-args/.test(o.label) ? _ok(out) : _ok('[]'), _n, _n, null).then(() => 'ran', (e) => String(e.message))
const _sb = [await _stop(`RECORDED x\nBUDGET cap 1000000, estimate 10 (80%)\n${_C}\n${_S}`), await _stop(`RECORDED x\n${_B}\nCONFIG {"tiers":{"balanced":"t-b"}}\n${_S}`), await _stop(`RECORDED x\n${_C}\n${_S}`), await _stop(`${_B}\n${_C}\n${_S}`)]
console.log(`budget-reworded:${_sb.every((x) => /re-worded twice: not started/.test(x)) && !/re-worded/.test(await _stop(`RECORDED x\n${_B}\n${_C}\n${_S}`))}`)
'@
Expect-Each (Invoke-Js w2-testy $jst $wf) 'testy: #' 'resume-tiers', 'limit-up', 'limit-same-tier', 'config-reworded', 'budget-reworded' -Show 6
# step retry (2026-11-25 login race): a tester step with no result runs once more as <label>~retry1; close (publishes) never
$jsSr = @'
const labels = []
const agent = async (p, o) => { labels.push(o.label)
 if (/^record-args/.test(o.label)) return _rec()
 if (o.label === 'test:S1' || /^close:S2/.test(o.label)) return null
 return /^test:/.test(o.label) ? _res(o.label.slice(5, 7), [_ck('C1', 'PASS')]) : _ok('published') }
run({ runDir: 'C:/runs/R8', ..._kl, verify: false, items: [_item('S1'), _item('S2')] }, agent, _n, _n, null).then(() => {
 console.log(`sr-once:${labels.includes('test:S1~retry1') && labels.includes('close-retry:S2') && !labels.some((l) => /close.*~retry|~retry2/.test(l))}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-stepretry $jsSr $wf) 'workflow step retry: #' 'sr-once' -Show 8
# owner 2026-11-26 (dec-stage-model A, speed fixes): the stage -> tier map; should-fix -> Follow-ups, no fix round; repos[].appendOnly = one merge at a time
$jsS = @'
const P = { status: 'PASS', failing: [] }, mrOf = (n, st) => ({ url: `https://h/g/api/-/merge_requests/${n}`, repo: 'api', merged: false, mergeState: st })
const F = (severity, problem) => ({ mr: 'api!1', file: 'a.ts', severity, problem, fix: 'f' })
const go = async (cfg, ags, rv = [], bad = '', boom = false) => { const calls = [], order = [], seen = {}
 const agent = async (p, o) => { calls.push({ label: o.label, model: o.model, prompt: p }); const n = Number((/:S(\d)/.exec(o.label) || [0, 1])[1])
  if (/^record-args/.test(o.label)) return _ok(`RECORDED\n${cfg}`)
  if (/^ci:/.test(o.label)) return { done: true, mrs: [] }
  if (/^review/.test(o.label)) return { findings: seen[o.label]++ ? [] : (seen[o.label] = 1, rv) }
  if (o.label.startsWith(bad) && bad) { order.push('bad'); if (boom) throw new Error('ship died'); return null }
  if (/^ship:/.test(o.label)) { order.push(`ship${n}`); return _rep(P, { mrs: [mrOf(n, 'SCHEDULED')] }) }
  if (/^merge-wait:/.test(o.label)) { order.push(`merged${n}`); return _ok(JSON.stringify({ mrs: [{ mr: mrOf(n).url, status: 'merged' }] })) }
  return /^(build|fix):/.test(o.label) ? _rep(P, { mrs: [mrOf(n)] }) : _ok('[]') }
 const out = await run({ brief: 'C:/b/s.md', ..._kl, phases: false, agents: ags }, agent, _n, _n, pipeline).catch((e) => ({ err: e.message }))
 await new Promise((ok) => setImmediate(ok)); return { calls, order, out } }
const two = [{ id: 'S1', items: 'A1' }, { id: 'S2', items: 'A2', complex: true }], md = (r, l) => (r.calls.find((c) => c.label === l) || {}).model, pr = (r, l) => (r.calls.find((c) => c.label === l) || {}).prompt || ''
const d = await go('CONFIG {"roles":{},"qaLanes":null}', [...two, { id: 'S3', items: 'A3', model: 'm-flagged' }])
console.log(`stage-map:${['build:S1', 'build:S2', 'build:S3', 'review:S1', 'ci:S1', 'ship:S1', 'track:S1'].map((l) => md(d, l)).join() === 'sonnet,sonnet,m-flagged,opus,haiku,haiku,haiku'}`)
console.log(`parallel-merge:${d.order.slice(0, 2).join() === 'ship1,ship2' && !d.calls.some((c) => /^merge-wait/.test(c.label))}`)
const s = await go('CONFIG {"roles":{},"qaLanes":null,"serial":["api"]}', two)
console.log(`serial-merge:${s.order.join() === 'ship1,merged1,ship2,merged2' && /pipes -Mrs \S+merge_requests\/1 -MaxMinutes 9 -UntilMerged/.test(pr(s, 'merge-wait:S1'))}`)
const sf = await go('CONFIG {"roles":{},"qaLanes":null}', [two[0]], [F('should-fix', 'soft-p'), F('nit', 'nit-p')])
console.log(`should-fix-followup:${!sf.calls.some((c) => /^fix:/.test(c.label)) && /soft-p/.test(pr(sf, 'followups:S1')) && !/nit-p/.test(pr(sf, 'followups:S1')) && sf.order.join() === 'ship1' && sf.out.followUps.length === 1 && !sf.out.openFindings.length}`)
const bl = await go('CONFIG {"roles":{},"qaLanes":null}', [two[0]], [F('should-fix', 'soft-p'), F('blocking', 'hard-p')])
const sn = await go('CONFIG {"roles":{},"qaLanes":null,"serial":["api"]}', two, [], 'ship:S1'), st = await go('CONFIG {"roles":{},"qaLanes":null,"serial":["api"]}', two, [], 'ship:S1', true)
console.log(`serial-after-failure:${sn.order.join() === 'bad,bad,ship2,merged2' && st.out.err === 'ship died' && st.order.join() === 'bad,ship2,merged2'}`)
const nf = await go('CONFIG {"roles":{},"qaLanes":null}', [two[0]], [F('should-fix', 'soft-p'), F('blocking', 'hard-p')], 'fix:S1')
console.log(`stopped-fix-keeps-soft:${nf.out.agents[0].stopped === true && nf.out.followUps.length === 1 && nf.out.followUps[0].problem === 'soft-p' && nf.out.followUps[0].written === false}`)
console.log(`blocking-fix:${/hard-p/.test(pr(bl, 'fix:S1')) && !/soft-p/.test(pr(bl, 'fix:S1')) && /soft-p/.test(pr(bl, 'followups:S1')) && bl.order.join() === 'ship1'}`)
'@
Expect-Each (Invoke-Js w2-stage $jsS $wfd) 'buildy 2026-11-26: # (map: build / complex sonnet, a brief model wins, review opus, ci / ship / track haiku; serial: the next area ships after the first merged)' 'stage-map', 'parallel-merge', 'serial-merge', 'should-fix-followup', 'serial-after-failure', 'stopped-fix-keeps-soft', 'blocking-fix' -Show 8
$jsV = @'
const { calls, agent } = _mock((p, o) => /^test:/.test(o.label) ? _res('W1', [_ck('C1', 'FAIL'), _ck('C2', 'PASS_WITH_NOTE')]) : /^close/.test(o.label) ? _ok('published') : undefined)
await run({ runDir: 'C:/runs/V', ..._kl, items: [_item('W1', '')] }, async (p, o) => /^record-args/.test(o.label) ? _ok('RECORDED\nCONFIG {"roles":{},"qaLanes":null}') : agent(p, o), _n, _n, null).catch(_err)
const md = (rx) => (calls.find((c) => rx.test(c.label)) || {}).model
console.log(`stage-map:${[/^test:W1/, /^verify:W1/, /^audit:W1/, /^(close|hold):W1/].map(md).join()}`)
'@
$stV = @(Invoke-Js w2-stage-testy $jsV $wf) -join ' '
Expect "testy 2026-11-26 stage map: test sonnet, verify and audit opus, close haiku ($stV)" ($stV -match 'stage-map:sonnet,opus,opus,haiku')
$O = Join-Path $k 'skills/bossy/bossy.ps1'
$sr = Invoke-PsTest serial @'
$null = . $args[0] 6>$null
$__cfg = [pscustomobject]@{ repos = @([pscustomobject]@{ name = 'api'; aliases = @('Core'); appendOnly = @('**/changelog-master.xml') }, [pscustomobject]@{ name = 'web'; appendOnly = @() }, [pscustomobject]@{ name = 'app' }) }
"serial:$((Get-KitWorkflowConfig).serial -join ',')"
'@ @($O)
Expect "CONFIG serial: the names and aliases of repos with appendOnly globs, lower case ($sr)" ("$sr" -match 'serial:api,core$' -and (Get-Content (Join-Path $src 'agents/revy.md') -Raw) -match '(?m)^model: opus\r?$')
# owner 2026-11-26: "all on fable until Monday" = models.override {model, until}, never new defaults; KIT_NOW is the fake clock
$ovPy = Join-Path (Kd) 'ov.py'
"import sys; sys.path.insert(0, sys.argv[1]); import video; o = {'override': {'model': 'm-all', 'until': '2026-11-30T00:00+05:30'}}`nprint('|'.join([video.model_override(o, '2026-11-29T23:59+05:30'), video.model_override(o, '2026-11-30T00:01+05:30'), video.model_override({'override': {'model': 'm-all'}}), video.model_override({'override': 'm-all'}), video.model_override({'override': {'model': 'm-all', 'until': '20261130'}}, '2026-11-29T23:59+05:30')]))" | Set-Content $ovPy
$ovV = python -X utf8 $ovPy (Join-Path $src 'skills/pokey') | Out-String
$ov = Invoke-PsTest ov @'
$null = . $args[0] 6>$null; $env:KIT_TOOL = 'claude'
$__cfg = [pscustomobject]@{ models = [pscustomobject]@{ build = 'm-own'; docs = 'fast'; retestEffort = 'high'; override = [pscustomobject]@{ model = 'm-all'; until = '2026-11-30T00:00+05:30' } } }
foreach ($now in '2026-11-29T23:59+05:30', '2026-11-30T00:01+05:30') { $env:KIT_NOW = $now; $t = Get-KitTiers claude; $c = Get-KitWorkflowConfig; $f = @(Get-KitSuperviseFlagsModelOverride)
  "$($t.fast)/$($t.balanced)/$($t.strong)/$($t.inherit)|$($c.models.build)/$($c.models.docs)/$($c.models.retestEffort)|$($c.tiers.strong)|$((Get-KitTiers codex).strong)|$($f.what)" }
$env:KIT_NOW = '2026-11-29T23:59+05:30'; $d = [pscustomobject]@{ at = (Get-Date); rows = @(); flags = @(Get-KitSuperviseFlagsModelOverride) }
"brief:$(@(Format-KitSuperviseOut $d @() 'C:/r/supervise-report.html') -match '^INFO · model override m-all until')"
"sites:$(Get-KitModelNote)|$(Get-KitModelArg)|$(Resolve-KitPlanModel 'sonnet' 'claude')/$(Resolve-KitPlanModel 'inherit' 'claude')/$(Resolve-KitPlanModel 'gpt-5.5' 'codex')|$((Get-KitPlanCap 'devy/@build=sonnet:1' claude).cap -eq (Get-KitPlanCap 'devy/m-all:1' claude).cap)"
"action:$("$($d.flags[0].action)" -match "as the LAST key: config: \{ tiers: \{ fast: 'm-all', balanced: 'm-all', strong: 'm-all' \} \}")"
# recover's args + config: a config in the middle keeps every key after it (the appended one wins), a last one is replaced, tidy untouched
$mid = Add-KitResumeConfig '{"brief":"C:/b.md","config":{"tiers":{"fast":"x"}},"agents":[{"id":"A1"}],"local":{"lane":"r4"}}' 'buildy.js'
$last = Add-KitResumeConfig '{"brief":"C:/b.md","agents":[{"id":"A1"}],"config":{"tiers":{"fast":"x"},"models":{"tiers":{"claude":{"fast":"y"}}}}}' 'testy.js'
"resume:$($mid -match '"agents":\[\{"id":"A1"\}\],"local":\{"lane":"r4"\},"config":')/$(($mid | ConvertFrom-Json -AsHashtable).config.tiers.fast)/$([regex]::Matches($last, '"config":').Count)/$(($last | ConvertFrom-Json).config.tiers.fast)/$(Add-KitResumeConfig '{"a":1}' 'tidy.js')"
foreach ($u in ('{"u":"2026-11-30T00:00:00+05:30"}' | ConvertFrom-Json).u, '30 Nov 2026', '') { $__cfg.models.override.until = $u; "until:$([bool](Get-KitModelOverride))" }
$__cfg.models.override = 'm-all'; "string:$([bool](Get-KitModelOverride))"
'@ @($O)
$exM = (Get-Content (Join-Path $src 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).models
Expect "models.override: before until every claude tier and model id = the model (tier names, efforts, codex untouched), supervise says so; after it the config again; python the same; defaults unchanged ($($ov -join ' // ') $($ovV.Trim()))" (
  $ov[0] -eq 'm-all/m-all/m-all/|m-all/fast/high|m-all|gpt-5.5|model override m-all until 2026-11-30 00:00 +05:30' -and $ov[1] -eq 'haiku/sonnet/opus/|m-own/fast/high|opus|gpt-5.5|' -and $ovV.Trim() -eq 'm-all||||' -and
  ($ov -join ' ') -match 'brief:INFO · model override' -and ($ov -join ' ') -match "sites:MODEL m-all until 2026-11-30 00:00 \+05:30: pass model: 'm-all'[^|]*\|, model: 'm-all'\|m-all/inherit/gpt-5\.5\|True" -and ($ov -join ' ') -match 'until:True until:False until:False string:False' -and ($ov -join ' ') -match 'action:True resume:True/m-all/1/m-all/\{"a":1\} ' -and
  "$($exM.tiers.claude.fast)/$($exM.tiers.claude.strong)/$($exM.override.model)" -eq 'haiku/opus/' -and (Get-Content (Join-Path $src 'agents/devy.md') -Raw) -match '(?m)^model: sonnet\r?$')
Remove-TestKit $k
Complete-Tests
