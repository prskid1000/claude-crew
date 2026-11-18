#Requires -Version 7
<#
tests/tracker-adapters.tests.ps1: the tracker adapters (jira, jira-server, linear, youtrack, azure, gitlab, clickup) and the gitlab
git host on recorded answers (CLIs and Invoke-RestMethod mocked; an unknown call fails): one prelude, a block per adapter.
Usage: pwsh -NoProfile -File tests/tracker-adapters.tests.ps1 [-Kit <kit>] (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (Split-Path $PSScriptRoot))
. (Join-Path $Kit 'skills/crafty/lib.ps1')
foreach ($a in 'tracker_jira', 'tracker_linear', 'tracker_youtrack', 'tracker_azure', 'gitlab', 'tracker_clickup') { . (Join-Path (Split-Path $PSScriptRoot) "skills/crafty/adapters/$a.ps1") }
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
  $r = @{ v = Get-TrackerTask $id; s = Set-TrackerStatus $id 'in-test'; c = Add-TrackerComment $id 'two words'; n = New-TrackerTask -List $list -Name 'New one' -Description "Problem: p`nGoal: g`nItems: A1`nAcceptance: a`nLinks: l" -Parent $id -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks $list inTest) }   # in-test: the kebab alias of inTest (2026-11-18)
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
# ---- jira
$jf = { param($ver, $doc, $who, $srch) [ordered]@{ "GET https://j.test/rest/api/$ver/issue/P-1\?" = '{"key":"P-1","fields":{"summary":"Bug","status":{"name":"In Progress"},"parent":{"key":"P-0"},"subtasks":[{"key":"P-2","fields":{"summary":"Sub","status":{"name":"To Do"}}}],"description":' + $doc + '}}'
 'transitions  ' = '{"transitions":[{"id":"31","name":"QA","to":{"name":"In Test"}}]}'; 'transitions application/json .*"31"' = ''; "P-1/comment .*$(if ($ver -eq 3) { '"type":"doc"' } else { '"body":"two words"' })" = '{"id":"9"}'
 "POST .*/issue .*$who" = '{"key":"P-7"}'; "$srch\?jql=project" = '{"issues":[{"key":"P-3","fields":{"summary":"A","assignee":{"accountId":"u1","name":"u1","displayName":"Ann"}}}]}' } }
Run jira (& $jf 3 '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Steps"}]}]}' '"accountId":"Ann Lee"' 'search/jql') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Basic .*"Subtask"' }
Run jira-server (& $jf 2 '"Steps"' '"name":"Ann Lee"' 'api/2/search') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Bearer pat' -and $l -notmatch 'api/3' }
$md = "<!-- kit:delivery -->`n**Sum**: 1 of 2`n`n| Subtask | MRs |`n|---|---|`n| [S-1](https://j.test/S-1) | !8 merged<br>!7 a \| b |`n- one`n<!-- /kit:delivery -->"
$adf = __TrAdf $md; $aj = $adf | ConvertTo-Json -Depth 20 -Compress; $back = (__TrAdfText ($aj | ConvertFrom-Json)).Trim()
$okAdf = $aj -match '"type":"table"' -and $aj -match '"type":"tableHeader"' -and $aj -match '"href":"https://j.test/S-1"' -and $aj -match '"type":"hardBreak"' -and $aj -match '"type":"strong"' -and $aj -match '"type":"bulletList"' -and $back -eq $md.Replace("`n`n", "`n")
$wk = __TrWiki $md
$okWiki = $wk -eq "<!-- kit:delivery -->`n*Sum*: 1 of 2`n||Subtask||MRs||`n|[S-1|https://j.test/S-1]|!8 merged \\ !7 a / b|`n* one`n<!-- /kit:delivery -->" -and (__TrWiki $wk) -eq $wk
if (-not ($okAdf -and $okWiki)) { $global:failed++; "  adf: $back`n  wiki: $wk" }
"$(if ($okAdf -and $okWiki) { 'PASS' } else { 'FAIL' }) tracker jira / jira-server: Markdown tables, links, breaks, lists -> ADF (round trip to the same Markdown) / wiki (stable when re-sent)"
Cmt jira ([ordered]@{ 'GET .*api/3/issue/P-1/comment\?maxResults' = '{"comments":[{"id":"10007","author":{"displayName":"A"},"created":"2026-01-01T00:00:00Z","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"old"}]}]}}]}'; 'PUT .*api/3/issue/P-1/comment/10007 .*new words' = '{"id":"10007"}'; 'DELETE .*api/3/issue/P-1/comment/10007' = '' }) P-1 '10007'
# K54 move: parent field set / cleared (top-level); another project refused before any call
try { Initialize-KitTracker -Type jira; $global:fx = [ordered]@{ 'PUT .*api/3/issue/P-1 ' = '' }; $global:log.Clear()
  $m1 = Move-TrackerTask P-1 -Parent P-0; $m2 = Move-TrackerTask P-1 -Top; $mx = try { Move-TrackerTask P-1 -List OPS; 'no throw' } catch { "$_" }; $ml = $global:log -join "`n"
  $pass = $m1 -eq 'moved P-1: under P-0' -and $ml -match '"parent":\{"key":"P-0"\}' -and $ml -match '"parent":null' -and $mx -match "another project \(OPS\) needs Jira's bulk move" -and $global:log.Count -eq 2 } catch { $pass = $false; "  jira move error: $_" }
