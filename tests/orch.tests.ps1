#Requires -Version 7
<#
orch.tests.ps1: orch.ps1 deploy, track, decide, launch, board, supervise, learn, budget, setup.
Usage: pwsh -NoProfile -File <kit>/tests/orch.tests.ps1 (or tests/kit-tests.ps1 -Area orch).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit orch; $O = Join-Path $k 'skills/orchestrate/orch.ps1'; $tf = Join-Path $k '.state/tracking.json'
$r = Join-Path (Kd) 'git'; New-Item -ItemType Directory -Force "$r/outer/inner" | Out-Null
$env:CLAUDE_WT_ROOT = "$r/wt"; foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
try {
  git init -q --bare "$r/origin.git"; git clone -q "$r/origin.git" "$r/repo" 2>$null
  'a' | Set-Content "$r/repo/a.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m init; git -C "$r/repo" branch -M main
  git -C "$r/repo" push -q origin main 2>$null; git -C "$r/repo" push -q origin main:staging 2>$null
  New-Item -ItemType Directory -Force "$r/repo/.githooks" | Out-Null
  [IO.File]::WriteAllText("$r/repo/.githooks/pre-commit", "#!/bin/sh`necho hooked > `"`$(git rev-parse --git-dir)/hook-ran`"`n")
  git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m hooks; git -C "$r/repo" config core.hooksPath .githooks
  'b' | Set-Content "$r/repo/b.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: b'; git -C "$r/repo" push -q origin main 2>$null
  $out = Px $O deploy merge -Repo "$r/repo" -To staging -From main 2>&1 | Out-String
  $wt = if ($out -match 'worktree: (.+)') { $Matches[1].Trim() }
  $gd = if ($wt) { (git -C $wt rev-parse --absolute-git-dir).Trim() }
  Expect 'deploy merge is a merge commit' ($wt -and @((git -C $wt log -1 --format=%p) -split ' ').Count -eq 2)
  Expect 'deploy merge ran the pre-commit hook' ($gd -and (Test-Path (Join-Path $gd 'hook-ran')))
  $kl = "$k/skills/dev-kit/kit.local.json"; & $J @{ repos = @(@{ checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'live'; tag = 'rel-{date}' }) }) } $kl 5
  $dm = { Px $O deploy merge -Repo "$r/repo" @args 2>&1 | Out-String }; $o1 = & $dm -To main; $o2 = & $dm -To live -Push; Remove-Item $kl
  Expect 'deploy merge: trunk = no merge; tag deploy pushes a tag' ($o1 -match 'trunk' -and $o2 -match 'pushed rel-' -and (git -C "$r/origin.git" tag) -match '^rel-')
} finally { Remove-Item Env:CLAUDE_WT_ROOT -ErrorAction SilentlyContinue }
$KP = Join-Path $k 'skills/orchestrate/orch.ps1'
$null = pwsh @np $KP --help; $h0 = $LASTEXITCODE; $null = pwsh @np $KP bogus-verb; $h2 = $LASTEXITCODE
$mk = Join-Path (Kd) 'kit main'; New-Item -ItemType Directory -Force "$mk/skills/dev-kit", "$mk/skills/orchestrate" | Out-Null
Copy-Item (Join-Path $k 'skills/dev-kit/lib.ps1'), (Join-Path $k 'skills/dev-kit/kit.example.json') "$mk/skills/dev-kit/"; Copy-Item $KP "$mk/skills/orchestrate/"
'readme' | Set-Content "$mk/README.md"
git -C $mk init -q; git -C $mk add -A; git -C $mk -c user.name=t -c user.email=t@t commit -q -m init
& $J @{ localOnly = @('secret.txt') } "$mk/skills/dev-kit/kit.local.json"
$lw = Join-Path (Kd) 'kit wt'; git -C $mk worktree add -q --detach $lw 2>$null
'edited' | Set-Content "$lw/README.md"
$kx = (pwsh @np "$lw/skills/orchestrate/orch.ps1" setup -Exclude 2>&1 | Out-String) + (pwsh -NoProfile -Command ". '$lw/skills/orchestrate/orch.ps1'; 'unstaged:' + (Test-UnstagedEdits '$lw' 'README.md')" 2>&1 | Out-String)
Expect 'orch.ps1: --help 0, bad verb 2; worktree: excludes to main clone, no memory, unstaged README seen' ($h0 -eq 0 -and $h2 -eq 2 -and
  (Get-Content "$mk/.git/info/exclude" -Raw) -match '/secret\.txt' -and $kx -match 'linked kit worktree' -and -not (Test-Path "$lw/memory") -and $kx -match 'unstaged:True')
