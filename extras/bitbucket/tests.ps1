# Tests of the extra bitbucket on recorded REST answers (Invoke-KitHttp mocked). Run from a kit clone:
#   pwsh extras/bitbucket/tests.ps1 [-Kit <kit>]   -> a PASS / FAIL line per check; exit 1 on a failure
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/dev-kit/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/dev-kit/adapters/bitbucket.ps1')
$__cfg = '{"gitHost":"git.example","repos":[{"name":"jkrepo","ci":"jenkins"}],"ci":{"url":"https://ci.example","job":"job/{repo}"}}' | ConvertFrom-Json
$KitConf.GitHost = 'git.example'; $script:KitRoot = Join-Path ([IO.Path]::GetTempPath()) "extra-test-$PID"   # tracking.json of the test, not the kit's
# fixtures, then the checks; each prints '<name>:True|False' (one pass, collected in $res)
$res = foreach ($pass in 1) {
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
$env:BITBUCKET_TOKEN = 'u:app'
$m = Invoke-HostVerb 'mr.get' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; n = '12' }; "bb-mr:$($m.iid -eq 12 -and $m.state -eq 'opened' -and $m.sha -eq 'abc123def456' -and $m.head_pipeline.status -eq 'running' -and $m.head_pipeline.id -eq '41' -and $script:http[0].h.Authorization -like 'Basic *')"
$l = @(Invoke-HostVerb 'mr.list' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; state = 'opened'; source_branch = 'f/x' }); "bb-list:$($l[0].iid -eq 12 -and @($script:http | ? { $_.u -match 'state=OPEN&q=source.branch.name%3D%22f%2Fx%22' }).Count -eq 1)"
$r = Invoke-HostVerb 'mr.merge' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; n = '12'; sha = 'abc123def456'; auto = $true }; "bb-kit-auto:$($r.auto_merge -eq 'kit' -and (Read-KitTracking).automerge.ContainsKey('ws/bbrepo!12') -and -not @($script:http | ? m -eq 'POST').Count)"
$p = @(Invoke-HostVerb 'ci.runs' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; ref = 'f/x' }); $j = @(Invoke-HostVerb 'ci.jobs' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; id = $p[0].id }); "bb-pipelines:$($p[0].status -eq 'failed' -and $j[0].id -eq '{p-1}/{s-1}' -and $j[0].status -eq 'failed')"
}
$out = @($res)
$fail = 0; foreach ($n in 'bb-mr bb-list bb-kit-auto bb-pipelines'.Split(' ')) { $ok = $out -contains "${n}:True"; if (-not $ok) { $fail++ }; "$(if ($ok) { 'PASS' } else { 'FAIL' }) $n" }
Remove-Item -Recurse -Force $script:KitRoot -ErrorAction SilentlyContinue
exit [int]($fail -gt 0)