if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker jira: move under a parent, top-level (parent null); another project refused before the call"
# ---- linear
Run linear ([ordered]@{ 'identifier title url description' = '{"data":{"issue":{"identifier":"E-1","title":"Bug","state":{"name":"In Progress"},"team":{"key":"E"},"children":{"nodes":[{"identifier":"E-2","title":"Sub"}]}}}}'
 'team \{ states' = '{"data":{"issue":{"team":{"states":{"nodes":[{"id":"s1","name":"Backlog"},{"id":"s2","name":"In Test"}]}}}}}'; '"stateId":"s2"' = '{"data":{"issueUpdate":{"success":true}}}'
 '"b":"two words"' = '{"data":{"commentCreate":{"success":true}}}'; 'teams\(filter' = '{"data":{"teams":{"nodes":[{"id":"t1"}]}}}'; 'issue\(id: \$id\) \{ id' = '{"data":{"issue":{"id":"uuid-1"}}}'
 'users\(filter' = '{"data":{"users":{"nodes":[{"id":"u1"}]}}}'; '"parentId":"uuid-1"' = '{"data":{"issueCreate":{"issue":{"identifier":"E-9"}}}}'
 '"eqIgnoreCase":"in test"' = '{"data":{"issues":{"nodes":[{"identifier":"E-3","title":"A","assignee":{"id":"u1","name":"Ann"}}]}}}' }) E-1 E { param($r, $l) & $v $r u1 E-9 }
Cmt linear ([ordered]@{ 'comments\(first: 200\)' = '{"data":{"issue":{"comments":{"nodes":[{"id":"cm-7","body":"old","createdAt":"2026-01-01T00:00:00Z","user":{"name":"A"}}]}}}}'; '(?=.*commentUpdate)(?=.*cm-7)(?=.*new words)' = '{"data":{"commentUpdate":{"success":true}}}'; '(?=.*commentDelete)(?=.*cm-7)' = '{"data":{"commentDelete":{"success":true}}}' }) E-1 'cm-7'
# K54 move: team (from its key) and parent in one issueUpdate; top-level = parentId null
try { Initialize-KitTracker -Type linear; $global:fx = [ordered]@{ 'teams\(filter' = '{"data":{"teams":{"nodes":[{"id":"t1"}]}}}'; 'issue\(id: \$id\) \{ id' = '{"data":{"issue":{"id":"uuid-0"}}}'; 'issueUpdate' = '{"data":{"issueUpdate":{"success":true}}}' }; $global:log.Clear()
  $m1 = Move-TrackerTask E-1 -Parent E-0 -List OPS; $m2 = Move-TrackerTask E-1 -Top; $ml = $global:log -join "`n"
  $pass = $m1 -eq 'moved E-1 to team OPS under E-0' -and $ml -match '(?=.*issueUpdate)(?=.*"teamId":"t1")(?=.*"parentId":"uuid-0")' -and $ml -match '(?=.*issueUpdate)(?=.*"parentId":null)' } catch { $pass = $false; "  linear move error: $_" }
