#Requires -Version 7
<#
tests/devtools.tests.ps1: devtools.py adapters on one test kit: module_audit.py findings schema / validate / summary; the gdocs report
adapter (devtools selftest on recorded gws replies) and pokey.ps1 finalize -Report gdocs with a fake gws CLI, the QA report HTML;
tracker bodies (a missing path refused, desc-backups, update -ReplaceItems).
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
Copy-Item @(foreach ($rn in 'gdocs', 'confluence', 'notion', 'pdf') { Join-Path (Split-Path $PSScriptRoot) "skills/crafty/adapters/report_$rn.py" }) (Join-Path $k 'skills/crafty/adapters')
New-Item -ItemType Directory -Force (Join-Path $k 'skills/pokey/adapters') | Out-Null
Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/adapters/report-html.ps1') (Join-Path $k 'skills/pokey/adapters') -Force
$out = & $py -X utf8 (Join-Path $k 'skills/crafty/devtools.py') selftest 2>&1 | Out-String
Expect 'devtools selftest with the gdocs adapter: share modes, unshared refused, an earlier link updated in place (a timeout retried once), env runs filling the human doc rows (a later NOT TESTED keeps a PASS), Drive evidence' ($LASTEXITCODE -eq 0 -and @([regex]::Matches($out, '(?m)^PASS gdocs')).Count -eq 7)
Expect 'devtools selftest, confluence and command evidence (recorded replies, no account): page + multipart attachments, reused page; command store via reports.evidenceCommand' (
  $out -match '(?m)^PASS confluence evidence: ' -and $out -match '(?m)^PASS report command: evidence ' -and $out -notmatch '(?m)^FAIL')
