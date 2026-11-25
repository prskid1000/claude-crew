#Requires -Version 7
<#
tests/tracker-adapters-2.tests.ps1: the linear, youtrack and azure tracker adapters' K54 moves and native caps (dependencies, labels,
statuses, azure checklist), clickup tags prune, the dec-60 kit table through every adapter's description path, on recorded answers (Invoke-RestMethod mocked; an unknown call fails; no account: replayed API). Split from tracker-adapters (file cap).
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
# ---- dec-60 (owner 2026-11-25): the kit table (Code, Area, Product, Parent, Run; no title key, no custom field) through each adapter's description
# path, one reader in PowerShell and Python (CRLF too), kept last on every rewrite, out of the word cap; lookup kit table -> old title prefix -> tracker id
. (Join-Path $Kit 'skills/crafty/adapters/tracker-jira.ps1')
$mF = [ordered]@{ key = 'SHOP-CAT-004'; area = 'catalogue'; product = 'shop'; parent = 'T1' }; $mT = Set-KitTaskMeta "Problem: x`n`n**Items**`n- [ ] A1 · grid`n" $mF
$mPaths = [ordered]@{ 'clickup github gitlab linear youtrack none (Markdown as stored)' = $mT; jira = (__TrAdfText (__TrAdf $mT)); 'jira-server' = (__TrWiki $mT); azure = (__TrUnHtml (__TrHtml $mT)); crlf = ($mT -replace "`n", "`r`n"); 'clickup read-back (\<!--)' = ($mT -replace '<!--', '\<!--') }
$mBad = @($mPaths.Keys | Where-Object { (@((Get-KitTaskMeta $mPaths[$_]).Values) -join '|') -ne 'SHOP-CAT-004|catalogue|shop|T1' })
$mPy = Join-Path $trRt 'meta.md'; $null = New-Item -ItemType Directory -Force $trRt; [IO.File]::WriteAllText($mPy, (($mT -replace 'SHOP-CAT-004', 'SHOP\-CAT\-004' -replace '<!--', '\<!--') -replace "`n", "`r`n"))
$mPr = & (Get-Python) -X utf8 -c 'import sys; sys.path.insert(0, sys.argv[1]); import kitbag_naming as n; print("|".join(n.meta_read(open(sys.argv[2], encoding="utf-8", newline="").read()).values()))' (Join-Path $Kit 'skills/bossy') $mPy
$mTbl = "<!-- kit:meta -->`n`n| Kit | Value |`n|---|---|`n| Code | SHOP-CAT-004 |`n| Area | catalogue |`n| Product | shop |`n| Parent | T1 |`n`n<!-- /kit:meta -->"
$pass = $mT -ceq "Problem: x`n`n**Items**`n- [ ] A1 · grid`n`n$mTbl" -and (Set-KitTaskMeta $mT $mF) -ceq $mT -and (Set-KitTaskMeta ($mT -replace '<!--', '\<!--') $mF) -ceq $mT -and -not $mBad.Count -and "$mPr" -eq 'SHOP-CAT-004|catalogue|shop|T1' -and
  (Set-KitTaskMeta $mT @{ area = 'payments'; key = ''; parent = '-' }) -cmatch '(?s)Items.*\| Code \| SHOP-CAT-004 \|\n\| Area \| payments \|\n\| Product \| shop \|\n\n<!-- /kit:meta -->$' -and @([regex]::Matches((Set-KitTaskMeta $mT @{ run = 'r' }), '<!-- kit:meta -->')).Count -eq 1
if (-not $pass) { $global:failed++; "  $($mBad -join ', ') | py $mPr | $($mT -replace '\n', '\n')" }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) dec-60 kit table: one writer, every adapter's description path reads the same rows (Markdown, Jira ADF and wiki, Azure HTML, CRLF), Python reads it too, an update keeps one table, '-' drops a row"
$mem = @{ T7 = [pscustomobject]@{ id = 'T7'; name = 'Cart held in the browser'; status = 'open'; description = $mT }; T8 = [pscustomobject]@{ id = 'T8'; name = 'SHOP-CAT-002 Old style'; status = 'open'; description = 'd' }
  T9 = [pscustomobject]@{ id = 'T9'; name = 'Plain'; status = 'open'; description = 'd' }; T10 = [pscustomobject]@{ id = 'T10'; name = 'Pay x'; status = 'open'; description = (Set-KitTaskMeta 'd' @{ key = 'SHOP-PAY-001' }) } }
