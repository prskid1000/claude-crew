#Requires -Version 7
<#
devkit.tests.ps1: dev.ps1 wt / check / gate / guard, lib.ps1 git host + tracker adapters, devtools.py.
Usage: pwsh -NoProfile -File <kit>/tests/devkit.tests.ps1 (or tests/kit-tests.ps1 -Area devkit).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit dev; $D = Join-Path $k 'skills/dev-kit/dev.ps1'; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
$r = Join-Path (Kd) 'git'; New-Item -ItemType Directory -Force "$r/outer/inner" | Out-Null
$env:CLAUDE_WT_ROOT = "$r/wt"; foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
try {
  git -C "$r/outer" init -q; git -C "$r/outer" commit -q --allow-empty -m init
  'x' | Set-Content "$r/outer/stray.txt"; 'y' | Set-Content "$r/outer/inner/a.txt"
  $out = pwsh @np $D wt commit -Dir "$r/outer/inner" -Message m 2>&1 | Out-String
  Expect 'wt commit refuses a plain subfolder' ($LASTEXITCODE -ne 0 -and $out -match 'not the top of a git worktree' -and -not (git -C "$r/outer" diff --cached --name-only))
  'feat: from file' | Set-Content "$r/msg.txt"
  Push-Location "$r/outer"; $null = pwsh @np $D wt commit -MessageFile "$r/msg.txt" 2>&1; $code = $LASTEXITCODE; Pop-Location
  Expect 'wt commit -MessageFile from the current folder' ($code -eq 0 -and (git -C "$r/outer" log -1 --format=%s) -eq 'feat: from file')
} finally { Remove-Item Env:CLAUDE_WT_ROOT -ErrorAction SilentlyContinue }
# git-host + ci adapters: glab/gh replies, type command, MR URLs
$gh = @'
$script:calls = [Collections.Generic.List[string]]::new()
function glab { $script:calls.Add("glab $($args -join ' ')"); $global:LASTEXITCODE = 0; '{"iid":5,"state":"merged"}' }
function gh { $script:calls.Add("gh $($args -join ' ')"); $global:LASTEXITCODE = 0; $p = "$($args[1])"
 switch -Regex ($p) {
  'pulls/7/files' { '[{"filename":"a.txt"},{"filename":"b.txt","previous_filename":"old.txt"}]'; break }
  'pulls/7$' { '{"number":7,"state":"open","head":{"ref":"f/x","sha":"abc"},"base":{"ref":"main"},"mergeable":false,"mergeable_state":"dirty"}'; break }
  'pulls/8$' { '{"number":8,"state":"closed","merged_at":"2026-10-15T10:00:00Z","head":{"ref":"f/y"},"base":{"ref":"main"},"merge_commit_sha":"m8"}'; break }
  'pulls\?state' { '[{"number":7,"state":"open","head":{"ref":"f/x"},"base":{"ref":"main"}},{"number":9,"state":"open","head":{"ref":"f/z"},"base":{"ref":"main"}}]'; break }
  'abc/check-runs' { '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/11/job/3"}]}'; break }
  'zzz/status$' { '{"statuses":[{"state":"pending","context":"jenkins"}]}'; break }
  'compare/' { '{"merge_base_commit":{"sha":"base1"},"files":[{"filename":"a.txt"}]}'; break }
  'actions/runs\?' { '{"workflow_runs":[{"id":11,"head_sha":"m8","created_at":"2026-10-15T11:00:00Z","conclusion":"success"}]}'; break }
  'actions/runs/11/jobs' { '{"jobs":[{"id":3,"name":"deploy-staging","conclusion":"success","completed_at":"2026-10-15T11:05:00Z"}]}'; break }
  default { '{}' } } }