Expect 'devtools selftest, native evidence and tags (parity): notion File Upload API (recorded replies, no account), kept evidence for markdown / html / pdf, command {tags}; native tags: markdown front matter, html meta, pdf /Keywords, notion database Tags; notion 429 retried once' (
  $out -match '(?m)^PASS notion evidence: ' -and $out -match '(?m)^PASS kept evidence\b' -and $out -match '(?m)^PASS pdf evidence: ' -and $out -match '(?m)^PASS command: \{title\} and \{tags\}' -and
  @([regex]::Matches($out, '(?m)^PASS (pdf|notion) tags: ')).Count -eq 3 -and $out -match '(?m)^PASS notion: HTTP 429 retried once')
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
# ---- tracker bodies (kept off tracker.tests.ps1: its cap)
$dpCr = Join-Path $k 'skills/crafty/crafty.ps1'; $env:KIT_TRACKER_TYPE = 'none'; $bk = Kd; $fbSec = "**Problem:** p`n**Goal:** g`n**Acceptance:** a`n**Links:** https://x.example/2"
$fbOwn = (pwsh @np $dpCr tracker create -List L1 -Key qa-dp-own -Name 'Owner shaped' -NewTask x -Description $fbSec | ConvertFrom-Json).id
$null = pwsh @np $dpCr tracker describe $fbOwn "**Testing doc (AI):** [open](https://x.example/a)`n`n$fbSec"
# a body that looks like a path but is no file: refused, nothing written (2026-11-23: a path string replaced a parent's description); the replaced text kept
$dpOld = (pwsh @np $dpCr tracker view $fbOwn | ConvertFrom-Json).description
$dpMiss = pwsh @np $dpCr tracker describe $fbOwn "$bk/gone/brief.md" 2>&1 | Out-String; $dpCodes = "$LASTEXITCODE"
$null = pwsh @np $dpCr tracker describe $fbOwn 'brief-v2.md' 2>&1; $dpCodes += " $LASTEXITCODE"; $null = pwsh @np $dpCr tracker describe $fbOwn -Text 'work\x\desc.txt' 2>&1; $dpCodes += " $LASTEXITCODE"
$null = pwsh @np $dpCr tracker comment $fbOwn 'work/x/comment.md' -Kind comment-status 2>&1; $dpCodes += " $LASTEXITCODE"
foreach ($dpWord in 'n/a', 'yes/no') { $null = pwsh @np $dpCr tracker comment $fbOwn $dpWord -Kind comment-status -ProseOk t 2>&1; $dpCodes += " $LASTEXITCODE" }   # one-word text, no path
$dpSame = (pwsh @np $dpCr tracker view $fbOwn | ConvertFrom-Json).description -eq $dpOld
$dpOk = pwsh @np $dpCr tracker describe $fbOwn "**Testing doc (human):** [open](https://x.example/h2)`n`n$fbSec" 2>&1 | Out-String
$dpBk = @(Get-ChildItem (Join-Path (TkPath $k desc-backups) $fbOwn) -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object { if ($_.BaseName -match '-(\d+)$') { [int]$Matches[1] } else { 1 } })   # desc, desc-2, ...
Expect "tracker describe / comment: a missing path-like body (absolute, bare .md, -Text, comment) exits 1 and writes nothing, n/a and yes/no are text; a write keeps the old text in desc-backups/<id>/desc[-<n>].md ($dpCodes; $($dpBk.Count) backups)" ($dpCodes -eq '1 1 1 1 0 0' -and $dpMiss -match 'no such file' -and $dpSame -and $dpOk -match 'old description kept: .*desc-backups' -and $dpBk.Count -ge 2 -and -not @($dpBk | Where-Object Name -notmatch '^desc(-\d+)?\.md$').Count -and [IO.File]::ReadAllText($dpBk[-1].FullName) -eq $dpOld)
# tracker update -ReplaceItems: the spec's items are the whole list; a done one stays unless -Force; dropped codes stay out of rollups
Set-JsonFile "$bk/ri1.json" @{ kind = 'Feature'; title = 'Replace items'; list = 'L1'; newTask = 'x'; problem = 'p.'; goal = 'g.'; acceptance = @('a'); links = @('https://x.example/r'); items = @(@{ code = 'OLD-1'; desc = 'old one' }, @{ code = 'OLD-2'; desc = 'old done' }, @{ code = 'KEEP'; desc = 'kept' }) }
Set-JsonFile "$bk/ri2.json" @{ items = @(@{ code = 'KEEP'; desc = 'kept' }, @{ code = 'NEW-1'; desc = 'new one' }) }
$riId = (pwsh @np $dpCr tracker create -Spec "$bk/ri1.json" | ConvertFrom-Json).id; $riSf = TkPath $k tasks | Join-Path -ChildPath "$riId.json"
$riS = Get-Content -Raw $riSf | ConvertFrom-Json -AsHashtable; $riS.itemsMrs = @{ 'web!5' = @('OLD-2') }; Set-JsonFile $riSf $riS 20   # OLD-2 done: named by a merged MR
$riU = pwsh @np $dpCr tracker update $riId -Spec "$bk/ri2.json" -ReplaceItems | ConvertFrom-Json; $riD = (pwsh @np $dpCr tracker view $riId | ConvertFrom-Json).description
$riF = pwsh @np $dpCr tracker update $riId -Spec "$bk/ri2.json" -ReplaceItems -Force | ConvertFrom-Json; $riD2 = (pwsh @np $dpCr tracker view $riId | ConvertFrom-Json).description
$riX = Get-Content -Raw $riSf | ConvertFrom-Json
Expect "tracker update -ReplaceItems: an item not in the spec leaves spec and checklist, a done one only with -Force, counts reported, dropped kept in itemsDropped ($("$($riU.dropped)") $($riU.checklist) | $("$($riF.dropped)") $($riF.checklist))" (
  "$($riU.dropped)" -eq 'OLD-1' -and $riU.checklist -match '1 removed' -and $riD -notmatch 'OLD-1' -and $riD -match '- \[x\] OLD-2' -and $riD -match '- \[ \] NEW-1' -and
  "$($riF.dropped)" -eq 'OLD-2' -and $riD2 -notmatch 'OLD-' -and $riD2 -match 'KEEP' -and (@($riX.itemsDropped) -join ',') -eq 'OLD-1,OLD-2' -and (@($riX.spec.items.code) -join ',') -eq 'KEEP,NEW-1')
