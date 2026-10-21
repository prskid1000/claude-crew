#Requires -Version 7
<#
tests.ps1 (extra duel): the buildy-duel.js sim: 2 POCs, compare, debate, owner judges, winner ships.
Usage: pwsh -NoProfile -File extras/duel/tests.ps1 -Kit <kit> (the workflow comes from files/ beside this file; the kit gives tests/harness.ps1).
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
. (Join-Path $Kit 'tests/harness.ps1')   # sets $src = $Kit
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
$k = New-TestKit duel
$wfd = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'files/workflows/buildy-duel.js')) -replace '^export const meta', 'const meta'
# buildy duel: 2 POCs, compare, debate, owner judges, winner ships
$jsu = @'
const lt = { status: 'PASS', env: 'shop r1', rounds: 1, failing: [], goalsDoc: 'g.md' }
const rep = (id) => _rep(lt, { mrs: [{ url: `https://h/g/api/-/merge_requests/${id === 'D2' ? 2 : 1}`, repo: 'api', merged: false }], worktrees: [`C:/wt/${id}`] })
const calls = []
async function agent(prompt, o) {
 calls.push({ label: o.label, agentType: o.agentType, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^duel:/.test(o.label)) return { approach: o.label.endsWith('D1') ? 'cache' : 'index', summary: 'poc', evidence: ['run.json'], worktrees: [`C:/wt/${o.label.slice(5)}`], branch: 'f/x-poc', localTest: 'PASS' }
 if (/^debate:/.test(o.label)) return { points: [{ claim: 'faster', evidence: '120 ms vs 300 ms' }], concede: [], rest: true }
 if (o.label === 'duel-compare' || o.label === 'duel-moderate') return { record: '| correctness | a | b |', unsupported: [], recommend: 'B' }
 if (o.label === 'duel-ask') return { ok: true, output: 'DECISION d-20261016000000-duel-ab12 pending' }
 if (o.label === 'duel-verdict') return { ok: true, output: 'ANSWERED d-20261016000000-duel-ab12: B, the index wins' }
 if (/^build:/.test(o.label)) return rep(o.label.slice(6))
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ci:/.test(o.label)) return { done: true, mrs: [{ mr: '2', status: 'success' }] }
 if (/^ship:/.test(o.label)) return { ...rep('D2'), ..._merged(2) }
 return _ok('[]')
}
const parallel = async (fns) => Promise.all(fns.map((f) => f()))
const args = { brief: 'C:/b/duel.md', mode: 'duel', duel: { question: 'cache or index?', rounds: 2 }, agents: [{ id: 'D1', items: 'A1', area: 'q' }, { id: 'D2', items: 'A1', area: 'q', dependsOn: ['D1'] }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
run(args, agent, _n, _n, pipeline, parallel).then((o) => {
 const deb = calls.filter((c) => /^debate:/.test(c.label))
 console.log(`duel-pocs:${calls.filter((c) => /^duel:D[12]$/.test(c.label) && c.agentType === 'devy').length === 2 && calls.some((c) => c.label === 'duel-compare' && c.agentType === 'revy')}`)
 console.log(`duel-debate:${deb.length === 2 && deb.every((c) => /board msg/.test(c.prompt))}`)
 console.log(`duel-judge:${o.duel && o.duel.winner === 'D2' && calls.some((c) => c.label === 'duel-ask' && /-Recommend B/.test(c.prompt)) && calls.some((c) => c.label === 'duel-close:D1')}`)
 console.log(`duel-ships-winner:${calls.some((c) => c.label === 'build:D2' && /DUEL WON/.test(c.prompt)) && !calls.some((c) => c.label === 'build:D1') && calls.some((c) => c.label === 'ship:D2')}`)
 console.log(`crew-only:${calls.every((c) => ['devy', 'revy', 'checky', 'kitty'].includes(c.agentType))}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js dw-duel $jsu $wfd) 'buildy duel: #' 'duel-pocs', 'duel-debate', 'duel-judge', 'duel-ships-winner', 'crew-only' -Show 5
Remove-TestKit $k
Complete-Tests