Register-KitAdapter 'tracker' 'fkm' @{ view = { param($a) $mem[$a.id] }; describe = { param($a) $mem[$a.id].description = $a.text; 'ok' }; rename = { param($a) $mem[$a.id].name = $a.name; 'ok' }; url = { param($a) $a.id } }
$mk = try { $__trType = 'fkm'; $null = Set-TrackerDescription T7 "Rewritten by a rollup`n`n<!-- kit:delivery -->`nrows`n<!-- /kit:delivery -->"; $null = Set-TrackerDescription T7 "$($mem.T7.description)`n`n**Scope 2026-11-25:** more"
  "$((Get-KitTaskKey T7))|$((Get-KitTaskKey T8))|$((Get-KitTaskKey T9))|$((Get-KitTaskKey T9 -OrId))" } catch { "$_" }
$pass = $mk -eq 'SHOP-CAT-004|SHOP-CAT-002||T9' -and $mem.T7.description -cmatch "(?s)^Rewritten by a rollup.*kit:delivery.*\*\*Scope 2026-11-25:\*\* more\n\n$([regex]::Escape($mTbl))$" -and @([regex]::Matches($mem.T7.description, '<!-- kit:meta -->')).Count -eq 1
if (-not $pass) { $global:failed++; "  $mk | $($mem.T7.description -replace '\n', '\n')" }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) dec-60: a description rewrite keeps the kit table last (rollup, scope); key lookup kit table -> old title prefix -> '' / -OrId the tracker id ($mk)"
# naming on (make stubbed): an old keyed title renamed moves its key into the kit table first; a QA collector of another area is refused; a plain title
# never borrows another task's real key, only its own create's <P>-<A>-000
$mr = & { function Test-KitNamingOn { $true }; function Invoke-KitNaming([string[]]$Argv) { if ($o = "$(@($Argv) -like 'outcome=*')") { $o.Substring(8) } else { 'desc' } }
  $__trType = 'fkm'; $null = Set-TrackerName T8 'Old style, reworded'; $script:KitTitleKey['Add tests'] = 'SHOP-CAT-009'; $script:KitTitleKey['New one'] = 'SHOP-CAT-000'
  "$($mem.T8.name)|$((Get-KitTaskMeta $mem.T8.description).key)|$(Test-KitSameArea $mem.T10 T7)|$(Test-KitSameArea $mem.T7 T7)|$(Get-KitNewTaskKey 'Add tests' '' '' -NoAllocate 2>$null)|$(Get-KitNewTaskKey 'New one' '' '' -NoAllocate)" }
