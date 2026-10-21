#Requires -Version 7
<#
orch.tests.ps1: orch.ps1 track, decide, launch, board, supervise, learn, budget, setup (extras: deploys, kit-admin, supervise-resources).
Usage: pwsh -NoProfile -File <kit>/tests/orch.tests.ps1 (or tests/kit-tests.ps1 -Area orch).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit orch; $O = Join-Path $k 'skills/orchestrate/orch.ps1'; $tf = Join-Path $k '.state/tracking.json'
foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
$KP = Join-Path $k 'skills/orchestrate/orch.ps1'
$null = pwsh @np $KP --help; $h0 = $LASTEXITCODE; $null = pwsh @np $KP bogus-verb; $h2 = $LASTEXITCODE
$mk = Join-Path (Kd) 'kit main'; New-Item -ItemType Directory -Force "$mk/skills/dev-kit", "$mk/skills/orchestrate" | Out-Null
Copy-Item (Join-Path $k 'skills/dev-kit/lib.ps1'), (Join-Path $k 'skills/dev-kit/kit.example.json') "$mk/skills/dev-kit/"; Copy-Item $KP "$mk/skills/orchestrate/"
'readme' | Set-Content "$mk/README.md"
git -C $mk init -q; git -C $mk add -A; git -C $mk -c user.name=t -c user.email=t@t commit -q -m init
& $J @{ localOnly = @('secret.txt') } "$mk/skills/dev-kit/kit.local.json"
$lw = Join-Path (Kd) 'kit wt'; git -C $mk worktree add -q --detach $lw 2>$null
'edited' | Set-Content "$lw/README.md"
$kx = (pwsh @np "$lw/skills/orchestrate/orch.ps1" setup -Exclude 2>&1 | Out-String)
Expect 'orch.ps1: --help 0, bad verb 2; worktree: excludes to main clone, no memory' ($h0 -eq 0 -and $h2 -eq 2 -and
  (Get-Content "$mk/.git/info/exclude" -Raw) -match '/secret\.txt' -and $kx -match 'linked kit worktree' -and -not (Test-Path "$lw/memory"))
