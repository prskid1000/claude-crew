#Requires -Version 7
<#
tests/tracker-adapters-2.tests.ps1: the linear, youtrack and azure tracker adapters' K54 moves and native caps (dependencies, labels,
statuses, azure checklist) on recorded answers (Invoke-RestMethod mocked; an unknown call fails; no account: replayed API). Split from tracker-adapters (file cap).
Usage: pwsh -NoProfile -File tests/tracker-adapters-2.tests.ps1 [-Kit <kit>] (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (Split-Path $PSScriptRoot))
Set-Item Env:CLAUDE_RUNTIME ($trRt = Join-Path ([IO.Path]::GetTempPath()) "kit-tr2-rt-$PID")   # own cache
. (Join-Path $Kit 'skills/crafty/lib.ps1')
foreach ($a in 'tracker-linear', 'tracker-youtrack', 'tracker-azure') { . (Join-Path $Kit "skills/crafty/adapters/$a.ps1") }
$global:log = [Collections.Generic.List[string]]::new(); $global:failed = 0
$__cfg = '{"tracker":{"org":"acme","project":"Shop"}}' | ConvertFrom-Json
$env:LINEAR_API_KEY = 'k'; $env:AZURE_DEVOPS_EXT_PAT = 'p'; $env:YOUTRACK_URL = 'https://yt.test'; $env:YOUTRACK_TOKEN = 'y'
function Fx($call) { $global:log.Add($call); foreach ($k in $global:fx.Keys) { if ($call -match $k) { return $global:fx[$k] } }; throw "404 no fixture: $call" }
function Invoke-RestMethod($Method, $Uri, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec, $Body, $ContentType, $Form, $InFile) {
 $j = Fx "$Method $Uri $ContentType $($Headers.Authorization) $(if ($Body) { [Text.Encoding]::UTF8.GetString($Body) })"; if ($j) { $j | ConvertFrom-Json } }
# ---- moves (K54)
# linear: team (from its key) and parent in one issueUpdate; top-level = parentId null
try { Initialize-KitTracker -Type linear; $global:fx = [ordered]@{ 'teams\(filter' = '{"data":{"teams":{"nodes":[{"id":"t1"}]}}}'; 'issue\(id: \$id\) \{ id' = '{"data":{"issue":{"id":"uuid-0"}}}'; 'issueUpdate' = '{"data":{"issueUpdate":{"success":true}}}' }; $global:log.Clear()
  $m1 = Move-TrackerTask E-1 -Parent E-0 -List OPS; $m2 = Move-TrackerTask E-1 -Top; $ml = $global:log -join "`n"
  $pass = $m1 -eq 'moved E-1 to team OPS under E-0' -and $ml -match '(?=.*issueUpdate)(?=.*"teamId":"t1")(?=.*"parentId":"uuid-0")' -and $ml -match '(?=.*issueUpdate)(?=.*"parentId":null)' } catch { $pass = $false; "  linear move error: $_" }
if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker linear: move to a team and under a parent (one issueUpdate), top-level = parentId null"
# youtrack: project, the old parent's link out, the new one in; top-level: only the old link out
try { Initialize-KitTracker -Type youtrack; $global:fx = [ordered]@{ 'admin/projects' = '[{"id":"0-2","shortName":"D"}]'; 'GET .*issues/D-5\?fields' = '{"idReadable":"D-5","summary":"S","parent":{"issues":[{"idReadable":"D-1"}]}}'; 'POST .*issues/D-5\?fields=idReadable .*"0-2"' = '{"idReadable":"D-5"}'; 'commands ' = '{}' }; $global:log.Clear()
  $m1 = Move-TrackerTask D-5 -Parent D-2 -List D; $m2 = Move-TrackerTask D-5 -Top; $ml = $global:log -join "`n"
  $pass = $m1 -eq 'moved D-5 to D under D-2' -and $ml -match 'remove subtask of D-1' -and $ml -match '"query":"subtask of D-2"' -and @($global:log -match 'commands ').Count -eq 3 } catch { $pass = $false; "  youtrack move error: $_" }
