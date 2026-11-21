#Requires -Version 7
<#
tests/devtools.tests.ps1: devtools.py adapters on one test kit: module_audit.py findings schema / validate / summary; the gdocs report
adapter (devtools selftest on recorded gws replies) and pokey.ps1 finalize -Report gdocs with a fake gws CLI, the QA report HTML.
Usage: pwsh -NoProfile -File <kit>/tests/devtools.tests.ps1 [-Kit <kit>] (or tests/kit-tests.ps1 -Area devtools).
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (Split-Path $PSScriptRoot))
. (Join-Path $Kit 'tests/harness.ps1')
$k = New-TestKit devtools; $Q = Join-Path $k 'skills/pokey/pokey.ps1'
# ---- module-audit
$DT = Join-Path $k 'skills/crafty/devtools.py'
New-Item -ItemType Directory -Force (Join-Path $k 'skills/crafty/adapters') | Out-Null
Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/module_audit.py') (Join-Path $k 'skills/crafty/adapters')
$out = & $py -X utf8 $DT findings schema 2>&1 | Out-String
Expect 'findings schema: the 23 keys' ($LASTEXITCODE -eq 0 -and $out -match 'exactly these 23 string keys')
$good = [ordered]@{ id = 'NOTIF-BUG-001'; module = 'Notifications'; layer = 'Node API'; type = 'Bug'; in_scope = 'Yes'; subtype = 'Data Integrity'; title = 'Digest ignores opt-out'
  area = 'Email'; severity = 'High'; current = 'Opted-out users get it.'; expected = 'They never do.'; business_impact = 'Unwanted mail.'; root_cause = 'Flag unread.'
  why_today = '(inferred) new flag'; why_not_prod = '(inferred) few opt-outs'; customer_impact = 'Mail.'; db_migration = 'No'; suggested_fix = 'Filter.'
  code_location = 'DigestJob.ts:12'; product_decision = 'No'; effort = 'Low'; existing_notes = ''; source = 'module review' }
$bad = [ordered]@{} + $good; $bad.id = 'bad id'; $bad.severity = 'Critical'; $bad.current = '(unverified) maybe'; $bad.root_cause = ''
$f = Join-Path (Kd) 'notif.json'; ConvertTo-Json -InputObject @($good, $bad) -Depth 3 | Set-Content $f
$out = & $py -X utf8 $DT findings validate $f 2>&1 | Out-String
Expect 'findings validate: id, unverified Critical and a missing in-scope field are problems' ($LASTEXITCODE -eq 1 -and $out -match 'bad id: id should look like' -and
  $out -match 'unverified finding cannot be Critical' -and $out -match 'needs root_cause' -and $out -notmatch 'NOTIF-BUG-001:')