if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker linear: move to a team and under a parent (one issueUpdate), top-level = parentId null"
# ---- youtrack
Run youtrack ([ordered]@{ 'GET https://yt.test/api/issues/D-1\?' = '{"idReadable":"D-1","summary":"Bug","subtasks":{"issues":[{"idReadable":"D-2","summary":"Sub"}]},"customFields":[{"name":"State","value":{"name":"In Progress"}}]}'
 'commands .*State \{in test\}' = '{}'; 'D-1/comments.*two words' = '{"id":"c"}'; 'admin/projects' = '[{"id":"0-1","shortName":"OPS"},{"id":"0-2","shortName":"D"}]'; 'POST .*issues\?fields.*"0-2"' = '{"idReadable":"D-9"}'
 'commands .*subtask of D-1 for Ann Lee Priority Major' = '{}'; 'GET .*issues\?query=project%3A%20%7BD%7D' = '[{"idReadable":"D-3","summary":"A","customFields":[{"name":"Assignee","value":{"login":"ann"}}]}]' }) D-1 D { param($r, $l) (& $v $r ann D-9) -and $l -match 'Bearer y' }
Cmt youtrack ([ordered]@{ 'GET .*issues/D-1/comments\?fields=id' = '[{"id":"4-7","text":"old","created":1767225600000,"author":{"login":"a"}}]'; 'POST .*issues/D-1/comments/4-7\?fields=id .*new words' = '{"id":"4-7"}'; 'DELETE .*issues/D-1/comments/4-7' = '' }) D-1 '4-7'
# K54 move: project, the old parent's link out, the new one in; top-level: only the old link out
try { Initialize-KitTracker -Type youtrack; $global:fx = [ordered]@{ 'admin/projects' = '[{"id":"0-2","shortName":"D"}]'; 'GET .*issues/D-5\?fields' = '{"idReadable":"D-5","summary":"S","parent":{"issues":[{"idReadable":"D-1"}]}}'; 'POST .*issues/D-5\?fields=idReadable .*"0-2"' = '{"idReadable":"D-5"}'; 'commands ' = '{}' }; $global:log.Clear()
  $m1 = Move-TrackerTask D-5 -Parent D-2 -List D; $m2 = Move-TrackerTask D-5 -Top; $ml = $global:log -join "`n"
  $pass = $m1 -eq 'moved D-5 to D under D-2' -and $ml -match 'remove subtask of D-1' -and $ml -match '"query":"subtask of D-2"' -and @($global:log -match 'commands ').Count -eq 3 } catch { $pass = $false; "  youtrack move error: $_" }
if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker youtrack: move to a project and a new parent (old link out), top-level"
# ---- azure
Run azure ([ordered]@{ 'GET .*/acme/Shop/_apis/wit/workitems/42\?\$expand' = '{"id":42,"fields":{"System.Title":"Bug","System.State":"In Progress","System.Description":"<div>a<br>b</div>"},"relations":[{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/43"}]}'
 'ids=43&' = '{"value":[{"id":43,"fields":{"System.Title":"Sub"}}]}'; 'PATCH .*workitems/42.*json-patch\+json Basic .*System.State' = '{"id":42}'; 'comments\?api-version=7.1-preview.4 .*two words' = '{"id":1}'
 'POST .*workitems/\$Task.*Hierarchy-Reverse' = '{"id":50}'; 'wiql.*in test' = '{"workItems":[{"id":44}]}'; 'ids=44&' = '{"value":[{"id":44,"fields":{"System.Title":"A","System.AssignedTo":{"uniqueName":"ann@x","displayName":"Ann"}}}]}' }) 42 '' { param($r, $l) (& $v $r ann@x 50) -and $l -match '"value":"in test"' -and $r.v.description -eq "a`nb" }
