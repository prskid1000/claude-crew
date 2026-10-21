#Requires -Version 7
<#
tests.ps1 (extra report-gdocs): the gdocs adapter on recorded gws replies (devtools.py selftest) and qa.ps1 finalize -Report gdocs
with a fake gws CLI (a re-run reuses the doc, a failed share warns).
Usage: pwsh -NoProfile -File extras/report-gdocs/tests.ps1 -Kit <kit> (the plugin comes from files/ beside this file).
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
. (Join-Path $Kit 'tests/harness.ps1')
$k = New-TestKit report-gdocs; $Q = Join-Path $k 'skills/qa-kit/qa.ps1'
New-Item -ItemType Directory -Force (Join-Path $k 'skills/dev-kit/adapters') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'files/skills/dev-kit/adapters/report_gdocs.py') (Join-Path $k 'skills/dev-kit/adapters')
$out = & $py -X utf8 (Join-Path $k 'skills/dev-kit/devtools.py') selftest 2>&1 | Out-String
Expect 'devtools selftest with the gdocs adapter: share modes, unshared refused, Drive evidence' ($LASTEXITCODE -eq 0 -and @([regex]::Matches($out, '(?m)^PASS gdocs')).Count -eq 3)
$env:KIT_TRACKER_TYPE = 'none'
$d = Join-Path (Kd) 'runs/GD'
& $J @{ title = 'Run GD'; target = 't'; tracker = @{ list = 'L1'; parent = 'P1' }; items = @(foreach ($c in 'G1', 'G2') { @{ code = $c; title = $c; subtasks = @(@{ id = 'TG'; name = 'Task TG' }) } }) } "$d/run.json"
foreach ($c in 'G1', 'G2') { & $J @{ code = $c; checks = @(@{ id = "C$c"; subtask_id = 'TG'; screen = 's'; result = 'PASS'; what_was_done = 'w'; observed = 'o'; evidence = @() }); findings = @(); setup_changes = @(); data_created = @() } "$d/$c/results.json" }
$gb = Join-Path (Kd) 'fakebin'; New-Item -ItemType Directory -Force $gb | Out-Null; $glog = Join-Path $gb 'gws.log'
"@echo off`r`necho %* >> `"$glog`"`r`necho %* | findstr /c:`"permissions`" >nul && (echo 403 forbidden & exit /b 1)`r`necho {`"id`":`"D1`",`"webViewLink`":`"https://x.example/D1`"}" | Set-Content (Join-Path $gb 'gws.cmd') -Encoding ascii
$oldPath = $env:PATH; $env:PATH = "$gb;$env:PATH"
$g1 = pwsh @np $Q finalize -RunDir $d -Code G1 -Report gdocs 2>&1 | Out-String
$docs1 = @(Get-Content $glog | Where-Object { $_ -match 'google-apps.document' }).Count
$null = pwsh @np $Q finalize -RunDir $d -Code G1 -Report gdocs 2>&1
$docs2 = @(Get-Content $glog | Where-Object { $_ -match 'google-apps.document' }).Count
$env:PATH = $oldPath
$rec = (Get-Content "$d/G1/finalize.json" -Raw | ConvertFrom-Json).subtasks[0]
Expect 'finalize gdocs: re-run reuses the doc; failed share warns' ($docs1 -eq 1 -and $docs2 -eq 1 -and $g1 -match 'uploaded but not shared \(anyone\)' -and $rec.waitingFor -contains 'G2')
Remove-TestKit $k
Complete-Tests