$out = & $py -X utf8 $DT findings summary $f --sources 'code' 2>&1 | Out-String
$md = Join-Path (Kd) 'notif-summary.md'
Expect 'findings summary: <module>-summary.md with the Critical / High table' ($LASTEXITCODE -eq 0 -and (Test-Path $md) -and (Get-Content $md -Raw) -match '## Critical / High')
# ---- report-gdocs
New-Item -ItemType Directory -Force (Join-Path $k 'skills/crafty/adapters') | Out-Null
Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/report_gdocs.py') (Join-Path $k 'skills/crafty/adapters')
New-Item -ItemType Directory -Force (Join-Path $k 'skills/pokey/adapters') | Out-Null
Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/adapters/report_html.ps1') (Join-Path $k 'skills/pokey/adapters') -Force
$out = & $py -X utf8 (Join-Path $k 'skills/crafty/devtools.py') selftest 2>&1 | Out-String
Expect 'devtools selftest with the gdocs adapter: share modes, unshared refused, an earlier link updated in place (a timeout retried once), env runs filling the human doc rows (a later NOT TESTED keeps a PASS), Drive evidence' ($LASTEXITCODE -eq 0 -and @([regex]::Matches($out, '(?m)^PASS gdocs')).Count -eq 6)
$env:KIT_TRACKER_TYPE = 'none'
$d = Join-Path (Kd) 'runs/GD'
& $J @{ title = 'Run GD'; target = 't'; tracker = @{ list = 'L1'; parent = 'P1' }; items = @(foreach ($c in 'G1', 'G2') { @{ code = $c; title = $c; subtasks = @(@{ id = 'TG'; name = 'Task TG' }) } }) } "$d/run.json"
foreach ($c in 'G1', 'G2') { & $J @{ code = $c; checks = @(@{ id = "C$c"; subtask_id = 'TG'; screen = 's'; result = 'PASS'; what_was_done = 'w'; observed = 'o `a.b=1`'; evidence = @() }); findings = @(); setup_changes = @(); data_created = @() } "$d/$c/results.json" }
$gb = Join-Path (Kd) 'fakebin'; New-Item -ItemType Directory -Force $gb | Out-Null; $glog = Join-Path $gb 'gws.log'
# an npm shim like the real gws (devtools runs its node script directly: cmd.exe never sees the JSON args)
New-Item -ItemType Directory -Force "$gb/node_modules/g" | Out-Null
"const fs = require('fs'), a = process.argv.slice(2).join(' '); fs.appendFileSync(require('path').join(__dirname, '../../gws.log'), a + '\n')`nif (a.includes('permissions')) { console.log('403 forbidden'); process.exit(1) }`nconsole.log(JSON.stringify({ id: 'D1', webViewLink: 'https://x.example/D1' }))" | Set-Content "$gb/node_modules/g/run.js"
"@ECHO off`r`nSET dp0=%~dp0`r`n""node""  ""%dp0%\node_modules\g\run.js"" %*" | Set-Content (Join-Path $gb 'gws.cmd') -Encoding ascii
if (-not $IsWindows) { "#!/bin/sh`nexec node `"$gb/node_modules/g/run.js`" `"`$@`"" | Set-Content (Join-Path $gb 'gws'); chmod +x (Join-Path $gb 'gws') }
$oldPath = $env:PATH; $env:PATH = "$gb;$env:PATH"
$g1 = pwsh @np $Q finalize -RunDir $d -Code G1 -Report gdocs 2>&1 | Out-String
$docs1 = @(Get-Content $glog | Where-Object { $_ -match 'google-apps.document' }).Count
$null = pwsh @np $Q finalize -RunDir $d -Code G1 -Report gdocs 2>&1
$docs2 = @(Get-Content $glog | Where-Object { $_ -match 'google-apps.document' }).Count
$env:PATH = $oldPath
$rec = (Get-Content "$d/G1/finalize.json" -Raw | ConvertFrom-Json).subtasks[0]
Expect 'finalize gdocs: re-run reuses the doc; failed share warns' ($docs1 -eq 1 -and $docs2 -eq 1 -and $g1 -match 'uploaded but not shared \(anyone\)' -and $rec.waitingFor -contains 'G2')
$qh = Get-ChildItem "$d/G1" -Filter *.html -Recurse | Get-Content -Raw | Out-String
Expect 'QA report HTML: header cells are <th> (Docs repeats them), backtick spans monospace' ($qh -match "<th style='[^']*'><b>Check</b></th>" -and $qh -match "o <span style=`"font-family:'Roboto Mono'[^`"]*`">a\.b=1</span>")
$kh = "$(Invoke-PsTest 'known-html' ". `$args[0]; Build-QaReport -Title T -Code K1 -Item ([pscustomobject]@{ title = 'x'; subtasks = @() }) -Res ([pscustomobject]@{ checks = @([pscustomobject]@{ id = 'X1'; screen = 's'; result = 'FAIL'; knownBug = 'KB9'; what_was_done = 'w'; observed = 'o'; evidence = @() }) }) -Map @{ files = @{}; folderLink = 'f'; label = 'l' } -Run ([pscustomobject]@{}) -Tester t -Date d" @($Q))"
Expect 'QA report HTML: a knownBug FAIL reads FAIL (known: <id>) with the task link, and its detail names the tracking task' ($kh -match '<b>FAIL</b> \(known: <a href=''[^'']*''>KB9</a>\)' -and $kh -match '<b>Known defect</b></td><td[^>]*>tracked in <a href=''[^'']*''>KB9</a>')
# retro 2205: a mistyped cases verb names the closest one; a verb without <task> says so (exit 2 both)
$cv = @(foreach ($cva in @('reslt', 'T1'), @('add')) { $cvo = & $py -X utf8 $DT cases @cva 2>&1 | Out-String; "$LASTEXITCODE|$(($cvo -split "`r?`n" | Where-Object { $_.Trim() })[-1])" })
Expect "devtools cases: closest verb / missing task named ($($cv -join ' ; '))" ($cv[0] -eq '2|did you mean: cases result (see its example above)' -and $cv[1] -eq '2|cases add needs <task> first (example above)')
# retro 2026-11-21: cases --help = usage, exit 0; cases <task> <verb> = the swapped form, run as cases <verb> <task>
$chOut = & $py -X utf8 $DT cases --help 2>&1 | Out-String; $chCode = $LASTEXITCODE
$csOut = & $py -X utf8 $DT cases T1 render nosuchkind 2>&1 | Out-String
Expect "devtools cases: --help exits 0 with the examples ($chCode); <task> <verb> runs the verb" ($chCode -eq 0 -and $chOut -match 'cases render T1 ai' -and $csOut -match "kind 'nosuchkind'|has no cases spec" -and $csOut -notmatch 'did you mean')
Remove-TestKit $k
Complete-Tests
