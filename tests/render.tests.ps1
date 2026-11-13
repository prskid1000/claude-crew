#Requires -Version 7
<#
render.tests.ps1: agent-written artefacts rendered from small specs (devtools.py "render"): golden text per renderer, the
same spec -> the same text on every adapter, the gates judge the rendered text.
Usage: pwsh -NoProfile -File <kit>/tests/render.tests.ps1 (or tests/kit-tests.ps1 -Area render).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit render; $DT = Join-Path $k 'skills/crafty/devtools.py'; $wd = Join-Path (Kd) 'w'; New-Item -ItemType Directory -Force $wd | Out-Null
function Dt { $o = & $py -X utf8 $DT @args 2>&1 | Out-String; [pscustomobject]@{ out = $o.Trim(); code = $LASTEXITCODE } }
function Gold($a, $b) { ("$a" -replace "`r`n", "`n").TrimEnd() -eq ("$b" -replace "`r`n", "`n").TrimEnd() }

# ---- cases spec -> goals file, AI doc, human doc (item 1)
$cs = @{ title = 'Sort orders'; change = 'orders sort by date'; repos = @('web!5'); env = 'local r3'; services = 'api'; setup = 'order rows via the API, deleted after'
  checks = @(@{ id = 'T1'; area = 'Orders screen'; steps = '1. Open Orders 2. Click Date'; expected = 'newest first' })
  qualities = @(@{ id = 'Q1'; goal = 'list loads fast'; how = '5 timings'; rule = 'p95 <= 2 s' })
  cases = @(@{ id = 'A1'; type = 'positive'; check = 'T1'; steps = 'click Date'; expected = 'newest first' }, @{ id = 'A2'; type = 'negative'; steps = 'GET /orders?sort=x'; expected = '400 | bad sort' })
  plan = @{ unit = 'OrderSortTest' }; switches = @(@{ setting = 'sortV2'; where = 'Settings'; value = 'on' }) }
