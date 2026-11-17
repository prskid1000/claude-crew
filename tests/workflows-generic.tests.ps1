#Requires -Version 7
<#
workflows-generic.tests.ps1: buildy.js / testy.js on neutral and custom config (CONFIG line of launch -Self): repo roles, qa.lanes, models.<phase>.
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
'@
Expect-Each (Invoke-Js dw-deploy $jsdp $wfd) 'buildy deploy: #' 'deploy-skip', 'deploy-batch' -Show 5
# generic: no CONFIG roles = independent repos, no merge order; repos[].role (any name, GitHub URLs) orders them; models.<phase> win
$jsg = @'
const mr = (r) => ({ url: `https://github.com/o/${r}/pull/4`, repo: '', merged: false }), lt = { status: 'PASS' }
const go = async (cfg) => { const m = _mock((p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`) : /^(build|ship):G1/.test(o.label) ? _rep(lt, { mrs: [mr('storefront'), mr('core')] }) : /^review/.test(o.label) ? { findings: [] } : o.label === 'order:G1' ? _ok('merge-after: x') : undefined, '[]')
 const a = async (p, o) => /^record-args/.test(o.label) ? (m.calls.push({ label: o.label, model: o.model, prompt: p }), _ok(`RECORDED\n${cfg}`)) : m.agent(p, o)
 await run({ brief: 'C:/b/g.md', ..._kl, agents: [{ id: 'G1' }] }, a, _n, _n, pipeline); return m.calls }
const n = await go('CONFIG {"models":null,"roles":{},"qaLanes":null}'), r = await go('CONFIG {"models":{"build":"m-big","step":"m-small"},"roles":{"storefront":"consumer","core":"producer"},"qaLanes":null}')
const sh = (c) => c.find((x) => x.label === 'ship:G1').prompt
console.log(`no-roles:${!n.some((c) => c.label === 'order:G1') && /storefront\/pull\/4 \(, independent\)/.test(sh(n)) && n.find((c) => c.label === 'build:G1').model === 'sonnet'}`)
console.log(`roles:${/storefront\/pull\/4>https:\/\/github\.com\/o\/core\/pull\/4/.test(r.find((c) => c.label === 'order:G1').prompt) && /1\. \S+core\/pull\/4 \(, producer\)[\s\S]*2\. \S+storefront/.test(sh(r))}`)
console.log(`models:${r.find((c) => c.label === 'build:G1').model === 'm-big' && r.find((c) => c.label === 'order:G1').model === 'm-small' && /-Plan 'devy\/@build=sonnet:1,revy\/@review=sonnet:1,step\/@ship=haiku:3,item:1,step\/@step=haiku:2,kitty\/@learn=haiku:1'/.test(r.find((c) => c.label === 'record-args').prompt)}`)
'@
Expect-Each (Invoke-Js dw-generic $jsg $wfd) 'buildy generic: #' 'no-roles', 'roles', 'models' -Show 5
# testy generic: qa.lanes unset = one web lane (an api item refused); a desktop lane with followUp web; models.test
$jsl = @'
const go = async (cfg, items) => { const logs = [], { calls, agent } = _mock((p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`)
  : o.label === 'test:D1' ? _res('D1', [_ck('C1', 'PASS'), _ck('C2', 'PENDING')]) : /^test:/.test(o.label) ? _res(o.label.slice(5), [_ck('C2', 'PASS')]) : /^close/.test(o.label) ? _ok('published') : undefined)
 const out = await run({ runDir: 'C:/runs/G', ..._kl, items }, async (p, o) => /^record-args/.test(o.label) ? _ok(`RECORDED\n${cfg}`) : agent(p, o), (m) => logs.push(m), _n, null).catch((e) => ({ err: e.message }))
 return { calls, out, logs } }
