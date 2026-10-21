#Requires -Version 7
<#
tests.ps1 (extra track-rebuild): offline, on a throw-away copy of the kit's orch.ps1 + lib.ps1 with this extra's files.
Usage: pwsh -NoProfile -File extras/track-rebuild/tests.ps1 -Kit <kit>
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
$k = Join-Path ([IO.Path]::GetTempPath()) "extra-test-$PID\.claude"
foreach ($f in 'skills/dev-kit/lib.ps1', 'skills/dev-kit/kit.example.json', 'skills/dev-kit/dev.ps1', 'skills/orchestrate/orch.ps1') { New-Item -ItemType Directory -Force (Join-Path $k (Split-Path $f)) | Out-Null; Copy-Item (Join-Path $Kit $f) (Join-Path $k $f) }
Copy-Item -Recurse (Join-Path $PSScriptRoot 'files/*') $k -Force
Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue
$O = Join-Path $k 'skills/orchestrate/orch.ps1'; $np = '-NoProfile', '-File'
try {
  $out = pwsh @np $O track -Rebuild 2>&1 | Out-String
  $tf = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath tracking }
  Expect 'track -Rebuild without trackerRepos: an empty tracking file and the config hint' ((Test-Path $tf) -and $out -match 'trackerRepos')
  $out2 = pwsh @np $O track -Rebuild 2>&1 | Out-String
  Expect 'track -Rebuild keeps an existing file (no -Force)' ($out2 -match 'nothing to rebuild')
} finally { Remove-Item (Split-Path $k) -Recurse -Force -ErrorAction SilentlyContinue }
exit [int]($script:fails -gt 0)
