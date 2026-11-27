#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/github.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/github.tests.ps1: github on recorded gh answers (gh mocked). Usage: pwsh -NoProfile -File tests/github.tests.ps1
#   (or pwsh -NoProfile -File tests/github.tests.ps1 next to a copy of tests/harness.ps1) -> a PASS / FAIL line per check; exit 1 on a failure
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/github.ps1')   # copied into every New-TestKit kit
$k = New-TestKit github; $D = Join-Path $k 'skills/crafty/crafty.ps1'
$gh = @'
$script:calls = [Collections.Generic.List[string]]::new()
function gh { $script:calls.Add("gh $($args -join ' ')"); $global:LASTEXITCODE = 0; $p = "$($args[1])"; if ("$args" -match '-X PUT') { return '{}' }
 switch -Regex ($p) {
  'pulls/7/files' { '[{"filename":"a.txt"},{"filename":"b.txt","previous_filename":"old.txt"}]'; break }
  'pulls/7$' { '{"number":7,"state":"open","head":{"ref":"f/x","sha":"abc"},"base":{"ref":"main"},"mergeable":false,"mergeable_state":"dirty"}'; break }
  'pulls/8$' { '{"number":8,"state":"closed","merged_at":"2026-10-15T10:00:00Z","head":{"ref":"f/y"},"base":{"ref":"main"},"merge_commit_sha":"m8"}'; break }
  'pulls\?state' { '[{"number":7,"state":"open","head":{"ref":"f/x"},"base":{"ref":"main"}},{"number":9,"state":"open","head":{"ref":"f/z"},"base":{"ref":"main"}}]'; break }
  'abc/check-runs' { '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/11/job/3"}]}'; break }
  'zzz/status$' { '{"statuses":[{"state":"pending","context":"jenkins"}]}'; break }
  'branches/main/protection' { '{"allow_force_pushes":{"enabled":false},"allow_deletions":{"enabled":false}}'; break }
  'branches/release/protection' { '{"allow_force_pushes":{"enabled":true},"allow_deletions":{"enabled":false}}'; break }
  'branches/(new|locked)/protection' { $global:LASTEXITCODE = 1; Write-Error $(if ($Matches[1] -eq 'new') { 'gh: Branch not protected (HTTP 404)' } else { 'gh: Not Found (HTTP 404)' }); break }
  'compare/' { '{"merge_base_commit":{"sha":"base1"},"files":[{"filename":"a.txt"}]}'; break }
  'actions/runs\?' { '{"workflow_runs":[{"id":11,"head_sha":"m8","created_at":"2026-10-15T11:00:00Z","conclusion":"success"}]}'; break }
  'actions/runs/11/jobs' { '{"jobs":[{"id":3,"name":"deploy-staging","conclusion":"success","completed_at":"2026-10-15T11:05:00Z"}]}'; break }
  default { '{}' } } }
