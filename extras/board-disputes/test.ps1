#Requires -Version 7
# Offline test of the extra: a throw-away copy of the kit's orch.ps1 + lib.ps1 with this extra installed. Exit 0 pass, 1 fail.
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
  $dp = pwsh @np $O board dispute -Agent X7 -With R7 -Item A1 -Claim 'no null check needed' -Evidence 'a.ts:3' -Propose 'drop it' | Out-String
  $did = if ($dp -match 'DISPUTE (p-\S+) open') { $Matches[1] }
  $null = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'b.ts:9'
  $null = pwsh @np $O board dispute -Id $did -Agent X7 -Claim 'b.ts is dead' -Evidence 'git grep: no caller'
  $esc = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'router.ts:12' | Out-String
  $ib = pwsh @np $O board inbox -Agent R7 | Out-String
  Expect 'dispute: board msg to the other agent; split after 2 rounds -> decision' ($did -and $ib -match "DISPUTE $did" -and $esc -match 'escalated: DECISION d-' -and (pwsh @np $O decide list -Pending | Out-String) -match "Dispute $did")
  $dp2 = pwsh @np $O board dispute -Agent X7 -With R7 -Item A2 -Claim 'cache is safe' -Evidence 'c.ts:4' -Propose 'keep' | Out-String
  $did2 = if ($dp2 -match 'DISPUTE (p-\S+) open') { $Matches[1] }
  $df2 = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath disputes) "$did2.json" }
  (Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3); $ex = & { . $O; Get-KitSuperviseFlagsDisputes -AutoFix } | Out-String
  (Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3); $ex2 = & { . $O; Invoke-DisputeExpiry } | Out-String
  Expect 'dispute: silent 2 h escalates once through the supervise hook' (-not $ex2.Trim() -and $ex -match "dispute $did2 .*escalated, DECISION d-" -and (Get-Content $df2 -Raw | ConvertFrom-Json).status -eq 'escalated')
  Expect 'disputes: lists both' (@((pwsh @np $O board disputes) | Where-Object { $_ -match '^ESCALATED' }).Count -eq 2)
} finally { Remove-Item (Split-Path $k) -Recurse -Force -ErrorAction SilentlyContinue }
exit [int]($script:fails -gt 0)