$env:KIT_TRACKER_TYPE = 'clickup'   # tag CU-
$out = pwsh @np $O track add -Task 0 -Mrs 'web!1' 2>&1 | Out-String
Expect "track: placeholder task '0' refused" ($LASTEXITCODE -ne 0 -and $out -match 'needs a real -Task id')
$out = pwsh @np $O track add -Task 'CU-abc123' -Mrs 'web!1,web!2' -MergeAfter 'web!2>api!7' 2>&1 | Out-String
$tasks = (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks
Expect 'track: tag stripped, merge order echoed' ($tasks.ContainsKey('abc123') -and $out -match 'merge-after: web!2>api!7')
$null = pwsh @np $O track remove -Task abc123 -Mrs 'web!2' 2>&1
$tasks = (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks
Expect 'track: remove drops the MR and its pair' ((@($tasks.abc123.mrs) -join ',') -eq 'web!1' -and -not @($tasks.abc123.mergeAfter).Count)
Remove-Item Env:KIT_TRACKER_TYPE
$cf = Join-Path (Kd) 'brief.contracts.md'; '# contracts' | Set-Content $cf
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
Expect 'decide ids unique within a second; board check without -Worktree exit 2; orch.ps1 setup --help prints usage, exit 0' ($i1 -ne $i2 -and $bc -eq 2 -and $hc -eq 0 -and $hp -match 'commands in one file' -and $hp -notmatch 'setup:')
# deploy batching
$cfgF = Join-Path $k 'skills/dev-kit/kit.local.json'; $dep = { Px $O deploy @args }
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }, @{ target = 'prod'; branch = 'production'; job = 'deploy' }, @{ target = 'live'; production = $true }, @{ target = 'preprod'; production = $false }) }); deploy = @{ trigger = 'ask'; minIntervalHours = @{ default = 4 } } } $cfgF
$null = New-Item -ItemType Directory -Force (Split-Path $tf); & $J @{ tasks = @{ t1 = @{ task = 't1'; mrs = @('api!1'); done = $true; doneAt = (Get-Date).ToString('s') }; t2 = @{ task = 't2'; mrs = @('api!2'); done = $false } }; automerge = @{} } $tf
$fx = Join-Path (Kd) 'deploy-fixture.json'
& $J @{ mrs = @{ 'api!1' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) }; 'api!2' = @{ rows = @(@{ target = 'stage'; state = 'DEPLOYED'; detail = 'live' }) }; 'api!3' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) } }; lastCi = @{ stage = (Get-Date).AddHours(-6).ToString('s') } } $fx
$plan = { @(& $dep plan -Offline $fx -Json | ConvertFrom-Json) }; $p = & $plan
Expect 'deploy plan: production by name / flag / false; one ASK batch for stage' (($p.target -join ',') -eq 'stage,preprod' -and $p[0].target -eq 'stage' -and $p[0].status -eq 'ASK' -and (@($p[0].mrs.mr) -join ',') -eq 'api!1')
$null = & $dep request -Mrs 'https://git.example.com/g/api/-/merge_requests/3' -Run w2 -Offline $fx; $p = & $plan
Expect 'deploy request: another session''s MR joins the same batch' ((@($p[0].mrs.mr | Sort-Object) -join ',') -eq 'api!1,api!3')
$null = & $dep record -Env stage -Mrs 'api!1','api!3' -By tester; $p = & $plan
Expect 'deploy record: WAIT in the window, the request cleared' ($p[0].status -eq 'WAIT' -and -not @($p[0].pending).Count)
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }, @{ name = 'py'; deploys = @(@{ target = 'pystage' }) }) } $cfgF
$fx2 = Join-Path (Kd) 'deploy-fixture2.json'; & $J @{ mrs = @{ 'api!5' = @{ rows = @(@{ target = 'stage'; state = 'UNKNOWN'; detail = 'cannot reach the host' }) } } } $fx2
$dr = & $dep request -Mrs 'api!5' -Run w4 -Offline $fx2 | Out-String
Expect 'deploy request: only the MR repo''s deploys; UNKNOWN names the deploy and why' ($dr -match 'DEPLOY stage: UNKNOWN: the deploy check failed: api!5: cannot reach the host' -and $dr -notmatch 'pystage')
$null = & $dep record -Env stage -Mrs 'api!5' -By tester
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }) } $cfgF
$null = & $dep request -Mrs 'api!3' -Run w3 -Offline $fx; $p = & $plan
Expect 'deploy plan: trigger owner -> READY in the window, never ASK / WAIT' ($p[0].status -eq 'READY' -and $p[0].trigger -eq 'owner')
$sup = (Get-Command (Join-Path $k 'skills/orchestrate/orch.ps1')).ScriptBlock.Ast.Extent.Text -match "deploy\.trigger' 'owner'\)\)\.ToLower\(\) -eq 'ask'"
Expect 'supervise: DEPLOY ASK only under trigger ask' $sup
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
# never re-applied; "All MRs merged" once; deploy plan UNKNOWN on a failed check; supervise step-aside;
# LESSONS.md lock freed on a failed -Bump; top-level --help; MergedTip on a submodule
$bwt = Join-Path (Kd) 'bwt'
$j1 = pwsh @np $O board join -Agent BX -Run rb -Claims $bwt | Out-String; $s1 = if ($j1 -match 'SESSION (\S+)') { $Matches[1] }
$j2 = pwsh @np $O board join -Agent BX -Run rb -Claims $bwt -Resume | Out-String
$bt = pwsh @np $O board beat -Session $s1 | Out-String; $btc = $LASTEXITCODE
$bd = TkPath $k board
Expect 'board: beat after TAKEOVER exit 1, no lock left' ($j2 -match 'TAKEOVER' -and $btc -eq 1 -and $bt -match 'TAKEN OVER' -and -not @(Get-ChildItem $bd -Filter '*.lock').Count)
$a2 = '{"brief":"C:/b/wave-y.md","agents":[{"id":"Y1","items":"B1"}]}'; $af2 = Join-Path (Kd) 'args2.json'; [IO.File]::WriteAllText($af2, $a2)
$h2 = & { . $O; Get-KitFnv $a2 }
$null = pwsh @np $O launch -Self -Script buildy.js -Run wave-x -ArgsFile $af2 -Fnv $h2
Expect 'launch -Self: 2 launches, one run name: 2 records' (@(Get-ChildItem $ld -Filter 'self-buildy-wave-x-*.json').Count -eq 2)
'{"kitDir":"C:/k","runDir":"C:/r"}' | Set-Content (Join-Path $ld 'args-testy-r.json'); '{"script":"","at":"bad"}' | Set-Content (Join-Path $ld 'broken.json')
$ll = pwsh @np $O launch -List 2>&1 | Out-String; $cl = pwsh @np $O cleanup -IfDue -Quiet 2>&1 | Out-String; $clc = $LASTEXITCODE
Expect 'launch records: args dumps / broken records skipped; SessionStart hook shows no error' ($ll -notmatch 'Exception|Cannot bind' -and $cl -notmatch 'Exception|Cannot bind' -and $clc -eq 0)
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
function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$TimeoutSec = 60) { [pscustomobject]@{ code = 2; out = 'qa.ps1: usage error'; err = ''; timedOut = $false } }
$p = @(Invoke-Deploy plan -Json | ConvertFrom-Json)
"unknown:$(@($p | Where-Object status -eq 'UNKNOWN').Count -ge 1 -and -not @($p | Where-Object status -eq 'NOTHING').Count)"
'@
$res = Invoke-PsTest 'track-test' $tt @($O)
Expect-Each $res 'track/deploy: # (throttle: the MR search once per 30 min, tasks rotate by checkedAt; keep: a hold added mid-run survives)' @('skip', 'once', 'hold', 'unknown', 'throttle', 'keep') 8
$lkf = Join-Path (TkPath $k cache -Create) 'supervise.lock'
Set-JsonFile $lkf @{ session = 'other'; at = (Get-Date).ToString('s'); pid = 1 }
$sv = pwsh @np $O supervise -Brief -Session me | Out-String
Expect 'supervise: another session''s fresh lock -> steps aside, lock file kept, no .lock left' ($sv -match 'steps aside' -and (Get-Content $lkf -Raw) -match 'other' -and -not (Test-Path "$lkf.lock"))
$dp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden; $dp.WaitForExit()
$gb = Join-Path (TkPath $k board -Create) 'gone-s.json'; Set-JsonFile $gb @{ session = 'gone-s'; agent = 'X9'; run = 'r1'; status = 'working'; beat = (Get-Date).ToString('o'); joined = (Get-Date).ToString('o'); holderPid = $dp.Id }
$sv = pwsh @np $O supervise -AutoFix -Brief -Takeover -Session me 2>&1 | Out-String
Expect 'supervise -AutoFix -Takeover: a gone session''s board entry is marked left (no "not recognized")' ((Get-Content $gb -Raw | ConvertFrom-Json).status -eq 'left' -and $sv -notmatch 'not recognized'); Remove-Item $gb
$lt = Join-Path (Kd) 'lk.json'; '' | Set-Content "$lt.lock"; (Get-Item "$lt.lock").LastWriteTime = (Get-Date).AddMinutes(-5); $fs = [IO.File]::Open("$lt.lock", 'Open', 'Write', 'None')
$lj = Start-ThreadJob { Start-Sleep -Milliseconds 1500; ($using:fs).Dispose(); Remove-Item "$using:lt.lock" }
$lw = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); try { Invoke-KitLocked $lt { 'got' } } catch { "threw: $_" } }; $null = $lj | Wait-Job
Expect 'Invoke-KitLocked: an old lock still held open waits for its holder, never fails fast' ($lw -eq 'got')
$er = & { . $O; Get-KitEnvRows @([pscustomobject]@{ env = 'e'; services = @([pscustomobject]@{ service = 'api'; state = 'down'; why = 'idle for 15 min' }, [pscustomobject]@{ service = 'web'; state = 'down'; why = 'crashed' }); leases = @([pscustomobject]@{ agent = 'a1'; services = @('web') }); holds = @() }) (Get-Date) }
Expect 'supervise: a down service with no lease is idle (no row, no flag); a leased one shows' (@($er.rows).Count -eq 1 -and $er.rows[0].name -match 'web' -and $er.rows[0].name -notmatch 'api' -and -not @($er.flags).Count)
$null = pwsh @np $O learn -Skill revy -Bump 'no such lesson words'; $bc2 = $LASTEXITCODE
Expect 'learn -Bump miss: exit 1, LESSONS.md lock released' ($bc2 -eq 1 -and -not (Test-Path (Join-Path $k 'LESSONS.md.lock')))
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
$env:KIT_NET_TRIES = '1'; Initialize-KitTracker -Type clickup
function clickup { $global:LASTEXITCODE = 1; 'Error: dial tcp: lookup api.clickup.com: no such host' }
$q = Set-TrackerStatus 'T9' 'inTest' 3>$null; "queued:$("$q" -match '^QUEUED' -and (Test-Path (Get-KitPath outbox)))"
function clickup { $global:LASTEXITCODE = 0; "status set: $($args[2])" }
$s = @(Invoke-KitOutbox); "sent:$("$s" -match '^SENT status T9' -and -not (Test-Path (Get-KitPath outbox)))"
function clickup { $global:LASTEXITCODE = 1; 'Error: task not found' }
try { $null = Set-TrackerStatus 'T9' 'inTest'; 'real:False' } catch { "real:$(-not (Test-Path (Get-KitPath outbox)))" }
'@
$res = Invoke-PsTest 'outbox-test' $nt @(Join-Path $k 'skills/dev-kit/lib.ps1')
Expect-Each $res 'outbox: #' @('queued', 'sent', 'real')
& $J @{ orgTerms = @('Acmecorp') } (Join-Path $k 'skills/dev-kit/kit.local.json')
$null = pwsh @np $O learn -Skill revy -Lesson '(2×) a generic lesson'
$null = pwsh @np $O learn -Skill revy -Lesson 'an Acmecorp lesson'
$r1 = pwsh @np $O learn -Read -Skill revy | Out-String
Expect 'learn: generic -> LESSONS.md, org term -> LESSONS.local.md' ($r1 -match 'a generic lesson' -and $r1 -match '\(local\)' -and (Get-Content (Join-Path $k 'LESSONS.local.md') -Raw) -match 'Acmecorp' -and (Get-Content (Join-Path $k 'LESSONS.md') -Raw) -notmatch 'Acmecorp')
$null = pwsh @np $O learn -Skill revy -Fixed 'a generic lesson'
$hi = pwsh @np $O learn -History -Grep 'a generic lesson' | Out-String
Expect 'learn -Fixed: line leaves LESSONS.md, shown by -History' ((Get-Content (Join-Path $k 'LESSONS.md') -Raw) -notmatch 'a generic lesson' -and $hi -match '\(fixed in kit\) \(2×\) a generic lesson')
$j1 = pwsh @np $O board join -Type devy -Agent X7 -Run w7 -Items 'A1' -Claims 'C:/wt/x7' | Out-String
$j2 = pwsh @np $O board join -Type revy -Agent R7 -Run w7 | Out-String
$null = pwsh @np $O board msg -Agent R7 -To X7 -Text 'I need a.ts'
$ib = pwsh @np $O board inbox -Agent X7 | Out-String
$dp = pwsh @np $O board dispute -Agent X7 -With R7 -Item A1 -Claim 'no null check needed' -Evidence 'a.ts:3' -Propose 'drop it' | Out-String
$did = if ($dp -match 'DISPUTE (p-\S+) open') { $Matches[1] }
$null = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'b.ts:9'
$null = pwsh @np $O board dispute -Id $did -Agent X7 -Claim 'b.ts is dead' -Evidence 'git grep: no caller'
$esc = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'router.ts:12' | Out-String
$dl = pwsh @np $O decide list -Pending | Out-String
Expect 'board: join -Type shown; msg in inbox; dispute split after 2 rounds -> decision' ($j2 -match 'X7\s+devy' -and
  $ib -match 'from R7: I need a\.ts' -and $did -and $esc -match 'escalated: DECISION d-' -and $dl -match "Dispute $did")