. $args[0]; . (Join-Path (Split-Path $args[0]) 'adapters/github.ps1')   # a vendor adapter loads when config names it; this test names none
$script:HostType = 'github'
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/7'; "gh-mr:$($m.iid -eq 7 -and $m.state -eq 'opened' -and $m.source_branch -eq 'f/x' -and $m.has_conflicts -and $m.head_pipeline.status -eq 'failed' -and $m.head_pipeline.id -eq '11')"
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'; "gh-merged:$($m.state -eq 'merged' -and $m.merge_commit_sha -eq 'm8')"
$c = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/changes'; "gh-changes:$(@($c.changes).Count -eq 2 -and $c.changes[1].old_path -eq 'old.txt')"
$b = Invoke-HostApi 'projects/o%2Fr/repository/merge_base?refs[]=abc&refs[]=staging'; "gh-base:$($b.id -eq 'base1')"
$p = @(Invoke-HostApi 'projects/o%2Fr/pipelines?ref=staging&per_page=10'); $j = @(Invoke-HostApi "projects/o%2Fr/pipelines/$($p[0].id)/jobs?per_page=100"); "gh-runs:$($p[0].sha -eq 'm8' -and $j[0].name -eq 'deploy-staging' -and $j[0].status -eq 'success')"
$null = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/merge' -Method PUT -Fields @{ merge_when_pipeline_succeeds = 'true' }; "gh-auto:$(@($script:calls | ? { $_ -like 'gh pr merge 7 -R o/r --squash --delete-branch --auto' }).Count -eq 1)"
$l = @(Invoke-HostVerb 'mr.list' @{ repo = 'o/r'; state = 'opened'; source_branch = 'f/z' }); "gh-list-head:$($l.Count -eq 1 -and $l[0].iid -eq 9)"
$s = Invoke-HostVerb 'ci.status' @{ repo = 'o/r'; sha = 'zzz' } -NoMemo; "gh-status-external:$($s.status -eq 'pending')"
$pm = Invoke-HostVerb 'branch.protect' @{ repo = 'o/r'; branch = 'main' } -NoMemo; $px = Invoke-HostVerb 'branch.protect' @{ repo = 'o/r'; branch = 'release' } -NoMemo; $pn = Invoke-HostVerb 'branch.protect' @{ repo = 'o/r'; branch = 'new' } -NoMemo; $pl = Invoke-HostVerb 'branch.protect' @{ repo = 'o/r'; branch = 'locked' } -NoMemo
"gh-protect:$($pm -eq 'ok' -and $px -like 'failed: protected but force push*' -and $pn -eq 'set' -and $pl -like 'skip: no admin rights*' -and @($script:calls -match 'PUT repos/o/r/branches/new/protection').Count)"
$null = Invoke-HostVerb 'mr.merge' @{ repo = 'o/r'; n = 7; method = 'merge' }; "gh-deploy-merge:$(@($script:calls | ? { $_ -like 'gh pr merge 7 -R o/r --merge*' -and $_ -notlike '*--squash*' }).Count -eq 1)"
'@
$res = Invoke-PsTest 'github-host' $gh @(Join-Path $k 'skills/crafty/lib.ps1')
Expect-Each $res 'github host: #' 'gh-mr', 'gh-merged', 'gh-changes', 'gh-base', 'gh-runs', 'gh-auto', 'gh-list-head', 'gh-status-external', 'gh-protect', 'gh-deploy-merge'
# tracker on recorded answers (an unknown call fails)
$tb = @'
. $args[0]; . (Join-Path (Split-Path $args[0]) 'adapters/github.ps1'); $global:log = [Collections.Generic.List[string]]::new(); $__trRepo = 'g/p'
function Fx($call) { $global:log.Add($call); foreach ($k in $global:fx.Keys) { if ($call -match $k) { return $global:fx[$k] } }; throw "404 no fixture: $call" }
function gh { $i = [array]::IndexOf($args, '--input'); $global:LASTEXITCODE = 0; Fx "$($args -join ' ') $(if ($i -ge 0) { gc $args[$i + 1] -Raw })" }
Initialize-KitTracker -Type github
$global:fx = [ordered]@{ 'assignees,body' = '{"number":5,"title":"Bug","state":"OPEN","labels":[{"name":"status:In Progress"}],"body":"Part of #1\n- [ ] #6"}'
 'view 6 ' = '{"number":6,"title":"Sub","state":"CLOSED","labels":[]}'; 'view 5 .*state,labels' = '{"state":"OPEN","labels":[{"name":"status:In Progress"}]}'; 'view 5 .*json body' = '{"body":"x"}'
 '^label create' = ''; 'edit 5 -R o/r --remove-label status:In Progress --add-label status:in test' = 'ok'; 'comment 5 -R o/r --body-file' = 'https://github.com/o/r/issues/5#c1'
 'create -R o/r --title New one --assignee Ann Lee --label priority:high' = 'https://github.com/o/r/issues/9'; '^issue edit 5 -R o/r --body-file' = 'ok'; 'list -R o/r .*--label status:in test' = '[{"number":7,"title":"A","assignees":[{"login":"ann"}]}]' }
$r = @{ v = Get-TrackerTask 'o/r#5'; s = Set-TrackerStatus 'o/r#5' inTest -Deployed deploy-intest; c = Add-TrackerComment 'o/r#5' 'two words'; n = New-TrackerTask -List o/r -Name 'New one' -Description "Problem: p`nGoal: g`nItems: A1`nAcceptance: a`nLinks: l" -Parent 'o/r#5' -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks o/r inTest) }
"tracker:$($r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.v.subtasks[0].status -eq 'closed' -and $r.v.parent -eq '1' -and $r.n.id -eq 9 -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq 'ann')"
$global:fx = [ordered]@{ 'view 5 -R o/r --json comments' = '{"comments":[{"author":{"login":"a"},"createdAt":"2026-01-01T00:00:00Z","body":"old","url":"https://github.com/o/r/issues/5#issuecomment-77"}]}'
 'api -X PATCH repos/o/r/issues/comments/77 .*new words' = '{"id":77}'; 'api -X DELETE repos/o/r/issues/comments/77' = '' }; $global:log.Clear()
