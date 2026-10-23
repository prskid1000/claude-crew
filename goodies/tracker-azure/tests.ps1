# Tests of the goody tracker-azure on recorded answers (CLIs and Invoke-RestMethod mocked; an unknown call fails). Run from a kit clone:
#   pwsh goodies/tracker-azure/tests.ps1 [-Kit <kit>]   -> a PASS / FAIL line per tracker type; exit 1 on a failure
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/crafty/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/crafty/adapters/tracker_azure.ps1')
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
Run azure ([ordered]@{ 'GET .*/acme/Shop/_apis/wit/workitems/42\?\$expand' = '{"id":42,"fields":{"System.Title":"Bug","System.State":"In Progress","System.Description":"<div>a<br>b</div>"},"relations":[{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/43"}]}'
 'ids=43&' = '{"value":[{"id":43,"fields":{"System.Title":"Sub"}}]}'; 'PATCH .*workitems/42.*json-patch\+json Basic .*System.State' = '{"id":42}'; 'comments\?api-version=7.1-preview.4 .*two words' = '{"id":1}'
 'POST .*workitems/\$Task.*Hierarchy-Reverse' = '{"id":50}'; 'wiql.*in test' = '{"workItems":[{"id":44}]}'; 'ids=44&' = '{"value":[{"id":44,"fields":{"System.Title":"A","System.AssignedTo":{"uniqueName":"ann@x","displayName":"Ann"}}}]}' }) 42 '' { param($r, $l) (& $v $r ann@x 50) -and $l -match '"value":"in test"' -and $r.v.description -eq "a`nb" }
exit [int]($global:failed -gt 0)
