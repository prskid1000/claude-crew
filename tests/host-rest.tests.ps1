#Requires -Version 7
<#
tests/host-rest.tests.ps1: the REST git hosts and CI (gitea, bitbucket, azure-devops, ci-jenkins) on recorded answers (Invoke-KitHttp
mocked): one fixture table, one case per row, the call log reset per row; then the tracker order verbs (dependencies, labels) of
clickup, jira, gitlab, github on their own recorded answers.
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
# order (owner 2026-11-23): dependencies (waits on; a known link never posted twice; returns the waits) + labels per adapter
$env:JIRA_BASE_URL = 'https://j.test'; $env:JIRA_EMAIL = 'a@x'; $env:JIRA_API_TOKEN = 't'; $__trRepo = 'g/p'; $global:ordLog = [Collections.Generic.List[string]]::new(); $global:ordHttp = [Collections.Generic.List[string]]::new()
foreach ($a in 'tracker_jira', 'gitlab', 'tracker_clickup') { . (Join-Path (Split-Path $PSScriptRoot) "skills/crafty/adapters/$a.ps1") }
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