if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker youtrack: move to a project and a new parent (old link out), top-level"
# azure: old parent link removed by index, new one added, area path set; top-level: removal only
try { Initialize-KitTracker -Type azure; $global:fx = [ordered]@{ 'GET .*workitems/42\?\$expand=relations' = '{"id":42,"relations":[{"rel":"System.LinkTypes.Related","url":"u"},{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"p"}]}'; 'PATCH .*workitems/42\?' = '{"id":42}' }; $global:log.Clear()
  $m1 = Move-TrackerTask 42 -Parent 7 -List 'Shop\Team'; $m2 = Move-TrackerTask 42 -Top; $pl = @($global:log -match '^PATCH')
  $o0 = @(($pl[0] -replace '^[^\[]*') | ConvertFrom-Json); $o1 = @(($pl[1] -replace '^[^\[]*') | ConvertFrom-Json)   # key order differs per process
  $pass = $m1 -eq 'moved 42 to Shop\Team under 7' -and "$($o0.op -join ',')|$($o0.path -join ',')" -eq 'remove,add,add|/relations/1,/relations/-,/fields/System.AreaPath' -and $o0[1].value.url -match 'workItems/7$' -and
    "$($o1.op -join ',')|$($o1.path -join ',')" -eq 'remove|/relations/1' } catch { $pass = $false; "  azure move error: $_" }
if (-not $pass) { $global:failed++ }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker azure: move swaps the parent link (old one out by index), sets the area path; top-level removes the link"
# ---- caps: dependencies (one held, one added), labels (add + remove), statuses; $ok gets the result and the log
function Cap($type, $verb, $fx, $arg, [scriptblock]$ok, $what) {
 try { Initialize-KitTracker -Type $type; $global:fx = $fx; $global:log.Clear(); $pass = (Test-KitCap 'tracker' $type $verb) -and [bool](& $ok @(__TrA $verb $arg) ($global:log -join "`n")) } catch { $pass = $false; "  $type $verb error: $_" }
 if (-not $pass) { $global:failed++; "  log: $($global:log -join ' | ')" }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker ${type}: $verb native ($what)"
}
Cap linear dependencies ([ordered]@{ 'inverseRelations' = '{"data":{"issue":{"inverseRelations":{"nodes":[{"type":"blocks","issue":{"identifier":"E-2"}},{"type":"related","issue":{"identifier":"E-7"}}]}}}}'; '(?=.*issue\(id: \$id\) \{ id)(?=.*"E-3")' = '{"data":{"issue":{"id":"u-3"}}}'
 '(?=.*issue\(id: \$id\) \{ id)(?=.*"E-1")' = '{"data":{"issue":{"id":"u-1"}}}'; 'issueRelationCreate' = '{"data":{"issueRelationCreate":{"success":true}}}' }) @{ id = 'E-1'; on = @('E-2', 'E-3') } {
 param($r, $l) ($r -join ',') -eq 'E-2,E-3' -and @($global:log -match 'issueRelationCreate').Count -eq 1 -and $l -match '(?=.*issueRelationCreate)(?=.*"issueId":"u-3")(?=.*"relatedIssueId":"u-1")(?=.*"type":"blocks")' } 'a blocks relation from the blocker; a related link is no wait'
Cap linear labels ([ordered]@{ 'issue\(id: \$id\) \{ id team' = '{"data":{"issue":{"id":"u-1","team":{"key":"E"},"labels":{"nodes":[{"id":"lb-1","name":"Wave-1"},{"id":"lb-3","name":"wave-3"}]}}}}'
 '(?=.*issueLabels)(?=.*"wave-2")' = '{"data":{"issueLabels":{"nodes":[{"id":"lb-ops","team":{"key":"OPS"}}]}}}'; 'issueLabelCreate' = '{"data":{"issueLabelCreate":{"issueLabel":{"id":"lb-9"}}}}'; 'issue(Add|Remove)Label' = '{"data":{"x":{"success":true}}}' }) @{ id = 'E-1'; add = @('wave-2', 'wave-3'); remove = @('wave-1', 'wave-0') } {
 param($r, $l) $l -match '(?=.*issueLabelCreate)(?=.*"wave-2")' -and $l -match '(?=.*issueAddLabel)(?=.*"l":"lb-9")' -and $l -match '(?=.*issueRemoveLabel)(?=.*"l":"lb-1")' -and @($global:log -match 'issue(Add|Remove)Label').Count -eq 2 -and $l -notmatch 'lb-ops' } 'another team''s label skipped, made; one removed; no-ops skipped'
