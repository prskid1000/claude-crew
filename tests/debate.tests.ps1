#Requires -Version 7
<#
debate.tests.ps1: bossy.ps1 decide ask / answer / envfix (a bare ask refused: specs.tests), debate (1 per run, -Owner, A/B options, each role's
Character, the owner's table + decide ask) and the
buildy sims of the review rebuttal (disputes), the trigger debates and the phases (code, loop, docs; a handoff before the loop), a step with no result (one <label>@redo) (brief, dispute, rejected twice, low confidence); board join of
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
  $dbA -match 'Cite it or drop it.*\n.*\n.*ROUND 0 \(blind' -and $dbR -match 'Show me the' -and $dbk -match '\| B: Cached \| lags 5 min \| -35 ms \| stale price \| 1 d \| C\.java:20 \| a wrong price at 9:00 \|' -and $dbk -match 'revy recommends A' -and $dbk -match 'DECISION dec-[a-z0-9-]+')
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
$eid = if ($out -match 'ENV-FIX (envfix-[a-z0-9-]+) pending') { $Matches[1] }
$pend = @(Px $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_.run -eq 'w1' })
$null = Px $O decide answer -Id $eid -By coordinator -Answer 'done: refreshed'
$w = Px $O decide wait -Id $eid -MaxMinutes 1 | Out-String
Expect 'decide envfix: no context needed, pending for the coordinator, contracts note, answer returned' ($eid -and $pend.Count -eq 1 -and $pend[0].kind -eq 'envfix' -and (Get-Content $cf -Raw) -match "ENV-FIX NEEDED $eid" -and $w -match 'done: refreshed')
# board reads: one batched parse (a broken / empty file skipped, an array's items, a "File" key overwritten); a bare beat's session
# lookup reads its transcript once (join lines + the persisted outputs it names)
$rjs = @'
. $args[0]; $d = Join-Path $args[1] 'rj'; $null = New-Item -ItemType Directory -Force $d; $i = 0
foreach ($t in '{"a":1}', '{}', '{"File":"x","b":2}', '[{"c":3}]', '{"a":', '') { $i++; Set-Content (Join-Path $d "$i.json") $t }
$r = @(Read-KitJsonFiles $d); "json:$((@($r | ForEach-Object { Split-Path $_.file -Leaf }) -join ',') -eq '1.json,2.json,3.json,4.json' -and $r[0].a -eq 1 -and $r[2].b -eq 2 -and $r[3].c -eq 3)"
$tx = Join-Path $args[1] 'sess1.jsonl'; $trd = Join-Path $args[1] 'sess1/tool-results'; $null = New-Item -ItemType Directory -Force $trd
'{"t":"(pass -Session a-1 to beat"}', '{"t":"x (pass -Session b-2 to beat"}', '{"t":"see tool-results/p1.txt"}' | Set-Content $tx
$mc = '(pass -Session c-3 to beat'; $md = '(pass -Session d-4 to beat'; $mc | Set-Content (Join-Path $trd 'p1.txt'); $md | Set-Content (Join-Path $trd 'p2.txt')
"sess:$(((@(Get-KitTranscriptSessions $tx) | Sort-Object) -join ',') -eq 'a-1,b-2,c-3' -and (Test-KitTranscriptMarker $tx $mc) -and -not (Test-KitTranscriptMarker $tx $md) -and (Test-KitTranscriptMarker $tx 'tool-results/p1'))"
'@
Expect-Each (Invoke-PsTest 'board-reads' $rjs @($O, (Kd))) 'board reads: # (one parse, broken / empty skipped; transcript sessions in one read)' 'json', 'sess'
# decide watch (the coordinator's Monitor): each new blocking ask and ENV-FIX once, at once; FYI and answered ones never
$wq = pwsh @np $O decide ask -Run w2 -Agent X2 -Item A4 -Context 'today: x' -Question 'Show the old price?' -Options 'A: yes — shown','B: no — hidden' -Recommend A | Out-String
$wi = if ($wq -match 'DECISION (\S+) pending') { $Matches[1] }; $we = if ((pwsh @np $O decide ask -Kind envfix -Run w2 -Agent X2 -Item A6 -Question 'restart the api' | Out-String) -match 'ENV-FIX (\S+) pending') { $Matches[1] }
$null = pwsh @np $O decide ask -Run w2 -Agent X2 -Item A5 -Context 'today: y' -Question 'Round the totals?' -Options 'A: yes — rounded','B: no — exact' -Recommend A -Fyi; $ww = @(pwsh @np $O decide watch -MaxMinutes 0)
Expect "decide watch: one ACT per pending blocking ask / ENV-FIX, FYI and answered none ($($ww -join ' | '))" ($wi -and $we -and @($ww -match "^ACT DECISION $wi ").Count -eq 1 -and @($ww -match "^ACT ENV-FIX $we ").Count -eq 1 -and -not ($ww -match ('Round the totals|' + [regex]::Escape($id) + ' |' + [regex]::Escape($eid) + ' ')))
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
# Waste (context.tests: its cap): every item tagged (fixable / open / fixed / ignored, reason), fixable first; a pattern in 2 runs -> one
# retro signal (then open); a win signal "fixed in <sha>" -> fixed; per-role columns of the role heat map
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
$wc = Get-KitWasteRoleCells @($b + $b); "cells:$("$(@($wc.devy.v) -join ',')|$(@($wc.revy.v) -join ',')" -eq '0,0,1|0,1,0' -and $wc.revy.tips[1] -match '^buildlog: 1 build / test log\(s\) pasted · 2 items · v1 · 10(.0)?k: retro signal raised' -and $wc.checky.ignored -match '^reread: .*: 478 tokens, under 2k, one-off$')"
"heat:$((Format-KitWasteLegend) -match '^waste, last 7 days, one item per role \+ kind')"
$null = Invoke-Learn -Skill checky -Kind false-positive -Text 'one-off notes read' -Ref waste:checky:reread; "closed:$(@(Get-KitWasteItems $ss | Where-Object kind -eq 'reread')[0].why -eq 'closed by /tidy: one-off notes read')"
$late = (Get-Date).AddHours(1).ToString('o'); $dv = { param($s0) @($ss) + @([pscustomobject]@{ role = 'devy'; label = 'd9'; run = 'r9'; at = $late; cx = [pscustomobject]@{ n = 3; s0 = $s0; w = $z; rr = @(0, '') } }) }
$c3 = @(Get-KitWasteItems (& $dv 30000) | Where-Object kind -eq 'startload')[0]; $c4 = @(Get-KitWasteItems (& $dv 12000) | Where-Object kind -eq 'startload')[0]
"refix:$($c3.tag -eq 'open' -and $c3.why -match '^seen again after the fix abc1234' -and $c4.tag -eq 'fixed')"
$gk = Join-Path (Get-KitPath work -Create) 'wfix'; $null = git init -q $gk; git -C $gk -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'fix(kit): slim build logs' -m 'Waste-Fix: waste:revy:buildlog'; $KitConf.Kit = $gk
"trailer:$(@(Get-KitWasteItems $ss | Where-Object kind -eq 'buildlog')[0].why -match '^fixed in [0-9a-f]{7}')"
'@ @($O)
Expect-Each $wz 'waste: # (tags: fixable first by tokens, open, ignored; why: the reason; raised: one signal per 2-run pattern, once, then open; fixed: its commit; cells: one item per role + kind, per role fixable / open / fixed counts, items + reasons per cell, ignored apart; heat: waste columns of the role · context map, the window in its legend, no own panel; closed: /tidy''s reason -> ignored; refix: runs after the fix re-measure it; trailer: a Waste-Fix: commit fixes it)' @('tags', 'why', 'raised', 'fixed', 'cells', 'heat', 'closed', 'refix', 'trailer') -Show 10
# retro tidy-20261124-01 (moved here: room): usage errors, decision ids in answers, prior wave siblings, log slack
$tSt = Px $O track status 2>&1 | Out-String; $tSh = Px $O track show 2>&1 | Out-String
Expect "track status = track show (retro tidy-6)" ($tSt -eq $tSh -and $tSt -notmatch 'Did you mean|usage')
$dShow = (Px $O decide show 2>&1 | Out-String) -replace '\s+(\|\s+)?', ' '; $dShowc = $LASTEXITCODE; $tRm = Px $O track remove -Task X1 2>&1 | Out-String; $tRmc = $LASTEXITCODE
Expect "usage: decide show names its verbs + the read verb (list); track remove without -Mrs prints its params, exit 2 ($dShowc $tRmc)" ($dShowc -eq 2 -and $dShow -match 'ask,list,answer' -and $dShow -match 'Did you mean: list\?' -and $tRmc -eq 2 -and $tRm -match 'track remove -Task <id> -Mrs')
$sup = Invoke-PsTest supersede @'
$null = . $args[0] 6>$null; $rw = { param($i, $h, $q, $a) [pscustomobject]@{ id = $i; at = "2026-01-01T$($h):00:00Z"; question = $q; answer = $a; status = 'answered'; by = 'owner' } }
@(Format-KitDecisionItems @((& $rw 'dec-0001' '10' 'Where?' 'A'), (& $rw 'dec-0002' '11' 'Cache?' 'B, supersedes dec-0001')) '' 'T1').text -join "`n"
'@ @($O)
Expect "decide: 'supersedes dec-<nnnn>' in an answer supersedes that decision ($($sup -join ' | '))" ("$sup" -match '0001 · Where\? → superseded by 0002')
$env:KIT_TRACKER_TYPE = 'none'; $crP = Join-Path $k 'skills/crafty/crafty.ps1'; $wvSpec = Join-Path (Kd) 'wave-spec.json'
$wvPar = (Px $crP tracker create -Key qa-fx-debate-1 -List L1 -Name 'Launch parent ask' -Description 'the ask' | ConvertFrom-Json).id
$wvIds = foreach ($wvT in 'Phase two api', 'Phase two api docs') { Set-JsonFile $wvSpec @{ title = $wvT; list = 'L1'; parent = $wvPar; newTask = 'planned phase'; problem = 'p'; goal = 'g'; items = @(@{ code = 'A1'; desc = 'x' }); acceptance = @('a'); links = @('https://x.example/1') }; (Px $crP tracker create -Spec $wvSpec | ConvertFrom-Json).id }
$wvPr = Px $crP prior -Task $wvIds[0] | Out-String; $wvPrc = $LASTEXITCODE; $env:KIT_TRACKER_TYPE = $null
Expect "prior gate: a wave sibling (same parent) is INFO, never a stop ($wvPrc $wvPr)" ($wvIds.Count -eq 2 -and $wvPrc -eq 0 -and $wvPr -match "INFO task\s+$($wvIds[1])" -and $wvPr -match 'NONE')
$sl = Invoke-PsTest log-slack @'
$null = . $args[0] 6>$null; $lf = Join-Path (Get-KitPath work -Create) 'slack.jsonl'; $t0 = Get-Date
Set-Content $lf @(foreach ($m in 45, 20, 5) { [ordered]@{ at = $t0.AddMinutes(-$m).ToString('o'); m = $m } | ConvertTo-Json -Compress })
$rd = { @(Get-KitLogLines $lf $t0.AddMinutes(-21) | ForEach-Object { "$(($_ | ConvertFrom-Json).m)" }) -join ',' }; $d30 = & $rd; $env:KIT_PARAM_LOG_SINCESLACKMINUTES = '0'; "$d30|$(& $rd)"
'@ @($O)
Expect "log.sinceSlackMinutes: the 30-min default reads a 45-min-old row from 21 min, 0 does not ($sl)" ("$sl".Trim() -eq '45,20,5|20,5')
# an item's ask ("outside the area", no -Gate), add pick: its scope word serves the item's branch (no 2nd ask)
$siA = pwsh @np $O decide ask -Run r -Agent devy -Item itm4321x -Question 'Fix in Svc.java, outside the area.' -Context 'today: saves fail' -Options 'A: add Svc.java to the scope — saves work', 'B: no change — saves fail' -Recommend A | Out-String
$siR = pwsh @np $O decide answer -Id $(if ($siA -match 'DECISION (\S+)') { $Matches[1] }) -Answer 'A' | Out-String
$siC, $siN = foreach ($b in 'itm4321x', 'oth99') { pwsh @np $O decide check -Gate scope -Item "fix/CU-$b-x" | Out-String }
$sdA = pwsh @np $O decide ask -Run r -Agent devy -Item itm5 -Question 'Fix in Svc.java, outside the area.' -Context 'today: saves fail' -Options 'A: drop Svc.java, add a test — saves fail', 'B: no — x' -Recommend A | Out-String
$sdR = pwsh @np $O decide answer -Id $(if ($sdA -match 'DECISION (\S+)') { $Matches[1] }) -Answer 'A' | Out-String
Expect "decide answer: an item's scope word is found for a branch naming the item, not another; a 'drop ..., add' pick records none ($siR | $siC | $sdR)" ($siR -match 'SCOPE RECORDED' -and $siC -match '^WORD ' -and $siN -notmatch '^WORD ' -and $sdR -match 'no scope word')
# dec-37: "outside the <area> paths" wording, a branch not naming the item: the record carries the asking agent's checkpoint branch
$sbRepo = Join-Path (Kd) 'scbr'; git init -q -b feat/PAY-1-methods $sbRepo; git -C $sbRepo commit -q --allow-empty -m init
$null = pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') checkpoint -Agent devy-pay -Run r -Step worktree -Dir $sbRepo
$sbA = pwsh @np $O decide ask -Run r -Agent devy-pay -Item G9-methods -Question 'Angular needs the card registered in app.module.ts, which is outside the web-payments paths. How do we wire it?' -Context 'today: the card is not shown' -Options 'A: add one import line to app.module.ts (scope-ok for that file) — the card shows', 'B: build the card inline in the page — a bigger page' -Recommend A | Out-String
$sbR = pwsh @np $O decide answer -Id $(if ($sbA -match 'DECISION (\S+)') { $Matches[1] }) -Answer 'A: one import line (scope ok)' | Out-String
$sbC = pwsh @np $O decide check -Gate scope -Item feat/PAY-1-methods | Out-String
$scA = pwsh @np $O decide ask -Run r -Agent devy-pay -Item 5jet-T4 -Question 'The old assertion in lib.spec.ts sits outside the web-orders paths: change it?' -Context 'today: one test pins the old rule' -Options 'A: change it — the test pins the new rule', 'B: leave it red — the MR ships a red test' -Recommend A | Out-String
$scR = pwsh @np $O decide answer -Id $(if ($scA -match 'DECISION (\S+)') { $Matches[1] }) -Answer 'A (scope ok)' | Out-String
# a declining pick records none: the recommended B "build it inline" and "B (no scope ok needed)"
$sxR = foreach ($sxAns in 'B', 'B (no scope ok needed)') { $sxA = pwsh @np $O decide ask -Run r -Agent devy-pay -Item G9x -Question 'The card needs app.module.ts, outside the web-payments paths: how?' -Context 'today: the card is not shown' -Options 'A: register it in app.module.ts — the card shows', 'B: build the card inline in the page — a bigger page' -Recommend B | Out-String
  pwsh @np $O decide answer -Id $(if ($sxA -match 'DECISION (\S+)') { $Matches[1] }) -Answer $sxAns | Out-String }
