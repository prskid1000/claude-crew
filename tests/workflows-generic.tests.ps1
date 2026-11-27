#Requires -Version 7
<#
workflows-generic.tests.ps1: buildy.js / testy.js on neutral and custom config (CONFIG line of launch -Self): repo roles, qa.lanes, models.<phase>, model tiers per tool;
testy.js resultsPatch -> pokey.ps1 results patch / hold; tidy.js run name, parity next proposals, judge retry.
Usage: pwsh -NoProfile -File <kit>/tests/workflows-generic.tests.ps1 (or tests/kit-tests.ps1 -Area workflows-generic).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit workflows-generic; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$wfd = Join-Path $src 'workflows/buildy.js'; $wf = Join-Path $src 'workflows/testy.js'
# buildy deploy batch: skipped without adapters/deploys.ps1, else parsed
$jsdp = @'
const mk = (out, seen) => async (p, o) => { if (o.label === 'deploy-batch') { seen.push(p); return { ok: true, output: out } }
 return _pass(p, o) }
const base = { brief: 'C:/b/w.md', ..._kl, agents: [{ id: 'X1', items: 'A1' }] }
const logs = [], seen = []
const a = await run(base, mk('NO-DEPLOYS', seen), (m) => logs.push(m), _n, pipeline)
const b = await run(base, mk('[{"target":"t1","trigger":"owner"}]', []), _n, _n, pipeline)
console.log(`deploy-skip:${!a.deployBatch && logs.some((l) => /no deploys adapter in this kit/.test(l)) && seen[0].includes("Test-Path 'C:/kit/skills/bossy/adapters/deploys.ps1'")}`)
console.log(`deploy-batch:${Array.isArray(b.deployBatch) && b.deployBatch[0].target === 't1'}`)
console.log(`deploy-quick:${/ -Json -Quiet \}/.test(seen[0]) && !/tool timeout/.test(seen[0])}`)
'@
Expect-Each (Invoke-Js dw-deploy $jsdp $wfd) 'buildy deploy: # (quick: request -Quiet records only; the plan ran up to 594 s, 2026-11-26)' 'deploy-skip', 'deploy-batch', 'deploy-quick' -Show 5
# buildy: localTest NONE never merges a code area (an MR merged without one, 2026-11-21) unless the owner allowed it (decisionId); kind doc needs no loop
$jsn0 = @'
const none = (extra = {}) => ({ status: 'NONE', env: 'none: no local env', rounds: 0, failing: [], goalsDoc: '', ...extra }), logs = []
const { calls, agent } = _mock((p, o) => {
 if (o.label === 'build:N3') return _rep(none({ decisionId: 'd-20261121120000-owner-ab12' }))
 if (o.label === 'build:N4') return _rep(none({ decisionId: 'ok' }))
 if (o.label === 'build:N5') return _rep(none({ decisionId: 'd-20261121120000-owner-cd34' }))
 if (o.label === 'none-word:N3') return _ok('WORD d-20261121120000-owner-ab12 (merge A3): "ship it" by owner via chat at t | question: q')
 if (o.label === 'none-word:N5') return { ok: false, output: 'NO-WORD id d-20261121120000-owner-cd34: d-20261121120000-owner-cd34 answered by devy-x, no person' }
 if (/^(build|local):/.test(o.label)) return _rep(none())
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ship:/.test(o.label)) return _rep(none(), _merged(1))
}, '[]')
const o = await run({ brief: 'C:/b/w.md', mandate: ['m'], ..._kl, agents: [{ id: 'N1', items: 'A1' }, { id: 'N2', items: 'A2', kind: 'doc' }, { id: 'N3', items: 'A3' }, { id: 'N4', items: 'A4' }, { id: 'N5', items: 'A5' }] }, agent, (m) => logs.push(m), _n, pipeline)
const L = calls.map((c) => c.label)
console.log(`none-verified:${L.includes('none-word:N5') && !L.includes('ship:N5') && calls.find((c) => c.label === 'none-word:N3').prompt.includes("decide check -Id d-20261121120000-owner-ab12 -Gate 'merge,scope,other' -Item 'N3,A3,api!1")
 && logs.some((l) => /N5: .*refused \(NO-WORD/.test(l))}`)
console.log(`none-held:${!L.includes('review:N1') && !L.includes('ship:N1') && o.blocked.some((b) => b.agent === 'N1' && /local test NONE/.test(b.why))}`)
console.log(`none-doc:${L.includes('ship:N2')}`)
console.log(`none-local:${L.filter((l) => l === 'local:N1').length === 1 && !L.includes('local:N2') && !L.includes('local:N3') && logs.some((l) => /N1: reported done with no local loop/.test(l))}`)
console.log(`none-decided:${L.includes('ship:N3') && !L.includes('ship:N4')}`)
'@
Expect-Each (Invoke-Js dw-none $jsn0 $wfd) 'buildy merge gate: localTest NONE # (a code area held, kind doc and a person''s merge word ship; a made-up id or a NO-WORD from decide check -Gate merge,scope,other -Item <area keys> not, 2026-11-21)' 'none-held', 'none-doc', 'none-decided', 'none-verified', 'none-local' -Show 8
# repos[].localTest optional / none (CONFIG local): NONE + localFallback ships with no decision; required (unset) or unit without its run: held
$jslf = @'
const UR = { command: 'crafty.ps1 check -Dir C:/w', result: 'PASS 12 tests' }, lt = (fb, ur) => ({ status: 'NONE', env: 'none: no local env', rounds: 0, failing: [], goalsDoc: '', ...(fb ? { fallback: fb } : {}), ...(ur ? { unitRun: ur } : {}) })
const go = async (cfg, fb, ur) => { const m = _mock((p, o) => /^(build|ship):F1/.test(o.label) ? _rep(lt(fb, ur)) : /^review/.test(o.label) ? { findings: [] } : undefined, '[]')
 const a = async (p, o) => /^record-args/.test(o.label) ? (m.calls.push({ label: o.label, prompt: p }), _ok(`RECORDED\nCONFIG {"roles":{},"local":${cfg}}`)) : m.agent(p, o)
 await run({ brief: 'C:/b/f.md', mandate: ['m'], ..._kl, agents: [{ id: 'F1', items: 'A1' }] }, a, _n, _n, pipeline); return m.calls.map((c) => c.label) }
