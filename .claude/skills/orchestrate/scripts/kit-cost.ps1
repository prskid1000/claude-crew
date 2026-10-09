#Requires -Version 7
<#
Token budget of the kit: approx tokens (UTF-8 bytes / 4) each agent type reads when it starts — the always-loaded files
(CLAUDE.md, rules/multi-agent.md, the skill index), its agent definition, the files that definition tells it to read first,
and the prompt the workflow builds for it (rendered by kit-cost.mjs: each workflow runs with mock agents and sample args).

  $C = '<workspace>/.claude/skills/orchestrate/scripts/kit-cost.ps1'
  & $C                                      # table
  & $C -SaveJson before.json                # keep a baseline
  & $C -Baseline before.json -Out kit-cost.md   # BEFORE vs AFTER table, also written as Markdown
  & $C -Live                                # also measure one real supervise round (default and -Brief output)
  & $C -Steps                               # every workflow step: label, agent type, model, prompt tokens (behaviour diff)

Keep $Reads in step with agents/*.md and the skills' "read first" lines when they change.
#>
param([string]$Out, [string]$SaveJson, [string]$Baseline, [string]$Label = 'AFTER', [switch]$Live, [switch]$Steps, [switch]$Json)
$ErrorActionPreference = 'Stop'
$kit = Split-Path (Split-Path (Split-Path (Split-Path $PSCommandPath)))   # <workspace>/.claude
function Tok([string]$s) { [int][math]::Ceiling([Text.Encoding]::UTF8.GetByteCount($s) / 4) }
function FileTok($rel) { $p = Join-Path $kit $rel; if (Test-Path $p) { Tok (Get-Content $p -Raw) } else { 0 } }

# what every session loads: CLAUDE.md + always-on rules + one description line per skill (path-scoped rules load later)
$skillIndex = (Get-ChildItem (Join-Path $kit 'skills') -Directory | ForEach-Object {
    $f = Join-Path $_.FullName 'SKILL.md'; if (Test-Path $f) { (Get-Content $f -Raw) -replace '(?s)^---\s*(.*?)\s*---.*$', '$1' } }) -join "`n"
$base = (FileTok 'CLAUDE.md') + (FileTok 'rules/multi-agent.md') + (Tok $skillIndex)

# agent type -> files read at start (agent definition + its "read first" list) and the workflow step whose prompt it gets
$Reads = [ordered]@{
  'dev-agent (build)' = @{ files = 'agents/dev-agent.md', 'skills/dev-kit/LESSONS.md', 'skills/dev-kit/SKILL.md'; step = 'build:X1' }
  'dev-agent (fix)'   = @{ files = 'agents/dev-agent.md', 'skills/dev-kit/LESSONS.md', 'skills/dev-kit/SKILL.md'; step = 'fix:X2' }
  'mr-reviewer'       = @{ files = 'agents/mr-reviewer.md', 'skills/dev-kit/LESSONS.md', 'skills/dev-kit/SKILL.md'; step = 'review:X1' }
  'qa-tester (web)'   = @{ files = 'agents/qa-tester.md', 'skills/qa-kit/LESSONS.md', 'skills/qa-kit/SKILL.md', 'skills/qa-kit/reference/evidence-standard.md'; step = 'test:W1' }
  'qa-tester (app)'   = @{ files = 'agents/qa-tester.md', 'skills/qa-kit/LESSONS.md', 'skills/qa-kit/SKILL.md', 'skills/qa-kit/reference/evidence-standard.md'; step = 'test:P1@Falcon' }
  'qa-verifier'       = @{ files = 'agents/qa-verifier.md', 'skills/qa-kit/LESSONS.md', 'skills/qa-kit/SKILL.md', 'skills/qa-kit/reference/evidence-standard.md'; step = 'verify:W1' }
  'coordinator'       = @{ files = 'skills/orchestrate/SKILL.md', 'skills/orchestrate/LESSONS.md'; step = '' }
}
$calls = @((node (Join-Path $PSScriptRoot 'kit-cost.mjs') $kit | ConvertFrom-Json).calls)
if (-not $calls.Count) { throw 'kit-cost.mjs rendered no prompts (node missing or a workflow failed)' }
foreach ($c in $calls) { $c | Add-Member tokens ([int][math]::Ceiling($c.bytes / 4)) }

if ($Steps) { $calls | ForEach-Object { '{0,-15} {1,-16} {2,-12} {3,-7} {4,-6} {5,6}' -f $_.wf, $_.label, $_.agentType, $_.model, $_.effort, $_.tokens }; return }

$rows = foreach ($k in $Reads.Keys) {
  $r = $Reads[$k]; $files = ($r.files | ForEach-Object { FileTok $_ } | Measure-Object -Sum).Sum
  $prompt = if ($r.step) { [int](@($calls | Where-Object label -eq $r.step)[0].tokens) } else { 0 }
  [pscustomobject]@{ agent = $k; base = $base; files = [int]$files; prompt = $prompt; total = [int]($base + $files + $prompt) }
}
# a whole sample run: every step's prompt + what its agent reads at start (typed agents: their definition + read list; others: base only)
$typeFiles = @{}; foreach ($k in $Reads.Keys) { $t = ($k -split ' ')[0]; if (-not $typeFiles[$t]) { $typeFiles[$t] = ($Reads[$k].files | ForEach-Object { FileTok $_ } | Measure-Object -Sum).Sum } }
foreach ($wf in @($calls.wf | Select-Object -Unique)) {
  $cs = @($calls | Where-Object wf -eq $wf)
  $sum = ($cs | ForEach-Object { $base + $_.tokens + $(if ($_.agentType) { [int]$typeFiles[$_.agentType] } else { 0 }) } | Measure-Object -Sum).Sum
  $rows += [pscustomobject]@{ agent = "run: $wf ($($cs.Count) steps)"; base = $base * $cs.Count; files = [int]($sum - $base * $cs.Count - ($cs | Measure-Object tokens -Sum).Sum); prompt = [int]($cs | Measure-Object tokens -Sum).Sum; total = [int]$sum }
}
if ($Live) {
  $sup = Join-Path $PSScriptRoot 'supervise.ps1'
  $full = (& $sup 2>&1 | Out-String); $rows += [pscustomobject]@{ agent = 'supervise round (default)'; base = 0; files = 0; prompt = (Tok $full); total = (Tok $full) }
  if ((Get-Command $sup).Parameters.ContainsKey('Brief')) { $b = (& $sup -Brief 2>&1 | Out-String); $rows += [pscustomobject]@{ agent = 'supervise round (-Brief)'; base = 0; files = 0; prompt = (Tok $b); total = (Tok $b) } }
}
if ($SaveJson) { $rows | ConvertTo-Json | Set-Content $SaveJson -Encoding utf8 }
if ($Json) { $rows | ConvertTo-Json; return }

$before = @{}; if ($Baseline) { foreach ($b in (Get-Content $Baseline -Raw | ConvertFrom-Json)) { $before[$b.agent] = $b } }
$md = New-Object System.Collections.Generic.List[string]
if ($Baseline) {
  $md.Add('| Agent / run | BEFORE | AFTER | change | AFTER: always-loaded + start files + prompt |'); $md.Add('|---|---:|---:|---:|---|')
  foreach ($r in $rows) {
    $b = $before[$r.agent]; $bt = if ($b) { [int]$b.total } else { $null }
    $chg = if ($bt) { '{0:+0;-0}%' -f (100 * ($r.total - $bt) / $bt) } else { 'new' }
    $md.Add("| $($r.agent) | $(if ($bt) { $bt } else { '-' }) | $($r.total) | $chg | $($r.base) + $($r.files) + $($r.prompt) |")
  }
} else {
  $md.Add("| Agent / run | always-loaded | start files | prompt | $Label total |"); $md.Add('|---|---:|---:|---:|---:|')
  foreach ($r in $rows) { $md.Add("| $($r.agent) | $($r.base) | $($r.files) | $($r.prompt) | $($r.total) |") }
}
if ($Out) { $md -join "`n" | Set-Content $Out -Encoding utf8; "written: $Out" }
$md
