# Tests of the goody gitlab on recorded answers (CLIs and Invoke-RestMethod mocked; an unknown call fails): tracker, git host,
# branch.protect. Run from a kit clone: pwsh goodies/gitlab/tests.ps1 [-Kit <kit>] -> PASS / FAIL lines; exit 1 on a failure
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/crafty/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/crafty/adapters/gitlab.ps1')
$global:log = [Collections.Generic.List[string]]::new(); $global:failed = 0
$__cfg = '{"tracker":{"org":"acme","project":"Shop","commands":{"view":"mytr view {id}","status":"mytr status {id} {status}","comment":"mytr comment {id} {text}","create":"mytr create {list} {name}","list":"mytr list {list} {status}"}}}' | ConvertFrom-Json; $__trRepo = 'g/p'
$env:JIRA_BASE_URL = 'https://j.test'; $env:JIRA_EMAIL = 'a@x'; $env:JIRA_API_TOKEN = 't'; $env:JIRA_TOKEN = 'pat'; $env:LINEAR_API_KEY = 'k'; $env:AZURE_DEVOPS_EXT_PAT = 'p'; $env:YOUTRACK_URL = 'https://yt.test'; $env:YOUTRACK_TOKEN = 'y'
function Fx($call) { $global:log.Add($call); foreach ($k in $global:fx.Keys) { if ($call -match $k) { return $global:fx[$k] } }; throw "404 no fixture: $call" }
function Invoke-RestMethod($Method, $Uri, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec, $Body, $ContentType, $Form, $InFile) {
 $j = Fx "$Method $Uri $ContentType $($Headers.Authorization) $(if ($Body) { [Text.Encoding]::UTF8.GetString($Body) })"; if ($j) { $j | ConvertFrom-Json } }
foreach ($c in 'clickup', 'gh', 'glab', 'mytr') { Set-Item "function:$c" { $i = [array]::IndexOf($args, '--input'); $global:LASTEXITCODE = 0; Fx "$($args -join ' ') $(if ($i -ge 0) { gc $args[$i + 1] -Raw })" } }
function Run($type, $fx, $id, $list, [scriptblock]$ok) {
 try {
  Initialize-KitTracker -Type $type; $global:fx = $fx; $global:log.Clear()
  $r = @{ v = Get-TrackerTask $id; s = Set-TrackerStatus $id inTest; c = Add-TrackerComment $id 'two words'; n = New-TrackerTask -List $list -Name 'New one' -Description 'd' -Parent $id -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks $list inTest) }
  $pass = [bool](& $ok $r ($global:log -join "`n"))
 } catch { $pass = $false; "  $type error: $_" }
 if (-not $pass) { $global:failed++ }
 "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker ${type}: view, status, comment, create, list"
}
$v = { param($r, $s, $n) $r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.n.id -eq $n -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq $s }
Run gitlab ([ordered]@{ 'PUT projects/g%2Fp/issues/5 .*status:in test' = '{"iid":5}'; 'POST projects/g%2Fp/issues/5/notes .*two words' = '{"id":1}'; 'GET projects/g%2Fp/issues/5 ' = '{"iid":5,"title":"Bug","state":"opened","labels":["status:In Progress"],"description":"- [ ] #6"}'
 'GET projects/g%2Fp/issues/6' = '{"iid":6,"title":"Sub","state":"closed","labels":[]}'; 'users\?username=Ann' = '[{"id":3}]'; 'POST projects/g%2Fp/issues .*"assignee_ids":\[3\]' = '{"iid":12}'; 'PUT projects/g%2Fp/issues/5 .*#12' = '{"iid":5}'
 'issues\?state=opened&labels=status%3Ain%20test' = '[{"iid":7,"title":"A","assignees":[{"id":3,"username":"ann"}]}]' }) 'g/p#5' g/p { param($r, $l) & $v $r 3 12 }
# git host: glab calls, the memo, branch.protect answers
function Check($what, $ok) { if (-not $ok) { $global:failed++ }; "$(if ($ok) { 'PASS' } else { 'FAIL' }) gitlab ${what}" }
$global:calls = [Collections.Generic.List[string]]::new(); $global:post = ''
function glab { $p = "$($args -join ' ')"; $global:calls.Add("glab $p"); $global:LASTEXITCODE = 0
  if ($p -match '-X POST projects/o%2Fr/protected') { $global:post = $p; return '{}' }
  switch -Regex ($p) { 'branches/main$' { '{"allow_force_push":false}'; return } 'branches/dev$' { '{"allow_force_push":true}'; return }
    'branches/(\w+)$' { $global:LASTEXITCODE = 1; Write-Error "glab: $(@{ goodies = '404 Not Found'; locked = '403 Forbidden' }[$Matches[1]] ?? '401 Unauthorized')"; return } }
  '{"iid":5,"state":"merged"}' }
$script:HostType = 'gitlab'
$m = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'
Check 'host: mr.get calls glab api' ($global:calls[-1] -eq 'glab api projects/g%2Fr/merge_requests/5' -and $m.state -eq 'merged')
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5/merge' -Method PUT -Fields @{ squash = 'true' }
Check 'host: mr.merge squashes, removes the branch' ($global:calls[-1] -like 'glab api -X PUT projects/g%2Fr/merge_requests/5/merge -f *squash=true*' -and $global:calls[-1] -like '*should_remove_source_branch=true*')
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; $n = $global:calls.Count; $null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'
Check 'host: a repeated read is memoised' ($global:calls.Count -eq $n)
$v = foreach ($b in 'main', 'dev', 'goodies', 'locked', 'auth') { "$b=$(Invoke-HostVerb 'branch.protect' @{ type = 'gitlab'; repo = 'o/r'; branch = $b } -NoMemo 2>$null)" }
Check "branch.protect: ok, force allowed, set, no admin, auth failure ($($v -join ';'))" (($v -join ';') -match '^main=ok;dev=failed: protected but force push allowed.*;goodies=set;locked=skip: no admin rights on o/r;auth=failed: .*401' -and $global:post -match 'allow_force_push=false')
$null = Invoke-HostVerb 'mr.update' @{ type = 'gitlab'; repo = 'o/r'; n = 5; title = 't'; body = 'b' } -NoMemo
Check 'host: mr.update edits the open MR (PUT, devtools.py mr re-run)' ($global:calls[-1] -like 'glab api -X PUT projects/o%2Fr/merge_requests/5 *')
exit [int]($global:failed -gt 0)
