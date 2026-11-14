#Requires -Version 7
<#
debate.tests.ps1: bossy.ps1 debate (1 per run, -Owner, A/B options, each role's Character, the owner's table + decide ask) and the
buildy sims of the review rebuttal (disputes) and the trigger debates (brief, dispute, rejected twice, low confidence).
Usage: pwsh -NoProfile -File <kit>/tests/debate.tests.ps1 (or tests/kit-tests.ps1 -Area debate).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit debate; $O = Join-Path $k 'skills/bossy/bossy.ps1'; $wfd = Join-Path $src 'workflows/buildy.js'
Copy-Item (Join-Path $src agents) $k -Recurse -Force; $dbs = pwsh @np $O debate start -Run dr -Agent X1 -Item A2 -Question 'Cache prices?' -Options 'A: per request — exact','B: cached — fast' -Why brief
$dbf = "$dbs" -replace '^DEBATE ', ''; $null = pwsh @np $O debate start -Run dr -Item A3 -Question q -Options 'A: x','B: y' -Why dispute; $dbc = $LASTEXITCODE
$dbo = pwsh @np $O debate start -Run dr -Item A3 -Question q -Options 'A: x','B: y' -Owner | Out-String; $null = pwsh @np $O debate start -Item A3 -Question q -Options '1: x','2: y'; $dbu = $LASTEXITCODE
$dbA = pwsh @np $O debate brief -File $dbf -Side B -Round 0 | Out-String; $dbR = pwsh @np $O debate brief -File $dbf -Side revy -Round 1 | Out-String
$dbj = Get-Content $dbf -Raw | ConvertFrom-Json -AsHashtable; $dbj.verdict = @{ recommend = 'A'; why = 'SLO holds (slo.md:4)' }; $dbj.rows = @{ A = @{} }
Set-JsonFile $dbf $dbj; $null = pwsh @np $O debate ask -File $dbf; $dbx = $LASTEXITCODE
$dbj.rows = @(@{ option = 'A'; label = 'Per request'; change = 'always current'; cost = '+40 ms'; risk = 'DB load'; effort = '0.5 d'; evidence = @('P.java:88'); against = 'p95 +40 ms' },
  @{ option = 'B'; label = 'Cached'; change = 'lags 5 min'; cost = '-35 ms'; risk = 'stale price'; effort = '1 d'; evidence = @('C.java:20'); against = 'a wrong price at 9:00' })
Set-JsonFile $dbf $dbj; $dbk = pwsh @np $O debate ask -File $dbf | Out-String
Expect "debate: 2nd per run refused (1), -Owner allowed, options not A:/B: or rows not [A, B] = usage (2); brief: Character + round; ask: table, decide ask ($dbc $dbu $dbx)" ($dbc -eq 1 -and $dbo -match '^DEBATE ' -and $dbu -eq 2 -and $dbx -eq 2 -and
  $dbA -match 'Cite it or drop it.*\n.*\n.*ROUND 0 \(blind' -and $dbR -match 'Show me the' -and $dbk -match '\| B: Cached \| lags 5 min \| -35 ms \| stale price \| 1 d \| C\.java:20 \| a wrong price at 9:00 \|' -and $dbk -match 'revy recommends A' -and $dbk -match 'DECISION d-')
