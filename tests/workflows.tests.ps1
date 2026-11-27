#Requires -Version 7
<#
workflows.tests.ps1: buildy.js and testy.js sims (agents mocked; node runs the real script body); recover's area states and run lineage.
Also (was workflows-2.tests.ps1): buildy.js / testy.js step wrappers and resume config (workflows-generic.tests.ps1 is at its cap): a usage
limit runs a step once on the next tier (<label>@up), args.config (bossy.ps1 recover) beats the cached CONFIG tiers, the
tracker step is one track add (script groups MRs by title), a tester step with no result retries once.
Usage: pwsh -NoProfile -File <kit>/tests/workflows.tests.ps1 (or tests/kit-tests.ps1 -Area workflows).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit workflows; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# the sims run on a legacy CONFIG line (qa.lanes web/api/app, repo roles); the neutral defaults: sims at the end
$legacyCfg = 'CONFIG {"models":null,"roles":{"api":"producer","java":"producer","py":"producer","web":"consumer"},"qaLanes":{"web":{"kind":"web","parallel":5,"followUp":"app"},"api":{"kind":"api","parallel":5,"followUp":"app"},"app":{"kind":"app","devices":"android"}}}'
$jsLib = [regex]::Replace($jsLib, "(?m)^const _CFG = '.*?'(?=\s)", { "const _CFG = '$legacyCfg'" })
if ($jsLib -notmatch [regex]::Escape("const _CFG = '$legacyCfg'")) { throw 'workflows tests: harness _CFG changed, update the legacy CONFIG hook' }
# buildy local loop: BLOCKED = FAIL; still FAIL -> ONE stronger round; ENV-FIX waits
$wfd = Join-Path $src 'workflows/buildy.js'
$jsd = @'
const lt = (status, extra = {}) => ({ status, env: 'shop r1', rounds: 3, failing: status === 'PASS' ? [] : ['G1 still 500'], goalsDoc: 'g.md', ...extra })
const rep = (status, extra = {}) => _rep(lt(status), extra)
const mk = (envfix, gap) => _mock((prompt, o) => {
 if (/^build:/.test(o.label) && gap) return rep('FAIL', { localTest: lt('FAIL', { envGap: gap === 'gap' }) })
 if (/^local-strong:/.test(o.label) && gap) return rep('FAIL')
 if (/^build:/.test(o.label)) return envfix ? rep('FAIL', { done: [], needsEnvFix: [{ item: 'A1', envFixId: 'e-20260101000000-x1', need: 'refresh the release' }] }) : rep('BLOCKED', { localTest: lt('BLOCKED', { blockedReason: 'local DB missing a table' }) })
 if (/^local:/.test(o.label)) return rep('FAIL')
 if (/^envfix:/.test(o.label)) return { ok: true, output: 'ANSWERED e-20260101000000-x1: done: refreshed r2' }
 if (/^(local-strong|envfix-resume):/.test(o.label)) return rep('PASS')
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ship:/.test(o.label)) return rep('PASS', _merged(1))
}, '[]')
const args = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], ..._kl }
const a = mk(false), b = mk(true), c = mk(false, 'gap'), d = mk(false, 'fail')
run(args, c.agent, _n, _n, pipeline).then((oc) => run(args, d.agent, _n, _n, pipeline).then((od) => {
 const lb = (m, l) => m.calls.some((x) => x.label === l)
 console.log(`env-gap:${!c.calls.some((x) => /^local/.test(x.label)) && lb(c, 'review:X1') && lb(c, 'ship:X1') && !oc.blocked.length && lb(d, 'local-strong:X1') && !lb(d, 'ship:X1') && od.blocked.length === 1}`)
})).then(() => run(args, a.agent, _n, _n, pipeline)).then((oa) => run(args, b.agent, _n, _n, pipeline).then((ob) => {
 const s = a.calls.find((c) => c.label === 'local-strong:X1')
 console.log(`blocked-is-fail:${a.calls.some((c) => c.label === 'local:X1') && !oa.blocked.length}`)
 console.log(`strong-round:${!!s && s.model === 'opus' && /STRONGER FIX ROUND/.test(s.prompt) && a.calls.some((c) => c.label === 'ship:X1')}`)
 console.log(`envfix:${b.calls.some((c) => c.label === 'envfix:X1' && /decide wait -Id e-20260101000000-x1/.test(c.prompt)) && b.calls.some((c) => c.label === 'envfix-resume:X1' && /done: refreshed r2/.test(c.prompt)) && ob.envFixes.length === 1 && b.calls.some((c) => c.label === 'ship:X1')}`)
 console.log(`flow-text:${/"In a \/buildy wave" commands: run \S+, mode \w+, <O> = \S+bossy\.ps1/.test(a.calls.find((c) => c.label === 'build:X1').prompt)}`)
})).catch(_err)
'@
Expect-Each (Invoke-Js dw-local $jsd $wfd) 'buildy local loop: # (env-gap: FAIL only for env gaps is reviewed and shipped, a real FAIL blocks)' 'blocked-is-fail', 'strong-round', 'envfix', 'flow-text', 'env-gap' -Show 5
# buildy: blocking -> fix -> ONE re-review; a deferred item holds promotion, an owner-deferred one or a people step (kind people) not
$jsr = @'
const lt = { status: 'PASS', env: 'shop r1', rounds: 1, failing: [], goalsDoc: 'g.md' }
const rep = (extra = {}) => _rep(lt, extra)
let reviews = 0
const { calls, agent } = _mock((prompt, o) => {
 if (/^build:/.test(o.label)) return rep({ deferred: [{ id: 'A2', reason: 'needs data' }, { id: 'A3', reason: 'o', ownerDecided: true }, { id: 'A4', reason: 'team labels a sheet', kind: 'people' }] })
 if (/^review:/.test(o.label)) return { findings: [{ mr: '1', file: 'a.ts', line: 3, severity: reviews++ ? 'nit' : 'blocking', problem: reviews > 1 ? 'rename y' : 'null check missing', fix: 'add it' }] }
 if (/^fix:/.test(o.label)) return rep({ worktrees: ['c:\\WT\\x1\\'] })
 if (/^ship:/.test(o.label)) return rep(_merged(1))
}, '[]')
const args = { brief: 'C:/b/wave-x.md', agents: [{ id: 'X1', items: 'A1, A2', area: 'a' }], mandate: ['m'], ..._kl }
let lost = 0; const agentLost = async (p, o) => (o.label === 'track:X1' && !lost++) ? null : agent(p, o)
run(args, agentLost, _n, _n, pipeline).then(() => {
 const rv = calls.filter((c) => c.label === 'review:X1'), ti = calls.findIndex((c) => c.label === 'track:X1@redo'), si = calls.findIndex((c) => c.label === 'ship:X1')
 console.log(`re-review:${rv.length === 2 && /RE-REVIEW after fix round 1/.test(rv[1].prompt) && /null check missing/.test(rv[1].prompt) && si > calls.indexOf(rv[1])}`)
 console.log(`follow-ups:${calls.some((c) => c.label === 'followups:X1' && /rename y/.test(c.prompt) && / followups \S+ https:\/\/h\/g\/api/.test(c.prompt))}`)
 console.log(`wt-dedup:${calls[si].prompt.includes('last: C:/wt/x1)')}`)
 console.log(`steps-ref:${/skills\/crafty\/SKILL\.md/.test(calls.find((c) => c.label === 'build:X1').prompt)}`)
 console.log(`hold:${lost === 1 && ti >= 0 && /^STEP: No report came back[\s\S]*-HoldPromotion 'deferred items: A2'/.test(calls[ti].prompt)}`)   // track redone once
 const m = /-Run '([^']+)'/.exec(calls.find((c) => c.label === 'record-args').prompt)
 console.log(`run:${m ? m[1] : 'none'}`)
}).catch(_err)
'@
$res = Invoke-Js dw-review $jsr $wfd
$want = & { . $O; Get-LaunchRunName ([pscustomobject]@{ brief = 'C:/b/wave-x.md' }) }
Expect-Each $res 'buildy: #' 're-review', 'follow-ups', 'hold', 'wt-dedup', 'steps-ref' -Show 5
Expect 'buildy: devy steps (crafty D3): a person''s deferred step = kind: people' ((Get-Content (Join-Path $src 'skills/crafty/SKILL.md') -Raw) -match 'D3\. \*\*Deferred[^\n]*\n[^\n]*`kind: people`')
# buildy: still blocking after fix round 2 -> a decide ask, no merge
$jsb = $jsr -replace "severity: reviews\+\+ \? 'nit' : 'blocking'", "severity: 'blocking', n: reviews++" -replace "if \(/\^ship:/", "if (/^decide:/.test(o.label)) return { ok: true, output: 'DECISION d1 pending' }`n if (/^ship:/" -replace "(?s)run\(args, agentLost, _n, _n, pipeline\)\.then.*", @'
run(args, agent, _n, _n, pipeline).then((o) => console.log(`ask:${calls.filter((c) => c.label === 'fix:X1').length === 2 && calls.filter((c) => c.label === 'review:X1').length === 3 && calls.some((c) => c.label === 'decide:X1' && /Still blocking after 2 fix rounds/.test(c.prompt)) && !calls.some((c) => c.label === 'ship:X1') && calls.some((c) => c.label === 'followups:X1')
  && o.decisions.some((d) => d.agent === 'X1' && d.decisionId === 'd1') && o.openFindings.length > 0}`)).catch(_err)
