#Requires -Version 7
<#
Adds a RETEST item for a bug task whose fix went live (supervise: "[ACT] LIVE <task>: ... Ready for QA") to an existing QA run,
so the retest is one command + one /test-and-close launch instead of hand-editing run.json.

  & <kit>\skills\qa-kit\scripts\add-retest.ps1 -RunDir <run> -Task <bug task id> -Code H2R -Title "RETEST ..." -Mrs "web-code!6178" [-Only X1,X2] [-Lane web|api|app]
  then: Workflow test-and-close { runDir: <run>, only: ['H2R'], instance: 'w<next>' }

The guide is the bug task itself (description = the failed checks with steps + evidence, comments = the fix and how to test),
written to <run>\tasks\<task>.md. -Only defaults to the check ids in the task name ("... failed checks X1, X2").
Re-running with the same -Code replaces that item.
#>
param(
  [Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][string]$Task, [Parameter(Mandatory)][string]$Code,
  [string]$Title, [string]$Mrs = '', [string[]]$Only, [ValidateSet('web', 'api', 'app')][string]$Lane = 'web'
)
$ErrorActionPreference = 'Stop'
$t = clickup task view $Task --json | ConvertFrom-Json
if (-not $t.id) { throw "cannot read task $Task (clickup auth?)" }
$c = clickup comment list $Task --json 2>$null | ConvertFrom-Json
if (-not $Only -and $t.name -match 'failed checks\s+(?<ids>.+)$') { $Only = @($Matches.ids -split '\s*,\s*' | Where-Object { $_ }) }
if (-not $Title) { $Title = "RETEST $($t.name -replace '^\[Bug\]\s*', '')" }
$md = "# $($t.name)`n`nTask: $($t.url)  Status: $($t.status.status)`n`n" +
  "RETEST of the fix: run the failed checks ($($Only -join ', ')) again on the deployed build, same steps and data where possible. " +
  "Check the fix is deployed first (deployed.ps1 -Mrs $Mrs); not deployed = NOT_TESTED.`n`n## Description`n`n$($t.markdown_description ?? $t.description)`n`n## Comments (oldest first)`n"
foreach ($x in @($c) | Sort-Object { [long]$_.date }) { $md += "`n---`n**$($x.user.username)**`n`n$($x.comment_text)`n" }
New-Item -ItemType Directory -Force "$RunDir\tasks" | Out-Null
$gf = "$RunDir\tasks\$Task.md"; Set-Content $gf $md -Encoding utf8
$r = Get-Content "$RunDir\run.json" -Raw | ConvertFrom-Json
$items = @($r.items | Where-Object { $_.code -ne $Code })
$items += [pscustomobject]@{ code = $Code; lane = $Lane; title = $Title; guideFile = $gf; retest = $true; only = @($Only); subtasks = @([pscustomobject]@{ id = $Task; name = $t.name; mrs = $Mrs }) }
$r.items = $items
$r | ConvertTo-Json -Depth 8 | Set-Content "$RunDir\run.json" -Encoding utf8
"added $Code (retest of $Task, checks $($Only -join ', ')) to $RunDir\run.json - launch: Workflow test-and-close { runDir: '$($RunDir -replace '\\', '\\')', only: ['$Code'], instance: 'w<next>' }"
