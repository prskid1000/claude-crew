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
$r = @{ v = Get-TrackerTask 'o/r#5'; s = Set-TrackerStatus 'o/r#5' inTest; c = Add-TrackerComment 'o/r#5' 'two words'; n = New-TrackerTask -List o/r -Name 'New one' -Description "Problem: p`nGoal: g`nItems: A1`nAcceptance: a`nLinks: l" -Parent 'o/r#5' -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks o/r inTest) }
"tracker:$($r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.v.subtasks[0].status -eq 'closed' -and $r.v.parent -eq '1' -and $r.n.id -eq 9 -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq 'ann')"
$global:fx = [ordered]@{ 'view 5 -R o/r --json comments' = '{"comments":[{"author":{"login":"a"},"createdAt":"2026-01-01T00:00:00Z","body":"old","url":"https://github.com/o/r/issues/5#issuecomment-77"}]}'
 'api -X PATCH repos/o/r/issues/comments/77 .*new words' = '{"id":77}'; 'api -X DELETE repos/o/r/issues/comments/77' = '' }; $global:log.Clear()
$c = @(Get-TrackerComments 'o/r#5'); $e = __TrA 'comment-edit' @{ id = 'o/r#5'; comment = $c[0].id; text = 'new words' }; $x = __TrA 'comment-delete' @{ id = 'o/r#5'; comment = $c[0].id }
"cmt:$($c[0].id -eq '77' -and $e -match 'edited' -and $x -match 'deleted' -and $global:log.Count -eq 3)"
'@
Expect-Each (Invoke-PsTest 'github-tracker' $tb @(Join-Path $k 'skills/crafty/lib.ps1')) 'github #: view, status, comment, create, list; comment ids, edit, delete on recorded answers' 'tracker', 'cmt'
$env:KIT_TRACKER_TYPE = 'github'; 'body text' | Set-Content "$(Kd)/c.md"
$out = pwsh @np $D tracker comment o/r#12 -File "$(Kd)/c.md" -Kind comment-status -ProseOk x -DryRun 6>&1 2>&1 | Out-String
Remove-Item Env:KIT_TRACKER_TYPE
Expect 'github: tracker comment -File sends the file as the body' ($out -match 'issue comment 12 -R o/r --body "body text')
Remove-TestKit $k
Complete-Tests