$lv = try { Initialize-KitTracker -Type linear; $global:fx = [ordered]@{ 'identifier title url' = '{"data":{"issue":{"identifier":"E-1","title":"T","state":{"name":"Todo"},"labels":{"nodes":[{"name":"wave-2"}]}}}}' }; "$((Get-TrackerTask E-1).tags)" } catch { "$_" }
if ($lv -ne 'wave-2') { $global:failed++ }; "$(if ($lv -eq 'wave-2') { 'PASS' } else { 'FAIL' }) tracker linear: view reads the labels as tags ($lv)"
Cap youtrack statuses ([ordered]@{ 'admin/projects\?' = '[{"id":"0-2","shortName":"D"}]'; 'admin/projects/0-2/customFields' = '[{"field":{"name":"Priority"},"bundle":{"values":[{"name":"Major"}]}},{"field":{"name":"State"},"bundle":{"values":[{"name":"Fixed","isResolved":true,"ordinal":3},{"name":"Submitted","ordinal":0},{"name":"In Progress","ordinal":1}]}}]' }) @{ scope = 'D' } {
 param($r) ($r | ForEach-Object { "$($_.name)=$($_.type)" }) -join ',' -eq 'Submitted=open,In Progress=custom,Fixed=closed' } 'State values by ordinal; resolved -> closed'
foreach ($dir in 'INWARD', 'OUTWARD') {   # the "depends on" side by the link type's verb, whichever direction holds it
 $lt = if ($dir -eq 'INWARD') { '"sourceToTarget":"is required for","targetToSource":"depends on"' } else { '"sourceToTarget":"depends on","targetToSource":"is required for"' }; $od = @{ INWARD = 'OUTWARD'; OUTWARD = 'INWARD' }[$dir]
 Cap youtrack dependencies ([ordered]@{ 'GET .*issues/D-1\?fields=links' = "{`"links`":[{`"direction`":`"$dir`",`"linkType`":{`"name`":`"Depend`",$lt},`"issues`":[{`"idReadable`":`"D-2`"}]},{`"direction`":`"$od`",`"linkType`":{`"name`":`"Depend`",$lt},`"issues`":[{`"idReadable`":`"D-8`"}]}]}"; 'commands ' = '{}' }) @{ id = 'D-1'; on = @('D-2', 'D-3') } {
  param($r, $l) ($r -join ',') -eq 'D-2,D-3' -and @($global:log -match 'commands ').Count -eq 1 -and $l -match '"query":"depends on D-3"' } "the Depend link's depends-on side ($dir); is-required-for is no wait"
}
Cap youtrack labels ([ordered]@{ 'GET .*issues/D-1\?fields=tags' = '{"tags":[{"name":"wave-1"},{"name":"wave 3"}]}'; 'commands ' = '{}' }) @{ id = 'D-1'; add = @('wave 2', 'wave 3'); remove = @('wave-1', 'wave-0') } {
 param($r, $l) $l -match '"query":"tag \{wave 2\}"' -and $l -match '"query":"untag \{wave-1\}"' -and @($global:log -match 'commands ').Count -eq 2 } 'tag / untag commands, only the ones that change'
$yv = try { Initialize-KitTracker -Type youtrack; $global:fx = [ordered]@{ 'GET .*issues/D-1\?fields=idReadable' = '{"idReadable":"D-1","summary":"T","tags":[{"name":"wave-2"}]}' }; "$((Get-TrackerTask D-1).tags)" } catch { "$_" }
if ($yv -ne 'wave-2') { $global:failed++ }; "$(if ($yv -eq 'wave-2') { 'PASS' } else { 'FAIL' }) tracker youtrack: view reads the tags ($yv)"
Cap azure dependencies ([ordered]@{ 'GET .*workitems/42\?\$expand=relations' = '{"id":42,"relations":[{"rel":"System.LinkTypes.Dependency-Reverse","url":"https://dev.azure.com/acme/_apis/wit/workItems/40"},{"rel":"System.LinkTypes.Dependency-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/49"}]}'; 'PATCH .*workitems/42\?' = '{"id":42}' }) @{ id = '42'; on = @('40', '41') } {
 param($r, $l) ($r -join ',') -eq '40,41' -and @($global:log -match '^PATCH').Count -eq 1 -and $l -match '(?=PATCH .*json-patch)(?=.*Dependency-Reverse)(?=.*workItems/41")' -and $l -notmatch 'workItems/40"' } 'a Predecessor link per wait; a successor is no wait'
