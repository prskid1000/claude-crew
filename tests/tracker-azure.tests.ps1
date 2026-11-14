#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/tracker-azure.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# Tests of the goody tracker-azure on recorded answers (CLIs and Invoke-RestMethod mocked; an unknown call fails). Run from a kit clone:
#   pwsh goodies/tracker-azure/tests.ps1 [-Kit <kit>]   -> a PASS / FAIL line per tracker type; exit 1 on a failure
param([string]$Kit = (Split-Path $PSScriptRoot))
. (Join-Path $Kit 'skills/crafty/lib.ps1'); . (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/tracker_azure.ps1')
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
  $r = @{ v = Get-TrackerTask $id; s = Set-TrackerStatus $id inTest; c = Add-TrackerComment $id 'two words'; n = New-TrackerTask -List $list -Name 'New one' -Description "Problem: p`nGoal: g`nItems: A1`nAcceptance: a`nLinks: l" -Parent $id -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks $list inTest) }
  $pass = [bool](& $ok $r ($global:log -join "`n"))
 } catch { $pass = $false; "  $type error: $_" }
 if (-not $pass) { $global:failed++ }
 "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker ${type}: view, status, comment, create, list"
}
function Cmt($type, $fx, $id, $cid) {   # comment ids, then a kit comment edited in place and a stale one deleted (lib.ps1 Set-TrackerKitComment, tracker uncomment)
 try { Initialize-KitTracker -Type $type; $global:fx = $fx; $global:log.Clear(); $c = @(Get-TrackerComments $id); $null = __TrA 'comment-edit' @{ id = $id; comment = $c[0].id; text = 'new words' }; $null = __TrA 'comment-delete' @{ id = $id; comment = $c[0].id }; $pass = "$($c[0].id)" -eq $cid -and $global:log.Count -eq 3 } catch { $pass = $false; "  $type error: $_" }
 if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker ${type}: comment ids, comment-edit, comment-delete"
}
$v = { param($r, $s, $n) $r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.n.id -eq $n -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq $s }
Run azure ([ordered]@{ 'GET .*/acme/Shop/_apis/wit/workitems/42\?\$expand' = '{"id":42,"fields":{"System.Title":"Bug","System.State":"In Progress","System.Description":"<div>a<br>b</div>"},"relations":[{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/43"}]}'
 'ids=43&' = '{"value":[{"id":43,"fields":{"System.Title":"Sub"}}]}'; 'PATCH .*workitems/42.*json-patch\+json Basic .*System.State' = '{"id":42}'; 'comments\?api-version=7.1-preview.4 .*two words' = '{"id":1}'
 'POST .*workitems/\$Task.*Hierarchy-Reverse' = '{"id":50}'; 'wiql.*in test' = '{"workItems":[{"id":44}]}'; 'ids=44&' = '{"value":[{"id":44,"fields":{"System.Title":"A","System.AssignedTo":{"uniqueName":"ann@x","displayName":"Ann"}}}]}' }) 42 '' { param($r, $l) (& $v $r ann@x 50) -and $l -match '"value":"in test"' -and $r.v.description -eq "a`nb" }
$md = "<!-- kit:delivery -->`n**Sum**: 1 of 2 · x`n`n| Subtask | MRs |`n|---|---|`n| [S-1](https://a.test/S-1?a=1&b=2) | !8 merged<br>!7 a \| b |`n- one`n- two`n<!-- /kit:delivery -->"
$html = __TrHtml $md; $back = __TrUnHtml $html
$okHtml = $html -match '<table><tr><th>Subtask</th><th>MRs</th></tr><tr><td><a href="https://a.test/S-1\?a=1&amp;b=2">S-1</a></td><td>!8 merged<br>!7 a \| b</td></tr></table>' -and $html -match '<ul><li>one</li><li>two</li></ul>' -and $html -match '<div><b>Sum</b>' -and $html -match '<div>&lt;!-- kit:delivery --&gt;</div>' -and $back -eq $md.Replace("`n`n", "`n")
if (-not $okHtml) { $global:failed++; "  html: $html`n  back: $back" }
"$(if ($okHtml) { 'PASS' } else { 'FAIL' }) tracker azure: Markdown tables, links, breaks, lists -> HTML; read back to the same Markdown (markers kept)"
Cmt azure ([ordered]@{ 'GET .*workItems/42/comments\?' = '{"comments":[{"id":7,"createdBy":{"displayName":"A"},"createdDate":"2026-01-01T00:00:00Z","text":"<div>old</div>"}]}'; 'PATCH .*workItems/42/comments/7\?.*new words' = '{"id":7}'; 'DELETE .*workItems/42/comments/7\?' = '' }) 42 '7'
exit [int]($global:failed -gt 0)
