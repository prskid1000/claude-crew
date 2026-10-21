#Requires -Version 7
<#
tests.ps1 (extra supervise-resources): the cache flush (once per 30 min, a failing command = one WATCH), repeated build failures,
gone sessions' QA seats freed in one line, board show seats and leases.
Usage: kittool.py extra test supervise-resources (tests/kit-tests.ps1 -Area extras runs every installed extra).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit)   # kittool.py extra test passes the kit; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$k = New-TestKit sres; $ad = New-Item -ItemType Directory -Force (Join-Path $k 'skills/orchestrate/adapters')
Copy-Item (Join-Path $PSScriptRoot 'files/skills/orchestrate/adapters/supervise_resources.ps1') $ad
$O = Join-Path $k 'skills/orchestrate/orch.ps1'
# gate.cacheFlush: a starved gate + a big file cache -> one flush per 30 min; a failing command = one WATCH
$cft = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
function Get-KitSetting($Key, $Default) { if ($Key -eq 'gate.cacheFlush') { 'flush-now' } else { $Default } }
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 20GB } }
$global:runs = 0; function Invoke-KitExe($Exe, $A, $TimeoutSec) { $global:runs++; [pscustomobject]@{ code = 0; out = ''; err = ''; timedOut = $false } }
function Get-SysMem { [pscustomobject]@{ TotalGB = 64; AvailGB = 9 } }
$m = [pscustomobject]@{ TotalGB = 64; AvailGB = 3 }; $n = Get-Date
$a = Invoke-KitCacheFlush 12 $m $n; $b = Invoke-KitCacheFlush 12 $m $n
"once:$($a.what -eq 'auto-fixed: file cache flush: available 3 -> 9 GB' -and -not $b -and $global:runs -eq 1)"
Remove-Item (Join-Path (Get-KitPath cache) 'cache-flush.stamp')
"short:$(-not (Invoke-KitCacheFlush 5 $m $n) -and $global:runs -eq 1)"
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 4GB } }
"small:$(-not (Invoke-KitCacheFlush 12 $m $n) -and $global:runs -eq 1)"
function Get-CimInstance { [pscustomobject]@{ SystemCacheResidentBytes = 20GB } }
function Invoke-KitExe($Exe, $A, $TimeoutSec) { [pscustomobject]@{ code = 1; out = ''; err = 'Access is denied.'; timedOut = $false } }
$fl = Invoke-KitCacheFlush 12 $m $n
"fail:$($fl.level -eq 'WATCH' -and $fl.what -match 'exit 1: Access is denied')"
Remove-Item (Join-Path (Get-KitPath cache) 'cache-flush.stamp'); function Invoke-KitExe($Exe, $A, $TimeoutSec) { [pscustomobject]@{ code = 0; out = ''; err = ''; timedOut = $false } }
$global:polls = 0; function Get-SysMem { $global:polls++; [pscustomobject]@{ TotalGB = 64; AvailGB = 3 } }   # no gain: polls only within its budget
$nb = Invoke-KitCacheFlush 12 $m $n 2
"budget:$($global:polls -eq 1 -and $nb.what -match 'available 3 -> 3 GB')"
'@
Expect-Each (Invoke-PsTest 'cache-flush' $cft @($O)) 'cache flush: #' @('once', 'short', 'small', 'fail', 'budget')
$bf = & { . $O; $n = Get-Date; $f = { param($h, $ok) @{ ok = $ok; at = $n.AddHours(-$h).ToString('o') } }
  @(Get-KitBuildFailures @{ old = @((& $f 150 $false), (& $f 149 $false), (& $f 148 $false)); new = @((& $f 3 $false), (& $f 2 $false), (& $f 1 $false)); mixed = @((& $f 3 $false), (& $f 2 $true), (& $f 1 $false)) } $n) -join ',' }
Expect 'build failures: 3 failed in a row flag only when the last is < 24 h old' ($bf -eq 'new')
# a gone session's QA seat + claims freed in ONE line; board show lists seats and env leases
$dp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'exit' -PassThru -WindowStyle Hidden; $dp.WaitForExit()
$qs = TkPath $k qa-seats -Create; foreach ($x in 'seats/s1', 'claims/r1__A1', 'claims/r1__A2') { Set-JsonFile (Join-Path $qs "$x.json") @{ agent = 'test:Q9'; holderPid = $dp.Id } }
$null = Px $O supervise -AutoFix -Brief -Takeover -Session me 2>&1
$sr = Get-Content (TkPath $k supervise-report) -Raw
Expect 'supervise -AutoFix: a gone session''s QA seat + claims freed in ONE line' (@([regex]::Matches($sr, 'QA seat/claim')).Count -eq 1 -and $sr -match "freed 3 QA seat/claim file\(s\) of gone session process $($dp.Id)" -and -not @(Get-ChildItem $qs -Recurse -Filter *.json).Count -and $sr -match 'gate: \d+ running')
$sd = Join-Path $qs 'seats'; New-Item -ItemType Directory -Force $sd | Out-Null
'{"agent":"test:Q1","kind":"web","need":2,"since":"2026-10-16T10:00:00"}' | Set-Content "$sd/q1.json"
'{"leases":{"devy-A1":{"services":["api"],"repos":[],"until":"2026-10-16T12:00:00"}}}' | Set-Content (Join-Path (TkPath $k localenv -Create) 'shop.json')
$bs = Px $O board show | Out-String; $rc = Px $O recover | Out-String
Expect 'board show lists QA seats and env leases; recover lists the lease with no live holder' ($bs -match 'seat: test:Q1 web 2 GB' -and $bs -match 'lease: shop devy-A1 on api' -and $rc -match '== LEASE shop devy-A1 \[api\]: no live holder')
Remove-TestKit $k
Complete-Tests
