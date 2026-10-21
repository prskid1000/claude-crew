#Requires -Version 7
<#
tests.ps1 (extra deploys): deploy plan / request / record batching, trigger owner vs ask, UNKNOWN on a failed check.
Usage: pwsh -NoProfile -File extras/deploys/tests.ps1 (kittool.py extra test deploys: next to the kit's tests/harness.ps1; New-TestKit
gets this extra's files).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit deploys; $O = Join-Path $k 'skills/orchestrate/orch.ps1'; $tf = Join-Path $k '.state/tracking.json'
$cfgF = Join-Path $k 'skills/dev-kit/kit.local.json'; $dep = { Px $O deploy @args }
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }, @{ target = 'prod'; branch = 'production'; job = 'deploy' }, @{ target = 'live'; production = $true }, @{ target = 'preprod'; production = $false }) }); deploy = @{ trigger = 'ask'; minIntervalHours = @{ default = 4 } } } $cfgF
$null = New-Item -ItemType Directory -Force (Split-Path $tf); & $J @{ tasks = @{ t1 = @{ task = 't1'; mrs = @('api!1'); done = $true; doneAt = (Get-Date).ToString('s') }; t2 = @{ task = 't2'; mrs = @('api!2'); done = $false } }; automerge = @{} } $tf
$fx = Join-Path (Kd) 'deploy-fixture.json'
& $J @{ mrs = @{ 'api!1' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) }; 'api!2' = @{ rows = @(@{ target = 'stage'; state = 'DEPLOYED'; detail = 'live' }) }; 'api!3' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) } }; lastCi = @{ stage = (Get-Date).AddHours(-6).ToString('s') } } $fx
$plan = { @(& $dep plan -Offline $fx -Json | ConvertFrom-Json) }; $p = & $plan
Expect 'deploy plan: production by name / flag / false; one ASK batch for stage' (($p.target -join ',') -eq 'stage,preprod' -and $p[0].target -eq 'stage' -and $p[0].status -eq 'ASK' -and (@($p[0].mrs.mr) -join ',') -eq 'api!1')
$null = & $dep request -Mrs 'https://git.example.com/g/api/-/merge_requests/3' -Run w2 -Offline $fx; $p = & $plan
Expect 'deploy request: another session''s MR joins the same batch' ((@($p[0].mrs.mr | Sort-Object) -join ',') -eq 'api!1,api!3')
$null = & $dep record -Env stage -Mrs 'api!1','api!3' -By tester; $p = & $plan
Expect 'deploy record: WAIT in the window, the request cleared' ($p[0].status -eq 'WAIT' -and -not @($p[0].pending).Count)
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }, @{ name = 'py'; deploys = @(@{ target = 'pystage' }) }) } $cfgF
$fx2 = Join-Path (Kd) 'deploy-fixture2.json'; & $J @{ mrs = @{ 'api!5' = @{ rows = @(@{ target = 'stage'; state = 'UNKNOWN'; detail = 'cannot reach the host' }) } } } $fx2
$dr = & $dep request -Mrs 'api!5' -Run w4 -Offline $fx2 | Out-String
Expect 'deploy request: only the MR repo''s deploys; UNKNOWN names the deploy and why' ($dr -match 'DEPLOY stage: UNKNOWN: the deploy check failed: api!5: cannot reach the host' -and $dr -notmatch 'pystage')
$null = & $dep record -Env stage -Mrs 'api!5' -By tester
& $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }) } $cfgF
$null = & $dep request -Mrs 'api!3' -Run w3 -Offline $fx; $p = & $plan
Expect 'deploy plan: trigger owner -> READY in the window, never ASK / WAIT' ($p[0].status -eq 'READY' -and $p[0].trigger -eq 'owner')
$sup = (Get-Content (Join-Path $k 'skills/orchestrate/adapters/deploys.ps1') -Raw) -match "deploy\.trigger' 'owner'\)\)\.ToLower\(\) -eq 'ask'"
Expect 'supervise: DEPLOY ASK only under trigger ask' $sup
# a failed qa.ps1 deployed: UNKNOWN, never NOTHING
$ut = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$TimeoutSec = 60) { [pscustomobject]@{ code = 2; out = 'qa.ps1: usage error'; err = ''; timedOut = $false } }
$p = @(Invoke-Deploy plan -Json | ConvertFrom-Json)
"unknown:$(@($p | Where-Object status -eq 'UNKNOWN').Count -ge 1 -and -not @($p | Where-Object status -eq 'NOTHING').Count)"
'@
$res = Invoke-PsTest 'deploy-unknown' $ut @($O)
Expect-Each $res 'deploy: #' @('unknown')
Remove-TestKit $k
Complete-Tests