$dp2 = pwsh @np $O board dispute -Agent X7 -With R7 -Item A2 -Claim 'cache is safe' -Evidence 'c.ts:4' -Propose 'keep' | Out-String
$did2 = if ($dp2 -match 'DISPUTE (p-\S+) open') { $Matches[1] }; $df2 = Join-Path (TkPath $k disputes) "$did2.json"
(Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3)
$ex = & { . $O; Invoke-DisputeExpiry } | Out-String
(Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3); $ex2 = & { . $O; Invoke-DisputeExpiry } | Out-String
Expect 'board: dispute silent 2 h escalates once (re-read under lock)' (-not $ex2.Trim() -and $ex -match "dispute $did2 .*escalated, DECISION d-" -and (Get-Content $df2 -Raw | ConvertFrom-Json).status -eq 'escalated' -and (pwsh @np $O decide list -Pending | Out-String) -match "Dispute $did2")
$sd = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath qa-seats -Create) 'seats' }; New-Item -ItemType Directory -Force $sd | Out-Null
'{"agent":"test:Q1","kind":"web","need":2,"since":"2026-10-16T10:00:00"}' | Set-Content "$sd/q1.json"
'{"leases":{"devy-A1":{"services":["api"],"repos":[],"until":"2026-10-16T12:00:00"}}}' | Set-Content (Join-Path (& { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath localenv -Create }) 'shop.json')
$bs = pwsh @np $O board show | Out-String
Expect 'board show: lists QA seats and local-env leases' ($bs -match 'seat: test:Q1 web 2 GB' -and $bs -match 'lease: shop devy-A1 on api')
$km = New-TestKit mig; $Om = Join-Path $km 'skills/orchestrate/orch.ps1'
$oldWf = 'dev' + '-wave'; $oldSk = 'tech' + '-audit'   # built: no old name in the kit (lint OLD-NAME)
$ldm = TkPath $km launches -Create
[IO.File]::WriteAllText((Join-Path $ldm 'm1.json'), "{`"script`": `"C:/kit/workflows/$oldWf.js`", `"completed`": `"2026-10-16T10:00:00`"}")
Add-Content (TkPath $km signals -Create) "{`"at`":`"2026-10-16T10:00:00`",`"skill`":`"$oldSk`",`"kind`":`"idea`",`"text`":`"x`"}" -Encoding utf8
$oa = Join-Path (TkPath $km logs -Create) ('kit' + '-audits'); New-Item -ItemType Directory -Force $oa | Out-Null; 'r' | Set-Content "$oa/audit-1.md"
'2026-10-01' | Set-Content (Join-Path $km ".state/$('kit' + '-audit').stamp")
$hm = '{}' | pwsh @np $Om health 2>&1 | Out-String
Expect 'health: state under a renamed name nudges setup -Migrate' ($hm -match 'renamed state under its old name')
$mg = pwsh @np $Om setup -Migrate 2>&1 | Out-String
Expect 'setup -Migrate: launch records, signals follow renames' ((Get-Content (Join-Path $ldm 'm1.json') -Raw) -match 'workflows/buildy\.js' -and
  (Get-Content (TkPath $km signals) -Raw) -match '"skill":"revy"')
Expect 'setup -Migrate: renamed runtime / state paths move' (-not (Test-Path $oa) -and (Test-Path (Join-Path (TkPath $km kitty-audits) 'audit-1.md')) -and (Test-Path (TkPath $km last-kitty-audit)))
Remove-TestKit $km
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
  mem = @{ TotalGB = 64; AvailGB = 16 }; ram = @{ kit = 5; browsers = 4; apps = 3; servers = 1; vms = 2; windows = 13; unknown = 20 }; unknown = @('foo 0.6'); top = @(@{ name = 'Teams'; gb = 2.4; mark = '💤' }); keepFree = 8; avgFree = 15; disk = 'D: 100 GB free'; info = @('deploy ready: stage (2 MR(s))')
  resources = @(@{ name = '🟢 rm · api'; type = 'local env'; by = 'W1'; gb = 3 }, @{ name = '🌐 rm·acme·admin'; type = 'test browser'; by = 'W1'; gb = 2 }, @{ name = '🔴 hm · api'; type = 'local env'; by = 'down: memory'; gb = 0 })
  flags = @(@{ level = 'ASK'; what = 'Teams 2.4 GB 💤 — close it?'; action = 'ask' }, @{ level = 'ACT'; what = 'ENV-FIX e-1 waiting 240 min'; action = 'fix it' }); detailFile = 'r.md' }
