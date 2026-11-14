#Requires -Version 7
<#
qa-config.tests.ps1: pokey.ps1 config-driven QA rules: neutral finalize defaults (qa.newDefectIdRx, qa.holdCauses), qa.lanes,
prepare (process.docs guide doc, qa.guideDoc; none = the task text guides).
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
function Fin($d, $c) { Px $Q finalize -RunDir $d -Code $c 2>&1 | Out-String }
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
# lanes: qa.lanes names any lane; unset = web only; unknown names the configured list
$lo1 = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z2 -Lane app 2>&1 | Out-String; $lc1 = $LASTEXITCODE
'{"qa":{"lanes":{"web":{"kind":"web"},"desk":{"kind":"desktop"},"phone":{"kind":"app","devices":"android"}}}}' | Set-Content $kl
$lo2 = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z3 -Lane desk 2>&1 | Out-String; $lz = @((Read-Json "$rt/run.json").items | Where-Object code -eq 'Z3')[0]
$lo3 = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z4 -Lane app 2>&1 | Out-String; $lz4 = @((Read-Json "$rt/run.json").items | Where-Object code -eq 'Z4')[0]
Expect "lanes: unset -> only web (app refused, list named); a configured desktop lane accepted; a kind resolves to its lane ($lc1)" ($lc1 -ne 0 -and $lo1 -match "unknown lane 'app'.*are web" -and $lz.lane -eq 'desk' -and $lz4.lane -eq 'phone')
Remove-Item $kl -ErrorAction SilentlyContinue
# ---- prepare (item 4): pokey.ps1 prepare = L1 selection by script: run.json, lead-notes skeleton, Left out; the last line RUN <json>
$PKp = Join-Path $k 'skills/pokey/pokey.ps1'
$mkTask = { param($Name, $Desc) (pwsh -NoProfile -File $craftyPs tracker create -Name $Name -Description $Desc -NewTask fixture 2>$null | ConvertFrom-Json).id }
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
$ppAgain = @(pwsh -NoProfile -File $PKp prepare -Job $pjob 2>&1); $ppAgainCode = $LASTEXITCODE
$null = New-Item -ItemType Directory -Force "$wd/qa-runs/$pDay-empty/guides"; $pjobEmpty = $pjob -replace '<yyyy-MM-dd>-stg', '<yyyy-MM-dd>-empty'
$ppEmpty = @(pwsh -NoProfile -File $PKp prepare -Job $pjobEmpty 2>&1); $ppEmptyCode = $LASTEXITCODE
Expect "prepare: a run folder with files is refused (exit 1, no -2 suffix); an empty one is reused and RUN printed ($ppAgainCode $ppEmptyCode $($ppEmpty[-2]))" ($ppAgainCode -eq 1 -and "$ppAgain" -match 'exists with files' -and -not (Test-Path "$wd/qa-runs/$pDay-stg-2") -and $ppEmptyCode -eq 0 -and "$($ppEmpty[-1])" -match "^RUN .*qa-runs/$pDay-empty""")
Remove-Item $kl
$ppNd = @(pwsh -NoProfile -File $PKp prepare -Job ($pjob -replace '<yyyy-MM-dd>-stg', '<yyyy-MM-dd>-nodoc') 2>&1); $ndRun = ("$($ppNd[-1])" -replace '^RUN ') | ConvertFrom-Json
Expect "prepare, no process.docs: no doc needed, the task text is the guide, lane = the first qa.lanes lane (web) ($($ppNd[-2]))" (@($ndRun.items).Count -eq 2 -and -not @($ndRun.left).Count -and (Get-Content -Raw $ndRun.items[1].guideFile) -match 'No testing doc configured' -and $ndRun.items[0].lane -eq 'web')
# browser.mjs defaultUser: no 'admin' default (as pokey.ps1 api)
if (Use-BrowserKit) {
  $du = "import { defaultUser } from '$((Join-Path $k 'skills/pokey/browser.mjs').Replace('\', '/') -replace '^', 'file:///')'`nconst two = { users: { a: 1, b: 2 } }`nlet e = ''; try { defaultUser(two, 'tt') } catch (x) { e = x.message }`nconsole.log([defaultUser({ users: { solo: 1 } }), defaultUser({ ...two, defaultUser: 'b' }), defaultUser({}), /several users/.test(e)].join('|'))"
  Set-Content "$(Kd)/du.mjs" $du; $duo = node "$(Kd)/du.mjs" 2>&1 | Out-String
  Expect "browser defaultUser: one user = it; target defaultUser; none = ''; several, none chosen -> refused ($duo)" ($duo.Trim() -eq 'solo|b||true')
}
Remove-Item Env:KIT_TRACKER_TYPE, Env:KIT_REPORT_TYPE -ErrorAction SilentlyContinue
Remove-TestKit $k
Complete-Tests
