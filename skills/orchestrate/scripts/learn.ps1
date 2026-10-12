<#
Record one learning signal (anything that cost time, failed, surprised you, or worked unusually well), and keep each skill's
LESSONS.md short. Signals are raw observations; /kit-retro and each workflow's learn step turn recurring ones into lessons.

  $L = '<workspace>/.claude/skills/orchestrate/scripts/learn.ps1'
  & $L -Skill dev-kit -Kind friction -Text "wt.ps1 new warned deps differ for frontend; -LinkFrom <checkout of the target branch> fixed it"
  & $L -Skill qa-kit  -Kind defect-missed -Text "tester marked 500 on save as PASS_WITH_NOTE; audit caught it" -Ref F2-T4
  & $L -Show [-Last 30]          # print recent signals
  & $L -Stats                    # counts per skill/kind since the last retro

Lessons (learn steps, /kit-retro, the lead):
  & $L -Skill qa-kit -Lesson "(2×) <one actionable line>" [-Project <name>]   # new ACTIVE lesson: top of ## General (or ## Project: <name>)
  & $L -Skill dev-kit -Fixed "<unique words of a lesson>"   # the kit now handles it: move that line to HISTORY.md as "(fixed in kit) ..."
  & $L -Skill dev-kit -Trim [-Max 40]                       # enforce the cap: move "(fixed in kit)" lines, then the oldest
                                                            # (bottom) lines, verbatim to HISTORY.md until LESSONS.md has <= Max lines
LESSONS.md = active rules agents read (newest first, one line each); HISTORY.md next to it = moved lines, never read by agents.
-Lesson and -Fixed trim automatically.

-Skill: orchestrate | dev-kit | qa-kit | android-swarm | tech-audit | <project name>
-Kind : friction (slow/awkward) | failure (tool/script broke) | defect-missed | false-positive | rule-violation |
        stale-env | flaky | idea | win (something that worked well and should become the default)
#>
param(
  [string]$Skill, [ValidateSet('friction', 'failure', 'defect-missed', 'false-positive', 'rule-violation', 'stale-env', 'flaky', 'idea', 'win')][string]$Kind,
  [string]$Text, [string]$Ref = '', [string]$Source = 'agent',
  [switch]$Show, [int]$Last = 30, [switch]$Stats,
  [string]$Lesson, [string]$Project, [string]$Fixed, [switch]$Trim, [int]$Max = 40
)
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path ($PSCommandPath -replace '[\\/]\.claude[\\/].*$', '') '.claude-runtime' }
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

# ---- lessons: LESSONS.md (active, capped) and HISTORY.md (moved lines, verbatim) ----
if ($Lesson -or $Fixed -or $Trim) {
  if (-not $Skill) { throw 'need -Skill <skill folder> with -Lesson / -Fixed / -Trim' }
  $sd = Join-Path (Split-Path (Split-Path $PSScriptRoot)) $Skill
  $lf = Join-Path $sd 'LESSONS.md'; $hf = Join-Path $sd 'HISTORY.md'
  if (-not (Test-Path $lf)) { throw "no LESSONS.md in skill '$Skill' ($lf)" }
  $L = [System.Collections.Generic.List[string]]@((Get-Content $lf -Raw) -split "`r?`n")
  while ($L.Count -and $L[$L.Count - 1] -eq '') { $L.RemoveAt($L.Count - 1) }
  $moved = New-Object System.Collections.Generic.List[string]
  if ($Lesson) {
    $line = '- ' + ($Lesson.Trim() -replace '^-\s*', '')
    $head = if ($Project) { "## Project: $Project" } else { '## General' }
    $at = -1; for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -eq $head -or ($Project -and $L[$i] -like "$head *")) { $at = $i; break } }
    if ($at -lt 0) {
      if ($Project) { $L.Add(''); $L.Add($head); $L.Add($line) }
      else { $first = 0; for ($i = 0; $i -lt $L.Count; $i++) { if ($L[$i] -match '^- ') { $first = $i; break } }; if (-not $first) { $first = $L.Count }; $L.Insert($first, $line) }
    } else { $L.Insert($at + 1, $line) }
    "lesson added to $Skill/LESSONS.md ($head)"
  }
  if ($Fixed) {
    $hit = @(0..($L.Count - 1) | Where-Object { $L[$_] -match '^- ' -and $L[$_].Contains($Fixed) })
    if ($hit.Count -ne 1) { throw "-Fixed must match exactly one lesson line (matched $($hit.Count))" }
    $moved.Add(($L[$hit[0]] -replace '^- (\(fixed in kit\) )?', '- (fixed in kit) ')); $L.RemoveAt($hit[0])
  }
  # cap: fixed-in-kit lines first, then the oldest (bottom-most) lessons
  foreach ($i in @(($L.Count - 1)..0 | Where-Object { $L[$_] -match '^- \((\d+×, )?fixed in kit' })) { $moved.Insert(0, $L[$i]); $L.RemoveAt($i) }
  $gEnd = { $g = $L.IndexOf('## General'); if ($g -lt 0) { return $L.Count - 1 }; for ($k = $g + 1; $k -lt $L.Count; $k++) { if ($L[$k] -match '^## ') { return $k - 1 } }; $L.Count - 1 }
  while ($L.Count -gt $Max) {
    # oldest = the last line of ## General (project gotchas below it stay), else the last lesson in the file
    $i = (& $gEnd)..0 | Where-Object { $L[$_] -match '^- ' } | Select-Object -First 1
    if ($null -eq $i) { $i = ($L.Count - 1)..0 | Where-Object { $L[$_] -match '^- ' } | Select-Object -First 1 }
    if ($null -eq $i) { break }
    $moved.Add($L[$i]); $L.RemoveAt($i)
  }
  [IO.File]::WriteAllText($lf, (($L -join "`n") + "`n"))
  if ($moved.Count) {
    $h = if (Test-Path $hf) { (Get-Content $hf -Raw).TrimEnd() } else { "# $Skill - lessons history (NOT read by agents)" }
    if ($h -notmatch '(?m)^## Moved by learn\.ps1') { $h += "`n`n## Moved by learn.ps1 (-Fixed / -Trim), oldest first" }
    [IO.File]::WriteAllText($hf, $h + "`n" + ($moved -join "`n") + "`n")
  }
  "$Skill/LESSONS.md: $($L.Count) lines (max $Max)$(if ($moved.Count) { "; moved $($moved.Count) to HISTORY.md" })"
  return
}

if (-not ($Skill -and $Kind -and $Text)) { throw 'need -Skill -Kind -Text (or -Show / -Stats / -Lesson / -Fixed / -Trim)' }
[ordered]@{ at = (Get-Date).ToString('s'); skill = $Skill; kind = $Kind; text = $Text; ref = $Ref; source = $Source } |
  ConvertTo-Json -Compress | Add-Content $file
"recorded ($Skill/$Kind)"
