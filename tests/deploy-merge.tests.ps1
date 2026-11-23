#Requires -Version 7
<#
tests/deploy-merge.tests.ps1: bossy.ps1 deploy merge, offline, on a throw-away test kit with the deploys adapters.
Usage: pwsh -NoProfile -File tests/deploy-merge.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$env:KIT_TEST_SHIM = Join-Path $PSScriptRoot 'hostverb-shim.ps1'   # GitLab-path mocks behind host verbs   # New-TestKit adds $TestKitFiles
$TestKitFiles = @('skills/bossy/adapters/deploy_merge.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/deploys.md', 'skills/pokey/adapters/deployed_checks.ps1')   # copied into every New-TestKit kit
$k = New-TestKit deploy-merge; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# deploy merge is a verb of adapters/deploys.ps1
$dpa = Join-Path $src 'skills/bossy/adapters/deploys.ps1'
Copy-Item $dpa (Join-Path $k 'skills/bossy/adapters'); $r = Assert-TestPath (Join-Path (Kd) 'git')
$env:CLAUDE_WT_ROOT = "$r/wt"
git init -q --bare "$r/origin.git"; git clone -q "$r/origin.git" "$r/repo" 2>$null
'a' | Set-Content "$r/repo/a.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m init; git -C "$r/repo" branch -M main
git -C "$r/repo" push -q origin main 2>$null; git -C "$r/repo" push -q origin main:staging 2>$null
New-Item -ItemType Directory -Force "$r/repo/.githooks" | Out-Null
[IO.File]::WriteAllText("$r/repo/.githooks/pre-commit", "#!/bin/sh`necho hooked > `"`$(git rev-parse --git-dir)/hook-ran`"`n")
git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m hooks; git -C "$r/repo" config core.hooksPath .githooks
'b' | Set-Content "$r/repo/b.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: b'; git -C "$r/repo" push -q origin main 2>$null
$out = pwsh @np $O deploy merge -Repo "$r/repo" -To staging -From main 2>&1 | Out-String
$wt = if ($out -match 'worktree: (.+)') { $Matches[1].Trim() }
$gd = if ($wt) { (git -C $wt rev-parse --absolute-git-dir).Trim() }
Expect 'deploy merge is a merge commit' ($wt -and @((git -C $wt log -1 --format=%p) -split ' ').Count -eq 2)
Expect 'deploy merge ran the pre-commit hook' ($gd -and (Test-Path (Join-Path $gd 'hook-ran')))
$kl = "$k/skills/crafty/kit.local.json"; @{ repos = @(@{ checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'live'; tag = 'rel-{date}' }) }) } | ConvertTo-Json -Depth 5 | Set-Content $kl
$o1 = pwsh @np $O deploy merge -Repo "$r/repo" -To main 2>&1 | Out-String; $o2 = pwsh @np $O deploy merge -Repo "$r/repo" -To live -Push 2>&1 | Out-String
Expect 'deploy merge: trunk = no merge; tag deploy pushes a tag' ($o1 -match 'trunk' -and $o2 -match 'pushed rel-' -and (git -C "$r/origin.git" tag) -match '^rel-')
@{ repos = @(@{ checkout = "$r/repo"; target = 'other'; deploys = @(@{ target = 'st'; branch = 'main'; from = @('main') }) }) } | ConvertTo-Json -Depth 5 | Set-Content $kl
$o4 = pwsh @np $O deploy merge -Repo "$r/repo" -To st 2>&1 | Out-String
Expect "deploy merge: no -From = deploys[].from before the repo target ($($o4.Trim()))" ($o4 -match 'source branch: main' -and $o4 -match 'trunk')
# a deploy branch: -Push refused (nothing reaches it); -Mr pushes deploy/<env>-<date>, opens the MR (method merge = squash off), merges on green
$stagingTip = "$(git -C "$r/origin.git" rev-parse staging)".Trim(); $hostLog = Join-Path (Kd) 'host.log'; $hostPs = Join-Path (Kd) 'host.ps1'
Set-Content $hostPs @'
$v, $rest = $args; $log = $env:DM_HOST_LOG; $flag = "$log.merged"
switch ($v) {
  'create' { Add-Content $log "create $($rest -join ' | ')"; '{"iid":5,"web_url":"https://h.example/g/shop/-/merge_requests/5"}' }
  'get' { $gets = if (Test-Path $flag) { [int](Get-Content $flag) } else { -1 }; if ($gets -ge 0) { Set-Content $flag ($gets + 1) }   # merges async: 'opened' for 2 reads after the merge call
    @{ iid = 5; sha = 'abc'; state = $(if ($gets -ge 2) { 'merged' } else { 'opened' }) } | ConvertTo-Json -Compress }
  'merge' { Add-Content $log "merge $($rest -join ' ')"; Set-Content $flag 0; '{"iid":5,"state":"opened"}' }
  'ci' { '{"id":1,"status":"success"}' }
}
'@
$hostCmd = { param($v, $a) "pwsh -NoProfile -File `"$hostPs`" $v $a" }
@{ gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.create' = (& $hostCmd create '{source} {target} {method} "{body}"'); 'mr.get' = (& $hostCmd get '{n}'); 'mr.merge' = (& $hostCmd merge '{n} {method} {sha}') } }; ci = @{ type = 'command'; commands = @{ status = (& $hostCmd ci '{sha}') } }
   repos = @(@{ name = 'shop'; checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'st'; branch = 'staging' }) }) } | ConvertTo-Json -Depth 6 | Set-Content $kl
'c' | Set-Content "$r/repo/c.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: c'; git -C "$r/repo" push -q origin main 2>$null
Get-ChildItem "$r/wt" -Directory -Filter 'deploymerge-*' -ErrorAction SilentlyContinue | ForEach-Object { git -C "$r/repo" worktree remove --force $_.FullName 2>$null }
$o5 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Push 2>&1 | Out-String
Expect "deploy merge -Push to a deploy branch: refused, nothing pushed ($($o5.Trim()))" ($o5 -match 'REFUSED' -and $o5 -match '-Mr' -and $o5 -match 'squash off' -and "$(git -C "$r/origin.git" rev-parse staging)".Trim() -eq $stagingTip)
$klKeep = Get-Content $kl -Raw; $klSq = $klKeep | ConvertFrom-Json; $klSq | Add-Member -Force NoteProperty deploy @{ mergeMethod = 'squash' }; $klSq | ConvertTo-Json -Depth 8 | Set-Content $kl
$o5s = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Push 2>&1 | Out-String; Set-Content $kl $klKeep -NoNewline
Expect "deploy merge texts follow deploy.mergeMethod: squash never says squash off ($($o5s.Trim()))" ($o5s -match 'merge method squash' -and $o5s -notmatch 'squash off')
$env:DM_HOST_LOG = $hostLog
$o6 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Mrs 'shop!12' -Decision 'd-42' -WaitMinutes 1 2>&1 | Out-String
$hl = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }; $depBr = @(git -C "$r/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/deploy/')
Expect "deploy merge -Mr: deploy/st-<date> pushed, MR to staging with method merge and MRs + decision in the body, merged on green, staging never pushed ($($o6.Trim()) | $hl)" ($o6 -match 'merged deploy MR https://h\.example/g/shop/-/merge_requests/5' -and $depBr -match '^deploy/st-\d{8}-\d{6}$' -and $hl -match 'create deploy/st-\d{8}-\d{6} \| staging \| merge \| ' -and $hl -match 'shop!12' -and $hl -match 'Deploy decision: d-42' -and $hl -match 'merge 5 merge abc' -and "$(git -C "$r/origin.git" rev-parse staging)".Trim() -eq $stagingTip)
Remove-Item Env:DM_HOST_LOG
$o3 = pwsh @np $O deploy merge -To staging 2>&1 | Out-String
Expect "deploy merge without -Repo: a clear error, no binding crash ($($o3.Trim()))" ($o3 -match 'deploy merge: -Repo missing' -and $o3 -notmatch 'Cannot bind')
# -To a target name: from another clone of the repo (no checkout match) it still resolves; a target without branch = a clear stop
Get-ChildItem "$r/wt" -Directory -Filter 'deploymerge-*' -ErrorAction SilentlyContinue | ForEach-Object { git -C "$r/repo" worktree remove --force $_.FullName 2>$null }
git clone -q "$r/origin.git" "$r/repo2" 2>$null
$o7 = pwsh @np $O deploy merge -Repo "$r/repo2" -To st 2>&1 | Out-String
$cfg7 = Get-Content $kl -Raw | ConvertFrom-Json; $cfg7.repos[0].deploys += [pscustomobject]@{ target = 'hostonly'; ssh = @{ host = 'u@h' } }; $cfg7 | ConvertTo-Json -Depth 8 | Set-Content $kl
$o8 = pwsh @np $O deploy merge -Repo "$r/repo2" -To hostonly -Mr 2>&1 | Out-String; $o8c = $LASTEXITCODE
Expect "deploy merge -To <target>: resolved from another clone; a target without branch stops with the fix, exit 2 ($($o7.Trim()) | $($o8.Trim()))" ($o7 -match 'deploymerge-staging' -and $o7 -notmatch 'fetch origin .*FAILED' -and $o8c -eq 2 -and $o8 -match 'deploys\[\] target hostonly has no branch')
$cfg7.repos += [pscustomobject]@{ name = 'other'; checkout = "$r/none"; deploys = @(@{ target = 'o-st'; branch = 'staging' }) }; $cfg7 | ConvertTo-Json -Depth 8 | Set-Content $kl
$o9 = pwsh @np $O deploy merge -Repo "$r/repo2" -To staging 2>&1 | Out-String; $o9c = $LASTEXITCODE
Expect "deploy merge: -To that two repos' deploys name, from an unknown clone = a stop, exit 2 ($($o9.Trim()))" ($o9c -eq 2 -and $o9 -match 'names deploys of shop, other')
# K62r: deploy record without -Mrs clears only the recorded target's repos; another repo's pending request survives
Set-JsonFile (Join-Path $k 'skills/crafty/kit.local.json') @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage' }) }, @{ name = 'web'; deploys = @(@{ target = 'webst' }) }) }
Set-JsonFile (Join-Path (TkPath $k deploys -Create) 'pending.json') @{ requests = @(@{ at = (Get-Date).ToString('s'); run = 'r1'; mrs = @('api!9', 'web!4') }) }
$null = pwsh @np $O deploy record -Env stage -By tester 2>&1; $pend62 = @((Read-Json (Join-Path (TkPath $k deploys) 'pending.json')).requests.mrs)
Expect "deploy record without -Mrs: the stage repo's MR leaves pending, the other repo's request stays ($($pend62 -join ','))" (($pend62 -join ',') -eq 'web!4')
# pipes (waste audit 2026-11-18): a failed pipeline retried is still re-polled, a merged-style end state is not; every round backs off
$pp = Invoke-PsTest 'pipes-backoff' @'
$null = . $args[0] 6>$null; $global:seq = @{ '1' = @('failed', 'running', 'success'); '2' = @('running', 'success') }; $global:calls = @{ '1' = 0; '2' = 0 }; $global:naps = 0
function Invoke-HostVerb([string]$Verb, $A, [switch]$NoMemo) { if ($Verb -ne 'mr.get') { return @() }; $n = "$($A.n)"; $i = [math]::Min($global:calls[$n], $global:seq[$n].Count - 1); $global:calls[$n]++
  [pscustomobject]@{ state = 'opened'; target_branch = 'main'; head_pipeline = [pscustomobject]@{ status = $global:seq[$n][$i]; id = 0 } } }
function Start-Sleep([int]$Seconds) { $global:naps++ }
$po = Invoke-Pipes -Mrs 'https://git.example.com/g/r/-/merge_requests/1,https://git.example.com/g/r/-/merge_requests/2' -MaxMinutes 5 | ConvertFrom-Json
"retry:$((@($po.mrs.status) -join ',') -eq 'success,success' -and $po.done -and $global:calls['1'] -eq 3 -and $global:naps -eq 2)"
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
Expect-Each $pp 'pipes: #' 'retry' -Show 4
# K99 (retro 2026-11-20, 2x refused): -Mrs <repo!iid> resolves to the MR url (mr.url), a url passes as is
$pr = Invoke-PsTest 'pipes-ref' @'
$null = . $args[0] 6>$null; $global:urls = @()
function Invoke-HostVerb([string]$Verb, $A, [switch]$NoMemo) { if ($Verb -eq 'mr.url') { $global:urls += "$($A.n)"; return "https://git.example.com/g/r/-/merge_requests/$($A.n)" }
  if ($Verb -ne 'mr.get') { return @() }; [pscustomobject]@{ state = 'merged'; target_branch = 'main'; head_pipeline = [pscustomobject]@{ status = 'success'; id = 0 } } }
function Start-Sleep([int]$Seconds) { }
$po = Invoke-Pipes -Mrs 'r!7,https://git.example.com/g/r/-/merge_requests/8' -MaxMinutes 1 | ConvertFrom-Json
"ref:$((@($po.mrs.mr) -join ',') -eq 'https://git.example.com/g/r/-/merge_requests/7,https://git.example.com/g/r/-/merge_requests/8' -and ($global:urls -join ',') -eq '7')"
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
Expect-Each $pr 'pipes: #' 'ref' -Show 4
# deploy intest candidates (from deploys.tests.ps1: its token cap)
$it = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$d0 = (Get-Date).ToString('o'); $old = (Get-Date).AddDays(-30).ToString('o')
Update-KitTracking { param($t) $t.tasks['gone1'] = @{ task = 'gone1'; mrs = @('api!1'); done = $true; doneAt = $d0 }; $t.tasks['ok2'] = @{ task = 'ok2'; mrs = @('api!2'); done = $true; doneAt = $d0 }
  $t.tasks['old3'] = @{ task = 'old3'; mrs = @('api!3'); done = $true; doneAt = $old }; $t.tasks['open4'] = @{ task = 'open4'; mrs = @('api!4') }; $t.tasks['qa5'] = @{ task = 'qa5'; mrs = @('api!5'); done = $true; doneAt = $d0; qaCovered = @('r1') } }
$script:viewed = @(); function Get-TrackerTask($id) { $script:viewed += $id; if ($id -eq 'gone1') { throw "HTTP 404 'Task not found, deleted'" }; [pscustomobject]@{ id = $id; name = 'n'; status = 'inProgress' } }
$o = Invoke-MarkInTest -Apply | Out-String
"gone:$($o -match 'GONE  gone1' -and $o -match 'deleted in the tracker \(gone1\)' -and -not (Read-KitTracking).tasks.ContainsKey('gone1') -and (Read-KitTracking).tasks.ContainsKey('ok2'))"
"scope:$((@($script:viewed | Sort-Object) -join ',') -eq 'gone1,ok2,qa5' -and $o -match "mark-in-test: 3 task\(s\) checked \(3 promoted by the kit in 14 d, subtasks included\): 2 now 'inProgress', 1 deleted in the tracker \(gone1\)")"
$script:viewed = @(); $tq = Invoke-MarkInTest -Task old3 | Out-String; "task:$(($script:viewed -join ',') -eq 'old3' -and $tq -match "SKIP  old3  status 'inProgress', not promoted")"
Update-KitTracking { param($t) $t.tasks['api!4'] = @{ task = 'api!4'; mrs = @('api!4') } }   # an MR ref registered as a task
function Get-TrackerTask($id) { $script:viewed += $id; if ($id -ne 'nil1') { [pscustomobject]@{ id = $id; name = 'n'; status = 'inProgress' } } }; $nq = Invoke-MarkInTest -Task nil1 | Out-String
$script:viewed = @(); $mq = Invoke-MarkInTest -FromMrs 'api!4,api!3,api!9' | Out-String
"mrs:$((@($script:viewed | Sort-Object) -join ',') -eq 'ok2,old3,open4,qa5' -and $mq -match 'MAP   api!4 -> open4\r?\n' -and $mq -match 'api!9 -> no task' -and $nq -match 'SKIP  nil1  the tracker returned nothing')"
# K3: -Mrs is bounded (-BudgetSec): its own tasks first, the rest past 60% of it = 'not checked (time budget)'; progress on stderr
function Get-TrackerTask($id) { $script:viewed += $id; Start-Sleep -Milliseconds 700; [pscustomobject]@{ id = $id; name = 'n'; status = 'inProgress' } }
$script:viewed = @(); $bq = Invoke-MarkInTest -FromMrs 'api!4' -BudgetSec 1 | Out-String
$rxBud = 'not checked \(time budget\) \('; "budget:$($script:viewed[0] -eq 'open4' -and $script:viewed.Count -lt 4 -and $bq -match $rxBud)"
# a tracker with no promoted / review role (tracker.statuses.<role> null): merged work waits in inProgress, the source role
function Test-TrackerStatusOff($s) { $s -in 'promoted', 'review' }; $tq2 = Invoke-MarkInTest -Task old3 | Out-String; "minimal:$($tq2 -notmatch 'SKIP  old3  status')"
'@
$itR = Invoke-PsTest 'intest-gone' $it @($O); Expect 'deploy intest: one progress line per task on stderr' (@($itR -match '^intest \d+s task 1/').Count -gt 0)
Expect-Each $itR 'deploy intest -Apply: a task deleted in the tracker is skipped, reported and dropped; the rest go on; candidates = tracked tasks promoted in -Days, -Task any (SKIP line), -Mrs their tracked tasks on top of every candidate; no promoted / review role: inProgress is the source (#)' @('gone', 'scope', 'task', 'mrs', 'budget', 'minimal')
# deploy plan target-branch memo (from deploys.tests.ps1: its token cap)
$tbm = Join-Path (TkPath $k cache -Create) 'deployed-rows.json'; & $J @{ 'mr|jc!9' = @{ at = (Get-Date).ToString('s'); mr = @{ target_branch = 'st/a' } } } $tbm
Expect-Each (Invoke-PsTest 'tb-memo' '. $args[0]; function Invoke-HostVerb { throw }; "memo:$((Get-MrTargetBranch ''jc!9'' $null) -eq ''st/a'')"' @($O)) 'deploy plan: target branch from pokey''s cache, no host call (#)' @('memo') 3; Remove-Item $tbm
Remove-Item Env:CLAUDE_WT_ROOT
Remove-TestKit $k
Complete-Tests
