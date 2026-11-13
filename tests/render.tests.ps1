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
Remove-TestKit $k
Complete-Tests
