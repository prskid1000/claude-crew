<#
SessionStart hook: one line when the workspace kit needs attention (orchestrate event E17), nothing otherwise.
  - drift: sync-kit.ps1 writes <kit>/kit-sync.local.json (source clone, commit, time); when the source clone has newer commits
    (or uncommitted kit changes) the line says so: sync once no agents run.
  - kit-lint summary (fast, warn only): unrouted parts, unlisted files, fuzzy triggers, dangling paths, overlay problems.
  pwsh -File kit-health.ps1          # the two checks above (synchronous hook, well under 2 s)
  pwsh -File kit-health.ps1 -Flow    # regenerate <runtime>/kit-flow.html (async hook; never blocks start)
#>
param([switch]$Flow)
$ErrorActionPreference = 'SilentlyContinue'
$kit = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # <kit>/skills/orchestrate/scripts -> <kit>
$py = @('python3', 'python') | ForEach-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } | Where-Object { $_ } | Select-Object -First 1
if ($Flow) { if ($py) { & $py (Join-Path $PSScriptRoot 'kit-flow.py') $kit | Out-Null }; exit 0 }

$msgs = @()
$stampFile = Join-Path $kit 'kit-sync.local.json'
if (Test-Path $stampFile) {
  try {
    $st = Get-Content $stampFile -Raw | ConvertFrom-Json
    if ($st.source -and (Test-Path $st.source)) {
      $repo = Split-Path $st.source
      $head = (git -C $repo rev-parse --short HEAD 2>$null)
      if ($head -and $st.commit -and $head.Trim() -ne $st.commit) {
        $n = (git -C $repo rev-list --count "$($st.commit)..HEAD" 2>$null)
        $msgs += "kit drift: the workspace kit is synced to $($st.commit) ($($st.at)) but its source $repo is at $($head.Trim())$(if ($n) { " ($($n.Trim()) commit(s) ahead)" }). Sync once no agents run: pwsh -File $(Join-Path $st.source 'skills/dev-kit/scripts/sync-kit.ps1') -To $kit -Clean"
      }
      elseif ((git -C $repo status --porcelain -- .claude 2>$null)) {
        $msgs += "kit drift: the kit source $repo has uncommitted changes the workspace does not have yet (commit, push, then sync-kit)."
      }
    }
  } catch {}
}
if ($py) {
  $lint = & $py (Join-Path $PSScriptRoot 'kit-lint.py') $kit --summary --warn --no-flow 2>$null
  if ($lint) { $msgs += ($lint -join ' ') }
}
if ($msgs) {
  $text = ($msgs -join ' | ') + ' (orchestrate Events E17)'
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
