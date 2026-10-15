# finalize.ps1 close rules, offline: tracker 'none' + markdown reports in a throw-away copy of the kit (no real tracker, no Drive).
#   pwsh -NoProfile -File <kit>/skills/qa-kit/tests/test-finalize.ps1      exit 0 = all pass
$ErrorActionPreference = 'Stop'
$src = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # the kit
$tmp = Join-Path ([IO.Path]::GetTempPath()) "kit-test-finalize-$PID"; $kit = Join-Path $tmp '.claude'
foreach ($d in 'skills/dev-kit/scripts', 'skills/qa-kit/scripts/lib') { New-Item -ItemType Directory -Force (Join-Path $kit $d) | Out-Null; Copy-Item (Join-Path $src "$d/*") (Join-Path $kit $d) -Recurse }
Copy-Item (Join-Path $src 'skills/qa-kit/scripts/finalize.ps1') (Join-Path $kit 'skills/qa-kit/scripts')
$env:KIT_TRACKER_TYPE = 'none'; $env:KIT_REPORT_TYPE = 'markdown'; Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # runtime = the temp kit's own
$fin = Join-Path $kit 'skills/qa-kit/scripts/finalize.ps1'; $store = Join-Path $kit 'tracker-none.local'
$fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
function New-Run($name, $closeNT, $items) {
  $d = Join-Path $tmp "runs/$name"; New-Item -ItemType Directory -Force $d | Out-Null
  $tr = @{ list = 'L1'; parent = 'P1' }; if ($null -ne $closeNT) { $tr.closeWithNotTested = $closeNT }
  @{ title = "Run $name"; target = 't'; tracker = $tr; items = @($items | ForEach-Object { @{ code = $_.code; title = $_.code; subtasks = @(@{ id = $_.task; name = "Task $($_.task)" }) } }) } | ConvertTo-Json -Depth 8 | Set-Content "$d/run.json"
  foreach ($it in $items) {
    New-Item -ItemType Directory -Force "$d/$($it.code)" | Out-Null
    @{ code = $it.code; checks = @($it.checks | ForEach-Object { @{ id = $_[0]; subtask_id = $it.task; screen = 's'; result = $_[1]; what_was_done = 'w'; observed = "o $($_[0])"; evidence = @() } }); findings = @(); setup_changes = @(); data_created = @() } | ConvertTo-Json -Depth 8 | Set-Content "$d/$($it.code)/results.json"
  }
  $d
}
function Fin($d, $c) { & $fin -RunDir $d -Code $c 2>&1 | Out-String }
function Rec($d, $c) { (Get-Content "$d/$c/finalize.json" -Raw | ConvertFrom-Json).subtasks[0] }
try {
  # NOT_TESTED, no flag anywhere: kept open, the reason printed
  $a = New-Run 'A' $null @(@{ code = 'A1'; task = 'T1'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
  $o = Fin $a 'A1'
  Expect 'NOT_TESTED keeps the task open' (-not (Rec $a 'A1').closed)
  Expect 'the summary says why' ($o -match 'kept open: 1 check\(s\) not tested')
  # closeWithNotTested: both items close, one [Test] task under the parent, renamed to the total
  $b = New-Run 'B' $true @(@{ code = 'B1'; task = 'T2'; checks = , @('C1', 'NOT_TESTED') }, @{ code = 'B2'; task = 'T3'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED'), @('C3', 'NOT_TESTED')) })
  $null = Fin $b 'B1'; $null = Fin $b 'B2'
  $u = Get-Content "$b/untested.json" -Raw | ConvertFrom-Json; $t = Get-Content (Join-Path $store "$($u.id).json") -Raw | ConvertFrom-Json
  Expect 'one [Test] task for the run' (@(Get-ChildItem $store -Filter 'LOCAL-*.json' | Where-Object { (Get-Content $_.FullName -Raw) -match '\[Test\]' }).Count -eq 1)
  Expect '[Test] task named with the total' ($t.name -eq '[Test] Run B — untested checks (3)')
  Expect '[Test] task under the parent, both tasks listed' ($t.parent -eq 'P1' -and $t.description -match 'Task T2' -and $t.description -match 'Task T3')
  Expect 'both tasks closed' ((Rec $b 'B1').closed -and (Rec $b 'B2').closed)
  # OUT_OF_SCOPE never keeps a task open
  $c = New-Run 'C' $null @(@{ code = 'C1'; task = 'T4'; checks = @(@('C1', 'PASS'), @('C2', 'OUT_OF_SCOPE')) })
  $null = Fin $c 'C1'
  Expect 'OUT_OF_SCOPE closes' ((Rec $c 'C1').closed -and (Rec $c 'C1').outOfScope -eq 1)
  Expect 'report counts it' ((Get-Content "$c/C1/report.md" -Raw) -match 'OUT OF SCOPE 1')
  # re-run after the flag is switched on: closes, files the [Test] task, no second results comment
  $r = Get-Content "$a/run.json" -Raw | ConvertFrom-Json; $r.tracker | Add-Member closeWithNotTested $true -Force; $r | ConvertTo-Json -Depth 8 | Set-Content "$a/run.json"
  $null = Fin $a 'A1'
  Expect 're-run closes with a [Test] task' ((Rec $a 'A1').closed -and (Rec $a 'A1').untested)
  Expect 'one results comment' (@((Get-Content (Join-Path $store 'T1.json') -Raw | ConvertFrom-Json).comments | Where-Object { $_.text -match 'Test results' }).Count -eq 1)
  # an unknown verdict renders instead of failing the publish
  $e = New-Run 'E' $null @(@{ code = 'E1'; task = 'T5'; checks = , @('C1', 'PASSED') })
  $o = Fin $e 'E1'
  Expect 'unknown verdict still publishes' (Test-Path "$e/E1/report.md")
  # a second subtask no check names stays open (0 of 0 is not a pass); a dups entry shares the primary's checks
  $f = New-Run 'F' $null @(@{ code = 'F1'; task = 'T6'; checks = , @('C1', 'PASS') })
  $r = Get-Content "$f/run.json" -Raw | ConvertFrom-Json; $r.items[0].subtasks = @($r.items[0].subtasks) + @([pscustomobject]@{ id = 'T7'; name = 'Task T7' }); $r | ConvertTo-Json -Depth 8 | Set-Content "$f/run.json"
  $null = Fin $f 'F1'; $s = (Get-Content "$f/F1/finalize.json" -Raw | ConvertFrom-Json).subtasks
  Expect 'untagged subtask kept open' ((@($s | Where-Object id -eq 'T6')[0]).closed -and -not (@($s | Where-Object id -eq 'T7')[0]).closed)
  $g = New-Run 'G' $null @(@{ code = 'G1'; task = 'T8'; checks = , @('C1', 'PASS') })
  $r = Get-Content "$g/run.json" -Raw | ConvertFrom-Json; $r.items[0].subtasks = @($r.items[0].subtasks) + @([pscustomobject]@{ id = 'T9'; name = 'Task T9' }); $r.items[0] | Add-Member dups ([pscustomobject]@{ T9 = 'T8' }); $r | ConvertTo-Json -Depth 8 | Set-Content "$g/run.json"
  $null = Fin $g 'G1'
  Expect 'dups subtask closes with its primary' (@((Get-Content "$g/G1/finalize.json" -Raw | ConvertFrom-Json).subtasks | Where-Object { $_.closed }).Count -eq 2)
  # closeWithNotTested written as the string "false" stays off
  $h = New-Run 'H' 'false' @(@{ code = 'H1'; task = 'T10'; checks = , @('C1', 'NOT_TESTED') })
  $null = Fin $h 'H1'
  Expect 'closeWithNotTested "false" keeps it open' (-not (Rec $h 'H1').closed)
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$fails failure(s)"; exit [int]($fails -gt 0)