$r1 = (& { . $O; Format-KitReport $rd -Width 160 -Agents }) -join "`n"; $rd.mem.AvailGB = 6; $r2 = (& { . $O; Format-KitReport $rd -Ascii -Width 80 }) -join "`n"
$want1 = @('| Agent | Doing |', '|---|---|', '| 🛠️ 1 × devy (+10kT) | build 1 (P1) |', '| 🧪 2 × checky (+20kT) | ⏸ env-fix 1 (J1) · test 1 (W1) |', '',
  "🖥️ **RAM** $('🟦' * 2)🟨🟧🟪$('🟫' * 4)$('⬛' * 6)$('⬜' * 5) **48 / 64 GB**", '🟦 Kit 5 · 🟨 Your browsers 4 · 🟧 Your apps 3 · 🟩 Servers 1', '🟪 WSL 2 · 🟫 Windows 13 · ⬛ Unknown 20 (foo 0.6) · ⬜ Free 16', 'top apps: Teams 2.4 💤 (💤 idle · 📈 +1 GB)', '',
  '| Resource | Used by | RAM | Resource | Used by | RAM |', '|---|---|---|---|---|---|', '| 🟢 rm · api | W1 | 3 | 🔴 hm · api | down: memory | — |', '| 🌐 rm·acme·admin | W1 | 2 |  | |  |', '',
  '🚩 **Flags**', '- **ACT** ENV-FIX e-1 waiting 240 min -> fix it', '- ❓ **ASK** · Teams 2.4 GB 💤 — close it? -> ask', '- **INFO** deploy ready: stage (2 MR(s))') -join "`n"
