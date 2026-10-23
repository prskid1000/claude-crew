#Requires -Version 7
<#
workflows.tests.ps1: buildy.js and testy.js sims (agents mocked; node runs the real script body); recover's area states and run lineage.
Usage: pwsh -NoProfile -File <kit>/tests/workflows.tests.ps1 (or tests/kit-tests.ps1 -Area workflows).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit workflows; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
# buildy local loop: BLOCKED = FAIL; still FAIL -> ONE stronger round; ENV-FIX waits
$wfd = Join-Path $src 'workflows/buildy.js'
$jsd = @'
const lt = (status, extra = {}) => ({ status, env: 'shop r1', rounds: 3, failing: status === 'PASS' ? [] : ['G1 still 500'], goalsDoc: 'g.md', ...extra })
const rep = (status, extra = {}) => _rep(lt(status), extra)
const mk = (envfix) => _mock((prompt, o) => {
 if (/^build:/.test(o.label)) return envfix ? rep('FAIL', { done: [], needsEnvFix: [{ item: 'A1', envFixId: 'e-20260101000000-x1', need: 'refresh the release' }] }) : rep('BLOCKED', { localTest: lt('BLOCKED', { blockedReason: 'local DB missing a table' }) })
 if (/^local:/.test(o.label)) return rep('FAIL')
 if (/^envfix:/.test(o.label)) return { ok: true, output: 'ANSWERED e-20260101000000-x1: done: refreshed r2' }
 if (/^(local-strong|envfix-resume):/.test(o.label)) return rep('PASS')
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ship:/.test(o.label)) return rep('PASS', _merged(1))
}, '[]')
const args = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], ..._kl }
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
let reviews = 0
const { calls, agent } = _mock((prompt, o) => {
 if (/^build:/.test(o.label)) return rep({ deferred: [{ id: 'A2', reason: 'needs data' }] })
 if (/^review:/.test(o.label)) return { findings: reviews++ ? [] : [{ mr: '1', file: 'a.ts', line: 3, severity: 'blocking', problem: 'null check missing', fix: 'add it' }] }
 if (/^fix:/.test(o.label)) return rep()
 if (/^ship:/.test(o.label)) return rep(_merged(1))
}, '[]')
const args = { brief: 'C:/b/wave-x.md', agents: [{ id: 'X1', items: 'A1, A2', area: 'a' }], mandate: ['m'], ..._kl }
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
Expect 'buildy: default run name = orch.ps1 Get-LaunchRunName (the brief name + 4 hex of its path)' (@($res | Where-Object { "$_" -eq "run:$want" }).Count -eq 1 -and $want -match '^wave-x-[0-9a-f]{4}$')
# buildy: a batch's next run drops producers outside its list
$jsn = @'
const o1 = await run({ brief: 'C:/b/w.md', ..._kl, batch: 1, agents: [{ id: 'X0', items: 'A1' }, { id: 'X1', items: 'A2', dependsOn: ['X0'] }] }, _pass, _n, _n, pipeline)
console.log(`batch-next:${!!(await run(o1.next.args, _pass, _n, _n, pipeline).catch(_err))}`)
'@
Expect-Each (Invoke-Js dw-next $jsn $wfd) 'buildy: #' 'batch-next' -Show 5
# buildy: merge pairs set by the workflow; no ship agent behind an unmerged producer
$jsm = @'
const mr = (r, s) => ({ url: `u/${r}/-/merge_requests/1`, repo: r, merged: false, mergeState: s }), lt = { status: 'PASS' }
const { calls, agent } = _mock((p, o) => ({ 'build:F1': _rep(lt, { mrs: [mr('py')] }), 'build:F2': _rep(lt, { mrs: [mr('java'), mr('web')] }), 'ship:F1': _rep(lt, { mrs: [mr('py', 'WAIT')] }),
 'order:F2': { ok: true, output: 'merge-after: x' } }[o.label] || (/^review/.test(o.label) ? { findings: [] } : undefined)), '[]')