. $args[0]
$script:http = [Collections.Generic.List[object]]::new(); $script:gtMerged = $false
$fx = [ordered]@{
 'GET .*bitbucket.*/pullrequests/12$' = '{"id":12,"title":"x","state":"OPEN","source":{"branch":{"name":"f/x"},"commit":{"hash":"abc123def456"}},"links":{"html":{"href":"https://bitbucket.org/ws/bbrepo/pull-requests/12"}}}'
 'GET .*bitbucket.*/commit/abc123def456/statuses' = '{"values":[{"state":"INPROGRESS","key":"build","url":"https://bitbucket.org/ws/bbrepo/pipelines/results/41"}]}'
 'GET .*bitbucket.*/pullrequests\?' = '{"values":[{"id":12,"title":"x","state":"OPEN","source":{"branch":{"name":"f/x"},"commit":{"hash":"abc123def456"}}}]}'
 'GET .*bitbucket.*/pipelines\?' = '{"values":[{"uuid":"{p-1}","state":{"name":"COMPLETED","result":{"name":"FAILED"}},"target":{"commit":{"hash":"abc123def456"}}}]}'
 'GET .*bitbucket.*/pipelines/%7Bp-1%7D/steps' = '{"values":[{"uuid":"{s-1}","name":"test","state":{"name":"COMPLETED","result":{"name":"FAILED"}}}]}'
 'GET .*dev.azure.com/org/proj/_apis/git/repositories/azrepo/pullrequests/5\?' = '{"pullRequestId":5,"title":"t","status":"active","sourceRefName":"refs/heads/f/x","lastMergeSourceCommit":{"commitId":"aaa"},"mergeStatus":"conflicts","repository":{"webUrl":"https://dev.azure.com/org/proj/_git/azrepo"}}'
 'GET .*refs/pull/5/merge' = '{"count":1,"value":[{"id":77,"status":"completed","result":"succeeded"}]}'
 'GET .*/org/_apis/connectionData' = '{"authenticatedUser":{"id":"u-1"}}'
 'PATCH .*pullrequests/5\?' = '{"pullRequestId":5,"status":"active","autoCompleteSetBy":{"id":"u-1"},"sourceRefName":"refs/heads/f/x","repository":{"webUrl":"https://dev.azure.com/org/proj/_git/azrepo"}}'
 'GET .*/repos/o/gtrepo/commits/ggg/status' = '{"state":"success","statuses":[{"status":"success","context":"ci"}]}'
 'GET .*/repos/o/gtrepo/compare/main...ggg' = '{"total_commits":0,"commits":[],"files":[]}'
 'GET .*ci.example/job/jkrepo/job/f%252Fx/api/json' = '{"builds":[{"number":9,"result":null,"building":true,"actions":[{},{"lastBuiltRevision":{"SHA1":"jjj"}}]}]}'
}
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) {
 $script:http.Add([pscustomobject]@{ m = $Method; u = $Uri; b = $Body; h = $Headers })
 if ($Uri -match '/repos/o/gtrepo/pulls/3/merge') { $script:gtMerged = $true; return $null }
 if ($Uri -match '/repos/o/gtrepo/pulls/3$') { return ('{"number":3,"title":"t","state":"' + $(if ($script:gtMerged) { 'closed","merged":true,"merged_at":"2026-10-15T12:00:00Z"' } else { 'open","merged":false' }) + ',"head":{"ref":"f/x","sha":"ggg"},"base":{"ref":"main"},"mergeable":true,"html_url":"https://git.example/o/gtrepo/pulls/3"}') | ConvertFrom-Json }
 foreach ($k in $fx.Keys) { if ("$Method $Uri" -match $k) { return ($fx[$k] | ConvertFrom-Json) } }
 $null
}
$script:HostType = 'gitlab'
$m = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; "gl-get:$($script:calls[-1] -eq 'glab api projects/g%2Fr/merge_requests/5' -and $m.state -eq 'merged')"
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5/merge' -Method PUT -Fields @{ squash = 'true' }; "gl-put:$($script:calls[-1] -like 'glab api -X PUT projects/g%2Fr/merge_requests/5/merge -f *squash=true*' -and $script:calls[-1] -like '*should_remove_source_branch=true*')"
$script:HostType = 'github'
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/7'; "gh-mr:$($m.iid -eq 7 -and $m.state -eq 'opened' -and $m.source_branch -eq 'f/x' -and $m.has_conflicts -and $m.head_pipeline.status -eq 'failed' -and $m.head_pipeline.id -eq '11')"
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'; "gh-merged:$($m.state -eq 'merged' -and $m.merge_commit_sha -eq 'm8')"
$c = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/changes'; "gh-changes:$(@($c.changes).Count -eq 2 -and $c.changes[1].old_path -eq 'old.txt')"
$b = Invoke-HostApi 'projects/o%2Fr/repository/merge_base?refs[]=abc&refs[]=staging'; "gh-base:$($b.id -eq 'base1')"
$p = @(Invoke-HostApi 'projects/o%2Fr/pipelines?ref=staging&per_page=10'); $j = @(Invoke-HostApi "projects/o%2Fr/pipelines/$($p[0].id)/jobs?per_page=100"); "gh-runs:$($p[0].sha -eq 'm8' -and $j[0].name -eq 'deploy-staging' -and $j[0].status -eq 'success')"
$n = $script:calls.Count; $null = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'; "memo:$($script:calls.Count -eq $n)"
$null = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/merge' -Method PUT -Fields @{ merge_when_pipeline_succeeds = 'true' }; "gh-auto:$(@($script:calls | ? { $_ -like 'gh pr merge 7 -R o/r --squash --delete-branch --auto' }).Count -eq 1)"
$l = @(Invoke-HostVerb 'mr.list' @{ repo = 'o/r'; state = 'opened'; source_branch = 'f/z' }); "gh-list-head:$($l.Count -eq 1 -and $l[0].iid -eq 9)"
$s = Invoke-HostVerb 'ci.status' @{ repo = 'o/r'; sha = 'zzz' } -NoMemo; "gh-status-external:$($s.status -eq 'pending')"
$u = 'https://h/g/s/r/-/merge_requests/4', 'https://github.com/o/r/pull/5', 'https://h/w/r/pull-requests/6', 'https://h/o/p/_git/r/pullrequest/7' | % { $x = ConvertFrom-MrUrl $_; "$($x.type):$($x.repo)!$($x.n)" }
"mr-urls:$("$u" -eq 'gitlab:g/s/r!4 github:o/r!5 bitbucket:w/r!6 azure:o/p/r!7')"
$m = Invoke-HostVerb 'mr.get' @{ type = 'command'; repo = 'o/cmd'; n = '4' }; "command:$($m.iid -eq 4 -and $m.title -eq 'o/cmd')"
$env:BITBUCKET_TOKEN = 'u:app'
$m = Invoke-HostVerb 'mr.get' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; n = '12' }; "bb-mr:$($m.iid -eq 12 -and $m.state -eq 'opened' -and $m.sha -eq 'abc123def456' -and $m.head_pipeline.status -eq 'running' -and $m.head_pipeline.id -eq '41' -and $script:http[0].h.Authorization -like 'Basic *')"
$l = @(Invoke-HostVerb 'mr.list' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; state = 'opened'; source_branch = 'f/x' }); "bb-list:$($l[0].iid -eq 12 -and @($script:http | ? { $_.u -match 'state=OPEN&q=source.branch.name%3D%22f%2Fx%22' }).Count -eq 1)"
$r = Invoke-HostVerb 'mr.merge' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; n = '12'; sha = 'abc123def456'; auto = $true }; "bb-kit-auto:$($r.auto_merge -eq 'kit' -and (Read-KitTracking).automerge.ContainsKey('ws/bbrepo!12') -and -not @($script:http | ? m -eq 'POST').Count)"
$p = @(Invoke-HostVerb 'ci.runs' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; ref = 'f/x' }); $j = @(Invoke-HostVerb 'ci.jobs' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; id = $p[0].id }); "bb-pipelines:$($p[0].status -eq 'failed' -and $j[0].id -eq '{p-1}/{s-1}' -and $j[0].status -eq 'failed')"
$env:AZURE_DEVOPS_EXT_PAT = 'pat'
$m = Invoke-HostVerb 'mr.get' @{ type = 'azure'; repo = 'org/proj/azrepo'; n = '5' }; "az-mr:$($m.has_conflicts -and $m.source_branch -eq 'f/x' -and $m.sha -eq 'aaa' -and $m.web_url -eq 'https://dev.azure.com/org/proj/_git/azrepo/pullrequest/5' -and $m.head_pipeline.status -eq 'success' -and $m.head_pipeline.id -eq 77)"
$r = Invoke-HostVerb 'mr.merge' @{ type = 'azure'; repo = 'org/proj/azrepo'; n = '5'; sha = 'aaa'; auto = $true }; $pb = @($script:http | ? m -eq 'PATCH')[-1].b; "az-auto:$($r.merge_when_pipeline_succeeds -and $pb.autoCompleteSetBy.id -eq 'u-1' -and $pb.completionOptions.mergeStrategy -eq 'squash' -and -not $pb.status)"
$env:GITEA_TOKEN = 'tok'
$r = Invoke-HostVerb 'mr.merge' @{ type = 'gitea'; repo = 'o/gtrepo'; n = '3'; sha = 'ggg' }; $pb = @($script:http | ? m -eq 'POST')[-1]; "gt-merge:$($r.state -eq 'merged' -and $pb.b.Do -eq 'squash' -and $pb.b.head_commit_id -eq 'ggg' -and $pb.h.Authorization -eq 'token tok' -and $pb.u -eq 'https://git.example/api/v1/repos/o/gtrepo/pulls/3/merge')"
$b = Invoke-HostVerb 'repo.base' @{ type = 'gitea'; repo = 'o/gtrepo'; a = 'ggg'; b = 'main' }; "gt-base:$($b.id -eq 'ggg')"
$s = Invoke-HostVerb 'ci.status' @{ repo = 'jkrepo'; sha = 'jjj'; ref = 'f/x' }; "jk-status:$($s.status -eq 'running' -and $s.id -eq 'f/x#9')"
'@
$ka = New-TestKit adapters; $cmdf = Join-Path (Split-Path $ka) 'host-cmd.ps1'; Set-Content $cmdf '[ordered]@{ iid = [int]$args[1]; state = ''merged''; title = $args[0] } | ConvertTo-Json -Compress'
& $J @{ gitHost = 'git.example'; repos = @(@{ name = 'jkrepo'; ci = 'jenkins' }); ci = @{ url = 'https://ci.example'; job = 'job/{repo}' }; gitHostApi = @{ commands = @{ 'mr.get' = "pwsh -NoProfile -File `"$cmdf`" {repo} {n}" } } } (Join-Path $ka 'skills/dev-kit/kit.local.json') 5
$f = Join-Path (Kd) 'githost-test.ps1'; Set-Content $f $gh
$res = @(pwsh @np $f (Join-Path $ka 'skills/dev-kit/lib.ps1') 2>&1)
Expect-Each $res 'git host: #' 'gl-get', 'gl-put', 'gh-mr', 'gh-merged', 'gh-changes', 'gh-base', 'gh-runs', 'memo', 'gh-auto', 'gh-list-head', 'gh-status-external', 'bb-mr', 'bb-list', 'bb-kit-auto', 'bb-pipelines', 'az-mr', 'az-auto', 'gt-merge', 'gt-base', 'jk-status', 'mr-urls', 'command'
Remove-TestKit $ka
$out = pwsh @np $D tracker list PROJ failedTesting -Type jira -DryRun 6>&1 2>&1 | Out-String
Expect 'tracker -Type jira -DryRun: list prints the call' ($out -match 'DRYRUN: GET \S+/rest/api/3/search/jql')
$env:KIT_TRACKER_TYPE = 'none'
$t = pwsh @np $D tracker create -List L1 -Name 'T one' -Description 'd' | ConvertFrom-Json
$null = pwsh @np $D tracker status $t.id failedTesting
$l = @(pwsh @np $D tracker list L1 failedTesting | ConvertFrom-Json)
Expect 'tracker none: create, status failedTesting, list' ($t.id -like 'LOCAL-*' -and $l.Count -eq 1 -and $l[0].id -eq $t.id)
$env:KIT_TRACKER_TYPE = 'clickup'; 'body text' | Set-Content "$r/c.md"
$out = pwsh @np $D tracker comment 12 -File "$r/c.md" -DryRun 6>&1 2>&1 | Out-String
$bad = pwsh @np $D tracker comment 12 -Bogus x -DryRun 2>&1 | Out-String; $badCode = $LASTEXITCODE
Expect 'tracker comment -File sends it; unknown option = usage error' ($out -match 'comment add 12 "body text' -and $badCode -eq 2 -and $bad -match 'unknown option -Bogus')
Remove-Item Env:KIT_TRACKER_TYPE
# tracker backends on recorded answers (CLIs, Invoke-RestMethod mocked; an unknown call fails)
$tb = @'
. $args[0]; $global:log = [Collections.Generic.List[string]]::new()
$__cfg = '{"tracker":{"org":"acme","project":"Shop","commands":{"view":"mytr view {id}","status":"mytr status {id} {status}","comment":"mytr comment {id} {text}","create":"mytr create {list} {name}","list":"mytr list {list} {status}"}}}' | ConvertFrom-Json; $__trRepo = 'g/p'
$env:JIRA_BASE_URL = 'https://j.test'; $env:JIRA_EMAIL = 'a@x'; $env:JIRA_API_TOKEN = 't'; $env:JIRA_TOKEN = 'pat'; $env:LINEAR_API_KEY = 'k'; $env:AZURE_DEVOPS_EXT_PAT = 'p'; $env:YOUTRACK_URL = 'https://yt.test'; $env:YOUTRACK_TOKEN = 'y'
function Fx($call) { $global:log.Add($call); foreach ($k in $global:fx.Keys) { if ($call -match $k) { return $global:fx[$k] } }; throw "404 no fixture: $call" }
function Invoke-RestMethod($Method, $Uri, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec, $Body, $ContentType, $Form, $InFile) {
 $j = Fx "$Method $Uri $ContentType $($Headers.Authorization) $(if ($Body) { [Text.Encoding]::UTF8.GetString($Body) })"; if ($j) { $j | ConvertFrom-Json } }
foreach ($c in 'clickup', 'gh', 'glab', 'mytr') { Set-Item "function:$c" { $i = [array]::IndexOf($args, '--input'); $global:LASTEXITCODE = 0; Fx "$($args -join ' ') $(if ($i -ge 0) { gc $args[$i + 1] -Raw })" } }
function Run($type, $fx, $id, $list, [scriptblock]$ok) {
 Initialize-KitTracker -Type $type; $global:fx = $fx; $global:log.Clear()
 $r = @{ v = Get-TrackerTask $id; s = Set-TrackerStatus $id inTest; c = Add-TrackerComment $id 'two words'; n = New-TrackerTask -List $list -Name 'New one' -Description 'd' -Parent $id -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks $list inTest) }
 "${type}:$(& $ok $r ($global:log -join "`n"))"
}
$v = { param($r, $s, $n) $r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.n.id -eq $n -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq $s }
Run clickup ([ordered]@{ 'task view C1' = '{"id":"C1","name":"Bug","status":{"status":"In Progress"},"list":{"id":"L9"},"subtasks":[{"id":"C2","name":"Sub"}]}'
 'status set in test C1' = 'Status set'; 'comment add C1 two words' = '{"id":"90"}'; 'member list' = '[{"id":7,"username":"Ann Lee"}]'
 'task create --list-id L9 .*--assignee 7 --parent C1' = '{"id":"C5"}'; 'task list --list-id L9 --status in test --page 0' = '[{"id":"C3","name":"A","assignees":[{"id":7,"username":"ann"}]}]' }) C1 L9 { param($r, $l) (& $v $r 7 C5) -and $l -match '--priority 2' }
Run github ([ordered]@{ 'assignees,body' = '{"number":5,"title":"Bug","state":"OPEN","labels":[{"name":"status:In Progress"}],"body":"Part of #1\n- [ ] #6"}'
 'view 6 ' = '{"number":6,"title":"Sub","state":"CLOSED","labels":[]}'; 'view 5 .*state,labels' = '{"state":"OPEN","labels":[{"name":"status:In Progress"}]}'; 'view 5 .*json body' = '{"body":"x"}'
 '^label create' = ''; 'edit 5 -R o/r --remove-label status:In Progress --add-label status:in test' = 'ok'; 'comment 5 -R o/r --body-file' = 'https://github.com/o/r/issues/5#c1'
 'create -R o/r --title New one --assignee Ann Lee --label priority:high' = 'https://github.com/o/r/issues/9'; '^issue edit 5 -R o/r --body-file' = 'ok'; 'list -R o/r .*--label status:in test' = '[{"number":7,"title":"A","assignees":[{"login":"ann"}]}]' }) 'o/r#5' o/r { param($r, $l) (& $v $r ann 9) -and $r.v.parent -eq '1' -and $r.v.subtasks[0].status -eq 'closed' }
Run gitlab ([ordered]@{ 'PUT projects/g%2Fp/issues/5 .*status:in test' = '{"iid":5}'; 'POST projects/g%2Fp/issues/5/notes .*two words' = '{"id":1}'; 'GET projects/g%2Fp/issues/5 ' = '{"iid":5,"title":"Bug","state":"opened","labels":["status:In Progress"],"description":"- [ ] #6"}'
 'GET projects/g%2Fp/issues/6' = '{"iid":6,"title":"Sub","state":"closed","labels":[]}'; 'users\?username=Ann' = '[{"id":3}]'; 'POST projects/g%2Fp/issues .*"assignee_ids":\[3\]' = '{"iid":12}'; 'PUT projects/g%2Fp/issues/5 .*#12' = '{"iid":5}'
 'issues\?state=opened&labels=status%3Ain%20test' = '[{"iid":7,"title":"A","assignees":[{"id":3,"username":"ann"}]}]' }) 'g/p#5' g/p { param($r, $l) & $v $r 3 12 }
$jf = { param($ver, $doc, $who, $srch) [ordered]@{ "GET https://j.test/rest/api/$ver/issue/P-1\?" = '{"key":"P-1","fields":{"summary":"Bug","status":{"name":"In Progress"},"parent":{"key":"P-0"},"subtasks":[{"key":"P-2","fields":{"summary":"Sub","status":{"name":"To Do"}}}],"description":' + $doc + '}}'
 'transitions  ' = '{"transitions":[{"id":"31","name":"QA","to":{"name":"In Test"}}]}'; 'transitions application/json .*"31"' = ''; "P-1/comment .*$(if ($ver -eq 3) { '"type":"doc"' } else { '"body":"two words"' })" = '{"id":"9"}'
 "POST .*/issue .*$who" = '{"key":"P-7"}'; "$srch\?jql=project" = '{"issues":[{"key":"P-3","fields":{"summary":"A","assignee":{"accountId":"u1","name":"u1","displayName":"Ann"}}}]}' } }
Run jira (& $jf 3 '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Steps"}]}]}' '"accountId":"Ann Lee"' 'search/jql') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Basic .*"Subtask"' }
Run jira-server (& $jf 2 '"Steps"' '"name":"Ann Lee"' 'api/2/search') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Bearer pat' -and $l -notmatch 'api/3' }
Run linear ([ordered]@{ 'identifier title url description' = '{"data":{"issue":{"identifier":"E-1","title":"Bug","state":{"name":"In Progress"},"team":{"key":"E"},"children":{"nodes":[{"identifier":"E-2","title":"Sub"}]}}}}'
 'team \{ states' = '{"data":{"issue":{"team":{"states":{"nodes":[{"id":"s1","name":"Backlog"},{"id":"s2","name":"In Test"}]}}}}}'; '"stateId":"s2"' = '{"data":{"issueUpdate":{"success":true}}}'
 '"b":"two words"' = '{"data":{"commentCreate":{"success":true}}}'; 'teams\(filter' = '{"data":{"teams":{"nodes":[{"id":"t1"}]}}}'; 'issue\(id: \$id\) \{ id' = '{"data":{"issue":{"id":"uuid-1"}}}'
 'users\(filter' = '{"data":{"users":{"nodes":[{"id":"u1"}]}}}'; '"parentId":"uuid-1"' = '{"data":{"issueCreate":{"issue":{"identifier":"E-9"}}}}'
 '"eqIgnoreCase":"in test"' = '{"data":{"issues":{"nodes":[{"identifier":"E-3","title":"A","assignee":{"id":"u1","name":"Ann"}}]}}}' }) E-1 E { param($r, $l) & $v $r u1 E-9 }
Run azure ([ordered]@{ 'GET .*/acme/Shop/_apis/wit/workitems/42\?\$expand' = '{"id":42,"fields":{"System.Title":"Bug","System.State":"In Progress","System.Description":"<div>a<br>b</div>"},"relations":[{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/43"}]}'
 'ids=43&' = '{"value":[{"id":43,"fields":{"System.Title":"Sub"}}]}'; 'PATCH .*workitems/42.*json-patch\+json Basic .*System.State' = '{"id":42}'; 'comments\?api-version=7.1-preview.4 .*two words' = '{"id":1}'
 'POST .*workitems/\$Task.*Hierarchy-Reverse' = '{"id":50}'; 'wiql.*in test' = '{"workItems":[{"id":44}]}'; 'ids=44&' = '{"value":[{"id":44,"fields":{"System.Title":"A","System.AssignedTo":{"uniqueName":"ann@x","displayName":"Ann"}}}]}' }) 42 '' { param($r, $l) (& $v $r ann@x 50) -and $l -match '"value":"in test"' -and $r.v.description -eq "a`nb" }
Run youtrack ([ordered]@{ 'GET https://yt.test/api/issues/D-1\?' = '{"idReadable":"D-1","summary":"Bug","subtasks":{"issues":[{"idReadable":"D-2","summary":"Sub"}]},"customFields":[{"name":"State","value":{"name":"In Progress"}}]}'
 'commands .*State \{in test\}' = '{}'; 'D-1/comments.*two words' = '{"id":"c"}'; 'admin/projects' = '[{"id":"0-1","shortName":"OPS"},{"id":"0-2","shortName":"D"}]'; 'POST .*issues\?fields.*"0-2"' = '{"idReadable":"D-9"}'
 'commands .*subtask of D-1 for Ann Lee Priority Major' = '{}'; 'GET .*issues\?query=project%3A%20%7BD%7D' = '[{"idReadable":"D-3","summary":"A","customFields":[{"name":"Assignee","value":{"login":"ann"}}]}]' }) D-1 D { param($r, $l) (& $v $r ann D-9) -and $l -match 'Bearer y' }
Run command ([ordered]@{ '^view T1' = '{"id":"T1","name":"Bug","status":"In Progress","subtasks":[{"name":"Sub"}]}'; '^status T1 in test' = 'ok'; '^comment T1 two words' = 'ok'; '^create B New one' = '{"id":"T9"}'
 '^list B in test' = '[{"id":"T3","name":"A","assignees":[{"id":"ann"}]}]' }) T1 B { param($r, $l) & $v $r ann T9 }
'@
$res = Invoke-PsTest 'tracker-test' $tb @(Join-Path $k 'skills/dev-kit/lib.ps1')
Expect-Each $res 'tracker #: view, status, comment, create, list on recorded answers' 'clickup', 'github', 'gitlab', 'jira', 'jira-server', 'linear', 'azure', 'youtrack', 'command'
$kv = pwsh -NoProfile -Command ". '$(Join-Path $k 'skills/dev-kit/lib.ps1')'; function T1 { param([string]`$Mode, [string[]]`$Lanes, [switch]`$Cold) ""`$Mode|`$(`$Lanes -join '+')|`$Cold"" }; `$a = @{ Lanes = 'L1'; Mode = 'None'; Cold = `$true }; & { Invoke-KitVerb T1 `$args } @a"
Expect 'Invoke-KitVerb: splatted Mode=None binds like -Mode None' ("$kv".Trim() -eq 'None|L1|True')
$out = pwsh @np $D guard -SelfTest 2>&1 | Out-String
Expect 'guard self-test' ($out -match '(\d+)/\1 passed')
$out = & $py -X utf8 (Join-Path $k 'skills/dev-kit/devtools.py') selftest 2>&1 | Out-String
Expect 'devtools selftest' ($LASTEXITCODE -eq 0)
$DT = Join-Path $k 'skills/dev-kit/devtools.py'
$th = & $py -X utf8 $DT task --help 2>&1 | Out-String; $thc = $LASTEXITCODE; $null = & $py -X utf8 $DT task --bogus 2>&1; $tbc = $LASTEXITCODE; $null = & $py -X utf8 $DT status T1 2>&1; $tmc = $LASTEXITCODE
$fk = Join-Path (Kd) 'flaky.py'; [IO.File]::WriteAllText($fk, "import sys, subprocess as sp; sys.path.insert(0, sys.argv[1]); import devtools as d`nn = []; hang = [0]`ndef fake(cmd, **kw):`n    n.append(cmd)`n    if hang[0]: raise sp.TimeoutExpired(cmd, 1)`n    return sp.CompletedProcess(cmd, 1 if len(n) == 1 else 0, 'connection reset' if len(n) == 1 else 'ok', '')`nd.subprocess.run = fake`nr = d._tracker('view', 'T1'); a = len(n); n.clear()`ntry: d._tracker('create', 'x')`nexcept SystemExit: pass`nw = len(n); n.clear(); hang[0] = 1; d._run(['glab', 'api', 'x']); print(r, a, w, len(n))`n")
$rt = & $py -X utf8 $fk (Split-Path $DT) 2>&1 | Out-String
Expect "devtools: --help 0, bad args 2, reads retried, writes never, hung read once ($thc $tbc $tmc $($rt.Trim()))" ($thc -eq 0 -and $th -match 'devtools\.py task <taskId>' -and $th -notmatch 'subtasks' -and $tbc -eq 2 -and $tmc -eq 2 -and $rt.Trim() -eq 'ok 2 1 2')
# pipes: busy only with a head pipeline
$pt = @'
. $args[0]
$ast = [Management.Automation.Language.Parser]::ParseFile($args[1], [ref]$null, [ref]$null)
$fn = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Invoke-Pipes' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
 if ($Verb -eq 'mr.get') { if ($A.n -ne '9') { [pscustomobject]@{ state = 'opened'; head_pipeline = $null; target_branch = 'main' } } }
 elseif ($Verb -eq 'ci.config') { if ($A.repo -match 'nocirepo') { $false } else { $null } }   # no CI file / a failed call
}
$a = Invoke-Pipes -Mrs 'https://h.example/g/nocirepo/-/merge_requests/1' -MaxMinutes 0 | ConvertFrom-Json
$b = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/2' -MaxMinutes 0 | ConvertFrom-Json
$c = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/9' -MaxMinutes 0 | ConvertFrom-Json
"no-ci:$($a.done -and $a.mrs[0].status -eq 'no-ci')"
"no-pipeline:$(-not $b.done -and $b.mrs[0].status -eq 'no-pipeline')"
"unknown:$(-not $c.done -and $c.mrs[0].status -eq 'unknown')"
'@
$res = Invoke-PsTest 'pipes-test' $pt @((Join-Path $k 'skills/dev-kit/lib.ps1'), $D)
Expect-Each $res 'pipes: #' 'no-ci', 'no-pipeline', 'unknown'
# > 200 baseline errors = UNRUN
$ud = Join-Path (Kd) 'unrun-repo'; New-Item -ItemType Directory -Force $ud | Out-Null
'{ "name": "x" }' | Set-Content "$ud/package.json"; '{ "stack": "custom", "commands": { "typecheck": "node tsc.js" } }' | Set-Content "$ud/.claude-stack.json"
'for (let i = 0; i < 250; i++) console.log(`src/old${i}.ts(1,1): error TS2322: x`); process.exit(2)' | Set-Content "$ud/tsc.js"
git -C $ud init -q; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m init
$env:CLAUDE_GATE_KEEP_FREE_GB = '0'   # the test builds need no free-RAM reserve: a busy machine must not stall them
$out = pwsh @np $D check -Dir $ud -Step typecheck 2>&1 | Out-String
Expect 'check: a typecheck UNRUN exits 5' ($LASTEXITCODE -eq 5 -and $out -match 'UNRUN')
New-Item -ItemType Directory -Force "$ud/db/migrate", "$ud/database/migrations" | Out-Null; 'def change; end' | Set-Content "$ud/db/migrate/20240101000000_x.rb"
'x' | Set-Content "$ud/CHANGELOG.md"; '<?php' | Set-Content "$ud/database/migrations/2024_01_01_000000_x.php"; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m rb
$out = pwsh -NoProfile -File $D check -Dir $ud -Step migrations 2>&1 | Out-String
Expect 'check: migrations without a kit check or tool are UNRUN (exit 5), docs skipped' ($LASTEXITCODE -eq 5 -and $out -match 'UNRUN: rails' -and $out -match '000000_x\.php' -and $out -notmatch 'CHANGELOG')
$out = pwsh @np $D gate -Dir $ud -Cmd 'echo gradlew build' 2>&1 | Out-String; Remove-Item Env:CLAUDE_GATE_KEEP_FREE_GB
Expect 'gate: gradle gets the heap cap' ($out -match 'gradlew "?-Dorg\.gradle\.jvmargs=-Xmx\d+g')
# guard: a non-JSON payload denies (logged); empty stdin allows
$gbad = '{not json' | Px $D guard | Out-String
$gnone = '' | Px $D guard | Out-String
Expect 'guard: malformed hook input denies, empty input allows' ($gbad -match '"permissionDecision":"deny"' -and -not $gnone.Trim())
$mk = Join-Path (Kd) 'main kit'; New-Item -ItemType Directory -Force "$mk/skills/dev-kit" | Out-Null
Copy-Item (Join-Path $k 'skills/dev-kit/lib.ps1'), (Join-Path $k 'skills/dev-kit/kit.example.json') "$mk/skills/dev-kit/"
git -C $mk init -q; git -C $mk add -A; git -C $mk -c user.name=t -c user.email=t@t commit -q -m init
& $J @{ tracker = @{ type = 'jira' } } "$mk/skills/dev-kit/kit.local.json"
$lw = Join-Path (Kd) 'wt kit'; git -C $mk worktree add -q --detach $lw 2>$null
$tt = pwsh -NoProfile -Command ". '$lw/skills/dev-kit/lib.ps1'; Get-KitSetting 'tracker.type' 'none'; Invoke-GitFetch -Dir '$lw' -TimeoutSec 20" 2>&1 | Out-String
Expect 'lib: a linked worktree reads the main clone''s kit.local.json; fetch in a path with spaces runs (no origin: warning, $false)' ($tt -match '(?m)^jira' -and $tt -match 'git fetch in .*wt kit failed' -and $tt -match '(?m)^False')
Remove-TestKit $k
Complete-Tests