const a = await go('CONFIG {"models":null,"roles":{},"qaLanes":null}', [_item('A1', 'api')])
const b = await go('CONFIG {"models":null,"roles":{},"qaLanes":null}', [_item('W1', '')])
const c = await go('CONFIG {"models":{"test":"m-t"},"roles":{},"qaLanes":{"desktop":{"kind":"desktop","parallel":2,"followUp":"web"},"web":{"kind":"web"}}}', [_item('D1', 'desktop')])
console.log(`unknown-refused:${/unknown lane\(s\) api \(items A1\): qa\.lanes has web/.test(a.out.err || '')}`)
const tw = b.calls.find((x) => x.label === 'test:W1')
console.log(`default-web:${!!tw && /-Kind web /.test(tw.prompt) && /BROWSER \(web\)/.test(tw.prompt)}`)
const td = c.calls.find((x) => x.label === 'test:D1'), fu = c.calls.find((x) => x.label === 'test:D1W')
console.log(`desktop:${!!td && td.model === 'm-t' && /-Kind desktop /.test(td.prompt) && /LANE "desktop" \(kind desktop\)/.test(td.prompt) && !/BROWSER \(web\)/.test(td.prompt) && c.logs.some((l) => /desktop 1 \(x2\), web 0 \(x5\)/.test(l))}`)
console.log(`follow-up:${!!fu && /BROWSER \(web\)/.test(fu.prompt) && /ONLY these checks: C2/.test(fu.prompt) && /The desktop pass \(D1\)/.test(fu.prompt) && c.calls.some((x) => x.label === 'add-followups')}`)
'@
Expect-Each (Invoke-Js tc-generic $jsl $wf) 'testy lanes: #' 'unknown-refused', 'default-web', 'desktop', 'follow-up' -Show 5
# launch -Self: CONFIG line (models, roles by name + alias, qa.lanes; _readme keys dropped); plan @phase tokens resolve models.<phase>
& $J @{ models = @{ _readme = 'x'; build = 'opus' }; repos = @(@{ name = 'core'; aliases = @('api'); role = 'Producer' }, @{ name = 'ui' }); qa = @{ lanes = @{ web = @{ kind = 'web' } } } } (Join-Path $k 'skills/crafty/kit.local.json')
$cf = Join-Path (Kd) 'cfg-args.json'; [IO.File]::WriteAllText($cf, '{"brief":"C:/b/c.md","mode":"resume","agents":[{"id":"C1"}]}')
$lo = pwsh @np $O launch -Self -Script buildy.js -Run cfgrun -ArgsFile $cf -Plan 'devy/@build=sonnet:1,step/@step=haiku:1' | Out-String
$cfg = ($lo -split "`n" | Where-Object { $_ -like 'CONFIG *' }) -replace '^CONFIG ' | ConvertFrom-Json
$pc = & { . $O; $a = Get-KitPlanCap 'devy/@build=sonnet:1,step/@step=haiku:1'; $b = Get-KitPlanCap 'devy/opus:1,step/haiku:1'; "$($a.cap -eq $b.cap)|$(($a.perModel.Keys | Sort-Object) -join ',')" }
Expect "launch -Self prints CONFIG: models, repo roles by name + alias, qa.lanes; plan @phase tokens = models.<phase> ($pc)" ($cfg.models.build -eq 'opus' -and -not $cfg.models._readme -and $cfg.roles.core -eq 'producer' -and $cfg.roles.api -eq 'producer' -and -not $cfg.roles.ui -and $cfg.qaLanes.web.kind -eq 'web' -and $pc -eq 'True|haiku,opus')
Remove-Item (Join-Path $k 'skills/crafty/kit.local.json')
# bugbrief: Migration range column + phone APK line only when repos[].migrations / qa.lanes kind app declare them
$bbg = Invoke-PsTest bb-generic @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; Update-KitTracking { param($tk) $tk.tasks.g1 = @{ task = 'g1' } }
function Get-TrackerTask { @{ name = 'E500'; description = 'spike' } }; function Get-TrackerComments { }; function Get-TaskMrBranches { }
$kl = Join-Path $KitConf.Kit 'skills/crafty/kit.local.json'; $bf = { $null = Invoke-BugBrief -Task g1 -Repos w 3>$null; Get-Content (Join-Path (Get-KitPath briefs) g1.md) -Raw }
function Use($c) { Set-Content $kl ($c | ConvertTo-Json -Depth 6); $script:__cfg = $c | ConvertTo-Json -Depth 6 | ConvertFrom-Json }
Use @{ repos = @(@{ name = 'w'; checkout = 'C:/w'; target = 'm' }) }; $t = & $bf
"neutral:$($t -match '\| Agent \| Bug task \| Items \|\r?\n' -and $t -notmatch 'Migration range' -and $t -notmatch 'phoney')"
Use @{ repos = @(@{ name = 'w'; checkout = 'C:/w'; target = 'm'; migrations = @{ check = 'x' } }); qa = @{ lanes = @{ web = @{ kind = 'web' }; app = @{ kind = 'app' } } } }; $t = & $bf
"declared:$($t -match '\| Items \| Migration range \|' -and $t -match '\| ask the coordinator if you need one \|' -and $t -match 'phoney\.ps1 acquire -Agent B-g1 -Apk local')"
'@ @($O)
Expect-Each $bbg 'bugbrief generic: #' 'neutral', 'declared' -Show 5
# testy: the prompts call envy.ps1 use and phoney.ps1 acquire directly
$js3b = @'
const { calls, agent } = _mock((prompt, o) => {
 if (/^(test|retest)/.test(o.label)) return _res(o.label.split(':')[1], [_ck('C1', 'PASS')])
})
const args = { runDir: 'C:/runs/R2', ..._kl, verify: false, localEnv: 'shop', lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556' }],
 items: [_item('P1', 'app')] }