const o = await run({ brief: 'C:/b/w.md', ..._kl, agents: [{ id: 'F1' }, { id: 'F2', dependsOn: ['F1'] }] }, agent, _n, _n, pipeline)
const L = calls.map((c) => c.label), ord = calls[L.indexOf('order:F2')].prompt.replace(/\/-\/merge_requests\/1/g, '')
console.log(`order:${/u\/java>u\/py/.test(ord) && /u\/web>u\/java/.test(ord) && !L.includes('order:F1') && !L.includes('ship:F2') && o.agents[1].report.mrs.every((m) => m.mergeState === 'WAIT')}`)
'@
Expect-Each (Invoke-Js dw-order $jsm $wfd) 'buildy merge order: #' 'order' -Show 9
# buildy: mode duel is an extra (refused, names the extra); a removed arg is warned about, not silently ignored
$jso = @'
const logs = [], base = { brief: 'C:/b/w.md', ..._kl, agents: [{ id: 'X1', items: 'A1' }] }
const e = await run({ ...base, mode: 'duel' }, _pass, _n, _n, pipeline).then(() => '', (x) => x.message)
await run({ ...base, review: false }, _pass, (m) => logs.push(m), _n, pipeline)
console.log(`duel-refused:${/duel is an extra: run kittool.py extra add duel/.test(e)}`)
console.log(`removed-arg:${logs.some((l) => /args.review was removed/.test(l))}`)
'@
Expect-Each (Invoke-Js dw-args $jso $wfd) 'buildy: #' 'duel-refused', 'removed-arg' -Show 5
# buildy deploy batch: skipped without the deploys extra (the step checks for it), parsed with it
$jsdp = @'
const mk = (out, seen) => async (p, o) => { if (o.label === 'deploy-batch') { seen.push(p); return { ok: true, output: out } }
 return _pass(p, o) }
const base = { brief: 'C:/b/w.md', ..._kl, agents: [{ id: 'X1', items: 'A1' }] }
const logs = [], seen = []
const a = await run(base, mk('NO-DEPLOYS', seen), (m) => logs.push(m), _n, pipeline)
const b = await run(base, mk('[{"target":"t1","trigger":"owner"}]', []), _n, _n, pipeline)
console.log(`deploy-skip:${!a.deployBatch && logs.some((l) => /deploys extra is not installed/.test(l)) && seen[0].includes("Test-Path 'C:/kit/skills/orchestrate/adapters/deploys.ps1'")}`)
console.log(`deploy-batch:${Array.isArray(b.deployBatch) && b.deployBatch[0].target === 't1'}`)
'@
Expect-Each (Invoke-Js dw-deploy $jsdp $wfd) 'buildy deploy: #' 'deploy-skip', 'deploy-batch' -Show 5
# buildy resume: each area skips the steps recover found done; all done -> no agent at all
$jsrs = @'
const S = ['build', 'review', 'ci', 'merge', 'testing-doc', 'tracker'], m = (n, merged) => [{ url: `https://h/g/api/-/merge_requests/${n}`, repo: 'api', merged }]
const resume = { D: { skip: S, mrs: m(1, true) }, M: { skip: S.slice(0, 4), mrs: m(2, true) }, O: { skip: ['build'], mrs: m(3, false) } }
const base = { brief: 'C:/b/w.md', ..._kl, mode: 'resume', resume, agents: [{ id: 'D' }, { id: 'M' }, { id: 'O' }, { id: 'N' }] }
const { calls, agent } = _mock((p, o) => /^(build|ship|postmerge):/.test(o.label) ? _rep({ status: 'PASS' }, _merged(9)) : /^review/.test(o.label) ? { findings: [] } : undefined, '[]')
await run(base, agent, _n, _n, pipeline); const L = calls.map((c) => c.label), d = await _mock(() => undefined)
const od = await run({ ...base, agents: [{ id: 'D' }] }, d.agent, _n, _n, pipeline)
console.log(`resume-skip:${!L.some((l) => /:(D|M|O)$/.test(l) && /^build/.test(l)) && L.includes('postmerge:M') && L.includes('build:N') && L.includes('review:O') && !L.some((l) => /^(review|ship):[DM]$/.test(l)) && L.includes('track:M') && !L.includes('track:D')}`)
console.log(`resume-done:${d.calls.length === 0 && od.resumedDone[0].agent === 'D'}`)
'@
Expect-Each (Invoke-Js dw-resume $jsrs $wfd) 'buildy resume: #' 'resume-skip', 'resume-done' -Show 5
$as = & { . $O; $env:KIT_OFFLINE = '0'; function Find-TaskMrs { 'g/api!7' }
  Register-KitAdapter 'git-host' 'gitlab' @{ 'mr.get' = { param($a) [pscustomobject]@{ iid = $a.n; state = 'merged'; title = 'fx9abc'; description = 'Testing doc: https://d/1'; created_at = (Get-Date).ToUniversalTime().AddDays(-2) } } }
  Register-KitAdapter 'tracker' 'none' @{ view = { param($a) [pscustomobject]@{ id = $a.id; name = 'n'; status = 'failed testing' } }; comments = { @() } }
  $f = { param($i, $d) Get-KitAreaState ([pscustomobject]@{ id = 'F'; items = $i }) @() @() (Get-Date).AddDays($d) }
  $o, $n, $g = (& $f 'fx9abc' 0), (& $f 'fx9abc' -3), (& $f 'A3, A4 g/api!2' 0); "$($o.state)|$($o.skip.Count)|$($n.state)|$($n.skip -join ',')|$($n.items[0].doc)|$($g.state)" }
