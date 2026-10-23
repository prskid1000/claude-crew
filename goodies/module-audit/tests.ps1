#Requires -Version 7
<#
tests.ps1 (goody module-audit): devtools.py findings schema / validate / summary on a good and a broken finding; without the
plugin `findings` prints the goody line (exit 3).
Usage: pwsh -NoProfile -File goodies/module-audit/tests.ps1 -Kit <kit> (the plugin comes from files/ beside this file).
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
. (Join-Path $Kit 'tests/harness.ps1')
$k = New-TestKit module-audit
$DT = Join-Path $k 'skills/crafty/devtools.py'
$out = & $py -X utf8 $DT findings schema 2>&1 | Out-String
Expect 'findings without the goody: exit 3 + the goody line' ($LASTEXITCODE -eq 3 -and $out -match 'goody add module-audit')
New-Item -ItemType Directory -Force (Join-Path $k 'skills/crafty/adapters') | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'files/skills/crafty/adapters/module_audit.py') (Join-Path $k 'skills/crafty/adapters')
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
Remove-TestKit $k
Complete-Tests
