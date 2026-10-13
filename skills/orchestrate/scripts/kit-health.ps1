<#
SessionStart hook: one line when the workspace kit needs attention (orchestrate event E17), nothing otherwise. No network.
The kit (the workspace's .claude folder) is a git clone of the kit repo, edited in place:
  - git: uncommitted kit changes, and commits behind/ahead of the LAST FETCHED upstream (git status --branch; the async
    -Fetch hook refreshes it for the next start); core.hooksPath must be .githooks (the pre-push gate)
  - kit.local.json "localOnly" paths are kept in .git/info/exclude (kit-setup.ps1 -Exclude; rewrites only on change)
  - an old runtime next to .claude (pre-clone layout) -> migrate it (kit-setup.ps1 -Migrate)
  - kit-lint summary (warn only): unrouted parts, unlisted files, fuzzy triggers, dangling paths, raw runtime paths,
    durable state inside the runtime (RUNTIME-DURABLE), overlay problems
  pwsh -File kit-health.ps1                # the checks above (synchronous hook, well under 2 s)
  pwsh -File kit-health.ps1 -Flow -Fetch   # async hook: regenerate <runtime>/cache/kit-flow.html, git fetch the kit's upstream
#>
param([switch]$Flow, [switch]$Fetch)
$ErrorActionPreference = 'SilentlyContinue'
$kit = Split-Path (Split-Path (Split-Path $PSScriptRoot))   # <kit>/skills/orchestrate/scripts -> <kit>
$py = @('python3', 'python') | ForEach-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } | Where-Object { $_ } | Select-Object -First 1
if ($Flow -or $Fetch) {
  if ($Fetch -and (Test-Path (Join-Path $kit '.git'))) { git -C $kit fetch --quiet 2>$null }
  if ($Flow -and $py) { & $py (Join-Path $PSScriptRoot 'kit-flow.py') $kit | Out-Null }
  exit 0
}

$msgs = @()
if (Test-Path (Join-Path $kit '.git')) {
  try { & (Join-Path $PSScriptRoot 'kit-setup.ps1') -Exclude -Quiet | Out-Null } catch {}
  $st = @(git -C $kit status --porcelain=v1 --branch 2>$null)
  $head = [string]($st | Select-Object -First 1)
  $changes = @($st | Select-Object -Skip 1).Count
  $parts = @()
  if ($changes) { $parts += "$changes uncommitted change(s) (commit + push them, or list org-only paths in kit.local.json localOnly)" }
  if ($head -match '\.\.\.(?<up>\S+)') {
    $up = $Matches.up
    if ($head -match 'behind (?<b>\d+)') { $parts += "$($Matches.b) commit(s) behind $up (git -C $kit pull --rebase once no agents run)" }
    if ($head -match 'ahead (?<a>\d+)') { $parts += "$($Matches.a) commit(s) ahead of $up (push them)" }
  }
  if ((git -C $kit config core.hooksPath 2>$null) -ne '.githooks') { $parts += "pre-push gate off (run: pwsh -File $(Join-Path $PSScriptRoot 'kit-setup.ps1'))" }
  if ($parts) { $msgs += "kit: " + ($parts -join '; ') }
} else {
  $msgs += "kit: $kit is not a git clone of the kit repo (install: git clone https://github.com/prskid1000/claude-crew <workspace>/.claude; docs/install.md)"
}
. (Join-Path $kit 'skills/dev-kit/scripts/kitpaths.ps1')
$legacy = Join-Path (Split-Path $kit) '.claude-runtime'
if ((Test-Path $legacy) -and $legacy -ne (Get-KitPath runtime)) { $msgs += "old runtime at $($legacy): carry it over once no agents run: pwsh -File $(Join-Path $PSScriptRoot 'kit-setup.ps1') -Migrate $legacy" }
if ($py) {
  $lint = & $py (Join-Path $PSScriptRoot 'kit-lint.py') $kit --summary --warn --no-flow 2>$null
  if ($lint) { $msgs += ($lint -join ' ') }
  $portKit = Join-Path $PSScriptRoot 'port-kit.py'
  if (Test-Path $portKit) {
    & $py $portKit --check 2>$null | ForEach-Object { $msgs += $_ }
  }
}
if ($msgs) {
  $text = ($msgs -join ' | ') + ' (orchestrate Events E17)'
  @{ systemMessage = $text; hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $text } } | ConvertTo-Json -Compress -Depth 4
}
exit 0
