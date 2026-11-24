#Requires -Version 7
<#
tests/host-rest.tests.ps1: the REST git hosts and CI (gitea, bitbucket, azure-devops, ci-jenkins) on recorded answers (Invoke-KitHttp
mocked): one fixture table, one case per row, the call log reset per row (parity rows: mr.update, branch.protect, whoami,
ci.parseUrl, CI task run order by created_at); then the tracker order verbs (dependencies, labels) of
clickup, jira, gitlab, github on their own recorded answers.
Usage: pwsh -NoProfile -File tests/host-rest.tests.ps1 [-Kit <kit>] (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (Split-Path $PSScriptRoot))
. (Join-Path $Kit 'skills/crafty/lib.ps1')
foreach ($a in 'gitea', 'bitbucket', 'azure-devops', 'ci-jenkins') { . (Join-Path (Split-Path $PSScriptRoot) "skills/crafty/adapters/$a.ps1") }
$__cfg = '{"gitHost":"git.example","repos":[{"name":"jkrepo","ci":"jenkins"}],"ci":{"url":"https://ci.example","job":"job/{repo}"}}' | ConvertFrom-Json
$KitConf.GitHost = 'git.example'; $script:KitRoot = Join-Path ([IO.Path]::GetTempPath()) "extra-test-$PID"   # tracking.json of the test, not the kit's
$fx = [ordered]@{
 'GET .*bitbucket.*/pullrequests/12$' = '{"id":12,"title":"x","description":"D0","state":"OPEN","source":{"branch":{"name":"f/x"},"commit":{"hash":"abc123def456"}},"links":{"html":{"href":"https://bitbucket.org/ws/bbrepo/pull-requests/12"}}}'
 'GET .*bitbucket.*/commit/abc123def456/statuses' = '{"values":[{"state":"INPROGRESS","key":"build","url":"https://bitbucket.org/ws/bbrepo/pipelines/results/41"}]}'
 'GET .*bitbucket.*/pullrequests\?' = '{"values":[{"id":12,"title":"x","state":"OPEN","source":{"branch":{"name":"f/x"},"commit":{"hash":"abc123def456"}}}]}'
 'GET .*bitbucket.*/pipelines\?' = '{"values":[{"uuid":"{p-1}","build_number":41,"state":{"name":"COMPLETED","result":{"name":"FAILED"}},"target":{"commit":{"hash":"abc123def456"}}}]}'
 'PUT .*bitbucket.*/pullrequests/12$' = '{"id":12,"title":"new","state":"OPEN","source":{"branch":{"name":"f/x"},"commit":{"hash":"abc123def456"}}}'
 'GET .*bitbucket.*/branch-restrictions\?pattern=main&' = '{"values":[{"kind":"force","pattern":"main"},{"kind":"delete","pattern":"main"}]}'
 'GET .*bitbucket.*/branch-restrictions\?pattern=dev&' = '{"values":[{"kind":"force","pattern":"dev"},{"kind":"delete","pattern":"dev2"}]}'
 'POST .*bitbucket.*/branch-restrictions$' = '{"id":3}'
 'GET .*/repos/o/gtrepo/branch_protections/main$' = '{"branch_name":"main","enable_force_push":false}'
 'GET .*/repos/o/gtrepo/branch_protections/dev$' = '{"branch_name":"dev","enable_force_push":true}'
 'POST .*/repos/o/gtrepo/branch_protections$' = '{"rule_name":"new"}'
 'GET .*/repos/o/gtrepo/actions/tasks' = '{"workflow_runs":[{"id":502,"run_number":7,"name":"build","status":"failure","url":"https://git.example/o/gtrepo/actions/runs/7/jobs/1"},{"id":501,"run_number":7,"name":"lint","status":"cancelled"},{"id":400,"run_number":6,"status":"success"}]}'
 'GET .*/_apis/git/repositories/azrepo\?' = '{"id":"r-1","project":{"id":"p-1"}}'
 'GET .*accesscontrollists/2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87\?token=repoV2%2Fp-1%2Fr-1%2Frefs%2Fheads%2F720065006c00&' = '{"count":1,"value":[{"acesDictionary":{"d-1":{"allow":0,"deny":8}}}]}'
 'GET .*accesscontrollists/2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87\?token=repoV2%2Fp-1%2Fr-1%2Frefs%2Fheads%2F6d00610069006e00&' = '{"count":0,"value":[]}'
 'GET .*vssps.dev.azure.com/org/_apis/identities\?searchFilter=General&filterValue=%5Bproj%5D%5CContributors' = '{"value":[{"descriptor":"Microsoft.TeamFoundation.Identity;S-1-9-7"}]}'
 'POST .*/org/_apis/accesscontrolentries/2e9eb7ed' = '{"count":1}'
 'GET .*/org/proj/_apis/build/builds/77/timeline' = '{"records":[{"id":"11111111-2222-3333-4444-555555555555","type":"Job","log":{"id":9}}]}'
 'GET .*bitbucket.*/steps/%7Bs-1%7D/log' = '"ok\nERROR: bb boom"'
 'GET .*/org/proj/_apis/build/builds/78/timeline' = '{"records":[{"id":"j-1","type":"Job","name":"Build","result":"failed","log":{"id":9}},{"id":"t-1","parentId":"j-1","type":"Task","issues":[{"type":"warning","message":"w"},{"type":"error","message":"The job ran longer than the maximum time of 60 minutes"}]}]}'
 'GET .*/build/builds/78/logs/9' = '"plain log"'
 'GET .*/org/proj/_apis/build/builds/79/timeline' = '{"records":[{"id":"j-2","type":"Job","name":"Deploy","result":"failed"},{"id":"t-2","parentId":"j-2","type":"Task","result":"failed","log":{"id":4}}]}'
 'GET .*/build/builds/79/logs/4' = '"x\nERROR: az deploy failed"'
 'GET .*/org/proj/_apis/build/builds/80/timeline' = '{"records":[{"id":"j-3","type":"Job","name":"Pack","result":"failed","issues":[{"type":"error","message":"No agent found in pool"}]}]}'
 'GET .*bitbucket.*/pipelines/%7Bp-2%7D/steps\?' = '{"values":[{"uuid":"{s-2}","name":"deploy","state":{"name":"COMPLETED","result":{"name":"ERROR","error":{"message":"Container out of memory"}}}}]}'
 'GET .*/repos/o/gtrepo/labels\?limit=50&page=1$' = ('[' + ((1..49 | ForEach-Object { "{`"name`":`"l$_`"}" }) -join ',') + ',{"name":"api"}]')
 'GET .*/repos/o/gtrepo/labels\?limit=50&page=2$' = '[{"name":"bug"}]'
 'POST .*/repos/o/gtrepo/(labels|issues/3/labels)$' = '{"id":1}'
 'GET .*f%252Fx/9/wfapi/describe' = '{"stages":[{"id":"6","name":"Build","status":"SUCCESS"},{"id":"12","name":"Test","status":"FAILED","error":{"message":"script returned exit code 1","type":"hudson.AbortException"}}]}'
 'GET .*/(f%252Fx/9|main/4)/consoleText' = '"[Pipeline] sh\nERROR: tests failed"'
 'GET .*/main/4/api/json\?tree=result' = '{"result":"FAILURE"}'
 'GET .*bitbucket.*/pipelines/%7Bp-1%7D/steps' ='{"values":[{"uuid":"{s-1}","name":"test","state":{"name":"COMPLETED","result":{"name":"FAILED"}}}]}'
 'GET .*dev.azure.com/org/proj/_apis/git/repositories/azrepo/pullrequests/5\?' = '{"pullRequestId":5,"title":"t","description":"A0","status":"active","sourceRefName":"refs/heads/f/x","lastMergeSourceCommit":{"commitId":"aaa"},"mergeStatus":"conflicts","repository":{"webUrl":"https://dev.azure.com/org/proj/_git/azrepo"}}'
 'GET .*refs/pull/5/merge' = '{"count":1,"value":[{"id":77,"status":"completed","result":"succeeded"}]}'
 'GET .*/org/_apis/connectionData' = '{"authenticatedUser":{"id":"u-1","providerDisplayName":"A B","properties":{"Account":{"$value":"ab@example.test"}}}}'
 'PATCH .*pullrequests/5\?' = '{"pullRequestId":5,"status":"active","autoCompleteSetBy":{"id":"u-1"},"sourceRefName":"refs/heads/f/x","repository":{"webUrl":"https://dev.azure.com/org/proj/_git/azrepo"}}'
 'GET .*/repos/o/gtrepo/commits/ggg/status' = '{"state":"success","statuses":[{"status":"success","context":"ci"}]}'
 'GET .*/repos/o/gtrepo/compare/main...ggg' = '{"total_commits":0,"commits":[],"files":[]}'
 'GET .*ci.example/job/jkrepo/job/f%252Fx/api/json' = '{"builds":[{"number":9,"result":null,"building":true,"actions":[{},{"lastBuiltRevision":{"SHA1":"jjj"}}]}]}'
}
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) {
 $script:http.Add([pscustomobject]@{ m = $Method; u = $Uri; b = $Body; h = $Headers })
 if ($Uri -match '/repos/o/gtrepo/pulls/3/merge') { $script:gtMerged = $true; return $null }
 if ($Uri -match '/repos/o/gtrepo/pulls/3$') { return ('{"number":3,"title":"t","body":"G0","state":"' + $(if ($script:gtMerged) { 'closed","merged":true,"merged_at":"2026-10-15T12:00:00Z"' } else { 'open","merged":false' }) + ',"head":{"ref":"f/x","sha":"ggg"},"base":{"ref":"main"},"mergeable":true,"html_url":"https://git.example/o/gtrepo/pulls/3"}') | ConvertFrom-Json }
 $global:KitHttpCode = 0; foreach ($k in $fx.Keys) { if ("$Method $Uri" -match $k) { return ($fx[$k] | ConvertFrom-Json) } }
 $global:KitHttpCode = if ($Uri -match 'locked') { 403 } else { 404 }; $null
}
$env:GITEA_TOKEN = 'tok'; $env:BITBUCKET_TOKEN = 'u:app'; $env:AZURE_DEVOPS_EXT_PAT = 'pat'
function LastCall($m) { @($script:http | Where-Object m -eq $m)[-1] }
$bb = @{ type = 'bitbucket'; repo = 'ws/bbrepo' }; $gt = @{ type = 'gitea'; repo = 'o/gtrepo' }; $az = @{ type = 'azure'; repo = 'org/proj/azrepo' }
# rows: name, { check } (fresh call log and gitea merge state per row)
$rows = @(
 ,@('gt-merge', { $r = Invoke-HostVerb 'mr.merge' ($gt + @{ n = '3'; sha = 'ggg' }); $pb = LastCall POST; $r.state -eq 'merged' -and $pb.b.Do -eq 'squash' -and $pb.b.head_commit_id -eq 'ggg' -and $pb.h.Authorization -eq 'token tok' -and $pb.u -eq 'https://git.example/api/v1/repos/o/gtrepo/pulls/3/merge' })
 ,@('gt-deploy-merge', { $null = Invoke-HostVerb 'mr.merge' ($gt + @{ n = '3'; method = 'merge' }); (LastCall POST).b.Do -eq 'merge' })
 ,@('gt-base', { (Invoke-HostVerb 'repo.base' ($gt + @{ a = 'ggg'; b = 'main' })).id -eq 'ggg' })
 ,@('bb-mr', { $m = Invoke-HostVerb 'mr.get' ($bb + @{ n = '12' }); $m.iid -eq 12 -and $m.state -eq 'opened' -and $m.sha -eq 'abc123def456' -and $m.head_pipeline.status -eq 'running' -and $m.head_pipeline.id -eq '41' -and $script:http[0].h.Authorization -like 'Basic *' })
 ,@('bb-list', { $l = @(Invoke-HostVerb 'mr.list' ($bb + @{ state = 'opened'; source_branch = 'f/x' })); $l[0].iid -eq 12 -and @($script:http | Where-Object { $_.u -match 'state=OPEN&q=source.branch.name%3D%22f%2Fx%22' }).Count -eq 1 })
 ,@('bb-kit-auto', { $r = Invoke-HostVerb 'mr.merge' ($bb + @{ n = '12'; sha = 'abc123def456'; auto = $true }); $r.auto_merge -eq 'kit' -and (Read-KitTracking).automerge.ContainsKey('ws/bbrepo!12') -and -not @($script:http | Where-Object m -eq 'POST').Count })
 ,@('bb-pipelines', { $p = @(Invoke-HostVerb 'ci.runs' ($bb + @{ ref = 'f/x' })); $j = @(Invoke-HostVerb 'ci.jobs' ($bb + @{ id = $p[0].id })); $p[0].status -eq 'failed' -and $j[0].id -eq '{p-1}/{s-1}' -and $j[0].status -eq 'failed' })
 ,@('bb-deploy-merge', { $null = Invoke-HostVerb 'mr.merge' ($bb + @{ n = '12'; method = 'merge' }); (LastCall POST).b.merge_strategy -eq 'merge_commit' })
 ,@('az-mr', { $m = Invoke-HostVerb 'mr.get' ($az + @{ n = '5' }); $m.has_conflicts -and $m.source_branch -eq 'f/x' -and $m.sha -eq 'aaa' -and $m.web_url -eq 'https://dev.azure.com/org/proj/_git/azrepo/pullrequest/5' -and $m.head_pipeline.status -eq 'success' -and $m.head_pipeline.id -eq 77 })
 ,@('az-auto', { $r = Invoke-HostVerb 'mr.merge' ($az + @{ n = '5'; sha = 'aaa'; auto = $true }); $pb = (LastCall PATCH).b; $r.merge_when_pipeline_succeeds -and $pb.autoCompleteSetBy.id -eq 'u-1' -and $pb.completionOptions.mergeStrategy -eq 'squash' -and -not $pb.status })
 ,@('az-deploy-merge', { $null = Invoke-HostVerb 'mr.merge' ($az + @{ n = '5'; sha = 'aaa'; method = 'merge' }); (LastCall PATCH).b.completionOptions.mergeStrategy -eq 'noFastForward' })
 ,@('jk-status', { $s = Invoke-HostVerb 'ci.status' @{ repo = 'jkrepo'; sha = 'jjj'; ref = 'f/x' }; $s.status -eq 'running' -and $s.id -eq 'f/x#9' })
 # parity (owner 2026-11-24): mr.update, branch.protect (ok | set | skip on 403 | failed), azure whoami + author filter, ci.parseUrl
 ,@('mr-body', { "$((Invoke-HostVerb 'mr.get' ($bb + @{ n = '12' })).description)|$((Invoke-HostVerb 'mr.get' ($az + @{ n = '5' })).description)|$((Invoke-HostVerb 'mr.get' ($gt + @{ n = '3' })).description)" -eq 'D0|A0|G0' })   # devtools.py edits the body it read: never an empty one
 ,@('bb-update', { $m = Invoke-HostVerb 'mr.update' ($bb + @{ n = '12'; title = 'new'; body = 'B' }); $u = LastCall PUT; $m.title -eq 'new' -and $u.b.description -eq 'B' -and $u.b.title -eq 'new' })
 ,@('bb-protect', { $v = foreach ($b in 'main', 'dev', 'locked') { Invoke-HostVerb 'branch.protect' ($bb + @{ branch = $b }) -NoMemo }; $pb = LastCall POST; ($v -join ';') -eq 'ok;set;skip: no admin rights on ws/bbrepo' -and $pb.b.kind -eq 'delete' -and $pb.b.pattern -eq 'dev' })
 ,@('bb-author', { @(Invoke-HostVerb 'mr.list' ($bb + @{ state = 'opened'; author_username = 'zed' })).Count -eq 0 -and @(Invoke-HostVerb 'mr.list' ($bb + @{ state = 'opened' })).Count -eq 1 })
 ,@('bb-parseUrl', { $u = Invoke-HostVerb 'ci.parseUrl' ($bb + @{ text = 'failed: https://bitbucket.org/ws/bbrepo/pipelines/results/41/steps/%7B0f1e2d3c-1111-2222-3333-444455556666%7D' }); $u.run -eq '{p-1}' -and $u.job -eq '{p-1}/{0f1e2d3c-1111-2222-3333-444455556666}' -and $u.url -match '/results/41/steps/' })
 ,@('gt-update', { $m = Invoke-HostVerb 'mr.update' ($gt + @{ n = '3'; title = 'T2'; body = 'B2' }); $u = LastCall PATCH; $m.iid -eq 3 -and $u.b.body -eq 'B2' -and $u.u -match '/repos/o/gtrepo/pulls/3$' })
 ,@('gt-protect', { $v = foreach ($b in 'main', 'dev', 'new', 'locked') { Invoke-HostVerb 'branch.protect' ($gt + @{ branch = $b }) -NoMemo }; $pb = LastCall POST
   ($v -join ';') -eq 'ok;failed: protected but force push allowed: turn it off by hand;set;skip: no admin rights on o/gtrepo' -and $pb.b.branch_name -eq 'new' -and $pb.b.enable_push -and -not $pb.b.enable_force_push })
 ,@('gt-parseUrl', { $u = Invoke-HostVerb 'ci.parseUrl' ($gt + @{ text = 'see https://git.example/o/gtrepo/actions/runs/7/jobs/1 for the log' }); $r = Invoke-HostVerb 'ci.parseUrl' ($gt + @{ text = 'https://git.example/o/gtrepo/actions/runs/7' }); "$($u.run)/$($u.job) $($r.run)/$($r.job)" -eq '502/502 501/' })
 ,@('az-update', { $m = Invoke-HostVerb 'mr.update' ($az + @{ n = '5'; title = 'T'; body = 'D' }); $u = LastCall PATCH; $m.iid -eq 5 -and $u.b.description -eq 'D' -and $u.b.title -eq 'T' })
 ,@('az-whoami', { (Invoke-HostVerb 'whoami' $az -NoMemo) -eq 'ab@example.test' })
 ,@('az-protect', { $v = foreach ($b in 'main', 'rel') { Invoke-HostVerb 'branch.protect' ($az + @{ branch = $b }) -NoMemo }; $pb = LastCall POST
   ($v -join ';') -eq 'set;ok' -and $pb.b.token -eq 'repoV2/p-1/r-1/refs/heads/6d00610069006e00' -and $pb.b.accessControlEntries[0].deny -eq 8 -and $pb.b.accessControlEntries[0].descriptor -match 'S-1-9-7' -and $pb.b.merge })
 ,@('az-parseUrl', { $u = Invoke-HostVerb 'ci.parseUrl' ($az + @{ text = 'https://dev.azure.com/org/proj/_build/results?buildId=77&view=logs&j=11111111-2222-3333-4444-555555555555' }); "$($u.run)|$($u.job)" -eq '77|77/9' })
 ,@('jk-parseUrl', { $x = foreach ($tx in 'https://ci.example/job/jkrepo/job/f%252Fx/9/execution/node/12/', 'https://ci.example/blue/organizations/jenkins/jkrepo/detail/f%2Fx/9/pipeline/12', 'https://ci.example/job/jkrepo/job/main/4/console') { $u = Invoke-HostVerb 'ci.parseUrl' @{ repo = 'jkrepo'; text = $tx }; "$($u.run)|$($u.job)" }; ($x -join ' ') -eq 'f/x#9|f/x#9/12 f/x#9|f/x#9/12 main#4|' })
 # parity natives (recorded answers, no account): mr.parseRef short refs, ci.failure from the vendor's own failure data, gitea mr.labels
 ,@('short-refs', { $x = foreach ($c in @(($bb + @{ ref = 'pull request #4' }), ($az + @{ ref = '!5' }), ($gt + @{ ref = '#3' }), ($gt + @{ ref = '!3' }))) { $p = Invoke-HostVerb 'mr.parseRef' $c; "$($p.repo)|$($p.n)|$($p.type)" }
   ($x -join ' ') -eq 'ws/bbrepo|4|bitbucket org/proj/azrepo|5|azure o/gtrepo|3|gitea o/gtrepo|3|gitea' -and $null -eq (Invoke-HostVerb 'mr.parseRef' @{ type = 'bitbucket'; ref = 'pull request #4' }) -and $null -eq (Invoke-HostVerb 'mr.parseRef' ($bb + @{ ref = '#4' })) })
 ,@('bb-failure', { $f = Invoke-HostVerb 'ci.failure' ($bb + @{ id = '{p-1}' }); "$($f.job)|$($f.id)|$($f.reason)|$($f.raw)|$($f.excerpt)" -eq 'test|{p-1}/{s-1}|script|FAILED|ERROR: bb boom' -and
   "$((Invoke-HostVerb 'ci.failure' ($bb + @{ id = '{p-2}' })) | ForEach-Object { "$($_.job)|$($_.reason)|$($_.excerpt)" })" -eq 'deploy|infra|Container out of memory' })
 ,@('az-failure', { $x = foreach ($b in '78', '79', '80') { $f = Invoke-HostVerb 'ci.failure' ($az + @{ id = $b }); "$($f.job)|$($f.id)|$($f.reason)|$($f.excerpt -replace "`n", '~')" }
   ($x -join ' ; ') -eq 'Build|78/9|timeout|The job ran longer than the maximum time of 60 minutes ; Deploy|79/4|script|ERROR: az deploy failed ; Pack|80|infra|No agent found in pool' })
 ,@('jk-failure', { $f = Invoke-HostVerb 'ci.failure' @{ repo = 'jkrepo'; id = 'f/x#9' }; $g = Invoke-HostVerb 'ci.failure' @{ repo = 'jkrepo'; id = 'main#4' }
   "$($f.job)|$($f.id)|$($f.reason)|$($f.excerpt -replace "`n", '~')" -eq 'Test|f/x#9/12|script|script returned exit code 1~ERROR: tests failed' -and "$($g.job)|$($g.id)" -eq 'main|main#4' })
 ,@('gt-failure', { $x = foreach ($t in '502', '501', '400') { $f = Invoke-HostVerb 'ci.failure' ($gt + @{ id = $t }); "$($f.job)|$($f.id)|$($f.reason)|$($f.raw)|$($f.url)" }
   ($x -join ' ; ') -eq 'build|502|script|failure|https://git.example/o/gtrepo/actions/runs/7/jobs/1 ; lint|501|canceled|cancelled| ; ||||' })
 ,@('gt-labels', { $r = Invoke-HostVerb 'mr.labels' ($gt + @{ n = '3'; labels = @('api', 'bug', 'new') }); $po = @($script:http | Where-Object m -eq 'POST')
   ($r.labels -join ',') -eq 'api,bug,new' -and $po.Count -eq 2 -and $po[0].b.name -eq 'new' -and $po[1].u -match '/issues/3/labels$' -and ($po[1].b.labels -join ',') -eq 'api,bug,new' })
 ,@('ci-task-order', { $fa = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Kit 'skills/bossy/adapters/supervise-resources.ps1'), [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-KitCiTaskJob' }, $true)[0]
   & { . ([scriptblock]::Create($fa.Extent.Text)); function ProjPath($r) { "g/$r" }
     function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}) { switch ($Verb) { 'mr.get' { [pscustomobject]@{ merge_commit_sha = 'm1' } } 'repo.base' { [pscustomobject]@{ id = 'm1' } }
       'ci.runs' { @([pscustomobject]@{ id = 'main#5'; sha = 's5'; created_at = '2026-11-20T10:00:00Z' }, [pscustomobject]@{ id = 'main#4'; sha = 's4'; created_at = '2026-11-20T09:00:00Z' }) }
       'ci.jobs' { @([pscustomobject]@{ id = "$($A.id)/1"; name = 'unit'; status = $(if ($A.id -eq 'main#5') { 'success' } else { 'failed' }) }) } } }
     $r = Test-KitCiTaskJob ([pscustomobject]@{ job = 'main#4/1'; run = 'main#4'; branch = 'main'; url = 'https://ci.example/job/api/job/main/4/' }) @('api!5'); "$($r.state)|$($r.name)" -eq 'pass|unit' } })
)
$fail = 0
foreach ($row in $rows) {
 $script:http = [Collections.Generic.List[object]]::new(); $script:gtMerged = $false
 $ok = $false; try { $ok = [bool](& $row[1]) } catch { "  $($row[0]) error: $_" }
 if (-not $ok) { $fail++ }; "$(if ($ok) { 'PASS' } else { 'FAIL' }) $($row[0])"
}
# order (owner 2026-11-23): dependencies (waits on; a known link never posted twice; returns the waits) + labels per adapter
$env:JIRA_BASE_URL = 'https://j.test'; $env:JIRA_EMAIL = 'a@x'; $env:JIRA_API_TOKEN = 't'; $__trRepo = 'g/p'; $global:ordLog = [Collections.Generic.List[string]]::new(); $global:ordHttp = [Collections.Generic.List[string]]::new()
foreach ($a in 'tracker-jira', 'gitlab', 'tracker-clickup') { . (Join-Path (Split-Path $PSScriptRoot) "skills/crafty/adapters/$a.ps1") }
function OrdFx($call) { $global:ordLog.Add($call); foreach ($k in $global:ordFx.Keys) { if ($call -match $k) { return $global:ordFx[$k] } }; throw "404 no fixture: $call" }
function Invoke-RestMethod($Method, $Uri, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec, $Body, $ContentType, $Form, $InFile) { $j = OrdFx "$Method $Uri $ContentType $(if ($Body) { [Text.Encoding]::UTF8.GetString($Body) })"; if ($j) { $j | ConvertFrom-Json } }
foreach ($c in 'clickup', 'gh') { Set-Item "function:$c" { $global:LASTEXITCODE = 0; OrdFx "$($args -join ' ') " } }
. (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/github.ps1')
Set-Item 'function:glab' { $i = [array]::IndexOf($args, '--input'); $global:LASTEXITCODE = 0; OrdFx "$($args -join ' ') $(if ($i -ge 0) { gc $args[$i + 1] -Raw })" }
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) { $hl = "$Method $Uri $($Body | ConvertTo-Json -Compress -Depth 10) $($Headers.Authorization)"; $global:ordHttp.Add($hl); $hj = try { OrdFx $hl } catch { $null }; if ($hj) { $hj | ConvertFrom-Json } else { @{ id = 'C9' } } }
$ord = [ordered]@{}
try { $env:CLICKUP_API_TOKEN = 'tk-test'; Initialize-KitTracker -Type clickup; $global:ordHttp.Clear(); $global:ordFx = [ordered]@{ 'task view C9 --json' = '{"id":"C9","dependencies":[{"task_id":"C9","depends_on":"C1"},{"task_id":"C7","depends_on":"C9"}]}' }
  $ord.clickup = "$(@(__TrA 'dependencies' @{ id = 'C9'; on = @('C1', 'C2') }) -join ',')|$(__TrA 'labels' @{ id = 'C9'; add = @('Wave: v2 wave 1') })$($global:ordHttp -join ' ; ')" } catch { $ord.clickup = "error: $_" } finally { Remove-Item Env:CLICKUP_API_TOKEN -ErrorAction SilentlyContinue }
try { Initialize-KitTracker -Type jira; $global:ordLog.Clear(); $global:ordFx = [ordered]@{ 'GET https://j.test/rest/api/3/issue/P-5\?fields=issuelinks' = '{"fields":{"issuelinks":[{"type":{"name":"Blocks"},"inwardIssue":{"key":"P-1"}},{"type":{"name":"Blocks"},"outwardIssue":{"key":"P-9"}}]}}'; 'POST https://j.test/rest/api/3/issueLink' = ''; 'PUT https://j.test/rest/api/3/issue/P-5 ' = '' }
  $ord.jira = "$(@(__TrA 'dependencies' @{ id = 'P-5'; on = @('P-1', 'P-2') }) -join ',')|$(__TrA 'labels' @{ id = 'P-5'; add = @('Wave: v2 wave 1') })$($global:ordLog -join ' ; ')" } catch { $ord.jira = "error: $_" }
try { Initialize-KitTracker -Type gitlab; $global:ordLog.Clear(); $global:ordFx = [ordered]@{ 'GET projects/g%2Fp/issues/5/links' = '[{"iid":1,"link_type":"is_blocked_by"},{"iid":9,"link_type":"blocks"}]'; 'POST projects/g%2Fp/issues/5/links' = '{}'; 'PUT projects/g%2Fp/issues/5 ' = '{"iid":5}' }
  $ord.gitlab = "$(@(__TrA 'dependencies' @{ id = '5'; on = @('1', 'g/p#2') }) -join ',')|$(__TrA 'labels' @{ id = '5'; add = @('Wave: v2 wave 1') })$($global:ordLog -join ' ; ')" } catch { $ord.gitlab = "error: $_" }
try { Initialize-KitTracker -Type github; $global:ordLog.Clear(); $global:ordFx = [ordered]@{ '^api repos/g/p/issues/5/dependencies/blocked_by $' ='[{"number":1}]'; 'api repos/g/p/issues/2 --jq .id' = '4402'; 'api -X POST repos/g/p/issues/5/dependencies/blocked_by -F issue_id=4402' = '{}'; '^label create' = ''; '^issue edit 5' = '' }
  $ord.github = "$(@(__TrA 'dependencies' @{ id = '5'; on = @('1', '2') }) -join ',')|$(__TrA 'labels' @{ id = '5'; add = @('Wave: v2 wave 1') })$($global:ordLog -join ' ; ')" } catch { $ord.github = "error: $_" }
$pass = $ord.clickup -match '^C1,C2\|' -and $ord.clickup -match 'POST https://api.clickup.com/api/v2/task/C9/dependency \{"depends_on":"C2"\} tk-test ; POST https://api.clickup.com/api/v2/task/C9/tag/wave%3A%20v2%20wave%201 ' -and $ord.clickup -notmatch '"depends_on":"C1"' -and
  $ord.jira -match '^P-1,P-2\|' -and @([regex]::Matches($ord.jira, 'POST https://j.test/rest/api/3/issueLink')).Count -eq 1 -and $ord.jira -match '"inwardIssue":\{"key":"P-2"\}' -and $ord.jira -match '"outwardIssue":\{"key":"P-5"\}' -and $ord.jira -match '"add":"wave-v2-wave-1"' -and
  $ord.gitlab -match '^1,2\|' -and @([regex]::Matches($ord.gitlab, 'POST projects/g%2Fp/issues/5/links')).Count -eq 1 -and $ord.gitlab -match '"target_issue_iid":"2"' -and $ord.gitlab -match '"link_type":"is_blocked_by"' -and $ord.gitlab -match '"add_labels":"Wave: v2 wave 1"' -and
  $ord.github -match '^1,2\|' -and $ord.github -match 'issue_id=4402' -and $ord.github -match 'issue edit 5 -R g/p --add-label Wave: v2 wave 1'; if (-not $pass) { $fail++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker order: dependencies (waits on, a known link not posted again) and labels on clickup, jira, gitlab, github ($(@($ord.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' // '))"
Remove-Item -Recurse -Force $script:KitRoot -ErrorAction SilentlyContinue
exit [int]($fail -gt 0)
