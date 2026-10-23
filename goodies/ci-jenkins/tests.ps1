# Tests of the goody ci-jenkins on recorded REST answers (Invoke-KitHttp mocked). Run from a kit clone:
#   pwsh goodies/ci-jenkins/tests.ps1 [-Kit <kit>]   -> a PASS / FAIL line per check; exit 1 on a failure
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/crafty/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/crafty/adapters/ci_jenkins.ps1')
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
$s = Invoke-HostVerb 'ci.status' @{ repo = 'jkrepo'; sha = 'jjj'; ref = 'f/x' }; "jk-status:$($s.status -eq 'running' -and $s.id -eq 'f/x#9')"
}
$out = @($res)
$fail = 0; foreach ($n in 'jk-status'.Split(' ')) { $ok = $out -contains "${n}:True"; if (-not $ok) { $fail++ }; "$(if ($ok) { 'PASS' } else { 'FAIL' }) $n" }
Remove-Item -Recurse -Force $script:KitRoot -ErrorAction SilentlyContinue
exit [int]($fail -gt 0)