const ci = await go('{"api":"ci"}', 'ci'), unit = await go('{"api":"unit"}', 'unit', UR), unitBare = await go('{"api":"unit"}', 'unit'), unitFail = await go('{"api":"unit"}', 'unit', { ...UR, result: '3 failed' }), unitCi = await go('{"api":"unit"}', 'ci'), req = await go('{}', 'ci')
console.log(`fallback-ci:${ci.includes('ship:F1') && !ci.some((l) => /^none-word/.test(l))}`)
console.log(`fallback-unit:${unit.includes('ship:F1') && !unitCi.includes('ship:F1') && !unitBare.includes('ship:F1') && !unitFail.includes('ship:F1')}`)   // RF: unit needs its passed run
console.log(`required-held:${!req.includes('ship:F1') && !req.includes('review:F1')}`)
'@
$lcR = & { . $O; $__cfg = '{"repos":[{"name":"api","aliases":["be"],"localTest":"none"},{"name":"web","localTest":"optional","localFallback":"unit"},{"name":"app","localTest":"none","ci":{"mrPipelines":false}},{"name":"core"}]}' | ConvertFrom-Json; $wc = Get-KitWorkflowConfig; "$($wc.local | ConvertTo-Json -Compress) $($wc.humanDoc)"
  $__cfg = '{"process":{"docs":[{"key":"testing-ai","label":"AI"}]}}' | ConvertFrom-Json; "$((Get-KitWorkflowConfig).humanDoc)" }
