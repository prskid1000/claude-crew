#Requires -Version 7
<#
render.tests.ps1: agent-written artefacts rendered from small specs (devtools.py "render") and supervise page fixes: golden text per renderer, the
same spec -> the same text on every adapter, the gates judge the rendered text.
Usage: pwsh -NoProfile -File <kit>/tests/render.tests.ps1 (or tests/kit-tests.ps1 -Area render).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/gitlab.ps1')   # mr.url: full MR links
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
Expect 'cases render ai: golden text (case # names its human check, evidence image inline / link named by type, a pipe escaped, Rounds row)' (Gold $ai @"
# Testing doc (AI): T1 Sort orders

Setup and cleanup: order rows via the API, deleted after.

Cases:

| # | Type | Steps / API call + payload | Expected | Result | Evidence |
|---|---|---|---|---|---|
| A1 (T1) | positive | click Date | newest first | PASS | ![A1](https://x/a1.png) |
| A2 | negative | GET /orders?sort=x | 400 \| bad sort | PASS | [json](https://x/a2.json) |

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

Do each check in the app as a user would; a screenshot of what you see, every check; network or log JSON from that action only as extra evidence. "No UI trigger": check the visible effect it names.

Orders screen:

| # | UI steps | Expected on screen | Screenshot | Extra evidence | Result |
|---|---|---|---|---|---|
| T1 | 1. Open Orders 2. Click Date | newest first |  |  |  |

## Out of scope

none

## Result (testers)

All checks pass -> close the task. A check of this change fails or could not be tested -> failedTesting with the check ids and why. A defect outside this change -> one [Bug] task under the original ask.
"@)
Expect 'cases render goals: a goal per human check (its result from the AI rows naming it) and quality, the rounds' ($go -match '(?m)^\| G1 \(T1\) \| newest first \| UI: 1\. Open Orders 2\. Click Date · A1 \| newest first \| PASS \|$' -and $go -match '(?m)^\| Q1 \| list loads fast \| 5 timings \| p95 <= 2 s \|  \|$' -and $go -match '(?m)^- unit: OrderSortTest$' -and $go -match '(?m)^\| 1 \| none \| abc1234 \|$')
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
$art = @($sl | Where-Object name -eq 'artefacts' | ForEach-Object { "$($_.level) $($_.file)" }) -join '; '; $artWhy = @($sl | Where-Object name -eq 'artefacts' | ForEach-Object problem) -join ' '
Expect "state lint drift guard: an unlisted shape in a shared place BAD (exit 1), agent scratch / loose work files WARN, listed shapes pass ($art)" ($slc -eq 1 -and $art -match 'BAD work/qa-runs/r2/lead-notes.md' -and $art -match 'BAD work/qa-runs/r1/fix-round.md' -and $art -match 'WARN work/agents/a1/free.md' -and $art -match 'WARN work/loose.py' -and $art -notmatch 'r1/lead-notes|mr\.md|spec\.json|T1_testing|run\.json' -and $artWhy -match 'unlisted shape: no STATE\.md "Artefacts" row names its writer')
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
# owner, 2026-11-15: a configured host turns every bare MR ref into a full-URL link (solution, status, MR body siblings)
Set-JsonFile "$k/skills/crafty/kit.local.json" @{ gitHostType = 'gitlab'; gitHost = 'git.example'; gitlabGroup = 'g' }; Set-JsonFile "$wd/st3.json" @{ status = 'promoted'; why = 'web!5 merged'; link = 'api!4' }
$lu = { param($r, $n) "[$r!$n](https://git.example/g/$r/-/merge_requests/$n)" }; $cs4 = Dt render comment-solution "$wd/sol.json"; $cs5 = Dt render comment-status "$wd/st3.json"; $mb2 = Dt render mr-body "$wd/mr.json"; Remove-Item "$k/skills/crafty/kit.local.json"
Expect "render with a git host: MR refs are full-URL links in comment-solution, comment-status and the MR body's siblings ($($cs5.out))" ($cs4.out.Contains("**MRs:** $(& $lu web 5) (MERGED) · $(& $lu api 4) (OPEN)") -and $cs5.out.Contains("promoted — $(& $lu web 5) merged · $(& $lu api 4)") -and $mb2.out.Contains("**Sibling MRs:** $(& $lu api 4) (merge order"))
# ---- run-file schemas (items 10, 17, 19): required + allowed keys; another key = drift (BAD, supervise WATCH)
$qr = TkPath $k qa-runs -Create; New-Item -ItemType Directory -Force "$qr/r3/A1" | Out-Null
Set-JsonFile "$qr/r3/A1/results.json" @{ code = 'A1'; checks = @(); colour = 'red' }; Set-JsonFile "$qr/r3/run.json" @{ title = 't'; runDir = 'r3'; items = @() }
Set-JsonFile (Join-Path (TkPath $k programs -Create) 'p1.json') @{ wave = 1 }
Set-JsonFile (Join-Path (TkPath $k decisions -Create) 'd.json') @{ schemaVersion = 2; id = 'd'; status = 'answered'; question = 'q'; scopeId = 's'; rationale = 'r' }
$s10 = @(& $py -X utf8 $KB state lint --json 2>$null | ConvertFrom-Json | ForEach-Object { "$($_.name)|$($_.problem)" }) -join "`n"
Expect "state lint schemas: an unknown results.json key is drift, a program lacks updated, a listed run.json, a scope decision pass" ($s10 -match 'qa-runs:results\|drift: key\(s\) colour' -and $s10 -match 'programs\|missing updated' -and $s10 -notmatch '(?m)qa-runs:run\|drift|^decisions\|')
# ---- kitty to-do / handoff lists (item 21): one item shape, written by kitbag.py state todo, linted
$td = Join-Path $wd 'todo.md'; $t1 = & $py -X utf8 $KB state todo add $td R1 'render the wave brief' 'kit-render-all.md:10' 2>&1; $null = & $py -X utf8 $KB state todo add $td R2 'retro report' 'item 9' 2>&1
$t2 = & $py -X utf8 $KB state todo done $td R1 'kit abc1234' 2>&1; $t3 = & $py -X utf8 $KB state todo add $td R2 'again' 'x' 2>&1; $t3c = $LASTEXITCODE
$tl0 = & $py -X utf8 $KB state todo lint $td 2>&1; $tl0c = $LASTEXITCODE; Add-Content $td '- [ ] free text item'; $tl1 = & $py -X utf8 $KB state todo lint $td 2>&1; $tl1c = $LASTEXITCODE
Expect "state todo: add / done render '- [ ] <code> · <desc> · <ref>', a dup code refused; lint fails on a free line ($tl0c $tl1c)" ((Gold ((Get-Content -Raw $td) -replace '(?m)^- \[ \] free text item\r?\n?', '') "# Kit to-do`n`n- [x] R1 · render the wave brief · kit abc1234`n- [ ] R2 · retro report · item 9") -and $t3c -ne 0 -and $tl0c -eq 0 -and $tl1c -eq 1 -and "$tl1" -match 'TODO-SHAPE - \[ \] free text item')
$t4 = & $py -X utf8 $KB state todo add $td R3 'no ref given' 2>&1 | Out-String; $t4c = $LASTEXITCODE
Expect "state todo add: a missing field is named, with one filled example line ($t4c)" ($t4c -ne 0 -and $t4 -match 'state todo add: missing ref;' -and $t4 -match 'e\.g\. kitbag\.py state todo add todo\.md L1 ')
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
# a hand-written brief at -Brief keeps its text; the rendered part follows a marker and is replaced on the next checkpoint (retro 2026-11-17 10:12)
$hwf = Join-Path $wd 'own-h9.md'; [IO.File]::WriteAllText($hwf, "# My plan`n- keep me`n"); foreach ($stp in 'commit', 'mr') { $null = pwsh -NoProfile -File $craftyPs checkpoint -Agent h9 -Run r9 -Step $stp -Brief $hwf 2>&1 }
$hwt = Get-Content -Raw $hwf
Expect 'checkpoint -Brief on a hand-written brief: its text kept, one rendered part after the marker' ($hwt.StartsWith("# My plan`n- keep me`n`n<!-- checkpoint") -and ([regex]::Matches($hwt, '# Resume brief: h9')).Count -eq 1 -and ([regex]::Matches($hwt, '<!-- checkpoint')).Count -eq 1 -and $hwt -match '\| mr \|')
$hlNoRun = & { . (Join-Path $k 'skills/bossy/bossy.ps1'); Get-KitHandoffLine ([pscustomobject]@{ agent = 'h8'; run = '' }) 's8' 'why' }
Expect "HANDOFF line: the checkpoint call it names drops -Run when the agent has none ($hlNoRun)" ($hlNoRun -match 'checkpoint -Agent h8 -Step <last done>' -and $hlNoRun -notmatch '-Run ')
if (Use-BrowserKit) {   # kitbag.py ui-check on a canvas page
  $uiKb = Join-Path $k 'skills/bossy/kitbag.py'
  $uiLay = Join-Path (Kd) 'boxes.html'   # a canvas page's window.uiBoxes: one box off-screen, one pair overlapping; a label on its own node passes
  [IO.File]::WriteAllText($uiLay, '<!doctype html><body><figure style="position:relative;width:60px"><figcaption>k <i style="position:absolute;left:200px">stray</i></figcaption></figure><script>window.uiBoxes = () => ({view: [0, 0, 300, 300], boxes: [{id: "node a", key: "a", b: [10, 10, 20, 20]}, {id: "label a", own: "a", b: [5, 25, 40, 12]}, {id: "node b", key: "b", b: [60, 60, 20, 20]}, {id: "node c", key: "c", b: [70, 70, 20, 20]}, {id: "node far", key: "f", b: [290, 100, 20, 20]}]}); window.uiChecks = () => matchMedia("(pointer: coarse)").matches ? [{el: "x", why: "coarse", text: ""}] : []</script></body>')
  $uiLayOut = @(& $py -X utf8 $uiKb ui-check $uiLay --widths 390 2>&1); $uiLayCode = $LASTEXITCODE
  # a page at rest, never a fixed sleep: a details the page closes again is not waited for; a toggle's pending work (uiBusy) is; a 60 s transition = a finding, no hang
  $uiRest = Join-Path (Kd) 'rest.html'
  [IO.File]::WriteAllText($uiRest, '<!doctype html><body><details id=a><summary>a</summary>a</details><details id=b><summary>b</summary>b</details><details id=c><summary>c</summary><div id=w style="width:10px;transition:width 60s linear">x</div></details><script>let pend = 0; window.uiBusy = () => pend > 0; a.addEventListener("toggle", () => { if (a.open) a.open = false }); b.addEventListener("toggle", () => { pend++; setTimeout(() => { pend--; document.body.dataset.ok = 1 }, 300) }); c.addEventListener("toggle", () => { w.style.width = "200px" }); window.uiChecks = () => document.body.dataset.ok ? [] : [{el: "b", why: "read before its toggle work ended", text: ""}]</script></body>')
  $uiRestOut = @(& $py -X utf8 $uiKb ui-check $uiRest --widths 1366 2>&1); $uiRestCode = $LASTEXITCODE
  Expect "ui-check: waits for toggle work (uiBusy), skips a details the page closed, a 60 s transition = 'never settled' (exit $uiRestCode; $(@($uiRestOut -cmatch 'CLIP|failed') -join ' | '))" ($uiRestCode -eq 1 -and @($uiRestOut -cmatch 'CLIP page: never settled with every details open').Count -eq 2 -and @($uiRestOut -cmatch 'CLIP').Count -eq 2)
  # D8 (owner 2026-11-19): a one-line ellipsis passes when it fits or a title on it or its tile holds the full text; else it is clipped text
  $uiEll = Join-Path (Kd) 'ellipsis.html'; $es = 'style="width:60px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis"'
  [IO.File]::WriteAllText($uiEll, "<!doctype html><body><p $es title='a long label here'>a long label here</p><div title='tile: b long label there'><span $es>b long label there</span></div><p $es>ok</p><p $es>c long label, no title</p></body>")
  $uiEllOut = @(& $py -X utf8 $uiKb ui-check $uiEll --widths 1366 2>&1)
  Expect "ui-check: an ellipsis with its full text in a title passes, without one it is flagged ($(@($uiEllOut -cmatch 'CLIP') -join ' | '))" (@($uiEllOut -cmatch 'CLIP p: text-overflow: ellipsis without a title holding the full text \(c long').Count -eq 2 -and @($uiEllOut -cmatch 'CLIP').Count -eq 2)
  Expect "ui-check: uiBoxes off-screen / overlap fail (a label on its own node passes), uiChecks issues count, 390 px = touch, an absolute mark outside its parent = stray (exit $uiLayCode)" ($uiLayCode -eq 1 -and @($uiLayOut -match 'CLIP stray: absolute element').Count -eq 2 -and @($uiLayOut -match 'CLIP x: coarse').Count -eq 2 -and @($uiLayOut -match 'CLIP layout: off-screen \(node far\)').Count -eq 2 -and @($uiLayOut -match 'CLIP layout: overlap \(node b x node c\)').Count -eq 2 -and @($uiLayOut -match 'CLIP layout').Count -eq 4)
}
# owner 2026-11-13: a STOPPED agent idle 1 h is finished, idle 5 min live; one deferred item whole; same-kind notes one line; release command once; no machine header count; the legend mark is no chart dot
$dashFix = (Invoke-PsTest dashfix @'
. $args[0]
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00'; agents = @(@{ name = 'k2 (kitty)'; state = 'STOPPED'; last = '2026-01-02T09:00:00' }, @{ name = 'k3 (kitty)'; state = 'STOPPED'; last = '2026-01-02T09:55:00' }, @{ name = 'k1 (kitty)'; state = 'ACTIVE' }); history = @(@{ flags = @() }, @{ flags = @() })
  flags = @(@{ level = 'INFO'; what = "HOLD t1: promotion held (deferred items: pin 744); release: bossy.ps1 track add -Task t1 -HoldPromotion ''" }, @{ level = 'INFO'; what = 'RAM FLOOR: rm moved 8 GB (why)' }, @{ level = 'INFO'; what = 'RAM FLOOR: hm moved 8 GB (why)' }) })
"$($h -match ">k2<small>kitty</small><span class='chip s-fin'>finished</span>" -and $h -match ">k3<small>kitty</small><span class='chip s-oth'>STOPPED</span>") $($h -match '<span class=hw>pin 744</span>') $($h -match 'colspan=5>RAM FLOOR: rm, hm moved 8 GB \(why\)</td>') $(([regex]::Matches($h, 'track add -Task')).Count) $($h -match "<h2>Machine and resources</h2></summary>") $($h -match "id=sec-flagmap><summary><h4>Flags &#183; 24 h</h4><span class=cnt>\(0\)" -and $h -notmatch 'flags raised per sweep')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join ' '
Expect "supervise page: stale STOPPED agent finished, one hold item whole, notes grouped, release once, no machine header count, the flags heatmap (no line chart) ($dashFix)" ($dashFix -eq 'True True True 1 True True')
# ---- lessons and signals (items 7, 18): one lesson shape (lint), signals <= 400 chars with a fixed key set (state lint)
$bossyPs = Join-Path $k 'skills/bossy/bossy.ps1'; $null = pwsh -NoProfile -File $bossyPs learn -Skill kitty -Kind idea -Text ('z' * 401) 2>&1; $sigLongCode = $LASTEXITCODE
$null = pwsh -NoProfile -File $bossyPs learn -Skill kitty -Kind idea -Text 'short one' 2>&1
Add-Content (TkPath $k signals) '{"at":"2026-11-13T10:00:00Z","skill":"kitty","kind":"idea","text":"x","colour":"red"}'
$sigLint = @(& $py -X utf8 $KB state lint --json 2>$null | ConvertFrom-Json | Where-Object name -eq 'signals' | ForEach-Object problem) -join ' '
$shape = python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KB)'); import kitbag as k; print([bool(k.LESSON_SHAPE.match(x)) for x in ('- a case -> do it (why) (2×)', '- free text (2×)', '- a -> b (3x)', '- (fixed in kit) a -> b (why)')])"
Expect "learn: -Text over 400 chars refused (2); signals: a key outside the schema is drift; LESSON-SHAPE wants '<when> -> <do> (<why>)', a count is no why ($shape)" ($sigLongCode -eq 2 -and $sigLint -match 'drift: key\(s\) colour' -and "$shape".Trim() -eq '[True, False, False, True]')
# ---- wave brief (item 6): one spec -> brief + contracts + /buildy args
Set-JsonFile "$wd/wb.json" ([ordered]@{ name = 'orders-sort'; date = '2026-11-13'; items = 'T-1 epic'; decisions = 'none'; localEnv = 'r3'; testEnv = 'stg'; kitDir = 'K'
  repos = @([ordered]@{ repo = 'web'; checkout = 'R/web'; target = 'main'; migrations = 'none' }); agents = @([ordered]@{ id = 'X1'; items = 'A1'; area = 'orders screen'; repos = 'web'; services = 'api'; complex = 'new grid' }, [ordered]@{ id = 'X2'; items = 'A2'; area = 'api sort'; repos = 'api'; dependsOn = @('X1'); migrations = $true; debate = [ordered]@{ item = 'A2'; options = 'A: x', 'B: y' } })
  contracts = @([ordered]@{ name = 'GET /orders?sort'; type = 'query'; producer = 'X2'; consumers = 'X1'; order = 'X2 first'; compatible = $true }); openQuestions = @([ordered]@{ question = 'Which index?'; blocks = 'A2'; answers = 'rechy' }); mandate = @('sort orders'); mode = 'feature' })
$wbo = Dt render wave-brief "$wd/wb.json" "$wd/wb.md"; $wbArgs = Get-Content -Raw "$wd/wb.args.json" | ConvertFrom-Json
Expect "render wave-brief: golden brief + contracts; args = brief, agents (empty keys dropped, debate kept), mode, mandate, rechy questions ($($wbo.code))" ($wbo.code -eq 0 -and (Gold (Get-Content -Raw "$wd/wb.md") @"
# Wave brief: orders-sort, 2026-11-13
**Read first:** ``K/skills/crafty/SKILL.md``; this brief wins where they differ.
**Items:** T-1 epic · **Decisions:** none; final, don't re-ask (a NEW choice -> crafty D1).
**Local env:** r3 · **Test env after deploy:** stg (never production).
## Repos
| Repo | Main checkout | Target | Link deps from | Migrations |
|---|---|---|---|---|
| web | R/web | main |  | none |
## Agents
| Agent | Items | Area (screens / packages / files) | Paths (enforced) | Repos | Migration range | Services (leased, nothing else) | Complex? |
|---|---|---|---|---|---|---|---|
| X1 | A1 | orders screen | any | web |  | api | yes: new grid |
| X2 | A2 | api sort | any | api |  |  | no |

**Overlaps:** none · **Contracts:** ``wb.contracts.md`` (1 crossing)
**Branch:** ``f/<tag><task>-<slug>``, pool slots leased as the agent id · **Tracker:** —.
Rule changes during the wave are appended below and to the contracts file: re-read both before every push.

## openQuestions
Which index? · blocks A2 · answers: rechy
## Findings (rechy)
none yet
## Rule changes during the wave (newest last)
"@) -and (Gold (Get-Content -Raw "$wd/wb.contracts.md") "# Contracts: orders-sort`n| Field / endpoint | Type | Producer | Consumers | Merge / deploy order | Backward-compatible |`n|---|---|---|---|---|---|`n| GET /orders?sort | query | X2 | X1 | X2 first | yes |`n## Rule changes during the wave (newest last)") -and
  $wbArgs.brief -like '*/wb.md' -and ($wbArgs.agents[1] | ConvertTo-Json -Compress) -eq '{"id":"X2","items":"A2","area":"api sort","dependsOn":["X1"],"migrations":true,"debate":{"item":"A2","options":["A: x","B: y"]}}' -and $wbArgs.openQuestions[0] -eq 'Which index?' -and $wbArgs.mandate[0] -eq 'sort orders')
foreach ($n in 'a', 'b', 'c') { Set-JsonFile "$wd/s$n.json" @{ title = $n; checks = @(@{ id = $(if ($n -eq 'c') { 'S2' } else { 'S1' }) }) } }
$s = foreach ($n in 'AA:a', 'BB:b', 'BB:c') { $env:CLAUDE_AGENT, $f = $n -split ':'; Dt cases add T7 "$wd/s$f.json" }; $env:CLAUDE_AGENT = $null
Expect 'cases add, shared task: another agent''s id refused, its title kept' ($s[1].out -match 'S1 \(AA\) belong to another' -and $s[2].out -match "title kept \('a', set by AA")
$nf = Dt render commit (Join-Path $wd 'nope.json')
Expect 'render: a missing spec file = usage (exit 2), no traceback' ($nf.code -eq 2 -and $nf.out -match 'no such spec file' -and $nf.out -notmatch 'Traceback')
# supervise page parts (moved from dashboard.tests.ps1: its cap)
$O = Join-Path $k 'skills/bossy/bossy.ps1'
# Tuning K100: a row per changed key + scope, latest first, a day cell old→new up / down, "→default" = reset; bad dates skipped.
# Settings: key tables, changed first, scope | path, last change old → new
$tnp = & { . $O; $n = [datetime]'2026-01-02T10:00:00'; $pf = Get-KitPath params-changes; New-Item -ItemType Directory -Force (Split-Path $pf) | Out-Null; $gx = 'mvn|svc-code/shop/api'
  @(@{ at = $n.AddDays(-1).ToString('o'); key = 'gate.needGB'; ctx = $gx; from = $null; to = 5.91 }, @{ at = $n.AddHours(-1).ToString('o'); key = 'gate.needGB'; ctx = $gx; from = 5.91; to = 6 }, @{ at = $n.ToString('o'); key = 'gate.needGB'; ctx = $gx; from = 6; to = 5.32 }, @{ at = $n.AddMinutes(-30).ToString('o'); key = 'a.b'; ctx = ''; from = 5.91; to = $null }, @{ at = $n.AddHours(-2).ToString('o'); key = 'c.d'; to = 'abc' }, @{ at = $n.AddHours(-2).ToString('o'); key = 'c.d'; from = 'abc'; to = 'xyz' }, @{ at = 'bad'; key = 'gate.needGB'; ctx = $gx; to = 9 }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $pf
  $pd = @(Get-KitParamDays $n); $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ paramDays = $pd; params = @(@{ key = 'gate.needGB'; ctx = 'mvn'; value = 6; source = 'live'; changed = $n.ToString('o') }, @{ key = 'gate.needGB'; ctx = $gx; value = 5.32; default = 4; source = 'live'; changed = $n.ToString('o') }, @{ key = 'foo'; ctx = '<b>'; value = 1 }) } })
  $row = { param($lb) [regex]::Match($h, "<span class=gn title='[^']*'>$lb</span>.*?</div>").Value }; $g0 = & $row 'needGB &#183; mvn &#183; shop/api'; $a0 = & $row 'b'
  "$(@($pd.key) -join ',') $($h.IndexOf('>needGB &#183;') -lt $h.IndexOf('>b</span>')) $($g0 -match '<i data-d=dn class=nw [^>]*>5\.91→​5\.32</i>' -and $g0 -match '<i data-d=ch [^>]*>→5\.91</i>' -and $g0 -match "<span class='gc'>5\.32</span>" -and $g0 -match 'gate\.needGB \[mvn\|svc-code/shop/api\] = 5\.32') $($a0 -match '<i data-d=rs [^>]*>→default</i>' -and $a0 -match "<span class='gc'>default</span>") $($h -notmatch 'class=tcs') $($h -match "<tr class='f c7' data-k='gate\.needGB'><td class='tk'[^>]*><i class=cmk[^/]*/i>needGB<span[^/]*/span></td><td class=pth>mvn</td><td class=pth></td><td class=tv>6<" -and $h -match "'tk rep'[^/]*/i>needGB<span hidden>[^<]*</span></td><td class=pth>mvn</td><td class=pth title='svc-code/shop/api'>svc-code/shop/api</td><td class=tv>5\.32</td><td class=tv>4</td>.{9,99}learned</td><td data-s='[^']+'>[^<]*6 (→|&#8594;) 5\.32</td>" -and $h -match '<td class=pth>&lt;b&gt;</td>' -and $h.IndexOf('id=tg-gate') -lt $h.IndexOf('id=tg-foo'))" }
Expect "Tuning: a row per changed key + scope, latest first, old→new cells up / down / reset, the value now, no chips, tiles escaped ($tnp)" ($tnp -eq 'gate.needGB,a.b,c.d True True True True True')
$cpn = & { . $O; (@(999600, 999960000, 12345, 9.96, 0) | ForEach-Object { Format-KitCompactNum $_ }) -join '/' }
Expect "compact day numbers round before the unit (no 1000k / 1000M) ($cpn)" ($cpn -eq '1M/1B/12k/10/')
Remove-TestKit $k
Complete-Tests