$c = @(Get-TrackerComments 'o/r#5'); $e = __TrA 'comment-edit' @{ id = 'o/r#5'; comment = $c[0].id; text = 'new words' }; $x = __TrA 'comment-delete' @{ id = 'o/r#5'; comment = $c[0].id }
"cmt:$($c[0].id -eq '77' -and $e -match 'edited' -and $x -match 'deleted' -and $global:log.Count -eq 3)"
$global:fx = [ordered]@{ 'view 5 -R o/r --json body' = '{"body":"x\n- [ ] #6"}'; '^issue edit 5 -R o/r --body-file' = 'ok'; '^issue transfer 8 o/r2 -R o/r' = 'https://github.com/o/r2/issues/1' }; $global:log.Clear()
$m1 = Move-TrackerTask 'o/r#8' -Parent 'o/r#5'; $m2 = Move-TrackerTask 'o/r#6' -Parent 'o/r#5'; $m3 = Move-TrackerTask 'o/r#8' -List o/r2; $mt = try { Move-TrackerTask 'o/r#8' -Top; 'no throw' } catch { "$_" }
"mv:$($m1 -eq 'moved #8 under #5' -and @($global:log -match '^issue edit 5').Count -eq 1 -and $m2 -eq 'moved #6 under #5' -and $m3 -match '^moved #8 to o/r2' -and $mt -match 'task-list line on its parent')"
'@
Expect-Each (Invoke-PsTest 'github-tracker' $tb @(Join-Path $k 'skills/crafty/lib.ps1')) 'github #: view, status, comment, create, list; comment ids, edit, delete; move (task-list line once, transfer, top refused) on recorded answers' 'tracker', 'cmt', 'mv'
$env:KIT_TRACKER_TYPE = 'github'; 'body text' | Set-Content "$(Kd)/c.md"
$out = pwsh @np $D tracker comment o/r#12 -File "$(Kd)/c.md" -Kind comment-status -ProseOk x -DryRun 6>&1 2>&1 | Out-String
Remove-Item Env:KIT_TRACKER_TYPE
Expect 'github: tracker comment -File sends the file as the body' ($out -match 'issue comment 12 -R o/r --body "body text')
# (cap move) a CI task with a job and a run link: github's run id is read too
$gp = "$(Invoke-PsTest 'github-ciurl' @'
$null = . $args[0] 6>$null; . (Join-Path (Split-Path $args[0]) 'adapters/github.ps1')
@(foreach ($tx in 'job `unit` of [run](https://github.com/o/r/actions/runs/77)', 'https://github.com/o/r/actions/runs/77/job/9') { $u = Invoke-KitAdapter ci github parseUrl @{ text = $tx }; "$($u.run)/$($u.job)" }) -join ' '
'@ @(Join-Path $k 'skills/crafty/lib.ps1') | Select-Object -Last 1)"
Expect "github ci.parseUrl: a run link alone gives the run, a job URL the run and the job ($gp)" ($gp -eq '77/ 77/9')
# parity natives (recorded gh answers, no account): #7 / GH-7 refs in the repo; ci.failure by GitHub's job conclusion, failed step, annotations
$gn = "$(Invoke-PsTest 'github-natives' @'
$null = . $args[0] 6>$null; . (Join-Path (Split-Path $args[0]) 'adapters/github.ps1'); $script:HostType = 'github'
function gh { $global:LASTEXITCODE = 0; switch -Regex ("$($args[1])") {
  'runs/5/jobs' { '{"jobs":[{"id":30,"name":"lint","conclusion":"success"},{"id":31,"name":"unit","conclusion":"timed_out","html_url":"https://github.com/o/r/actions/runs/5/job/31","steps":[{"name":"setup","conclusion":"success"},{"name":"test","conclusion":"timed_out"}]}]}'; break }
  'check-runs/31/annotations' { '[{"annotation_level":"warning","path":"a.js","start_line":1,"message":"w"},{"annotation_level":"failure","path":"t/x.test.js","start_line":9,"message":"expected 2"}]'; break }
  'jobs/31/logs$' { "ok`nERROR: from log"; break }
  default { '{}' } } }
