<#
Writes a bug-fix wave brief from a QA-raised "[Bug] … failed checks" task, so the coordinator only adds judgement (hints, overlaps),
not boilerplate. It pulls the failed checks (id, screen, what was seen) from the task, adds the repo table, the evidence/guide location
of the QA run that raised it, ownership, branch/board/merge rules, and prints the /dev-wave args to launch (incl. mandate).

  $BB = '<workspace>/.claude/skills/orchestrate/scripts/bug-brief.ps1'
  & $BB -Task 86abc123 -Agent B-CHK -Repos api,web [-Hints 'X3: reuse the existing time zone helper'] [-Range 20260101000000-20260101005959]

Repos: names or aliases from kit.local.json "repos" (each: { name, checkout, target, linkFrom?, aliases[] }); `name@branch` overrides the
target for this bug (e.g. web@main when the same repo ships two products from different branches). The brief lands next to the
other briefs (<runtime>/briefs/<task>.md); the script prints the path and the Workflow args JSON.
Mandate: kit.local.json "bugfixMandate" (the task owner's own words asking the coordinator to fix QA bugs), else -Mandate.
#>
param(
  [Parameter(Mandatory)][string]$Task,
  [Parameter(Mandatory)][string]$Agent,
  [Parameter(Mandatory)][string[]]$Repos,
  [string[]]$Hints = @(),
  [string]$Range,
  [string[]]$Mandate = @()
)
$ErrorActionPreference = 'Stop'
$kit = Split-Path (Split-Path $PSScriptRoot)                     # .../.claude/skills
$claude = Split-Path $kit
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path (Split-Path $claude) '.claude-runtime' }
$cfgFile = Join-Path $kit 'dev-kit\kit.local.json'
$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw | ConvertFrom-Json } else { $null }
if (-not $cfg -or -not $cfg.repos) { throw "add a ""repos"" list to $cfgFile (see kit.example.json)" }

. (Join-Path $kit 'dev-kit\scripts\tracker.ps1')                # Get-TrackerTask etc. (tracker.type in kit.local.json)
$j = Get-TrackerTask $Task
if (-not $j.name) { throw "cannot read task $Task from the tracker ($($KitConf.TrackerType)) - check its CLI auth / tracker config" }
$desc = [string]$j.description
# failed checks: "### <id> — <screen>" then "**Saw:** ..."
$checks = @(); $cur = $null
foreach ($line in $desc -split "`n") {
  if ($line -match '^###\s+(?<id>\S+)\s+[—-]\s+(?<screen>.+)$') { if ($cur) { $checks += $cur }; $cur = [ordered]@{ id = $Matches.id; screen = $Matches.screen.Trim(); saw = '' } }
  elseif ($cur -and $line -match '^\*\*Saw:\*\*\s*(?<s>.+)$') { $s = ($Matches.s -split '\| Independent re-test')[0].Trim(); $cur.saw = if ($s.Length -gt 500) { $s.Substring(0, 497) + '...' } else { $s } }
}
if ($cur) { $checks += $cur }
if (-not $checks) { throw "no '### <id> — <screen>' failed checks found in $Task" }

# the QA run that raised it: the run folder whose finalize.json names this bug
$runItem = $null
foreach ($fin in Get-ChildItem (Join-Path $rt 'qa-runs') -Recurse -Filter finalize.json -ErrorAction SilentlyContinue) {
  $o = Get-Content $fin.FullName -Raw | ConvertFrom-Json
  if (@($o.subtasks | Where-Object { $_.bug -eq $Task }).Count) { $runItem = $fin.Directory; break }
}
$evidence = if ($runItem) { "Evidence + exported guide: ``$($runItem.FullName)\`` and ``$(Split-Path $runItem.FullName)\guides\$($runItem.Name).txt``." } else { 'Evidence: the results doc linked in the task.' }

$Repos = @($Repos -split '\s*,\s*' | Where-Object { $_ })   # "api,web" passed as one string (variables, other shells) works like api,web
$rows = foreach ($spec in $Repos) {
  $r, $branch = $spec -split '@', 2
  $repo = @($cfg.repos | Where-Object { $_.name -eq $r -or @($_.aliases) -contains $r })[0]
  if (-not $repo) { throw "unknown repo '$r' (kit.local.json repos: $(@($cfg.repos.name) -join ', '))" }
  # an overridden target must not borrow deps linked for the default target (different package versions break builds)
  $deps = if ($branch -and $branch -ne $repo.target) { "a checkout on ``$branch`` (not ``$($repo.linkFrom)``, which is on ``$($repo.target)``; wt.ps1 warns on a mismatch)" } elseif ($repo.linkFrom) { "``$($repo.linkFrom)`` (-LinkFrom)" } else { 'main checkout' }
  "| $($repo.name) | ``$($repo.checkout)`` | ``$(if ($branch) { $branch } else { $repo.target })`` | $deps |"
}
$ids = ($checks | ForEach-Object id) -join ', '
$slugAgent = $Agent.ToLower()
$runName = "bugfix-$($Task)"
$md = @"
# Bug-fix brief: $($j.name)