run(args, agent, _n, _n, null).then(() => {
 const tp = (calls.find((c) => /^test:P1/.test(c.label)) || {}).prompt || '', rel = (calls.find((c) => c.label === 'release-Falcon') || {}).prompt || ''
 console.log(`local-call:${tp.includes("& 'C:/kit/skills/envy/envy.ps1' use -Env shop -Services ") && !/Test-Path/.test(tp)}`)
 console.log(`phone-call:${tp.includes("& 'C:/kit/skills/phoney/phoney.ps1' acquire -Agent qa-w1-Falcon -Lane Falcon")}`)
 console.log(`release-guard:${/bossy\.ps1 release -Agent 'qa-w1-Falcon' -Reason 'agent finished'/.test(rel)}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-extras $js3b (Join-Path $src 'workflows/testy.js')) 'testy prompts: #' 'local-call', 'phone-call', 'release-guard' -Show 8
# K70 (K7 fix): one area over the cap is refused as unsplittable, with no next (a batch of 1 changed nothing: endless refusal)
$js1a = @'
const calls = [], agent = async (p, o) => { calls.push(o.label); return /^record-args/.test(o.label) ? _ok('RECORDED x\nBUDGET {"cap":100000,"estimate":500000,"stopAt":0.8}') : _ok('[]') }
const o = await run({ brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }], mandate: ['m'], ..._kl }, agent, _n, _n, pipeline)
console.log(`one-area:${o.refused === true && o.unsplittable === true && !o.next && !o.batch && !calls.some((c) => /^build:/.test(c))}`)
'@
Expect-Each (Invoke-Js wg-one $js1a $wfd) 'buildy budget: #' 'one-area' -Show 5
# K66: a budget stop after the build hands next a resume map (its MRs and worktrees), never a bare mode resume
$js1b = @'
const agent = async (p, o) => /^record-args/.test(o.label) ? _ok('RECORDED x\nBUDGET {"cap":1000000,"estimate":700000,"stopAt":0.8}') : o.label === 'budget' ? _ok(JSON.stringify({ spent: 900000 }))
 : /^build:/.test(o.label) ? _rep({ status: 'FAIL', env: 'e', rounds: 1, failing: ['G1'], goalsDoc: 'g' }) : _ok('[]')
const o = await run({ brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }], mandate: ['m'], ..._kl }, agent, _n, _n, pipeline)
const rs = o.next && o.next.args.resume && o.next.args.resume.X1
console.log(`resume-map:${o.next && o.next.args.mode === 'resume' && rs && rs.state === 'budget stop' && rs.mrs.length === 1 && rs.worktrees[0] === 'C:/wt/x1' && !rs.skip.includes('build')}`)   // the loop had failed: devy finishes it in that worktree
'@
Expect-Each (Invoke-Js wg-res $js1b $wfd) 'buildy budget: #' 'resume-map' -Show 5
# K69: testy next keeps the run options; a mostly NOT_TESTED shared-env item is held (never dropped unpublished); verify corrects the defect class
$js1c = @'
const sim = async (args, checks, verdicts, spent = 0) => { const calls = []; const agent = async (p, o) => { calls.push({ label: o.label, prompt: p })
  if (/^record-args/.test(o.label)) return _ok('RECORDED x\nBUDGET {"cap":1000000,"estimate":750000,"stopAt":0.8}')
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
Remove-TestKit $k
Complete-Tests
