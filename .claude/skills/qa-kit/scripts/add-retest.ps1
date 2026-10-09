#Requires -Version 7
<#
Adds a RETEST item for a bug task whose fix went live (supervise: "[ACT] LIVE <task>: ... Ready for QA") to an existing QA run,
so the retest is one command + one /test-and-close launch instead of hand-editing run.json.

  & <kit>/skills/qa-kit/scripts/add-retest.ps1 -RunDir <run> -Task <bug task id> -Code H2R -Title "RETEST ..." -Mrs "web-code!6178" [-Only X1,X2] [-Lane web|api|app]
  then: Workflow test-and-close { runDir: <run>, only: ['H2R'], instance: 'w<next>' }

The guide is the bug task itself (description = the failed checks with steps + evidence, comments = the fix and how to test),
written to <run>/tasks/<task>.md. -Only defaults to the check ids in the task name ("... failed checks X1, X2").
Re-running with the same -Code replaces that item.
#>
param(
  [Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][string]$Code,
  [string]$Title, [string]$Mrs = '', [string[]]$Only, [ValidateSet('web', 'api', 'app')][string]$Lane = 'web'
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dev-kit\scripts\tracker.ps1')   # tracker.type in kit.local.json
$t = Get-TrackerTask $Task
if (-not $t.name) { throw "cannot read task $Task (tracker $($KitConf.TrackerType): CLI auth / config?)" }
$c = @(try { Get-TrackerComments $Task } catch { @() })
# greedy: older bug titles carry several "failed checks" parts; the last one is the current list
if (-not $Only -and $t.name -match '.*failed checks\s+(?<ids>.+)$') { $Only = @($Matches.ids -split '\s*,\s*' | Where-Object { $_ }) }
if (-not $Title) { $Title = "RETEST $($t.name -replace '^\[Bug\]\s*', '')" }
$md = "# $($t.name)`n`nTask: $($t.url)  Status: $($t.status)`n`n" +
  "RETEST of the fix: run the failed checks ($($Only -join ', ')) again on the deployed build, same steps and data where possible. " +
  "Check the fix is deployed first (deployed.ps1 -Mrs $Mrs); not deployed = NOT_TESTED.`n`n## Description`n`n$($t.description)`n`n## Comments (oldest first)`n"
foreach ($x in $c) { $md += "`n---`n**$($x.user)** $($x.date)`n`n$($x.text)`n" }
New-Item -ItemType Directory -Force "$RunDir\tasks" | Out-Null
$gf = "$RunDir\tasks\$Task.md"; Set-Content $gf $md -Encoding utf8
$r = Get-Content "$RunDir\run.json" -Raw | ConvertFrom-Json
$items = @($r.items | Where-Object { $_.code -ne $Code })
$items += [pscustomobject]@{ code = $Code; lane = $Lane; title = $Title; guideFile = $gf; retest = $true; only = @($Only); subtasks = @([pscustomobject]@{ id = $Task; name = $t.name; mrs = $Mrs }) }
$r.items = $items
$r | ConvertTo-Json -Depth 8 | Set-Content "$RunDir\run.json" -Encoding utf8
"added $Code (retest of $Task, checks $($Only -join ', ')) to $RunDir\run.json - launch: Workflow test-and-close { runDir: '$($RunDir -replace '\\', '\\')', only: ['$Code'], instance: 'w<next>' }"