Expect 'supervise report snapshot (-Agents, wide)' ($r1 -eq $want1)
Expect 'supervise report: below the floor red, -Ascii, narrow, no agents by default' ($r2 -match '\*\*RAM\*\* \[KKBBAVW{5}U{7}\.\.\] \*\*58 / 64 GB\*\*' -and $r2 -match '\| Resource \| Used by \| RAM \|\r?\n\|---\|---\|---\|\r?\n\| rm - api \| W1 \| 3 \|' -and (& { . $O; Format-KitReport $rd }) -join '' -match '(🟥){2}' -and ((& { . $O; Format-KitReport $rd }) -join '') -notmatch 'Agent')
$rd.ram.servers = 0; $r3 = (& { . $O; Format-KitReport $rd }) -join "`n"
Expect 'supervise report: a 0.0 category leaves the legend' ($r3 -notmatch 'Servers' -and $r3 -match 'Unknown 20')
$rn = (Get-Content (Join-Path $k 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._manifest.ram; $pr = { param($i, $n, $p, $g) [pscustomobject]@{ Id = $i; Name = $n; Path = $p; WorkingSet = $g * 1GB; Private = $g * 1GB; Cpu = 0 } }
$rb = & { . $O; Get-KitRamBuckets @((& $pr 1 'svchost.exe' 'C:\Windows\System32\svchost.exe' 1), (& $pr 2 'vtool.exe' 'C:\Program Files\Realtek\vtool.exe' 1), (& $pr 3 'wslhost.exe' 'C:\x\wslhost.exe' 1), (& $pr 4 'mystery.exe' 'D:\x.exe' 2)) @{} $rn ([pscustomobject]@{ TotalGB = 16; AvailGB = 6 }) }
Expect 'supervise RAM: Windows paths + RAM no process owns = Windows, wsl* = WSL (first match), the rest unknown' ($rb.bk.windows -eq 7 -and $rb.bk.vms -eq 1 -and $rb.bk.unknown -eq 2)
$an = & { . $O; $n = Get-Date; $c = @{ usedGB = 40; cpu = 95; runs = @(@{ id = 'wf1'; at = $n.AddMinutes(-25).ToString('o'); path = 'j.jsonl' }); trains = @(@{ env = 'shop'; key = 't1 build' })
    logs = @(@{ path = 'api.log'; errors = 2; first = 'ERROR boom' }); restarts = @(@{ env = 'shop'; svc = 'api'; n = 3 }); outbox = 4; toolErrors = 2; errorRun = 'wf1'; lint = '2 problem(s)'
    adopted = @(@{ env = 'shop'; svc = 'web'; port = 4200 }); stray = @('junk.txt') }
  $p = @{ usedGB = 36; outbox = 1; toolErrors = 1; cpuHighSince = $n.AddMinutes(-11).ToString('o'); trains = @{ shop = @{ key = 't1 build'; since = $n.AddMinutes(-21).ToString('o') } } }
  "$((Get-KitAnomalies $c $p $n).flags.what -join "`n")`n$((Get-KitAnomalies @{ usedGB = 1; cpu = 5 } @{} $n).flags.Count)" }
$want = 'STALL: run wf1', 'STALL: shop train', 'ERROR SPIKE: 2', 'RESTART LOOP: shop api', 'RAM \+4', 'CPU 95%', 'outbox grew to 4', '1 new agent', 'main lint red', 'shop web port 4200', 'UNKNOWN: junk.txt', '\n0$'
Expect "supervise anomalies: every flag from its fixture, none on a quiet round" (-not @($want | Where-Object { $an -notmatch $_ }).Count)
$lg = Join-Path (Split-Path $k) 'an.log'; 'ok' | Set-Content $lg; $s1 = @(& { . $O; Get-KitLogErrors @($lg) @{} }); Add-Content $lg "ERROR one`nTraceback (most recent call last)`nfine"
$s2 = @(& { . $O; Get-KitLogErrors @($lg) @{ (Resolve-Path $lg).Path = $s1[0].size } })
$oc = & { . $O; $o = (Get-Date).AddMinutes(-40); $mk = { param($i, $pp, $n, $c) [pscustomobject]@{ Id = $i; ParentId = $pp; Name = $n; Cpu = $c; Created = $o } }
  $pr = @((& $mk 10 1 'cmd.exe' 1), (& $mk 11 10 'conhost.exe' 1), (& $mk 12 99 'pwsh.exe' 5), (& $mk 13 98 'pwsh.exe' 1), (& $mk 14 97 'python.exe' 1), (& $mk 99 0 'x' 1), (& $mk 98 0 'claude' 1), (& $mk 97 0 'y' 1))
  @(Get-KitOrphanConsoles $pr @{ 10 = 1; 11 = 1; 12 = 1; 13 = 1 } @{ '10' = 1; '11' = 1; '12' = 1; '13' = 1; '14' = 1 } 10 @{ 13 = 1 }).Id -join ',' }
Expect "supervise: orphan kit consoles = parent gone / idle, never busy, tool-shell or owner ones ($oc)" ($oc -eq '10')
Expect 'supervise anomalies: only new log error lines count' ($s1[0].errors -eq 0 -and $s2[0].errors -eq 2)
Remove-TestKit $k
Complete-Tests