Cap azure dependencies $global:fx @{ id = '42'; on = @() } { param($r) ($r -join ',') -eq '40' -and -not ($global:log -match '^PATCH') } 'on = none: a read only (tracker order)'
Cap azure statuses ([ordered]@{ 'GET .*_apis/wit/workitemtypes/Task/states\?api-version=7\.1' = '{"value":[{"name":"To Do","category":"Proposed"},{"name":"QA","category":"InProgress"},{"name":"Done","category":"Completed"},{"name":"Cut","category":"Removed"}]}' }) @{ scope = 'Shop\Team' } {
 param($r) ($r | ForEach-Object { "$($_.name)=$($_.type)" }) -join ',' -eq 'To Do=open,QA=custom,Done=closed,Cut=custom' } "the issue type's states; Proposed -> open, Completed -> closed"
# checklist: child Tasks tagged kit-checklist-<name> (a real subtask untouched): tick, untick + rename, add (then tick), prune a stale kit line,
# the old description section out; view and list skip checklist children
$azT = '"System.Tags":"kit-checklist; kit-checklist-items"'
$azCl = [ordered]@{ 'GET .*workitems/42\?\$expand=relations' = '{"id":42,"fields":{"System.Title":"P","System.State":"Doing","System.AreaPath":"Shop\\Team","System.Description":"<div>keep</div><div>&lt;!-- kit:items --&gt;</div><div>- [ ] old</div><div>&lt;!-- /kit:items --&gt;</div>"},"relations":[' + (@(50..53 | ForEach-Object { "{`"rel`":`"System.LinkTypes.Hierarchy-Forward`",`"url`":`"https://dev.azure.com/acme/_apis/wit/workItems/$_`"}" }) -join ',') + ']}'
 'GET .*workitems\?ids=50,51,52,53&' = '{"value":[{"id":50,"fields":{"System.Title":"A1 · first","System.State":"To Do",' + $azT + '}},{"id":51,"fields":{"System.Title":"A2 · second","System.State":"Done",' + $azT + '}},{"id":52,"fields":{"System.Title":"Real sub","System.State":"To Do"}},{"id":53,"fields":{"System.Title":"Z9 · stale","System.State":"To Do",' + $azT + '}}]}'
 'GET .*workitemtypes/Task/states' = '{"value":[{"name":"To Do","category":"Proposed"},{"name":"Done","category":"Completed"}]}'; 'POST .*workitems/\$Task' = '{"id":60}'; 'PATCH .*workitems/(42|50|51|60)\?' = '{"id":1}'; 'DELETE .*workitems/53\?' = '' }
Cap azure checklist $azCl @{ id = '42'; name = 'Items'; prune = $true; items = @(@{ text = 'A1 · first'; done = $true }, @{ text = 'A2 · second v2'; done = $false }, @{ text = 'A3 · third'; done = $true }) } {
 param($r, $l) $p = @($global:log -match '^PATCH'); "$r" -eq 'checklist Items on 42: 4 change(s), 1 removed' -and @($global:log -match '^DELETE').Count -eq 1 -and $l -match 'DELETE .*workitems/53\?' -and
  @($p -match 'workitems/50\?.*"value":"Done"').Count -eq 1 -and @($p -match '(?=.*workitems/51\?)(?=.*second v2)(?=.*"value":"To Do")').Count -eq 1 -and @($p -match 'workitems/60\?.*"value":"Done"').Count -eq 1 -and
  $l -match '(?=POST .*workitems/\$Task)(?=.*A3 · third)(?=.*kit-checklist-items)(?=.*Hierarchy-Reverse)(?=.*workItems/42")(?=.*Shop\\\\Team)' -and @($p -match '(?=.*workitems/42\?)(?=.*keep)').Count -eq 1 -and -not @($p -match 'workitems/42\?.*kit:items').Count -and $l -notmatch 'workitems/52\?' } 'child Tasks: tick, untick + rename, add, prune; a real subtask and others'' lines kept'
$azV = try { Initialize-KitTracker -Type azure; $global:fx = $azCl; $global:log.Clear(); Clear-TrackerMemo 42; $vt = Get-TrackerTask 42; $global:fx = [ordered]@{ 'wiql' = '{"workItems":[]}' }; $null = __TrA 'list' @{ status = 'To Do' }
  "$(@($vt.subtasks.id) -join ',')|$([bool]@(($global:log -match 'wiql') -match "NOT \[System.Tags\] CONTAINS 'kit-checklist'").Count)" } catch { "$_" }
if ($azV -notmatch '^52\|True$') { $global:failed++ }; "$(if ($azV -match '^52\|True$') { 'PASS' } else { 'FAIL' }) tracker azure: view and list skip checklist children ($azV)"
Remove-Item $trRt -Recurse -Force -ErrorAction SilentlyContinue
exit [int]($global:failed -gt 0)