$md = "<!-- kit:delivery -->`n**Sum**: 1 of 2 · x`n`n| Subtask | MRs |`n|---|---|`n| [S-1](https://a.test/S-1?a=1&b=2) | !8 merged<br>!7 a \| b |`n- one`n- two`n<!-- /kit:delivery -->"
$html = __TrHtml $md; $back = __TrUnHtml $html
$okHtml = $html -match '<table><tr><th>Subtask</th><th>MRs</th></tr><tr><td><a href="https://a.test/S-1\?a=1&amp;b=2">S-1</a></td><td>!8 merged<br>!7 a \| b</td></tr></table>' -and $html -match '<ul><li>one</li><li>two</li></ul>' -and $html -match '<div><b>Sum</b>' -and $html -match '<div>&lt;!-- kit:delivery --&gt;</div>' -and $back -eq $md.Replace("`n`n", "`n")
if (-not $okHtml) { $global:failed++; "  html: $html`n  back: $back" }
"$(if ($okHtml) { 'PASS' } else { 'FAIL' }) tracker azure: Markdown tables, links, breaks, lists -> HTML; read back to the same Markdown (markers kept)"
Cmt azure ([ordered]@{ 'GET .*workItems/42/comments\?' = '{"comments":[{"id":7,"createdBy":{"displayName":"A"},"createdDate":"2026-01-01T00:00:00Z","text":"<div>old</div>"}]}'; 'PATCH .*workItems/42/comments/7\?.*new words' = '{"id":7}'; 'DELETE .*workItems/42/comments/7\?' = '' }) 42 '7'
# K54 move: the old parent link removed by index, the new one added, the area path set; top-level: only the removal
try { Initialize-KitTracker -Type azure; $global:fx = [ordered]@{ 'GET .*workitems/42\?\$expand=relations' = '{"id":42,"relations":[{"rel":"System.LinkTypes.Related","url":"u"},{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"p"}]}'; 'PATCH .*workitems/42\?' = '{"id":42}' }; $global:log.Clear()
  $m1 = Move-TrackerTask 42 -Parent 7 -List 'Shop\Team'; $m2 = Move-TrackerTask 42 -Top; $pl = @($global:log -match '^PATCH')
  $o0 = @(($pl[0] -replace '^[^\[]*') | ConvertFrom-Json); $o1 = @(($pl[1] -replace '^[^\[]*') | ConvertFrom-Json)   # key order differs per process
  $pass = $m1 -eq 'moved 42 to Shop\Team under 7' -and "$($o0.op -join ',')|$($o0.path -join ',')" -eq 'remove,add,add|/relations/1,/relations/-,/fields/System.AreaPath' -and $o0[1].value.url -match 'workItems/7$' -and
    "$($o1.op -join ',')|$($o1.path -join ',')" -eq 'remove|/relations/1' } catch { $pass = $false; "  azure move error: $_" }
if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker azure: move swaps the parent link (old one out by index), sets the area path; top-level removes the link"
# ---- gitlab
Run gitlab ([ordered]@{ 'PUT projects/g%2Fp/issues/5 .*status:in test' = '{"iid":5}'; 'POST projects/g%2Fp/issues/5/notes .*two words' = '{"id":1}'; 'GET projects/g%2Fp/issues/5 ' = '{"iid":5,"title":"Bug","state":"opened","labels":["status:In Progress"],"description":"- [ ] #6"}'
 'GET projects/g%2Fp/issues/6' = '{"iid":6,"title":"Sub","state":"closed","labels":[]}'; 'users\?username=Ann' = '[{"id":3}]'; 'POST projects/g%2Fp/issues .*"assignee_ids":\[3\]' = '{"iid":12}'; 'PUT projects/g%2Fp/issues/5 .*#12' = '{"iid":5}'
 'issues\?state=opened&labels=status%3Ain%20test' = '[{"iid":7,"title":"A","assignees":[{"id":3,"username":"ann"}]}]' }) 'g/p#5' g/p { param($r, $l) & $v $r 3 12 }