Remove-Item Env:KIT_OFFLINE
Expect 'recover area state: an MR older than the run = earlier work, failedTesting = back to dev; doc link from the MR; a loose MR among 2 items = unknown' ($as -eq 'start|0|merged|build,review,ci,merge,testing-doc|https://d/1|unknown')
# launch records: a fix round supersedes the launch (one recover entry); launch -Done -RunId closes both kinds
$ld = TkPath $k launches -Create; $self = { param($s, $run, $json) $f = Join-Path (Kd) "args-$(Get-Random).json"; [IO.File]::WriteAllText($f, $json); pwsh @np $O launch -Self -Script $s -Run $run -ArgsFile $f -Fnv (& { . $O; Get-KitFnv $json }) @args | Out-String }
$sa = '{"select":{"statuses":["inTest"]},"target":"stg","kitDir":"C:/k"}'
$null = & $self testy.js select-stg $sa -RunDir 'C:/rt/qa-runs/d-stg'
$sr = Get-ChildItem $ld -Filter 'self-testy-select-stg-*.json' | Get-Content -Raw | ConvertFrom-Json
Expect 'launch -Self testy: original args + runDir as extra field' ($sr.argsRaw -eq $sa -and $sr.runDir -eq 'C:/rt/qa-runs/d-stg' -and -not $sr.args.runDir -and (& { . $O; Get-LaunchRunName ($sa | ConvertFrom-Json) }) -eq 'select-stg')
$sf = Get-ChildItem $ld -Filter 'self-testy-select-stg-*.json' | Select-Object -First 1
$sr | Add-Member -Force holderPid 999999; & $J $sr $sf.FullName 10   # its session is gone
$sl0 = pwsh @np $O launch -List -Brief | Out-String
$dn = pwsh @np $O launch -Done -Run select-stg 2>&1 | Out-String; $sl1 = pwsh @np $O launch -List -Brief | Out-String
Expect 'launch -Done -Run: a completed self record (owner-stopped run) is no stopped run' ($sl0 -match 'select-stg' -and $dn -match 'marked completed: self-testy' -and $sl1 -notmatch 'select-stg')
foreach ($n in '', 'fix') { $null = & $self buildy.js dd "{""brief"":""C:/b/dd.md"",""agents"":[{""id"":""D1"",""note"":""$n""}]}" }
$null = pwsh @np $O launch -RunId wf_d1 -Script (Join-Path $k 'workflows/buildy.js') -ArgsJson '{"brief":"C:/b/dd.md","run":"dd"}'
$df = @(Get-ChildItem $ld -Filter '*d*.json' | Where-Object Name -match '^(self-buildy-dd-|wf_d1)' | Sort-Object Name); foreach ($f in $df) { $x = Read-Json $f.FullName; $x.holderPid = 999999; if ($f.Name -like 'self-*' -and "$($x.args.agents[0].note)" -eq '') { $x.at = (Get-Date).AddHours(-1).ToString('o') }; & $J $x $f.FullName 10 }
$dr = pwsh @np $O recover | Out-String; $null = pwsh @np $O launch -Done -RunId wf_d1; $dl = pwsh @np $O launch -List -Brief | Out-String
Expect 'recover: one entry per run (a fix round supersedes the launch); launch -Done -RunId closes both record kinds' (([regex]::Matches($dr, '== buildy\.js run \S+ \(dd\)')).Count -eq 1 -and $dl -notmatch '\bdd\b' -and @($df | Where-Object { (Read-Json $_.FullName).completed }).Count -eq 3)
$wf = Join-Path $src 'workflows/testy.js'
$js = @'
const { calls, agent } = _mock((prompt, o) => {
 if (/^(test|retest):/.test(o.label)) return _res('A1', [_ck('C1', 'NOT_TESTED', { cause: 'env-data' }), _ck('C2', 'PASS'), _ck('C3', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('A1', [_ck('C1', 'PASS')])
 if (/^close/.test(o.label)) return { ok: true, output: 'published' }
})
const args = { runDir: 'C:/runs/R1', ..._kl, items: [_item('A1', 'web')] }
run(args, agent, _n, _n, null).then(() => {
 const s = calls.find((c) => c.label === 'retest-strong:A1'), cl = calls.find((c) => c.label === 'close:A1')
 console.log(`strong:${!!s && s.model === 'opus' && /blocked by env-data/.test(s.prompt) && /ONLY these checks: C1/.test(s.prompt)}`)
 console.log(`closed-pass:${!!cl && /"id":"C1"[^}]*"result":"PASS"/.test(cl.prompt) && /\(stronger retry\)"[^}]*"firstAttempt":/.test(cl.prompt)}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-retry $js $wf) 'testy NOT_TESTED retry: #' 'strong', 'closed-pass'
# testy local: NOT_TESTED -> ENV-FIX + retest; 2 cycles: held
$js3 = @'
const mk = (fixWorks) => _mock((prompt, o) => {
 if (/^(test|retest|retest-strong):/.test(o.label)) return _res('A1', [_ck('C1', 'NOT_TESTED', { cause: 'undeployed', env_fix: 'refresh the release' }), ...(/^retest-strong/.test(o.label) ? [] : [_ck('C2', 'PASS'), _ck('C3', 'PASS'), _ck('C4', 'PASS')])])
 if (/^envfix-ask:/.test(o.label)) return { ok: true, output: `ENV-FIX e-20260101000000-qa-a1 pending` }
 if (/^envfix-wait:/.test(o.label)) return { ok: true, output: 'ANSWERED e-20260101000000-qa-a1: done: refreshed' }
 if (/^envfix-retest:/.test(o.label)) return _res('A1', [_ck('C1', fixWorks ? 'PASS' : 'NOT_TESTED', { cause: 'env-data' })])
})
const args = { runDir: 'C:/runs/R1', ..._kl, localEnv: 'shop', items: [_item('A1')] }
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
# testy: localenv.ps1 / swarm.ps1 calls guarded (extras): a missing one prints the extra line; the prompt names extra sync
$js3b = @'
const { calls, agent } = _mock((prompt, o) => {
 if (/^(test|retest)/.test(o.label)) return _res(o.label.split(':')[1], [_ck('C1', 'PASS')])
})
const args = { runDir: 'C:/runs/R2', ..._kl, verify: false, localEnv: 'shop', lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556' }],
 items: [_item('P1', 'app')] }
run(args, agent, _n, _n, null).then(() => {
 const tp = (calls.find((c) => /^test:P1/.test(c.label)) || {}).prompt || '', rel = (calls.find((c) => c.label === 'release:Falcon') || {}).prompt || ''
 const guard = (s, x) => tp.includes(`if (Test-Path 'C:/kit/skills/${s}') { & 'C:/kit/skills/${s}' `) && tp.includes(`else { '${x} is an extra: run kittool.py extra add ${x}' }`)
 console.log(`local-guard:${guard('local-env/localenv.ps1', 'local-env') && /extra sync \(or extra add local-env\)/.test(tp)}`)
 console.log(`phone-guard:${guard('android-swarm/swarm.ps1', 'android-swarm') && /extra sync \(or extra add android-swarm\)/.test(tp)}`)
 console.log(`release-guard:${/Test-Path 'C:\/kit\/skills\/android-swarm\/swarm\.ps1'.*release -Agent qa-w1-Falcon.*extra add android-swarm/.test(rel)}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-extras $js3b $wf) 'testy extras: #' 'local-guard', 'phone-guard', 'release-guard' -Show 8
# testy retries per check: fewer checks keep the first FAIL; a duplicate (C5b) retries as C5
$js4 = @'
const { calls, agent } = _mock((prompt, o) => {
 if (/^test:/.test(o.label)) return _res('A1', [_ck('C1', 'FAIL', { defect: 'own' }), _ck('C2', 'NOT_TESTED'), _ck('C3', 'NOT_TESTED'), _ck('C4', 'PASS'), _ck('C5', 'PASS'), _ck('C5', 'NOT_TESTED')])
 if (/^retest:/.test(o.label)) return _res('A1', [_ck('C2', 'PASS'), _ck('C3', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('A1', [_ck('C5', 'PASS')])
 if (/^verify:/.test(o.label)) return { verdicts: [{ id: 'C1', outcome: 'confirmed', attempts: 1, observed: 'again', evidence: [], basis: 'none' }] }
}, 'published')
const args = { runDir: 'C:/runs/R4', ..._kl, items: [_item('A1')] }
run(args, agent, _n, _n, null).then(() => {
 const cl = calls.find((c) => c.label === 'close:A1'), s = calls.find((c) => c.label === 'retest-strong:A1')
 console.log(`keeps-fail:${!!cl && /"id":"C1"[^}]*"result":"FAIL"/.test(cl.prompt) && /"id":"C3"[^}]*"result":"PASS"/.test(cl.prompt)}`)
 console.log(`guide-id:${!!s && /ONLY these checks: C5\./.test(s.prompt) && /"id":"C5b"[^}]*"result":"PASS"/.test(cl.prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-merge $js4 $wf
Expect-Each $res 'testy retries: #' 'keeps-fail', 'guide-id' -Show 5
$js2 = @'
const { calls, agent } = _mock((prompt, o) => {
 if (o.label === 'prepare') return { runDir: 'C:/rt/work/qa-runs/2026-01-01-local', items: 1, left: [{ id: 'T9', reason: 'not live' }], summary: 's' }
 if (/^load-run/.test(o.label)) return { json: JSON.stringify({ target: 'local-a', items: [_item('A1', 'api', { target: 'local-b' })] }) }
 if (/^test:/.test(o.label)) return _res('A1', [_ck('C1', 'PASS')])
})
const args = { select: { statuses: ['promoted', 'inTest'], exclude: ['T7'] }, target: 'local', ..._kl }
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
const args = { runDir: 'C:/runs/R9', ..._kl, only: ['F1', 'F2', 'F3'], lanes: ['L'], instance: 'w2', batch: 1 }
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
const mk = () => _mock((prompt, o) => {
 if (/^test:/.test(o.label)) ports.push(/SHARED logged-in Chrome/.test(prompt) && /relogin\(s\)/.test(prompt) && !/killSession\(\)/.test(prompt) && !/session\(\{ port/.test(prompt))
 if (o.label === 'test:W0') return _res('W0', [_ck('C1', 'NOT_TESTED'), _ck('C2', 'PASS'), _ck('C3', 'PASS'), _ck('C4', 'PASS')])
 if (/^(test|retest):/.test(o.label)) return _res('x', [_ck('C1', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('W0', [_ck('C1', 'PASS')])
}, 'published')
const items = Array.from({ length: 45 }, (_, i) => _item(`W${i}`, 'web'))
const a = mk(), b = mk()
run({ runDir: 'C:/runs/P1', ..._kl, items }, a.agent, _n, _n, null)
 .then(() => run({ runDir: 'C:/runs/P1', ..._kl, instance: 'w1', items }, b.agent, _n, _n, null)).then(() => {
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
const { calls, agent } = _mock((prompt, o) => {
 if (/^test:/.test(o.label)) return _res('A1', [_ck('C1', 'FAIL', { defect: 'own', evidence: ['A1-C1_01_500.json'] }), _ck('C2', 'FAIL', { defect: 'own' }), _ck('C3', 'PASS')])
 if (/^verify:/.test(o.label)) return { verdicts: ['C1', 'C2'].map((id) => ({ id, outcome: 'refuted', attempts: 1, observed: 'fine now', evidence: [`A1-${id}_verify_01_ok.json`], basis: 'saved _verify files' })) }
}, 'published')
const args = { runDir: 'C:/runs/R6', ..._kl, items: [_item('A1')] }
run(args, agent, _n, _n, null).then(() => {
 const cl = calls.find((c) => c.label === 'close:A1')
 console.log(`flaky:${!!cl && /"id":"C1"[^}]*"result":"FAIL"[^}]*"verify":"not reproduced \(flaky\)","flaky":true/.test(cl.prompt)}`)
 console.log(`no-evidence:${!!cl && /"id":"C2"[^}]*"result":"PASS_WITH_NOTE"/.test(cl.prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-flaky $js6 $wf
Expect-Each $res 'testy verify: #' 'flaky', 'no-evidence' -Show 5
# budget: a run over its cap is refused with the split; a build handoff resumes from its brief; testy at 80% stops and returns the rest
$jsb = @'
const mk = (out, spent, handoff) => { const calls = []; return { calls, agent: async (p, o) => { calls.push({ label: o.label, prompt: p })
  if (/^record-args/.test(o.label)) return { ok: true, output: `RECORDED x\nBUDGET ${out}` }
  if (o.label === 'budget') return { ok: true, output: JSON.stringify({ spent }) }
  if (/^(build|handoff):/.test(o.label)) return _rep({ status: 'PASS', env: 'e', rounds: 1, failing: [], goalsDoc: 'g' }, { mrs: [], handoff: o.label.startsWith('build') ? handoff : '' })
  if (/^(test|handoff|retest)/.test(o.label)) return { ..._res(o.label.split(':')[1], [_ck('C1', 'PASS')]), handoff: '' }
  return { ..._ok('[]'), json: '' } } } }
const ba = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }, { id: 'X2', items: 'A2' }], mandate: ['m'], ..._kl }
'@
$jsbB = @'
const m1 = mk('{"cap":100000,"estimate":500000,"stopAt":0.8}'); const o1 = await run(ba, m1.agent, _n, _n, pipeline)
console.log(`refuse:${o1.refused === true && o1.batch === 1 && o1.next.args.batch === 1 && !m1.calls.some((c) => /^build:/.test(c.label))}`)
const m2 = mk('{"cap":10000000,"estimate":100000,"stopAt":0.8}', 0, 'C:/b/handoff-X1.md'); const o2 = await run({ ...ba, agents: [ba.agents[0]] }, m2.agent, _n, _n, pipeline)
console.log(`handoff:${m2.calls.some((c) => c.label === 'handoff:X1' && /resume brief C:\/b\/handoff-X1\.md/.test(c.prompt)) && !o2.next}`)
'@
$jsbT = @'
const items = ['W1', 'W2', 'W3'].map((c) => _item(c, 'web', { skipClose: true }))
const m3 = mk('{"cap":1000000,"estimate":750000,"stopAt":0.8}', 900000); const o3 = await run({ runDir: 'C:/r/run1', ..._kl, items, webParallel: 1, mandate: ['m'], verify: false }, m3.agent, _n, _n, null)
console.log(`stop-next:${o3.next && o3.next.args.only.join(',') === 'W2,W3' && m3.calls.some((c) => c.label === 'budget') && !m3.calls.some((c) => c.label === 'test:W2')}`)
'@
Expect-Each (@(Invoke-Js wb-b "$jsb`n$jsbB" $wfd) + @(Invoke-Js wb-t "$jsb`n$jsbT" $wf)) 'workflow budget: #' @('refuse', 'handoff', 'stop-next') -Show 5
# recover, records shaped like 2026-10-23: one task over phase runs and a wave; relaunch under another run name; same item twice
$gw = Join-Path (Kd) 'pw'; New-Item -ItemType Directory -Force $gw | Out-Null; 'a' | Set-Content "$gw/a.txt"; Save-GitRepo $gw base; git -C $gw remote add origin https://h.example/g/api.git
$pa = Invoke-PsTest areas @'
$null = . $args[0] 6>$null; $env:KIT_OFFLINE = '0'; $br = @{ 39 = 't-tsk1abc-5a'; 43 = 't-tsk1abc-6a'; 45 = 't-tsk2abc-rates' }
function Invoke-HostVerb($V, $A) { if ($V -eq 'mr.list') { return @($br.Keys | Where-Object { $br[$_] -eq $A.source_branch } | ForEach-Object { @{ iid = $_ } }) }
  if ($A.n -eq '47') { throw 'host down' }; @{ state = $(if ($A.n -in 39, 45) { 'merged' } else { 'opened' }); source_branch = $br[[int]$A.n]; description = 'Testing doc: https://d.example/1'; created_at = '2026-10-24T00:00:00Z' } }
function Find-TaskMrs($t) { if ($t -eq 'tsk1abc') { 'g/api!39', 'g/api!43' } elseif ($t -eq 'tsk2abc') { 'g/api!45' } else { 'g/web!47' } }
function Get-TrackerTask($t) { @{ status = 'Open' } }; function Get-TrackerComments { }; function Read-KitTracking { @{ tasks = @{ tsk1abc = @{ mrs = @('a!39') } } } }; $KitConf.RepoAliases = [pscustomobject]@{ api = 'a' }
foreach ($c in @('tsk1abc phase 6', '', 't-tsk1abc-6a'), @('tsk1abc phase 5', 'https://h.example/g/api/-/merge_requests/39', ''), @('tsk2abc rates, surcharges', '', 't-tsk2abc-rates'), @('tsk2abc orders', '', 't-tsk2abc-orders'), @('tsk1abc phase 0', '', ''), @('tsk4abc web', '', '', 't-tsk4abc-web'), @('tsk1abc phase 6', '', 't-tsk1abc-6a', '', '', 'https://h.example/g/api/-/merge_requests/39'), @('tsk1abc phase 0', '', '', '', 't-tsk1abc-6a')) {
  $s = Get-KitAreaState @{ id = 'A'; items = $c[0]; branch = $c[3] } @($c[1] | Where-Object { $_ }) @(if ($c[2]) { [pscustomobject]@{ dir = $args[1]; branch = $c[2]; dirty = 0; unpushed = '0' } }) ([datetime]'2026-10-23T10:00') @($c[4] | Where-Object { $_ }) @($c[5] | Where-Object { $_ })
  "$($s.state):$(@($s.items | ForEach-Object { $_.mrs.ref | Sort-Object }) -join ' ')" }
'@ @($O, $gw)
Expect 'recover: MRs by the area''s branch (worktree, checkpoint MR; a reported one on another branch dropped), task id only without one, never a sibling''s branch; merged + registered = done' (($pa -join '|') -eq 'open:g/api!43|done:g/api!39|merged:g/api!45 g/api!45|start:|open:g/api!39 g/api!43|unknown:g/web!47|open:g/api!43|done:g/api!39')
$lq = TkPath $k launches -Create; Remove-Item "$lq/*.json"; $t0 = [datetime]'2026-10-23T10:00'
$rec = { param($f, $m, $x) $r = [ordered]@{ script = "$k/workflows/buildy.js"; at = $t0.AddMinutes($m).ToString('o') }; foreach ($q in $x.Keys) { $r[$q] = $x[$q] }; & $J $r "$lq/$f.json" 10 }
$ar = { param($b, $i) @{ brief = $b; agents = @(@{ id = 'W1'; items = $i }) } }
& $rec wf_a1 0 @{ runId = 'wf_a1'; args = @{} }; & $rec self-buildy-p6-1 1 @{ run = 'p6'; args = (& $ar 'C:/b/p6.md' 'tsk1abc') }
& $rec wf_b2 60 @{ runId = 'wf_b2'; args = @{} }; & $rec self-buildy-wf-a1.resume-2633-2 61 @{ run = 'wf-a1.resume-2633'; args = (& $ar "$lq/wf-a1.resume.md" 'tsk1abc') }
& $rec self-buildy-fix-3 5 @{ run = 'fix'; args = (& $ar 'C:/b/f.md' 'tsk3abc DW1-B-T3, DW1-C-7') }; & $rec self-buildy-fix-r2-4 90 @{ run = 'fix-r2'; args = (& $ar 'C:/b/f2.md' 'tsk3abc DW1-B-T3, DW1-C-7 (fix round 2 on g/api!41)') }
& $rec self-buildy-ph5-6 10 @{ run = 'ph5'; args = (& $ar 'C:/b/ph5.md' 'tsk5abc phase 5') }; & $rec self-buildy-ph6-7 20 @{ run = 'ph6'; args = (& $ar 'C:/b/ph6.md' 'tsk5abc phase 6') }; & $rec self-buildy-old-8 -50 @{ run = 'old'; args = (& $ar "$lq/ph6.resume.md" 'x'); completed = 'x' }
$hl = & { . (Lib); @{ holderPid = $PID; holderStart = (Get-KitPidStart $PID) } }   # a relaunch whose session lives
& $rec wf_c3 30 @{ runId = 'wf_c3'; args = @{} }; & $rec self-buildy-c3-9 30 @{ run = 'c3'; args = (& $ar 'C:/b/c3.md' 'tsk6abc') }; & $rec wf_d4 70 @{ runId = 'wf_d4'; args = @{} }; & $rec self-buildy-wf-c3.resume-1-10 71 (@{ run = 'wf-c3.resume-1'; args = (& $ar "$lq/wf-c3.resume.md" 'tsk6abc') } + $hl)
$runs = { (& { . $O; Get-StoppedRuns -Hours 99999 -All | ForEach-Object run } | Sort-Object) -join ' ' }
$ln = & { . $O; $l = Get-KitLineage @(Get-StoppedRuns -Hours 99999 -All | Where-Object run -eq 'wf-a1.resume-2633')[0]; "$($l.since.ToString('HH:mm'))|$($l.runs -join ',')|$($l.ids -join ',')" }
$l1 = & $runs; $dn = Px $O launch -Done -RunId wf_b2 | Out-String; $null = Px $O launch -Done -RunId wf_c3; $l2 = & $runs
& $rec self-buildy-r3-5 120 @{ run = 'r3'; args = (& $ar "$lq/fix-r2.resume.md" 'tsk9abc'); completed = 'x' }; $l3 = & $runs
Expect 'recover: a relaunch''s lineage: the first launch, its ancestors'' run names and ids' ($ln -eq '10:00|wf-a1.resume-2633|wf_b2,wf_a1')   # a typed launch's run name only from its transcript (none here)
Expect 'recover: a relaunch replaces its original, the same agent + items twice shows once (phases stay); launch -Done closes the lineage, never a live relaunch; a closed relaunch hides its older parent' (
  "$l1|$l2|$l3" -eq 'fix-r2 ph5 ph6 wf-a1.resume-2633 wf-c3.resume-1|fix-r2 ph5 ph6 wf-c3.resume-1|ph5 ph6 wf-c3.resume-1' -and -not @('wf_a1', 'wf_b2', 'p6-1', 'resume-2633' | Where-Object { $dn -notmatch $_ }).Count)
Remove-TestKit $k
Complete-Tests
