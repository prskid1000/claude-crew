# Tests of the goody tracker-jira on recorded answers (CLIs and Invoke-RestMethod mocked; an unknown call fails). Run from a kit clone:
#   pwsh goodies/tracker-jira/tests.ps1 [-Kit <kit>]   -> a PASS / FAIL line per tracker type; exit 1 on a failure
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/crafty/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/crafty/adapters/tracker_jira.ps1')
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
$jf = { param($ver, $doc, $who, $srch) [ordered]@{ "GET https://j.test/rest/api/$ver/issue/P-1\?" = '{"key":"P-1","fields":{"summary":"Bug","status":{"name":"In Progress"},"parent":{"key":"P-0"},"subtasks":[{"key":"P-2","fields":{"summary":"Sub","status":{"name":"To Do"}}}],"description":' + $doc + '}}'
 'transitions  ' = '{"transitions":[{"id":"31","name":"QA","to":{"name":"In Test"}}]}'; 'transitions application/json .*"31"' = ''; "P-1/comment .*$(if ($ver -eq 3) { '"type":"doc"' } else { '"body":"two words"' })" = '{"id":"9"}'
 "POST .*/issue .*$who" = '{"key":"P-7"}'; "$srch\?jql=project" = '{"issues":[{"key":"P-3","fields":{"summary":"A","assignee":{"accountId":"u1","name":"u1","displayName":"Ann"}}}]}' } }
Run jira (& $jf 3 '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Steps"}]}]}' '"accountId":"Ann Lee"' 'search/jql') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Basic .*"Subtask"' }
Run jira-server (& $jf 2 '"Steps"' '"name":"Ann Lee"' 'api/2/search') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Bearer pat' -and $l -notmatch 'api/3' }
exit [int]($global:failed -gt 0)