Cmt gitlab ([ordered]@{ 'GET projects/g%2Fp/issues/5/notes' = '[{"id":77,"author":{"username":"a"},"created_at":"2026-01-01T00:00:00Z","body":"old","system":false}]'; 'PUT projects/g%2Fp/issues/5/notes/77 .*new words' = '{"id":77}'; 'DELETE projects/g%2Fp/issues/5/notes/77' = '' }) 'g/p#5' '77'
# K54 move: a task-list line on the parent once (an existing one kept), the issue move API to another project, top-level refused
try { Initialize-KitTracker -Type gitlab; $global:fx = [ordered]@{ 'GET projects/g%2Fp/issues/5 ' = '{"iid":5,"description":"x\n- [ ] #6"}'; 'PUT projects/g%2Fp/issues/5 .*#8' = '{"iid":5}'; 'GET projects/g%2Fq ' = '{"id":44}'; 'POST projects/g%2Fp/issues/8/move .*"to_project_id":44' = '{"iid":3}' }; $global:log.Clear()
  $m1 = Move-TrackerTask 'g/p#8' -Parent 'g/p#5'; $m2 = Move-TrackerTask 'g/p#6' -Parent 'g/p#5'; $m3 = Move-TrackerTask 'g/p#8' -List g/q; $mt = try { Move-TrackerTask 'g/p#8' -Top; 'no throw' } catch { "$_" }
  $ok = $m1 -eq 'moved #8 under g/p#5' -and @($global:log -match 'PUT projects/g%2Fp/issues/5 ').Count -eq 1 -and $m2 -eq 'moved #6 under g/p#5' -and $m3 -eq 'moved #8 to g/q as #3' -and $mt -match 'task-list line on its parent' } catch { $ok = $false; "  gitlab move error: $_" }
if (-not $ok) { $global:failed++ }; "$(if ($ok) { 'PASS' } else { 'FAIL' }) tracker gitlab: move (a task-list line once, the move API to another project, top-level refused)"
# git host: glab calls, the memo, branch.protect answers
function Check($what, $ok) { if (-not $ok) { $global:failed++ }; "$(if ($ok) { 'PASS' } else { 'FAIL' }) gitlab ${what}" }
$global:calls = [Collections.Generic.List[string]]::new(); $global:post = ''
function glab { $p = "$($args -join ' ')"; $global:calls.Add("glab $p"); $global:LASTEXITCODE = 0
  if ($p -match '-X POST projects/o%2Fr/protected') { $global:post = $p; return '{}' }
  switch -Regex ($p) { 'branches/main$' { '{"allow_force_push":false}'; return } 'branches/dev$' { '{"allow_force_push":true}'; return }
    'branches/(\w+)$' { $global:LASTEXITCODE = 1; Write-Error "glab: $(@{ release = '404 Not Found'; locked = '403 Forbidden' }[$Matches[1]] ?? '401 Unauthorized')"; return } }
  '{"iid":5,"state":"merged"}' }
