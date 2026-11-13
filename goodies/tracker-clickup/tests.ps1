#Requires -Version 7
<#
tests.ps1 (goody tracker-clickup): the ClickUp tracker on recorded clickup CLI answers (an unknown call fails): view, status,
comment, create (assignee looked up, parent kept, no list: the parent's), list; a dry-run comment from a file.
Usage: pwsh -NoProfile -File goodies/tracker-clickup/tests.ps1 [-Kit <kit>] (the adapter comes from files/ beside this file).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/crafty/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/crafty/adapters/tracker_clickup.ps1')
$global:log = [Collections.Generic.List[string]]::new(); $failed = 0
function Fx($call) { $global:log.Add($call); foreach ($k in $global:fx.Keys) { if ($call -match $k) { return $global:fx[$k] } }; throw "404 no fixture: $call" }
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
if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: view, status, comment, create (no list: the parent's), list on recorded answers"
$global:fx.Insert(0, 'task view P2', '{"id":"P2","list":{"id":"L7"}}'); $global:fx.Insert(0, 'task view P3', '{"id":"P3","list":{"id":"L9"}}'); $global:fx['task create --list-id L7 .*--parent P2'] = '{"id":"C7"}'; $global:fx['task create --list-id L9 --name w .*--parent P4'] = '{"id":"C8"}'; $global:log.Clear()
$sw = [IO.StringWriter]::new(); $se = [Console]::Error; [Console]::SetError($sw)
try { $xw = __TrA 'create' @{ list = 'L9'; name = 'y'; description = 'd'; parent = 'P2' }; $xe = try { $null = __TrA 'create' @{ list = 'L9'; name = 'z'; description = 'd'; parent = 'P3' }; 'no throw' } catch { "$_" }; $xv = __TrA 'create' @{ list = 'L9'; name = 'w'; description = 'd'; parent = 'P4' } } finally { [Console]::SetError($se) }
$pass = $xw.id -eq 'C7' -and $xv.id -eq 'C8' -and "$sw" -match 'parent P2 is in list L7, not L9' -and $xe -match 'subtask of P3 failed, nothing created' -and -not ($global:log -match 'create --list-id L9 --name z(?!.*--parent)'); if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: -Parent in another list -> created in the parent's list, said on stderr; a failed parent look-up keeps -List; a failed subtask create throws, never a silent top-level task ($xe)"
$global:log.Clear(); try { $null = Set-TrackerKitComment C1 qa-result 'round two'; $pass = ($global:log -join "`n") -match '(?m)^comment edit 55 round two$' -and ($global:log -join "`n") -notmatch 'comment (add|delete)|56' } catch { $pass = $false; "  clickup error: $_" }
if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a kit comment's next round edits it (comment edit <id>); a person's comment untouched"
$global:log.Clear(); $nl = try { @(Get-TrackerTasks '' inTest 3>$null); 'no throw' } catch { "$_" }
$pass = $nl -match 'tracker list needs -List <id>' -and -not ($global:log -match 'task list'); if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: list with no -List and no tracker.list stops before the CLI ($nl)"
$f = Join-Path ([IO.Path]::GetTempPath()) "clickup-body-$PID.md"; 'body text' | Set-Content $f
Initialize-KitTracker -Type clickup -DryRun
$out = Add-TrackerComment 12 $f 6>&1 | Out-String; Remove-Item $f
$pass = $out -match 'comment add 12 "body text'; if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a dry-run comment sends the file's text"
$out = Add-TrackerComment 12 '**Solution:** fixed `a.b` · [MR !7](https://h/7) · https://h/8 · [https://h/9](https://h/9)' 6>&1 | Out-String
$pass = $out -match [regex]::Escape('Solution: fixed a.b · MR !7 (https://h/7) · https://h/8 · https://h/9') -and $out -notmatch '\*\*|`|\]\('; if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a comment goes as plain text (bold and code marks dropped, [text](url) -> text (url)) ($($out.Trim()))"
Initialize-KitTracker -Type clickup; $global:log.Clear()
$global:fx.Insert(0, 'task view C1 --jq .checklists','[{"id":"K1","name":"Items","items":[{"id":"i1","name":"A1 · High · old","resolved":false},{"id":"i9","name":"a person''s","resolved":false}]}]')
$global:fx['task checklist item (add|edit|resolve) K1'] = 'ok'
$ck = try { __TrA 'checklist' @{ id = 'C1'; name = 'Items'; items = @(@{ text = 'A1 · High · new'; done = $true }, @{ text = 'A2 · Low · two'; done = $false }) } } catch { "$_" }
$cl = $global:log -join "`n"
$pass = $ck -match '3 change' -and $cl -match '(?m)^task checklist item edit K1 i1 --name A1 · High · new$' -and $cl -match '(?m)^task checklist item add K1 A2 · Low · two$' -and $cl -match '(?m)^task checklist item resolve K1 i1$' -and $cl -notmatch 'i9|checklist add C1'
if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: checklist renames, adds and resolves the kit's items by id, a person's item untouched ($ck)"
"$failed failure(s)"   # the per-extra count: kitbag.py goody test prints only the total
exit [int]($failed -gt 0)