$pass = $mr -ceq 'Old style, reworded|SHOP-CAT-002|False|True||SHOP-CAT-000'; if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) dec-60: rename of an old keyed title keeps its key in the kit table; same-area by the table; no borrowed key ($mr)"
$mS1 = Set-KitTaskMeta 'd' (Get-KitShapeMeta @{} 'SHOP-CAT-004'); $mS2 = Set-KitTaskMeta $mS1 (Get-KitShapeMeta @{ subtasks = @(@{ id = 'a' }, @{ id = 'b' }) } 'SHOP-CAT-004'); $mS3 = Set-KitTaskMeta 'd' (Get-KitShapeMeta @{ parent = 'P1' } 'SHOP-CAT-004')
$ms = @($mS1, $mS2, $mS3 | ForEach-Object { $sm = Get-KitTaskMeta $_; @($sm.Keys | ForEach-Object { "$_=$($sm[$_])" }) -join ',' }) -join ' | '
$pass = $ms -eq 'key=SHOP-CAT-004,area=cat,product=shop | key=SHOP-CAT-004,product=shop,children=2 | key=SHOP-CAT-004,area=cat,parent=P1'; if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) dec-60 kit table rows by shape: standalone Code Area Product · parent Code Product Children · child Code Area Parent ($ms)"
$mW = Join-Path $trRt 'cap.md'; [IO.File]::WriteAllText($mW, "Problem: $((1..195 | ForEach-Object { "w$_" }) -join ' ') https://x.example/1`n`n$mTbl`n")
$mC = & (Get-Python) -X utf8 (Join-Path $Kit 'skills/bossy/kitbag.py') prose --kind task-description $mW 2>&1 | Out-String
$pass = $mC -notmatch 'words \(max'; if (-not $pass) { $global:failed++; "  $mC" }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) dec-60: the kit table is out of the task-description word cap (197 words + the table)"
# a fake 429 (ClickUp retag stopped at task 6): the wait reads Retry-After / X-RateLimit-Reset; a CLI write and a REST POST retry it; an id like CU-429 is no rate limit
$env:KIT_POLL_MS = 200; $rs = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 5   # Wait-KitPoll fake clock
$rlW = "$(Get-KitRateWait 'Error: 429 Too Many Requests' 7) $(Get-KitRateWait 'HTTP 429 Retry-After: 3' 7) $(Get-KitRateWait "http 429 x-ratelimit-reset $rs" 7) $(Get-KitRateWait "http 429 x-ratelimit-reset $($rs * 1000)" 7) $(Get-KitRateWait 'Error: task CU-429 not found' 7) $(Get-KitRateWait 'unknown field rate_limit' 7)"
$script:nCall = 0; $cr = Invoke-KitRetry { $script:nCall++; if ($script:nCall -lt 3) { @{ code = 1; err = 'Error: 429 Too Many Requests' } } else { @{ code = 0; out = 'ok' } } } -Connect; $rlC = "$($cr.code)/$script:nCall"
$script:nCall = 0; $null = Invoke-KitRetry { $script:nCall++; @{ code = 1; err = 'Error: task CU-429 not found' } } -Connect; $rlC += " $script:nCall"
$tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl.Start(); $port = $tl.LocalEndpoint.Port; $tl.Stop()
$srv = Start-ThreadJob -ArgumentList $port { param($pt) $hl = [Net.HttpListener]::new(); $hl.Prefixes.Add("http://127.0.0.1:$pt/"); $hl.Start(); $hits = 0
  try { while ($hits -lt 2) { $tk = $hl.GetContextAsync(); if (-not $tk.Wait(20000)) { break }; $c = $tk.Result; $hits++
      if ($hits -eq 1) { $c.Response.StatusCode = 429; $c.Response.AddHeader('X-RateLimit-Reset', "$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1)") } else { $bd = [Text.Encoding]::UTF8.GetBytes('{"ok":true}'); $c.Response.ContentType = 'application/json'; $c.Response.OutputStream.Write($bd, 0, $bd.Length) }
      $c.Response.Close() } } finally { Start-Sleep -Milliseconds 500; $hl.Stop() }; $hits }   # the last answer flushes before the stop
$irmMock = ${function:Invoke-RestMethod}; Remove-Item function:Invoke-RestMethod   # the real cmdlet against the local listener
Start-Sleep -Milliseconds 300; $hr = Invoke-KitHttp 'POST' "http://127.0.0.1:$port/task/T1/tag/x" @{} @{} 3>$null; $hits = Receive-Job $srv -Wait -AutoRemoveJob; Set-Item function:Invoke-RestMethod $irmMock
$pass = $rlW -match '^7 3 [56] [56] 0 0$' -and $rlC -eq '0/3 1' -and $hr.ok -eq $true -and $hits -eq 2; if (-not $pass) { $global:failed++; "  $rlW | $rlC | $($hr | ConvertTo-Json -Compress) | $hits" }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) rate limit 429: waits per header; a CLI write retried, CU-429 not; a REST POST retried once"
# every MR merged (bossy track): the solution comment's '(OPEN)' MRs read MERGED, edited in place; another comment untouched
$sCm = @([pscustomobject]@{ id = 'c1'; user = 'u'; date = ''; text = 'Started work' }, [pscustomobject]@{ id = 'c2'; user = 'u'; date = ''; text = "**Solution:** grid`n**MRs:** web!4 (OPEN) · api!7 (OPEN) · **Local proof:** ok`n**Deferred:** flag (OPEN)" })
Register-KitAdapter 'tracker' 'fks' @{ caps = @{ commentEdit = $true }; comments = { $sCm }; 'comment-edit' = { param($a) ($sCm | Where-Object id -eq $a.comment).text = $a.text; 'edited' }; comment = { 'new' }; url = { param($a) $a.id } }
$__trType = 'fks'; Update-KitSolutionMrs 'T9'; $sMg = "$($sCm[1].text)"
$pass = $sMg -match 'web!4 \(MERGED\) · api!7 \(MERGED\)' -and $sMg -match 'Deferred:\*\* flag \(OPEN\)' -and $sMg -notmatch 'MRs:.*OPEN' -and $sCm[0].text -eq 'Started work'; if (-not $pass) { $global:failed++; "  $sMg" }; "$(if ($pass) { 'PASS' } else { 'FAIL' }) solution comment: MRs (OPEN) -> (MERGED) once every MR merged, the MRs line only, the same comment edited"
# azure tags prune (parity next 2026-11-25): wit/tags (preview api), each counted by WIQL; a used one skipped, kit-checklist tags never listed
Cap azure tag-prune ([ordered]@{ 'GET .*_apis/wit/tags\?api-version=7\.1-preview\.1' = '{"value":[{"name":"old"},{"name":"used"},{"name":"kit-checklist-Items"}]}'
 'POST .*wit/wiql.*CONTAINS ''old''' = '{"workItems":[]}'; 'POST .*wit/wiql.*CONTAINS ''used''' = '{"workItems":[{"id":7}]}'; 'DELETE .*_apis/wit/tags/old\?api-version=7\.1-preview\.1' = '' }) @{ names = @(); lists = @() } {
 param($r, $l) (@($r | ForEach-Object { "$($_.tag)=$($_.result)" }) -join ',') -eq 'old=deleted,used=skipped (in use)' -and @($l -split "`n" -match '^DELETE').Count -eq 1 } 'wit/tags + WIQL counts, only an unused tag deleted'