Follow ``$claude\skills\orchestrate\templates\BUGFIX_BRIEF.md`` and ``$claude\skills\dev-kit\SKILL.md`` (read dev-kit LESSONS.md first).
This brief wins where they differ.

Bug task: $($j.url) — failed checks $ids (each has steps, what was seen, the independent re-test and evidence links).
$evidence

## Failed checks
$(($checks | ForEach-Object { "- **$($_.id)** — $($_.screen): $($_.saw)" }) -join "`n")
$(if ($Hints) { "`n## Coordinator notes`n" + (($Hints | ForEach-Object { "- $_" }) -join "`n") + "`n" })
**No deferrals.** Fix every check above (root cause + test) or prove it stale/expected with evidence. Fix only these checks.
Product calls: pick the behaviour of the reference product/decisions in memory and say so. Additive changes only; existing users and
tenants with the feature off must see no change (crash/500/data-loss fixes may apply to everyone - list them under "Kept for everyone").

## Repos
| Repo | Main checkout | Target | Link deps from |
|---|---|---|---|
$($rows -join "`n")

## Ownership
| Agent | Bug task | Items | Migration range |
|---|---|---|---|
| $Agent | $Task | $ids | $(if ($Range) { $Range } else { 'ask the coordinator if you need one' }) |

Branches ``fix/$($KitConf.TrackerTag)$Task-<slug>``; worktree prefix ``$slugAgent``; board run ``$runName``. Tracker (``$claude\skills\dev-kit\scripts\tracker.ps1``):
in progress → review (the coordinator's track.ps1 sets promoted). This wave is reviewed: do NOT schedule merges; the workflow does it after review.
Register: ``$claude\skills\orchestrate\scripts\track.ps1 add -Task $Task -Discover``.
Phones (app bugs): only if you really need one, ``$claude\skills\android-swarm\phone.ps1 acquire -Agent $Agent``, release it when done.
"@
$dir = Join-Path $rt 'briefs'; New-Item -ItemType Directory -Force $dir | Out-Null
$out = Join-Path $dir "$Task.md"
Set-Content $out $md -Encoding utf8
$m = if ($Mandate) { $Mandate } elseif ($cfg.bugfixMandate) { @($cfg.bugfixMandate) } else { Write-Warning 'no mandate: pass -Mandate or set kit.local.json "bugfixMandate" (agents drop their items for later chat messages without one)'; @() }
# model: dev-wave builds on sonnet unless the agent is marked complex (strongest model). Complex = more than 2 failed checks, or any
# check that isn't cosmetic (label / colour / i18n / raw key / date format / typo / alignment ...): logic, data or crash bugs.
$cosmetic = '(?i)label|translation|i18n|raw (translation )?key|colou?r|date format|typo|spelling|alignment|padding|wording|icon'
$complex = $checks.Count -gt 2 -or @($checks | Where-Object { ($_.screen + ' ' + $_.saw) -notmatch $cosmetic }).Count
$agentArgs = [ordered]@{ id = $Agent; items = "$Task $ids" }; if ($complex) { $agentArgs.complex = $true }
$wfArgs = [ordered]@{ brief = $out; run = $runName; mode = 'bugfix'; review = $true; mandate = $m; agents = @($agentArgs) }
$wfArgs.agents[0].area = (($checks | ForEach-Object screen) -join '; ').Substring(0, [math]::Min(160, (($checks | ForEach-Object screen) -join '; ').Length))
"brief: $out ($($checks.Count) checks: $ids; model: $(if ($complex) { 'strongest (complex: true)' } else { 'sonnet (small/cosmetic)' }))"
"Workflow args (scriptPath $claude\workflows\dev-wave.js):"
$wfArgs | ConvertTo-Json -Depth 5 -Compress
$tf = Join-Path $rt "tracking\$Task.json"
if (Test-Path $tf) { "already tracked: $Task" } else { & (Join-Path $PSScriptRoot 'track.ps1') add -Task $Task -Discover | Out-Null; "tracking $Task (-Discover)" }
