#Requires -Version 7
<#
tests/tracker-adapters-2.tests.ps1: the linear, youtrack and azure tracker adapters' K54 moves and native caps (dependencies, labels,
statuses) on recorded answers (Invoke-RestMethod mocked; an unknown call fails; no account: replayed API). Split from tracker-adapters (file cap).
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
Cap linear labels ([ordered]@{ 'issue\(id: \$id\) \{ id' = '{"data":{"issue":{"id":"u-1"}}}'; '(?=.*issueLabels)(?=.*"wave-2")' = '{"data":{"issueLabels":{"nodes":[]}}}'; 'issueLabels' = '{"data":{"issueLabels":{"nodes":[{"id":"lb-1"}]}}}'
 'issueLabelCreate' = '{"data":{"issueLabelCreate":{"issueLabel":{"id":"lb-9"}}}}'; 'issue(Add|Remove)Label' = '{"data":{"x":{"success":true}}}' }) @{ id = 'E-1'; add = @('wave-2'); remove = @('wave-1') } {
 param($r, $l) $l -match '(?=.*issueLabelCreate)(?=.*"wave-2")' -and $l -match '(?=.*issueAddLabel)(?=.*"l":"lb-9")' -and $l -match '(?=.*issueRemoveLabel)(?=.*"l":"lb-1")' } 'a missing label made, then added; one removed'
$lv = try { Initialize-KitTracker -Type linear; $global:fx = [ordered]@{ 'identifier title url' = '{"data":{"issue":{"identifier":"E-1","title":"T","state":{"name":"Todo"},"labels":{"nodes":[{"name":"wave-2"}]}}}}' }; "$((Get-TrackerTask E-1).tags)" } catch { "$_" }
if ($lv -ne 'wave-2') { $global:failed++ }; "$(if ($lv -eq 'wave-2') { 'PASS' } else { 'FAIL' }) tracker linear: view reads the labels as tags ($lv)"
Cap youtrack statuses ([ordered]@{ 'admin/projects\?' = '[{"id":"0-2","shortName":"D"}]'; 'admin/projects/0-2/customFields' = '[{"field":{"name":"Priority"},"bundle":{"values":[{"name":"Major"}]}},{"field":{"name":"State"},"bundle":{"values":[{"name":"Fixed","isResolved":true,"ordinal":3},{"name":"Submitted","ordinal":0},{"name":"In Progress","ordinal":1}]}}]' }) @{ scope = 'D' } {
 param($r) ($r | ForEach-Object { "$($_.name)=$($_.type)" }) -join ',' -eq 'Submitted=open,In Progress=custom,Fixed=closed' } 'State values by ordinal; resolved -> closed'
Cap youtrack dependencies ([ordered]@{ 'GET .*issues/D-1\?fields=links' = '{"links":[{"direction":"OUTWARD","linkType":{"name":"Depend"},"issues":[{"idReadable":"D-2"}]},{"direction":"INWARD","linkType":{"name":"Depend"},"issues":[{"idReadable":"D-8"}]}]}'; 'commands ' = '{}' }) @{ id = 'D-1'; on = @('D-2', 'D-3') } {
 param($r, $l) ($r -join ',') -eq 'D-2,D-3' -and @($global:log -match 'commands ').Count -eq 1 -and $l -match '"query":"depends on D-3"' } 'the Depend link, outward side; an inward one is no wait'
Cap youtrack labels ([ordered]@{ 'commands ' = '{}' }) @{ id = 'D-1'; add = @('wave 2'); remove = @('wave-1') } { param($r, $l) $l -match '"query":"tag \{wave 2\}"' -and $l -match '"query":"untag \{wave-1\}"' } 'tag / untag commands'
$yv = try { Initialize-KitTracker -Type youtrack; $global:fx = [ordered]@{ 'GET .*issues/D-1\?fields=idReadable' = '{"idReadable":"D-1","summary":"T","tags":[{"name":"wave-2"}]}' }; "$((Get-TrackerTask D-1).tags)" } catch { "$_" }
if ($yv -ne 'wave-2') { $global:failed++ }; "$(if ($yv -eq 'wave-2') { 'PASS' } else { 'FAIL' }) tracker youtrack: view reads the tags ($yv)"
Cap azure dependencies ([ordered]@{ 'GET .*workitems/42\?\$expand=relations' = '{"id":42,"relations":[{"rel":"System.LinkTypes.Dependency-Reverse","url":"https://dev.azure.com/acme/_apis/wit/workItems/40"},{"rel":"System.LinkTypes.Dependency-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/49"}]}'; 'PATCH .*workitems/42\?' = '{"id":42}' }) @{ id = '42'; on = @('40', '41') } {
 param($r, $l) ($r -join ',') -eq '40,41' -and @($global:log -match '^PATCH').Count -eq 1 -and $l -match '(?=PATCH .*json-patch)(?=.*Dependency-Reverse)(?=.*workItems/41")' -and $l -notmatch 'workItems/40"' } 'a Predecessor link per wait; a successor is no wait'
Remove-Item $trRt -Recurse -Force -ErrorAction SilentlyContinue
exit [int]($global:failed -gt 0)