Expect "decide answer: a recommended decline pick and a 'no scope ok' answer record no scope word ($sxR)" (@($sxR | Where-Object { $_ -match 'no scope word' -and $_ -notmatch 'SCOPE RECORDED' }).Count -eq 2)
Expect "decide answer: a scope ask worded 'outside the <area> paths' records the agent's branch, a 'change it' pick too (dec-42); check finds the word by that branch ($sbR | $sbC | $scR)" ($sbR -match 'SCOPE RECORDED' -and $sbC -match '^WORD ' -and $scR -match 'SCOPE RECORDED')
# dec-47 (retro tidy-6): an 'allow scope exception — merge as is' pick records the word though the owner's why names the revert side
$s47 = foreach ($s47Ans in 'A: allow it: reverting would drop the approved menu entry', 'B', 'A split is cleaner, do not merge as is') { $s47A = pwsh @np $O decide ask -Run r -Agent devy-pay -Item web!77 -Question 'MR 77 changes two nav files outside the area: allow or revert?' -Context 'today: held by scope' -Options 'A: allow scope exception — merge 77 as is', 'B: revert the two nav files — merge 77 without them' -Recommend B | Out-String
  pwsh @np $O decide answer -Id $(if ($s47A -match 'DECISION (\S+)') { $Matches[1] }) -Answer $s47Ans | Out-String }