# buildy sims, one body, variant V: q = brief debate beside the build + a dispute; k = rejected twice; p = moderator fails, answer pending; d = low confidence
$jsq = @'
const V = '__V__', lt = (status = 'PASS') => ({ status, env: 'e r1', rounds: 1, failing: status === 'PASS' ? [] : ['G1'], goalsDoc: 'g.md' }), F = (file, line) => ({ mr: '1', file, line, severity: 'blocking', problem: `p ${file}`, fix: `f ${file}` })
let rv = 0
const m = _mock((p, o) => {
 if (/^debate:/.test(o.label)) return V === 'p' ? { ok: false, output: 'cannot spawn' } : { ok: true, output: 'C:/d/x.json' }
 if (/^debate-ask:/.test(o.label)) return { ok: true, output: 'DECISION d7 pending' }
 if (/^decide:/.test(o.label)) return /decide wait/.test(p) ? { ok: true, output: 'ANSWERED d7: A' } : { ok: true, output: 'DECISION d8 pending' }
 if (/^dispute-wait:/.test(o.label)) return { ok: true, output: V === 'p' ? 'PENDING d8' : 'ANSWERED d8: B' }
 if (/^review:/.test(o.label)) return { findings: V === 'd' || (V === 'q' && rv++) ? [] : V === 'p' ? [F('a.ts', 3)] : [F('a.ts', 3), F('c.ts', 7)] }
 if (/^fix:/.test(o.label)) return _rep(lt(), { disputes: [{ finding: 'a.ts:3', evidence: 't9 covers null' }, { finding: 'c.ts:7', evidence: 'dead code' }] })
 if (/^dispute:/.test(o.label)) return { answers: [{ finding: 'a.ts:3', verdict: 'upheld', evidence: 'b.ts:4 passes null', why: 'fix it' }, { finding: 'c.ts:7', verdict: 'withdrawn', evidence: 'ok' }] }
 if (/^build:/.test(o.label)) return V === 'd' ? _rep(lt('FAIL'), { debate: [{ item: 'A2', question: 'q?', options: ['A: x', 'B: y'] }] }) : _rep(lt())
 if (/^(local|resume|ship):/.test(o.label)) return _rep(lt(), /^ship/.test(o.label) ? _merged(1) : { debate: [] })
}, '[]')
run({ brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1, A2', area: 'a', ...(V === 'q' && { debate: { item: 'A2', question: 'cache?', options: ['A: x', 'B: y'] } }) }], mandate: ['m'], ..._kl }, m.agent, _n, _n, pipeline).then((o) => {
 const c = (l) => m.calls.filter((x) => x.label === l), asks = c('decide:X1').filter((x) => /decide ask/.test(x.prompt)), d = asks[0] || { prompt: '' }, fx = c('fix:X1')
 if (V === 'q') console.log(`brief:${c('debate:X1').length === 1 && /-Why 'brief'/.test(c('debate:X1')[0].prompt) && /ITEM A2 WAITS/.test(c('build:X1')[0].prompt) && /d7/.test((c('resume:X1')[0] || {}).prompt)}`)
 if (V === 'q') console.log(`split:${/"A: devy - no fix: t9 covers null"/.test(d.prompt) && /"B: revy - fix it: b\.ts:4 passes null"/.test(d.prompt) && /revy: fix it/.test(d.prompt) && /-Recommend B/.test(d.prompt) && o.decisions.some((x) => x.decisionId === 'd8')}`)
 if (V === 'q') console.log(`settled:${c('review:X1').length === 2 && /a\.ts:3[\s\S]*Settled in a dispute, never raise again: c\.ts:7/.test(c('review:X1')[1].prompt) && c('ship:X1').length === 1}`)
 const last = (asks[asks.length - 1] || { prompt: '' }).prompt
 if (V === 'k') console.log(`sides:${/Still blocking after 2 fix rounds[\s\S]*devy: t9 covers null[\s\S]*revy: f a\.ts/.test(last) && c('dispute:X1').length === 1 && /owner decided these stay: fix them, no dispute: a\.ts:3/.test((fx[1] || {}).prompt)}`)
 if (V === 'p') console.log(`pending:${asks.length === 1 && /"A: devy - no fix/.test(d.prompt) && c('debate:X1').length === 1 && o.agents[0].decisionAsked === 'd8'}`)
 if (V === 'd') console.log(`low:${/-Why 'low confidence'/.test((c('debate:X1')[0] || {}).prompt) && c('local:X1').length === 1 && /d7/.test((c('resume:X1')[0] || {}).prompt)}`)
}).catch(_err)
'@
$jr = foreach ($v in 'q', 'k', 'p', 'd') { Invoke-Js "dw-$v" ($jsq -replace '__V__', $v) $wfd }
Expect-Each $jr 'buildy dispute/debate: # (brief: beside the build, its answer resumes devy; split: A/B ask both sides; settled: never re-raised; sides: askBlocking both sides, owner B in the last fix round; pending: a failed moderator = plain ask, a pending answer reused; low: devy''s debate survives a local round)' 'brief', 'split', 'settled', 'sides', 'pending', 'low' -Show 8
Remove-TestKit $k
Complete-Tests
