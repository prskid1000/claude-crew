#Requires -Version 7
<#
pokey.tests.ps1: pokey.ps1 finalize (result rule), seats, api, retest; browser.mjs.
Usage: pwsh -NoProfile -File <kit>/tests/pokey.tests.ps1 (or tests/kit-tests.ps1 -Area pokey).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $store = Join-Path $k '.state/tracker-none'
$env:KIT_TRACKER_TYPE = 'none'; $env:KIT_REPORT_TYPE = 'markdown'
function New-Run($name, $items) {
  $d = Join-Path (Kd) "runs/$name"; New-Item -ItemType Directory -Force $d | Out-Null
  & $J @{ title = "Run $name"; target = 't'; tracker = @{ list = 'L1'; parent = 'P1' }; items = @($items | ForEach-Object { @{ code = $_.code; title = $_.code; subtasks = @(@{ id = $_.task; name = "Task $($_.task)" }) } }) } "$d/run.json"
  foreach ($it in $items) {
    New-Item -ItemType Directory -Force "$d/$($it.code)" | Out-Null
    & $J @{ code = $it.code; checks = @($it.checks | ForEach-Object { $c = @{ id = $_[0]; subtask_id = $it.task; screen = 's'; result = $_[1]; what_was_done = 'w'; observed = "o $($_[0])"; evidence = @() }; if ($_.Count -gt 2) { $c.defect = $_[2] }; $c }); findings = @(); setup_changes = @(); data_created = @() } "$d/$($it.code)/results.json"
  }
  $d
}
function Fin($d, $c) { Px $Q finalize -RunDir $d -Code $c @args 2>&1 | Out-String }   # $LASTEXITCODE = its exit
function Rec($d, $c) { (Read-Json "$d/$c/finalize.json").subtasks[0] }
function Task($id) { Read-Json (Join-Path $store "$id.json") }
function Bugs { @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.name -like '`[Bug`]*' }) }
# a task in the tracker-none store
function New-Task($id, $name, $parent = $null, $status = 'open', $desc = '') { & $J @{ id = $id; name = $name; status = $status; parent = $parent; list = 'L1'; assignees = @(); description = $desc; comments = @() } (Join-Path $store "$id.json") }
New-Item -ItemType Directory -Force $store | Out-Null
foreach ($x in @(@('PA', 'Ask A'), @('PQ', '[Feature] Ask Q — q1'), @('TA', 'Task A', 'PA'), @('TQ', 'Task Q', 'PQ'), @('TA2', 'Task A2', 'PA'))) { New-Task @x }
$a = New-Run 'A' @(@{ code = 'A1'; task = 'T1'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
$out = Fin $a 'A1'
Expect 'NOT_TESTED -> failedTesting' ((Rec $a 'A1').failedTesting -and -not (Rec $a 'A1').closed -and (Task 'T1').status -eq 'failed testing')
Expect 'the one-line comment names the untested check' (@((Task 'T1').comments | Where-Object { $_.text -match '1 not tested \(C2\)' -and $_.text -notmatch '##' }).Count -eq 1)
Expect 'no task created for untested checks' (-not @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count)
$lo = New-Run 'LO' @(@{ code = 'L1'; task = 'TL'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
$rj = Read-Json "$lo/run.json"; $rj | Add-Member localEnv 'shop'; & $J $rj "$lo/run.json"
$null = Fin $lo 'L1'; $rl = Rec $lo 'L1'
Expect 'local env: NOT_TESTED keeps the task open, not failedTesting' (-not $rl.failedTesting -and -not $rl.closed -and $rl.keptOpen -match 'ENV-FIX' -and (Task 'TL').status -ne 'failed testing')
$b = New-Run 'B' @(@{ code = 'B1'; task = 'T2'; checks = @(@('C1', 'PASS'), @('C2', 'FAIL')) })
$null = Fin $b 'B1'
Expect 'own FAIL -> failedTesting, no [Bug]' ((Rec $b 'B1').failedTesting -and (Rec $b 'B1').fail -eq 1 -and -not (Bugs).Count)
Expect 'the one-line comment names the failed check' (@((Task 'T2').comments | Where-Object { $_.text -match 'checks failed \(C2\)' -and $_.text -notmatch '\*\*Saw' }).Count -eq 1)
$c = New-Run 'C' @(@{ code = 'C1'; task = 'T4'; checks = @(@('C1', 'PASS'), @('C2', 'OUT_OF_SCOPE')) })
$null = Fin $c 'C1'
Expect 'all pass (+ OUT_OF_SCOPE) -> closed' ((Rec $c 'C1').closed -and (Rec $c 'C1').outOfScope -eq 1 -and (Get-Content "$c/C1/report.md" -Raw) -match 'OUT OF SCOPE 1')
$rb = Get-Content "$b/B1/report.md" -Raw; $rc1 = Get-Content "$c/C1/report.md" -Raw
Expect 'report: a FAIL row links its detail, steps / saw once; a note''s observed only in the table' ($rb -match '\| \[details\]\(#c2--s\) \|' -and ([regex]::Matches($rb, 'o C2')).Count -eq 1 -and
  $rc1 -notmatch '## Notes' -and ([regex]::Matches($rc1, 'o C2')).Count -eq 1)
Copy-Item (Join-Path $src 'skills/crafty/templates.md') (Join-Path $k 'skills/crafty/')   # the prose limits
$pl = New-Run 'PL' @(@{ code = 'P1'; task = 'TP'; checks = @(1..3 | ForEach-Object { , @("C$_", 'PASS_WITH_NOTE') }) })
$rj = Read-Json "$pl/P1/results.json"; $rj.checks[0].observed = (1..60 | ForEach-Object { "word$_" }) -join ' '; $rj.checks[1].observed = '(b) x'; $rj.checks[2] | Add-Member verify 'no'; & $J $rj "$pl/P1/results.json"
$po = Fin $pl P1 -Check
Expect "finalize -Check: a 60-word observed fails prose; a note needs its (a)-(d) class" ($LASTEXITCODE -eq 1 -and $po -match 'P1 prose check' -and $po -match 'word' -and $po -match '(?m)P1 note check: .*: C1\r?$')
$pp = Fin $pl P1; $ppc = $LASTEXITCODE
Expect "finalize publish: over prose limits exits 1 like -Check, nothing published ($ppc)" ($ppc -eq 1 -and $pp -match 'P1 prose check' -and $pp -match 'nothing was published' -and -not (Test-Path "$pl/P1/report.md") -and -not (Test-Path "$pl/P1/finalize.json"))
$tm = New-Run 'TM' @(@{ code = 'M1'; task = 'TM1'; checks = , @('C1', 'PASS') }); $rj = Read-Json "$tm/run.json"; $rj.items[0].subtasks[0].name = (1..15 | % { "name$_" }) -join ' '; $rj.items[0].subtasks[0] | Add-Member mrs ((1..13 | % { "repo!$_" }) -join ', '); & $J $rj "$tm/run.json"
$tmo = Fin $tm M1 -Check; $tmc = $LASTEXITCODE; $null = Fin $tm M1; $tmr = "$(Get-Content "$tm/M1/report.md" -Raw -ErrorAction Ignore)"
Expect "report Tasks row: a 15-word name with 13 MRs -> [id](link) · 13 MRs, prose passes ($tmc)" ($tmc -eq 0 -and $tmr -match '\| Tasks \| \[TM1\]\([^)]*\) · 13 MRs \|' -and $tmr -notmatch 'repo!')
$s12 = "$(1..12) ."; $note = "$s12 $s12 $s12"; $bg = New-Run 'BG' @(@{ code = 'G1'; task = 'TG'; checks = @(1..44 | % { , @("C$_", 'PASS') }) }); $sm = New-Run 'SM' @(@{ code = 'S1'; task = 'TS'; checks = , @('C1', 'PASS') })
$rj = Read-Json "$bg/G1/results.json"; foreach ($x in $rj.checks) { $x.observed = $x.what_was_done = $note }; foreach ($i in 0, 1) { $rj.checks[$i].result = 'FAIL'; $rj.checks[$i] | Add-Member verify "confirmed | $(1..(300 - 270 * $i))" }; $rj.checks[0].evidence = @(10..39 | % { $e = "G1-C1_$($_)_e.json"; $null = New-Item "$bg/G1/shots/$e" -Force -Value 1; $e }); & $J $rj "$bg/G1/results.json"; $rj = Read-Json "$sm/S1/results.json"; $rj.findings = @(1..14 | % { "$note $note" }); & $J $rj "$sm/S1/results.json"
$go = Fin $bg G1 -Check; $gc = $LASTEXITCODE; $so = Fin $sm S1 -Check
Expect "finalize -Check: 44 checks, 36-word notes, 300- and 30-word verify, 30 links pass prose:900w ($gc); a small one padded over 900 words fails" ($gc -eq 0 -and $LASTEXITCODE -eq 1 -and $so -match '\(prose\): \d+ words \(max 900\)')
$null = Fin $bg 'G1'; $vm = Get-Content "$bg/G1/report.md" -Raw
Expect 'finalize: verify status in the cell, a long text in a linked file' ((Get-Content "$bg/G1/evidence/G1-C1_verify_retest.txt" -Raw) -match ' 300' -and $vm -match 'FAIL\*\* \(re-test: confirmed · 1 2 3 [^|]*…\)' -and $vm -match 'text: \[G1-C1_verify' -and $vm -notmatch ' 300')
# -FixNames: a reference in another case is rewritten; a results.json written again with the old name still resolves (rename log)
$rn = New-Run 'RN' @(@{ code = 'R1'; task = 'TR'; checks = , @('C1', 'PASS') }); New-Item -ItemType Directory -Force "$rn/R1/shots" | Out-Null
[IO.File]::WriteAllBytes("$rn/R1/shots/shotone.png", [byte[]](1, 2, 3)); $rj = Read-Json "$rn/R1/results.json"; $rj.checks[0].evidence = @('ShotOne.PNG'); & $J $rj "$rn/R1/results.json"
$null = Fin $rn R1 -Check -FixNames; $f1 = Get-Content "$rn/R1/results.json" -Raw; $new = @(Get-ChildItem "$rn/R1/shots").Name; $p0 = Test-Path "$rn/R1/finalize.json"
& $J $rj "$rn/R1/results.json"; $null = Fin $rn R1 -Check; $f2c = $LASTEXITCODE
$null = Fin $rn R1 -FixNames; $f3 = Get-Content "$rn/R1/results.json" -Raw; $p1 = Test-Path "$rn/R1/finalize.json"
[IO.File]::WriteAllBytes("$rn/R1/shots/two.png", [byte[]](1, 2)); $rj = Read-Json "$rn/R1/results.json"; $rj.checks[0].evidence += 'two.png'; $o0 = $rj.checks[0].observed; $rj.checks[0].observed = "$(1..60)"; & $J $rj "$rn/R1/results.json"
$o1 = Fin $rn R1 -Check | Out-String; $rj = Read-Json "$rn/R1/results.json"; $rj.checks[0].observed = $o0; & $J $rj "$rn/R1/results.json"; $null = Fin $rn R1 -Check -FixNames; $o2c = $LASTEXITCODE
Expect "finalize -Check: prose and off-standard names in one pass, ONE -FixNames run passes ($o2c)" ($o1 -match 'R1 prose check' -and $o1 -match 'two\.png -> R1-C1_' -and $o1 -match 'next: .*ONE run: .*-Check -FixNames' -and $o2c -eq 0)
Expect "finalize -FixNames: any-case refs renamed; an old name after a rewrite resolves; alone it publishes ($new)" (-not $p0 -and $p1 -and $new -match '^R1-C1_' -and $f1 -match [regex]::Escape($new) -and $f1 -notmatch '(?i)"shotone\.png"' -and $f2c -eq 0 -and $f3 -match [regex]::Escape($new))
$m = New-Run 'M' @(@{ code = 'M1'; task = 'TA'; checks = @(@('C1', 'PASS'), @('X1', 'FAIL')) }, @{ code = 'M2'; task = 'TA2'; checks = , @('C1', 'FAIL', 'new') }, @{ code = 'M3'; task = 'TQ'; checks = , @('X1', 'FAIL') })
$null = Fin $m 'M1'; $null = Fin $m 'M2'; $null = Fin $m 'M3'
$bA = @(Bugs | Where-Object { $_.parent -eq 'PA' }); $bQ = @(Bugs | Where-Object { $_.parent -eq 'PQ' })
$i = $bA[0].id; $tb = Task $i; $tb.name = '[Bug] mine'; & $J $tb "$store/$i.json"; $null = Fin $m 'M2'
Expect 'one [Bug] per ask: <ask, no [Feature]> — <defect> (+N more); a hand rename kept' ($bA.Count -eq 1 -and $bQ.Count -eq 1 -and $bA[0].name -eq '[Bug] Ask A — s (+1 more)' -and $bQ[0].name -eq '[Bug] Ask Q — s' -and (Task $i).name -eq '[Bug] mine')
$bd = (Task $i).description; Expect '[Bug] text: bold label bullet, code, task link' ($bd -match '(?m)^- \*\*Results report:\*\* ' -and $bd -match 'testing \[[^\]]+\]\([^)]+\), package `M1`')
Expect 'a task with only a new defect closes' ((Rec $m 'M1').closed -and (Rec $m 'M2').closed)
$n = New-Run 'N' @(@{ code = 'N1'; task = 'TA2'; checks = , @('X1', 'FAIL') })
$null = Fin $n 'N1'
Expect 'a later run files its own [Bug], the earlier one untouched' (@(Bugs | Where-Object { $_.parent -eq 'PA' }).Count -eq 2 -and (Task $i).name -eq '[Bug] mine' -and (Task $bA[0].id).description -eq $bd)
$null = Fin $c 'C1'
Expect 'a re-run posts no second results comment' (@((Task 'T4').comments | Where-Object { $_.text -match 'Test results' }).Count -eq 1)
$h = New-Run 'H' @(@{ code = 'H1'; task = 'T10'; checks = , @('C1', 'PASS') }, @{ code = 'H2'; task = 'T10'; checks = , @('C2', 'FAIL') })
$null = Fin $h 'H1'; $w = Rec $h 'H1'; $null = Fin $h 'H2'
Expect 'shared task waits for its sibling, then failedTesting' ($w.waitingFor -contains 'H2' -and (Rec $h 'H2').failedTesting)
$cap = Invoke-PsTest 'caption-test' ". `$args[0]; Caption 'TA1R-T1_01_new-instructions.png'; Caption 'TA1R-T1_verify_02_after-save.png'" @($Q)
Expect "Caption renders standard evidence names ($($cap -join ' | '))" (($cap -join '|') -ceq 'New instructions|After save (independent re-test)')
# run with & after -Check's exit 0: a crashing publish must still exit 1
$rc = Invoke-PsTest 'fin-crash' "pwsh -NoProfile -Command 'exit 0'; & `$args[0] finalize -RunDir `$args[1] -Code NOPE 2>`$null; `"rc=`$LASTEXITCODE`"" @($Q, $h)
Expect "a crashing finalize publish exits 1 ($rc)" ("$rc" -match 'rc=1')
# finalize, fake uploader: devtools.py evidence runs $Evidence (python, 4-space body; a = argv, here = its folder), the rest real
$dt = Join-Path $k 'skills/crafty'
function Use-FakeUploader([string]$Evidence, [scriptblock]$Run, [string]$Verbs = "'evidence'") {
  Move-Item "$dt/devtools.py" "$dt/devtools_real.py"
  Set-Content "$dt/devtools.py" -Encoding utf8 "import sys, os, runpy, ctypes, json`nhere = os.path.dirname(os.path.abspath(__file__)); a = sys.argv`nif a[1] in ($Verbs,):`n$Evidence`nelse:`n    a[0] = os.path.join(here, 'devtools_real.py'); runpy.run_path(a[0], run_name='__main__')"
  try { & $Run } finally { Remove-Item "$dt/devtools.py"; Move-Item "$dt/devtools_real.py" "$dt/devtools.py" }
}
# 300 long evidence paths: the uploader records the command-line length and the files it got
$lr = New-Run 'L' @(@{ code = 'L1'; task = 'T20'; checks = , @('C1', 'PASS') }); New-Item -ItemType Directory -Force "$lr/L1/shots" | Out-Null
foreach ($i in 1..300) { [IO.File]::WriteAllBytes("$lr/L1/shots/L1-C1_01_$('long-evidence-name-' * 7)$i.png", [byte[]](1, 2, 3)) }
$lrc = Use-FakeUploader @'
    ff = a[a.index('--files-from') + 1] if '--files-from' in a else None
    n = len([x for x in open(ff, encoding='utf-8-sig').read().splitlines() if x.strip()]) if ff else 0
    gl = ctypes.windll.kernel32.GetCommandLineW if os.name == 'nt' else None
    if gl: gl.restype = ctypes.c_wchar_p
    open(os.path.join(here, 'ev-rec.txt'), 'a').write(f'{len(gl() if gl else " ".join(a))} {n + len([x for x in a[2:] if x.endswith(".png")])}\n')
    print('{}')
'@ { $null = Fin $lr L1 -NoTracker; $LASTEXITCODE }
$rec = @(Get-Content "$dt/ev-rec.txt" -ErrorAction SilentlyContinue)
Expect "300 long evidence paths: one upload, command line < 8191, all 300 files (rc $lrc; $rec)" ($lrc -eq 0 -and $rec.Count -eq 1 -and [int]($rec[0] -split ' ')[0] -lt 8191 -and ($rec[0] -split ' ')[1] -eq '300')
# an uploader that hosts a folder but drops a cited file: nothing is published
$ur = New-Run 'U' @(@{ code = 'U1'; task = 'TU'; checks = , @('C1', 'PASS') }); New-Item -ItemType Directory -Force "$ur/U1/shots" | Out-Null
[IO.File]::WriteAllBytes("$ur/U1/shots/U1-C1_01_screen.png", [byte[]](1, 2, 3))
$rj = Read-Json "$ur/U1/results.json"; $rj.checks[0].evidence = @('U1-C1_01_screen.png'); & $J $rj "$ur/U1/results.json"
$uo = Use-FakeUploader "    print('{`"folderId`": `"F`", `"folderLink`": `"x`", `"files`": {}}')" { Fin $ur U1 -NoTracker; "rc=$LASTEXITCODE" }
$urc = if ("$uo" -match 'rc=(\d+)\s*$') { [int]$Matches[1] }
Expect "finalize: cited evidence not uploaded throws, nothing published (rc $urc)" ($urc -ne 0 -and $uo -match '1 evidence file\(s\) cited but not uploaded' -and -not (Test-Path "$ur/U1/report.md"))
$fo = Use-FakeUploader "    sys.stderr.write('gws: 403 quota\n'); sys.exit(3)" { Fin $ur U1 -NoTracker }
Expect "finalize: a failed upload names the uploader's exit code and stderr" ($fo -match 'failed \(exit 3\): gws: 403 quota')
# 3 images: inline under their checks in the report, a JSON as one file line; the comment: no evidence, exactly one link
$ir = New-Run 'I' @(@{ code = 'I1'; task = 'TI'; checks = @(@('C1', 'FAIL'), @('C2', 'PASS')) }); New-Item -ItemType Directory -Force "$ir/I1/shots" | Out-Null
$evf = 'I1-C1_01_before.png', 'I1-C1_02_after.png', 'I1-C1_03_resp.json', 'I1-C2_01_list.png'; $evf | ForEach-Object { [IO.File]::WriteAllBytes("$ir/I1/shots/$_", [byte[]](1, 2)) }
'{"rates":{"child":[567,567]},"original":567}' | Set-Content "$ir/I1/shots/I1-C1_03_resp.json"
$rj = Read-Json "$ir/I1/results.json"; $rj.checks[0].evidence = $evf[0..2]; $rj.checks[1].evidence = @($evf[3]); & $J $rj "$ir/I1/results.json"
$null = Use-FakeUploader @'
    if a[1] == 'doc': print('https://docs.example/d/R1'); sys.exit(0)
    ff = [os.path.basename(x) for x in open(a[a.index('--files-from') + 1], encoding='utf-8-sig').read().splitlines() if x.strip()]
    print(json.dumps({'folderId': 'F', 'folderLink': 'https://f/F', 'files': {n: {'id': n, 'link': 'https://f/' + n, 'src': 'https://img/' + n} for n in ff}}))
'@ { Fin $ir I1 } "'evidence', 'doc'"
$irp = Get-Content "$ir/I1/report.md" -Raw; $ic = @((Task 'TI').comments | Where-Object { $_.text -match 'Test results' })
Expect 'report: 3 images inline under their checks (caption = id), JSON as a file line; one comment, one link, no evidence list' (([regex]::Matches($irp, '!\[')).Count -eq 3 -and
  $irp -match '(?m)^\| \*\*C1\*\* s \| \*\*FAIL\*\* \|[^\n]*!\[C1: Before\][^\n]*`rates\.child\[1\]: 567`<br>[^\n]*\[full file\]\(https://f/I1-C1_03_resp\.json\)' -and $irp -match '\| Task TI \| 1 \| 1 \| 0 \| failed \|' -and $ic.Count -eq 1 -and ([regex]::Matches($ic[0].text, 'https?://')).Count -eq 1 -and $ic[0].text -notmatch '\*\*Evidence|\]\(')
# a task with a human testing doc (Result / Evidence empty): finalize on the env fills them (same doc) + a dated "<env> run" section
$ad = "$(Kd)/TAI-h.md"; New-Item -ItemType Directory -Force (Split-Path $ad), "$k/.state/published" | Out-Null; Set-Content $ad 'v1'
& $J @{ key = 'TAI:testing-doc'; url = $ad; rounds = @(@{ at = '2026-10-29 10:00'; label = ''; ext = '.md'; body = "# Testing: X`n| # | Steps | Expected | Result | Evidence |`n|---|---|---|---|---|`n| C1 | open a | a shown | | |`n| C2 | open b | b shown | | |" }) } "$k/.state/published/TAI_testing-doc.json"
$ai = New-Run 'AI' @(@{ code = 'Q1'; task = 'TAI'; checks = @(@('C1', 'PASS'), @('C2', 'FAIL')) }); New-Item -ItemType Directory -Force "$ai/Q1/shots" | Out-Null
[IO.File]::WriteAllBytes("$ai/Q1/shots/Q1-C1_01_a.png", [byte[]](1, 2)); $rj = Read-Json "$ai/Q1/results.json"; $rj.checks[0].evidence = @('Q1-C1_01_a.png'); & $J $rj "$ai/Q1/results.json"
$null = Fin $ai Q1; $at = Get-Content $ad -Raw; $ti = Read-Json (Join-Path (TkPath $k tasks) 'TAI.json')
Expect 'finalize: run index (items.Q1) and task index (envRuns, docs.testing-doc) written' ((Read-Json "$ai/index.json").items.Q1.tasks -contains 'TAI' -and
  $ti.envRuns[0].code -eq 'Q1' -and $ti.envRuns[0].fail -eq 1 -and $ti.docs.'testing-doc'.url -eq $ad)
Expect 'finalize: the human doc (same file) gets the env Result / Evidence per row and a dated "<env> run" section; no report doc' ((Read-Json "$ai/Q1/finalize.json").doc -eq $ad -and
  $at -match '\| C1 \| open a \| a shown \| PASS \| !\[C1: A\]' -and $at -match '\| C2 \| open b \| b shown \| FAIL \|' -and $at -match '## t run 20' -and -not (Test-Path "$k/.state/published/TAI_qa-report.json"))
# NOT_TESTED for a cause no developer can fix: status kept, the owner decides (close / retest)
$nr = New-Run 'N' @(@{ code = 'N1'; task = 'TN'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) }); New-Task 'TN' 'Task N'
$rj = Read-Json "$nr/N1/results.json"; $rj.checks[1] | Add-Member cause 'env-data'; & $J $rj "$nr/N1/results.json"
$null = Fin $nr N1; $rn = Rec $nr N1
Expect 'NOT_TESTED env-data: status kept, keptOpen, a decision asked' (-not $rn.failedTesting -and (Task 'TN').status -eq 'open' -and $rn.keptOpen -match 'owner decides' -and "$($rn.decision)" -match 'DECISION')
# ---- review batch 2: pokey.ps1, testy, browser.mjs
$sd = TkPath $k qa-seats; New-Item -ItemType Directory -Force "$sd/claims" | Out-Null
$crd = Join-Path (Kd) 'runs/CL'; New-Item -ItemType Directory -Force $crd | Out-Null
$me = Get-Process -Id $PID
& $J @{ run = 'CL'; code = 'C1'; owner = 'w9'; since = (Get-Date).AddHours(-7).ToString('s'); holderPid = $PID; holderStart = $me.StartTime.ToUniversalTime().ToString('o') } "$sd/claims/CL__C1.json"
& $J @{ run = 'CL'; code = 'C2'; owner = 'w9'; since = (Get-Date).AddHours(-7).ToString('s') } "$sd/claims/CL__C2.json"
& $J @{ run = 'CL'; code = 'C4'; owner = 'w9'; since = (Get-Date).ToString('s'); holderPid = 999999; seen = '2000-01-01' } "$sd/claims/CL__C4.json"
$sq = { param($c, [double]$gb = 0.1) pwsh @np $Q seat acquire -Agent "test:$c" -Kind api -RunDir $crd -Code $c -Owner w1 -KeepFreeGB $gb -WaitMinutes 0 | Out-String; "rc=$LASTEXITCODE"; $null = pwsh @np $Q seat release -Agent "test:$c" }
$o1, $o2, $o4, $o3 = ('C1', 'C2', 'C4' | ForEach-Object { "$(& $sq $_)" }) + "$(& $sq C3 100000)"
Expect 'seat: a live holder keeps its claim past 6 h; an unknown holder''s old claim is free; a dead holder''s is taken over; still waiting exits 4' ($o1 -match 'ALREADY' -and $o1 -match 'rc=3' -and $o2 -notmatch 'ALREADY' -and
  $o4 -notmatch 'ALREADY' -and (Read-Json "$sd/claims/CL__C4.json").owner -eq 'w1' -and $o3 -match 'rc=4')
New-Item -ItemType Directory -Force "$sd/seats" | Out-Null
$sw = { param($n, $o) & $J ($o + @{ agent = $n; lease = $n; need = 0; since = (Get-Date).AddHours(-4).ToString('s') }) "$sd/seats/$n.json" }
& $sw L1 @{ holderPid = $PID; holderStart = $me.StartTime.ToUniversalTime().ToString('o') }; & $sw L2 @{ holderPid = 999999; seen = '2000-01-01' }; & $sw L3 @{ holderPid = 999999 }
$null = pwsh @np $Q seat status
Expect 'seat: a live holder''s 4 h seat stays; a dead one''s goes after the grace' ((Test-Path "$sd/seats/L1.json") -and -not (Test-Path "$sd/seats/L2.json") -and (Get-Content "$sd/seats/L3.json" | ConvertFrom-Json).seen); Remove-Item "$sd/seats/L*"
$sr = New-Run 'SR' @(@{ code = 'S1'; task = 'TS'; checks = , @('C1', 'PASS') }, @{ code = 'S2'; task = 'TS'; checks = , @('C2', 'PASS') })
$ps = @('S1', 'S2' | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile', '-File', "`"$Q`"", 'finalize', '-RunDir', "`"$sr`"", '-Code', $_ -PassThru -WindowStyle Hidden })
$ps | Wait-Process -Timeout 180
Expect 'finalize: parallel siblings of a shared task close it' (((Rec $sr 'S1').closed -or (Rec $sr 'S2').closed) -and (Task 'TS').status -eq 'closed')
$ex = New-Run 'EX' @(@{ code = 'E1'; task = 'TE'; checks = @(@('C1', 'PASS'), @('C2', 'PASS')) })
$eo = Fin $ex E1 -ExpectChecks 5
$null = Fin $ex E1 -Check -ExpectChecks 5; $ec = $LASTEXITCODE
$null = Fin $ex E1 -Check -ExpectChecks 2; $eok = $LASTEXITCODE
$er = Fin $ex E1 -Results results-retry.json
Expect 'finalize: -ExpectChecks refuses a truncated copy; -Results needs -Check' ($eo -match 'truncated copy' -and -not (Test-Path "$ex/E1/finalize.json") -and $ec -eq 1 -and $eok -eq 0 -and $er -match 'only with -Check')
New-Item -ItemType Directory -Force "$ex/E1/shots" | Out-Null; 'x' | Set-Content "$ex/E1/shots/retryshot.png"; 'y' | Set-Content "$ex/E1/shots/othershot.png"
& $J @{ code = 'E1'; checks = @(@{ id = 'C2'; subtask_id = 'TE'; screen = 's'; result = 'PASS'; what_was_done = 'w'; observed = 'o'; evidence = @('retryshot.png') }); findings = @(); setup_changes = @(); data_created = @() } "$ex/E1/results-retry.json" 6
$before = Get-Content "$ex/E1/results.json" -Raw
$null = Fin $ex E1 -Check -FixNames -Results results-retry.json
Expect 'finalize -Results: a scoped retry renames only its own files' (-not (Test-Path "$ex/E1/shots/retryshot.png") -and (Test-Path "$ex/E1/shots/othershot.png") -and (Get-Content "$ex/E1/results-retry.json" -Raw) -match 'E1-C2_' -and (Get-Content "$ex/E1/results.json" -Raw) -eq $before)
Remove-Item "$ex/E1/shots" -Recurse -Force; Remove-Item "$ex/E1/results-retry.json" -Force
$cf = New-Run 'CF' @(@{ code = 'F1'; task = 'TF'; checks = , @('C1', 'PASS') })
New-Task TF 'Task F' $null 'in test'
(Get-Item (Join-Path $store 'TF.json')).IsReadOnly = $true
$null = Fin $cf 'F1'; $r1 = Rec $cf 'F1'
(Get-Item (Join-Path $store 'TF.json')).IsReadOnly = $false
$null = Fin $cf 'F1'; $r2 = Rec $cf 'F1'
Expect 'finalize: failed comment keeps the task open; next run posts + closes' ($r1.commentFailed -and -not $r1.closed -and $r2.closed -and @((Task 'TF').comments | Where-Object { $_.text -match 'Test results' }).Count -eq 1)
$here0 = (Get-Location).Path
$wd = pwsh -NoProfile -Command "Set-Location '$($env:TEMP)'; . '$Q'; `$null = Invoke-Finalize -RunDir '$ex' -Code E1 -NoTracker *>&1; (Get-Location).Path" | Select-Object -Last 1
Expect 'finalize: the caller''s directory is restored' ($wd.TrimEnd('\') -eq $env:TEMP.TrimEnd('\') -and (Get-Location).Path -eq $here0)
$rt = New-Run 'RT' @(@{ code = 'Z1'; task = 'TZ'; checks = , @('C1', 'FAIL') })
New-Task TZ 'Task Z' $null open '### C1 — s'
$null = Fin $rt 'Z1'
$ro = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z1 -Mrs 'api!1' 2>&1 | Out-String
$arc = @(Get-ChildItem "$rt/Z1" -Directory -Filter 'archive-*')
Expect 'retest: a reused code archives the earlier round' ($arc.Count -eq 1 -and (Test-Path "$($arc[0].FullName)/finalize.json") -and -not (Test-Path "$rt/Z1/finalize.json") -and $ro -match 'archived the earlier round')
# tracker.bugPrefix; a check without evidence; guideId is a Docs URL only for gdocs
$kl = "$k/skills/crafty/kit.local.json"; '{"tracker":{"bugPrefix":"[Defect]"}}' | Set-Content $kl
foreach ($x in @('PY', 'Ask Y'), @('TY', 'T', 'PY'), @('BY', '[Defect] Ask Y — new defects (1)', 'PY')) { New-Task @x }
$by = New-Run 'BY' @(@{ code = 'Y1'; task = 'TY'; checks = , @('X1', 'FAIL', 'new') })
(Get-Content "$by/run.json" -Raw) -replace '"code":', '"guideId": "G4", "code":' | Set-Content "$by/run.json"
(Get-Content "$by/Y1/results.json" -Raw) -replace '"evidence":', '"x":' | Set-Content "$by/Y1/results.json"
$null = Fin $by 'Y1'; $null = pwsh @np $Q retest -RunDir $by -Task BY -Code Y2
Expect 'bugPrefix: another open [Defect] untouched; retest strips it; no evidence key; guideId' ((Task 'BY').name -eq '[Defect] Ask Y — new defects (1)' -and -not (Task 'BY').description -and (Get-Content "$by/run.json" -Raw) -match 'RETEST Ask Y — new' -and (Get-Content "$by/Y1/report.md" -Raw) -notmatch 'docs\.google'); Remove-Item $kl
& $J @{ targets = @{ tq = @{ api = 'http://127.0.0.1:9'; auth = @{ type = 'none' } }; tw = @{ web = 'http://127.0.0.1:9'; auth = @{ type = 'none' } } } } (Join-Path $k 'skills/pokey/targets.local.json') 5
$ao = Px $Q api -Target tq -Path '/x' -TimeoutSec 5 2>&1 | Out-String; $ac = $LASTEXITCODE
$uo = Px $Q ui dump 2>&1 | Out-String; $uc = $LASTEXITCODE   # phone lanes are the goody android-swarm
$xo = foreach ($v in 'deployed', 'annotate') { $o = Px $Q $v 2>&1 | Out-String; "$LASTEXITCODE $o".Trim() }
$wo = Px $Q api -Target tw -Path '/x' 2>&1 | Out-String
Expect 'api: no answer exits 1 (status shown); ui, deployed, annotate without goodies exit 2 naming them; web-only target' ($ac -eq 1 -and $ao -match 'HTTP 0' -and $uc -eq 2 -and $uo -match 'goody add android-swarm' -and $xo[0] -match '(?s)^2 .*goody add deploys' -and $xo[1] -match '(?s)^2 .*goody add android-swarm' -and $wo -match 'no api URL')
$api = Start-TestApi; $P = $api.port
$T = { param($a, $sub) @{ api = "http://127.0.0.1:$P$sub"; auth = $a; users = @{ admin = 'u', 'K9' }; defaultTenant = 'acme' } }; $L = @{ path = '/login'; body = @{} }
& $J @{ targets = @{ tl = & $T ($L + @{ type = 'login' }); tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tt = & $T @{ type = 'none' } '/t/{tenant}' } } (Join-Path $k 'skills/pokey/targets.local.json') 6
$ok = foreach ($x in 'tl/l', 'tt/x') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
$xo = Px $Q api -Target tc -Path '/c' 2>&1 | Out-String; $xc = $LASTEXITCODE
Expect "api auth login + none; other kinds name their goody ($ok)" (@($ok).Count -eq 2 -and (Get-Content "$(Kd)/A1-C1_01_tl.json" -Raw) -match '"authorization": "\[redacted\]"' -and $xc -eq 1 -and $xo -match 'is a goody: run kitbag\.py goody add api-auth')
foreach ($e in 'pdf', 'txt', 'empty') { $null = Px $Q api -Target tt -Path "/$e" -Save "S-$e" -OutDir (Kd) 2>&1 }; $bo = @(Get-ChildItem (Kd) -Filter 'S-*.body*').Name -join ' '
Expect "api -Save: octet-stream sniffed, empty body: no file ($bo)" ($bo -ceq 'S-pdf.body.pdf S-txt.body.txt')
Expect 'api -ContentType is sent' ((Px $Q api -Target tt -Method POST -Path '/ct' -Body 'hi' -ContentType text/plain 2>&1) -match 'HTTP 200')
$pp = Px $Q api /x -Target tt 2>&1 | Out-String; $pg = Px $Q api -Target tt -Path 'C:/Program Files/Git/x' 2>&1 | Out-String
Expect 'api: a Git Bash path (C:/Program Files/Git/x) is sent as /x' ($pg -match 'HTTP 200'); $pu = Px $Q api -Target tt 2>&1 | ForEach-Object { "$_" } | Out-String; $puc = $LASTEXITCODE
Expect 'api: the first bare arg is -Path; none -> exit 2 with the usage line' ($pp -match 'HTTP 200' -and $puc -eq 2 -and $pu -match 'Usage: api -Target')
$api.proc.Kill()
# browser.mjs: mocks, then local fixture servers
$qk = "$k/skills/pokey"
if (Use-BrowserKit) {
  $res = NodeT pick ("const pg = (els) => ({ waitForSelector: async () => {}, `$`$: async () => els }), e = (p) => m.pick(p, '.x', 0, 'x').catch((x) => x.message)`n" +
    "console.log(/has 0 match\(es\), no index 0/.test(await e(pg([]))), /has no box/.test(await e(pg([{ scrollIntoView: async () => {}, boundingBox: async () => null }]))))")
  Expect 'browser.mjs pick: bad nth / hidden element errors' ("$res" -eq 'true true')
  & $J @{ pins = @{ 'net.timeoutSec|gh' = @{ value = 33 } }; byKey = @{ 'idle.graceMinutes' = @{ _ = @{ value = 4.6 } } } } (TkPath $k param-state -Create)
  $ps = pwsh -NoProfile -Command ". '$(Lib)'; Get-KitParam idle.graceMinutes 10; Get-KitParam net.timeoutSec 60 gh; Get-KitParam gate.waitMinutes 90"
  $res = NodeT param "console.log([m.kitParam('idle.graceMinutes', 10), m.kitParam('net.timeoutSec', 60, 'gh'), m.kitParam('gate.waitMinutes', 90)].join(' '))"
  Expect 'browser.mjs kitParam = Get-KitParam' ("$res" -eq ($ps -join ' ') -and "$res" -eq '4.6 33 90')
  $res = NodeT ports @'
import { rmSync, existsSync } from 'node:fs'
const P = m.sessionPort, a = await P('s', 't', 'a'), seen = [], job = (n) => m.withLock('l', async () => { seen.push(n); await new Promise((r) => setTimeout(r, 150)); seen.push(n) })
await Promise.all([job(1), job(2)]); const uniq = new Set([a, await P('s', 't', 'v'), await P('p', 't', 'a')]).size === 3
rmSync(m.kitPath('browser-ports')); console.log(a === await P('s', 't', 'a') && uniq, /^(\d),\1,/.test(seen.join(',')), existsSync(m.kitPath('browser-ports')))
'@
  Expect 'browser.mjs: stable port per user key, locked logins' ("$res" -eq 'true true true')
  $env:KIT_BROWSER_PORT_BASE = 30000
  $res = NodeT base "const u = [], pg = (web) => ({ __qa: { t: { web } }, goto: async (x) => u.push(x), on() {}, off() {}, waitForNetworkIdle: async () => {} })`nawait m.go(pg('a'), '/x'); await m.go(pg('b'), '/y'); console.log(u + '' === 'a/x,b/y', (await m.sessionPort('pb', 't', 'a')) >= 30000)"
  Remove-Item Env:KIT_BROWSER_PORT_BASE
  Expect 'browser.mjs: each tab uses its own target; browser.portBase' ("$res" -eq 'true true')
  # tab cap: 9 concurrent openers -> 8 tabs, the 9th waits; a full browser fails clearly; dead / left holders are swept
  $res = NodeT tabs @'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
const { openTab, closeTab, kitPath, sweepAll } = m
let n = 0, max = 0; const tabs = [], K = 'k|t|a'
const mk = () => { const id = 'T' + (++n), p = { url: () => 'https://app/x', close: async () => { tabs.splice(tabs.indexOf(p), 1) },
  createCDPSession: async () => ({ send: async () => ({ targetInfo: { targetId: id } }), detach: async () => {} }) }; return p }
const browser = { pages: async () => [...tabs], newPage: async () => { await new Promise((r) => setTimeout(r, 20)); const p = mk(); tabs.push(p); max = Math.max(max, tabs.length); return p } }
let done = 0; const all = Array.from({ length: 9 }, () => openTab(browser, K, { agent: 'A' }).then((p) => { done++; return p }))
for (let i = 0; i < 100 && done < 8; i++) await new Promise((r) => setTimeout(r, 50))   // 8 open, then the 9th must still wait
await new Promise((r) => setTimeout(r, 300))
console.log('waits:' + (tabs.length === 8 && max === 8 && done === 8))
await closeTab(tabs[0], K); const got = await Promise.all(all)
console.log('ninth:' + (got.every(Boolean) && tabs.length === 8 && max === 8))
const e = await openTab(browser, K, { agent: 'A', waitMs: 1200 }).catch((x) => x.message)
console.log('fails:' + /all 8 tabs of k\|t\|a stayed busy for 1 s/.test(e))
const f = `${kitPath('sessions')}/tabs-k__t__a.json`, reg = JSON.parse(readFileSync(f, 'utf8'))
reg[tabs[1].__tid].pid = 999999; reg[tabs[2].__tid].agent = 'Z'; reg[tabs[1].__tid].at = reg[tabs[2].__tid].at = reg[tabs[1].__tid].seen = reg[tabs[2].__tid].seen = 0; reg[tabs[3].__tid].pid = 999999; writeFileSync(f, JSON.stringify(reg))
mkdirSync(kitPath('board'), { recursive: true }); writeFileSync(`${kitPath('board')}/z.json`, JSON.stringify({ agent: 'Z', status: 'left' }))
const dead = tabs[1], left = tabs[2], grace = tabs[3], t = await openTab(browser, K, { agent: 'A', waitMs: 1200 }).catch(() => null)
console.log('orphans:' + (!!t && !tabs.includes(dead) && !tabs.includes(left) && tabs.includes(grace) && tabs.length === 7))
const S = kitPath('sessions'); writeFileSync(kitPath('browser-ports'), JSON.stringify({ 'k|t|a': 9, 'u__v|t|a': 9 }))
writeFileSync(`${S}/tabs-u____v__t__a.json`, JSON.stringify({ _key: 'u__v|t|a' })); writeFileSync(`${S}/tabs-gone.json`, JSON.stringify({ _key: 'gone' }))
await sweepAll(); console.log('sweep:' + (existsSync(f) && existsSync(`${S}/tabs-u____v__t__a.json`) && !existsSync(`${S}/tabs-gone.json`)))
'@
  Expect-Each $res 'browser.mjs tabs: #' 'waits', 'ninth', 'fails', 'orphans', 'sweep'
  Expect 'browser.mjs: never logs out' ((Get-Content "$qk/browser.mjs" -Raw) -notmatch '(?i)localStorage\.clear|sessionStorage\.clear|logout|8 \* 3600')
  # fixture app: form login, relogin (Chrome); sso-steps / other engines name their goody
  $res = NodeT auth ($LoginApp + @'
const [TF, SLOW] = process.argv.slice(2), F = { '#u': '{user}', '#c': '123456' }, steps = [{ goto: '/sso-app' }, { fill: F }, { click: 'button', waitUrl: '/$' }]
writeFileSync(TF, JSON.stringify({ default: 'form', targets: { form: { web, webLogin: { path: '/login', fields: F, submit: 'button' }, users: U },
  sso: { web, webLogin: { type: 'sso-steps', steps }, users: U }, ff: { web, browser: { engine: 'firefox' }, webLogin: {}, users: U } } }))
const { b, home, out } = await login()
await out('goodies', async () => /goody add browser-engines/.test(await b.session({ target: 'ff' }).then(() => '', (e) => e.message)))
process.env.KIT_QA_TARGETS = 'x'; await out('pin', () => b.session({ target: 'form' }).then(() => false, (e) => /QA run's target/.test(e.message))); delete process.env.KIT_QA_TARGETS
// a real headless Chrome only with KIT_TESTS_SLOW (seconds each)
if (SLOW) await out('webext', async () => /goody add web-login-types/.test(await b.session({ target: 'sso' }).then(() => '', (e) => e.message)))
if (SLOW) await out('chrome', async () => { const s = await b.session({ tenant: 'a' }), r = s.key === 'form|a|admin' && await home(s) && posts === 1; gen++; await b.go(s.page, '/'); const r2 = r && await home(s) && posts === 2; await s.done(); await b.killSession(s.port); return r2 })
process.exit(0)
'@) "$qk/targets.local.json" $(if ($env:KIT_TESTS_SLOW) { '1' } else { '' })
  Expect-Each $res 'browser.mjs login: #' (@('goodies', 'pin') + @(if ($env:KIT_TESTS_SLOW) { 'webext', 'chrome' }))
} else { 'SKIP browser.mjs (no puppeteer-core in skills/pokey)' }
$fk = New-Run 'FK' @(@{ code = 'K1'; task = 'TQ'; checks = , @('X1', 'FAIL', 'new') })
$rk = Read-Json "$fk/K1/results.json"; $rk.checks[0] | Add-Member flaky $true; & $J $rk "$fk/K1/results.json"
$null = Fin $fk 'K1'
Expect 'finalize: flaky new defect -> [Bug] task, tagged flaky' (@(Bugs | Where-Object { $_.parent -eq 'PQ' -and $_.name -match '\[flaky\]' -and $_.description -match '### X1 — s \(flaky\)' }).Count -eq 1)
# bossy.ps1 bugbrief (a QA bug's brief) and a missing verb
$BX = Join-Path $k 'skills/bossy/bossy.ps1'
$kl = Join-Path $k 'skills/crafty/kit.local.json'; Set-JsonFile $kl @{ repos = @(@{ name = 'w'; checkout = 'C:/w'; target = 'm' }) }
$bb = Invoke-PsTest bb @'
. $args[0]; Update-KitTracking { param($tk) $tk.tasks.b1 = @{ task = 'b1' } }
function Get-TrackerTask { @{ name = 'E500'; description = 'spike' } }; function Get-TrackerComments { }; function Get-TaskMrBranches { @{ repo = 'w'; branch = 'm' } }
$o = Invoke-BugBrief -Task b1 3>$null | Out-String; "d:$($o -match '"id":"B-b1"' -and (Get-Content (Join-Path (Get-KitPath briefs) b1.md) -Raw) -match '(?s)\*\*b1\*\* .*E500: spike.*\| w \| `C:/w` \| `m`')"
function Get-TaskMrBranches { }; "r:$(try { Invoke-BugBrief -Task b1 3>$null; 0 } catch { "$_" -match 'no -Repos' })"
'@ @($BX); Remove-Item $kl
Expect-Each $bb 'bugbrief without check headings: the task is the check, -Agent B-<task>, -Repos from its MRs, else an error (#)' 'd', 'r'
Remove-Item Env:KIT_TRACKER_TYPE, Env:KIT_REPORT_TYPE
Remove-TestKit $k
Complete-Tests
