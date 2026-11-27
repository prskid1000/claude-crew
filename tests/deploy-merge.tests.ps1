#Requires -Version 7
<#
tests/deploy-merge.tests.ps1: bossy.ps1 deploy merge, offline, on a throw-away test kit with the deploys adapters.
Usage: pwsh -NoProfile -File tests/deploy-merge.tests.ps1
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$env:KIT_TEST_SHIM = Join-Path $PSScriptRoot 'hostverb-shim.ps1'   # GitLab-path mocks behind host verbs   # New-TestKit adds $TestKitFiles
$TestKitFiles = @('skills/bossy/adapters/deploy-merge.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/deploys.md', 'skills/pokey/adapters/deployed-checks.ps1')   # copied into every New-TestKit kit
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
$o2b = pwsh @np $O deploy merge -Repo "$r/repo" -To live -Push 2>&1 | Out-String; $relTags = @(git -C "$r/origin.git" tag --list 'rel-*'); $relMsg = "$(git -C "$r/repo" tag -l --format='%(contents:subject)' $relTags[-1])"
$headSha = "$(git -C "$r/repo" rev-parse --short=7 origin/main)".Trim()
Expect "deploy merge: trunk = no merge; tag deploy pushes rel-<sha7> (retired {date} warns, gives the sha7; the same head again: the same tag; the time in the tag message) ($($relTags -join ','), $relMsg)" ($o1 -match 'trunk' -and $o2 -match "pushed rel-$headSha\b" -and $o2 -match '\{date\} is retired' -and $o2b -match "pushed rel-$headSha\b" -and ($relTags -join ',') -eq "rel-$headSha" -and $relMsg -match '^deploy live \d{4}-\d\d-\d\dT')
@{ repos = @(@{ checkout = "$r/repo"; target = 'other'; deploys = @(@{ target = 'st'; branch = 'main'; from = @('main') }) }) } | ConvertTo-Json -Depth 5 | Set-Content $kl
$o4 = pwsh @np $O deploy merge -Repo "$r/repo" -To st 2>&1 | Out-String
Expect "deploy merge: no -From = deploys[].from before the repo target ($($o4.Trim()))" ($o4 -match 'source branch: main' -and $o4 -match 'trunk')
# a deploy branch: -Push refused (nothing reaches it); -Mr pushes deploy/<env> (one per env), opens the MR (method merge = squash off), merges on green
$stagingTip = "$(git -C "$r/origin.git" rev-parse staging)".Trim(); $hostLog = Join-Path (Kd) 'host.log'; $hostPs = Join-Path (Kd) 'host.ps1'
Set-Content $hostPs @'
$v, $rest = $args; $log = $env:DM_HOST_LOG; $flag = "$log.merged"
switch ($v) {
  'create' { Add-Content $log "create $($rest -join ' | ')"; '{"iid":5,"web_url":"https://h.example/g/shop/-/merge_requests/5"}' }
  'get' { $gets = if (Test-Path $flag) { [int](Get-Content $flag) } else { -1 }; if ($gets -ge 0) { Set-Content $flag ($gets + 1) }   # merges async: 'opened' for 2 reads after the merge call
    @{ iid = 5; sha = 'abc'; state = $(if ($gets -ge 2) { 'merged' } else { 'opened' }) } | ConvertTo-Json -Compress }
  'merge' { Add-Content $log "merge $($rest -join ' ')"; Set-Content $flag 0; '{"iid":5,"state":"opened"}' }
  'ci' { '{"id":1,"status":"success"}' }
  'list' { if (Test-Path "$log.open") { Get-Content "$log.open" -Raw } else { '[]' } }
}
'@
$hostCmd = { param($v, $a) "pwsh -NoProfile -File `"$hostPs`" $v $a" }
@{ gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.create' = (& $hostCmd create '{source} {target} {method} "{body}"'); 'mr.get' = (& $hostCmd get '{n}'); 'mr.merge' = (& $hostCmd merge '{n} {method} {sha}'); 'mr.list' = (& $hostCmd list '{state}') } }; ci = @{ type = 'command'; commands = @{ status = (& $hostCmd ci '{sha}') } }
   repos = @(@{ name = 'shop'; checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'st'; branch = 'staging' }) }) } | ConvertTo-Json -Depth 6 | Set-Content $kl
'c' | Set-Content "$r/repo/c.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: c'; git -C "$r/repo" push -q origin main 2>$null
Get-ChildItem "$r/wt" -Directory -Filter 'deploymerge-*' -ErrorAction SilentlyContinue | ForEach-Object { git -C "$r/repo" worktree remove --force $_.FullName 2>$null }
$o5 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Push 2>&1 | Out-String
Expect "deploy merge -Push to a deploy branch: refused, nothing pushed ($($o5.Trim()))" ($o5 -match 'REFUSED' -and $o5 -match '-Mr' -and $o5 -match 'squash off' -and "$(git -C "$r/origin.git" rev-parse staging)".Trim() -eq $stagingTip)
# a pinned word (owner 2026-11-25): no -Commit, a sha the repo lacks, MRs it does not cover: refused, nothing merged
$wordOf = { param($a) (pwsh @np $O decide record -Gate deploy -Item st -Question q -Answer $a -Source chat | Out-String) -replace '(?s).*RECORDED (\S+) .*', '$1' }
$hd = "$(git -C "$r/repo" rev-parse origin/main)".Trim()
$pm1 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Decision (& $wordOf "yes, pinned at $($hd.Substring(0, 10))") 2>&1 | Out-String
$pm2 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Commit $hd -Decision (& $wordOf 'yes, pinned at 0badc0ffee12') 2>&1 | Out-String
$pm3 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Commit $hd -Mrs 'repo!8' -Decision (& $wordOf 'yes: repo!7; repo!8 not included') 2>&1 | Out-String
Expect "deploy merge: a pinned word refuses no -Commit, a foreign sha, an MR outside it ($($pm1.Trim()) | $($pm3.Trim()))" ($pm1 -match 'pass -Commit' -and $pm2 -match 'not a commit of' -and $pm3 -match 'does not cover repo!8' -and "$(git -C "$r/origin.git" rev-parse staging)".Trim() -eq $stagingTip)
$klKeep = Get-Content $kl -Raw; $klSq = $klKeep | ConvertFrom-Json; $klSq | Add-Member -Force NoteProperty deploy @{ mergeMethod = 'squash' }; $klSq | ConvertTo-Json -Depth 8 | Set-Content $kl
$o5s = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Push 2>&1 | Out-String; Set-Content $kl $klKeep -NoNewline
Expect "deploy merge texts follow deploy.mergeMethod: squash never says squash off ($($o5s.Trim()))" ($o5s -match 'merge method squash' -and $o5s -notmatch 'squash off')
$env:DM_HOST_LOG = $hostLog
$o6 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Mrs 'shop!12' -Decision ($d42 = & $wordOf 'yes') -WaitMinutes 1 2>&1 | Out-String
$hl = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }; $depBr = @(git -C "$r/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/deploy/')
Expect "deploy merge -Mr: deploy/st pushed (no counter, no date), MR to staging with method merge and MRs + decision in the body, merged on green, staging never pushed ($($o6.Trim()) | $hl)" ($o6 -match 'merged deploy MR https://h\.example/g/shop/-/merge_requests/5' -and $depBr -contains 'deploy/st' -and $hl -match 'create deploy/st \| staging \| merge \| ' -and $hl -match 'shop!12' -and $hl -match "Deploy decision: $d42" -and $hl -match 'merge 5 merge abc' -and "$(git -C "$r/origin.git" rev-parse staging)".Trim() -eq $stagingTip)
# a re-run after a cut wait (an agent shell's timeout): the open deploy MR of the env resumes: no new branch, no second MR
Set-Content "$hostLog.open" '[{"iid":7,"source_branch":"deploy/st-20260101-101010","target_branch":"staging","state":"opened","web_url":"https://h.example/g/shop/-/merge_requests/7"}]'
git -C "$r/repo" push -q origin main:refs/heads/deploy/st-20260101-101010 2>$null; Remove-Item "$hostLog.merged", $hostLog -ErrorAction SilentlyContinue; $brN = @(git -C "$r/origin.git" for-each-ref 'refs/heads/deploy/').Count
$o6r = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -WaitMinutes 1 2>&1 | Out-String; $hlr = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }
Expect "deploy merge -Mr re-run: the open deploy MR resumed and merged, no create, no new branch ($($o6r.Trim()) | $hlr)" ($o6r -match 'resumed' -and $o6r -match 'merged deploy MR https://h\.example/g/shop/-/merge_requests/7' -and $hlr -notmatch 'create' -and $hlr -match 'merge 7 ' -and @(git -C "$r/origin.git" for-each-ref 'refs/heads/deploy/').Count -eq $brN)
git -C "$r/repo" push -q origin main~1:refs/heads/deploy/st-20260101-121212 2>$null   # an open deploy MR without the newest main: stale, never merged
Set-Content "$hostLog.open" '[{"iid":8,"source_branch":"deploy/st-20260101-121212","target_branch":"staging","state":"opened"}]'; $o6s = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -WaitMinutes 1 2>&1 | Out-String
Expect "deploy merge -Mr: an open deploy MR lacking origin/main = stale, refused ($($o6s.Trim()))" ($o6s -match 'lacks origin/main \(stale\)' -and $o6s -notmatch 'merged deploy MR')
Remove-Item "$hostLog.open"
# -Commit <sha>: one main-line commit deploys (no hand-pushed pin branch); unknown or off-main commits refused
'd' | Set-Content "$r/repo/d.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: d'; git -C "$r/repo" push -q origin main 2>$null
$pinSha = "$(git -C "$r/repo" rev-parse main~1)".Trim(); $offSha = "$(git -C "$r/repo" commit-tree 'HEAD^{tree}' -m side)".Trim()
Get-ChildItem "$r/wt" -Directory -Filter 'deploymerge-*' -ErrorAction SilentlyContinue | ForEach-Object { git -C "$r/repo" worktree remove --force $_.FullName 2>$null }
Remove-Item "$hostLog.merged", $hostLog -ErrorAction SilentlyContinue
$pinOut = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Commit $pinSha.Substring(0, 10) -WaitMinutes 1 2>&1 | Out-String; $pinLog = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }
$pinBad = foreach ($bad in 'feedc0de', $offSha) { "$(pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Commit $bad 2>&1) rc=$LASTEXITCODE" }
git -C "$r/origin.git" merge-base --is-ancestor main deploy/st; $pinHasHead = -not $LASTEXITCODE; git -C "$r/origin.git" merge-base --is-ancestor $pinSha deploy/st; $pinHasPin = -not $LASTEXITCODE
Expect "deploy merge -Commit: deploy/st holds the pinned commit, not the newer main head, body names it; unknown / off-main sha exit 2 ($($pinOut.Trim()) | $($pinBad -join ' | '))" ($pinOut -match 'pinned: ' -and $pinOut -match 'merged deploy MR' -and $pinHasPin -and -not $pinHasHead -and $pinLog -match "Pinned commit: $pinSha" -and
  $pinBad[0] -match 'no such commit.*rc=2' -and $pinBad[1] -match 'is not on origin/main.*rc=2')
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
# 2026-11-24 (a monitor missed a finished deploy pipeline for 1 h): pipes -Branch -Sha polls the host until the run of that commit ends
$pbr = Invoke-PsTest 'pipes-branch' @'
$null = . $args[0] 6>$null; $global:runs = @(@(), @([pscustomobject]@{ id = 5; sha = 'aaa111'; state = 'success' }), @([pscustomobject]@{ id = 6; sha = 'abc12345ff'; state = 'running' }), @([pscustomobject]@{ id = 6; sha = 'abc12345ff'; state = 'success' })); $global:ci = 0
function Invoke-HostVerb([string]$Verb, $A, [switch]$NoMemo) { if ($Verb -ne 'ci.runs') { return @() }; $r = $global:runs[[math]::Min($global:ci, $global:runs.Count - 1)]; $global:ci++; $r }
function Start-Sleep([int]$Seconds) { }; $kp = ${function:Get-KitParam}; function Get-KitParam([string]$N) { if ($N -eq 'deploy.pipelineWaitMinutes') { $global:pw = 1 }; & $kp $N }
$po = Invoke-Pipes -Repo shop -Branch staging -Sha abc12345 2>&1; $js = @($po | Where-Object { "$_" -match '^\{' })[0] | ConvertFrom-Json
"branch:$($js.done -and $js.mrs[0].status -eq 'success' -and $global:ci -eq 4 -and $global:pw)"
$global:runs = @(, @()); $global:ci = 0; $po2 = Invoke-Pipes -Repo shop -Branch staging -Sha abc12345 -MaxMinutes 0 2>&1; $js2 = @($po2 | Where-Object { "$_" -match '^\{' })[0] | ConvertFrom-Json
"timeout:$(-not $js2.done -and $js2.mrs[0].status -eq 'no-pipeline')"
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
$rxChg = 'pipes \d\d:\d\d:\d\d shop@staging (no-pipeline|running|success)\b'; $pbrAll = ($pbr | ForEach-Object { "$_" }) -join "`n"
Expect "pipes -Branch: one stderr line per status change; past the wait a re-run hint ($([regex]::Matches($pbrAll, $rxChg).Count))" ([regex]::Matches($pbrAll, $rxChg).Count -eq 4 -and $pbrAll -match 'pipes: still no-pipeline after 0 min: run it again')
Expect-Each $pbr 'pipes -Branch -Sha: the host''s status is the truth: no run yet waits, another commit''s run ignored, ends on the run''s end state; default wait deploy.pipelineWaitMinutes; a line per change; past the wait done false + a re-run hint (#)' @('branch', 'timeout') -Show 6
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
"mrs:$((@($script:viewed | Sort-Object) -join ',') -eq 'old3,open4' -and $mq -match 'MAP   api!4 -> open4\r?\n' -and $mq -match 'api!9 -> no task' -and $nq -match 'SKIP  nil1  the tracker returned nothing')"
# K3: the full sweep is bounded (-BudgetSec): past 60% of it = 'not checked (time budget)'; progress on stderr
function Get-TrackerTask($id) { $script:viewed += $id; Start-Sleep -Milliseconds 700; [pscustomobject]@{ id = $id; name = 'n'; status = 'inProgress' } }
$script:viewed = @(); $pq1 = Invoke-MarkInTest -BudgetSec 1 | Out-String; $pv1 = @($script:viewed)
$rxBud = 'not checked \(time budget\) \('; $rxOf = 'mark-in-test: 1 of \d+ task\(s\) checked'; "budget:$($pv1.Count -eq 1 -and $pq1 -match $rxBud -and $pq1 -match $rxOf)"
# pages: a re-run goes on where the cursor stopped, never re-checks a done task; the summary says so
$script:viewed = @(); $pq2 = Invoke-MarkInTest -BudgetSec 1 | Out-String
$rxPg = '(?m)^PAGE  \d+ task\(s\) left in this sweep \(page 1, 1 done; cursor intest-cursor-all-dry\.json\): run deploy intest again'; "page:$($script:viewed[0] -and $script:viewed[0] -notin $pv1 -and $pq1 -match $rxPg)"
$cfa = Join-Path (Get-KitPath deploys) 'intest-cursor-all-dry.json'; $cf0 = Get-Content $cfa -Raw; $null = Invoke-MarkInTest -Task old3 | Out-String; "keep:$((Get-Content $cfa -Raw) -eq $cf0)"   # a -Task run keeps the pages
# a tracker with no promoted / review role (tracker.statuses.<role> null): merged work waits in inProgress, the source role
function Test-TrackerStatusOff($s) { $s -in 'promoted', 'review' }; $tq2 = Invoke-MarkInTest -Task old3 | Out-String; "minimal:$($tq2 -notmatch 'SKIP  old3  status')"
'@
$itR = Invoke-PsTest 'intest-gone' $it @($O);Expect 'deploy intest: one progress line per task on stderr' (@($itR -match '^intest \d+s task 1/').Count -gt 0)
Expect-Each $itR 'deploy intest -Apply: a task deleted in the tracker is skipped, reported and dropped; the rest go on; candidates = tracked tasks promoted in -Days, -Task any (SKIP line), -Mrs only their tasks; pages by cursor; no promoted / review role: inProgress is the source (#)' @('gone', 'scope', 'task', 'mrs', 'budget', 'page', 'keep', 'minimal')
# 2026-11-25: ~188 tasks paged 13 a call, never converging: -Env / -Mrs check only the deployed tasks; the full sweep ends in few pages
$sw = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$cfApply = Join-Path (Get-KitPath deploys) 'intest-cursor-all.json'; $cfA0 = "$(Get-Content -LiteralPath $cfApply -Raw -ErrorAction SilentlyContinue)"
$d0 = (Get-Date).ToString('o'); Update-KitTracking { param($t) foreach ($n in 1..200) { $t.tasks["s$n"] = @{ task = "s$n"; mrs = @("api!$n"); done = $true; doneAt = $d0 } } }
$script:viewed = [Collections.Generic.List[string]]::new(); function Get-TrackerTask($id) { $script:viewed.Add($id); Start-Sleep -Milliseconds 25; [pscustomobject]@{ id = $id; name = 'n'; status = 'inProgress' } }
Write-KitLog deploy-log record ([ordered]@{ target = 'stage'; mrs = @('api!150', 'api!7'); by = 'opsy' })
$eo = Invoke-MarkInTest -Env stage | Out-String; "env:$(($script:viewed -join ',') -eq 's150,s7' -and $eo -match 'MAP   api!150 -> s150')"
$no = Invoke-MarkInTest -Env other | Out-String; "norec:$($no -match 'no deploy record for other: nothing to check')"
$script:viewed.Clear(); $pg = 0; $outs = @(); do { $pg++; $po = Invoke-MarkInTest -BudgetSec 6 | Out-String; $outs += $po } while ($po -match '(?m)^PAGE ' -and $pg -lt 30)
$cfs = Get-Content (Join-Path (Get-KitPath deploys) 'intest-cursor-all-dry.json') -Raw | ConvertFrom-Json; "dry:$("$(Get-Content -LiteralPath $cfApply -Raw -ErrorAction SilentlyContinue)" -eq $cfA0)"   # a dry run never moves the -Apply cursor
"sweep:$($pg -gt 1 -and $pg -le 10 -and $script:viewed.Count -ge 200 -and @($script:viewed | Select-Object -Unique).Count -eq $script:viewed.Count -and $po -match "SWEEP done in $pg page" -and -not @($cfs.left).Count)"
'@
$swR = Invoke-PsTest 'intest-sweep200' $sw @($O)
Expect-Each $swR 'deploy intest: -Env = its deploy records'' MRs, only their tasks, deployed first; no record = a clear stop; 200 tasks: every one checked once, in 10 pages or fewer (cursor) (#)' @('env', 'norec', 'sweep', 'dry')
# deploy plan target-branch memo (from deploys.tests.ps1: its token cap)
$tbm = Join-Path (TkPath $k cache -Create) 'deployed-rows.json'; & $J @{ 'mr|jc!9' = @{ at = (Get-Date).ToString('s'); mr = @{ target_branch = 'st/a' } } } $tbm
Expect-Each (Invoke-PsTest 'tb-memo' '. $args[0]; function Invoke-HostVerb { throw }; "memo:$((Get-MrTargetBranch ''jc!9'' $null) -eq ''st/a'')"' @($O)) 'deploy plan: target branch from pokey''s cache, no host call (#)' @('memo') 3; Remove-Item $tbm
# owner 2026-11-25: deploy shape from pipeline history (parallel / serial / staggered / mixed), one poll loop for all started pipelines
$shp = @'
. $args[0]
$mk = { param($n, $p50, $p90, $min, $af = @(), $st = @(), $lk = '') [ordered]@{ name = $n; p50 = $p50; p90 = $p90; min = $min; after = @($af); strict = @($st); lock = $lk; why = @{} } }
$it = { param($s, $n) @($s.items | Where-Object { $_.name -eq $n })[0] }
$s1 = Get-KitDeployShape @((& $mk be 24 30 20), (& $mk ui 8 10 6 @('be'))) auto 0 2; $u = & $it $s1 ui
"offset:$($s1.shape -eq 'staggered' -and $u.start -eq 18 -and $u.finish -eq 26 -and $u.gates[0].kind -eq 'left' -and $u.gates[0].lead -eq 6 -and $s1.finish -eq 26 -and $s1.serial -eq 32)"
$s2 = Get-KitDeployShape @((& $mk be $null $null $null), (& $mk ui 8 10 6 @('be')), (& $mk py 5 6 4)) auto 0 2
"nohist:$((& $it $s2 ui).gates[0].kind -eq 'live' -and $null -eq (& $it $s2 ui).start -and (& $it $s2 py).start -eq 0 -and $s2.shape -eq 'mixed' -and @($s2.why -match 'no timing history').Count)"
$s3 = Get-KitDeployShape @((& $mk ui 8 10 6 @() @('be')), (& $mk be 24 30 20)) auto 0 2; $u3 = & $it $s3 ui
"strict:$($s3.items[0].name -eq 'be' -and $u3.gates[0].kind -eq 'left90' -and $u3.start -eq 26 -and $u3.finish -ge 30)"
$s4 = Get-KitDeployShape @((& $mk a 10 12 9), (& $mk b 5 6 4), (& $mk c 3 4 2)) serial 0 2
"serial:$($s4.shape -eq 'serial' -and (& $it $s4 b).start -eq 10 -and (& $it $s4 c).start -eq 15)"
$s5 = Get-KitDeployShape @((& $mk be 24 30 20), (& $mk ui 8 10 6 @('be'))) parallel 0 2; $s5b = Get-KitDeployShape @((& $mk be 24 30 20), (& $mk ui 8 10 6 @() @('be'))) parallel 0 2
"parallel:$($s5.shape -eq 'parallel' -and (& $it $s5 ui).start -eq 0 -and (& $it $s5b ui).start -eq 26)"
$s6 = Get-KitDeployShape @((& $mk a 10 12 9), (& $mk b 5 6 4)) auto 1 2
$s7 = Get-KitDeployShape @((& $mk a 10 12 9 @() @() 'db'), (& $mk b 5 6 4 @() @() 'db'), (& $mk c 3 4 2)) auto 0 2
"limits:$((& $it $s6 b).start -eq 10 -and @($s6.why -match 'maxParallel 1').Count -and (& $it $s7 b).start -eq 10 -and (& $it $s7 c).start -eq 0 -and $s7.shape -eq 'mixed' -and @($s7.why -match 'lock db').Count)"
$s8 = Get-KitDeployShape @((& $mk a 10 12 9 @('b')), (& $mk b 5 6 4 @('a'))) auto 0 2; "cycle:$(@($s8.items).Count -eq 2 -and @($s8.why -match '^cycle').Count)"
'@
Expect-Each (Invoke-PsTest 'deploy-shape' $shp @($O)) 'deploy schedule shape: # (offsets from history, no-history fallback, strict order, serial / parallel modes, maxParallel + lock, cycle)' @('offset', 'nohist', 'strict', 'serial', 'parallel', 'limits', 'cycle') 12
Set-JsonFile $kl @{ deploy = @{ schedule = @{ marginMinutes = 2 } }; repos = @(
    @{ name = 'be'; checkout = "$r/repo"; role = 'producer'; deploys = @(@{ target = 'st'; branch = 'deploy/st'; job = 'deploy*' }) },
    @{ name = 'ui'; checkout = "$r/repo"; role = 'consumer'; deploys = @(@{ target = 'st'; branch = 'deploy/st' }) },
    @{ name = 'app'; checkout = "$r/repo"; role = 'consumer'; deploys = @(@{ target = 'st'; ssh = @{ host = 'u@h' } }) }) }
$wch = @'
. $args[0]
$t0 = [datetimeoffset]'2026-11-01T10:00:00Z'; $script:live = @{}; $script:jh = 0
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
  $rn = "$($A.repo)" -split '/' | Select-Object -Last 1; $len = @{ be = @(20, 24, 30); ui = @(7, 8, 10) }[$rn]
  if ($Verb -eq 'ci.runs') {
    if ($script:live[$rn]) { return @([pscustomobject]@{ id = "$rn-live"; sha = $script:live[$rn].sha; status = $script:live[$rn].st; created_at = $t0.ToString('o'); updated_at = $t0.AddMinutes(9).ToString('o') }) }
    return @(foreach ($n in 0..2) { [pscustomobject]@{ id = "$rn-$n"; sha = "s$rn$n"; status = 'success'; created_at = $t0.AddDays(-$n).ToString('o'); updated_at = $t0.AddDays(-$n).AddMinutes($len[$n]).ToString('o') } }) }
  if ($Verb -eq 'ci.jobs') { $script:jh++; $n = if ("$($A.id)" -match '-(\d)$') { [int]$Matches[1] } else { 0 }; $L = $len[[math]::Min(2, [math]::Max(0, $n))]
    return @([pscustomobject]@{ id = 1; name = 'build'; stage = 'build'; status = 'success'; finished_at = $t0.AddDays(-$n).AddMinutes($L - 5).ToString('o') }, [pscustomobject]@{ id = 2; name = 'deploy-st'; stage = 'deploy'; status = 'success'; finished_at = $t0.AddDays(-$n).AddMinutes($L).ToString('o') }) }
}
$tm = Get-KitDeployTiming be ([pscustomobject]@{ target = 'st'; branch = 'deploy/st'; job = 'deploy*' }); $h2 = @(Get-KitDeployHistory be ([pscustomobject]@{ target = 'st'; branch = 'deploy/st'; job = 'deploy*' }))
"history:$($tm.n -eq 3 -and $tm.p50 -eq 24 -and $tm.p90 -eq 30 -and $tm.min -eq 20 -and $tm.build -eq 19 -and $tm.deploy -eq 5 -and $tm.basis -eq '3 run(s): 3 host' -and $script:jh -eq 3 -and $h2[0].sha -eq 'sbe0' -and $h2[-1].sha -eq 'sbe2' -and $h2[0].at -match '^2026-11-01T')"
Write-KitLog deploy-log timing ([ordered]@{ target = 'st'; repo = 'app'; sha = 'x1'; status = 'success'; totalMin = 4 })
@{ id = 'd-1'; answer = 'yes' } | ConvertTo-Json | Set-Content (Join-Path (Get-KitPath decisions -Create) 'd-1.json')   # a recorded word (an unknown id is refused)
$so = Invoke-DeploySchedule @('st') @('be!1', 'ui!2', 'app!3') @() @() @() '' 'd-1' | Out-String
"plan:$($so -match 'SHAPE staggered' -and $so -match 'ui -> st: start \+18 · finish \+26 · p50 8 / p90 10 min' -and $so -match 'basis 1 run\(s\): 1 log' -and $so -match 'WHY  ui after be \(repos\[\]\.role producer -> consumer\)' -and $so -match 'build 19, deploy 5')"
$sf = Join-Path (Get-KitPath deploys) 'schedule-st.json'; $age = { param($n, $m) $d = Get-Content $sf -Raw | ConvertFrom-Json -AsHashtable; @($d.items | Where-Object { $_.name -eq $n })[0].startedAt = (Get-Date).AddMinutes(-$m).ToString('o'); Write-KitAtomic $sf ($d | ConvertTo-Json -Depth 6 -Compress) }
$script:live.be = @{ sha = 'aaa111'; st = 'running' }
$w1 = Invoke-DeployWatch @('st') @('be=aaa111') @() 0 | Out-String; & $age be 40; $w2 = Invoke-DeployWatch @('st') @() @() 0 | Out-String; & $age be 20; $w3 = Invoke-DeployWatch @('st') @() @() 0 | Out-String
"gate:$($w1 -match 'WAIT ui: be has ~24 min left \(start at <= 6\)' -and $w2 -match 'REPLAN be runs 40 min, past its p90 30' -and $w3 -match 'START ui -> st now .*deploy merge -Repo .* -To st -Mr -Mrs ui!2 -Decision d-1' -and $w3 -notmatch 'START app')"
$script:live.ui = @{ sha = 'bbb222'; st = 'running' }; $script:live.be.st = 'failed'
$w4 = Invoke-DeployWatch @('st') @('ui=bbb222') @() 0 | Out-String; $script:live.ui.st = 'success'; $w5 = Invoke-DeployWatch @('st') @() @() 0 | Out-String
$tl = @(Read-KitLog deploy-log | Where-Object { $_.event -eq 'timing' -and $_.repo -eq 'ui' })[-1]
$rs = Invoke-DeploySchedule @('st') @('be!1') @() @() @() '' '' | Out-String; $rs2 = Invoke-DeploySchedule @('st') @('be!1', 'app!3') @() @() @() '' '' | Out-String
$d = Get-Content $sf -Raw | ConvertFrom-Json -AsHashtable; foreach ($x in $d.items) { $x.lock = 'db'; $x.gates = @() }; Write-KitAtomic $sf ($d | ConvertTo-Json -Depth 6 -Compress)
$wl = Invoke-DeployWatch @('st') @() @() 0 | Out-String; $d = Get-Content $sf -Raw | ConvertFrom-Json -AsHashtable; @($d.items | Where-Object { $_.name -eq 'be' })[0].status = 'running'; Write-KitAtomic $sf ($d | ConvertTo-Json -Depth 6 -Compress)
"guards:$($rs -match 'SHAPE single' -and @([regex]::Matches($wl, '(?m)^START ')).Count -eq 1 -and $wl -match 'WAIT app: lock db held by be')"
"loop:$($w4 -match 'FAILED be -> st after 9 min: opsy step 6 for this target only' -and $w4 -match 'HELD app: its producer be failed' -and $w4 -notmatch 'HELD ui' -and $w5 -match 'DONE ui -> st in 9 min \(predicted 8, p90 10: on time\): verify it now' -and $w5 -match 'watch: 1 failed, 1 success, 1 held|watch: .*all finished' -and $tl.predictedMin -eq 8 -and $tl.totalMin -eq 9)"
'@
$cliW = pwsh @np $O deploy watch -Env nope 2>&1 | Out-String; $cliS = pwsh @np $O deploy schedule -Env st -Repo ui,app -Mode serial -After app=ui 2>&1 | Out-String
Expect "deploy schedule / watch from the CLI: no schedule = a clear stop; -Repo / -Mode / -After bind ($($cliS.Trim()))" ($cliW -match 'no schedule for nope: run bossy.ps1 deploy schedule' -and $cliS -match 'SHAPE serial \(mode serial\): ui, then app' -and $cliS -match 'WHY  app after ui \(-After\)')
Expect-Each (Invoke-PsTest 'deploy-watch' $wch @($O)) 'deploy schedule + watch: # (host history p50 / p90 + build / deploy split, cached; log history; saved plan text; gates replan; a lock starts one per pass; one loop: a failure holds its dependents only, done = verify, actual vs predicted logged)' @('history', 'plan', 'gate', 'guards', 'loop') 20
$cliR = pwsh @np $O deploy schedule -Env st -Mrs be!1 2>&1 | Out-String; $cliN = pwsh @np $O deploy watch -Env st -Started be 2>&1 | Out-String; $cliF = pwsh @np $O deploy watch -Env st -Finished app=ok 2>&1 | Out-String
Expect "deploy schedule refuses while a target runs; watch -Started without a sha / -Finished other than success|failed = usage ($($cliR.Trim()))" ($cliR -match 'be still running in schedule-st\.json' -and $cliN -match '-Started be needs =<merge sha>' -and $cliF -match '-Finished app=ok: use success or failed')
# full mode (owner 2026-11-27): an unpinned word saying full; a negation or a pin is no full
$fullWord = @'
. (Join-Path $args[0] 'skills/crafty/lib.ps1')
$as = 'full deployment', 'deploy st full', 'yes, full', 'not full', 'full !6', 'no full deploy', 'yes, NOT  full', 'yes in full', 'yes, full stop', 'yes, fully tested', 'yes'
"$(($as | ForEach-Object { [int](Get-KitDeployWordPin @{ answer = $_ }).full }) -join '')|$(Format-KitWordPin @{ answer = 'full' })"
'@
$fwOut = "$(Invoke-PsTest 'full-word' $fullWord @($k))"
Expect "deploy word full: mode full only for an unpinned, un-negated 'full' (WORD line '| mode: full') ($fwOut)" ($fwOut -eq '11100000000| | mode: full')
Remove-Item Env:CLAUDE_WT_ROOT
Remove-TestKit $k
Complete-Tests
