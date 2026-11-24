#Requires -Version 7
<#
debate.tests.ps1: bossy.ps1 decide ask / answer / envfix (a bare ask refused: specs.tests), debate (1 per run, -Owner, A/B options, each role's
Character, the owner's table + decide ask) and the
buildy sims of the review rebuttal (disputes) and the trigger debates (brief, dispute, rejected twice, low confidence); board join of
one id spawned twice (PARALLEL, REJOIN only with claims or -Session); bugbrief (repos from MRs, else configured; Migration range).
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
# ---- decide ask (moved from bossy.tests: room): structured, blocking; today's context, option effects, a recommendation (A5)
$cf = Join-Path (Kd) 'brief.contracts.md'; '# contracts' | Set-Content $cf
$out = pwsh @np $O decide ask -Run w1 -Agent X1 -Item A2 -Context 'edits recompute it' -Question 'Keep the old total?' -Options 'B: recompute — old invoices change','A: keep — no data change' -Recommend A -Contracts $cf | Out-String
$id = if ($out -match 'DECISION (\S+) pending') { $Matches[1] }
$pend = @(pwsh @np $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_.run -eq 'w1' })   # the debate above has its own
Expect 'decide ask: structured, blocking; note table, recommended first' ($id -and $pend.Count -eq 1 -and $pend[0].blocking -and $pend[0].options[1].description -eq 'no data change' -and
  (Get-Content $cf -Raw) -match "DECISION NEEDED $id(?s).*\| A \(recommended\) \| keep \| no data change \|\n\| B \|" -and (Test-Prose decision-request $cf))
