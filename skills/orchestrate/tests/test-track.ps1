# track.ps1 add/remove offline, in a throw-away copy of the kit (its own tracking.local.json; refs without a group never reach glab).
#   pwsh -NoProfile -File <kit>/skills/orchestrate/tests/test-track.ps1      exit 0 = all pass
$src = Split-Path (Split-Path (Split-Path $PSScriptRoot))
$tmp = Join-Path ([IO.Path]::GetTempPath()) "kit-test-track-$PID"; $kit = Join-Path $tmp '.claude'
foreach ($d in 'skills/dev-kit/scripts', 'skills/orchestrate/scripts') { New-Item -ItemType Directory -Force (Join-Path $kit $d) | Out-Null }
Copy-Item (Join-Path $src 'skills/dev-kit/scripts/*') (Join-Path $kit 'skills/dev-kit/scripts') -Recurse
Copy-Item (Join-Path $src 'skills/orchestrate/scripts/track.ps1') (Join-Path $kit 'skills/orchestrate/scripts')
$env:KIT_TRACKER_TYPE = 'clickup'; Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # tag CU-; runtime = the temp kit's own
$T = Join-Path $kit 'skills/orchestrate/scripts/track.ps1'; $tf = Join-Path $kit 'tracking.local.json'
$fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
function Tasks { (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks }
try {
  $o = pwsh -NoProfile -File $T add -Task 0 -Mrs 'web!1' 2>&1 | Out-String
  Expect "placeholder task '0' refused" ($LASTEXITCODE -ne 0 -and $o -match 'needs a real -Task id')
  $o = pwsh -NoProfile -File $T add -Task 'CU-abc123' -Mrs 'web!1,web!2' -MergeAfter 'web!2>api!7' 2>&1 | Out-String
  Expect 'tag stripped from the task id' ((Tasks).ContainsKey('abc123') -and -not (Tasks).ContainsKey('CU-abc123'))
  Expect 'add echoes the merge order' ($o -match 'merge-after: web!2>api!7')
  $null = pwsh -NoProfile -File $T remove -Task abc123 -Mrs 'web!2' 2>&1
  Expect 'remove drops the MR and its pair' ((@((Tasks).abc123.mrs) -join ',') -eq 'web!1' -and -not @((Tasks).abc123.mergeAfter).Count)
  $null = pwsh -NoProfile -File $T remove -Task abc123 2>&1
  Expect 'remove drops the task' (-not (Tasks).ContainsKey('abc123'))
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
"$fails failure(s)"; exit [int]($fails -gt 0)
