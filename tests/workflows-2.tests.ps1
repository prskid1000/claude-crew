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
// default tiers are one model (fable): no next tier, the limit error surfaces, no @up retry on the same model
const same = await go('CONFIG {"roles":{},"qaLanes":null}', {}, lim).catch((e) => e.message)
console.log(`limit-same-tier:${/weekly limit/.test(String(same))}`)
const no = await go('CONFIG {"roles":{},"qaLanes":null}', {}, (o) => { if (o.label === 'build:G1') throw new Error('socket hang up') }).catch((e) => e.message)
console.log(`other-error:${no === 'socket hang up'}`)
// a resume replays the cached CONFIG step (balanced = sonnet then): args.config (today's kit.local.json) wins
const rz = await go('CONFIG {"tiers":{"balanced":"sonnet"},"roles":{},"qaLanes":null}', { config: { tiers: { balanced: 'opus' } } })
console.log(`resume-tiers:${rz.find((c) => c.label === 'build:G1').model === 'opus'}`)
const tr = (rz.find((c) => c.label === 'track:G1') || {}).prompt || ''
console.log(`track-script:${/track add -Discover -Mrs 'https:\/\/github\.com\/o\/storefront\/pull\/4,https:\/\/github\.com\/o\/core\/pull\/4'/.test(tr) && !/group the MRs/.test(tr)}`)
'@
Expect-Each (Invoke-Js w2-buildy $jsb $wfd) 'buildy: #' 'limit-up', 'limit-same-tier', 'other-error', 'resume-tiers', 'track-script' -Show 6
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
const ls = await go('CONFIG {"models":{"test":"balanced"},"roles":{},"qaLanes":null}', {}, lim).then((x) => x, (e) => [])
console.log(`limit-same-tier:${!ls.some((x) => x.label === 'test:W1@up')}`)
'@
Expect-Each (Invoke-Js w2-testy $jst $wf) 'testy: #' 'resume-tiers', 'limit-up', 'limit-same-tier' -Show 6
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
# owner 2026-11-26 "all agents to fable": every agent file, the example's claude tiers, the workflow tier defaults and tidy's steps
$notFable = @(Get-ChildItem (Join-Path $src 'agents') -Filter *.md | Where-Object { (Get-Content $_.FullName -Raw) -notmatch '(?m)^model: fable\r?$' } | ForEach-Object Name)
$exTiers = (Get-Content (Join-Path $src 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).models.tiers.claude
$wfOld = @('buildy.js', 'testy.js', 'tidy.js' | Where-Object { (Get-Content (Join-Path $src "workflows/$_") -Raw) -match "'(sonnet|opus|haiku)'|/(sonnet|opus|haiku):" })
Expect "models: every agent file, models.tiers.claude and the workflow defaults = fable; the schema takes it ($($notFable -join ',') $($wfOld -join ','))" (-not $notFable -and -not $wfOld -and
  "$($exTiers.fast)/$($exTiers.balanced)/$($exTiers.strong)" -eq 'fable/fable/fable' -and (Get-Content (Join-Path $src 'workflows/tidy.js') -Raw) -match "label: 'apply'[^\n]*agentType: 'kitty', model: 'fable'" -and
  (Get-Content (Join-Path $src 'skills/bossy/kitbag.py') -Raw) -match "'enum': \['fable'," -and (Get-Content (Join-Path $src 'skills/bossy/SKILL.md') -Raw) -notmatch 'sonnet|haiku')
Remove-TestKit $k
Complete-Tests