$f = Invoke-HostVerb 'ci.failure' @{ repo = 'o/r'; id = 5 }; $p = @('#7', 'GH-8', 'o/r2#9' | ForEach-Object { $x = Invoke-HostVerb 'mr.parseRef' @{ ref = $_; repo = 'o/r' }; "$($x.repo)!$($x.n)" })
"$($f.job)|$($f.id)|$($f.reason)|$($f.step)|$($f.url)|$($f.excerpt)|$($p -join ',')|$($null -eq (Invoke-HostVerb 'mr.parseRef' @{ ref = '#7' }))"
'@ @(Join-Path $k 'skills/crafty/lib.ps1') | Select-Object -Last 1)"
Expect "github natives: ci.failure = the timed-out job, its step, the failure annotation; mr.parseRef #7 / GH-8 in the repo, owner/repo#9 as core, no repo = none ($gn)" ($gn -eq 'unit|31|timeout|test|https://github.com/o/r/actions/runs/5/job/31|t/x.test.js:9 expected 2|o/r!7,o/r!8,o/r2!9|True')
# inTest only after a deploy (owner 2026-11-27: "for test" set on merged work): refusals, the raw-name echo, the allowed paths, the parent rollup
$ki = New-TestKit intest; $envWas = $env:KIT_TRACKER_TYPE; $env:KIT_TRACKER_TYPE = 'none'; $Dc = Join-Path $ki 'skills/crafty/crafty.ps1'
[IO.File]::WriteAllText((Join-Path $ki 'skills/crafty/kit.local.json'), '{"tracker":{"statuses":{"inTest":["in test","for test"]}}}')
$it1 = (pwsh @np $Dc tracker create -Key qa-fx-tracker-intest -List L1 -Name 'T intest' -Description 'd' | ConvertFrom-Json).id
$null = pwsh @np $Dc tracker status $it1 review; $null = pwsh @np $Dc tracker status $it1 promoted
$itRaw = pwsh @np $Dc tracker status $it1 'for test' 2>&1 | Out-String; $itRawCode = $LASTEXITCODE
$itKey = pwsh @np $Dc tracker status $it1 inTest 2>&1 | Out-String
$itFake = pwsh @np $Dc tracker status $it1 inTest -Deployed deploy-intest 2>&1 | Out-String
$itNone = pwsh @np $Dc tracker status $it1 inTest -Deployed nosuch 2>&1 | Out-String
$itSt1 = (pwsh @np $Dc tracker view $it1 | ConvertFrom-Json).status
Expect "tracker status inTest or a raw alias ('for test') without a deploy: refused with the promoted hint, exit non-zero, task stays promoted; -Deployed deploy-intest from the CLI or an unknown record: refused ($itSt1)" ($itRawCode -ne 0 -and $itSt1 -eq 'promoted' -and @($itRaw, $itKey, $itFake, $itNone | Where-Object { $_ -match 'inTest only after a deploy: use promoted for merged work' }).Count -eq 4)
$itLib = pwsh -NoProfile -Command ". '$(Join-Path $ki 'skills/crafty/lib.ps1')'; try { Set-TrackerStatus '$it1' 'inTest' } catch { `$_.Exception.Message }; try { Set-TrackerStatus '$it1' 'inTest' -Deployed deploy-intest } catch { 'raised' }; (Get-TrackerTask '$it1').status" 2>&1 | Out-String
Expect "Set-TrackerStatus: no proof refused, the internal deploy-intest proof (deploy intest) allowed ($($itLib.Trim() -replace '\s+', ' '))" ($itLib -match 'inTest only after a deploy' -and $itLib -notmatch 'raised' -and $itLib -match 'in test')
Add-TestDeployRecord $ki 'stage'
$it2 = (pwsh @np $Dc tracker create -Key qa-fx-tracker-intest2 -List L1 -Name 'T intest 2' -Description 'd' | ConvertFrom-Json).id
$itForge = pwsh @np $Dc tracker status $it2 inTest -Deployed ' Deploy-Intest ' 2>&1 | Out-String
$itOk = pwsh @np $Dc tracker status $it2 inTest -Deployed stage 2>&1 | Out-String; $itSt2 = (pwsh @np $Dc tracker view $it2 | ConvertFrom-Json).status
Expect "tracker status inTest -Deployed <a recorded deploy target>: allowed, task in test; the internal proof padded or in other case from the CLI: refused ($itSt2)" ($itOk -notmatch 'only after a deploy' -and $itSt2 -eq 'in test' -and $itForge -match 'only after a deploy')
$itEcho = pwsh @np $Dc tracker status $it1 'failed testing' 2>&1 | Out-String
Expect "a raw board name prints the kit role it maps to ($($itEcho.Trim()))" ($itEcho -match "'failed testing' -> failedTesting")
$ip = (pwsh @np $Dc tracker create -Key qa-fx-tracker-intest-p -List L1 -Name 'P intest' -Description 'd' | ConvertFrom-Json).id
$ic = (pwsh @np $Dc tracker create -Key qa-fx-tracker-intest-c -List L1 -Name 'C intest' -Description 'd' -Parent $ip | ConvertFrom-Json).id
$null = pwsh @np $Dc tracker status $ic review; $null = pwsh @np $Dc tracker status $ic promoted; $null = pwsh @np $Dc tracker status $ic 'for test' 2>&1
$ipSt = (pwsh @np $Dc tracker view $ip | ConvertFrom-Json).status; $icSt = (pwsh @np $Dc tracker view $ic | ConvertFrom-Json).status
Expect "a child refused for inTest leaves its parent out of inTest too ($ipSt / $icSt)" ($ipSt -ne 'in test' -and $icSt -eq 'promoted')
$env:KIT_TRACKER_TYPE = $envWas; Remove-TestKit $ki
Remove-TestKit $k
Complete-Tests