$script:HostType = 'gitlab'
$m = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'
Check 'host: mr.get calls glab api' ($global:calls[-1] -eq 'glab api projects/g%2Fr/merge_requests/5' -and $m.state -eq 'merged')
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5/merge' -Method PUT -Fields @{ squash = 'true' }
Check 'host: mr.merge squashes, removes the branch' ($global:calls[-1] -like 'glab api -X PUT projects/g%2Fr/merge_requests/5/merge -f *squash=true*' -and $global:calls[-1] -like '*should_remove_source_branch=true*')
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; $n = $global:calls.Count; $null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'
Check 'host: a repeated read is memoised' ($global:calls.Count -eq $n)
$null = Invoke-HostVerb 'mr.merge' @{ type = 'gitlab'; repo = 'g/r'; n = 5; method = 'merge' }
Check 'host: a deploy MR (method merge) merges with squash off' ($global:calls[-1] -like '*merge_requests/5/merge*squash=false*')
$v = foreach ($b in 'main', 'dev', 'release', 'locked', 'auth') { "$b=$(Invoke-HostVerb 'branch.protect' @{ type = 'gitlab'; repo = 'o/r'; branch = $b } -NoMemo 2>$null)" }
Check "branch.protect: ok, force allowed, set, no admin, auth failure ($($v -join ';'))" (($v -join ';') -match '^main=ok;dev=failed: protected but force push allowed.*;release=set;locked=skip: no admin rights on o/r;auth=failed: .*401' -and $global:post -match 'allow_force_push=false')
$null = Invoke-HostVerb 'mr.update' @{ type = 'gitlab'; repo = 'o/r'; n = 5; title = 't'; body = 'b' } -NoMemo
Check 'host: mr.update edits the open MR (PUT, devtools.py mr re-run)' ($global:calls[-1] -like 'glab api -X PUT projects/o%2Fr/merge_requests/5 *')
# ---- clickup (its own clickup mock; dry-run comments, checklists, REST moves)
$global:log.Clear()
function clickup { $global:LASTEXITCODE = 0; Fx ($args -join ' ') }
$global:fx = [ordered]@{ 'task view C1' = '{"id":"C1","name":"Bug","status":{"status":"In Progress"},"list":{"id":"L9"},"subtasks":[{"id":"C2","name":"Sub"}],"markdown_description":"Testing doc (human): https://d/h"}'
  'comment list C1 --json' = '[{"id":"55","user":{"username":"kit"},"date":"1700000000000","comment_text":"round one\n\n[kit:qa-result]"},{"id":"56","user":{"username":"ann"},"date":"1700000001000","comment_text":"a person"}]'
  'comment edit 55 round two' = '{}'
  'status set in test C1' = 'Status set'; 'comment add C1 two words' = '{"id":"90"}'; 'member list' = '[{"id":7,"username":"Ann Lee"}]'
  '(?s)task create --list-id L9 .*--assignee 7 --parent C1' = '{"id":"C5"}'; 'task create --list-id L9 --name x .*--parent C1' = '{"id":"C6"}'; 'task list --list-id L9 --status in test --page 0' = '[{"id":"C3","name":"A","assignees":[{"id":7,"username":"ann"}]}]' }
