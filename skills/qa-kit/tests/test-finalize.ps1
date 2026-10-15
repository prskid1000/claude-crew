# finalize.ps1 result rule, offline: tracker 'none' + markdown reports in a throw-away copy of the kit (no real tracker, no Drive).
#   pwsh -NoProfile -File <kit>/skills/qa-kit/tests/test-finalize.ps1      exit 0 = all pass
# Rule: all pass -> closed; own FAIL or NOT_TESTED -> failedTesting (no new task); new defect -> one [Bug] per original ask.
$ErrorActionPreference = 'Stop'
$src = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # the kit
$tmp = Join-Path ([IO.Path]::GetTempPath()) "kit-test-finalize-$PID"; $kit = Join-Path $tmp '.claude'
foreach ($d in 'skills/dev-kit/scripts', 'skills/qa-kit/scripts/lib') { New-Item -ItemType Directory -Force (Join-Path $kit $d) | Out-Null; Copy-Item (Join-Path $src "$d/*") (Join-Path $kit $d) -Recurse }
Copy-Item (Join-Path $src 'skills/qa-kit/scripts/finalize.ps1') (Join-Path $kit 'skills/qa-kit/scripts')
$env:KIT_TRACKER_TYPE = 'none'; $env:KIT_REPORT_TYPE = 'markdown'; Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # runtime = the temp kit's own
$fin = Join-Path $kit 'skills/qa-kit/scripts/finalize.ps1'; $store = Join-Path $kit 'tracker-none.local'
$fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
# checks: @(id, result[, defect])
function New-Run($name, $items) {
  $d = Join-Path $tmp "runs/$name"; New-Item -ItemType Directory -Force $d | Out-Null
  @{ title = "Run $name"; target = 't'; tracker = @{ list = 'L1'; parent = 'P1' }; items = @($items | ForEach-Object { @{ code = $_.code; title = $_.code; subtasks = @(@{ id = $_.task; name = "Task $($_.task)" }) } }) } | ConvertTo-Json -Depth 8 | Set-Content "$d/run.json"
  foreach ($it in $items) {
    New-Item -ItemType Directory -Force "$d/$($it.code)" | Out-Null
    @{ code = $it.code; checks = @($it.checks | ForEach-Object { $c = @{ id = $_[0]; subtask_id = $it.task; screen = 's'; result = $_[1]; what_was_done = 'w'; observed = "o $($_[0])"; evidence = @() }; if ($_.Count -gt 2) { $c.defect = $_[2] }; $c }); findings = @(); setup_changes = @(); data_created = @() } | ConvertTo-Json -Depth 8 | Set-Content "$d/$($it.code)/results.json"
  }
  $d
}
function Fin($d, $c) { & $fin -RunDir $d -Code $c 2>&1 | Out-String }
function Rec($d, $c) { (Get-Content "$d/$c/finalize.json" -Raw | ConvertFrom-Json).subtasks[0] }
function Task($id) { Get-Content (Join-Path $store "$id.json") -Raw | ConvertFrom-Json }
function Bugs { @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.name -like '`[Bug`]*' }) }
try {
  New-Item -ItemType Directory -Force $store | Out-Null
  foreach ($x in @(@('PA', 'Ask A', $null), @('PQ', 'Ask Q', $null), @('TA', 'Task A', 'PA'), @('TQ', 'Task Q', 'PQ'), @('TA2', 'Task A2', 'PA'))) {
    @{ id = $x[0]; name = $x[1]; status = 'open'; parent = $x[2]; list = 'L1'; assignees = @(); description = ''; comments = @() } | ConvertTo-Json | Set-Content (Join-Path $store "$($x[0]).json")
  }
  # NOT_TESTED -> failedTesting, the untested check named in the comment, no new task
  $a = New-Run 'A' @(@{ code = 'A1'; task = 'T1'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
  $o = Fin $a 'A1'
  Expect 'NOT_TESTED -> failedTesting' ((Rec $a 'A1').failedTesting -and -not (Rec $a 'A1').closed -and (Task 'T1').status -eq 'failed testing')
  Expect 'the comment lists the untested check' (@((Task 'T1').comments | Where-Object { $_.text -match '## Untested checks' -and $_.text -match '### C2' }).Count -eq 1)
  Expect 'the summary says failed testing' ($o -match 'T1: .*failed testing')
  Expect 'no task created for untested checks' (-not @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count)
  # own FAIL -> failedTesting, no [Bug] task; the comment has the bug-brief format
  $b = New-Run 'B' @(@{ code = 'B1'; task = 'T2'; checks = @(@('C1', 'PASS'), @('C2', 'FAIL')) })
  $null = Fin $b 'B1'
  Expect 'own FAIL -> failedTesting' ((Rec $b 'B1').failedTesting -and (Rec $b 'B1').fail -eq 1)
  Expect 'own FAIL creates no [Bug] task' (-not (Bugs).Count)
  Expect 'failed check in the comment (### id — screen, **Saw:**)' (@((Task 'T2').comments | Where-Object { $_.text -match '### C2 — s' -and $_.text -match '\*\*Saw:\*\* o C2' }).Count -eq 1)
  # all pass -> closed; OUT_OF_SCOPE never counts
  $c = New-Run 'C' @(@{ code = 'C1'; task = 'T4'; checks = @(@('C1', 'PASS'), @('C2', 'OUT_OF_SCOPE')) })
  $null = Fin $c 'C1'
  Expect 'all pass (+ OUT_OF_SCOPE) -> closed' ((Rec $c 'C1').closed -and (Rec $c 'C1').outOfScope -eq 1)
  Expect 'report counts it' ((Get-Content "$c/C1/report.md" -Raw) -match 'OUT OF SCOPE 1')
  # new defects -> one [Bug] per ask, under it; the task closes when its own checks pass; a guide check marked "new" counts too
  $m = New-Run 'M' @(@{ code = 'M1'; task = 'TA'; checks = @(@('C1', 'PASS'), @('X1', 'FAIL')) }, @{ code = 'M2'; task = 'TA2'; checks = , @('C1', 'FAIL', 'new') }, @{ code = 'M3'; task = 'TQ'; checks = , @('X1', 'FAIL') })
  $null = Fin $m 'M1'; $null = Fin $m 'M2'; $null = Fin $m 'M3'
  $bA = @(Bugs | Where-Object { $_.parent -eq 'PA' }); $bQ = @(Bugs | Where-Object { $_.parent -eq 'PQ' })
  Expect 'one [Bug] per ask, under the ask' ($bA.Count -eq 1 -and $bQ.Count -eq 1)
  Expect '[Bug] named after the ask with the count' ($bA[0].name -eq '[Bug] Ask A — new defects (2)')
  Expect '[Bug] lists both tasks' ($bA[0].description -match 'Task TA \(' -and $bA[0].description -match 'Task TA2 \(')
  Expect 'task with only a new defect closes' ((Rec $m 'M1').closed -and (Rec $m 'M1').bug -eq $bA[0].id -and (Rec $m 'M2').closed)
  # a later run appends to the ask's open [Bug]
  $n = New-Run 'N' @(@{ code = 'N1'; task = 'TA2'; checks = , @('X1', 'FAIL') })
  $null = Fin $n 'N1'
  $bA = @(Bugs | Where-Object { $_.parent -eq 'PA' })
  Expect 'a later run appends to the open [Bug]' ($bA.Count -eq 1 -and $bA[0].name -eq '[Bug] Ask A — new defects (3)' -and $bA[0].description -match 'Task TA \(')
  # a re-run never posts a second results comment
  $null = Fin $c 'C1'
  Expect 'one results comment' (@((Task 'T4').comments | Where-Object { $_.text -match 'Test results' }).Count -eq 1)
  # an unknown verdict renders instead of failing the publish
  $e = New-Run 'E' @(@{ code = 'E1'; task = 'T5'; checks = , @('C1', 'PASSED') })
  $null = Fin $e 'E1'
  Expect 'unknown verdict still publishes' (Test-Path "$e/E1/report.md")
  # a second subtask no check names stays open (0 of 0 is not a pass); a dups entry shares the primary's checks
  $f = New-Run 'F' @(@{ code = 'F1'; task = 'T6'; checks = , @('C1', 'PASS') })
  $r = Get-Content "$f/run.json" -Raw | ConvertFrom-Json; $r.items[0].subtasks = @($r.items[0].subtasks) + @([pscustomobject]@{ id = 'T7'; name = 'Task T7' }); $r | ConvertTo-Json -Depth 8 | Set-Content "$f/run.json"
  $null = Fin $f 'F1'; $s = (Get-Content "$f/F1/finalize.json" -Raw | ConvertFrom-Json).subtasks
  Expect 'untagged subtask kept open' ((@($s | Where-Object id -eq 'T6')[0]).closed -and -not (@($s | Where-Object id -eq 'T7')[0]).closed)
  $g = New-Run 'G' @(@{ code = 'G1'; task = 'T8'; checks = , @('C1', 'PASS') })
  $r = Get-Content "$g/run.json" -Raw | ConvertFrom-Json; $r.items[0].subtasks = @($r.items[0].subtasks) + @([pscustomobject]@{ id = 'T9'; name = 'Task T9' }); $r.items[0] | Add-Member dups ([pscustomobject]@{ T9 = 'T8' }); $r | ConvertTo-Json -Depth 8 | Set-Content "$g/run.json"
  $null = Fin $g 'G1'
  Expect 'dups subtask closes with its primary' (@((Get-Content "$g/G1/finalize.json" -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.closed }).Count -eq 2)
  # a shared task: the first item waits for the second, then a failure in either sends the task to failedTesting
  $h = New-Run 'H' @(@{ code = 'H1'; task = 'T10'; checks = , @('C1', 'PASS') }, @{ code = 'H2'; task = 'T10'; checks = , @('C2', 'FAIL') })
  $null = Fin $h 'H1'
  Expect 'shared task waits for its sibling' ((Rec $h 'H1').waitingFor -contains 'H2' -and -not (Rec $h 'H1').closed)
  $null = Fin $h 'H2'
  Expect 'sibling failure -> failedTesting' ((Rec $h 'H2').failedTesting)
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$fails failure(s)"; exit [int]($fails -gt 0)