$null = pwsh @np $O decide answer -Id $id -Answer 'A, keep it'
$w = pwsh @np $O decide wait -Id $id -MaxMinutes 1 | Out-String
Expect 'decide answer: wait returns it, contracts carry it, none pending' ($w -match 'ANSWERED' -and $w -match 'keep it' -and (Get-Content $cf -Raw) -match "$id ANSWERED" -and -not @(pwsh @np $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_.run -eq 'w1' }).Count)
$out = pwsh @np $O decide ask -Kind envfix -Run w1 -Agent X1 -Item A3 -Question 'refresh the release' -Contracts $cf | Out-String
$eid = if ($out -match 'ENV-FIX (e-\S+) pending') { $Matches[1] }
$pend = @(Px $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_.run -eq 'w1' })
$null = Px $O decide answer -Id $eid -By coordinator -Answer 'done: refreshed'
$w = Px $O decide wait -Id $eid -MaxMinutes 1 | Out-String
Expect 'decide envfix: no context needed, pending for the coordinator, contracts note, answer returned' ($eid -and $pend.Count -eq 1 -and $pend[0].kind -eq 'envfix' -and (Get-Content $cf -Raw) -match "ENV-FIX NEEDED $eid" -and $w -match 'done: refreshed')
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
$bd = TkPath $k board; $bqw = Join-Path (Kd) 'bqw'
# two kittys spawned in one minute with one id (kit-build-1710 twice, 2026-11-19): no claims -> two rows, never a shared session
$pj = @(1, 2 | ForEach-Object -Parallel { pwsh -NoProfile -NonInteractive -File $using:O board join -Type kitty -Agent kitty-kb -Run kb | Out-String } -ThrottleLimit 2)
$ps = @($pj | ForEach-Object { if ($_ -cmatch '(?m)^SESSION (\S+)') { $Matches[1] } }); $pa = @(Get-ChildItem $bd -Filter 'kitty-kb*.json' | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).agent } | Sort-Object)
$jq = pwsh @np $O board join -Agent BQ -Run rq -Claims $bqw | Out-String; $jq2 = pwsh @np $O board join -Agent BQ -Run rq -Claims $bqw | Out-String
$js = pwsh @np $O board join -Type kitty -Agent kitty-kc -Run kc | Out-String; $fc = Join-Path $bd "$(($js -csplit 'SESSION ')[-1].Split(' ')[0]).json"
$ec = Read-Json $fc; $ec.holderPid = $PID; $ec.holderStart = & { . (Lib); Get-KitPidStart $PID }; & $J $ec $fc   # both kittys share the coordinator's process
$js2 = pwsh @np $O board join -Type kitty -Agent kitty-kc -Run kc | Out-String; $js3 = pwsh @np $O board join -Type kitty -Agent kitty-kc -Run kc -Session $ec.session | Out-String
# js3's REJOIN wrote its own holder (none under Git Bash timeout: the chain breaks): a live one again
$ec = Read-Json $fc; $ec.holderPid = $PID; $ec.holderStart = & { . (Lib); Get-KitPidStart $PID }; & $J $ec $fc
$jo = pwsh @np $O board join -Agent kitty-kc -Run other | Out-String; $joc = $LASTEXITCODE   # the id live in run kc: refused
Expect "board join: an id live in another run -> REFUSED, exit 2 ($($jo.Trim()))" ($joc -eq 2 -and $jo -match 'REFUSED: agent id kitty-kc is live in run kc')
Expect "board: parallel joins of one id without claims -> 2 rows, 2 sessions ($($pa -join ',')); one after the other -> the second is PARALLEL kitty-kc-2; same claims or its -Session within 2 min -> REJOIN" ($ps.Count -eq 2 -and $ps[0] -ne $ps[1] -and $pa.Count -eq 2 -and $js2 -match 'PARALLEL: kitty-kc runs .*you are kitty-kc-2' -and $jq2 -match 'REJOIN' -and $js3 -match "REJOIN: .*reusing session $($ec.session)")
# bossy.ps1 bugbrief (a QA bug's brief; moved from bossy-generic.tests: its cap)
$bbScript = Join-Path $k 'skills/bossy/bossy.ps1'
$kl = Join-Path $k 'skills/crafty/kit.local.json'; Set-JsonFile $kl @{ repos = @(@{ name = 'w'; checkout = 'C:/w'; target = 'm' }) }
$bb = Invoke-PsTest bb @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; Update-KitTracking { param($tk) $tk.tasks.b1 = @{ task = 'b1' } }
function Get-TrackerTask { @{ name = 'E500'; description = 'spike' } }; function Get-TrackerComments { }; function Get-TaskMrBranches { @{ repo = 'w'; branch = 'm' } }
$o = Invoke-BugBrief -Task b1 3>$null | Out-String; "d:$($o -match '"id":"B-b1"' -and (Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw) -match '(?s)\*\*b1\*\* .*E500: spike.*\| w \| `C:/w` \| `m`')"
function Get-TaskMrBranches { }; Remove-Item (Join-Path (Get-KitPath briefs) b1.md); $null = Invoke-BugBrief -Task b1 3>$null 2>$null; "r:$((Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw) -match '\| w \| `C:/w` \|')"   # no MR: the configured repos
# migration column only from a configured tool: localEnv envs.<env>.db.migrations (was a top-level db.migrations nobody sets)
$mg0 = (Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw) -notmatch 'Migration range'; $cfg0 = $__cfg; $__cfg = '{"repos":[{"name":"w","checkout":"C:/w","target":"m"}],"localEnv":{"envs":{"x":{"db":{"migrations":{"tool":"t"}}}}}}' | ConvertFrom-Json
Remove-Item (Join-Path (Get-KitPath briefs) b1.md); $null = Invoke-BugBrief -Task b1 -Repos w 3>$null 2>$null; "m:$($mg0 -and (Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw) -match 'Migration range')"; $__cfg = $cfg0
$klx = Join-Path (Split-Path (Split-Path $args[0])) 'crafty/kit.local.json'; $kl0 = Get-Content $klx -Raw; '{"repos":[{"checkout":"C:/w"}]}' | Set-Content $klx
"e:$(try { $null = Invoke-BugBrief -Task b1 3>$null 2>$null; 'no throw' } catch { "$_" -match 'no repos in kit.local.json' })"; Set-Content $klx $kl0   # no repo name anywhere: an error
function Get-TrackerTask { @{ name = 'E500'; description = "## Failed checks`n### C1 — a`n**Saw:** x`n### C2 — b`n**Saw:** y`n### C3 — c`n**Saw:** z" } }
$null = Invoke-BugBrief -Task b1 -Repos w -Only C1, C2 -Skip 'C2=web; api area' 3>$null; $bt = Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw
"o:$($bt -match '(?s)## Failed checks\s+- \*\*C1\*\*[^\n]*\n\n## Not yours \(coordinator\)\s+- \*\*C2\*\* — web; api area\s+- \*\*C3\*\* — outside -Only')"
"n:$(try { Invoke-BugBrief -Task b1 -Repos w -Only C9 3>$null; 0 } catch { "$_" -match 'no check C9 ' })"
'@ @($bbScript); Remove-Item $kl
Expect-Each $bb 'bugbrief without check headings: the task is the check, -Agent B-<task>, -Repos from its MRs, else the configured repos; -Only / -Skip -> a Not yours list (a ; in a why kept), an unknown id = error; no repo name anywhere = error; Migration range only with a configured tool (#)' 'd', 'r', 'm', 'e', 'o', 'n'
# Waste panel (context.tests: its cap): every item tagged (fixable / open / fixed / ignored, reason), fixable first; a pattern in 2 runs -> one
# retro signal (then open); a win signal "fixed in <sha>" -> fixed; filter chips, ignored muted
$wz = Invoke-PsTest waste @'
$null = . $args[0] 6>$null; $z = @(0, 0, 0, 0, 0, 0)
$st = { param($r, $l, $run, $s0, $w, $rr) [pscustomobject]@{ role = $r; label = $l; run = $run; cx = [pscustomobject]@{ n = 3; s0 = $s0; w = $w; rr = $rr } } }
$ss = @((& $st devy d1 r1 31000 $z @(0, '')), (& $st devy d2 r2 26000 $z @(0, '')), (& $st checky c1 r3 9000 @(0, 478, 0, 0, 0, 0) @(2, 'D:/x/notes.md')), (& $st revy v1 r4 9000 @(0, 0, 0, 0, 1, 5000) @(0, '')))
Write-KitLog signals '' ([ordered]@{ skill = 'revy'; kind = 'friction'; text = 'w'; ref = 'waste:revy:buildlog'; source = 'supervise' })
$a = @(Get-KitWasteItems $ss); "tags:$((@($a | ForEach-Object { "$($_.role)-$($_.kind)-$($_.tag)" }) -join ',') -eq 'devy-startload-fixable,revy-buildlog-open,checky-reread-ignored' -and $a[0].what -match '^avg start \S+ vs the 20k aim$')"
"why:$(@($a | Where-Object tag -eq 'ignored')[0].why -eq '478 tokens, under 2k, one-off')"
$r1 = Add-KitWasteSignals $a; $r2 = Add-KitWasteSignals @(Get-KitWasteItems $ss); "raised:$("$r1|$r2|$(@(Get-KitWasteItems $ss)[0].tag)" -eq '1|0|open')"
$null = Invoke-Learn -Skill devy -Kind win -Text 'fixed in abc1234: devy start files slimmed' -Ref waste:devy:startload; $b = @(Get-KitWasteItems $ss)
"fixed:$(@($b | Where-Object kind -eq 'startload')[0].why -eq 'fixed in abc1234')"
$fd = { param($id, $t, $n, [string]$inner, [string]$tag, [string]$cls, [string]$extra) "<details id=$id><summary>$t $n $extra</summary>$inner</details>" }
$h = Format-KitWastePanel $b $fd; "html:$(([regex]::Matches($h, '<button type=button data-w=')).Count -eq 4 -and $h -match 'class=wsx data-w=all' -and $h -match "class='wr t-ignored' title='478 tokens, under 2k, one-off")"
'@ @($O)
Expect-Each $wz 'waste: # (tags: fixable first by tokens, open, ignored; why: the reason; raised: one signal per 2-run pattern, once, then open; fixed: its commit; html: 4 chips, all shown, ignored muted with its reason)' @('tags', 'why', 'raised', 'fixed', 'html') -Show 6
Remove-TestKit $k
Complete-Tests
