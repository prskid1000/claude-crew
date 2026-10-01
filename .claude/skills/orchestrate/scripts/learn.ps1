<#
Record one learning signal (anything that cost time, failed, surprised you, or worked unusually well).
Signals are raw observations; /kit-retro and each workflow's learn step turn recurring ones into LESSONS.md entries.

  $L = '<workspace>\.claude\skills\orchestrate\scripts\learn.ps1'
  & $L -Skill dev-kit -Kind friction -Text "wt.ps1 new warned deps differ for frontend; -LinkFrom <checkout of the target branch> fixed it"
  & $L -Skill qa-kit  -Kind defect-missed -Text "tester marked 500 on save as PASS_WITH_NOTE; audit caught it" -Ref F2-T4
  & $L -Show [-Last 30]          # print recent signals
  & $L -Stats                    # counts per skill/kind since the last retro

-Skill: orchestrate | dev-kit | qa-kit | android-swarm | tech-audit | <project name>
-Kind : friction (slow/awkward) | failure (tool/script broke) | defect-missed | false-positive | rule-violation |
        stale-env | flaky | idea | win (something that worked well and should become the default)
#>
param(
  [string]$Skill, [ValidateSet('friction', 'failure', 'defect-missed', 'false-positive', 'rule-violation', 'stale-env', 'flaky', 'idea', 'win')][string]$Kind,
  [string]$Text, [string]$Ref = '', [string]$Source = 'agent',
  [switch]$Show, [int]$Last = 30, [switch]$Stats
)
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($PSCommandPath -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }
$dir = Join-Path $rt 'learning'; New-Item -ItemType Directory -Force $dir | Out-Null
$file = Join-Path $dir 'signals.jsonl'
$mark = Join-Path $dir 'last-retro.txt'

if ($Show) { if (Test-Path $file) { Get-Content $file -Tail $Last | ForEach-Object { $s = $_ | ConvertFrom-Json; '{0} {1,-13} {2,-15} {3}{4}' -f ([datetime]$s.at).ToString('yyyy-MM-dd HH:mm'), $s.skill, $s.kind, $s.text, $(if ($s.ref) { " [$($s.ref)]" }) } }; return }
if ($Stats) {
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  $all = if (Test-Path $file) { @(Get-Content $file | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [datetime]$_.at -gt $since }) } else { @() }
  "signals since last retro ($(if ($since -eq [datetime]::MinValue) { 'never' } else { $since.ToString('d MMM HH:mm') })): $($all.Count)"
  $all | Group-Object skill, kind | Sort-Object Count -Descending | ForEach-Object { '  {0,3}  {1}' -f $_.Count, $_.Name }
  return
}
if (-not ($Skill -and $Kind -and $Text)) { throw 'need -Skill -Kind -Text (or -Show / -Stats)' }
[ordered]@{ at = (Get-Date).ToString('s'); skill = $Skill; kind = $Kind; text = $Text; ref = $Ref; source = $Source } |
  ConvertTo-Json -Compress | Add-Content $file
"recorded ($Skill/$Kind)"
