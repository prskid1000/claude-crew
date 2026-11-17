#Requires -Version 7
<#
qa-config.tests.ps1: pokey.ps1 config-driven QA rules: neutral finalize defaults (qa.newDefectIdRx, qa.holdCauses), qa.lanes, the human testing doc fill
(rows from the checks that cover them, refused gaps), prepare (process.docs guide doc, qa.guideDoc; none = the task text guides).
Usage: pwsh -NoProfile -File <kit>/tests/qa-config.tests.ps1 (or tests/kit-tests.ps1 -Area qa-config).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qacfg; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $store = Join-Path $k '.state/tracker-none'
$craftyPs = Join-Path $k 'skills/crafty/crafty.ps1'; $wd = Join-Path (Kd) 'w'; New-Item -ItemType Directory -Force $wd, $store | Out-Null
$env:KIT_TRACKER_TYPE = 'none'; $env:KIT_REPORT_TYPE = 'markdown'; $kl = "$k/skills/crafty/kit.local.json"
function New-Run($name, $items) {
  $d = Join-Path (Kd) "runs/$name"; New-Item -ItemType Directory -Force $d | Out-Null
  & $J @{ title = "Run $name"; target = 't'; tracker = @{ list = 'L1'; parent = 'P1' }; items = @($items | ForEach-Object { @{ code = $_.code; title = $_.code; subtasks = @(@{ id = $_.task; name = "Task $($_.task)" }) } }) } "$d/run.json"
  foreach ($it in $items) {
    New-Item -ItemType Directory -Force "$d/$($it.code)" | Out-Null
    & $J @{ code = $it.code; checks = @($it.checks | ForEach-Object { $c = @{ id = $_[0]; subtask_id = $it.task; screen = 's'; result = $_[1]; what_was_done = 'w'; observed = "o $($_[0])"; evidence = @() }; if ($_.Count -gt 2) { $c.defect = $_[2] }; $c }); findings = @(); setup_changes = @(); data_created = @() } "$d/$($it.code)/results.json"
  }
  $d
}
function Gold($a, $b) { ("$a" -replace "`r`n", "`n").TrimEnd() -eq ("$b" -replace "`r`n", "`n").TrimEnd() }
function Fin($d, $c) { Px $Q finalize -RunDir $d -Code $c @args 2>&1 | Out-String }
function Read-Text($f) { Get-Content $f -Raw }
function Task($id) { Read-Json (Join-Path $store "$id.json") }
function Rec($d, $c) { (Read-Json "$d/$c/finalize.json").subtasks[0] }
function New-Task($id, $name, $parent = $null, $status = 'open', $desc = '') { & $J @{ id = $id; name = $name; status = $status; parent = $parent; list = 'L1'; assignees = @(); description = $desc; comments = @() } (Join-Path $store "$id.json") }
$rt = New-Run 'RT' @(@{ code = 'Z1'; task = 'TZ'; checks = , @('C1', 'FAIL') }); New-Task TZ 'Task Z' $null open '### C1 — s'; $null = Fin $rt 'Z1'
# tracker.bugPrefix; a check without evidence; guideId is a Docs URL only for gdocs
'{"tracker":{"bugPrefix":"[Defect]"}}' | Set-Content $kl
foreach ($x in @('PY', 'Ask Y'), @('TY', 'T', 'PY'), @('BY', '[Defect] Ask Y — new defects (1)', 'PY')) { New-Task @x }
$by = New-Run 'BY' @(@{ code = 'Y1'; task = 'TY'; checks = , @('X1', 'FAIL', 'new') })
(Read-Text "$by/run.json") -replace '"code":', '"guideId": "G4", "code":' | Set-Content "$by/run.json"
(Read-Text "$by/Y1/results.json") -replace '"evidence":', '"x":' | Set-Content "$by/Y1/results.json"
$null = Fin $by 'Y1'; $null = pwsh @np $Q retest -RunDir $by -Task BY -Code Y2
Expect 'bugPrefix: an open [Defect] under the ask gets the section, its name kept; retest strips it; no evidence key; guideId' ((Task 'BY').name -eq '[Defect] Ask Y — new defects (1)' -and (Task 'BY').description -match '(?m)^Source: qa-BY \[kit:bug:qa-BY\]' -and (Read-Text "$by/run.json") -match 'RETEST Ask Y — new' -and (Read-Text "$by/Y1/report.md") -notmatch 'docs\.google')
# neutral defaults: no qa.newDefectIdRx = an X id is the task's own FAIL; no qa.holdCauses = env-data untested fails testing
'{}' | Set-Content $kl
$nd = New-Run 'ND' @(@{ code = 'D1'; task = 'TD1'; checks = @(@('C1', 'PASS'), @('X1', 'FAIL')) }, @{ code = 'D2'; task = 'TD2'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
New-Task 'TD1' 'Task D1'; New-Task 'TD2' 'Task D2'
$rj = Read-Json "$nd/D2/results.json"; $rj.checks[1] | Add-Member cause 'env-data'; & $J $rj "$nd/D2/results.json"
$null = Fin $nd D1; $null = Fin $nd D2
Expect 'finalize, neutral config: an X id without defect is the own FAIL (no qa.newDefectIdRx); env-data untested fails testing (no qa.holdCauses)' ((Rec $nd D1).fail -eq 1 -and (Rec $nd D1).newDefects -eq 0 -and (Rec $nd D1).failedTesting -and (Rec $nd D2).failedTesting -and -not (Rec $nd D2).keptOpen)
# K52: an inconclusive new defect naming no request = WATCH, no [Bug]; the bug title = "<product> — <first defect>" (tested task's product, not the ask)
New-Task 'PU' 'Leverage the thing to build agents'; New-Task 'TU' '[Feature] ProdU - Agents P3: history' 'PU'; New-Task 'TV' 'Task V' 'PU'
$un = New-Run 'UN' @(@{ code = 'U1'; task = 'TU'; checks = @(@('C1', 'PASS'), @('X1', 'FAIL', 'new'), @('X2', 'FAIL', 'new')) }, @{ code = 'U2'; task = 'TV'; checks = @(@('C1', 'PASS'), @('X1', 'FAIL', 'new')) })
(Read-Text "$un/run.json") -replace 'Task TU', '[Feature] ProdU - Agents P3: history' | Set-Content "$un/run.json"; $ru = Read-Json "$un/U1/results.json"; $ru.checks[1].observed = 'Intermittent 502, about 1 in 3 calls, vs stable 2xx'; $ru.checks[1] | Add-Member verify 'inconclusive | 30 GETs all 200'
$ru.checks[2].observed = 'GET /api/agents/7 500 vs 200'; $ru.checks[2] | Add-Member verify 'inconclusive | window gone'; & $J $ru "$un/U1/results.json"
$rv = Read-Json "$un/U2/results.json"; $rv.checks[1].observed = 'Delete button did nothing, could not get a result'; $rv.checks[1] | Add-Member verify 'inconclusive | no repro'; & $J $rv "$un/U2/results.json"
$null = Fin $un U1; $null = Fin $un U2; $ub = @(Get-ChildItem $store -Filter *.json | ForEach-Object { Read-Json $_.FullName } | Where-Object { $_.parent -eq 'PU' -and $_.name -like '`[Bug`]*' })
Expect "finalize: inconclusive X1 without a request -> unproven + watch, no [Bug]; X2 names GET /api -> [Bug] '<product> — <first defect>' ($(@($ub.name) -join '; '))" ((Rec $un U1).unproven -contains 'X1' -and (Rec $un U1).newDefects -eq 1 -and (Read-Json "$un/U1/finalize.json").watch[0].id -eq 'X1' -and $ub.Count -eq 1 -and $ub[0].name -eq '[Bug] ProdU — s' -and (Rec $un U2).newDefects -eq 0 -and (Rec $un U2).closed -and -not (Rec $un U2).bug)
# K68: a passing retest closes (the original's FAIL is superseded); an own FAIL beats a pending check; a check naming no subtask keeps it open
New-Task 'TR' 'Task R'; New-Task 'TP' 'Task P'; New-Task 'TO' 'Task O'; New-Task 'TO2' 'Task O2'
$rr = New-Run 'RR' @(@{ code = 'R1'; task = 'TR'; checks = , @('C1', 'FAIL') }, @{ code = 'R2'; task = 'TR'; checks = , @('C1', 'PASS') }, @{ code = 'P1'; task = 'TP'; checks = @(@('C1', 'FAIL'), @('C2', 'PENDING')) }, @{ code = 'O1'; task = 'TO'; checks = @(@('C1', 'PASS'), @('C2', 'FAIL')) })
$rj = Read-Json "$rr/run.json"; $rj.items[1] | Add-Member retest $true; $rj.items[3].subtasks += [pscustomobject]@{ id = 'TO2'; name = 'Task O2' }; & $J $rj "$rr/run.json"
$ro = Read-Json "$rr/O1/results.json"; $ro.checks[1].subtask_id = 'TZZ'; & $J $ro "$rr/O1/results.json"
foreach ($c in 'R1', 'R2', 'P1', 'O1') { $null = Fin $rr $c }
Expect "finalize: a passing retest closes ($((Rec $rr R2).keptOpen)); an own FAIL beside a pending check fails testing; an orphan FAIL keeps the item open" ((Rec $rr R2).closed -and (Rec $rr P1).failedTesting -and (Rec $rr O1).keptOpen -match '1 check\(s\) name no subtask of this item \(TZZ\)')
# lanes: qa.lanes names any lane; unset = web only; unknown names the configured list
$lo1 = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z2 -Lane app 2>&1 | Out-String; $lc1 = $LASTEXITCODE
'{"qa":{"lanes":{"web":{"kind":"web"},"desk":{"kind":"desktop"},"phone":{"kind":"app","devices":"android"}}}}' | Set-Content $kl
$lo2 = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z3 -Lane desk 2>&1 | Out-String; $lz = @((Read-Json "$rt/run.json").items | Where-Object code -eq 'Z3')[0]
$lo3 = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z4 -Lane app 2>&1 | Out-String; $lz4 = @((Read-Json "$rt/run.json").items | Where-Object code -eq 'Z4')[0]
Expect "lanes: unset -> only web (app refused, list named); a configured desktop lane accepted; a kind resolves to its lane ($lc1)" ($lc1 -ne 0 -and $lo1 -match "unknown lane 'app'.*are web" -and $lz.lane -eq 'desk' -and $lz4.lane -eq 'phone')
Remove-Item $kl -ErrorAction SilentlyContinue
# ---- prepare (item 4): pokey.ps1 prepare = L1 selection by script: run.json, lead-notes skeleton, Left out; the last line RUN <json>
$PKp = Join-Path $k 'skills/pokey/pokey.ps1'
$mkTask = { param($Name, $Desc) (pwsh -NoProfile -File $craftyPs tracker create -Key "qa-fx-$Name" -Name $Name -Description $Desc -NewTask fixture 2>$null | ConvertFrom-Json).id }
$tA = & $mkTask '[Bug] Orders sort' "**Testing doc (human):** [open](https://docs.example/h1)`n`nMR: https://git.example/g/web/-/merge_requests/5"
$tB = & $mkTask '[Bug] No doc' 'MR: https://git.example/g/web/-/merge_requests/6'
$tC = & $mkTask '[Bug] Excluded' "**Testing doc (human):** [open](https://docs.example/h3)`n`nMR: https://git.example/g/web/-/merge_requests/7"
foreach ($tx in $tA, $tB, $tC) { $null = pwsh -NoProfile -File $craftyPs tracker status $tx 'in test' 2>&1 }
$pjob = @{ runFolder = "$wd/qa-runs/<yyyy-MM-dd>-stg"; statuses = @('inTest'); exclude = @($tC); target = 'stg-a'; kitDir = $k; runSettings = @{ mandate = @('test the sort') } } | ConvertTo-Json -Compress -Depth 4
# the guide doc comes from process.docs (qa.guideDoc picks the entry); these values = the legacy two-doc rows
Set-JsonFile "$k/skills/crafty/kit.local.json" @{ process = @{ docs = @(@{ key = 'ai'; label = 'Testing doc (AI)' }, @{ key = 'human'; label = 'Testing doc (human)' }) }; qa = @{ guideDoc = 'human' } }
$pp = @(pwsh -NoProfile -File $PKp prepare -Job $pjob 2>&1); $ppCode = $LASTEXITCODE; $pRun = ("$($pp[-1])" -replace '^RUN ') | ConvertFrom-Json
$pNotes = Get-Content -Raw "$($pRun.runDir)/lead-notes.md"; $null = pwsh -NoProfile -File $PKp lead-notes add -RunDir $pRun.runDir -Code T1 -Text 'which tenant? -> madrid' 2>&1
$pDay = Get-Date -Format 'yyyy-MM-dd'
Expect "prepare: one item (MR + doc + in test), the doc-less task left out, exclude honoured; exit 0, the last line is RUN <run>; lead-notes skeleton + lead-notes add ($ppCode $($pp[-2]))" ($ppCode -eq 0 -and "$($pp[-1])".StartsWith('RUN ') -and @($pRun.items).Count -eq 1 -and $pRun.items[0].code -eq 'T1' -and $pRun.items[0].subtasks[0].mrs -eq 'web!5' -and $pRun.items[0].target -eq 'stg-a' -and
  (Get-Content -Raw $pRun.items[0].guideFile) -match 'https://docs.example/h1' -and @($pRun.left).Count -eq 1 -and $pRun.left[0].reason -match 'Testing doc' -and $pRun.mandate[0] -eq 'test the sort' -and $pRun.runDir -match "qa-runs/$pDay-stg$" -and
  (Gold $pNotes "# Lead notes: $pDay-stg`n**Result:** 1 in, 1 left out · target stg-a`n`n## Prerequisites`n`n| Item | Flags / accounts / data ids | State |`n|---|---|---|`n| T1 [Bug] Orders sort | from the guide | to check |`n`n## Left out`n`n| Task | Reason |`n|---|---|`n| $tB [Bug] No doc | no ""Testing doc (human):"" link |`n`n## Answers (newest last)") -and
  (Get-Content -Raw "$($pRun.runDir)/lead-notes.md") -match '(?m)^- \d\d:\d\d T1: which tenant\? -> madrid\r?$')
$ttl = pwsh -NoProfile -Command ". '$k/skills/crafty/lib.ps1'; (Limit-KitWords ((1..30 | ForEach-Object { ""w`$_"" }) -join ' ') 25 '+3-items'), (Limit-KitWords 'a b' 25 x)"
Expect "prepare: the run title is cut to 25 words at creation (finalize -Check limit), the last word says how many items ($($ttl[0]))" (@($ttl[0] -split ' ').Count -eq 25 -and $ttl[0] -match 'w24 \+3-items$' -and $ttl[1] -eq 'a b' -and (Get-Content $PKp -Raw) -match 'title = \(Limit-KitWords ')
$ppAgain = @(pwsh -NoProfile -File $PKp prepare -Job $pjob 2>&1); $ppAgainCode = $LASTEXITCODE
$null = New-Item -ItemType Directory -Force "$wd/qa-runs/$pDay-empty/guides"; $pjobEmpty = $pjob -replace '<yyyy-MM-dd>-stg', '<yyyy-MM-dd>-empty'
$ppEmpty = @(pwsh -NoProfile -File $PKp prepare -Job $pjobEmpty 2>&1); $ppEmptyCode = $LASTEXITCODE
Expect "prepare: a run folder with files is refused (exit 1, no -2 suffix); an empty one is reused and RUN printed ($ppAgainCode $ppEmptyCode $($ppEmpty[-2]))" ($ppAgainCode -eq 1 -and "$ppAgain" -match 'exists with files' -and -not (Test-Path "$wd/qa-runs/$pDay-stg-2") -and $ppEmptyCode -eq 0 -and "$($ppEmpty[-1])" -match "^RUN .*qa-runs/$pDay-empty""")
Set-JsonFile $kl @{ process = @{ docs = @() } }   # [] = no docs (unset: the built-in pair, vocab.json)
$ppNd = @(pwsh -NoProfile -File $PKp prepare -Job ($pjob -replace '<yyyy-MM-dd>-stg', '<yyyy-MM-dd>-nodoc') 2>&1); $ndRun = ("$($ppNd[-1])" -replace '^RUN ') | ConvertFrom-Json
Expect "prepare, process.docs []: no doc needed, the task text is the guide, lane = the first qa.lanes lane (web) ($($ppNd[-2]))" (@($ndRun.items).Count -eq 2 -and -not @($ndRun.left).Count -and (Get-Content -Raw $ndRun.items[1].guideFile) -match 'No testing doc configured' -and $ndRun.items[0].lane -eq 'web')
# K68r: a retest supersedes only the FAILs its only list names: the original's other FAIL still fails testing
New-Task 'TQ' 'Task Q'; $rq = New-Run 'RQ' @(@{ code = 'Q1'; task = 'TQ'; checks = @(@('C1', 'FAIL'), @('C2', 'FAIL')) }, @{ code = 'Q2'; task = 'TQ'; checks = , @('C1', 'PASS') })
$rqj = Read-Json "$rq/run.json"; $rqj.items[1] | Add-Member retest $true; $rqj.items[1] | Add-Member only @('C1'); & $J $rqj "$rq/run.json"
foreach ($c in 'Q1', 'Q2') { $null = Fin $rq $c }
Expect "finalize: a retest of C1 alone leaves the original's C2 FAIL holding (failed testing, not closed)" ((Rec $rq Q2).failedTesting -and -not (Rec $rq Q2).closed)
# K68: a qa.targets rule's repos match the MR repos (the inner $_ hid the rule)
Set-JsonFile $kl @{ process = @{ docs = @() }; qa = @{ targets = @{ 'stg-a' = @(@{ repos = @('api'); target = 'x-api' }, @{ repos = @('web'); target = 'x-web' }) } } }
$ppTg = @(pwsh -NoProfile -File $PKp prepare -Job ($pjob -replace '<yyyy-MM-dd>-stg', '<yyyy-MM-dd>-tgt') 2>&1); $tgRun = ("$($ppTg[-1])" -replace '^RUN ') | ConvertFrom-Json
Expect "prepare: qa.targets rules match by repos (web MRs -> x-web) ($($ppTg[-2]))" (@($tgRun.items).Count -eq 2 -and @($tgRun.items | Where-Object target -eq 'x-web').Count -eq 2)
# browser.mjs defaultUser: no 'admin' default (as pokey.ps1 api)
if (Use-BrowserKit) {
  $du = "import { defaultUser } from '$((Join-Path $k 'skills/pokey/browser.mjs').Replace('\', '/') -replace '^', 'file:///')'`nconst two = { users: { a: 1, b: 2 } }`nlet e = ''; try { defaultUser(two, 'tt') } catch (x) { e = x.message }`nconsole.log([defaultUser({ users: { solo: 1 } }), defaultUser({ ...two, defaultUser: 'b' }), defaultUser({}), /several users/.test(e)].join('|'))"
  Set-Content "$(Kd)/du.mjs" $du; $duo = node "$(Kd)/du.mjs" 2>&1 | Out-String
  Expect "browser defaultUser: one user = it; target defaultUser; none = ''; several, none chosen -> refused ($duo)" ($duo.Trim() -eq 'solo|b||true')
}
# a task with a human testing doc (Result / Evidence empty): finalize on the env fills them (same doc) + a dated "<env> run" section
$ad = "$(Kd)/TAI-h.md"; New-Item -ItemType Directory -Force (Split-Path $ad), "$k/.state/published" | Out-Null; Set-Content $ad 'v1'
& $J @{ key = 'TAI:testing-doc'; url = $ad; rounds = @(@{ at = '2026-10-29 10:00'; label = ''; ext = '.md'; body = "# Testing: X`n| # | Steps | Expected | Result | Evidence |`n|---|---|---|---|---|`n| C1 | open a | a shown | | |`n| C2 | open b | b shown | | |" }) } "$k/.state/published/TAI_testing-doc.json"
$ai = New-Run 'AI' @(@{ code = 'Q1'; task = 'TAI'; checks = @(@('C1', 'PASS'), @('C2', 'FAIL')) }); New-Item -ItemType Directory -Force "$ai/Q1/shots" | Out-Null
[IO.File]::WriteAllBytes("$ai/Q1/shots/Q1-C1_01_a.png", [byte[]](1, 2)); $rj = Read-Json "$ai/Q1/results.json"; $rj.checks[0].evidence = @('Q1-C1_01_a.png'); & $J $rj "$ai/Q1/results.json"
$null = Fin $ai Q1; $at = Read-Text $ad; $ti = Read-Json (Join-Path (TkPath $k tasks) 'TAI.json')
Expect 'finalize: run index (items.Q1) and task index (envRuns, docs.testing-doc) written' ((Read-Json "$ai/index.json").items.Q1.tasks -contains 'TAI' -and
  $ti.envRuns[0].code -eq 'Q1' -and $ti.envRuns[0].fail -eq 1 -and $ti.docs.'testing-doc'.url -eq $ad)
Expect 'finalize: the human doc (same file) gets the env Result / Evidence per row and a dated "<env> run" section; no report doc' ((Read-Json "$ai/Q1/finalize.json").doc -eq $ad -and
  $at -match '\| C1 \| open a \| a shown \| PASS \| !\[C1: A\]' -and $at -match '\| C2 \| open b \| b shown \| FAIL \|' -and $at -match '## t run 20' -and -not (Test-Path "$k/.state/published/TAI_qa-report.json"))
# variant checks (V1: screen "C1 ...", V2: case C2) fill the doc rows; an api file previews "<METHOD> <path> -> <status>" + the field the notes name; the run's own folder
$vd = "$(Kd)/TVA-h.md"; Set-Content $vd 'v1'
& $J @{ key = 'TVA:testing-doc'; url = $vd; rounds = @(@{ at = '2026-10-29 10:00'; label = ''; ext = '.md'; body = "# Testing: X`n| # | Steps | Expected | Result | Evidence |`n|---|---|---|---|---|`n| C1 | open a | a shown | | |`n| C2 | open b | b shown | | |" }) } "$k/.state/published/TVA_testing-doc.json"
$vr = New-Run 'VA' @(@{ code = 'Q2'; task = 'TVA'; checks = @(@('V1', 'PASS'), @('V2', 'NOT_TESTED')) }); New-Item -ItemType Directory -Force "$vr/Q2/evidence" | Out-Null
& $J @{ meta = @{ code = 'Q2' }; request = @{ method = 'GET'; url = 'https://h/api/orders/7?x=1' }; response = @{ status = 200; headers = @{ h = 'PO-77' }; body = @{ id = 7; po = 'PO-77' } } } "$vr/Q2/evidence/Q2-V1_01_order.json"
$rj = Read-Json "$vr/Q2/results.json"; $rj.checks[0].screen = 'C1 open a'; $rj.checks[0].observed = 'order po PO-77 vs PO-77'; $rj.checks[0].evidence = @('Q2-V1_01_order.json')
$rj.checks[1] | Add-Member case 'C2'; $rj.checks[1] | Add-Member cause 'env-data'; & $J $rj "$vr/Q2/results.json"
$dtDir = Join-Path $k 'skills/crafty'; Move-Item "$dtDir/devtools.py" "$dtDir/devtools_real.py"
Set-Content "$dtDir/devtools.py" -Encoding utf8 ("import sys, os, runpy, json`nhere = os.path.dirname(os.path.abspath(__file__)); a = sys.argv`nif a[1] == 'evidence':`n" + @'
    open(os.path.join(here, 'ev-key.txt'), 'w').write(a[a.index('--key') + 1])
    ff = [os.path.basename(x) for x in open(a[a.index('--files-from') + 1], encoding='utf-8-sig').read().splitlines() if x.strip()]
    print(json.dumps({'folderId': 'F', 'folderLink': 'https://f/F', 'files': {n: {'id': n, 'link': 'https://f/' + n, 'src': 'https://img/' + n} for n in ff}}))
'@ + "`nelse:`n    a[0] = os.path.join(here, 'devtools_real.py'); runpy.run_path(a[0], run_name='__main__')")
try { $null = Fin $vr Q2 -NoTracker } finally { Remove-Item "$dtDir/devtools.py"; Move-Item "$dtDir/devtools_real.py" "$dtDir/devtools.py" }
$vt = Read-Text $vd
Expect 'finalize: variant checks fill their doc rows (ids named, api excerpt + link per file); evidence uploads under the run item key, never <task>:evidence' (
  $vt -match '\| C1 \| open a \| a shown \| PASS \(V1\) \| \*\*V1\*\* PASS: `GET /api/orders/7\?x=1 -> 200 · body\.po: PO-77` \[Order\]\(https://f/Q2-V1_01_order\.json\) \|' -and
  $vt -match '\| C2 \| open b \| b shown \| NOT TESTED \(V2\) \|' -and (Read-Text "$dtDir/ev-key.txt") -eq 'VA-Q2:evidence')
# a human doc row no check of this run or an earlier published one covers: -Check exits 1 naming it, publishing refuses
$gd = "$(Kd)/TGA-h.md"; Set-Content $gd 'g1'
& $J @{ key = 'TGA:testing-doc'; url = $gd; rounds = @(@{ at = '2026-10-29 10:00'; label = ''; ext = '.md'; body = "# Testing: X`n| # | Steps | Expected | Result | Evidence |`n|---|---|---|---|---|`n| C1 | open a | a shown | | |`n| C2 | open b | b shown | | |" }) } "$k/.state/published/TGA_testing-doc.json"
$gr = New-Run 'GA' @(@{ code = 'G1'; task = 'TGA'; checks = , @('C1', 'PASS') })
$go = Fin $gr G1 -Check; $grc = $LASTEXITCODE; $gp = Fin $gr G1 -NoTracker
Expect "finalize -Check: a human doc row no check covers -> EXIT=1 naming it; publish refuses, nothing published (rc $grc)" ($grc -eq 1 -and $go -match 'G1 doc check: C2: human testing doc row' -and $gp -match 'G1 doc check: C2' -and -not (Test-Path "$gr/G1/finalize.json"))
# a later run of one row (a local app part): the earlier published run Q1 covers C2, so no NOT_TESTED filler; a NOT_TESTED never replaces C1's PASS
$cr = New-Run 'CA' @(@{ code = 'G2'; task = 'TAI'; checks = , @('C1', 'NOT_TESTED') })
$rj = Read-Json "$cr/G2/results.json"; $rj.checks[0] | Add-Member cause 'env-data'; $rj.checks[0].observed = 'PO field read-only on the phone vs typed PO'; & $J $rj "$cr/G2/results.json"
$co = Fin $cr G2 -Check; $null = Fin $cr G2 -NoTracker; $ct = Read-Text $ad
Expect "finalize -Check: a run covering one row passes the doc check when an earlier run covers the rest; the doc keeps C1 PASS and C2 FAIL, the why named" (
  $co -notmatch 'doc check' -and $ct -match '\| C1 \| open a \| a shown \| PASS \(t C1\) · t: not tested \(C1\) — PO field read-only on the phone \|' -and $ct -match '\| C2 \| open b \| b shown \| FAIL \|')
# OUT_OF_SCOPE only for a qa.outOfScope channel named in the check (run.json outOfScope wins); an unbuilt app part is not one
$os = New-Run 'OS' @(@{ code = 'O1'; task = 'TOS'; checks = @(@('C1', 'OUT_OF_SCOPE'), @('C2', 'OUT_OF_SCOPE')) })
$rn = Read-Json "$os/run.json"; $rn | Add-Member outOfScope @('slack'); & $J $rn "$os/run.json"
$rj = Read-Json "$os/O1/results.json"; $rj.checks[0].observed = 'phone-only: app MR not deployed to a lane'; $rj.checks[1].observed = 'Slack message: channel out of scope'; & $J $rj "$os/O1/results.json"
$oo = Fin $os O1 -Check; $orc = $LASTEXITCODE
Expect "finalize -Check: OUT_OF_SCOPE without a qa.outOfScope channel (phone-only) -> EXIT=1 naming it and the local-env path; a named channel passes (rc $orc)" (
  $orc -eq 1 -and $oo -match 'O1 scope check: OUT_OF_SCOPE is only for a qa.outOfScope channel \(slack\), named in the check: C1\. ' -and $oo -match 'build -Local')
$lpScript = @'
. $args[0]; $row = { param($m, $s) [pscustomobject]@{ mr = $m; state = $s } }
$pa = Split-QaLiveParts @((& $row 'api!1' 'DEPLOYED'), (& $row 'app!2' 'NO-TARGET')); $pb = Split-QaLiveParts @(& $row 'app!2' 'NO-TARGET')
$pc = Split-QaLiveParts @((& $row 'api!1' 'NOT-DEPLOYED'), (& $row 'app!2' 'NO-TARGET')); $pd = Split-QaLiveParts @((& $row 'doc!3' 'N/A'), (& $row 'app!2' 'NO-TARGET'))
"$($pa.local)|$($pa.notLive.Count)|$($pb.notLive.Count)|$($pc.notLive.Count)|$($pc.local.Count)|$($pd.notLive.Count)"
'@
$lpo = "$(Invoke-PsTest 'live-parts' $lpScript @($Q))"
Expect "prepare: an app MR with no build on the target next to a deployed one -> localParts (local env), not left out; alone, next to a not-deployed or only an N/A MR -> left out ($lpo)" ($lpo.Trim() -eq 'app!2|0|1|2|0|1')
Remove-Item Env:KIT_TRACKER_TYPE, Env:KIT_REPORT_TYPE -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
