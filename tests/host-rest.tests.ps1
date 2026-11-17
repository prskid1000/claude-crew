#Requires -Version 7
<#
tests/host-rest.tests.ps1: the REST git hosts and CI (gitea, bitbucket, azure-devops, ci-jenkins) on recorded answers (Invoke-KitHttp
mocked): one fixture table, one case per row, the call log reset per row.
Usage: pwsh -NoProfile -File tests/host-rest.tests.ps1 [-Kit <kit>] (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (Split-Path $PSScriptRoot))
. (Join-Path $Kit 'skills/crafty/lib.ps1')
foreach ($a in 'gitea', 'bitbucket', 'azure_devops', 'ci_jenkins') { . (Join-Path (Split-Path $PSScriptRoot) "skills/crafty/adapters/$a.ps1") }
$__cfg = '{"gitHost":"git.example","repos":[{"name":"jkrepo","ci":"jenkins"}],"ci":{"url":"https://ci.example","job":"job/{repo}"}}' | ConvertFrom-Json
$KitConf.GitHost = 'git.example'; $script:KitRoot = Join-Path ([IO.Path]::GetTempPath()) "extra-test-$PID"   # tracking.json of the test, not the kit's
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
)
$fail = 0
foreach ($row in $rows) {
 $script:http = [Collections.Generic.List[object]]::new(); $script:gtMerged = $false
 $ok = $false; try { $ok = [bool](& $row[1]) } catch { "  $($row[0]) error: $_" }
 if (-not $ok) { $fail++ }; "$(if ($ok) { 'PASS' } else { 'FAIL' }) $($row[0])"
}
Remove-Item -Recurse -Force $script:KitRoot -ErrorAction SilentlyContinue
exit [int]($fail -gt 0)