Remove-Item Env:KIT_TRACKER_TYPE
# process.docs = the AI doc only: `doc ... cases` for the human doc is skipped (exit 0, nothing rendered); the AI doc still renders
$pdF = Join-Path $k 'skills/crafty/kit.local.json'; $pdOld = if (Test-Path $pdF) { Get-Content -Raw $pdF } else { $null }
$pdC = if ($pdOld) { $pdOld | ConvertFrom-Json -AsHashtable } else { @{} }; $pdC.process = @{ docs = @(@{ key = 'testing-ai'; label = 'AI doc' }) }; Set-JsonFile $pdF $pdC
$pdH = python -X utf8 $DT doc 'T9 human' cases --key PD9:testing-doc 2>&1 | Out-String; $pdHc = $LASTEXITCODE
$pdA = python -X utf8 $DT doc 'T9 ai' cases --key PD9:testing-ai 2>&1 | Out-String
if ($null -ne $pdOld) { [IO.File]::WriteAllText($pdF, $pdOld) } else { Remove-Item -LiteralPath $pdF }
Expect "doc cases: a doc process.docs lacks is skipped, a listed one renders ($pdHc; $($pdA.Trim()))" ($pdHc -eq 0 -and $pdH -match 'testing-doc is not in process\.docs' -and $pdA -match 'no cases spec')
# retro 1549: a retro.json with a raw Windows path (lone backslashes) renders; the path is kept
$rjf = Join-Path (Kd) 'retro-bs.json'; [IO.File]::WriteAllText($rjf, '{"date":"2026-11-23","applied":[{"change":"c","file":"D:\work\tmp\x\new.ps1","count":1}],"rejected":[]}')
$rjo = (& $py -X utf8 $DT render retro $rjf 2>&1 | Out-String)
Expect "render retro: lone backslashes in the spec (a Windows path) are kept, not a JSON error ($($rjo.Trim() -replace '\s+', ' '))" ($rjo -match [regex]::Escape('D:\work\tmp\x\new.ps1') -and $rjo -notmatch 'Traceback|JSONDecodeError')
# ---- A3: every listed section of a doc kind always present; empty -> `n/a — <why>` (renders), a gap refused (doc publish, prose)
$a3 = Join-Path (Kd) 'a3'; New-Item -ItemType Directory -Force $a3 | Out-Null; $KB = Join-Path $k 'skills/bossy/kitbag.py'; Copy-Item (Join-Path $src 'skills/crafty/templates.md') (Join-Path $k 'skills/crafty')
$a3Rb = "# Runbook: restore`n`n## Purpose`nRestore the DB.`n`n## Preconditions`nnone`n`n## Steps`n1. ``pwsh restore.ps1```n`n## Verify`nRow count matches."
Set-Content "$a3/rb.md" $a3Rb; $a3Bad = & $py -X utf8 $DT doc 'Restore' "$a3/rb.md" --key RB1:runbook 2>&1 | Out-String; $a3BadC = $LASTEXITCODE
Set-Content "$a3/rb.md" ($a3Rb -replace 'none', 'n/a — no lock needed' -replace '$', "`n`n## Rollback`nn/a — read-only restore check"); $null = & $py -X utf8 $DT doc 'Restore' "$a3/rb.md" --key RB1:runbook 2>&1; $a3OkC = $LASTEXITCODE
Set-JsonFile "$a3/retro.json" @{ date = '2026-11-23' }; & $py -X utf8 $DT render retro "$a3/retro.json" "$a3/retro.md" 2>$null | Out-Null
$a3Qa = pwsh -NoProfile -Command ". '$Q' 6>`$null; (Build-QaReportMd -Title t -Code T2 -Item @{} -Res ([pscustomobject]@{ checks = @([pscustomobject]@{ id = 'C1'; result = 'PASS'; observed = 'ok' }) }) -Map @{ files = @{} } -Run @{} -Tester x -Date d) -join ""``n""" 2>$null | Out-String
Set-Content "$a3/qa.md" $a3Qa; $a3Pr = foreach ($a3k in @(@('retro', 'retro.md'), @('qa-report', 'qa.md'))) { & $py -X utf8 $KB prose --kind $a3k[0] "$a3/$($a3k[1])" 2>&1 | Where-Object { $_ -match 'section' } }
Expect "A3: a runbook missing ## Rollback and a bare 'none' refused ($a3BadC), complete published ($a3OkC); retro + QA report render every section ($($a3Pr -join ' | '))" ($a3BadC -ne 0 -and $a3Bad -match 'missing sections: ## Rollback' -and
  $a3Bad -match "section ## Preconditions is 'none'" -and $a3OkC -eq 0 -and -not @($a3Pr).Count -and $a3Qa -match '## Failures in detail\s+n/a — no check failed' -and (Get-Content "$a3/retro.md" -Raw) -match '## Rejected\s+n/a — nothing rejected')
