#Requires -Version 7
<#
qa.tests.ps1: qa.ps1 finalize (result rule), seats, deployed, api, retest; browser.mjs.
Usage: pwsh -NoProfile -File <kit>/tests/qa.tests.ps1 (or tests/kit-tests.ps1 -Area qa).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qa; $Q = Join-Path $k 'skills/qa-kit/qa.ps1'; $store = Join-Path $k '.state/tracker-none'
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
function Fin($d, $c) { Px $Q finalize -RunDir $d -Code $c 2>&1 | Out-String }
function Rec($d, $c) { (Get-Content "$d/$c/finalize.json" -Raw | ConvertFrom-Json).subtasks[0] }
function Task($id) { Get-Content (Join-Path $store "$id.json") -Raw | ConvertFrom-Json }
function Bugs { @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.name -like '`[Bug`]*' }) }
New-Item -ItemType Directory -Force $store | Out-Null
foreach ($x in @(@('PA', 'Ask A', $null), @('PQ', 'Ask Q', $null), @('TA', 'Task A', 'PA'), @('TQ', 'Task Q', 'PQ'), @('TA2', 'Task A2', 'PA'))) {
  & $J @{ id = $x[0]; name = $x[1]; status = 'open'; parent = $x[2]; list = 'L1'; assignees = @(); description = ''; comments = @() } (Join-Path $store "$($x[0]).json")
}
$a = New-Run 'A' @(@{ code = 'A1'; task = 'T1'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
$out = Fin $a 'A1'
Expect 'NOT_TESTED -> failedTesting' ((Rec $a 'A1').failedTesting -and -not (Rec $a 'A1').closed -and (Task 'T1').status -eq 'failed testing')
Expect 'the comment lists the untested check' (@((Task 'T1').comments | Where-Object { $_.text -match '## Untested checks' -and $_.text -match '### C2' }).Count -eq 1)
Expect 'no task created for untested checks' (-not @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count)
$lo = New-Run 'LO' @(@{ code = 'L1'; task = 'TL'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
$rj = Get-Content "$lo/run.json" -Raw | ConvertFrom-Json; $rj | Add-Member localEnv 'shop'; & $J $rj "$lo/run.json"
$null = Fin $lo 'L1'; $rl = Rec $lo 'L1'
Expect 'local env: NOT_TESTED keeps the task open, not failedTesting' (-not $rl.failedTesting -and -not $rl.closed -and $rl.keptOpen -match 'ENV-FIX' -and (Task 'TL').status -ne 'failed testing')
$b = New-Run 'B' @(@{ code = 'B1'; task = 'T2'; checks = @(@('C1', 'PASS'), @('C2', 'FAIL')) })
$null = Fin $b 'B1'
Expect 'own FAIL -> failedTesting, no [Bug]' ((Rec $b 'B1').failedTesting -and (Rec $b 'B1').fail -eq 1 -and -not (Bugs).Count)
Expect 'failed check in the bug-brief format' (@((Task 'T2').comments | Where-Object { $_.text -match '### C2 — s' -and $_.text -match '\*\*Saw:\*\* o C2' }).Count -eq 1)
$c = New-Run 'C' @(@{ code = 'C1'; task = 'T4'; checks = @(@('C1', 'PASS'), @('C2', 'OUT_OF_SCOPE')) })
$null = Fin $c 'C1'
Expect 'all pass (+ OUT_OF_SCOPE) -> closed' ((Rec $c 'C1').closed -and (Rec $c 'C1').outOfScope -eq 1 -and (Get-Content "$c/C1/report.md" -Raw) -match 'OUT OF SCOPE 1')
$m = New-Run 'M' @(@{ code = 'M1'; task = 'TA'; checks = @(@('C1', 'PASS'), @('X1', 'FAIL')) }, @{ code = 'M2'; task = 'TA2'; checks = , @('C1', 'FAIL', 'new') }, @{ code = 'M3'; task = 'TQ'; checks = , @('X1', 'FAIL') })
$null = Fin $m 'M1'; $null = Fin $m 'M2'; $null = Fin $m 'M3'
$bA = @(Bugs | Where-Object { $_.parent -eq 'PA' }); $bQ = @(Bugs | Where-Object { $_.parent -eq 'PQ' })
Expect 'one [Bug] per ask, under the ask, named with the count' ($bA.Count -eq 1 -and $bQ.Count -eq 1 -and $bA[0].name -eq '[Bug] Ask A — new defects (2)')
Expect 'a task with only a new defect closes' ((Rec $m 'M1').closed -and (Rec $m 'M2').closed)
$n = New-Run 'N' @(@{ code = 'N1'; task = 'TA2'; checks = , @('X1', 'FAIL') })
$null = Fin $n 'N1'
Expect 'a later run appends to the open [Bug]' (@(Bugs | Where-Object { $_.parent -eq 'PA' }).Count -eq 1 -and @(Bugs | Where-Object { $_.parent -eq 'PA' })[0].name -eq '[Bug] Ask A — new defects (3)')
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
# 300 long evidence paths: a fake uploader records the command-line length and the files it got
$dt = Join-Path $k 'skills/dev-kit'; Move-Item "$dt/devtools.py" "$dt/devtools_real.py"
Set-Content "$dt/devtools.py" -Encoding utf8 @'
import sys, os, runpy, ctypes
here = os.path.dirname(os.path.abspath(__file__)); a = sys.argv
if a[1:2] == ['evidence']:
    ff = a[a.index('--files-from') + 1] if '--files-from' in a else None
    n = len([x for x in open(ff, encoding='utf-8-sig').read().splitlines() if x.strip()]) if ff else 0
    gl = ctypes.windll.kernel32.GetCommandLineW if os.name == 'nt' else None
    if gl: gl.restype = ctypes.c_wchar_p
    open(os.path.join(here, 'ev-rec.txt'), 'a').write(f'{len(gl() if gl else " ".join(a))} {n + len([x for x in a[2:] if x.endswith(".png")])}\n')
    print('{}')
else:
    a[0] = os.path.join(here, 'devtools_real.py'); runpy.run_path(a[0], run_name='__main__')
'@
$lr = New-Run 'L' @(@{ code = 'L1'; task = 'T20'; checks = , @('C1', 'PASS') }); New-Item -ItemType Directory -Force "$lr/L1/shots" | Out-Null
foreach ($i in 1..300) { [IO.File]::WriteAllBytes("$lr/L1/shots/L1-C1_01_$('long-evidence-name-' * 7)$i.png", [byte[]](1, 2, 3)) }
$null = pwsh @np $Q finalize -RunDir $lr -Code L1 -NoTracker 2>&1; $lrc = $LASTEXITCODE
$rec = @(Get-Content "$dt/ev-rec.txt" -ErrorAction SilentlyContinue); Remove-Item "$dt/devtools.py"; Move-Item "$dt/devtools_real.py" "$dt/devtools.py"
Expect "300 long evidence paths: one upload, command line < 8191, all 300 files (rc $lrc; $rec)" ($lrc -eq 0 -and $rec.Count -eq 1 -and [int]($rec[0] -split ' ')[0] -lt 8191 -and ($rec[0] -split ' ')[1] -eq '300')
# deploy detection: a squash-merged deploy MR counts
$t = @'
. $args[0]
$ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
function Canned($deployMrs) {
  $script:memo = @{}; $p = 'g%2Fweb'
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=stg"] = [pscustomobject]@{ id = 'OLD' }
  $memo["projects/$p/repository/commits/stg"] = [pscustomobject]@{ committed_date = '2026-01-02T08:00:00Z' }
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=main"] = [pscustomobject]@{ id = 'F' }
  $memo["projects/$p/merge_requests/5/changes?access_raw_diffs=true"] = [pscustomobject]@{ changes = @([pscustomobject]@{ new_path = 'a.ts'; old_path = 'a.ts' }) }
  $memo["projects/$p/repository/compare?from=stg&to=main&straight=true"] = [pscustomobject]@{ diffs = @([pscustomobject]@{ new_path = 'a.ts'; old_path = 'a.ts' }) }
  $memo["projects/$p/merge_requests?state=merged&target_branch=stg&updated_after=2026-01-02T07:00:00Z&per_page=50"] = $deployMrs
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=S"] = [pscustomobject]@{ id = 'F' }
  $memo["projects/$p/repository/merge_base?refs[]=L&refs[]=stg"] = [pscustomobject]@{ id = 'L' }
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=S0"] = [pscustomobject]@{ id = 'X' }
  $p
}
$mr = [pscustomobject]@{ iid = 5; merged_at = '2026-01-02T07:00:00Z'; target_branch = 'main' }
$p = Canned @([pscustomobject]@{ iid = 9; sha = 'S'; squash_commit_sha = 'L'; merge_commit_sha = $null }); "squash:$(OnRef $p $mr 'F' 'stg')"
$p = Canned @([pscustomobject]@{ iid = 8; sha = 'S0'; squash_commit_sha = 'L'; merge_commit_sha = $null }); "other:$(-not (OnRef $p $mr 'F' 'stg'))"
'@
$f = Join-Path (Kd) 'deployed-test.ps1'; Set-Content $f $t
$res = @(pwsh @np $f $Q 2>&1)
Expect 'deployed: a squash-merged deploy MR counts as deployed' (@($res | Where-Object { "$_" -eq 'squash:True' }).Count -eq 1)
Expect 'deployed: a deploy MR without the commit does not' (@($res | Where-Object { "$_" -eq 'other:True' }).Count -eq 1)
# ---- review batch 2: qa.ps1, testy, browser.mjs
$sd = TkPath $k qa-seats; New-Item -ItemType Directory -Force "$sd/claims" | Out-Null
$crd = Join-Path (Kd) 'runs/CL'; New-Item -ItemType Directory -Force $crd | Out-Null
$me = Get-Process -Id $PID
& $J @{ run = 'CL'; code = 'C1'; owner = 'w9'; since = (Get-Date).AddHours(-7).ToString('s'); holderPid = $PID; holderStart = $me.StartTime.ToUniversalTime().ToString('o') } "$sd/claims/CL__C1.json"
& $J @{ run = 'CL'; code = 'C2'; owner = 'w9'; since = (Get-Date).AddHours(-7).ToString('s') } "$sd/claims/CL__C2.json"
$o1 = pwsh @np $Q seat acquire -Agent test:C1 -Kind api -RunDir $crd -Code C1 -Owner w1 -KeepFreeGB 0.1 -WaitMinutes 0 | Out-String; $c1 = $LASTEXITCODE
$o2 = pwsh @np $Q seat acquire -Agent test:C2 -Kind api -RunDir $crd -Code C2 -Owner w1 -KeepFreeGB 0.1 -WaitMinutes 0 | Out-String
$null = pwsh @np $Q seat release -Agent test:C2
$null = pwsh @np $Q seat acquire -Agent test:C3 -Kind api -KeepFreeGB 100000 -WaitMinutes 0; $c3 = $LASTEXITCODE
$null = pwsh @np $Q seat release -Agent test:C3
Expect 'seat: a live holder keeps its claim past 6 h; an unknown holder''s old claim is free; still waiting exits 4' ($c1 -eq 3 -and $o1 -match 'ALREADY' -and $o2 -notmatch 'ALREADY' -and $c3 -eq 4)
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
$eo = pwsh @np $Q finalize -RunDir $ex -Code E1 -ExpectChecks 5 2>&1 | Out-String
$null = pwsh @np $Q finalize -RunDir $ex -Code E1 -Check -ExpectChecks 5 2>&1; $ec = $LASTEXITCODE
$null = pwsh @np $Q finalize -RunDir $ex -Code E1 -Check -ExpectChecks 2 2>&1; $eok = $LASTEXITCODE
$er = pwsh @np $Q finalize -RunDir $ex -Code E1 -Results results-retry.json 2>&1 | Out-String
Expect 'finalize: -ExpectChecks refuses a truncated copy; -Results needs -Check' ($eo -match 'truncated copy' -and -not (Test-Path "$ex/E1/finalize.json") -and $ec -eq 1 -and $eok -eq 0 -and $er -match 'only with -Check')
New-Item -ItemType Directory -Force "$ex/E1/shots" | Out-Null; 'x' | Set-Content "$ex/E1/shots/retryshot.png"; 'y' | Set-Content "$ex/E1/shots/othershot.png"
& $J @{ code = 'E1'; checks = @(@{ id = 'C2'; subtask_id = 'TE'; screen = 's'; result = 'PASS'; what_was_done = 'w'; observed = 'o'; evidence = @('retryshot.png') }); findings = @(); setup_changes = @(); data_created = @() } "$ex/E1/results-retry.json" 6
$before = Get-Content "$ex/E1/results.json" -Raw
$null = pwsh @np $Q finalize -RunDir $ex -Code E1 -Check -FixNames -Results results-retry.json 2>&1
Expect 'finalize -Results: a scoped retry renames only its own files' (-not (Test-Path "$ex/E1/shots/retryshot.png") -and (Test-Path "$ex/E1/shots/othershot.png") -and (Get-Content "$ex/E1/results-retry.json" -Raw) -match 'E1-C2_' -and (Get-Content "$ex/E1/results.json" -Raw) -eq $before)
Remove-Item "$ex/E1/shots" -Recurse -Force; Remove-Item "$ex/E1/results-retry.json" -Force
$cf = New-Run 'CF' @(@{ code = 'F1'; task = 'TF'; checks = , @('C1', 'PASS') })
& $J @{ id = 'TF'; name = 'Task F'; status = 'in test'; parent = $null; list = 'L1'; assignees = @(); description = ''; comments = @() } (Join-Path $store 'TF.json')
(Get-Item (Join-Path $store 'TF.json')).IsReadOnly = $true
$null = Fin $cf 'F1'; $r1 = Rec $cf 'F1'
(Get-Item (Join-Path $store 'TF.json')).IsReadOnly = $false
$null = Fin $cf 'F1'; $r2 = Rec $cf 'F1'
Expect 'finalize: failed results comment keeps the task open; next run posts + closes' ($r1.commentFailed -and -not $r1.closed -and $r2.closed -and @((Task 'TF').comments | Where-Object { $_.text -match 'Test results' }).Count -eq 1)
$here0 = (Get-Location).Path
$wd = pwsh -NoProfile -Command "Set-Location '$($env:TEMP)'; . '$Q'; `$null = Invoke-Finalize -RunDir '$ex' -Code E1 -NoTracker *>&1; (Get-Location).Path" | Select-Object -Last 1
Expect 'finalize: the caller''s directory is restored' ($wd.TrimEnd('\') -eq $env:TEMP.TrimEnd('\') -and (Get-Location).Path -eq $here0)
$rt = New-Run 'RT' @(@{ code = 'Z1'; task = 'TZ'; checks = , @('C1', 'FAIL') })
& $J @{ id = 'TZ'; name = 'Task Z'; status = 'open'; parent = $null; list = 'L1'; assignees = @(); description = '### C1 — s'; comments = @() } (Join-Path $store 'TZ.json')
$null = Fin $rt 'Z1'
$ro = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z1 -Mrs 'api!1' 2>&1 | Out-String
$arc = @(Get-ChildItem "$rt/Z1" -Directory -Filter 'archive-*')
Expect 'retest: a reused code archives the earlier round' ($arc.Count -eq 1 -and (Test-Path "$($arc[0].FullName)/finalize.json") -and -not (Test-Path "$rt/Z1/finalize.json") -and $ro -match 'archived the earlier round')
# tracker.bugPrefix; a check without evidence; guideId is a Docs URL only for gdocs
$kl = "$k/skills/dev-kit/kit.local.json"; '{"tracker":{"bugPrefix":"[Defect]"}}' | Set-Content $kl
foreach ($x in @('PY', 'Ask Y', $null), @('TY', 'T', 'PY'), @('BY', '[Defect] Ask Y — new defects (1)', 'PY')) { & $J @{ id = $x[0]; name = $x[1]; status = 'open'; parent = $x[2]; list = 'L1'; description = '' } "$store/$($x[0]).json" }
$by = New-Run 'BY' @(@{ code = 'Y1'; task = 'TY'; checks = , @('X1', 'FAIL', 'new') })
(Get-Content "$by/run.json" -Raw) -replace '"code":', '"guideId": "G4", "code":' | Set-Content "$by/run.json"
(Get-Content "$by/Y1/results.json" -Raw) -replace '"evidence":', '"x":' | Set-Content "$by/Y1/results.json"
$null = Fin $by 'Y1'; $null = pwsh @np $Q retest -RunDir $by -Task BY -Code Y2
Expect 'bugPrefix: bug reused, renamed, stripped by retest; no evidence key; guideId' ((Task 'BY').name -eq '[Defect] Ask Y — new defects (2)' -and (Get-Content "$by/run.json" -Raw) -match 'RETEST Ask Y — new' -and (Get-Content "$by/Y1/report.md" -Raw) -notmatch 'docs\.google'); Remove-Item $kl
# deployed: an unanswered git host is UNKNOWN, not NOT-DEPLOYED
$t2 = @'
. $args[0]
function Invoke-HostApi { $null }
$ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$script:memo = @{}
$d = [pscustomobject]@{ target = 'stg'; branch = 'staging' }
"down:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state)"
$memo['projects/g%2Fweb/repository/commits/staging'] = [pscustomobject]@{ id = 'abc' }
"up:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state)"
'@
$f2 = Join-Path (Kd) 'deployed-null.ps1'; Set-Content $f2 $t2
$res = @(pwsh @np $f2 $Q 2>&1)
Expect 'deployed: no answer from the git host = UNKNOWN; an answer = NOT-DEPLOYED' ((@($res) -contains 'down:UNKNOWN') -and (@($res) -contains 'up:NOT-DEPLOYED'))
& $J @{ targets = @{ tq = @{ api = 'http://127.0.0.1:9'; auth = @{ type = 'none' } }; tw = @{ web = 'http://127.0.0.1:9'; auth = @{ type = 'none' } } } } (Join-Path $k 'skills/qa-kit/targets.local.json') 5
$ao = Px $Q api -Target tq -Path '/x' -TimeoutSec 5 2>&1 | Out-String; $ac = $LASTEXITCODE
$null = Px $Q ui bogus 2>&1; $uc = $LASTEXITCODE
# ui: a tap that finds nothing and a wait that times out exit 1 (fake adb serves one screen)
$ud = Join-Path (Kd) 'ui'; New-Item -ItemType Directory -Force "$ud/platform-tools" | Out-Null
Set-Content "$ud/s.xml" '<hierarchy><node text="Hello" resource-id="a:id/h" class="x" bounds="[0,0][10,10]"/></hierarchy>'
Set-Content "$ud/platform-tools/adb.cmd" "@echo off`r`nif `"%1`"==`"pull`" copy /y `"$ud\s.xml`" `"%3`" >nul`r`nexit /b 0" -Encoding ascii
Set-Content "$ud/u.ps1" '$a = @($args); Set-Item Env:CLAUDE_RUNTIME "$($a[1])/rt"; $env:ANDROID_HOME = $a[1]; . $a[0]; function Get-ExeName($n) { "$n.cmd" }; Invoke-Ui "$($a[2])" "$($a[3])" "$($a[4])"'
$ut = @(foreach ($a in @(@('tap', 'Hello'), @('tap', 'Nope'), @('wait', 'Nope', '1'))) { $null = Px "$ud/u.ps1" $Q $ud @a 2>&1; $LASTEXITCODE })
Expect "ui: found 0, NOT FOUND 1, wait TIMEOUT 1 ($($ut -join ','))" (($ut -join ',') -eq '0,1,1')
$wo = Px $Q api -Target tw -Path '/x' 2>&1 | Out-String
Expect 'api: no answer exits 1 (status printed); ui unknown action exits 2; web-only target named' ($ac -eq 1 -and $ao -match 'HTTP 0' -and $uc -eq 2 -and $wo -match 'no api URL')
$gr = Join-Path (Kd) 'pr'; git init -q $gr; git -C $gr commit -qm a --allow-empty; git -C $gr tag v1; $s1 = git -C $gr rev-parse HEAD; git -C $gr commit -qm b --allow-empty; $s2 = git -C $gr rev-parse HEAD
$sv = "$(Kd)/s.cjs"; $P = 18000 + $PID % 1000
Set-Content $sv @'
require('http').createServer((q, s) => { let b = ''; q.on('data', (d) => b += d); q.on('end', () => {
  const u = q.url, h = q.headers, j = (o, st = 200, hd = {}) => { s.writeHead(st, { 'content-type': 'application/json', ...hd }); s.end(JSON.stringify(o)) }
  if (u === '/login') return /R1/.test(b) ? j({ access_token: 'A2' }) : j({ access_token: 'A1', refresh_token: 'R1' }, 200, { 'set-cookie': ['sid=1', 'XSRF-TOKEN=x1'] })
  const ok = { '/l': h.authorization === 'Bearer A1', '/c': h.cookie && h['x-xsrf-token'] === 'x1', '/b': h.authorization === 'Bearer A2', '/q?api_key=K9': 1, '/t/acme/x': 1, '/t/acme/ct': h['content-type'] === 'text/plain', '/h': h['x-sig'] === 's1' }[u]
  u === '/v' ? j({ v: { sha: process.argv[3] } }) : j({}, ok ? 200 : 401) }) }).listen(+process.argv[2], '127.0.0.1')
'@
$srv = Start-Process node -ArgumentList $sv, $P, $s1 -PassThru -NoNewWindow; Start-Sleep 1
$T = { param($a, $sub) @{ api = "http://127.0.0.1:$P$sub"; auth = $a; users = @{ admin = 'u', 'K9' }; defaultTenant = 'acme' } }; $L = @{ path = '/login'; body = @{} }
& $J @{ targets = @{ tl = & $T ($L + @{ type = 'login' }); tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tt = & $T @{ type = 'none' } '/t/{tenant}' } } (Join-Path $k 'skills/qa-kit/targets.local.json') 6
$ok = foreach ($x in 'tl/l', 'tt/x') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
$xo = Px $Q api -Target tc -Path '/c' 2>&1 | Out-String; $xc = $LASTEXITCODE
Expect "api auth login + none; other kinds name their extra ($ok)" (@($ok).Count -eq 2 -and (Get-Content "$(Kd)/A1-C1_01_tl.json" -Raw) -match '"authorization": "\[redacted\]"' -and $xc -eq 1 -and $xo -match 'is an extra: run kittool\.py extra add api-auth')
Expect 'api -ContentType is sent' ((Px $Q api -Target tt -Method POST -Path '/ct' -Body 'hi' -ContentType text/plain 2>&1) -match 'HTTP 200')
Set-Content "$(Kd)/dp.ps1" @'
. $args[0]; $ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
function Invoke-HostApi($p) { switch -Wildcard ($p) { '*requests/5' { @{ iid = 5; state = 'merged'; sha = 'F'; merged_at = '2026-01-02' } } '*merge_base*' { @{ id = 'F' } } '*ref=staging*' { , @(@{ id = 1; created_at = '2026-01-03'; sha = 'F' }) } '*jobs*' { , @(@{ name = 'deploy-eu'; status = 'success' }) } } }
Invoke-Deployed -Mrs 'web!5' -Detail
'@
'{"repos":[{"name":"web","deploys":[{"target":"stg","branch":"staging","job":"deploy-*"},{"target":"vm","ssh":{"host":"h"}}]}]}' | Set-Content $kl
$res = @(Px "$(Kd)/dp.ps1" $Q $gr $s1 $s2 "http://127.0.0.1:$P/v" 2>&1); $srv.Kill(); Remove-Item $kl
Expect 'deployed: an ssh deploy without its extra is UNKNOWN with the extra line' ("$res" -match 'UNKNOWN\s+web!5\s+vm\s+deploys\[\] ssh is an extra: run kittool\.py extra add deployed-checks')
Expect 'deployed: a wildcard job matches a matrix job' ("$res" -match 'DEPLOYED\s+web!5')
# browser.mjs: mocks, then local fixture servers
$nm = "$src/skills/qa-kit/node_modules"; $qk = "$k/skills/qa-kit"
if (Test-Path "$nm/puppeteer-core") {
  Copy-Item "$src/skills/qa-kit/browser.mjs" $qk
  New-Item -ItemType Junction -Path "$qk/node_modules" -Value (Resolve-Path $nm).Path | Out-Null
  function NodeT($n, $js) { $f = Join-Path (Kd) "$n.mjs"; [IO.File]::WriteAllText($f, "const BM = 'file:///$("$qk/browser.mjs" -replace '\\', '/')', m = await import(BM)`n$js"); @(node $f @args 2>&1) }
  $res = NodeT pick ("const pg = (els) => ({ waitForSelector: async () => {}, `$`$: async () => els }), e = (p) => m.pick(p, '.x', 0, 'x').catch((x) => x.message)`n" +
    "console.log(/has 0 match\(es\), no index 0/.test(await e(pg([]))), /has no box/.test(await e(pg([{ scrollIntoView: async () => {}, boundingBox: async () => null }]))))")
  Expect 'browser.mjs pick: bad nth / hidden element errors' ("$res" -eq 'true true')
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
  foreach ($x in 'waits', 'ninth', 'fails', 'orphans', 'sweep') { Expect "browser.mjs tabs: $x" (@($res) -contains "${x}:true") }
  Expect 'browser.mjs: never logs out' ((Get-Content "$qk/browser.mjs" -Raw) -notmatch '(?i)localStorage\.clear|sessionStorage\.clear|logout|8 \* 3600')
  # fixture app: form login, relogin (Chrome); sso-steps / other engines name their extra
  $res = NodeT auth @'
import http from 'node:http'
import { writeFileSync } from 'node:fs'
const [TF, SLOW] = process.argv.slice(2), U = { admin: ['qa', '', 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'] }, F = { '#u': '{user}', '#c': '123456' }
let posts = 0, gen = 1
const form = (to) => `<html><form method="post" action="${to}"><input id="u" name="u"><input id="c" name="c"><button>Go</button>`
const app = http.createServer((q, s) => {
  const go = (l, c) => { s.writeHead(302, { location: l, ...(c && { 'set-cookie': `sid=${gen}; HttpOnly` }) }); s.end() }
  if (q.method === 'POST') { posts++; let d = ''; q.on('data', (x) => (d += x)); return q.on('end', () => (/u=qa&c=\d{6}/.test(d) ? go(web + '/', 1) : go(q.url))) }
  if (/^\/(login|idp)$/.test(q.url)) return s.end(form(q.url === '/idp' ? web + '/sso' : '/login'))
  if (q.headers.cookie === `sid=${gen}`) return s.end('<html>home')
  go(q.url === '/sso-app' ? web.replace('127.0.0.1', 'localhost') + '/idp' : '/login')
})
await new Promise((r) => app.listen(0, r))
const web = `http://127.0.0.1:${app.address().port}`, steps = [{ goto: '/sso-app' }, { fill: F }, { click: 'button', waitUrl: '/$' }]
writeFileSync(TF, JSON.stringify({ default: 'form', targets: { form: { web, webLogin: { path: '/login', fields: F, submit: 'button' }, users: U },
  sso: { web, webLogin: { type: 'sso-steps', steps }, users: U }, ff: { web, browser: { engine: 'firefox' }, webLogin: {}, users: U } } }))
const b = await import(BM + '?a'), home = async (s) => (await b.text(s.page)).includes('home'), out = async (k, f) => console.log(k + ':' + await f().catch((e) => e.message))
await out('extras', async () => /extra add browser-engines/.test(await b.session({ target: 'ff' }).then(() => '', (e) => e.message)))
process.env.KIT_QA_TARGETS = 'x'; await out('pin', () => b.session({ target: 'form' }).then(() => false, (e) => /QA run's target/.test(e.message))); delete process.env.KIT_QA_TARGETS
// a real headless Chrome only with KIT_TESTS_SLOW (seconds each)
if (SLOW) await out('webext', async () => /extra add web-login-types/.test(await b.session({ target: 'sso' }).then(() => '', (e) => e.message)))
if (SLOW) await out('chrome', async () => { const s = await b.session({ tenant: 'a' }), r = s.key === 'form|a|admin' && await home(s) && posts === 1; gen++; await b.go(s.page, '/'); const r2 = r && await home(s) && posts === 2; await s.done(); await b.killSession(s.port); return r2 })
process.exit(0)
'@ "$qk/targets.local.json" $(if ($env:KIT_TESTS_SLOW) { '1' } else { '' })
  foreach ($x in @('extras', 'pin') + @(if ($env:KIT_TESTS_SLOW) { 'webext', 'chrome' })) { Expect "browser.mjs login: $x" (@($res) -contains "${x}:true") }
  [IO.Directory]::Delete("$qk/node_modules")   # the junction only
} else { 'SKIP browser.mjs (no puppeteer-core in skills/qa-kit)' }
$sd = TkPath $k qa-seats; New-Item -ItemType Directory -Force "$sd/seats", "$sd/claims" | Out-Null
Set-JsonFile "$sd/seats/test_D1.json" @{ agent = 'test:D1'; kind = 'web'; need = 1.5; since = (Get-Date).ToString('s'); holderPid = 999999; seen = '2000-01-01' }
$rd = Join-Path (Kd) 'runs/S'; New-Item -ItemType Directory -Force $rd | Out-Null
Set-JsonFile "$sd/claims/S__S1.json" @{ run = 'S'; code = 'S1'; owner = 'w9'; since = (Get-Date).ToString('s'); holderPid = 999999; seen = '2000-01-01' }
$null = pwsh @np (Join-Path $k 'skills/qa-kit/qa.ps1') seat status
$cl = pwsh @np (Join-Path $k 'skills/qa-kit/qa.ps1') seat acquire -Agent test:S1 -Kind api -RunDir $rd -Code S1 -Owner w1 -KeepFreeGB 0.1 -WaitMinutes 0 | Out-String
Expect 'seats: a dead holder''s seat is freed, its claim taken over' (-not (Test-Path "$sd/seats/test_D1.json") -and $cl -notmatch 'ALREADY' -and (Get-Content "$sd/claims/S__S1.json" -Raw | ConvertFrom-Json).owner -eq 'w1')
$fk = New-Run 'FK' @(@{ code = 'K1'; task = 'TQ'; checks = , @('X1', 'FAIL', 'new') })
$rk = Get-Content "$fk/K1/results.json" -Raw | ConvertFrom-Json; $rk.checks[0] | Add-Member flaky $true; & $J $rk "$fk/K1/results.json"
$null = Fin $fk 'K1'
Expect 'finalize: flaky new defect -> [Bug] task, tagged flaky' (@(Bugs | Where-Object { $_.parent -eq 'PQ' -and $_.name -match '\[flaky\]' -and $_.description -match '### X1 — s \(flaky\)' }).Count -eq 1)
Remove-Item Env:KIT_TRACKER_TYPE, Env:KIT_REPORT_TYPE
Remove-TestKit $k
Complete-Tests