Expect "decide answer: an allow-exception pick records the scope word; its revert sibling and a free-text decline starting 'A ' none ($s47)" ($s47[0] -match 'SCOPE RECORDED' -and @($s47[1], $s47[2] | Where-Object { $_ -match 'no scope word' -and $_ -notmatch 'SCOPE RECORDED' }).Count -eq 2)
# decide.neverAuto adds an org's words to the kit's never-auto list (deploy, prod, data ... stay)
$nvq = { (Invoke-PsTest never-auto @'
$null = . $args[0] 6>$null; "$(Test-KitRuleSensitive 'scope' 'Send the invoice batch?')|$(Test-KitRuleSensitive 'scope' 'Deploy it now?')|$(Test-KitRuleSensitive 'scope' 'Sort by name?')"
'@ @($O) | Select-Object -Last 1) }
$nv0 = & $nvq; $kcf = Join-Path $k 'skills/crafty/kit.local.json'; $kco = if (Test-Path $kcf) { Get-Content $kcf -Raw | ConvertFrom-Json -AsHashtable } else { @{} }; $kco.decide = @{ neverAuto = @('invoice\w*') }; Set-JsonFile $kcf $kco; $nv1 = & $nvq
Expect "decide.neverAuto: org words join the built-in list ($nv0 -> $nv1)" ("$nv0" -eq 'False|True|False' -and "$nv1" -eq 'True|True|False')
# buildy phases (T2): code -> loop -> docs, a fresh devy each unless one goes on under 80% budget (goon, tidy-6); the ship phase keeps the loop's localTest; phases:false = one devy
$jsph = @'
const lt = (status) => ({ status, env: status === 'NONE' ? 'phase code' : 'shop r1', rounds: 1, failing: [], goalsDoc: 'g.md' })
const mk = (mode) => _mock((prompt, o) => {
 if (/^build:/.test(o.label)) return o.label === 'build:X1' && /PHASE code/.test(prompt) && mode !== 'goon' ? _rep(lt('NONE'), { mrs: [], ...(mode === 'codehandoff' ? { handoff: 'C:/b/c.md' } : {}) }) : _rep(lt('PASS'))
 if (/^loop:/.test(o.label)) return mode === 'nullloop' ? null : mode === 'loophandoff' ? _rep(lt('NONE'), { mrs: [], handoff: 'C:/b/l.md' }) : _rep(lt('PASS'), { mrs: [] })
 if (/^handoff:/.test(o.label)) return _rep(lt('NONE'))
 if (/^docs:/.test(o.label)) return _rep(lt('NONE'), mode === 'handoff' ? { handoff: 'C:/b/h.md' } : {})
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ship:/.test(o.label)) return _rep(lt('PASS'), _merged(1))
}, '[]')
const args = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], ..._kl }
const p = mk(), q = mk(), h = mk('handoff'), n = mk('nullloop'), c = mk('codehandoff'), lh = mk('loophandoff'), g = mk('goon')
run(args, p.agent, _n, _n, pipeline).then((op) => run({ ...args, phases: false }, q.agent, _n, _n, pipeline).then(() => run(args, h.agent, _n, _n, pipeline)).then(() => run(args, n.agent, _n, _n, pipeline)).then(() => run(args, c.agent, _n, _n, pipeline)).then(() => run(args, lh.agent, _n, _n, pipeline)).then(() => run(args, g.agent, _n, _n, pipeline)).then(() => {
 const L = p.calls.map((c) => c.label), d = p.calls.find((c) => c.label === 'docs:X1')
 console.log(`order:${L.indexOf('build:X1') < L.indexOf('loop:X1') && L.indexOf('loop:X1') < L.indexOf('docs:X1') && L.indexOf('docs:X1') < L.indexOf('review:X1')}`)
 console.log(`prompts:${/PHASE local/.test(p.calls.find((c) => c.label === 'loop:X1').prompt) && /PHASE ship/.test(d.prompt) && /ship\.md/.test(d.prompt) && d.model === 'sonnet'}`)
 console.log(`kept:${p.calls.some((c) => c.label === 'ship:X1') && !op.blocked.length}`)
 const hc = h.calls.find((c) => c.label === 'handoff:X1'), nd = n.calls.find((c) => c.label === 'docs:X1')
 console.log(`handoff:${!!hc && /resume brief C:\/b\/h\.md/.test(hc.prompt) && /PHASE ship/.test(hc.prompt) && !/LOOP FIRST/.test(hc.prompt)}`)
 // a loop-phase handoff with no passing loop: the resume starts with it; a code-phase one keeps PHASE code (the loop phase follows)
 const cc = c.calls.find((x) => x.label === 'handoff:X1'), lc = lh.calls.find((x) => x.label === 'handoff:X1'), hl = (x) => x.prompt.split('\n').find((l) => /LOOP FIRST|HANDOFF/.test(l)) || ''
 console.log(`loopfirst:${!!cc && !!lc && /^LOOP FIRST: .*local test loop/.test(hl(lc)) && /^HANDOFF/.test(hl(cc))}`)
 console.log(`held:${!!nd && /Draft MRs only/.test(nd.prompt) && !/Draft MRs only/.test(p.calls.find((c) => c.label === 'docs:X1').prompt)}`)
 console.log(`goon:${/go on yourself; at 80%: checkpoint, HANDOFF/.test(p.calls.find((c) => c.label === 'build:X1').prompt) && !g.calls.some((c) => /^(loop|docs|handoff):/.test(c.label))}`)
 console.log(`off:${!q.calls.some((c) => /^(loop|docs):/.test(c.label)) && !/PHASE code/.test(q.calls.find((c) => c.label === 'build:X1').prompt)}`)
})).catch(_err)
'@
Expect-Each (Invoke-Js dw-phases $jsph $wfd) 'buildy phases: # (code, loop, docs as fresh devy; phases:false = one devy)' 'order', 'prompts', 'kept', 'off', 'handoff', 'held', 'loopfirst', 'goon' -Show 8
# buildy: review, fix, ship with no result run once more as <label>@redo (fix: state check first; ship: never merge twice); learn never
$jsBr = @'
const lt = { status: 'PASS', env: 'e', rounds: 1, failing: [], goalsDoc: 'g' }, all = [], lost = new Set()
const m = _mock((p, o) => /^review:/.test(o.label) ? { findings: m.calls.filter((c) => /^review:/.test(c.label)).length === 1 ? [{ mr: '1', file: 'a.ts', severity: 'blocking', problem: 'p', fix: 'f' }] : [] } : /^ship:/.test(o.label) ? _rep(lt, _merged(1)) : /^(build|fix):/.test(o.label) ? _rep(lt) : undefined)
const drop = (p, o) => { all.push(o.label); if (o.label === 'learn' || (/^(review|fix|ship):X1$/.test(o.label) && !lost.has(o.label) && lost.add(o.label))) return null; return m.agent(p, o) }
run({ brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], ..._kl, learn: true }, drop, _n, _n, pipeline).then(() => {
 const n = (l) => all.filter((x) => x === l).length, pr = (l) => (m.calls.find((c) => c.label === l) || {}).prompt || ''
 console.log(`br-redo:${n('review:X1@redo') === 1 && n('fix:X1@redo') === 1 && /^No report came back: first find what is done/.test(pr('fix:X1@redo')) && n('ship:X1') === 1 && n('ship:X1@redo') === 1 && /first find what is done[\s\S]*never merge twice/.test(pr('ship:X1@redo'))}`)
 console.log(`br-never:${n('learn') === 1 && !all.some((l) => /learn@|@redo@|~retry/.test(l))}`)
}).catch(_err)
'@
Expect-Each (Invoke-Js bw-stepretry $jsBr $wfd) 'buildy step retry: #' 'br-redo', 'br-never' -Show 8
Remove-TestKit $k
Complete-Tests