# mr prose refusal names each section's words and bullets next to the limits (retro 1709: 8 refusals guessed which field)
$pgBody = "## Summary`n$((@('word') * 60) -join ' ')`n## Changes`n- a`n- b`n- c`n- d`n## How tested`nunit`n## Risks`nnone`n## Links`nx"
$pgOut = $pgBody | & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d; d.prose_gate('mr-body', sys.stdin.read())" 2>&1 | Out-String
Expect "mr prose refusal: per-section word / bullet counts with the limits ($(($pgOut -split "`n" | Where-Object { $_ -match 'per section' }) -join ''))" ($pgOut -match 'per section \(mr-body: .*limits .*\): Summary 60w 0b · Changes 4w 4b · How tested 1w 0b' -and $pgOut -match 'refused')
# owner 2026-11-26: bullets over a section's cap are joined into the last one before the mr gate, nothing cut (724 of 2755 mr calls were refused, bullet counts the most frequent finding)
$pfPy = Join-Path (Kd) 'fit.py'
[IO.File]::WriteAllText($pfPy, "import sys; sys.path.insert(0, sys.argv[1]); import devtools as d, kitbag as kb`nb = '## Summary\nhttps://t.example.com/T-1 one\n## Changes\n- a\n- b\n- c.\n- d\n- e\n## How tested\n| Check | Result |\n|---|---|\n| unit | PASS |\n\nNot run: nothing\n## Risks\n- r1\n## Links\n' + '- l\n' * 9`nf = kb.prose_fit('mr-body', b, d.KIT_DIR)`nprint('FIT', '- c; d; e' in f, f.count('\n- '), kb.prose_fit('mr-body', f, d.KIT_DIR) is f, kb.prose_fit('nope', b, d.KIT_DIR) is b)`nprint(d.mr_create('x', 'feat(api): add x (T-1)', b, check=True))`nb2 = '## Changes\n- a\n- b\n- c\n``````\ncode\n``````\n- d\n'; b3 = '## Changes\n- a\n- b\n- c\nNot run: nothing\n- d\n'; print('BLOCK', kb.prose_fit('mr-body', b2, d.KIT_DIR) is b2, kb.prose_fit('mr-body', b3, d.KIT_DIR) is b3)`nimport json, os; L = ' '.join(['w'] * 61); rf = os.path.join(sys.argv[2], 'results.json')`njson.dump({'checks': [{'id': 'C1', 'what_was_done': L, 'evidence': 'a.png'}, {'observed': L}, {'id': 'A.1', 'observed': L}, {'id': 'A1', 'observed': L}]}, open(rf, 'w'))`nn = kb.notes_fit(rf, os.path.join(sys.argv[2], 'ev'), 'P1'); r = json.load(open(rf, encoding='utf-8'))['checks']`nprint('NOTES', len(n), r[0]['evidence'], r[1]['observed'] == L, r[2]['observed'] == L, r[3]['observed'] == L, sorted(os.listdir(os.path.join(sys.argv[2], 'ev'))), kb.notes_fit(rf, os.path.join(sys.argv[2], 'ev'), 'P1')[:1])")
$pfDir = Join-Path (Kd) 'fitnotes'; $null = New-Item -ItemType Directory -Force $pfDir; $pfOut = & $py -X utf8 $pfPy (Split-Path $DT) $pfDir 2>&1 | Out-String
Expect "mr prose fit: 5 Changes bullets -> 3 (c; d; e joined), 9 Links kept, a fitting text and an unknown kind unchanged; mr --check passes it ($(($pfOut -split "`n" | Where-Object { $_ -match 'FIT|fitted|CHECK' }) -join ' | '))" ($pfOut -match 'FIT True 13 True True' -and $pfOut -match 'mr-body fitted: Changes 5 bullets -> 3' -and $pfOut -match 'CHECK OK' -and $pfOut -notmatch 'refused')
Expect "prose fit guards: a bullet after a fence or a text line is not joined; notes_fit: steps fitted, a string evidence kept, rows with no id or the same file name left whole ($(($pfOut -split "`n" | Where-Object { $_ -match '^(BLOCK|NOTES)' }) -join ' | '))" ($pfOut -match 'BLOCK True True' -and
  $pfOut -match "NOTES 1 \['a\.png', 'P1-C1_91_full-steps\.txt'\] True True True \['P1-C1_91_full-steps\.txt'\] \[\]")
