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
const up = await go('CONFIG {"roles":{},"qaLanes":null}', {}, (o) => { if (o.label === 'build:G1') throw new Error("You've hit your weekly limit · resets Dec 2, 8:30am") })
console.log(`limit-up:${(up.find((c) => c.label === 'build:G1@up') || {}).model === 'opus'}`)
const no = await go('CONFIG {"roles":{},"qaLanes":null}', {}, (o) => { if (o.label === 'build:G1') throw new Error('socket hang up') }).catch((e) => e.message)
console.log(`other-error:${no === 'socket hang up'}`)
// a resume replays the cached CONFIG step (balanced = sonnet then): args.config (today's kit.local.json) wins
const rz = await go('CONFIG {"tiers":{"balanced":"sonnet"},"roles":{},"qaLanes":null}', { config: { tiers: { balanced: 'opus' } } })
console.log(`resume-tiers:${rz.find((c) => c.label === 'build:G1').model === 'opus'}`)
const tr = (rz.find((c) => c.label === 'track:G1') || {}).prompt || ''
console.log(`track-script:${/track add -Discover -Mrs 'https:\/\/github\.com\/o\/storefront\/pull\/4,https:\/\/github\.com\/o\/core\/pull\/4'/.test(tr) && !/group the MRs/.test(tr)}`)
'@
Expect-Each (Invoke-Js w2-buildy $jsb $wfd) 'buildy: #' 'limit-up', 'other-error', 'resume-tiers', 'track-script' -Show 6
$jst = @'
const go = async (cfg, ex = {}, pre = null) => { const { calls, agent } = _mock((p, o) => /^test:/.test(o.label) ? _res('W1', [_ck('C2', 'PASS')]) : /^close/.test(o.label) ? _ok('published') : undefined)
 await run({ runDir: 'C:/runs/G', ..._kl, items: [_item('W1', '')], ...ex }, async (p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`) : (pre && pre(o)) || agent(p, o), _n, _n, null)
 return calls }
const rz = await go('CONFIG {"models":{"test":"strong"},"tiers":{"strong":"t-old"},"roles":{},"qaLanes":null}', { config: { tiers: { strong: 't-new' } } })
console.log(`resume-tiers:${(rz.find((x) => x.label === 'test:W1') || {}).model === 't-new'}`)
const lu = await go('CONFIG {"models":{"test":"balanced"},"roles":{},"qaLanes":null}', {}, (o) => { if (o.label === 'test:W1') throw new Error('usage_limit_reached: weekly limit') })
console.log(`limit-up:${(lu.find((x) => x.label === 'test:W1@up') || {}).model === 'opus'}`)
'@
Expect-Each (Invoke-Js w2-testy $jst $wf) 'testy: #' 'resume-tiers', 'limit-up' -Show 6
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
Remove-TestKit $k
Complete-Tests