# ---- clickup tags prune (moved from tracker-adapters: file cap; its own Invoke-KitHttp mock)
. (Join-Path $Kit 'skills/crafty/adapters/tracker-clickup.ps1'); $global:http = [Collections.Generic.List[string]]::new()
# tags prune (owner 2026-11-25): each space tag counted live (closed, archived too) before its delete; used or uncounted: skipped
$global:http.Clear(); function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) { $global:http.Add("$Method $Uri $($Body | ConvertTo-Json -Compress)")
  if ($Uri -match '/list/L1$') { return @{ space = @{ id = 'S1' } } }; if ($Uri -match '/space/S1/tag$') { return @{ tags = @(@{ name = 'old one' }, @{ name = 'used' }, @{ name = 'flaky' }) } }
  if ($Uri -match 'tags%5B%5D=flaky') { return $null }; if ($Uri -match 'tags%5B%5D=used&.*archived=true') { return @{ tasks = @(@{ id = 'T1' }) } }; if ($Uri -match '/team/W1/task') { return @{ tasks = @() } }; @{} }
$env:CLICKUP_API_TOKEN = 'tk-test'; $__cfg = [pscustomobject]@{ tracker = [pscustomobject]@{ workspace = 'W1' } }
try { Initialize-KitTracker -Type clickup -DryRun; $pd = @(__TrA 'tag-prune' @{ names = @(); lists = @('L1') }); $dDel = @($global:http -match '^DELETE').Count   # the verb: a count failure makes the CLI exit 1
  Initialize-KitTracker -Type clickup; $pa = @(Invoke-KitTagPrune @('OLD ONE', 'missing') L1 -Unused -Json | ConvertFrom-Json) } finally { Remove-Item Env:CLICKUP_API_TOKEN; $__cfg = $null }
$pRes = ($pd | ForEach-Object { "$($_.tag)=$($_.result)" }) -join ','; $aRes = ($pa | ForEach-Object { "$($_.tag)=$($_.result)" }) -join ','
$pass = $pRes -match '^old one=would delete,used=skipped \(in use\),flaky=skipped \(count failed' -and $dDel -eq 0 -and $aRes -eq 'old one=deleted,missing=not in space' -and @($global:http -match 'tags%5B%5D=old%20one&').Count -ge 2 -and
  @($global:http -match '^DELETE').Count -eq 1 -and @($global:http -match '^DELETE https://api.clickup.com/api/v2/space/S1/tag/old%20one ').Count -eq 1 -and @($global:http -match 'include_closed=true&subtasks=true&archived=true').Count -ge 2; if (-not $pass) { $global:failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup tags prune: dry run deletes nothing; a tag on any task (archived too) or a failed count is skipped; -Name prunes only those ($pRes | $aRes)"
Remove-Item $trRt -Recurse -Force -ErrorAction SilentlyContinue
exit [int]($global:failed -gt 0)
