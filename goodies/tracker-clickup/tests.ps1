#Requires -Version 7
<#
tests.ps1 (goody tracker-clickup): the ClickUp tracker on recorded clickup CLI answers (an unknown call fails): view, status,
comment, create (assignee looked up, parent kept), list; a dry-run comment from a file.
Usage: pwsh -NoProfile -File goodies/tracker-clickup/tests.ps1 [-Kit <kit>] (the adapter comes from files/ beside this file).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (git rev-parse --show-toplevel))
. (Join-Path $Kit 'skills/crafty/lib.ps1'); . (Join-Path $PSScriptRoot 'files/skills/crafty/adapters/tracker_clickup.ps1')
$global:log = [Collections.Generic.List[string]]::new(); $failed = 0
function Fx($call) { $global:log.Add($call); foreach ($k in $global:fx.Keys) { if ($call -match $k) { return $global:fx[$k] } }; throw "404 no fixture: $call" }
function clickup { $global:LASTEXITCODE = 0; Fx ($args -join ' ') }
$global:fx = [ordered]@{ 'task view C1' = '{"id":"C1","name":"Bug","status":{"status":"In Progress"},"list":{"id":"L9"},"subtasks":[{"id":"C2","name":"Sub"}]}'
  'status set in test C1' = 'Status set'; 'comment add C1 two words' = '{"id":"90"}'; 'member list' = '[{"id":7,"username":"Ann Lee"}]'
  'task create --list-id L9 .*--assignee 7 --parent C1' = '{"id":"C5"}'; 'task list --list-id L9 --status in test --page 0' = '[{"id":"C3","name":"A","assignees":[{"id":7,"username":"ann"}]}]' }
try {
  Initialize-KitTracker -Type clickup
  $r = @{ v = Get-TrackerTask C1; s = Set-TrackerStatus C1 inTest; c = Add-TrackerComment C1 'two words'; n = New-TrackerTask -List L9 -Name 'New one' -Description 'd' -Parent C1 -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks L9 inTest) }
  $pass = $r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.n.id -eq 'C5' -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq 7 -and ($global:log -join "`n") -match '--priority 2'
} catch { $pass = $false; "  clickup error: $_" }
if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: view, status, comment, create, list on recorded answers"
$f = Join-Path ([IO.Path]::GetTempPath()) "clickup-body-$PID.md"; 'body text' | Set-Content $f
Initialize-KitTracker -Type clickup -DryRun
$out = Add-TrackerComment 12 $f 6>&1 | Out-String; Remove-Item $f
$pass = $out -match 'comment add 12 "body text'; if (-not $pass) { $failed++ }
"$(if ($pass) { 'PASS' } else { 'FAIL' }) tracker clickup: a dry-run comment sends the file's text"
"$failed failure(s)"   # the per-extra count: kitbag.py goody test prints only the total
exit [int]($failed -gt 0)