$env:KIT_TRACKER_TYPE = 'clickup'   # tag CU- (the type alone: no clickup call, so the extra tracker-clickup is not needed)
$out = pwsh @np $O track add -Task 0 -Mrs 'web!1' 2>&1 | Out-String
Expect "track: placeholder task '0' refused" ($LASTEXITCODE -ne 0 -and $out -match 'needs a real -Task id')
$out = pwsh @np $O track add -Task 'CU-abc123' -Mrs 'web!1,web!2' -MergeAfter 'web!2>api!7' 2>&1 | Out-String
$tasks = (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks
Expect 'track: tag stripped, merge order echoed' ($tasks.ContainsKey('abc123') -and $out -match 'merge-after: web!2>api!7')
$null = pwsh @np $O track add -Task zero1 2>&1; $zr = pwsh @np $O track run -Detail 2>&1 | Out-String
Expect 'track run: a task with 0 MRs is held, never promoted' (-not (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks.zero1.done -and $zr -match 'HOLD zero1: no MR')
$saved = $env:CLAUDE_CODE_SESSION_ID; Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue
$ow = @(1, 2 | ForEach-Object { pwsh -NoProfile -Command ". '$O'; Get-SuperviseOwner ''" })
$env:CLAUDE_CODE_SESSION_ID = 's1'; $os = pwsh -NoProfile -Command ". '$O'; Get-SuperviseOwner ''"; Remove-Item Env:CLAUDE_CODE_SESSION_ID; if ($saved) { $env:CLAUDE_CODE_SESSION_ID = $saved }
Expect 'supervise: without -Session the lock owner is the session, the same every round (no step-aside from itself)' ($ow[0] -and $ow[0] -eq $ow[1] -and $ow[0] -notmatch '^pid' -and $os -eq 's1')
$tb = pwsh -NoProfile -Command ". '$O'; `$KitConf.TrackerTag = 'CU-'; `$KitConf.TrackerRepos = @('web'); `$KitConf.GitlabGroup = 'g'; function Invoke-HostApi(`$p) { if (`$p -match 'search=') { @{ iid = 5; state = 'merged' } } elseif (`$p -match 'merge_requests/5$') { @{ target_branch = 'rel/x' } } }; Get-TaskMrBranches 'abc', '' | ForEach-Object { `"`$(`$_.ref) `$(`$_.repo)@`$(`$_.branch)`" }"
Expect "bugbrief: the original task's MRs give repo@target" ($tb -eq 'web!5 web@rel/x')
Remove-Item Env:KIT_TRACKER_TYPE
$cf =Join-Path (Kd) 'brief.contracts.md'; '# contracts' | Set-Content $cf
$out = pwsh @np $O decide ask -Run w1 -Agent X1 -Item A2 -Question 'Keep the old total?' -Options 'A: keep','B: recompute' -Recommend A -Contracts $cf | Out-String
$id = if ($out -match 'DECISION (\S+) pending') { $Matches[1] }
$pend = @(pwsh @np $O decide list -Pending -Json | ConvertFrom-Json)
Expect 'decide ask: pending + contracts note' ($id -and $pend.Count -eq 1 -and (Get-Content $cf -Raw) -match "DECISION NEEDED $id")
$null = pwsh @np $O decide answer -Id $id -Answer 'A, keep it'
$w = pwsh @np $O decide wait -Id $id -MaxMinutes 1 | Out-String
Expect 'decide answer: wait returns it, contracts carry it, none pending' ($w -match 'ANSWERED' -and $w -match 'keep it' -and (Get-Content $cf -Raw) -match "$id ANSWERED" -and -not @(pwsh @np $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_ }).Count)
$out = pwsh @np $O decide ask -Kind envfix -Run w1 -Agent X1 -Item A3 -Question 'refresh the release' -Contracts $cf | Out-String
$eid = if ($out -match 'ENV-FIX (e-\S+) pending') { $Matches[1] }
$pend = @(Px $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_ })
$null = Px $O decide answer -Id $eid -By coordinator -Answer 'done: refreshed'
$w = Px $O decide wait -Id $eid -MaxMinutes 1 | Out-String
Expect 'decide envfix: pending for the coordinator, contracts note, answer returned' ($eid -and $pend.Count -eq 1 -and $pend[0].kind -eq 'envfix' -and (Get-Content $cf -Raw) -match "ENV-FIX NEEDED $eid" -and $w -match 'done: refreshed')
$i1, $i2 = 'A1', 'A2' | ForEach-Object { (Px $O decide ask -Run w1 -Agent X9 -Item $_ -Question "q$_" -Options 'A: a','B: b' | Out-String) -replace '(?s).*DECISION (\S+) pending.*', '$1' }
$null = Px $O board check -Session s1 2>&1; $bc = $LASTEXITCODE
$hp = Px (Join-Path $k 'skills/orchestrate/orch.ps1') setup --help 2>&1 | Out-String; $hc = $LASTEXITCODE
Expect 'decide ids unique within a second; board check without -Worktree exit 2; orch.ps1 setup --help prints usage, exit 0' ($i1 -ne $i2 -and $bc -eq 2 -and $hc -eq 0 -and $hp -match 'coordinator \+ kit commands' -and $hp -notmatch 'setup:')
$dx2 = Px $O deploy plan 2>&1 | Out-String; $dxc = $LASTEXITCODE
$pp = Px $O precommit 2>&1 | Out-String; $ppc = $LASTEXITCODE
Expect 'deploy / precommit without their extra (deploys, kit-admin): its one line, exit 1' ($ppc -eq 1 -and $pp.Trim() -eq 'orch.ps1 precommit is an extra: run kittool.py extra add kit-admin' -and $dxc -eq 1 -and $dx2.Trim() -eq 'orch.ps1 deploy is an extra: run kittool.py extra add deploys')
$ld = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath launches }; New-Item -ItemType Directory -Force $ld | Out-Null
$full = '{"brief":"C:/b/wave-x.md","agents":[{"id":"X1","items":"A1"}],"mandate":["do it"]}'
$af = Join-Path (Kd) 'args.json'; [IO.File]::WriteAllText($af, $full)
$h = & { . $O; Get-KitFnv $full }
$bad = pwsh @np $O launch -Self -Script buildy.js -Run wave-x -ArgsFile $af -Fnv 00000000 | Out-String; $badCode = $LASTEXITCODE
$ok = pwsh @np $O launch -Self -Script buildy.js -Run wave-x -ArgsFile $af -Fnv $h | Out-String
Expect 'launch -Self: wrong hash MISMATCH (exit 1), right one RECORDED' ($badCode -eq 1 -and $bad -match 'MISMATCH' -and $ok -match 'RECORDED')
$null = pwsh @np $O launch -RunId wf_t1 -Script (Join-Path $k 'workflows/buildy.js') -ArgsJson '{"brief":"C:/b/wave-x.md"}' 2>&1
$rj = Get-Content (Join-Path $ld 'wf_t1.json') -Raw | ConvertFrom-Json; $rj.holderPid = 999999; & $J $rj (Join-Path $ld 'wf_t1.json') 10   # its session is gone
$l = pwsh @np $O launch -List -Brief | Out-String
$rc = pwsh @np $O recover | Out-String
Expect 'launch -List / recover: stopped run resumes with exact args' ($l -match 'wf_t1' -and $l -match 'self-buildy-wave-x' -and $rc -match "resumeFromRunId: 'wf_t1'" -and $rc -match 'written by the workflow: exact' -and (Test-Path (Join-Path $ld 'wf_t1.resume.md')))
Expect 'recover: RESUME line has the recorded args byte for byte' ($rc.Contains("resumeFromRunId: 'wf_t1', args: $full })"))
$sa = '{"select":{"statuses":["inTest"]},"target":"stg","kitDir":"C:/k"}'; $saf = Join-Path (Kd) 'args-sel.json'; [IO.File]::WriteAllText($saf, $sa)
$null = pwsh @np $O launch -Self -Script testy.js -Run select-stg -ArgsFile $saf -Fnv (& { . $O; Get-KitFnv $sa }) -RunDir 'C:/rt/qa-runs/d-stg'
$sr = Get-ChildItem $ld -Filter 'self-testy-select-stg-*.json' | Get-Content -Raw | ConvertFrom-Json
Expect 'launch -Self testy: original args + runDir as extra field' ($sr.argsRaw -eq $sa -and $sr.runDir -eq 'C:/rt/qa-runs/d-stg' -and -not $sr.args.runDir -and (& { . $O; Get-LaunchRunName ($sa | ConvertFrom-Json) }) -eq 'select-stg')
$sf = Get-ChildItem $ld -Filter 'self-testy-select-stg-*.json' | Select-Object -First 1
$sr | Add-Member -Force holderPid 999999; & $J $sr $sf.FullName 10   # its session is gone
$sl0 = pwsh @np $O launch -List -Brief | Out-String
$dn = pwsh @np $O launch -Done -Run select-stg 2>&1 | Out-String; $sl1 = pwsh @np $O launch -List -Brief | Out-String
Expect 'launch -Done -Run: a completed self record (owner-stopped run) is no stopped run' ($sl0 -match 'select-stg' -and $dn -match 'marked completed: self-testy' -and $sl1 -notmatch 'select-stg')
# orch batch 2: board TAKEOVER under lock; self records per args hash; promotion hold; passed statuses
# never re-applied; "All MRs merged" once; supervise step-aside;
# LESSONS.md lock freed on a failed -Bump; top-level --help; MergedTip on a submodule
$bwt = Join-Path (Kd) 'bwt'
$j1 = pwsh @np $O board join -Agent BX -Run rb -Claims $bwt | Out-String; $s1 = if ($j1 -match 'SESSION (\S+)') { $Matches[1] }
$j2 = pwsh @np $O board join -Agent BX -Run rb -Claims $bwt -Resume | Out-String
$bt = pwsh @np $O board beat -Session $s1 | Out-String; $btc = $LASTEXITCODE
$bd = TkPath $k board
Expect 'board: beat after TAKEOVER exit 1, no lock left' ($j2 -match 'TAKEOVER' -and $btc -eq 1 -and $bt -match 'TAKEN OVER' -and -not @(Get-ChildItem $bd -Filter '*.lock').Count)
$lv = pwsh @np $O board leave -Session no-such-s -Handoff x.md | Out-String
Expect 'board leave: an unknown session exits 1, records no handoff' ($LASTEXITCODE -eq 1 -and $lv -match 'unknown session')
$a2 = '{"brief":"C:/b/wave-y.md","agents":[{"id":"Y1","items":"B1"}]}'; $af2 = Join-Path (Kd) 'args2.json'; [IO.File]::WriteAllText($af2, $a2)
$h2 = & { . $O; Get-KitFnv $a2 }
$null = pwsh @np $O launch -Self -Script buildy.js -Run wave-x -ArgsFile $af2 -Fnv $h2
Expect 'launch -Self: 2 launches, one run name: 2 records' (@(Get-ChildItem $ld -Filter 'self-buildy-wave-x-*.json').Count -eq 2)
'{"kitDir":"C:/k","runDir":"C:/r"}' | Set-Content (Join-Path $ld 'args-testy-r.json'); '{"script":"","at":"bad"}' | Set-Content (Join-Path $ld 'broken.json')
$ll = pwsh @np $O launch -List 2>&1 | Out-String; $cl = pwsh @np $O cleanup -IfDue -Quiet 2>&1 | Out-String; $clc = $LASTEXITCODE
Expect 'launch records: args dumps / broken records skipped; -List points to recover; SessionStart hook shows no error' ($ll -notmatch 'Exception|Cannot bind' -and $ll.TrimEnd() -match 'resume calls, resume briefs, finalize lines: orch.ps1 recover$' -and $cl -notmatch 'Exception|Cannot bind' -and $clc -eq 0)
$rn = & { . $O; Get-LaunchRunName ([pscustomobject]@{ brief = 'C:/b/wave-x.md' }) }
Expect 'launch: a brief-named run + 4 hex of the brief path' ($rn -match '^wave-x-[0-9a-f]{4}$')
$tt = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$global:sets = @(); $global:cmts = @()
$global:q = 0; function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$NoMemo) { if ($Path -match 'search=') { $global:q++ }; [pscustomobject]@{ state = 'merged' } }
function Get-TrackerTask($id) { [pscustomobject]@{ status = 'promoted'; subtasks = @() } }
function Set-TrackerStatus($id, $s) { $global:sets += "$id=$s" }
function Add-TrackerComment($id, $text) { $global:cmts += [pscustomobject]@{ id = $id; text = $text } }
function Get-TrackerComments($id) { @($global:cmts | Where-Object { $_.id -eq $id }) }
function Start-Process { }   # no background cleanup from a test
$null = Invoke-Track add -Task t5 -Mrs 'g/web!9' -OnMerged 'review,promoted'
$null = Invoke-Track run -Detail
Update-KitTracking { param($t) $t.tasks['t5'].done = $false }
$null = Invoke-Track run -Detail
"skip:$(-not @($global:sets | Where-Object { $_ -like 't5=*' }).Count)"
"once:$(@($global:cmts | Where-Object { $_.id -eq 't5' -and $_.text -match '^All MRs merged' }).Count -eq 1)"
$h = Invoke-Track add -Task t6 -Mrs 'g/web!8' -HoldPromotion 'deferred A2' | Out-String
$r1 = Invoke-Track run -Detail | Out-String
$c1 = @($global:cmts | Where-Object id -eq 't6').Count
$null = Invoke-Track add -Task t6 -HoldPromotion ''
$null = Invoke-Track run -Detail
"hold:$($h -match 'promotion HELD' -and $r1 -match 'HOLD t6: promotion held' -and $c1 -eq 0 -and @($global:cmts | Where-Object id -eq 't6').Count -eq 1)"
$KitConf.TrackerRepos = @('g/web'); $KitConf.TrackerTag = 'CU-'; $null = Invoke-Track add -Task t7 -Discover -Mrs 'g/web!7'; $global:q = 0
$null = Invoke-Track run; $q1 = $global:q; $null = Invoke-Track run
"throttle:$($q1 -ge 1 -and $global:q -eq $q1 -and (Read-KitTracking).tasks['t7'].checkedAt)"
function Get-TrackerTask($id) { if ($id -eq 't8') { Update-KitTracking { param($t) $t.tasks['t8'].holdPromotion = 'late' } }; [pscustomobject]@{ status = 'promoted'; subtasks = @() } }   # a hold added mid-run
$null = Invoke-Track add -Task t8 -Mrs 'g/web!6'; $null = Invoke-Track run
"keep:$((Read-KitTracking).tasks['t8'].holdPromotion -eq 'late')"
'@
$res = Invoke-PsTest 'track-test' $tt @($O)
Expect-Each $res 'track: # (throttle: the MR search once per 30 min, tasks rotate by checkedAt; keep: a hold added mid-run survives)' @('skip', 'once', 'hold', 'throttle', 'keep') 8
$lkf = Join-Path (TkPath $k cache -Create) 'supervise.lock'
Set-JsonFile $lkf @{ session = 'other'; at = (Get-Date).ToString('s'); pid = 1 }
$sv = pwsh @np $O supervise -Brief -Session me | Out-String
Expect 'supervise: another session''s fresh lock -> steps aside, lock file kept, no .lock left' ($sv -match 'steps aside' -and (Get-Content $lkf -Raw) -match 'other' -and -not (Test-Path "$lkf.lock"))
$dp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden; $dp.WaitForExit()
$gb = Join-Path (TkPath $k board -Create) 'gone-s.json'; Set-JsonFile $gb @{ session = 'gone-s'; agent = 'X9'; run = 'r1'; status = 'working'; beat = (Get-Date).ToString('o'); joined = (Get-Date).ToString('o'); holderPid = $dp.Id }
$ad = New-Item -ItemType Directory -Force (Join-Path $k 'skills/orchestrate/adapters')
'function Get-KitSuperviseFlagsFake([switch]$AutoFix) { "fake line $AutoFix $($null -ne $now -and $null -ne $mem -and $null -ne $keepFree)"; [pscustomobject]@{ ramNeed = 9999 }; [pscustomobject]@{ level = "WATCH"; what = "fake flag"; action = "x" }; [pscustomobject]@{ name = "fake row"; by = "me"; gb = 1 }; [pscustomobject]@{ info = "fake info" } }' | Set-Content (Join-Path $ad 'fake.ps1')
$sv = pwsh @np $O supervise -AutoFix -Brief -Takeover -Session me 2>&1 | Out-String
$sr = Get-Content (TkPath $k supervise-report) -Raw
Expect 'supervise -AutoFix -Takeover: a gone session''s board entry is marked left (no "not recognized")' ((Get-Content $gb -Raw | ConvertFrom-Json).status -eq 'left' -and $sv -notmatch 'not recognized'); Remove-Item $gb
Expect 'supervise: an extra''s hook sees the sweep''s variables, adds a sweep line, a flag, a report row, an owner line, a RAM need' ($sr -match 'fake line True True' -and $sr -match 'RAM: .* largest waiting build 9999 GB.*Free the biggest: fake row 1 GB' -and $sr -match '\*\*WATCH\*\* fake flag' -and $sr -match '\| fake row \| me \| 1 \|' -and $sr -match '\*\*INFO\*\* fake info'); Remove-Item $ad -Recurse -Force
$lt = Join-Path (Kd) 'lk.json'; '' | Set-Content "$lt.lock"; (Get-Item "$lt.lock").LastWriteTime = (Get-Date).AddMinutes(-5); $fs = [IO.File]::Open("$lt.lock", 'Open', 'Write', 'None')
$lj = Start-ThreadJob { Start-Sleep -Milliseconds 1500; ($using:fs).Dispose(); Remove-Item "$using:lt.lock" }
$lw = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); try { Invoke-KitLocked $lt { 'got' } } catch { "threw: $_" } }; $null = $lj | Wait-Job
Expect 'Invoke-KitLocked: an old lock still held open waits for its holder, never fails fast' ($lw -eq 'got')
$hlp = pwsh @np $O --help | Out-String; $hc2 = $LASTEXITCODE; $null = pwsh @np $O nope; $nc = $LASTEXITCODE
Expect 'orch.ps1 --help: header only, exit 0; bad verb exit 2' ($hc2 -eq 0 -and $hlp -match '^\s*orch\.ps1: the coordinator' -and $hlp -notmatch '__verb|#>' -and $nc -eq 2)
$sm = Join-Path (Kd) 'subm'; New-Item -ItemType Directory -Force $sm | Out-Null
git init -q "$sm/sub"; git -C "$sm/sub" commit -q --allow-empty -m s; git init -q "$sm/super"; git -C "$sm/super" commit -q --allow-empty -m s
git -C "$sm/super" -c protocol.file.allow=always submodule add -q "$sm/sub" m 2>$null; git -C "$sm/super/m" remote set-url origin 'https://git.example.com/g/subrepo.git'
git -C "$sm/super" remote add origin 'https://git.example.com/g/superrepo.git'
$gd = "$(git -C "$sm/super/m" rev-parse --path-format=absolute --git-common-dir)".Trim()
$mt = & { . $O; $fa = (Get-Command Invoke-Cleanup).ScriptBlock.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'MergedTip' }, $true) | Select-Object -First 1; . ([scriptblock]::Create($fa.Extent.Text)); $global:seen = @(); function Invoke-HostVerb([string]$Verb, [hashtable]$A) { $global:seen += $A.repo; @() }; $null = MergedTip $gd 'f/x'; $global:seen -join ' ' }
Expect 'cleanup: MergedTip on a submodule''s git dir asks the submodule''s project, not the superproject' ($mt -match 'g/subrepo' -and $mt -notmatch 'superrepo')
$sd = TkPath $k sessions -Create; foreach ($n in 'tabs-t__u.json', 'old-login.json') { $p = Join-Path $sd $n; '{}' | Set-Content $p; (Get-Item $p).LastWriteTime = (Get-Date).AddHours(-9) }
$cd = pwsh @np $O cleanup -DryRun -WorktreeRoot (Join-Path (Kd) 'no-wt') 2>&1 | Out-String
Expect 'cleanup: an 8 h session sweep keeps tab registries (live browsers own them)' ($cd -match 'old-login\.json' -and $cd -notmatch 'tabs-t__u')
$nt = @'
. $args[0]
$env:KIT_NET_TRIES = '1'   # a tracker whose CLI fails as $global:trFails says: network, then fine, then a real error
Register-KitAdapter 'tracker' 'fake' @{ status = { param($a) if ($global:trFails) { throw $global:trFails }; 'ok' } }; Initialize-KitTracker -Type fake
$global:trFails = 'dial tcp: lookup api.example: no such host'
$q = Set-TrackerStatus 'o/r#9' 'inTest' 3>$null; "queued:$("$q" -match '^QUEUED' -and (Test-Path (Get-KitPath outbox)))"
$global:trFails = ''
$s = @(Invoke-KitOutbox); "sent:$("$s" -match '^SENT status o/r#9' -and -not (Test-Path (Get-KitPath outbox)))"
$global:trFails = 'no issue 9 in o/r (HTTP 404)'
try { $null = Set-TrackerStatus 'o/r#9' 'inTest'; 'real:False' } catch { "real:$(-not (Test-Path (Get-KitPath outbox)))" }
'@
$res = Invoke-PsTest 'outbox-test' $nt @(Join-Path $k 'skills/dev-kit/lib.ps1')
Expect-Each $res 'outbox: #' @('queued', 'sent', 'real')
& $J @{} (Join-Path $k 'skills/dev-kit/kit.local.json')   # a configured kit: lib.ps1 skips its load-time git lookup
"`n## zz-test`n- a core lesson" | Add-Content (Join-Path $k 'LESSONS.md')
$lr = Invoke-TestScript $O learn -Skill revy -Kind idea -Text 'x'; $r1 = pwsh @np $O learn -Read -Skill zz-test | Out-String; $lx = Invoke-TestScript $O learn -Skill revy -Lesson 'y'
Expect 'learn: record + -Read in core; lesson tools without kit-admin = its one line, exit 1' ($lr.out -match 'recorded \(revy/idea\)' -and $r1 -match 'a core lesson' -and $lx.code -eq 1 -and $lx.out.Trim() -eq 'learn -Stats / -History / -Lesson / -Bump / -Fixed / -Trim is an extra: run kittool.py extra add kit-admin')
$j1 = pwsh @np $O board join -Type devy -Agent X7 -Run w7 -Items 'A1' -Claims 'C:/wt/x7' | Out-String
$j2 = pwsh @np $O board join -Type revy -Agent R7 -Run w7 | Out-String
$null = pwsh @np $O board msg -Agent R7 -To X7 -Text 'I need a.ts'
$ib = pwsh @np $O board inbox -Agent X7 | Out-String
Expect 'board: join -Type shown; msg in inbox' ($j2 -match 'X7\s+devy' -and $ib -match 'from R7: I need a\.ts')
$dx = Invoke-TestScript $O board dispute -Agent X7 -With R7
$ad = Join-Path $k 'skills/orchestrate/adapters'; New-Item -ItemType Directory -Force $ad | Out-Null
'function Invoke-TrackRebuild { "fake rebuild $Force" }' | Set-Content (Join-Path $ad 'fake.ps1'); 'this is { not powershell' | Set-Content (Join-Path $ad 'broken.ps1')
$ld = Invoke-TestScript $O track -Rebuild -Force; Remove-Item $ad -Recurse -Force
Expect 'extras: a missing one = its one line, exit 1; an adapter file loads (sees its caller''s params); a broken one only warns' ($dx.code -eq 1 -and $dx.out.Trim() -eq 'board dispute is an extra: run kittool.py extra add board-disputes' -and $ld.code -eq 0 -and $ld.out -match 'fake rebuild True' -and $ld.out -match 'adapter broken\.ps1')
$bj = { param([string[]]$a) Px $O budget @a -Json | ConvertFrom-Json }
$cx = Join-Path (Kd) 'codex'; New-Item -ItemType Directory -Force $cx | Out-Null
'{"models":[{"slug":"gpt-5.5","context_window":272000,"effective_context_window_percent":95}]}' | Set-Content "$cx/models_cache.json"; 'model = "gpt-5.5"' | Set-Content "$cx/config.toml"
$b1 = & $bj '-Tool', 'claude', '-Model', 'claude-opus-5-5'; $b2 = & $bj '-Tool', 'claude', '-Model', 'claude-sonnet-4-6'; $b5 = & $bj '-Tool', 'unknown'
$env:CODEX_HOME = $cx; $b3 = & $bj '-Tool', 'codex'; "model = ""gpt-5.5""`nmodel_auto_compact_token_limit = 200000" | Set-Content "$cx/config.toml"; $b4 = & $bj '-Tool', 'codex'; Remove-Item Env:CODEX_HOME
$bp = & $bj '-Tool', 'claude', '-Plan', 'devy/claude-opus-5-5:1,revy/claude-sonnet-4-6:1'
Expect "budget: per-tool defaults and the plan cap (sum)" ("$($b1.budget)/$($b1.handoff) $($b2.budget)/$($b2.handoff) $($b3.budget)/$($b3.handoff) $($b4.budget)/$($b4.handoff) $($b5.budget)/$($b5.handoff) $($bp.cap)" -eq '967000/773600 167000/133600 232560/186048 200000/160000 160000/128000 1134000')
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx'; New-Item -ItemType Directory -Force $env:KIT_TRANSCRIPTS | Out-Null
$hj = pwsh @np $O board join -Agent H1 -Run hr -Model claude-opus-5-5 | Out-String; $ht = if ($hj -match 'SESSION (\S+)') { $Matches[1] }
@("{""type"":""user"",""text"":""SESSION $ht""}", '{"message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":799999,"output_tokens":0}}}') | Set-Content (Join-Path $env:KIT_TRANSCRIPTS 'agent-h1.jsonl')
$hb = Px $O board beat -Session $ht | Out-String; $hf = if ($hb -match 'leave -Session \S+ -Handoff (\S+),') { $Matches[1] }
$null = Px $O board leave -Session $ht -Handoff $hf; $hr = Px $O recover | Out-String
$h2 = Px $O board join -Agent H1 -Run hr | Out-String; Remove-Item Env:KIT_TRANSCRIPTS
Expect 'budget: join shows it, a beat at 80% = HANDOFF, recover lists the brief, a fresh join continues' ($hj -match 'budget: claude claude-opus-5-5 967000 tokens, handoff at 773600' -and $hb -match 'HANDOFF: spend 800000 >= 773600' -and $hf -and $hr -match "== HANDOFF H1 \(hr\).*$([regex]::Escape($hf))" -and $h2 -match "CONTINUE: .*$([regex]::Escape($hf))" -and $h2 -notmatch 'DUPLICATE')
$rd = @{ agents = @(@{ type = 'checky'; name = 'W1'; mode = 'test'; spend = 50000; prevSpend = 30000 }, @{ type = 'checky'; name = 'J1'; mode = 'env-fix'; wait = $true }, @{ type = 'devy'; name = 'P1'; mode = 'build'; spend = 10000; prevSpend = 0 })
  mem = @{ TotalGB = 64; AvailGB = 16 }; keepFree = 8; info = @('deploy ready: stage (2 MR(s))'); detailFile = 'r.md'
  resources = @(@{ name = 'rm · api'; by = 'W1'; gb = 3 }, @{ name = 'browser rm·acme·admin'; by = 'W1'; gb = 2 }, @{ name = 'hm · api (down)'; by = 'memory'; gb = 0 })
  flags = @(@{ level = 'WATCH'; what = 'gate: 6 builds queued'; action = 'wait' }, @{ level = 'ACT'; what = 'ENV-FIX e-1 waiting 240 min'; action = 'fix it' }) }