'@
Expect-Each (Invoke-Js dw-ask $jsb $wfd) 'buildy: #' 'ask' -Show 5
Expect 'buildy: default run name = bossy.ps1 Get-LaunchRunName (buildy-<brief words>, no hash)' (@($res | Where-Object { "$_" -eq "run:$want" }).Count -eq 1 -and $want -eq 'buildy-wave-x')
# buildy: a batch's next run drops producers outside its list
$jsn = @'
const o1 = await run({ brief: 'C:/b/w.md', ..._kl, batch: 1, agents: [{ id: 'X0', items: 'A1' }, { id: 'X1', items: 'A2', dependsOn: ['X0'] }] }, _pass, _n, _n, pipeline)
console.log(`batch-next:${!!(await run(o1.next.args, _pass, _n, _n, pipeline).catch(_err))}`)
'@
Expect-Each (Invoke-Js dw-next $jsn $wfd) 'buildy: #' 'batch-next' -Show 5
# buildy dependsOn: producer never merges -> no consumer build
$jsm = @'
const mr = (r, s) => ({ url: `u/${r}/-/merge_requests/1`, repo: r, merged: false, mergeState: s }), lt = { status: 'PASS' }
const { calls, agent } = _mock((p, o) => ({ 'build:F1': _rep(lt, { mrs: [mr('py')] }), 'build:F2': _rep(lt, { mrs: [mr('java'), mr('web')] }), 'ship:F1': _rep(lt, { mrs: [mr('py', 'WAIT')] }),
 'order:F2': { ok: true, output: 'merge-after: x' } }[o.label] || (/^review/.test(o.label) ? { findings: [] } : undefined)), '[]')