Expect "launch CONFIG: local = repos[].localTest optional / none -> localFallback (no MR pipelines -> unit), required repos absent; humanDoc follows process.docs ($lcR)" ("$lcR" -eq '{"api":"ci","be":"ci","web":"unit","app":"unit"} True False')
Expect-Each (Invoke-Js dw-fallback $jslf $wfd) 'buildy merge gate: repos[].localTest # (a repo without a local env merges on CI + review, ours stay required)' 'fallback-ci', 'fallback-unit', 'required-held' -Show 6
# buildy kind foundation (no human-facing change): no human doc asked, merge passes the docs gate with --no-docs, the report says exempt (2026-11-21: 5 consumer areas never started)
$jsfd = @'
const pass = { status: 'PASS', failing: [] }, logs = []
const { calls, agent } = _mock((p, o) => /^build:/.test(o.label) ? _rep(pass) : /^ship:/.test(o.label) ? _rep(pass, _merged(1)) : /^review:/.test(o.label) ? { findings: [] } : undefined, '[]')
const o = await run({ brief: 'C:/b/w.md', mandate: ['m'], ..._kl, agents: [{ id: 'F1', items: 'A1', kind: 'foundation' }, { id: 'F2', items: 'A2' }] }, agent, (m) => logs.push(m), _n, pipeline)
const P = (l) => (calls.find((c) => c.label === l) || {}).prompt || ''
console.log(`fd-ship:${/merge <wt> <iid> --no-docs 'foundation F1'/.test(P('ship:F1')) && !/--no-docs/.test(P('ship:F2')) && /kind: foundation\)/.test(P('build:F1'))}`)
console.log(`fd-report:${o.testerGuides.some((g) => g.agent === 'F1' && g.docsExempt && /^exempt$/.test(g.guide)) && o.testerGuides.some((g) => g.agent === 'F2' && !g.docsExempt) && logs.some((l) => /^F1: exempt$/.test(l))}`)
'@
Expect-Each (Invoke-Js dw-foundation $jsfd $wfd) 'buildy kind foundation: # (no human doc, merge --no-docs, exempt in the report)' 'fd-ship', 'fd-report' -Show 6
# generic: no CONFIG roles = independent repos, no merge order; repos[].role (any name, GitHub URLs) orders them; models.<phase> win
$jsg = @'
const mr = (r) => ({ url: `https://github.com/o/${r}/pull/4`, repo: '', merged: false }), lt = { status: 'PASS' }
const go = async (cfg) => { const m = _mock((p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`) : /^(build|ship):G1/.test(o.label) ? _rep(lt, { mrs: [mr('storefront'), mr('core')] }) : /^review/.test(o.label) ? { findings: [] } : o.label === 'order:G1' ? _ok('merge-after: x') : undefined, '[]')
 const a = async (p, o) => /^record-args/.test(o.label) ? (m.calls.push({ label: o.label, model: o.model, prompt: p }), _ok(`RECORDED\n${cfg}`)) : m.agent(p, o)
 await run({ brief: 'C:/b/g.md', ..._kl, agents: [{ id: 'G1' }] }, a, _n, _n, pipeline); return m.calls }
const n = await go('CONFIG {"models":null,"roles":{},"qaLanes":null}'), r = await go('CONFIG {"models":{"build":"m-big","step":"m-small"},"roles":{"storefront":"consumer","core":"producer"},"qaLanes":null}')
const t = await go('CONFIG {"models":{"build":"strong","review":"m-own"},"tiers":{"fast":"t-f","balanced":"t-b","strong":"t-s","inherit":""},"roles":{},"qaLanes":null}')
console.log(`tiers:${t.find((c) => c.label === 'build:G1').model === 't-s' && /^review/.test((t.find((c) => c.model === 'm-own') || {}).label) && t.some((c) => c.model === 't-f')}`)
const sh = (c) => c.find((x) => x.label === 'ship:G1').prompt
console.log(`no-roles:${!n.some((c) => c.label === 'order:G1') && /storefront\/pull\/4 \(, independent\)/.test(sh(n)) && n.find((c) => c.label === 'build:G1').model === 'sonnet'}`)
console.log(`roles:${/storefront\/pull\/4>https:\/\/github\.com\/o\/core\/pull\/4/.test(r.find((c) => c.label === 'order:G1').prompt) && /1\. \S+core\/pull\/4 \(, producer\)[\s\S]*2\. \S+storefront/.test(sh(r))}`)
console.log(`models:${r.find((c) => c.label === 'build:G1').model === 'm-big' && r.find((c) => c.label === 'order:G1').model === 'm-small' && /-Plan 'devy\/@build=sonnet:2,devy\/@docs=sonnet:1,revy\/@review=opus:1,step\/@ship=haiku:3,item:1,step\/@step=haiku:2,kitty\/@learn=haiku:1'/.test(r.find((c) => c.label === 'record-args').prompt)}`)
'@
Expect-Each (Invoke-Js dw-generic $jsg $wfd) 'buildy generic: #' 'no-roles', 'roles', 'models', 'tiers' -Show 6
# testy generic: qa.lanes unset = one web lane (an api item refused); a desktop lane with followUp web; models.test
$jsl = @'
const go = async (cfg, items, rd) => { const logs = [], { calls, agent } = _mock((p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`)
  : o.label === 'test:D1' ? _res('D1', [_ck('C1', 'PASS'), _ck('C2', 'PENDING')]) : /^test:/.test(o.label) ? _res(o.label.slice(5), [_ck('C2', 'PASS')]) : /^close/.test(o.label) ? _ok('published') : undefined)
 const out = await run({ runDir: rd || 'C:/runs/G', ..._kl, items }, async (p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`) : agent(p, o), (m) => logs.push(m), _n, null).catch((e) => ({ err: e.message }))
 return { calls, out, logs } }
const a = await go('CONFIG {"models":null,"roles":{},"qaLanes":null}', [_item('A1', 'api')])
const b = await go('CONFIG {"models":null,"roles":{},"qaLanes":null}', [_item('W1', '')])
const c = await go('CONFIG {"models":{"test":"m-t"},"roles":{},"qaLanes":{"desktop":{"kind":"desktop","parallel":2,"followUp":"web"},"web":{"kind":"web"}}}', [_item('D1', 'desktop')])
const rr = await go('CONFIG {"models":null,"roles":{},"qaLanes":null}', [_item('W1', '')], '.claude/rt/qa/G'), rt = rr.calls.find((x) => x.label === 'test:W1')
console.log(`rel-rundir:${!!rt && rt.prompt.includes('C:/.claude/rt/qa/G') && !rt.prompt.includes(' .claude/rt')}`)
const rk = await run({ runDir: 'C:/r', kitDir: '.claude', items: [] }, async () => _ok(''), _n, _n, null).catch((e) => ({ err: e.message }))
console.log(`rel-kitdir:${/absolute <workspace>\/\.claude path/.test((rk && rk.err) || '')}`)
console.log(`unknown-refused:${/unknown lane\(s\) api \(items A1\): qa\.lanes has web/.test(a.out.err || '')}`)
const tw = b.calls.find((x) => x.label === 'test:W1')
console.log(`default-web:${!!tw && /-Kind web /.test(tw.prompt) && /BROWSER \(web\)/.test(tw.prompt)}`)
const td = c.calls.find((x) => x.label === 'test:D1'), fu = c.calls.find((x) => x.label === 'test:D1W')
console.log(`desktop:${!!td && td.model === 'm-t' && /-Kind desktop /.test(td.prompt) && /LANE "desktop" \(kind desktop\)/.test(td.prompt) && !/BROWSER \(web\)/.test(td.prompt) && c.logs.some((l) => /desktop 1 \(x2\), web 0 \(x5\)/.test(l))}`)
console.log(`follow-up:${!!fu && /BROWSER \(web\)/.test(fu.prompt) && /ONLY these checks: C2/.test(fu.prompt) && /The desktop pass \(D1\)/.test(fu.prompt) && c.calls.some((x) => x.label === 'add-followups')}`)
'@
Expect-Each (Invoke-Js tc-generic $jsl $wf) 'testy lanes: # (rel-rundir: a relative runDir is from the workspace root; rel-kitdir: refused)' 'unknown-refused', 'default-web', 'desktop', 'follow-up', 'rel-rundir', 'rel-kitdir' -Show 6
# launch -Self: CONFIG line (models, roles by name + alias, qa.lanes; _readme keys dropped); plan @phase tokens resolve models.<phase>
& $J @{ models = @{ _readme = 'x'; build = 'opus' }; repos = @(@{ name = 'core'; aliases = @('api'); role = 'Producer' }, @{ name = 'ui' }); qa = @{ lanes = @{ web = @{ kind = 'web' } }; intermittentRx = "bo$([char]0xF8)m" } } (Join-Path $k 'skills/crafty/kit.local.json')
$cf = Join-Path (Kd) 'cfg-args.json'; [IO.File]::WriteAllText($cf, '{"brief":"C:/b/c.md","mode":"resume","agents":[{"id":"C1"}]}')
$lo = pwsh @np $O launch -Self -Script buildy.js -Run cfgrun -ArgsFile $cf -Plan 'devy/@build=sonnet:1,step/@step=haiku:1' | Out-String
$cfg = ($lo -split "`n" | Where-Object { $_ -like 'CONFIG *' }) -replace '^CONFIG ' | ConvertFrom-Json
$pc = & { . $O; $a = Get-KitPlanCap 'devy/@build=sonnet:1,step/@step=haiku:1'; $b = Get-KitPlanCap 'devy/opus:1,step/haiku:1'; "$($a.cap -eq $b.cap)|$(($a.perModel.Keys | Sort-Object) -join ',')" }
Expect "launch -Self prints CONFIG: models, repo roles by name + alias, qa.lanes; plan @phase tokens = models.<phase> ($pc)" ($cfg.models.build -eq 'opus' -and -not $cfg.models._readme -and $cfg.roles.core -eq 'producer' -and $cfg.roles.api -eq 'producer' -and -not $cfg.roles.ui -and $cfg.qaLanes.web.kind -eq 'web' -and $cfg.intermittentRx -eq "bo$([char]0xF8)m" -and $lo -notmatch '[^\x00-\x7F]' -and $pc -eq 'True|haiku,opus')
$bm = pwsh @np $O budget -Run cfgrun -Json | ConvertFrom-Json
Expect 'launch -Self BUDGET carries budget.runMinutes (0); budget -Run -Json the minutes since its launch' ($lo -match 'BUDGET \{.*"runMinutes":0' -and $bm.minutes -ge 0 -and $bm.minutes -lt 5)
# 2026-11-26: launch -Self's own lines pass buildy's SUM check (pwsh fnv = js fnv); the same lines with BUDGET re-worded stop the run
$sumJs = @'
const _real = __REC__, _try = (out) => run({ brief: 'C:/b/c.md', ..._kl, agents: [{ id: 'C1' }] }, async (p, o) => /^record-args/.test(o.label) ? _ok(out) : _ok('[]'), _n, _n, pipeline).then(() => 'ran', (e) => String(e.message))
console.log(`sum-real:${/\nSUM [0-9a-f]{8}\s*$/.test(_real) && /re-worded twice/.test(await _try(_real.slice(0, _real.lastIndexOf('SUM ')) + 'SUM-CUT')) && !/re-worded/.test(await _try(_real)) && /re-worded twice/.test(await _try(_real.replace(/^BUDGET \{.*$/m, 'BUDGET cap and estimate as planned')))}`)
'@
Expect-Each (Invoke-Js tc-sum $sumJs.Replace('__REC__', ($lo.Replace("`r", '') | ConvertTo-Json)) $wfd) 'launch -Self SUM: # (its real lines pass buildy, a re-worded BUDGET stops it)' 'sum-real'
Remove-Item (Join-Path $k 'skills/crafty/kit.local.json')
# qa.intermittentRx (CONFIG line) replaces the flaky-FAIL regex that earns 5 verify attempts; unset or no regex: the default
$jsir = Join-Path (Kd) 'ir.mjs'; [IO.File]::WriteAllText($jsir, @'
import fs from 'node:fs'
const src = fs.readFileSync(process.argv[2], 'utf8'), cut = (a, b) => src.slice(src.indexOf(a), src.indexOf(b, src.indexOf(a)))
const body = cut('let QL =', '// ---- record-args') + cut('let INTERMITTENT', '\nfunction verifyPrompt') + '\nreturn { takeConfig, attemptsNeeded }'
const mk = (logs) => new Function('log', 'MODELS', 'TIERS', 'MT', 'tierModels', 'setStr', 'ARGS0', body)((m) => logs.push(m), {}, {}, {}, () => {}, () => {}, {}), at = (t, s) => t.attemptsNeeded({ observed: s })
const d = mk([]); d.takeConfig('CONFIG {"intermittentRx":""}')
const c = mk([]); c.takeConfig('CONFIG {"intermittentRx":"boom"}')
const bl = [], b = mk(bl); b.takeConfig('CONFIG {"intermittentRx":"("}')
console.log(`default:${at(d, 'gateway timeout') === 5 && at(d, 'boom') === 1 && at(d, 'the assistant answered wrong') === 1}`)
console.log(`custom:${at(c, 'boom!') === 5 && at(c, 'gateway timeout') === 1}`)
console.log(`bad:${at(b, 'gateway timeout') === 5 && bl.some((l) => /qa\.intermittentRx is no regex/.test(l))}`)
'@)
Expect-Each @(node $jsir $wf 2>&1) 'testy qa.intermittentRx: #' 'default', 'custom', 'bad' -Show 5
# bugbrief: Migration range column + phone APK line only when repos[].migrations / qa.lanes kind app declare them
$bbg = Invoke-PsTest bb-generic @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; Update-KitTracking { param($tk) $tk.tasks.g1 = @{ task = 'g1' } }
function Get-TrackerTask { @{ name = 'E500'; description = 'spike' } }; function Get-TrackerComments { }; function Get-TaskMrBranches { }
$kl = Join-Path $KitConf.Kit 'skills/crafty/kit.local.json'; $bf = { $null = Invoke-BugBrief -Task g1 -Repos w 3>$null; Get-Content (Join-Path (Get-KitPath briefs) g1.md) -Raw }
function Use($c) { Set-Content $kl ($c | ConvertTo-Json -Depth 6); $script:__cfg = $c | ConvertTo-Json -Depth 6 | ConvertFrom-Json }
Use @{ repos = @(@{ name = 'w'; checkout = 'C:/w'; target = 'm' }) }; $t = & $bf
"neutral:$($t -match '\| Agent \| Bug task \| Items \|\r?\n' -and $t -notmatch 'Migration range' -and $t -notmatch 'phoney\.ps1' -and $t -match 'Branches `fix/')"
Use @{ repos = @(@{ name = 'w'; checkout = 'C:/w'; target = 'm'; migrations = @{ check = 'x' } }); qa = @{ lanes = @{ web = @{ kind = 'web' }; app = @{ kind = 'app' } } }; tracker = @{ bugBranchPrefix = 'bugfix/' } }; $t = & $bf
"declared:$($t -match '\| Items \| Migration range \|' -and $t -match '\| ask the coordinator if you need one \|' -and $t -match 'phoney\.ps1 acquire -Agent B-g1 -Apk local' -and $t -match 'Branches `bugfix/')"
'@ @($O)
Expect-Each $bbg 'bugbrief generic: #' 'neutral', 'declared' -Show 5
# testy: the prompts call envy.ps1 use and phoney.ps1 acquire directly
$js3b = @'
const { calls, agent } = _mock((prompt, o) => {
 if (/^(test|retest)/.test(o.label)) return _res(o.label.split(':')[1], [_ck('C1', 'PASS')])
})
const args = { runDir: 'C:/runs/R2', ..._kl, verify: false, localEnv: 'shop', lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556' }],
 items: [_item('P1', 'app'), _item('P2', 'app', { target: 'stg', localParts: ['app!2'] })] }
run(args, agent, _n, _n, null).then(() => {
 const tp = (calls.find((c) => /^test:P1/.test(c.label)) || {}).prompt || '', rel = (calls.find((c) => c.label === 'release:Falcon') || {}).prompt || ''
 console.log(`local-call:${tp.includes("& 'C:/kit/skills/envy/envy.ps1' use -Env shop -Services ") && !/Test-Path/.test(tp)}`)
 console.log(`phone-call:${tp.includes("& 'C:/kit/skills/phoney/phoney.ps1' acquire -Agent qa-w1-Falcon -Lane Falcon")}`)
 const lp = (calls.find((c) => /^test:P2/.test(c.label)) || {}).prompt || ''
 console.log(`local-parts:${/LOCAL PARTS app!2:.*use -Env <its local env> -Services api -Agent test:<CODE>@R2.*release it right after them.*never the whole env/.test(lp)}`)
 console.log(`run-tag:${/board join -Type checky -Run R2 -Area <CODE>/.test(tp) && /CLAUDE_AGENT='test:P1@R2'/.test(tp) && /seat acquire -Agent "test:P1@R2"/.test(tp)}`)
 console.log(`release-guard:${/bossy\.ps1 release -Agent 'qa-w1-Falcon' -Reason 'agent finished'/.test(rel)}`)
 console.log(`just-in-time:${/acquire right before your first phone check/.test(tp) && tp.includes("phoney.ps1' release -Agent qa-w1-Falcon") && /release right after the last one \(envy\.ps1 release -Env shop/.test(tp)}`)
 console.log(`progress:${/board beat -Session <token> -Status 'check <id>/.test(tp) && /never stop for time/.test(tp) && !/time-cap/.test(tp)}`)
 const sl = (calls.find((c) => c.label === 'seat-logins') || {}).prompt || ''
 console.log(`seat-login:${/seat acquire -Agent "test:P2@R2" .*-Target "stg"/.test(lp) && /SEAT_USER <login>: your own login/.test(lp) && !/-Target/.test(tp.split('SEAT (')[1].split('\n')[1]) && sl.includes("seat cleanup -RunDir 'C:/runs/R2'")}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-extras $js3b (Join-Path $src 'workflows/testy.js')) 'testy prompts (owner 2026-11-19: leases just in time, progress on the board, no time cap; 2026-11-24: own seat logins): #' 'local-call', 'phone-call', 'local-parts', 'run-tag', 'release-guard', 'just-in-time', 'progress', 'seat-login' -Show 8
# a first tester with no checks at all: the retest runs the whole guide (a scoped retest of nothing tested nothing)
$jsE = @'
const { calls, agent } = _mock((prompt, o) => { if (/^test:/.test(o.label)) return _res('E1', []); if (/^retest:/.test(o.label)) return _res('E1', [_ck('C1', 'PASS')]) }, 'published')
run({ runDir: 'C:/runs/R9', ..._kl, verify: false, items: [_item('E1')] }, agent, _n, _n, null).then(() => {
 const rt = calls.find((c) => c.label === 'retest:E1'), cl = calls.find((c) => c.label === 'close:E1')
 console.log(`empty-full:${!!rt && !/ONLY these checks/.test(rt.prompt) && /Work through ALL checks/.test(rt.prompt) && !!cl}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-empty $jsE (Join-Path $src 'workflows/testy.js')) 'testy retest: #' 'empty-full' -Show 8
# K70 (K7 fix): one area over the cap is refused as unsplittable, with no next (a batch of 1 changed nothing: endless refusal)
$js1a = @'
const calls = [], agent = async (p, o) => { calls.push(o.label); return /^record-args/.test(o.label) ? _ok('RECORDED x\nBUDGET {"cap":100000,"estimate":500000,"stopAt":0.8}\nCONFIG {}') : _ok('[]') }
const o = await run({ brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }], mandate: ['m'], ..._kl }, agent, _n, _n, pipeline)
console.log(`one-area:${o.refused === true && o.unsplittable === true && !o.next && !o.batch && !calls.some((c) => /^build:/.test(c))}`)
'@
Expect-Each (Invoke-Js wg-one $js1a $wfd) 'buildy budget: #' 'one-area' -Show 5
# K66: a budget stop after the build hands next a resume map (its MRs and worktrees), never a bare mode resume
$js1b = @'
const agent = async (p, o) => /^record-args/.test(o.label) ? _ok('RECORDED x\nBUDGET {"cap":1000000,"estimate":700000,"stopAt":0.8}\nCONFIG {}') : o.label === 'budget' ? _ok(JSON.stringify({ spent: 900000 }))
 : /^build:/.test(o.label) ? _rep({ status: 'FAIL', env: 'e', rounds: 1, failing: ['G1'], goalsDoc: 'g' }) : _ok('[]')
const o = await run({ brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }], mandate: ['m'], ..._kl }, agent, _n, _n, pipeline)
const rs = o.next && o.next.args.resume && o.next.args.resume.X1
console.log(`resume-map:${o.next && o.next.args.mode === 'resume' && rs && rs.state === 'budget stop' && rs.mrs.length === 1 && rs.worktrees[0] === 'C:/wt/x1' && !rs.skip.includes('build')}`)   // the loop had failed: devy finishes it in that worktree
'@
Expect-Each (Invoke-Js wg-res $js1b $wfd) 'buildy budget: #' 'resume-map' -Show 5
# K69: testy next keeps the run options; a mostly NOT_TESTED shared-env item is held (never dropped unpublished); verify corrects the defect class
$js1c = @'
const sim = async (args, checks, verdicts, spent = 0) => { const calls = []; const agent = async (p, o) => { calls.push({ label: o.label, prompt: p })
  if (/^record-args/.test(o.label)) return _ok('RECORDED x\nBUDGET {"cap":1000000,"estimate":750000,"stopAt":0.8}\nCONFIG {}')
  if (o.label === 'budget') return _ok(JSON.stringify({ spent }))
  if (/^(test|retest)/.test(o.label)) return { ..._res(o.label.split(':')[1], checks.map((c) => _ck(...c))), handoff: '' }
  if (/^verify/.test(o.label)) return { verdicts }
  return { ..._ok('[]'), json: '' } }; return { calls, o: await run({ runDir: 'C:/r/run1', ..._kl, mandate: ['m'], ...args }, agent, _n, _n, null) } }
const a = await sim({ items: ['W1', 'W2'].map((c) => _item(c, 'web', { skipClose: true })), webParallel: 1, verify: false, devices: 'none' }, [['C1', 'PASS']], [], 900000)
console.log(`next-opts:${a.o.next && a.o.next.args.verify === false && a.o.next.args.webParallel === 1 && a.o.next.args.devices === 'none'}`)
const b = await sim({ items: [_item('W1', 'web')] }, [['C1', 'NOT_TESTED'], ['C2', 'NOT_TESTED'], ['C3', 'PASS']])
console.log(`broken-held:${b.calls.some((c) => /^hold:W1/.test(c.label) && /broken run/.test(c.prompt)) && !b.calls.some((c) => /^close:W1/.test(c.label))}`)
const v = await sim({ items: [_item('W1', 'web', { skipClose: true })] }, [['C1', 'FAIL', { defect: 'own', evidence: ['e.png'] }]], [{ id: 'C1', outcome: 'confirmed', attempts: 1, observed: 'o', evidence: [], basis: 'none', defect: 'new' }])
console.log(`verify-defect:${v.calls.some((c) => /^hold:W1/.test(c.label) && /"defect":\s*"new"/.test(c.prompt))}`)
'@
Expect-Each (Invoke-Js wg-tn $js1c (Join-Path $src 'workflows/testy.js')) 'testy: #' 'next-opts', 'broken-held', 'verify-defect' -Show 8
# (cap move from render.tests.ps1)
# ---- results.json written once; the workflow sends deltas (item 3): testy.js resultsPatch -> pokey.ps1 results patch / hold
$rd = Join-Path (Kd) 'qa-run'; New-Item -ItemType Directory -Force "$rd/W1" | Out-Null
$row = { param($id, $r) [ordered]@{ id = $id; subtask_id = 't1'; screen = 's'; result = $r; what_was_done = 'w'; observed = 'o'; evidence = @(); attempts = 1 } }
$tester = [ordered]@{ code = 'W1'; checks = @((& $row 'T1' 'PASS'), (& $row 'T2' 'FAIL'), (& $row 'T2' 'PASS')); findings = @(); setup_changes = @(); data_created = @() }
Set-JsonFile "$rd/W1/results.json" $tester; Set-JsonFile "$rd/tester.json" $tester
$js = Join-Path (Kd) 'rp.mjs'; [IO.File]::WriteAllText($js, @'
import fs from 'node:fs'
const src = fs.readFileSync(process.argv[2], 'utf8'), Q = 'pokey.ps1', R = { runDir: 'RD' }
eval(src.slice(src.indexOf('const uniq ='), src.indexOf('function finalPrompt')).replace('function resultsPatch', 'globalThis.resultsPatch = function').replace('const uniq =', 'globalThis.uniq ='))
const written = JSON.parse(fs.readFileSync(process.argv[3], 'utf8')), res = JSON.parse(JSON.stringify(written))
res.code = 'W1'; res.checks[2].id = 'T2b'; res.checks[2].guideId = 'T2'; res.checks[1].verify = "re-test: confirmed (it's real)"; res.checks[0].firstAttempt = 'o'
res.checks.push({ id: 'T1n', subtask_id: 't1', screen: 's', result: 'NOT_TESTED', cause: 'env-data', what_was_done: 'split', observed: '', evidence: [], attempts: 0 })
console.log(resultsPatch(written, res)); console.log('NONE=' + JSON.stringify(resultsPatch(written, { ...written, checks: uniq(written.checks) })))
'@)
$cmds = @(node $js (Join-Path $src 'workflows/testy.js') "$rd/tester.json" 2>&1)
$pj = if ("$($cmds[0])" -match "-Patch '(.*)'$") { $Matches[1].Replace("''", "'") } else { '' }
$PK = Join-Path $k 'skills/pokey/pokey.ps1'
$pr = pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W1 -Patch $pj 2>&1 | Out-String; $after = Get-Content -Raw "$rd/W1/results.json" | ConvertFrom-Json
$pb = pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W1 -Patch '{"set":{"T9":{"result":"PASS"}},"add":[{"id":"Z1","color":"red"}]}' 2>&1 | Out-String
$ph = pwsh -NoProfile -File $PK results hold -RunDir $rd -Code W1 -Why "env: it's down" -Summary 'W1: pass 1/3' -EnvFix '{"id":"d-1","state":"open"}' 2>&1 | Out-String; $hj = Get-Content -Raw "$rd/W1/held.json" | ConvertFrom-Json
Expect "testy.js resultsPatch: only the changed fields and added rows (dup ids as the workflow names them), none when nothing changed ($($cmds -join ' || '))" ("$($cmds[0])" -match "^& 'pokey\.ps1' results patch -RunDir 'RD' -Code W1 -Patch '\{" -and $pj -match '"set":\{"T1":\{"firstAttempt":"o"\},"T2":\{"verify":"re-test: confirmed \(it.s real\)"\}\}' -and $pj -match '"add":\[\{"id":"T1n"' -and $pj -notmatch 'T2b' -and "$($cmds[1])" -eq 'NONE=""')
Expect "pokey.ps1 results patch: deltas merged by id (dup ids made unique, guideId, the workflow's firstAttempt), rows added, unknown key / id refused, nothing written ($($pr.Trim()))" ($pr -match '2 changed, 1 added, 4 checks' -and $after.checks[0].firstAttempt -eq 'o' -and (@($after.checks.id) -join ',') -eq 'T1,T2,T2b,T1n' -and $after.checks[1].verify -match "it's real" -and $after.checks[2].guideId -eq 'T2' -and $pb -match 'unknown row key\(s\) color' -and @((Get-Content -Raw "$rd/W1/results.json" | ConvertFrom-Json).checks).Count -eq 4)
$pn = foreach ($bp in '{"add":[{"observed":"x"}]}', '{"set":{"T1":"PASS"}}') { pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W1 -Patch $bp 2>&1 | Out-String }
Expect 'results patch: an add row without id or a set value no object = refused with the set shape, no crash' (@($pn | Where-Object { $_ -match 'add rows need an id; to change fields of a check use set' }).Count -eq 2)
$ps = pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W1 -Patch '{"set":{"T2":{"observed":"set only"}}}' 2>&1 | Out-String   # no add key: .add was the hashtable's Add method (L20)
Expect "results patch: a set-only patch (no add key) applies ($($ps.Trim()))" ($ps -match '1 changed, 0 added' -and @((Get-Content -Raw "$rd/W1/results.json" | ConvertFrom-Json).checks | Where-Object { $_.id -eq 'T2' -and $_.observed -eq 'set only' }).Count -eq 1)
# only a scoped retry's file (testy-wave2 T5): the error names -Results; -Results results-retry.json patches it
New-Item -ItemType Directory -Force "$rd/W2" | Out-Null; Set-JsonFile "$rd/W2/results-retry.json" $tester
$pq = pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W2 -Patch '{"set":{"T1":{"observed":"retry"}}}' 2>&1 | Out-String
$pqr = pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W2 -Patch '{"set":{"T1":{"observed":"retry"}}}' -Results results-retry.json 2>&1 | Out-String
Expect "results patch: no results.json but results-retry.json -> names -Results; with it the retry file is patched ($($pq.Trim()) || $($pqr.Trim()))" ($pq -match 'only .*results-retry\.json \(a scoped retry\): patch it with -Results results-retry\.json' -and -not (Test-Path "$rd/W2/results.json") -and $pqr -match '1 changed' -and (Get-Content -Raw "$rd/W2/results-retry.json" | ConvertFrom-Json).checks[0].observed -eq 'retry')
Expect "pokey.ps1 results hold: held.json from arguments, the script's UTC time ($($hj.at))" ($hj.held -eq "env: it's down" -and $hj.envFix.id -eq 'd-1' -and $hj.summary -eq 'W1: pass 1/3' -and (Get-Content -Raw "$rd/W1/held.json") -match '"at": "\d{4}-\d\d-\d\dT[\d:.]+Z"')
# buildy: AREA TASK lines give each devy its subtask; -HoldPromotion '' only on its own subtask (on a shared task it released every area's hold)
$jsat = @'
const calls = []
const agent = async (p, o) => { calls.push({ label: o.label, prompt: p })
 if (/^record-args/.test(o.label)) return { ok: true, output: 'RECORDED\nAREA TASK X1 T-X1 https://t/T-X1\nAREA TASK X2 FAILED: no\n' + _CFG }
 if (/^ci:/.test(o.label)) return { done: true, mrs: [] }
 return /^(build|ship):/.test(o.label) ? _rep({ status: 'PASS', failing: [] }, _merged(1)) : _ok('[]') }
const args = { brief: 'C:/b/w.md', task: 'P1', agents: [{ id: 'X1', items: 'A1', area: 'a' }, { id: 'X2', items: 'A2', area: 'b' }], mandate: ['m'], ..._kl }
run(args, agent, _n, _n, pipeline).then(() => {
 const pr = (l) => (calls.find((c) => c.label === l) || {}).prompt || ''
 console.log(`area-task:${/TRACKER TASK: T-X1 \(subtask of P1\)/.test(pr('build:X1')) && !/TRACKER TASK/.test(pr('build:X2'))}`)
 console.log(`no-release:${/-HoldPromotion ''/.test(pr('track:X1')) && pr('track:X2') !== '' && !/-HoldPromotion/.test(pr('track:X2'))}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js dw-areatask $jsat $wfd) 'buildy: #' 'area-task', 'no-release' -Show 5
# kit-only STEP agents run as steppy (lean agent file, no MCP tools); product MRs (ship, followups) stay devy; an older session falls back to kitty
$stT = foreach ($wn in 'buildy', 'testy') { $wt = Get-Content (Join-Path (Split-Path $PSScriptRoot) "workflows/$wn.js") -Raw
  @([regex]::Matches($wt, "(?s)STEP: (?:run exactly this|record this workflow)[^\n]*\n.{0,900}?agentType: '(\w+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join '/' }
$stS = [regex]::Matches((Get-Content (Join-Path (Split-Path $PSScriptRoot) 'workflows/buildy.js') -Raw), "label: ``(ship|track|ci):[^\n]*?agentType: '(\w+)'") | ForEach-Object { "$($_.Groups[1].Value)=$($_.Groups[2].Value)" }
$stF = @(foreach ($wn in 'buildy', 'testy') { (Get-Content (Join-Path (Split-Path $PSScriptRoot) "workflows/$wn.js") -Raw) -match "o\.agentType === 'steppy' && /steppy/\.test[^\n]*agentType: 'kitty'" })
Expect "workflows: kit-command STEP agents are steppy (unknown -> kitty once), ship stays devy ($($stT -join ' ') | $($stS -join ' ') | $stF)" (($stT -join ' ') -eq 'steppy steppy' -and ($stS -join ' ') -eq 'ci=steppy ship=devy' -and "$stF" -eq 'True True')
# model tiers (T4): budget.models picks the claude row; models.tiers.<tool> with a missing tier = the next stronger, then inherit
$mt = Invoke-PsTest ctx-tiers @'
$null = . $args[0] 6>$null
"$((Get-KitBudget -Tool claude -Model 'claude-opus-4-7').row) $((Get-KitBudget -Tool claude -Model 'claude-sonnet-4-6').row) $((Get-KitBudget -Tool claude -Model 'claude-haiku-5-5').row) $((Get-KitBudget -Tool claude -Model 'claude-sonnet-4-6[1m]').row)"
$t = Get-KitTiers claude; "$($t.fast)/$($t.balanced)/$($t.strong)/$($t.inherit)"
$__cfg = [pscustomobject]@{ models = [pscustomobject]@{ tiers = [pscustomobject]@{ local = [pscustomobject]@{ strong = 'big-x'; fast = '' } } }; budget = [pscustomobject]@{ models = @([pscustomobject]@{ match = 'sonnet'; row = 'claude-1m' }) } }
$t = Get-KitTiers local; "$($t.fast)/$($t.balanced)/$($t.strong)"; (Get-KitBudget -Tool claude -Model 'claude-sonnet-4-6').row
'@ @($O)
Expect "tiers: budget.models rows (opus 4.7 / haiku 5.5 / [1m] = 1M, sonnet 4.6 = 200k; a local list wins); claude tiers; local: fast unset -> the next stronger ($($mt -join ' / '))" ("$($mt -join '|')" -eq 'claude-1m claude-200k claude-1m claude-1m|haiku/sonnet/opus/|big-x/big-x/big-x|claude-1m')
# tidy: the prep step returns the run id (kitbag.py naming next id tidy); worktree, branch and retro file carry it
$jsT = @'
const P0 = { ok: true, record: 'RECORDED', prep: JSON.stringify({ work: 1, groups: 0, sec: 1, steps: [], digest: 'd.md', at: 'x', parity: ['ci/x/failure: fallback -> native'] }), run: 'tidy-2' }, J0 = { applied: [], proposedForApproval: ['p1'], rejected: [], report: 'r.md' }
const { calls, agent } = _mock((prompt, o) => o.label === 'prep' ? P0 : J0), L2 = []
const lost = async (p, o) => { L2.push(o.label + (/^No report came back: first find what is done: C:\/k\/\S+\/retros\/tidy-2\.md exists/.test(p) ? '+' : '')); return o.label === 'apply' ? null : o.label === 'prep' ? P0 : J0 }
run({ kitDir: 'C:/k' }, agent, _n, _n, null).then((res) => { const j = calls.find((c) => /Kind retro/.test(c.prompt)) || { prompt: '' }
 console.log(`tidy-run:${/naming next name tidy/.test(calls[0].prompt) && /wt lease -Repo \S+ -Branch kit\/tidy-2 -Agent tidy-2 /.test(j.prompt) && /\/tidy-2\.md\./.test(j.prompt)}`)
 console.log(`tidy-parity:${JSON.stringify(res.proposedForApproval) === JSON.stringify(['p1', 'parity next: ci/x/failure: fallback -> native'])}`)
 return run({ kitDir: 'C:/k' }, lost, _n, _n, null) }).then((r2) => console.log(`tidy-redo:${L2.join() === 'prep,apply,apply@redo+' && r2.report === 'r.md'}`)).catch(_err)
'@
Expect-Each (Invoke-Js nm-tidy $jsT (Join-Path $src 'workflows/tidy.js')) 'tidy: run name; parity next proposals; a judge with no result: one apply@redo that checks its retro file first: #' 'tidy-run', 'tidy-parity', 'tidy-redo' -Show 8
Remove-TestKit $k
Complete-Tests