$r1 = (& { . $O; Format-KitReport $rd -Agents }) -join "`n"; $rd.mem.AvailGB = 6; $r2 = (& { . $O; Format-KitReport $rd }) -join "`n"
$want1 = @('| Agent | Doing |', '|---|---|', '| 1 × devy (+10kT) | build 1 (P1) |', '| 2 × checky (+20kT) | waiting: env-fix 1 (J1) · test 1 (W1) |', '',
  '**RAM** 48 / 64 GB used, 16 GB free', '', '| Resource | Used by | RAM |', '|---|---|---|', '| rm · api | W1 | 3 |', '| browser rm·acme·admin | W1 | 2 |', '| hm · api (down) | memory | — |', '',
  '**Flags**', '- **ACT** ENV-FIX e-1 waiting 240 min -> fix it', '- **WATCH** gate: 6 builds queued -> wait', '- **INFO** deploy ready: stage (2 MR(s))') -join "`n"
Expect 'supervise report snapshot (-Agents)' ($r1 -eq $want1)
Expect 'supervise report: below the floor named, no agents by default' ($r2 -match '\*\*RAM\*\* 58 / 64 GB used, 6 GB free \(below the floor 8 GB\)' -and $r2 -notmatch 'Agent')
$an = & { . $O; $c = @{ outbox = 4; toolErrors = 2; errorRun = 'wf1' }
  "$((Get-KitAnomalies $c @{ outbox = 1; toolErrors = 1 }).flags.what -join "`n")`n$((Get-KitAnomalies @{ outbox = 0 } @{}).flags.Count)" }
$want = 'outbox grew to 4', '1 new agent', '\n0$'
Expect "supervise anomalies: every flag from its fixture, none on a quiet round" (-not @($want | Where-Object { $an -notmatch $_ }).Count)
$hr = & { . $O; $n = Get-Date
  $q = @{}; $a = Get-KitSilentRun 'wf1' 60 $q $n; $b = Get-KitSilentRun 'wf1' 61 $q $n; $c = Get-KitSilentRun 'wf2' 3 $q $n; $null = Get-KitSilentRun 'wf1' 2 $q $n; $d = Get-KitSilentRun 'wf1' 50 $q $n
  "$($a.skip -and $a.flag.what -match 'silent 2 days')|$($b.skip -and -not $b.flag)|$(-not $c.skip)|$([bool]$d.flag)" }
Expect 'supervise: a run silent 2+ days is flagged once, then skipped' ($hr -eq 'True|True|True|True')
$jr = & { . $O; $s = @(@{ agentId = 'a1'; label = 'build:X1' }, @{ agentId = 'a2'; label = 'build:X1' }, @{ agentId = 'a3'; label = 'review:X1' }, @{ agentId = 'a4'; label = 'test:Q1@2' }, @{ agentId = 'a5'; label = 'test:Q1' }, @{ agentId = 'a6'; label = 'test:Q1' }); (@(Get-JournalRunning $s @('a3')) | ForEach-Object agentId) -join ',' }
Expect 'journal: running = no result, not superseded by a later finished start of the item or a restart of the label' ($jr -eq 'a4,a6')
Remove-TestKit $k
Complete-Tests