const o = await run({ brief: 'C:/b/w.md', ..._kl, agents: [{ id: 'F1' }, { id: 'F2', dependsOn: ['F1'] }] }, agent, _n, _n, pipeline)
const L = calls.map((c) => c.label)
console.log(`gate:${L.includes('producer-wait:F2') && !L.includes('build:F2') && o.blocked.some((b) => /F1 not MERGED/.test(b.why) && b.agent === 'F2' && (b.blockedBy || []).join() === 'F1') && !o.next && o.afterMerge.waitFor.join() === 'F1' && o.afterMerge.next.args.agents.map((g) => g.id).join() === 'F2'}`)
'@
Expect-Each (Invoke-Js dw-order $jsm $wfd) 'buildy dependsOn: #' 'gate' -Show 9
# the producer merges in the wait: the consumer builds and merges
$jsw = $jsm -replace "'order:F2':", "'producer-wait:F2': { ok: true, output: '{""done"":true,""mrs"":[{""mr"":""u/py/-/merge_requests/1"",""status"":""merged""}]}' }, 'ship:F2': _rep(lt, { mrs: [mr('java', 'MERGED'), mr('web', 'MERGED')] }), 'order:F2':" -replace '(?s)console\.log\(`gate:.*', @'
const ord = calls[L.indexOf('order:F2')].prompt.replace(/\/-\/merge_requests\/1/g, '')
console.log(`consumer-merges:${/pipes -Mrs u\/py\S* -MaxMinutes 9 -UntilMerged/.test(calls[L.indexOf('producer-wait:F2')].prompt) && L.indexOf('build:F2') > L.indexOf('producer-wait:F2') && /u\/web>u\/java/.test(ord) && !/>u\/py/.test(ord) && o.agents[1].report.mrs.every((m) => m.mergeState === 'MERGED')}`)
'@
$jsx = $jsm -replace "mr\('py', 'WAIT'\)", "mr('py', 'NOT_MERGED')" -replace '(?s)console\.log\(`gate:.*', "console.log(``no-poll:`${!L.includes('producer-wait:F2') && !L.includes('build:F2')}``)`n"
Expect-Each (Invoke-Js dw-pwait $jsw $wfd) 'buildy merge order: #' 'consumer-merges' -Show 9
Expect-Each (Invoke-Js dw-nopoll $jsx $wfd) 'buildy dependsOn: NOT_MERGED, no poll: #' 'no-poll' -Show 9
# buildy: an unknown mode (duel) is refused; a removed arg is refused, never ignored
$jso = @'
const base = { brief: 'C:/b/w.md', ..._kl, agents: [{ id: 'X1', items: 'A1' }] }, err = (a) => run(a, _pass, _n, _n, pipeline).then(() => '', (x) => x.message)
const e = await err({ ...base, mode: 'duel' }), r = await err({ ...base, review: false }), g = await err({ ...base, agents: [{ id: 'X1', items: 'A1', notes: 'n' }] })
console.log(`mode-refused:${/^args\.mode 'duel' is not supported$/.test(e)}`)
console.log(`removed-arg:${/buildy\.js args refused: unknown review/.test(r)}`)
console.log(`agent-key:${/refused: unknown agents\.X1\.notes/.test(g)}`)
'@
Expect-Each (Invoke-Js dw-args $jso $wfd) 'buildy: #' 'mode-refused', 'removed-arg', 'agent-key' -Show 5
# buildy: rechy spike first, open -> no devy; datay reviews migrations twice, none = no merge
$jssp = @'
const M = 'migration-review:X1', ok = (p, o) => /^(build|ship|fix):/.test(o.label) ? _rep({ status: 'PASS' }, /^sh/.test(o.label) ? _merged(1) : {}) : /review:/.test(o.label) ? { findings: [] } : undefined
const go = async (x, f = ok, no) => { const m = _mock(f), ty = {}; const r = await run({ brief: 'w.md', ..._kl, agents: [{ id: 'X1', migrations: 1 }], ...x }, (p, o) => { ty[o.label] = o.agentType; return o.label.startsWith(M) && no ? null : m.agent(p, o) }, _n, _n, pipeline); return { r, ty, L: m.calls.map((c) => c.label) } }
const n = (L, l) => L.filter((x) => x === l).length, a = await go({ openQuestions: ['q'] })
const b = await go({ openQuestions: ['q'] }, (p, o) => o.label === 'spike' ? { ok: false, output: 'D-7' } : ok(p, o)), z = await go({}, ok, 1)
let k = 0; const f = await go({}, (p, o) => o.label === M && !k++ ? { findings: [{ mr: '1', file: 'm', severity: 'blocking', problem: 'p', fix: 'f' }] } : ok(p, o))
console.log(`spike:${a.ty.spike === 'rechy' && a.L.indexOf('spike') < a.L.indexOf('build:X1') && b.r.spikeOpen === 'D-7' && !n(b.L, 'build:X1') && !b.r.next.args.openQuestions}`)
console.log(`migration:${a.ty[M] === 'datay' && !n(z.L, 'ship:X1') && n(f.L, 'fix:X1') + n(f.L, M) + n(f.L, 'ship:X1') === 4}`)
'@
Expect-Each (Invoke-Js dw-spike $jssp $wfd) 'buildy: #' 'spike', 'migration' -Show 5
# buildy resume: an area skips steps recover found done; all done -> no agent
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
$asCfg = Join-Path $k 'skills/crafty/kit.local.json'; & $J @{ gitHost = 'gitlab.com' } $asCfg   # the pre-2 default host (no host: no adapter)
$as = & { . $O; $env:KIT_OFFLINE = '0'; function Find-TaskMrs { 'g/api!7' }
  Register-KitAdapter 'git-host' 'gitlab' @{ 'mr.get' = { param($a) [pscustomobject]@{ iid = $a.n; state = 'merged'; title = 'fx9abc'; source_branch = 'f-x'; description = 'Testing doc: https://d/1'; created_at = (Get-Date).ToUniversalTime().AddDays(-2) } } }
  Register-KitAdapter 'tracker' 'none' @{ view = { param($a) [pscustomobject]@{ id = $a.id; name = 'n'; status = 'failed testing' } }; comments = { @() } }
  $f = { param($i, $d, $b) Get-KitAreaState ([pscustomobject]@{ id = 'F'; items = $i; branch = $b }) @() @() (Get-Date).AddDays($d) }
  $o, $n, $g = (& $f 'fx9abc' 0), (& $f 'fx9abc' -3), (& $f 'A3, A4 g/api!2' 0 f-x); "$($o.state)|$($o.skip.Count)|$($n.state)|$($n.skip -join ',')|$($n.items[0].doc)|$($g.state)" }
