#Requires -Version 7
<#
wt-pool-2.tests.ps1: agents after board leave / handoff (wt-pool.tests.ps1 is at its cap): lease waits (Remove-KitPoolWaits,
Test-KitPoolWaiterGone, the wait loop exits), messages to a left id (Resolve-KitMsgTarget) and the inbox on wt / check / checkpoint;
e2e lane portFiles (Use- / Restore-KitLanePortFiles); a slot leased to another agent (Get-KitSlotForeign).
Usage: pwsh -NoProfile -File <kit>/tests/wt-pool-2.tests.ps1 (or tests/kit-tests.ps1 -Area wt-pool-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit pool2
# coordinator 2026-11-25: a handed-off agent's wt lease kept waiting (an orphan pwsh refreshed wait/<agent>-<repo>.json); its successor queued behind it
$owTest = Invoke-PsTest pool-orphan-wait @"
. '$k/skills/crafty/lib.ps1'; `$wd = Join-Path (Get-KitPath wt-slots -Create) 'wait'; New-Item -ItemType Directory -Force `$wd | Out-Null; `$bd = Get-KitPath board -Create
`$t0 = (Get-Date).AddMinutes(-5).ToString('o'); `$t1 = (Get-Date).ToString('o')
@{ agent = 'devQ'; repo = 'app'; since = `$t0; token = 'x' } | ConvertTo-Json | Set-Content (Join-Path `$wd 'devQ-app.json'); @{ agent = 'devR'; repo = 'app'; since = `$t0 } | ConvertTo-Json | Set-Content (Join-Path `$wd 'devR-app.json')
"removed:`$((Remove-KitPoolWaits devQ) -join ',') kept:`$(Test-Path (Join-Path `$wd 'devR-app.json'))"
"never-joined:`$(Test-KitPoolWaiterGone devZ `$t0)"
@{ agent = 'devQ'; status = 'left'; beat = `$t1 } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devQ-1.json'); "left-after:`$(Test-KitPoolWaiterGone devQ `$t0)"
"left-before:`$(Test-KitPoolWaiterGone devQ (Get-Date).AddMinutes(1).ToString('o'))"
@{ agent = 'devQ'; status = 'active'; beat = `$t1 } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devQ-2.json'); "successor-live:`$(Test-KitPoolWaiterGone devQ `$t0)"
"@
$owOut = $owTest -join ' '
Expect "pool: board leave removes only the leaving agent's queued waits; a waiter stops once its agent left after the wait began, never for one that never joined, left before it, or has a live successor row ($owOut)" ($owOut -match 'removed:devQ-app kept:True' -and $owOut -match 'never-joined:False' -and $owOut -match 'left-after:True' -and $owOut -match 'left-before:False' -and $owOut -match 'successor-live:False')
$lsrc = Get-Content (Join-Path $k 'skills/crafty/adapters/wt-pool.ps1') -Raw; $bsrc = Get-Content (Join-Path $k 'skills/bossy/bossy.ps1') -Raw
Expect "pool: the lease wait loop exits on a removed / replaced wait file or a gone agent, and its finally keeps a newer waiter's file; board leave calls Remove-KitPoolWaits" ($lsrc -match 'if \(-not \(& \$ownWait\)\) \{ throw' -and $lsrc -match 'if \(-not \(& \$ownWait\)\) \{ return \$null \}' -and $lsrc -match 'Test-KitPoolWaiterGone \$Agent \$since' -and $lsrc -match 'finally \{ if \(& \$ownWait\)' -and $bsrc -match 'Remove-KitPoolWaits \$script:leftEntry\.agent')
# coordinator 2026-11-25: 9 TASK CLOCK nudges to a workflow agent's left id never arrived: a msg goes to the live row of the same run,
# area and type; the agent's next wt / check / checkpoint call prints its unread messages (stderr)
$mbTest = Invoke-PsTest board-msg-left @"
. '$k/skills/crafty/lib.ps1'; `$bd = Get-KitPath board -Create; `$now = (Get-Date).ToString('o')
@{ agent = 'devy-old'; type = 'devy'; run = 'r1'; area = 'a1'; status = 'left'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-old-1.json')
@{ agent = 'devy-90'; type = 'devy'; run = 'r1'; area = 'a1'; status = 'step 4'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-90-1.json')
@{ agent = 'devy-lone'; type = 'devy'; run = 'r2'; area = 'a2'; status = 'left'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-lone-1.json')
Send-BoardMsg 'supervise' 'devy-old' 'TASK CLOCK: open the MR'; Send-BoardMsg 'supervise' 'devy-lone' 'kept'
"to:`$script:KitMsgTo new:`$(Test-Path (Get-InboxFile 'devy-90')) lone:`$(Test-Path (Get-InboxFile 'devy-lone'))"
Show-KitVerbInbox @('release', '-Agent', 'devy-90'); `$env:KIT_AGENT = 'coordinator'; Show-KitVerbInbox @('lease', '-Agent', 'devy-90'); Remove-Item Env:KIT_AGENT
Show-KitVerbInbox @('lease', '-Repo', 'x', '-Agent', 'devy-90'); Show-KitVerbInbox @('lease', '-Agent', 'devy-90'); Show-KitVerbInbox @('lease', '-Agent', 'devy-lone')
"@
$mbOut = $mbTest -join ' // '
Expect "board msg: a left id's message goes to the live agent of its run + area (a lone one stays); wt / check / checkpoint print the unread ones once, never a left agent's ($mbOut)" ($mbOut -match 'to:devy-lone new:True lone:True' -and @([regex]::Matches($mbOut, '\[inbox\] MESSAGE for devy-90 \(do what it says\): \d\d:\d\d from supervise: TASK CLOCK: open the MR')).Count -eq 1 -and $mbOut -notmatch 'MESSAGE for devy-lone' -and (Get-Content (Join-Path $k 'skills/crafty/crafty.ps1') -Raw) -match "if \(\`$__verb -in 'wt', 'check', 'checkpoint'\) \{ try \{ Show-KitVerbInbox")
# coordinator 2026-11-26: a successor resumed in its area's slot without leasing it; the old holder's lease ran out and the slot went
# to a third agent while the successor's board row still listed it: a dead holder's slot lease moves to the live row that lists it
$mvTest = Invoke-PsTest pool-slot-claim @"
. '$k/skills/crafty/lib.ps1'; `$bd = Get-KitPath board -Create; `$now = (Get-Date).ToString('o'); `$wtp = Join-Path '$k' 'wt/osprey-app'; `$sf = Get-KitSlotFile 'osprey-app'
`$mk = { @{ slot = 'app·Osprey'; n = 3; path = `$wtp; branch = 'f/x'; agent = 'devy-gone'; holderPid = 999999; holderStart = '2020-01-01T00:00:00Z'; at = `$now; seen = (Get-Date).AddHours(-2).ToString('o') } | ConvertTo-Json | Set-Content `$sf; Read-KitSlotLease `$sf }
@{ agent = 'devy-gone'; status = 'left'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-gone-1.json')
@{ agent = 'devy-quit'; session = 'devy-quit-1'; status = 'left'; beat = `$now; pid = `$PID; pidStart = (Get-KitPidStart `$PID); worktrees = @(`$wtp) } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-quit-1.json')
`$l0 = & `$mk; "left-claim:`$(Update-KitLease `$l0)/`$(`$l0.agent)"
@{ agent = 'devy-next'; session = 'devy-next-1'; run = 'r9'; status = 'step 2'; beat = `$now; pid = `$PID; pidStart = (Get-KitPidStart `$PID); worktrees = @('C:/other', `$wtp.Replace('\', '/')) } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-next-1.json')
`$script:KitJsonMemo = `$null; `$l1 = & `$mk; `$r1 = Update-KitLease `$l1; `$s1 = Read-KitSlotLease `$sf
"live-claim:`$r1/`$(`$l1.agent)/`$(`$s1.agent)/`$(`$s1.session)/`$(`$s1.run)/`$(`$null -eq `$s1.graceMin)/`$(Update-KitLease `$s1)"
`$lg = @(Get-Content (Get-KitLogFile leases) | ForEach-Object { `$_ | ConvertFrom-Json } | Where-Object name -eq 'app·Osprey' | ForEach-Object { "`$(`$_.event):`$(`$_.agent)" }) -join ','
"log:`$lg"; `$lp = & `$mk; Set-KitProp `$lp parked `$true; "parked:`$(Move-KitSlotLease `$lp)"
`$lgr = & `$mk; Set-KitProp `$lgr seen `$now; "grace:`$(Update-KitLease `$lgr)/`$(`$lgr.agent)"
`$lsm = & `$mk; Set-KitProp `$lsm agent 'devy-next'; Set-KitProp `$lsm session 'devy-next-0'; "same-id:`$(Update-KitLease `$lsm)/`$(`$lsm.session)"
"@
$mvOut = $mvTest -join ' '
Expect "pool: a slot lease with no live holder moves to the live agent whose board row lists the slot (saved, logged reclaim + acquire, live after); a left row's claim, a parked slot or a holder still in its grace: never; a successor with the same id and a new session gets it ($mvOut)" ($mvOut -match 'grace:True/devy-gone' -and $mvOut -match 'same-id:True/devy-next-1' -and $mvOut -match 'left-claim:False/devy-gone' -and $mvOut -match 'live-claim:True/devy-next/devy-next/devy-next-1/r9/True/True' -and $mvOut -match 'log:reclaim:devy-gone,acquire:devy-next' -and $mvOut -match 'parked:False')
# coordinator 2026-11-25: an api suite reads its URLs from cypress/data/config.ts (devys hand-edited it): tests.e2e.run[].portFiles
# get the lane's ports for the run and are put back after; a file with its own edits is refused; a killed run is restored first
$pfRepo = Join-Path (Kd) 'pf-repo'; New-Item -ItemType Directory -Force "$pfRepo/cypress/data" | Out-Null; Set-Content "$pfRepo/cypress/data/config.ts" "serverUrl: 'http://localhost:8443'"; Set-Content "$pfRepo/b.ts" "u: 'http://localhost:8443'"; Save-GitRepo $pfRepo base
$pfTest = Invoke-PsTest port-files @"
. '$k/skills/crafty/lib.ps1'; `$fx = { param([string]`$t) `$t -replace ':8443', ':8543' }; `$cf = '$pfRepo/cypress/data/config.ts'
Use-KitLanePortFiles '$pfRepo' @('cypress/data/config.ts', 'gone.ts') `$fx; "run:`$((Get-Content `$cf -Raw).Trim())|mark:`$(Test-Path (Get-KitPortFilesMark '$pfRepo'))"
Use-KitLanePortFiles '$pfRepo' @('cypress/data/config.ts') `$fx; "again:`$((Get-Content `$cf -Raw).Trim())"
Restore-KitLanePortFiles '$pfRepo'; "after:`$((Get-Content `$cf -Raw).Trim())|mark:`$(Test-Path (Get-KitPortFilesMark '$pfRepo'))|clean:`$(-not (git -C '$pfRepo' status --porcelain))"
Set-Content `$cf "serverUrl: 'http://localhost:8443' // mine"; try { Use-KitLanePortFiles '$pfRepo' @('b.ts', 'cypress/data/config.ts') `$fx; 'own:written' } catch { "own:refused|b:`$((Get-Content '$pfRepo/b.ts' -Raw).Trim())" }
"@
$pfOut = $pfTest -join ' // '
Expect "e2e portFiles: lane ports written for the run (a missing file skipped), a second run restores the first, put back after (clean tree); a file with its own edits refused; crafty runs it in try / finally ($pfOut)" ($pfOut -match "run:serverUrl: 'http://localhost:8543'\|mark:True" -and $pfOut -match "again:serverUrl: 'http://localhost:8543'" -and $pfOut -match "after:serverUrl: 'http://localhost:8443'\|mark:False\|clean:True" -and $pfOut -match "own:refused\|b:u: 'http://localhost:8443'" -and (Get-Content (Join-Path $k 'skills/crafty/crafty.ps1') -Raw) -match 'Invoke-KitE2eRuns \$st\.dir \$runs @\(if \(\$ln\) \{ \$recipe\.portFiles \}\)' -and (Get-Content (Join-Path $k 'skills/crafty/adapters/wt-pool.ps1') -Raw) -match '\} finally \{ Restore-KitLanePortFiles \$Dir \}')
# wt new / lease -Scope and devtools.py --scope: a brace glob keeps its commas (reported twice: 'src/{main' and 'test}/**' as two globs)
$bgS = 'src/{main,test}/java/**, docs/**,web/{a,b}/*.ts'; $bgSep = ',(?![^{}]*\})'
$bgP = & { . (Lib) *>$null; @(Split-KitList $bgS -Sep $bgSep) -join '|' }
$bgSrc = @('skills/crafty/crafty.ps1', 'skills/crafty/adapters/wt-pool.ps1' | Where-Object { -not (Get-Content (Join-Path $src $_) -Raw).Contains("Split-KitList `$Scope -Sep '$bgSep'") })
$bgY = & $py -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import devtools as d; g = d.scope_of('', sys.argv[2]); print('|'.join(g) + ' / ' + '|'.join(d.scope_dropped(sys.argv[2], lambda: g + ['x/**'])))" (Join-Path $src 'skills/crafty') $bgS
Expect "scope globs: a brace glob is one glob in wt new / lease -Scope and devtools.py --scope ($bgP ; $bgY ; $($bgSrc -join ','))" ($bgP -eq 'src/{main,test}/java/**|docs/**|web/{a,b}/*.ts' -and "$bgY" -eq "$bgP / x/**" -and -not $bgSrc.Count)
# coordinator 2026-11-26: a round's successor deployed from its old slot after the pool re-leased it (another agent's branch went live
# as its layer): envy deploy, wt commit and wt sync refuse a slot leased to another agent
$sfRepo = Join-Path (Kd) 'sf-repo'; New-Item -ItemType Directory -Force $sfRepo | Out-Null; Set-Content "$sfRepo/a.txt" 'a'; Save-GitRepo $sfRepo base
$sfSlot = Join-Path (Kd) 'heron-sf'; git -C $sfRepo worktree add -q --detach $sfSlot 2>$null | Out-Null
Set-Content (Join-Path "$(git -C $sfSlot rev-parse --absolute-git-dir)" 'claude-slot') '2'
$sfAssert = Join-Path (Kd) 'sf-assert.ps1'; Set-Content $sfAssert ". '$k/skills/crafty/lib.ps1'; Assert-KitSlotOwn '$sfSlot' 'devy-signup' 'commit'; 'passed'"
$sfTest = Invoke-PsTest slot-foreign @"
. '$k/skills/crafty/lib.ps1'; `$sff = Get-KitSlotFile 'heron-sf'
@{ slot = 'sf-Heron'; n = 2; repo = '$sfRepo'; path = '$sfSlot'; branch = 'f/theirs'; agent = 'devy-kyc'; since = '2026-01-02T03:04:05Z' } | ConvertTo-Json | Set-Content `$sff
"other:`$(Get-KitSlotForeign '$sfSlot' 'devy-signup')"; "holder:[`$(Get-KitSlotForeign '$sfSlot' 'devy-kyc')]"; "noid:[`$(Get-KitSlotForeign '$sfSlot' '')]"; "repo:[`$(Get-KitSlotForeign '$sfRepo' 'devy-signup')]"
`$sfa = @(pwsh -NoProfile -File '$sfAssert' 2>&1); "assert:`$LASTEXITCODE|`$(`$sfa -join ' ')"
Remove-Item -LiteralPath `$sff; "free:[`$(Get-KitSlotForeign '$sfSlot' 'devy-signup')]"
"@
$sfOut = $sfTest -join ' // '; $sfCrafty = Get-Content (Join-Path $k 'skills/crafty/crafty.ps1') -Raw; $sfEnvy = Get-Content (Join-Path $src 'skills/envy/envy.ps1') -Raw
Expect "pool: a slot leased to another agent is refused with its holder and the wt lease command; the holder, a free slot, a plain repo or no caller id pass; envy deploy, wt commit and wt sync call it ($sfOut)" ($sfOut -match 'other:\S+ is pool slot sf-Heron, leased to devy-kyc \(no live holder yet\) on f/theirs since .+wt lease -Repo sf-repo -Branch <your branch> -Agent devy-signup' -and $sfOut -match 'holder:\[\]' -and $sfOut -match 'noid:\[\]' -and $sfOut -match 'repo:\[\]' -and $sfOut -match 'free:\[\]' -and $sfOut -match 'assert:1\|commit refused: \S+ is pool slot sf-Heron' -and $sfOut -notmatch 'passed' -and $sfCrafty -match "Assert-KitSlotOwn \`$Dir \`$Agent 'wt sync'" -and $sfCrafty -match "Assert-KitSlotOwn \`$Dir \`$Agent 'commit'" -and $sfEnvy -match 'Assert-KitSlotOwn \$dd \$Agent "envy\.ps1: \[\$e\] deploy"')
Remove-TestKit $k
Complete-Tests