$pgLast = @($pgOut -split "`r?`n" | Where-Object { $_.Trim() })[-1]
Expect "mr prose refusal: its last line names the finding and the limits (retro 1124: 7 refusals showed only the count) ($pgLast)" ($pgLast -match 'mr-body refused: .*\(max \d+\).*; limits: mr-body: ')
# kept-doc tags (parity, moved from devtools selftest for its cap): Markdown front matter, HTML meta keywords
$tgPy = @'
import os, sys, tempfile; sys.path.insert(0, sys.argv[1]); import devtools as d
t = tempfile.mkdtemp(); p = os.path.join(t, 'tg.md'); open(p, 'w', encoding='utf-8').write('---\ntitle: X\ntags:\n  - old\n---\n# T\n')
def rd(ty, *a): d.REPORT_TYPE, d.RCFG = ty, {}; return open(d.make_doc('T', p, t, tags=list(a)), encoding='utf-8').read()
m1, m2, m0 = rd('markdown', 'a: b'), rd('markdown', 'b'), rd('markdown')
rd('html', 'x'); h = rd('html', 'w', 'a&b')
md = m1 == '---\ntitle: X\ntags: ["a: b"]\n---\n# T\n' and m2 == m1.replace('a: b', 'b') and m0 == '---\ntitle: X\n---\n# T\n'
print('md:%s html:%s' % (md, h.count('keywords') == 1 and '<meta name="keywords" content="w, a&amp;b"></head>' in h))
'@
Set-Content -LiteralPath ($tgF = Join-Path $k 'tg-tags.py') -Value $tgPy -Encoding utf8   # a file: the python shim cuts a multi-line -c
$tgOut = "$(& $py -X utf8 $tgF (Split-Path $DT) 2>&1)"
Expect "kept-doc tags: Markdown front matter (own keys kept, a block list replaced, a colon one tag, one block after 2 publishes, none: key gone); HTML one escaped meta keywords ($tgOut)" ($tgOut -match 'md:True html:True')
$vd = & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d; print(','.join(d._verdict(x) for x in (['PASS', 'NOT_TESTED_LOCAL'], ['PASS', 'PASS'], ['PASS', ''], ['FAIL', 'NOT_TESTED_LOCAL'])))" 2>&1
Expect "render cases: a goal mixing PASS and NOT_TESTED_LOCAL reads NOT_TESTED_LOCAL, not blank; unrecorded stays blank ($vd)" ("$vd" -eq 'NOT_TESTED_LOCAL,PASS,,FAIL')
# finish: one loop checkpoint under the keyed item covers every item tracked on the same MR (retro 1124: siblings refused)
$lp = & $py -X utf8 -c "import sys, os, json; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d, kitbag as kb; [kb.state_write(kb.task_file(t), {'task': t, 'track': {'mrs': m}}) for t, m in (('tA', ['g/w!1']), ('tB', ['g/w!1']), ('tC', ['g/w!2']))]; a = os.path.join(kb.kit_path('agents'), 'zz-dt'); os.makedirs(a, exist_ok=True); json.dump({'steps': [{'step': 'loop', 'item': 'tA', 'evidence': 'PASS local', 'at': '2026-11-24T10:00:00'}]}, open(os.path.join(a, 'resume-r.json'), 'w')); print(','.join(str(d.local_pass(t)[0]) for t in ('tA', 'tB', 'tC')))" 2>&1
Expect "local_pass: a shared MR's sibling item reads the keyed item's loop checkpoint; an item on another MR does not ($lp)" ("$lp" -eq 'True,True,None')
# retro 2026-11-25: checkpoint times compare as instants (09:40Z beats 15:00+05:30 = 09:30Z); merge --scope dropping a recorded glob; keepboth as a plugin verb
$cf = Join-Path (Kd) 'conflict.txt'; [IO.File]::WriteAllText($cf, "a`n<<<<<<< HEAD`nours`n=======`ntheirs`n>>>>>>> x`n")
$r25 = & $py -X utf8 -c "import sys, os, json; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d, kitbag as kb; a = os.path.join(kb.kit_path('agents'), 'zz-tz'); os.makedirs(a, exist_ok=True); json.dump({'steps': [{'step': 'loop', 'item': 'tZ', 'evidence': 'round 1 FAIL', 'at': '2026-10-30T15:00:00+05:30'}, {'step': 'loop', 'item': 'tZ', 'evidence': 'round 2 PASS', 'at': '2026-10-30T09:40:00Z'}]}, open(os.path.join(a, 'resume-r.json'), 'w')); print(d.local_pass('tZ')[1], d.scope_dropped('a/**', lambda: ['a/**', 'b.json']), d.scope_dropped('a/**, b.json, c/**', lambda: ['a/**', 'b.json']), d.scope_dropped('', lambda: ['a/**']), sep='|')" 2>&1
Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/liquibase.py') (Join-Path $k 'skills/crafty/adapters')   # keepboth is its plugin verb
$kb25 = & $py -X utf8 $DT keepboth $cf 2>&1 | Out-String
Expect "local_pass newest by instant; merge --scope names a dropped glob only; keepboth verb (plugin) keeps ours then theirs ($r25 | $($kb25.Trim()))" ("$r25" -eq "round 2 PASS|['b.json']|[]|[]" -and $kb25 -match 'resolved 1 block' -and [IO.File]::ReadAllText($cf) -eq "a`nours`ntheirs`n")
# Get-Python skips a .bat shim (pyenv-win): a run title with a quote and ( ) went through cmd.exe, finalize's upload exit 255
if ($IsWindows) {
  $shimDir = (New-Item -ItemType Directory -Force (Join-Path (Kd) 'pyshim')).FullName; $realPy = "$(& $py -c 'import sys; print(sys.executable)')".Trim()
  [IO.File]::WriteAllText((Join-Path $shimDir 'python.bat'), "@echo off`r`nfor %%a in (x) do (`r`n  `"$realPy`" %* || goto :error`r`n  exit /b`r`n)`r`n:error`r`nexit /b 255`r`n")
  $tq = 'run: a (x); "create a sale T4 - test evidence (2026-11-24)'; $oldPath = $env:PATH
  try { $env:PATH = "$shimDir;$oldPath"; $gpR = & { . (Join-Path $k 'skills/crafty/lib.ps1'); & (Get-Python) -c 'import sys; print(sys.argv[1])' $tq 2>&1 | Out-String } } finally { $env:PATH = $oldPath }
  Expect "Get-Python: the real python.exe behind a .bat shim keeps an arg with a quote and ( ) ($gpR)" ("$gpR".Trim() -eq $tq)
}
# ---- proof (owner 2026-11-25: 48% came back, ui goals proven by API / stubs): adapters/proof.py gates finish, mr, wt commit
Copy-Item (Join-Path $src 'skills/crafty/adapters/proof.py') (Join-Path $k 'skills/crafty/adapters')
$pfSelf = & $py -X utf8 $DT proof selftest 2>&1 | Out-String
Expect "proof selftest: channel gaps (API-only ui, NOT_TESTED_LOCAL, viewport, hit test, ai guard), impact map, happy path, Draft, finish wrap, goals doc ($(@([regex]::Matches($pfSelf, '(?m)^PASS')).Count) PASS)" ($LASTEXITCODE -eq 0 -and $pfSelf -notmatch '(?m)^FAIL' -and @([regex]::Matches($pfSelf, '(?m)^PASS')).Count -ge 13)
$pfOld = if (Test-Path $pdF) { Get-Content -Raw $pdF } else { $null }; $pfC = if ($pfOld) { $pfOld | ConvertFrom-Json -AsHashtable } else { @{} }
$pfC.process = @{ gates = @{ finish = 'builtin:testingDocs' } }; $pfC.tracker = @{ branchRx = '(?<id>PF\d+)' }; Set-JsonFile $pdF $pfC
$pfChk = @{ id = 'T1'; area = 'Orders'; steps = '1. open Orders 2. click Save'; expected = 'Saved shows' }
Set-JsonFile (Join-Path (Kd) 'pf1.json') @{ title = 'Save order'; checks = @($pfChk); cases = @(@{ id = 'A1'; type = 'positive'; check = 'T1'; steps = 'Orders, Save'; expected = 'Saved' }) }
$pfAdd = & $py -X utf8 $DT cases add PF1 (Join-Path (Kd) 'pf1.json') 2>&1 | Out-String
$pfGap = & $py -X utf8 $DT proof PF1 2>&1 | Out-String; $pfGapc = $LASTEXITCODE
$pfRepo = Join-Path (Kd) 'pf-repo'; New-Item -ItemType Directory -Force $pfRepo | Out-Null; 'a' | Set-Content "$pfRepo/a.txt"; Save-GitRepo $pfRepo i; git -C $pfRepo checkout -q -b feat/PF1-save
'b' | Set-Content "$pfRepo/b.ts"; $pfNo = pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') wt commit -Dir $pfRepo -Message 'feat: save the order' 2>&1 | Out-String; $pfNoc = $LASTEXITCODE
$null = pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') wt commit -Dir $pfRepo -Message 'wip: save' 2>&1; $pfWip = $LASTEXITCODE
Expect "proof: cases add warns, proof PF1 lists the gaps, wt commit refuses the code commit without the impact map, a WIP passes ($pfGapc $pfNoc $pfWip)" ($pfAdd -match 'WARN cases PF1: no impact map' -and $pfGapc -eq 1 -and $pfGap -match "check T1: channel 'unset'" -and
  $pfGap -match 'happy path only' -and $pfNoc -eq 1 -and $pfNo -match 'commit refused: .*no impact map' -and $pfWip -eq 0)
Set-JsonFile (Join-Path (Kd) 'pf1.json') @{ checks = @($pfChk + @{ channel = 'ui' }); impact = @{ logic = 'save since abc1; disabled SaveTest expects it'; callers = @('web Orders', 'app sync'); path = 'UI -> API -> DB -> UI'; renders = @(@{ item = 'Orders list'; result = 'A1 PASS' }) }
  cases = @(@{ id = 'A2'; type = 'negative'; check = 'T1'; steps = 'Orders, Save empty'; expected = 'Required shows' }) }
$null = & $py -X utf8 $DT cases add PF1 (Join-Path (Kd) 'pf1.json') --replace 2>&1
$pfApi = & $py -X utf8 $DT cases result PF1 A1 PASS 'put.json=https://h/put' 2>&1; $pfApiG = & $py -X utf8 $DT proof PF1 2>&1 | Out-String
$null = & $py -X utf8 $DT cases result PF1 A1 PASS 'a1.png=https://h/a1' viewport=1366x768 hit=PASS 2>&1; $null = & $py -X utf8 $DT cases result PF1 A2 PASS 'a2.png=https://h/a2' 2>&1
$pfOk = & $py -X utf8 $DT proof PF1 2>&1 | Out-String; $pfOkc = $LASTEXITCODE; $pfGoals = Get-Content -Raw (& $py -X utf8 $DT cases render PF1 goals 2>$null)
'c' | Set-Content "$pfRepo/c.ts"; $null = pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') wt commit -Dir $pfRepo -Message 'feat: save the order' 2>&1; $pfYes = $LASTEXITCODE
if ($null -ne $pfOld) { [IO.File]::WriteAllText($pdF, $pfOld) } else { Remove-Item -LiteralPath $pdF }
Expect "proof: an API-only PASS on a ui goal stays a gap; a screenshot at 1366x768 + hit PASS closes it; the goals doc shows proof and impact map; the code commit goes in ($pfOkc $pfYes)" (
  $pfApiG -match 'T1 \(ui\): no PASS case with UI evidence' -and $pfOkc -eq 0 -and $pfGoals -match '## Impact map' -and $pfGoals -match 'A1 PASS viewport 1366x768 hit PASS' -and $pfYes -eq 0)
# owner 2026-11-25: the matrix sized to the diff (proof.py matrix-scope): .ts edits = reduced, recorded on the task; a new .scss = full
git -C $pfRepo update-ref refs/remotes/origin/main (git -C $pfRepo rev-list --max-parents=0 HEAD)
$msR = & $py -X utf8 $DT matrix-scope PF1 --dir $pfRepo 2>$null | Out-String; 'x{}' | Set-Content "$pfRepo/my menu.scss"; $msF = & $py -X utf8 $DT matrix-scope --dir $pfRepo --json 2>$null | Out-String
$msRec = & { . (Join-Path $k 'skills/crafty/lib.ps1'); (Get-Content (Join-Path (Get-KitPath tasks) 'PF1.json') -Raw | ConvertFrom-Json).cases.matrixScope }
Expect "matrix-scope: .ts edits = reduced (1366x768 + 390x844), recorded on the task; an untracked .scss (a space in its name) = full, named ($($msR.Trim() -split "`n" | Select-Object -First 1))" (
  $msR -match '^matrix-scope PF1: reduced \(2 file\(s\), no layout / style or new screen\): 2 variant\(s\)' -and $msRec.scope -eq 'reduced' -and @($msRec.matrix.viewports) -join ',' -eq '1366x768,390x844' -and ($msF | ConvertFrom-Json).reason -eq 'my menu.scss is layout / style')
# owner 2026-11-25 ("never do this"), 2026-11-26 (dec-came-back C): N model runs only for an ai goal's declared passRate (devy, pre-merge)
$aiRx = @'
(\bai\b|\bmodel|\bllm|\bprompt|llm-driven).{0,80}([0-9]+\+?|\bN) (times|runs|reruns|attempts)
'@.Trim()
$aiHits = @(git -C $src grep -n -i -E $aiRx -- '*.md' '*.js' '*.mjs' ':!.codex' ':!.agents' 2>&1); $aiCode = $LASTEXITCODE
$aiHits = @($aiHits | Where-Object { "$_" -notmatch 'never (rerun|N reruns)|never reruns it|passRate|pass rate' })
$aiSelf = @("LLM-driven checks: 5+ runs in fresh sessions", "never rerun a model N times") | Where-Object { $_ -match "(?i)$aiRx" -and $_ -notmatch 'never (rerun|N reruns)' }
Expect "no kit text tells an agent to rerun an AI flow N times (grep exit $aiCode, $($aiHits.Count): $($aiHits | Select-Object -First 2))" ($aiCode -le 1 -and $aiHits.Count -eq 0 -and @($aiSelf).Count -eq 1 -and $pfSelf -match 'PASS proof: a goal per channel')
# ---- precheck (owner 2026-11-25): the mechanical review rules before review (adapters/precheck.py)
Copy-Item (Join-Path $src 'skills/crafty/adapters/precheck.py') (Join-Path $k 'skills/crafty/adapters')
$pcSelf = & $py -X utf8 $DT precheck selftest 2>&1 | Out-String
Expect "precheck selftest: every rule fires on its input, a clean MR passes ($(@([regex]::Matches($pcSelf, '(?m)^PASS')).Count) PASS)" ($LASTEXITCODE -eq 0 -and $pcSelf -notmatch '(?m)^FAIL' -and @([regex]::Matches($pcSelf, '(?m)^PASS')).Count -ge 21)
Set-JsonFile (Join-Path (Kd) 'pc-mr.json') @{ task = 'PF1'; type = 'fix'; scope = ''; change = 'save the order'; summary = 'Orders save'; changes = @(@{ text = 'Save works' }); checksRun = @(@{ name = 'tests'; result = 'PASS' }); notRun = 'nothing'; risks = @(@{ text = 'none: one field' }) }
$pcOut = & $py -X utf8 $DT precheck PF1 --dir $pfRepo --spec (Join-Path (Kd) 'pc-mr.json') --json 2>$null | Out-String; $pcCode = $LASTEXITCODE
$pcCodes = @(($pcOut | ConvertFrom-Json) | ForEach-Object code)
Expect "precheck --dir --spec: the branch's wip commit and the missing loop checkpoint fail it, the rendered title passes ($pcCode; $($pcCodes -join ','))" ($pcCode -eq 1 -and 'COMMITS' -in $pcCodes -and 'LOOP' -in $pcCodes -and 'TITLE' -notin $pcCodes)
# ---- promote on merge: MERGED runs track run for the MR's open task at once; SCHEDULED and a done task do not
$pmPy = Join-Path (Kd) 'promote-merge.py'
[IO.File]::WriteAllText($pmPy, "import sys; sys.path.insert(0, sys.argv[1]); import devtools as d`nruns = []`nd._run = lambda c, **kw: runs.append(c[-1]) or ''`nd.remote = lambda w: ('gitlab', 'grp/api')`nd.read_tracking = lambda: {'tasks': {'T1': {'mrs': ['api!7']}, 'T2': {'mrs': ['api!8'], 'done': True}}}`nfor iid, word in (('7', 'MERGED'), ('8', 'MERGED'), ('9', 'SCHEDULED')):`n    d.auto_merge = lambda w, i, word=word: 'x\n' + word`n    sys.argv = ['devtools.py', 'merge', '.', iid]`n    try: d._cli()`n    except SystemExit: pass`nprint('RUNS', runs)`n")
$pmOut = & $py -X utf8 $pmPy (Split-Path $DT) 2>&1 | Out-String
Expect "devtools.py merge MERGED: track run -Task of the open task only ($(($pmOut -split "`n" | Select-String 'RUNS') -join ''))" ($pmOut -match "RUNS \['T1'\]")
Remove-TestKit $k
Complete-Tests