Remove-Item Env:KIT_OFFLINE; Remove-Item $asCfg
Expect 'recover area state: MR older than the run = earlier work; failedTesting = dev; doc link from the MR; a loose MR, 2 items = unknown' ($as -eq 'start|0|merged|build,review,ci,merge,testing-doc|https://d/1|unknown')
# launch records: a fix round supersedes the launch; launch -Done -RunId closes both
$ld = TkPath $k launches -Create; $self = { param($s, $run, $json) $f = Join-Path (Kd) "args-$(Get-Random).json"; [IO.File]::WriteAllText($f, $json); pwsh @np $O launch -Self -Script $s -Run $run -ArgsFile $f -Fnv (& { . $O; Get-KitFnv $json }) @args | Out-String }
$sa = '{"select":{"statuses":["inTest"]},"target":"stg","kitDir":"C:/k"}'
$null = & $self testy.js select-stg $sa -RunDir 'C:/rt/qa-runs/d-stg'
$sr = Get-ChildItem $ld -Filter 'self-testy-select-stg-*.json' | Get-Content -Raw | ConvertFrom-Json
Expect 'launch -Self testy: original args + runDir as extra field' ($sr.argsRaw -eq $sa -and $sr.runDir -eq 'C:/rt/qa-runs/d-stg' -and -not $sr.args.runDir -and (& { . $O; Get-LaunchRunName ($sa | ConvertFrom-Json) }) -eq 'testy-stg')
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
 console.log(`test-sonnet:${calls.find((c) => c.label === 'test:A1').model === 'sonnet'}`)
 console.log(`closed-pass:${!!cl && /"C1":\{[^}]*"result":"PASS"/.test(cl.prompt) && /\(stronger retry\)"[^}]*"firstAttempt":/.test(cl.prompt)}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js tc-retry $js $wf) 'testy NOT_TESTED retry: #' 'strong', 'closed-pass', 'test-sonnet'
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
 console.log(`envfix-pass:${!!cl && /"C1":\{[^}]*"result":"PASS"/.test(cl.prompt) && /LOCAL ENV "shop"/.test(a.calls.find((c) => c.label === 'test:A1').prompt)}`)
 console.log(`envfix-held:${b.calls.filter((c) => c.label === 'envfix-ask:A1').length === 2 && !b.calls.some((c) => /^close/.test(c.label)) && b.calls.some((c) => c.label === 'hold:A1' && /ENV-FIX/.test(c.prompt)) && out.envFixOpen.includes('A1')}`)
}).catch(_err)
'@
$res = Invoke-Js tc-envfix $js3 $wf
Expect-Each $res 'testy local: #' 'envfix-ask', 'envfix-pass', 'envfix-held' -Show 5
# testy retries per check: fewer checks keep the first FAIL; duplicate C5b retries as C5
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
 console.log(`keeps-fail:${!!cl && !/"C1":\{[^}]*"result"/.test(cl.prompt) && /"C3":\{[^}]*"result":"PASS"/.test(cl.prompt) && /results patch/.test(cl.prompt)}`)
 console.log(`guide-id:${!!s && /ONLY these checks: C5\./.test(s.prompt) && /"C5b":\{[^}]*"result":"PASS"/.test(cl.prompt)}`)
 console.log(`scoped-retest:${/ONLY these checks: C2, C3, C5\./.test(calls.find((c) => c.label === 'retest:A1').prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-merge $js4 $wf
Expect-Each $res 'testy retries: #' 'keeps-fail', 'guide-id', 'scoped-retest' -Show 5
$js2 = @'
const { calls, agent } = _mock((prompt, o) => {
 if (o.label === 'prepare') return _ok('RUN ' + JSON.stringify({ runDir: 'C:/rt/work/qa-runs/2026-01-01-local', target: 'local-a', items: [_item('A1', 'api', { target: 'local-b' })], left: [{ id: 'T9', reason: 'not live' }] }))
 if (/^load-run/.test(o.label)) throw new Error('no load-run')
 if (/^test:/.test(o.label)) return _res('A1', [_ck('C1', 'PASS')])
})
const args = { select: { statuses: ['promoted', 'inTest'], exclude: ['T7'] }, target: 'local', ..._kl }
const logs = []
run(args, agent, (m) => logs.push(m), () => {}, null).then(() => {
 const p = calls.find((c) => c.label === 'prepare'), t = calls.find((c) => c.label === 'test:A1'), recs = calls.filter((c) => c.label === 'record-args'), orig = JSON.stringify(args)
 // the launch record == the original args (before Prepare), then the same args + the resolved runDir
 const rec = recs.length === 2 && calls.indexOf(recs[0]) < calls.indexOf(p) && recs.every((r) => r.prompt.includes(`<<<ARGS\n${orig}\nARGS>>>`) && /-Run 'testy-local'/.test(r.prompt)) &&
  !/-RunDir/.test(recs[0].prompt) && recs[1].prompt.includes("-RunDir 'C:/rt/work/qa-runs/2026-01-01-local'")
 console.log(`prepare:${!!p && /"statuses":\["promoted","inTest"\]/.test(p.prompt) && /"target":"local"/.test(p.prompt) && /"exclude":\["T7"\]/.test(p.prompt) && /qa-runs\/<testy-id>"/.test(p.prompt) && /"name":"local-promoted-inTest"/.test(p.prompt)}`)
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
 return /^load-run/.test(o.label) ? _ok('RUN ' + JSON.stringify({ items: [1, 2, 3, 4].map((n) => ({ code: `F${n}`, lane: 'api' })) }))
  : /^record-args/.test(o.label) ? _ok(rec) : /^test:/.test(o.label) ? _res(o.label.slice(5, 7), [_ck('C1', 'PASS')]) : _ok('') }
const args = { runDir: 'C:/runs/R9', ..._kl, only: ['F1', 'F2', 'F3'], lanes: ['L'], instance: 'w2', batch: 1 }
const keep = (n, only) => !!n && n.args.lanes[0] === 'L' && n.args.instance === 'w2' && n.args.only.join() === only
run(args, mk('RECORDED\n' + _CFG), _n, _n, null).then(async (o) => {
 const r = await run(args, mk('RECORDED\nBUDGET {"cap":100,"estimate":1000}\n' + _CFG), _n, _n, null)
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
# a FAIL a re-test misses: evidence: stays FAIL, else may pass
$js6 = @'
const { calls, agent } = _mock((prompt, o) => {
 if (/^test:/.test(o.label)) return _res('A1', [_ck('C1', 'FAIL', { defect: 'own', evidence: ['A1-C1_01_500.json'] }), _ck('C2', 'FAIL', { defect: 'own' }), _ck('C3', 'PASS')])
 if (/^verify:/.test(o.label)) return { verdicts: ['C1', 'C2'].map((id) => ({ id, outcome: 'refuted', attempts: 1, observed: 'fine now', evidence: [`A1-${id}_verify_01_ok.json`], basis: 'saved _verify files' })) }
}, 'published')
const args = { runDir: 'C:/runs/R6', ..._kl, items: [_item('A1')] }
run(args, agent, _n, _n, null).then(() => {
 const cl = calls.find((c) => c.label === 'close:A1')
 console.log(`flaky:${!!cl && /"C1":\{[^}]*"not reproduced \(flaky\) \|[^}]*"flaky":true/.test(cl.prompt)}`)
 console.log(`no-evidence:${!!cl && /"C2":\{[^}]*"result":"PASS_WITH_NOTE"[^}]*Re-test/.test(cl.prompt)}`)
}).catch(_err)
'@
$res = Invoke-Js tc-flaky $js6 $wf
Expect-Each $res 'testy verify: #' 'flaky', 'no-evidence' -Show 5
# budget: over cap -> refused + split; handoff -> brief + learn; testy at 80%: the rest
$jsb = @'
const mk = (out, spent, handoff) => { const calls = []; return { calls, agent: async (p, o) => { calls.push({ label: o.label, prompt: p })
  if (/^record-args/.test(o.label)) return { ok: true, output: `RECORDED x\nBUDGET ${out}\nCONFIG {}` }
  if (o.label === 'budget') return { ok: true, output: JSON.stringify({ spent }) }
  if (/^(build|handoff):/.test(o.label)) return _rep({ status: 'PASS', env: 'e', rounds: 1, failing: [], goalsDoc: 'g' }, { mrs: [], handoff: o.label.startsWith('build') ? handoff : '' })
  if (/^(test|handoff|retest)/.test(o.label)) return { ..._res(o.label.split(':')[1], [_ck('C1', 'PASS')]), handoff: '' }
  return { ..._ok('[]'), json: '' } } } }
const ba = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }, { id: 'X2', items: 'A2' }], mandate: ['m'], ..._kl }
'@
$jsbB = @'
const m1 = mk('{"cap":100000,"estimate":500000,"stopAt":0.8}'); const o1 = await run(ba, m1.agent, _n, _n, pipeline)
console.log(`refuse:${o1.refused === true && o1.batch === 1 && o1.next.args.batch === 1 && !m1.calls.some((c) => /^build:/.test(c.label))}`)
const m2 = mk('{"cap":10000000,"estimate":100000,"stopAt":0.8}', 42, 'C:/b/h1.md'); const o2 = await run({ ...ba, learn: 1, agents: [ba.agents[0]] }, m2.agent, _n, _n, pipeline)
console.log(`handoff:${m2.calls.some((c) => c.label === 'handoff:X1' && /brief C:\/b\/h1\.md[^]*learn -Sk/.test(c.prompt)) && !o2.next && o2.budget.spent === 42}`)
'@
$jsbT = @'
const items = ['W1', 'W2', 'W3'].map((c) => _item(c, 'web', { skipClose: true }))
const m3 = mk('{"cap":1000000,"estimate":750000,"stopAt":0.8}', 900000); const o3 = await run({ runDir: 'C:/r/run1', ..._kl, items, webParallel: 1, mandate: ['m'], verify: false }, m3.agent, _n, _n, null)
console.log(`stop-next:${o3.next && o3.next.args.only.join(',') === 'W2,W3' && m3.calls.filter((c) => c.label === 'budget').length === 2 && !m3.calls.some((c) => c.label === 'test:W2')}`)
'@
Expect-Each (@(Invoke-Js wb-b "$jsb`n$jsbB" $wfd) + @(Invoke-Js wb-t "$jsb`n$jsbT" $wf)) 'workflow budget: #' @('refuse', 'handoff', 'stop-next') -Show 5
# recover: one task over phase runs + a wave; relaunch under another name; one item twice
$gw = Join-Path (Kd) 'pw'; New-Item -ItemType Directory -Force $gw | Out-Null; 'a' | Set-Content "$gw/a.txt"; Save-GitRepo $gw base; git -C $gw remote add origin https://h.example/g/api.git
$pa = Invoke-PsTest areas @'
$null = . $args[0] 6>$null; $env:KIT_OFFLINE = '0'; $br = @{ 39 = 't-tsk1abc-5a'; 43 = 't-tsk1abc-6a'; 45 = 't-tsk2abc-rates' }
function Invoke-HostVerb($V, $A) { if ($V -eq 'mr.list') { return @($br.Keys | Where-Object { $br[$_] -eq $A.source_branch } | ForEach-Object { @{ iid = $_ } }) }
  if ($A.n -eq '47') { throw 'host down' }; @{ state = $(if ($A.n -in 39, 45) { 'merged' } else { 'opened' }); source_branch = $br[[int]$A.n]; description = 'Testing doc: https://d.example/1'; created_at = '2026-10-24T00:00:00Z' } }
function Find-TaskMrs($t) { if ($t -eq 'tsk1abc') { 'g/api!39', 'g/api!43' } elseif ($t -eq 'tsk2abc') { 'g/api!45' } else { 'g/web!47' } }
function Get-TrackerTask($t) { @{ status = 'Open' } }; function Get-TrackerComments { }; function Read-KitTracking { @{ tasks = @{ tsk1abc = @{ mrs = @('a!39') } } } }; $KitConf.RepoAliases = [pscustomobject]@{ api = 'a' }
foreach ($c in @('tsk1abc phase 6', '', 't-tsk1abc-6a'), @('tsk1abc phase 5', 'https://h.example/g/api/-/merge_requests/39', ''), @('tsk2abc rates, surcharges', '', 't-tsk2abc-rates'), @('tsk2abc orders g/api!45', '', 't-tsk2abc-orders'), @('tsk2abc fix g/api!43', '', '', 't-tsk1abc-6a'), @('z g/api!43'), @('z g/api!43', '', '', '', 't-tsk1abc-6a'), @('tsk1abc phase 0', '', ''), @('tsk4abc web', '', '', 't-tsk4abc-web'), @('tsk1abc phase 6', '', 't-tsk1abc-6a', '', '', 'https://h.example/g/api/-/merge_requests/39'), @('tsk1abc phase 0', '', '', '', 't-tsk1abc-6a')) {
  $s = Get-KitAreaState @{ id = 'A'; items = $c[0]; branch = $c[3] } @($c[1] | Where-Object { $_ }) @(if ($c[2]) { [pscustomobject]@{ dir = $args[1]; branch = $c[2]; dirty = 0; unpushed = '0' } }) ([datetime]'2026-10-23T10:00') @($c[4] | Where-Object { $_ }) @($c[5] | Where-Object { $_ })
  "$($s.state):$(@($s.items | ForEach-Object { $_.mrs.ref | Sort-Object }) -join ' ')" }
'@ @($O, $gw)
Expect 'recover: MRs on the area''s branch (worktree, checkpoint, note; none known: a note's MR unless a sibling's), task id only without one, never a sibling''s; merged + registered = done' (($pa -join '|') -eq 'open:g/api!43|done:g/api!39|merged:g/api!45 g/api!45|start:|open:g/api!43|open:g/api!43|start:|open:g/api!39 g/api!43|unknown:g/web!47|open:g/api!43|done:g/api!39')
$lq = TkPath $k launches -Create; Remove-Item "$lq/*.json"; $t0 = (Get-Date).Date.AddDays(-2).AddHours(10)
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
Expect 'recover: a relaunch''s lineage: the first launch, its ancestors'' run names and ids' ($ln -eq '10:00|wf-a1.resume-2633|wf_b2,wf_a1')   # a typed launch: run name from its transcript only
Expect 'recover: a relaunch replaces its original, same agent + items once (phases stay); launch -Done closes the lineage, never a live relaunch; a closed relaunch hides its parent' (
  "$l1|$l2|$l3" -eq 'fix-r2 ph5 ph6 wf-a1.resume-2633 wf-c3.resume-1|fix-r2 ph5 ph6 wf-c3.resume-1|ph5 ph6 wf-c3.resume-1' -and -not @('wf_a1', 'wf_b2', 'p6-1', 'resume-2633' | Where-Object { $dn -notmatch $_ }).Count)
$cap = Invoke-PsTest 'caption-test' ". `$args[0]; Caption 'TA1R-T1_01_new-instructions.png'; Caption 'TA1R-T1_verify_02_after-save.png'" @(Join-Path $k 'skills/pokey/pokey.ps1')
Expect "Caption renders standard evidence names ($($cap -join ' | '))" (($cap -join '|') -ceq 'New instructions|After save (independent re-test)')
$mdOut = & { . (Lib); $b = @(ConvertFrom-KitMarkdown "x`n| A |`n|---|`n| [x](https://u) a \| b<br>c |`n- i`n|no|"); $c = $b[1].rows[1][0]; "$($b.type)|$c|$((ConvertFrom-KitMdInline $c).mark)" -replace '\s+', ' ' }
Expect "markdown: a table needs its rule row; items, paras; inline link, br ($mdOut)" ($mdOut.Trim() -eq 'para table item para|[x](https://u) a | b<br>c|link br')
$ao = pwsh -NoProfile -Command ". '$O'; `$s = @{ acts = @('ft x'); actSec = @{ 'ft x' = 'ft' } }; `$n = Get-Date; foreach (`$c in @(@(), @{}, @('st')), @(@('ft x'), @{ 'ft x' = 'ft' }, @('ft')), @(@('b'), @{ b = 'st' }, @('st', 'ft')), @(@('b', 'c'), @{ b = 'st'; c = 'ft' }, @('st')), @(@('b', 'c'), @{ b = 'st'; c = 'ft' }, @('st', 'ft'))) { `"`$(@(Add-KitActObs `$s `$c[0] `$n `$c[1] `$c[2]) -join '+')/`$(`$s.acts -join '+')`" }"
Expect "supervise: a skipped section keeps its ACTs; a cut-short one's new ACT waits ($($ao -join ' | '))" (($ao -join '|') -eq '/ft x|/ft x|b/b|/b|c/b+c')
# ---- was workflows-2.tests.ps1 (same test kit)
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
// 2026-11-26 (steppy review): a session that predates steppy throws on its agentType: its STEPs run on kitty (record-args, release)
const seenAt = [], noStep = await run({ brief: 'C:/b/g.md', ..._kl, agents: [{ id: 'G1' }] }, async (p, o) => { seenAt.push(`${o.label}=${o.agentType}`); if (o.agentType === 'steppy') throw new Error("Agent type 'steppy' not found")
 return /^record-args/.test(o.label) ? _ok(`RECORDED x\n${_B}\n${_C}\n${_S}`) : _ok('[]') }, _n, _n, pipeline).then(() => 'ran', (e) => String(e.message))
const okNoStep = !/steppy/.test(noStep) && seenAt.includes('record-args=kitty') && seenAt.includes('release:G1=kitty'); console.log(`no-steppy:${okNoStep}`); if (!okNoStep) console.log(`  ${noStep.slice(0, 80)} | ${seenAt.join(' ').slice(0, 300)}`)
'@
Expect-Each (Invoke-Js w2-buildy $jsb $wfd) 'buildy: #' 'limit-up', 'limit-same-tier', 'other-error', 'resume-tiers', 'track-script', 'config-reworded', 'budget-reworded', 'no-steppy' -Show 6
# a devy that hands off forever (a 200k agentCap.devy, owner 2026-11-27): HANDOFFS 8, then the item halts, never reviewed half-done
$jsh = @'
const hoCalls = []
const hoAgent = async (p, o) => { hoCalls.push(o.label)
  if (/^record-args/.test(o.label)) return { ok: true, output: 'RECORDED x\nBUDGET {"cap":10000000,"estimate":100000,"stopAt":0.8}\nCONFIG {}' }
  if (o.label === 'budget') return { ok: true, output: JSON.stringify({ spent: 1 }) }
  if (/^(build|handoff):/.test(o.label)) return _rep({ status: 'PASS', env: 'e', rounds: 1, failing: [], goalsDoc: 'g' }, { mrs: [], handoff: 'C:/b/h.md' })
  return { ..._ok('[]'), json: '' } }
await run({ brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }], mandate: ['m'], ..._kl }, hoAgent, _n, _n, pipeline)
const hoN = hoCalls.filter((l) => l === 'handoff:X1').length
console.log(`cap:${hoN === 8 && !hoCalls.some((l) => /^(review|ship|fix|docs):/.test(l))}`); console.log(`${hoN} handoffs: ${hoCalls.join(' ')}`)
'@
Expect-Each (Invoke-Js w2-handoff $jsh $wfd) 'buildy handoffs: # (8, then the item halts: no review / ship / fix)' 'cap' -Show 3
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
  "$($t.fast)/$($t.balanced)/$($t.strong)/$($t.inherit)|$($c.models.build)/$($c.models.docs)/$($c.models.retestEffort)|$($c.tiers.strong)|$((Get-KitTiers local).strong)|$($f.what)" }
$env:KIT_NOW = '2026-11-29T23:59+05:30'; $d = [pscustomobject]@{ at = (Get-Date); rows = @(); flags = @(Get-KitSuperviseFlagsModelOverride) }
"brief:$(@(Format-KitSuperviseOut $d @() 'C:/r/supervise-report.html') -match '^INFO · model override m-all until')"
"sites:$(Get-KitModelNote)|$(Get-KitModelArg)|$(Resolve-KitPlanModel 'sonnet' 'claude')/$(Resolve-KitPlanModel 'inherit' 'claude')/$(Resolve-KitPlanModel 'small-a' 'local')|$((Get-KitPlanCap 'devy/@build=sonnet:1' claude).cap -eq (Get-KitPlanCap 'devy/m-all:1' claude).cap)"
"action:$("$($d.flags[0].action)" -match "as the LAST key: config: \{ tiers: \{ fast: 'm-all', balanced: 'm-all', strong: 'm-all' \} \}")"
# recover's args + config: a config in the middle keeps every key after it (the appended one wins), a last one is replaced, tidy untouched
$mid = Add-KitResumeConfig '{"brief":"C:/b.md","config":{"tiers":{"fast":"x"}},"agents":[{"id":"A1"}],"local":{"lane":"r4"}}' 'buildy.js'
$last = Add-KitResumeConfig '{"brief":"C:/b.md","agents":[{"id":"A1"}],"config":{"tiers":{"fast":"x"},"models":{"tiers":{"claude":{"fast":"y"}}}}}' 'testy.js'
"resume:$($mid -match '"agents":\[\{"id":"A1"\}\],"local":\{"lane":"r4"\},"config":')/$(($mid | ConvertFrom-Json -AsHashtable).config.tiers.fast)/$([regex]::Matches($last, '"config":').Count)/$(($last | ConvertFrom-Json).config.tiers.fast)/$(Add-KitResumeConfig '{"a":1}' 'tidy.js')"
foreach ($u in ('{"u":"2026-11-30T00:00:00+05:30"}' | ConvertFrom-Json).u, '30 Nov 2026', '') { $__cfg.models.override.until = $u; "until:$([bool](Get-KitModelOverride))" }
$__cfg.models.override = 'm-all'; "string:$([bool](Get-KitModelOverride))"
'@ @($O)
$exM = (Get-Content (Join-Path $src 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json).models
Expect "models.override: before until every claude tier and model id = the model (tier names, efforts; local untouched), supervise says so; after it the config again; python the same; defaults unchanged ($($ov -join ' // ') $($ovV.Trim()))" (
  $ov[0] -eq 'm-all/m-all/m-all/|m-all/fast/high|m-all||model override m-all until 2026-11-30 00:00 +05:30' -and $ov[1] -eq 'haiku/sonnet/opus/|m-own/fast/high|opus||' -and $ovV.Trim() -eq 'm-all||||' -and
  ($ov -join ' ') -match 'brief:INFO · model override' -and ($ov -join ' ') -match "sites:MODEL m-all until 2026-11-30 00:00 \+05:30: pass model: 'm-all'[^|]*\|, model: 'm-all'\|m-all/inherit/small-a\|True" -and ($ov -join ' ') -match 'until:True until:False until:False string:False' -and ($ov -join ' ') -match 'action:True resume:True/m-all/1/m-all/\{"a":1\} ' -and
  "$($exM.tiers.claude.fast)/$($exM.tiers.claude.strong)/$($exM.override.model)" -eq 'haiku/opus/' -and (Get-Content (Join-Path $src 'agents/devy.md') -Raw) -match '(?m)^model: sonnet\r?$')
Remove-TestKit $k
Complete-Tests