Set-JsonFile "$wd/cases.json" $cs
$ca = Dt cases add T1 "$wd/cases.json"; $cr = Dt cases result T1 A1 PASS 'https://x/a1.png'; $null = Dt cases result T1 A2 PASS 'https://x/a2.json'
$cn = Dt cases round T1 --fix abc1234; $cx = Dt cases result T1 A9 PASS
$ai = Get-Content -Raw (Dt cases render T1 ai).out; $hu = Get-Content -Raw (Dt cases render T1 human).out; $go = Get-Content -Raw (Dt cases render T1 goals).out
$day = Get-Date -Format 'yyyy-MM-dd'
Expect "cases add / result / round: the task's spec changes by key; an unknown case id is refused ($($ca.code)$($cr.code)$($cn.code)$($cx.code))" ($ca.code + $cr.code + $cn.code -eq 0 -and $cx.code -ne 0 -and $cx.out -match 'no case A9')
Expect 'cases render ai: golden text (case # names its human check, evidence image inline / file link, a pipe escaped, Rounds row)' (Gold $ai @"
# Testing doc (AI): T1 Sort orders

Setup and cleanup: order rows via the API, deleted after.

Cases:

| # | Type | Steps / API call + payload | Expected | Result | Evidence |
|---|---|---|---|---|---|
| A1 (T1) | positive | click Date | newest first | PASS | ![A1](https://x/a1.png) |
| A2 | negative | GET /orders?sort=x | 400 \| bad sort | PASS | [a2.json](https://x/a2.json) |

Rounds (one per round, appended):

| Round | Date | Cases run | Result | Bugs found | Fix commit | Retest |
|---|---|---|---|---|---|---|
| 1 | $day | A1, A2 | 2 PASS | none | abc1234 |  |
"@)
Expect 'cases render human: golden text (positive checks only, Result / Evidence empty, switches table)' (Gold $hu @"
# Testing: Sort orders

|  |  |
|---|---|
| Tasks | T1 |
| Environment |  |
| Logins |  |
| Test data |  |

## What changed

orders sort by date

## Before you start / Feature switches

Set these first, restore them after:

| Setting | Where | Value |
|---|---|---|
| sortV2 | Settings | on |

## Checks

Orders screen:

| # | Steps | Expected | Result | Evidence |
|---|---|---|---|---|
| T1 | 1. Open Orders 2. Click Date | newest first |  |  |

## Out of scope

none

## Result (testers)

All checks pass -> close the task. A check of this change fails or could not be tested -> failedTesting with the check ids and why. A defect outside this change -> one [Bug] task under the original ask.
"@)
Expect 'cases render goals: a goal per human check (its result from the AI rows naming it) and quality, the rounds' ($go -match '(?m)^\| G1 \(T1\) \| newest first \| A1 \| newest first \| PASS \|$' -and $go -match '(?m)^\| Q1 \| list loads fast \| 5 timings \| p95 <= 2 s \|  \|$' -and $go -match '(?m)^- unit: OrderSortTest$' -and $go -match '(?m)^\| 1 \| none \| abc1234 \|$')
# the gates judge the rendered text: the goals file is never published; the AI doc publishes (markdown and html adapters: same text)
$env:KIT_REPORT_TYPE = 'markdown'; $pg = Dt doc 'goals' (Dt cases render T1 goals).out --key T1:testing-ai --override t; $pm = Dt doc 'Sort orders' cases --key T1:testing-ai --override t
$env:KIT_REPORT_TYPE = 'html'; $null = Dt cases add T2 "$wd/cases.json"; $ph = Dt doc 'Sort orders' cases --key T2:testing-ai --override t; $env:KIT_REPORT_TYPE = $null
$pmText = if (Test-Path -LiteralPath $pm.out) { Get-Content -Raw $pm.out } else { '' }
Expect "cases: the goals file is refused for publishing; the rendered AI doc publishes unchanged (markdown) and as html ($($pm.code) $($ph.code))" ($pg.code -ne 0 -and $pg.out -match 'local goals file' -and $pm.code -eq 0 -and (Gold $pmText $ai) -and $ph.code -eq 0 -and (Get-Content -Raw $ph.out) -match '>400 \| bad sort<')
Set-JsonFile "$wd/bad.json" @{ title = 'x'; cases = @(@{ id = 'B1'; type = 'happy'; check = 'T9' }) }; $bad = Dt cases add T3 "$wd/bad.json"; $br = Dt cases render T3 ai
Expect "cases: a wrong type or an unknown check is named on add and refused on render ($($br.code))" ($bad.out -match "type 'happy'" -and $br.code -ne 0 -and $br.out -match "check 'T9'")
# ---- MR title / body / commit from one spec (item 2): one renderer, any git host
$ms = @{ task = 'T1'; taskUrl = 'https://tr/t/T1'; type = 'feat'; scope = 'orders'; change = 'sort orders by date'; code = 'P1'; repo = 'web'; summary = 'Orders sort newest first.'
  changes = @(@{ text = 'Orders list sorts by date'; technical = 'OrderService.sort' }); checksRun = @(@{ name = 'check quick'; result = 'PASS' }, @{ name = 'tests OrderSortTest'; result = 'PASS' })
  localEnv = 'local r3: round 2 PASS'; risks = @(@{ text = 'old clients keep id order' }); siblings = @('api!4'); trailers = @('Co-Authored-By: A <a@b>') }
Set-JsonFile "$wd/mr.json" $ms
$mt = Dt render mr-title "$wd/mr.json"; $mb = Dt render mr-body "$wd/mr.json"; $mc = Dt render commit "$wd/mr.json"
Expect "render mr-title / commit: default formats (templates.md mr-title, Conventional Commits), bullets, trailer ($($mt.out))" ($mt.out -eq 'feat(orders): sort orders by date (T1)' -and (Gold $mc.out "feat(orders): sort orders by date`n`n- Orders list sorts by date (``OrderService.sort``)`n`nCo-Authored-By: A <a@b>"))
Expect 'render mr-body: golden text (templates.md "MR spec": sections, How tested table, risks, links)' (Gold $mb.out @"
## Summary

[T1](https://tr/t/T1) — Orders sort newest first.

## Changes

- Orders list sorts by date · **Technical:** ``OrderService.sort``

## How tested

| Check | Result |
|---|---|
| Checks | check quick ✅ · tests OrderSortTest ✅ |
| Local env | local r3: round 2 PASS |
| Not run | nothing |
| UI | not a UI change |
| Pure logic | none |
| Regression | not a fix |

## Risks

- old clients keep id order
- **Behaviour limits:** none
- **Needs after deploy:** none

## Links

- **Sibling MRs:** api!4 (merge order: producers first)
"@)
Set-JsonFile "$k/skills/crafty/kit.local.json" @{ mrTitleFormat = '{type}: {change} - {code} ({tag}{task}) ({repo})'; commitFormat = '{repo}: {change}'; tracker = @{ branchTag = 'X-' } }
$mt2 = Dt render mr-title "$wd/mr.json"; $ms.code = ''; Set-JsonFile "$wd/mr2.json" $ms; $mt3 = Dt render mr-title "$wd/mr2.json"; $mc2 = Dt render commit "$wd/mr2.json"; Remove-Item "$k/skills/crafty/kit.local.json"
Expect "render: mrTitleFormat / commitFormat from kit config; an empty placeholder drops its ' -' and () ($($mt2.out) | $($mt3.out))" ($mt2.out -eq 'feat: sort orders by date - P1 (X-T1) (web)' -and $mt3.out -eq 'feat: sort orders by date (X-T1) (web)' -and $mc2.out -match '^web: sort orders by date\r?\n')
Set-JsonFile "$wd/mr3.json" @{ type = 'feat' }; $mg = Dt render mr-body "$wd/mr3.json"; $mm = Dt mr $wd --spec "$wd/mr3.json"
Expect "render / mr --spec: a spec without change or summary is refused, nothing opened ($($mg.code) $($mm.code))" ($mg.code -ne 0 -and $mg.out -match 'missing change, summary' -and $mm.code -ne 0 -and $mm.out -match 'mr spec refused')
$hp = Join-Path (Kd) 'hosts.py'; [IO.File]::WriteAllText($hp, "import sys, json; sys.path.insert(0, sys.argv[1]); import devtools as d`nsent = {}`nfor h in ('gitlab', 'github'):`n    d.remote = lambda wt, h=h: (h, 'g/web'); d._run = lambda *a, **k: 'f/T1-x'; d.prior_gate = d.task_of_branch = lambda *a: None`n    d._ui_line_missing = lambda *a: []; d._host = lambda verb, **a: [] if verb == 'mr.list' else sent.setdefault(a['type'], a) and {'web_url': 'u'}`n    s = json.load(open(sys.argv[2], encoding='utf-8')); d.mr_create('wt', d.render_title(s), d.render_mr_body(s), 'main')`nprint(sent['gitlab']['title'] == sent['github']['title'] and sent['gitlab']['body'] == sent['github']['body'] and 'How tested' in sent['github']['body'])`n")
$hr = & $py -X utf8 $hp (Split-Path $DT) "$wd/mr.json" 2>&1 | Select-Object -Last 1
Expect "mr --spec: the same title and body reach every git-host adapter (gitlab, github) ($hr)" ("$hr".Trim() -eq 'True')
$gr = Join-Path (Kd) 'cr'; New-Item -ItemType Directory -Force $gr | Out-Null; git -C $gr init -q; 'x' | Set-Content "$gr/a.txt"
$wc = pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') wt commit -Dir $gr -Spec "$wd/mr.json" 2>&1 | Out-String; $wcm = git -C $gr log -1 --format=%B
Expect "crafty.ps1 wt commit -Spec: the commit message is the rendered one ($($wcm -join ' '))" (Gold ($wcm -join "`n") $mc.out)
# ---- drift guard (item 22): every agent-written kind names its writer; run files keep a listed shape
New-Item -ItemType Directory -Force "$k/skills/crafty", "$k/skills/bossy" | Out-Null; Copy-Item (Join-Path $src 'skills/bossy/STATE.md') "$k/skills/bossy/"; Copy-Item (Join-Path $src 'skills/crafty/templates.md') "$k/skills/crafty/"
$KB = Join-Path $k 'skills/bossy/kitbag.py'
function Kb($code) { & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KB)'); import kitbag as k; $code" 2>&1 }
$al0 = Kb "print(len(k.artefact_lint(r'$k', {'bossy.ps1', 'crafty.ps1', 'devtools.py', 'pokey.ps1', 'testy.js', 'kitbag.py'})))"
$tp = Get-Content -Raw "$k/skills/crafty/templates.md"; [IO.File]::WriteAllText("$k/skills/crafty/templates.md", $tp.Replace('| owner-message |', "| sprint-note | a new free-text note | prose | 50w | — |`n| owner-message |"))
$sd = Get-Content -Raw "$k/skills/bossy/STATE.md"; [IO.File]::WriteAllText("$k/skills/bossy/STATE.md", $sd.Replace('| `owner-message` |', "| ``qa-x`` | hand-written | — | ``md ^(# x`` |`n| ``owner-message`` |"))
$al1 = Kb "print('\n'.join(k.artefact_lint(r'$k', {'bossy.ps1', 'crafty.ps1', 'devtools.py', 'pokey.ps1', 'testy.js', 'kitbag.py'})))"
Expect "lint ARTEFACT: the kit's kinds all name a writer; a new Writing-standards kind without a row, a writer no script / free, a bad shape fail ($al0)" ("$al0".Trim() -eq '0' -and "$al1" -match 'kind sprint-note has no "Artefacts" row' -and "$al1" -match "qa-x: writer 'hand-written'" -and "$al1" -match 'qa-x: shape regex')
[IO.File]::WriteAllText("$k/skills/bossy/STATE.md", $sd); $rw = TkPath $k work -Create
foreach ($f in @{ 'qa-runs/r1/lead-notes.md' = "# Lead notes: r1"; 'qa-runs/r2/lead-notes.md' = "Notes of r2"; 'qa-runs/r1/fix-round.md' = "Fix round 2"; 'qa-runs/r1/run.json' = '{}'
    'agents/a1/free.md' = 'my notes'; 'agents/a1/mr.md' = "## Summary"; 'agents/a1/spec.json' = '{}'; 'docs/T1_testing-ai.md' = '# Testing doc (AI): T1 x'; 'docs/T1_qa-report.md' = 'x'; 'loose.py' = 'print(1)' }.GetEnumerator()) {
  $p = Join-Path $rw $f.Key; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; [IO.File]::WriteAllText($p, $f.Value) }
$sl = & $py -X utf8 $KB state lint --json 2>$null | ConvertFrom-Json; $slc = $LASTEXITCODE
$art = @($sl | Where-Object name -eq 'artefacts' | ForEach-Object { "$($_.level) $($_.file)" }) -join '; '
Expect "state lint drift guard: an unlisted shape in a shared place BAD (exit 1), agent scratch / loose work files WARN, listed shapes pass ($art)" ($slc -eq 1 -and $art -match 'BAD work/qa-runs/r2/lead-notes.md' -and $art -match 'BAD work/qa-runs/r1/fix-round.md' -and $art -match 'WARN work/agents/a1/free.md' -and $art -match 'WARN work/loose.py' -and $art -notmatch 'r1/lead-notes|mr\.md|spec\.json|T1_testing|run\.json')
# ---- results.json written once; the workflow sends deltas (item 3): testy.js resultsPatch -> pokey.ps1 results patch / hold
$rd = Join-Path (Kd) 'qa-run'; New-Item -ItemType Directory -Force "$rd/W1" | Out-Null
$row = { param($id, $r) [ordered]@{ id = $id; subtask_id = 't1'; screen = 's'; result = $r; what_was_done = 'w'; observed = 'o'; evidence = @(); attempts = 1 } }
$tester = [ordered]@{ code = 'W1'; checks = @((& $row 'T1' 'PASS'), (& $row 'T2' 'FAIL'), (& $row 'T2' 'PASS')); findings = @(); setup_changes = @(); data_created = @() }
Set-JsonFile "$rd/W1/results.json" $tester; Set-JsonFile "$rd/tester.json" $tester
$js = Join-Path (Kd) 'rp.mjs'; [IO.File]::WriteAllText($js, @'
import fs from 'node:fs'
const src = fs.readFileSync(process.argv[2], 'utf8'), Q = 'pokey.ps1', R = { runDir: 'RD' }
eval(src.slice(src.indexOf('const uniq ='), src.indexOf('function finalPrompt')).replace('function resultsPatch', 'globalThis.resultsPatch = function').replace('const uniq =', 'globalThis.uniq ='))
const written = JSON.parse(fs.readFileSync(process.argv[3], 'utf8')), res = JSON.parse(JSON.stringify(written))
res.code = 'W1'; res.checks[2].id = 'T2b'; res.checks[2].guideId = 'T2'; res.checks[1].verify = "re-test: confirmed (it's real)"
res.checks.push({ id: 'T1n', subtask_id: 't1', screen: 's', result: 'NOT_TESTED', cause: 'env-data', what_was_done: 'split', observed: '', evidence: [], attempts: 0 })
console.log(resultsPatch(written, res)); console.log('NONE=' + JSON.stringify(resultsPatch(written, { ...written, checks: uniq(written.checks) })))
'@)
$cmds = @(node $js (Join-Path $src 'workflows/testy.js') "$rd/tester.json" 2>&1)
$pj = if ("$($cmds[0])" -match "-Patch '(.*)'$") { $Matches[1].Replace("''", "'") } else { '' }
$PK = Join-Path $k 'skills/pokey/pokey.ps1'
$pr = pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W1 -Patch $pj 2>&1 | Out-String; $after = Get-Content -Raw "$rd/W1/results.json" | ConvertFrom-Json
$pb = pwsh -NoProfile -File $PK results patch -RunDir $rd -Code W1 -Patch '{"set":{"T9":{"result":"PASS"}},"add":[{"id":"Z1","color":"red"}]}' 2>&1 | Out-String
$ph = pwsh -NoProfile -File $PK results hold -RunDir $rd -Code W1 -Why "env: it's down" -Summary 'W1: pass 1/3' -EnvFix '{"id":"d-1","state":"open"}' 2>&1 | Out-String; $hj = Get-Content -Raw "$rd/W1/held.json" | ConvertFrom-Json
Expect "testy.js resultsPatch: only the changed fields and added rows (dup ids as the workflow names them), none when nothing changed ($($cmds -join ' || '))" ("$($cmds[0])" -match "^& 'pokey\.ps1' results patch -RunDir 'RD' -Code W1 -Patch '\{" -and $pj -match '"set":\{"T2":\{"verify":"re-test: confirmed \(it.s real\)"\}\}' -and $pj -match '"add":\[\{"id":"T1n"' -and $pj -notmatch 'T2b|"T1":' -and "$($cmds[1])" -eq 'NONE=""')
Expect "pokey.ps1 results patch: deltas merged by id (dup ids made unique, guideId), rows added, unknown key / id refused, nothing written ($($pr.Trim()))" ($pr -match '1 changed, 1 added, 4 checks' -and (@($after.checks.id) -join ',') -eq 'T1,T2,T2b,T1n' -and $after.checks[1].verify -match "it's real" -and $after.checks[2].guideId -eq 'T2' -and $pb -match 'unknown row key\(s\) color' -and @((Get-Content -Raw "$rd/W1/results.json" | ConvertFrom-Json).checks).Count -eq 4)
Expect "pokey.ps1 results hold: held.json from arguments, the script's UTC time ($($hj.at))" ($hj.held -eq "env: it's down" -and $hj.envFix.id -eq 'd-1' -and $hj.summary -eq 'W1: pass 1/3' -and (Get-Content -Raw "$rd/W1/held.json") -match '"at": "\d{4}-\d\d-\d\dT[\d:.]+Z"')
# review fixes: a round counts only the cases run in it, a result replaces the evidence, _del removes; () and non-ASCII survive formats
$null = Dt cases result T1 A2 FAIL; $null = Dt cases round T1 --bugs 'A2: 500'; Set-JsonFile "$wd/del.json" @{ cases = @(@{ id = 'A2'; _del = $true }) }; $null = Dt cases add T1 "$wd/del.json"
$ai2 = Get-Content -Raw (Dt cases render T1 ai).out
Expect 'cases round 2: only the case run in it, its result; a new result drops the old evidence; _del removes a case' ($ai2 -match '(?m)^\| 2 \| [\d-]+ \| A2 \| 1 FAIL \| A2: 500 \|' -and $ai2 -notmatch '(?m)^\| A2 \|' -and $ai2 -match '(?m)^\| A1 \(T1\) \| positive')
Set-JsonFile "$wd/u.json" @{ type = 'fix'; change = 'remove init() — café ✅'; task = 'T1' }; $ut = Dt render mr-title "$wd/u.json"
'y' | Set-Content "$gr/b.txt"; $null = pwsh -NoProfile -File (Join-Path $k 'skills/crafty/crafty.ps1') wt commit -Dir $gr -Spec "$wd/u.json" 2>&1; $us = git -C $gr log -1 --format=%s
Expect "render / wt commit -Spec: a () and ' - ' inside the change and non-ASCII text survive ($($ut.out) | $us)" ($ut.out -eq 'fix: remove init() — café ✅ (T1)' -and $us -eq 'fix: remove init() — café ✅')
# ---- comments from specs (items 5, 12): solution and status comments, one renderer, any tracker
Set-JsonFile "$wd/sol.json" @{ solution = 'orders sorted by id; now by date'; mrs = @('web!5 (MERGED)', 'api!4 (OPEN)'); localProof = 'local r3: round 2 PASS'; deferred = 'export sort — next sprint' }
Set-JsonFile "$wd/st.json" @{ status = 'blocked'; why = 'needs the owner''s sort rule'; link = 'https://t/d1' }; Set-JsonFile "$wd/st2.json" @{ status = 'blocked' }
$cs1 = Dt render comment-solution "$wd/sol.json"; $cs2 = Dt render comment-status "$wd/st.json"; $cs3 = Dt render comment-status "$wd/st2.json"
Expect 'render comment-solution / comment-status: golden text; a status without why refused' ((Gold $cs1.out "**Solution:** orders sorted by id; now by date`n**MRs:** web!5 (MERGED) · api!4 (OPEN) · **Local proof:** local r3: round 2 PASS`n**After deploy:** nothing · **Deferred:** export sort — next sprint") -and $cs2.out -eq "blocked — needs the owner's sort rule · https://t/d1" -and $cs3.code -ne 0 -and $cs3.out -match 'missing why')
# ---- run-file schemas (items 10, 17, 19): required + allowed keys; another key = drift (BAD, supervise WATCH)
$qr = TkPath $k qa-runs -Create; New-Item -ItemType Directory -Force "$qr/r3/A1" | Out-Null
Set-JsonFile "$qr/r3/A1/results.json" @{ code = 'A1'; checks = @(); colour = 'red' }; Set-JsonFile "$qr/r3/run.json" @{ title = 't'; runDir = 'r3'; items = @() }
Set-JsonFile (Join-Path (TkPath $k programs -Create) 'p1.json') @{ wave = 1 }
$s10 = @(& $py -X utf8 $KB state lint --json 2>$null | ConvertFrom-Json | ForEach-Object { "$($_.name)|$($_.problem)" }) -join "`n"
Expect 'state lint schemas: a results.json key outside its schema is drift, a program without updated misses a key, a listed run.json passes' ($s10 -match 'qa-runs:results\|drift: key\(s\) colour' -and $s10 -match 'programs\|missing updated' -and $s10 -notmatch 'qa-runs:run\|drift')
# ---- kitty to-do / handoff lists (item 21): one item shape, written by kitbag.py state todo, linted
$td = Join-Path $wd 'todo.md'; $t1 = & $py -X utf8 $KB state todo add $td R1 'render the wave brief' 'kit-render-all.md:10' 2>&1; $null = & $py -X utf8 $KB state todo add $td R2 'retro report' 'item 9' 2>&1
$t2 = & $py -X utf8 $KB state todo done $td R1 'kit abc1234' 2>&1; $t3 = & $py -X utf8 $KB state todo add $td R2 'again' 'x' 2>&1; $t3c = $LASTEXITCODE
$tl0 = & $py -X utf8 $KB state todo lint $td 2>&1; $tl0c = $LASTEXITCODE; Add-Content $td '- [ ] free text item'; $tl1 = & $py -X utf8 $KB state todo lint $td 2>&1; $tl1c = $LASTEXITCODE
Expect "state todo: add / done render '- [ ] <code> · <desc> · <ref>', a dup code refused; lint fails on a free line ($tl0c $tl1c)" ((Gold ((Get-Content -Raw $td) -replace '(?m)^- \[ \] free text item\r?\n?', '') "# Kit to-do`n`n- [x] R1 · render the wave brief · kit abc1234`n- [ ] R2 · retro report · item 9") -and $t3c -ne 0 -and $tl0c -eq 0 -and $tl1c -eq 1 -and "$tl1" -match 'TODO-SHAPE - \[ \] free text item')
# ---- final reports (item 13): a role's JSON, rendered by the coordinator; no key ever dropped
Set-JsonFile "$wd/fr.json" ([ordered]@{ role = 'devy'; agent = 'X1'; disputes = @(); mrs = @([ordered]@{ url = 'https://g/r/-/merge_requests/5'; state = 'MERGED' }); localTest = [ordered]@{ status = 'PASS'; rounds = 2 }; done = @('S01', 'S02'); extra = 'kept' })
Set-JsonFile "$wd/fr2.json" ([ordered]@{ role = 'opsy'; env = 'staging'; verify = 'ok' }); $fr = Dt render final-report "$wd/fr.json"; $fr2 = Dt render final-report "$wd/fr2.json"
Expect 'render final-report: the role''s keys in order, empty ones dropped, other keys kept; any role renders' ((Gold $fr.out "**devy** X1`n**mrs:** url https://g/r/-/merge_requests/5 state MERGED`n**localTest:** status PASS rounds 2`n**done:** S01 · S02`n**extra:** kept") -and (Gold $fr2.out "**opsy**`n**env:** staging`n**verify:** ok"))
# ---- retro report (item 9) from the judge's lists
Set-JsonFile "$wd/retro.json" ([ordered]@{ date = '2026-11-13'; applied = @([ordered]@{ change = 'gate waits learned'; file = '`lib.ps1`'; count = 3 }); rejected = @([ordered]@{ signal = 'one flaky run'; why = 'single' }) })
$rr = Dt render retro "$wd/retro.json" (Join-Path $wd 'retro.md')
Expect 'render retro: golden kit-report (Result counts, Changed / Awaiting approval / Rejected), written to the out file' (Gold (Get-Content -Raw (Join-Path $wd 'retro.md')) "# Retro 2026-11-13`n`n**Result:** 1 applied · 0 awaiting approval · 1 rejected`n`n## Changed`n`n| Change | File | Digest count |`n|---|---|---|`n| gate waits learned | ``lib.ps1`` | 3 |`n`n## Awaiting approval`n`nnone`n`n## Rejected`n`n| Signal | Why |`n|---|---|`n| one flaky run | single |")
# ---- handoff resume brief (item 8): rendered from the checkpoint; the agent adds one notes line
$craftyPs = Join-Path $k 'skills/crafty/crafty.ps1'; $hbf = Join-Path $wd 'handoff-h8.md'
$null = pwsh -NoProfile -File $craftyPs checkpoint -Agent h8 -Run r8 -Step commit -Evidence abc1234 2>&1
$hbo = pwsh -NoProfile -File $craftyPs checkpoint -Agent h8 -Run r8 -Step mr -Evidence 'web!5' -Notes "rebase  pending`nthen push" -Brief $hbf 2>&1 | Out-String
$hbt = (Get-Content -Raw $hbf) -replace '\d{4}-\d\d-\d\dT[\d:.+\-Z]+', 'T' -replace '\d{4}-\d\d-\d\d \d\d:\d\d', 'T' -replace '(?m)^\| T \|', '| T |'
Expect "checkpoint -Notes -Brief: golden resume brief (Done table, Open, Notes as one line) ($($hbo.Trim()))" ($hbo -match 'resume brief: .*board leave -Handoff' -and (Gold $hbt "# Resume brief: h8 (run ``r8``)`n**Result:** Next: review (start here; the steps below are done: verify, never redo) · T`n`n## Done`n`n| At | Step | Item | Evidence | Worktree @ head |`n|---|---|---|---|---|`n| T | commit | — | abc1234 | — |`n| T | mr | — | web!5 | — |`n`n## Open`n`n**Worktrees:** `n**Leases:** `n**Decisions pending:** `n`n## Notes`n`n- T rebase pending then push"))
Remove-TestKit $k
Complete-Tests
