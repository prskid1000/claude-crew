# Tests of the extra tracker-youtrack on recorded answers (CLIs and Invoke-RestMethod mocked; an unknown call fails). Run from a kit clone:
#   pwsh extras/tracker-youtrack/tests.ps1 [-Kit <kit>]   -> a PASS / FAIL line per tracker type; exit 1 on a failure
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/dev-kit/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/dev-kit/adapters/tracker_youtrack.ps1')
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
Run youtrack ([ordered]@{ 'GET https://yt.test/api/issues/D-1\?' = '{"idReadable":"D-1","summary":"Bug","subtasks":{"issues":[{"idReadable":"D-2","summary":"Sub"}]},"customFields":[{"name":"State","value":{"name":"In Progress"}}]}'
 'commands .*State \{in test\}' = '{}'; 'D-1/comments.*two words' = '{"id":"c"}'; 'admin/projects' = '[{"id":"0-1","shortName":"OPS"},{"id":"0-2","shortName":"D"}]'; 'POST .*issues\?fields.*"0-2"' = '{"idReadable":"D-9"}'
 'commands .*subtask of D-1 for Ann Lee Priority Major' = '{}'; 'GET .*issues\?query=project%3A%20%7BD%7D' = '[{"idReadable":"D-3","summary":"A","customFields":[{"name":"Assignee","value":{"login":"ann"}}]}]' }) D-1 D { param($r, $l) (& $v $r ann D-9) -and $l -match 'Bearer y' }
exit [int]($global:failed -gt 0)