try {
  Initialize-KitTracker -Type clickup
  $r = @{ v = Get-TrackerTask C1; s = Set-TrackerStatus C1 inTest; c = Add-TrackerComment C1 'two words'; n = New-TrackerTask -List L9 -Name 'New one' -Description "Problem: p`nGoal: g`nItems: A1`nAcceptance: a`nLinks: l" -Parent C1 -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks L9 inTest); p = __TrA 'create' @{ name = 'x'; description = 'd'; parent = 'C1' } }
  $pass = $r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.n.id -eq 'C5' -and $r.p.id -eq 'C6' -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq 7 -and ($global:log -join "`n") -match '--priority 2'
} catch { $pass = $false; "  clickup error: $_" }
if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: view, status, comment, create (no list: the parent's), list on recorded answers"
$global:fx.Insert(0, 'task view P2', '{"id":"P2","list":{"id":"L7"}}'); $global:fx.Insert(0, 'task view P3', '{"id":"P3","list":{"id":"L9"}}'); $global:fx['task create --list-id L7 .*--parent P2'] = '{"id":"C7"}'; $global:fx['task create --list-id L9 --name w .*--parent P4'] = '{"id":"C8"}'; $global:log.Clear()
$sw = [IO.StringWriter]::new(); $se = [Console]::Error; [Console]::SetError($sw)
try { $xw = __TrA 'create' @{ list = 'L9'; name = 'y'; description = 'd'; parent = 'P2' }; $xe = try { $null = __TrA 'create' @{ list = 'L9'; name = 'z'; description = 'd'; parent = 'P3' }; 'no throw' } catch { "$_" }; $xv = __TrA 'create' @{ list = 'L9'; name = 'w'; description = 'd'; parent = 'P4' } } finally { [Console]::SetError($se) }
$pass = $xw.id -eq 'C7' -and $xv.id -eq 'C8' -and "$sw" -match 'parent P2 is in list L7, not L9' -and $xe -match 'subtask of P3 failed, nothing created' -and -not ($global:log -match 'create --list-id L9 --name z(?!.*--parent)'); if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: -Parent in another list -> created in the parent's list, said on stderr; a failed parent look-up keeps -List; a failed subtask create throws, never a silent top-level task ($xe)"
$global:log.Clear(); $dsc = "Problem: p`nGoal: g`nItems: A1`nAcceptance: a`nLinks: l"; $pw = try { $null = New-TrackerTask -List L9 -Name 'New one' -Description $dsc -Parent C1 -Assignee 'Ann Lee' -Priority urgent -NewTask t; 'ok' } catch { "$_" }; $pb = try { $null = New-TrackerTask -List L9 -Name 'New one' -Description $dsc -Parent C1 -Priority asap -NewTask t; 'no throw' } catch { "$_" }
$pass = $pw -eq 'ok' -and ($global:log -join "`n") -match '--priority 1' -and $pb -match "priority 'asap' unknown: 1-4 or urgent" -and -not ($global:log -match 'priority asap'); if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a priority word maps to 1-4 (urgent -> 1); an unknown one is refused before the CLI ($pw | $pb)"
$global:log.Clear(); try { $null = Set-TrackerKitComment C1 qa-result 'round two'; $pass = ($global:log -join "`n") -match '(?m)^comment edit 55 round two$' -and ($global:log -join "`n") -notmatch 'comment (add|delete)|56' } catch { $pass = $false; "  clickup error: $_" }
if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a kit comment's next round edits it (comment edit <id>); a person's comment untouched"
$global:log.Clear(); $nl = try { @(Get-TrackerTasks '' inTest 3>$null); 'no throw' } catch { "$_" }
$pass = $nl -match 'tracker list needs -List <id>' -and -not ($global:log -match 'task list'); if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: list with no -List and no tracker.list stops before the CLI ($nl)"
$f = Join-Path ([IO.Path]::GetTempPath()) "clickup-body-$PID.md"; 'body text' | Set-Content $f
Initialize-KitTracker -Type clickup -DryRun
$out = Add-TrackerComment 12 $f 6>&1 | Out-String; Remove-Item $f
$pass = $out -match 'comment add 12 "body text'; if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a dry-run comment sends the file's text"
$out = Add-TrackerComment 12 '**Solution:** fixed `a.b` · [MR !7](https://h/7) · https://h/8 · [https://h/9](https://h/9)' 6>&1 | Out-String
$pass = $out -match [regex]::Escape('Solution: fixed a.b · MR !7 (https://h/7) · https://h/8 · https://h/9') -and $out -notmatch '\*\*|`|\]\('; if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a comment goes as plain text (bold and code marks dropped, [text](url) -> text (url)) ($($out.Trim()))"
Initialize-KitTracker -Type clickup; $global:log.Clear()
$global:fx.Insert(0, 'task view C1 --jq .checklists','[{"id":"K1","name":"Items","items":[{"id":"i1","name":"A1 · High · old","resolved":false},{"id":"i9","name":"a person''s","resolved":false}]}]')
$global:fx['task checklist item (add|edit|resolve) K1'] = 'ok'
$ck = try { __TrA 'checklist' @{ id = 'C1'; name = 'Items'; items = @(@{ text = 'A1 · High · new'; done = $true }, @{ text = 'A2 · Low · two'; done = $false }) } } catch { "$_" }
$cl = $global:log -join "`n"
$pass = $ck -match '3 change' -and $cl -match '(?m)^task checklist item edit K1 i1 --name A1 · High · new$' -and $cl -match '(?m)^task checklist item add K1 A2 · Low · two$' -and $cl -match '(?m)^task checklist item resolve K1 i1$' -and $cl -notmatch 'i9|checklist add C1'
if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: checklist renames, adds and resolves the kit's items by id, a person's item untouched ($ck)"
$global:log.Clear(); $global:fx['task view C1 --jq .checklists'] = ('[{"id":"K1","name":"Items","items":[{"id":"i1","name":"A1 · x · u","resolved":true},{"id":"i2","name":"A2 · y","resolved":true},{"id":"i3","name":"A2 · y","resolved":true},{"id":"i4","name":"P1-JS-01 · other task · u","resolved":true},{"id":"i9","name":"a person''s · note","resolved":false}]}]')
$global:fx['task checklist item remove K1'] = 'ok'
$ck = try { __TrA 'checklist' @{ id = 'C1'; name = 'Items'; prune = $true; items = @(@{ text = 'A1 · x · u · held: real-API check'; done = $false }, @{ text = 'A2 · y'; done = $true }) } } catch { "$_" }
$cl = $global:log -join "`n"
$pass = $cl -match '(?m)^task checklist item remove K1 i1$' -and $cl -match '(?m)^task checklist item add K1 A1 · x · u · held: real-API check$' -and $cl -match '(?m)^task checklist item remove K1 i3$' -and $cl -match '(?m)^task checklist item remove K1 i4$' -and $cl -notmatch 'remove K1 i[29]|resolve K1 i2'
if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: checklist unticks a resolved item (remove + add: no unresolve verb); prune drops a kit line not wanted and a repeat, a person's line kept ($ck)"
# K54: re-parent through the REST API (the CLI has no --parent), the stored token as the header; another list: refused before the call
$global:http = [Collections.Generic.List[string]]::new(); function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) { $global:http.Add("$Method $Uri $($Body | ConvertTo-Json -Compress) $($Headers.Authorization)"); @{ id = 'C9' } }
$env:CLICKUP_API_TOKEN = 'tk-test'; $global:fx.Insert(0, 'task view C9 --json', '{"id":"C9","list":{"id":"L9"}}')
$__cfg = [pscustomobject]@{ tracker = [pscustomobject]@{ workspace = 'W1' } }
try { $rp = Move-TrackerTask C9 -Parent C1; $rx = try { Move-TrackerTask C9 -Parent P2; 'no throw' } catch { "$_" }; $rt = try { Move-TrackerTask C9 -Top; 'no throw' } catch { "$_" }; $rl = Move-TrackerTask C9 -List L7 -Parent P2 } finally { Remove-Item Env:CLICKUP_API_TOKEN; $__cfg = $null }
$pass = $rp -eq 'moved C9 under C1' -and $global:http.Count -eq 3 -and $global:http[0] -eq 'PUT https://api.clickup.com/api/v2/task/C9 {"parent":"C1"} tk-test' -and $rx -match 'C9 is in list L9, P2 in list L7: a subtask lives in its parent.s list \(-List L7 moves it first' -and $rt -match 'cannot make a subtask top-level' -and
  $rl -eq 'moved C9 to list L7 under P2' -and $global:http[1] -eq 'PUT https://api.clickup.com/api/v3/workspaces/W1/tasks/C9/home_list/L7 null tk-test' -and $global:http[2] -match 'task/C9 \{"parent":"P2"\}'; if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: move under a parent (REST v2 PUT with the stored token), to another list (v3 home_list, then the parent); a parent in another list without -List and top-level are refused before a call ($rp | $rx | $rt | $rl)"
$sk = @('in-test', 'in test', 'In_Test', 'inTest', 'failed-testing', 'for review') | ForEach-Object { ConvertTo-TrackerStatusKey $_ }
$pass = ($sk -join ',') -eq 'inTest,inTest,inTest,inTest,failedTesting,for review'; if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker status: kebab, spaced and snake forms of a kit status key resolve to the key for every adapter; a board name stays as given ($($sk -join ','))"
exit [int]($global:failed -gt 0)
