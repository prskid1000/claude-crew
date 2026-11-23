<#
bugbrief.ps1 (core): bossy.ps1 bugbrief (a bug-fix brief + /buildy args for QA-raised [Bug] or failedTesting tasks), dot-sourced by
bossy.ps1 (skills/bossy/adapters/).
Usage: dot-sourced by bossy.ps1 (adapters/*.ps1), not run on its own.
Exit codes: none (functions only).
Sections: L9 bugbrief
#>
#Requires -Version 7
# ---- bugbrief: bug-fix brief + /buildy args
function Invoke-BugBrief {
param(
  [Alias('Item')][Parameter(Mandatory)][string]$Task,
  [string]$Agent,
  [string[]]$Repos = @(),   # else its MRs' repos
  [string[]]$Hints = @(),
  [string]$Range,
  [string[]]$Mandate = @(),
  [string[]]$Only = @(), [string]$Skip = '',   # override: fix only these check ids; 'id=why; ..' skipped
  [switch]$Complex
)
$ErrorActionPreference = 'Stop'
$kit = Split-Path (Split-Path $PSScriptRoot)   # skills/ (this file is in skills/bossy/adapters)
$claude = Split-Path $kit
$cfgFile = Join-Path $kit 'crafty/kit.local.json'
$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw | ConvertFrom-Json } else { $null }
if (-not $cfg -or -not $cfg.repos) { throw "add a ""repos"" list to $cfgFile (see kit.example.json)" }

$j = Get-TrackerTask $Task
if (-not $j.name) { throw "cannot read task $Task from the tracker ($($KitConf.TrackerType)) - check its CLI auth / tracker config" }
$desc = [string]$j.description
$texts = @($desc) + @(@(try { Get-TrackerComments $Task } catch { @() }) | Sort-Object date -Descending | ForEach-Object { [string]$_.text })
$checks = @(Get-KitFailedChecks $texts)   # description, comments newest first
$saw = ($desc -replace '\s+', ' ').Trim()   # no checks (watchy [Bug]): task is the check
if (-not $checks) { $checks = @([pscustomobject]@{ id = $Task; screen = [string]$j.name; saw = $saw.Substring(0, [math]::Min(300, $saw.Length)) }) }
if (-not $Agent) { $Agent = "B-$Task" }
$Only = @(Split-KitList $Only); $skipWhy = @{}; foreach ($sk in @($Skip -split ';\s*(?=[^;=]+=)|;\s*$' | Where-Object { $_.Trim() })) { $skId, $skWhy = $sk -split '=', 2; $skipWhy[$skId.Trim()] = $(if ("$skWhy".Trim()) { "$skWhy" -replace '\s+', ' ' } else { 'skipped' }).Trim() }
$unk = @(@($skipWhy.Keys) + $Only | Where-Object { $_ -notin $checks.id }); if ($unk) { throw "bugbrief: no check $($unk -join ', ') on $Task" }
$notHere = @($checks | Where-Object { $skipWhy.ContainsKey($_.id) -or ($Only.Count -and $_.id -notin $Only) }); $checks = @($checks | Where-Object { $_ -notin $notHere })
if (-not $checks.Count) { throw "bugbrief: -Only / -Skip leave no check of $Task" }

$runItem = $null
foreach ($fin in @(Get-KitQaRunFiles finalize.json)) {
  $o = Get-Content $fin.FullName -Raw | ConvertFrom-Json
  if (@($o.subtasks | Where-Object { $_.bug -eq $Task }).Count) { $runItem = $fin.Directory; break }
}
$evidence = if ($runItem) { "Evidence + exported guide: ``$($runItem.FullName)/`` and ``$(Split-Path $runItem.FullName)/guides/$($runItem.Name).txt``." } else { 'Evidence: the results doc linked in the task.' }

$Repos = @($Repos -split '\s*,\s*' | Where-Object { $_ })
$orig = @(try { Get-TaskMrBranches @($Task, [string]$j.parent) } catch { @() })
function RepoName($r) { @($cfg.repos | Where-Object { $_.name -eq $r -or @($_.aliases) -contains $r })[0].name }
foreach ($o in $orig) {   # original ask's repos join unless named
  $rn = RepoName $o.repo
  if ($rn -and -not @($Repos | Where-Object { (RepoName ($_ -split '@')[0]) -eq $rn }).Count) { $Repos += "$rn@$($o.branch)" }
}
if (-not $Repos.Count) {   # no MR yet: the configured area repos (trackerRepos, else repos[]), named on stderr
  $Repos = @(@(if (@($KitConf.TrackerRepos).Count) { $KitConf.TrackerRepos } else { @($cfg.repos | ForEach-Object name) }) | Where-Object { $_ } | Select-Object -Unique)
  if ($Repos.Count) { [Console]::Error.WriteLine("bugbrief: no -Repos and no MR on $Task or its parent: using $($Repos -join ', ') (-Repos narrows it)") } }
if (-not $Repos.Count) { throw "no -Repos, no MR on $Task or its parent and no repos in kit.local.json: -Repos <repo>[@<branch>],..." }
$origLine = if ($orig) { "Original ask's MRs: " + (($orig | ForEach-Object { "$($_.ref) -> ``$($_.branch)``" }) -join ', ') + '.' }
$rows = foreach ($spec in $Repos) {
  $r, $branch = $spec -split '@', 2
  $repo = @($cfg.repos | Where-Object { $_.name -eq $r -or @($_.aliases) -contains $r })[0]
  if (-not $repo) { throw "unknown repo '$r' (kit.local.json repos: $(@($cfg.repos.name) -join ', '))" }
  # must not borrow the default's linked deps
  $deps = if ($branch -and $branch -ne $repo.target) { "a checkout on ``$branch`` (not ``$($repo.linkFrom)``, which is on ``$($repo.target)``; crafty.ps1 wt warns on a mismatch)" } elseif ($repo.linkFrom) { "``$($repo.linkFrom)`` (-LinkFrom)" } else { 'main checkout' }
  "| $($repo.name) | ``$($repo.checkout)`` | ``$(if ($branch) { $branch } else { $repo.target })`` | $deps |"
}
$ids = ($checks | ForEach-Object id) -join ', '
# only what the config declares: a migration tool (repos[].migrations, migrations.tool, localEnv db.migrations) or -Range; an app lane (qa.lanes kind app)
$briefRepos = @($Repos | ForEach-Object { RepoName ($_ -split '@')[0] })
$migTool = "$(Get-KitSetting 'migrations.tool' '')"; $leCfg = Get-KitSetting 'localEnv' $null
$leMig = [bool]@(if ($leCfg) { @($leCfg.defaults) + @(if ($leCfg.envs) { (Get-KitProps $leCfg.envs).Value }) | Where-Object { $_ -and $_.db -and $_.db.migrations } }).Count
$mig = [bool]$Range -or ($migTool -and $migTool -ne 'none') -or $leMig -or [bool]@($cfg.repos | Where-Object { $_.migrations -and $_.name -in $briefRepos }).Count
$lanes = Get-KitSetting 'qa.lanes' $null; $app = [bool]@(if ($lanes) { (Get-KitProps $lanes) | Where-Object { $_.Name -notlike '_*' -and "$($_.Value.kind)" -eq 'app' } }).Count
$slugAgent = $Agent.ToLower()
$runName = "bugfix-$($Task)"
$md = @"
# Bug-fix brief: $($j.name)

Follow ``$claude/skills/crafty/templates.md`` "Bug-fix brief", ``$claude/skills/crafty/SKILL.md`` and ``$claude/skills/envy/SKILL.md`` "Debug locally".
This brief wins where they differ.

Task: $($j.url) — checks $ids to fix. **Reproduce each check on the local env FIRST** (template steps 1-4).
$evidence
$origLine

## Failed checks
$(($checks | ForEach-Object { "- **$($_.id)** — $($_.screen): $($_.saw)" }) -join "`n")
$(if ($notHere) { "`n## Not yours (coordinator)`n" + (($notHere | ForEach-Object { "- **$($_.id)** — $(if ($skipWhy.ContainsKey($_.id)) { $skipWhy[$_.id] } else { 'outside -Only' })" }) -join "`n") + "`n" })$(if ($Hints) { "`n## Coordinator notes`n" + (($Hints | ForEach-Object { "- $_" }) -join "`n") + "`n" })
Fix every check above (root cause + test) or prove it stale/expected with evidence. Fix only these checks. A check you cannot
fix here (another area or repo) needs a follow-up tracker task (cause, proposed fix) linked in a comment on $Task before your MR is done.
Product calls: the reference behaviour or a recorded decision, named. Additive only: users the fix does not target see no change
(crash/500/data-loss fixes may apply to everyone: list them under "Kept for everyone").

## Repos
| Repo | Main checkout | Target | Link deps from |
|---|---|---|---|
$($rows -join "`n")

## Ownership
| Agent | Bug task | Items |$(if ($mig) { ' Migration range |' })
|---|---|---|$(if ($mig) { '---|' })
| $Agent | $Task | $ids |$(if ($mig) { " $(if ($Range) { $Range } else { 'ask the coordinator if you need one' }) |" })

Branches ``$(Get-KitSetting 'tracker.bugBranchPrefix' 'fix/')$($KitConf.TrackerTag)$Task-<slug>``; worktree prefix ``$slugAgent``; board run ``$runName``. Tracker (``$claude/skills/crafty/crafty.ps1 tracker``):
in progress → review (bossy.ps1 track sets promoted when all merge). The workflow merges after review: do NOT merge yourself.
Register: ``$claude/skills/bossy/bossy.ps1 track add -Task $Task -Discover``.
$(if ($app) { "Phones (app bugs): the local-env APK (``phoney.ps1 build -Local``, ``phoney.ps1 acquire -Agent $Agent -Apk local``); release it when done." })
"@
$dir = Get-KitPath briefs -Create
$out = Join-Path $dir "$Task.md"
Set-Content $out $md -Encoding utf8
$null = Test-KitProse -Kind bug-brief -Path $out
$wfArgs = Get-BugWfArgs $out $runName $Agent "$Task $ids" (($checks | ForEach-Object screen) -join '; ') $Mandate $Complex $claude
"brief: $out ($($checks.Count) checks: $ids; model: $(if ($Complex) { 'session (-Complex)' } else { 'sonnet' }))"
"Workflow args (scriptPath $claude/workflows/buildy.js):"
$wfArgs | ConvertTo-Json -Depth 5 -Compress
$tracked = (Read-KitTracking).tasks.ContainsKey($Task)
if ($tracked) { "already tracked: $Task" } else {
  $ta = @(& $KitCmd.orch track add -Task $Task -Discover 2>&1); $tc = $LASTEXITCODE
  if ($tc) { "NOT tracked: $Task (track add exit ${tc}: $(($ta | Select-Object -Last 2) -join ' ')): run bossy.ps1 track add -Task $Task -Discover" } else { "tracking $Task (-Discover)" }
}
}
