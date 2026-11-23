#Requires -Version 7
<#
specs.tests.ps1: spec docs (devtools.py spec): the standard layout, versions + change log, S-id traceability into cases, MR bodies,
commits and the finish gate, standing subject specs linked to tasks, retest marks on a changed S-id.
Usage: pwsh -NoProfile -File <kit>/tests/specs.tests.ps1 (or tests/kit-tests.ps1 -Area specs).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit specs; $DT = Join-Path $k 'skills/crafty/devtools.py'; $wd = Join-Path (Kd) 'w'; New-Item -ItemType Directory -Force $wd | Out-Null
$docs = TkPath $k docs
function Dt { $o = & $py -X utf8 $DT @args 2>&1 | Out-String; [pscustomobject]@{ out = $o.Trim(); code = $LASTEXITCODE } }

# ---- write: a bad S-id refused; a draft renders every section, open ones as their question (the interview)
$heads = @('Goal', 'Scope', 'Non-goals', 'Users and flows', 'Behaviour rules and acceptance', 'Options and trade-offs', 'Implementation approach', 'Impacted modules / APIs / data',
  'Data / API contracts', 'UI', 'Edge cases', 'Risks', 'Rollout and feature flag', 'Test strategy', 'Diagrams', 'Bug', 'Decisions', 'Open questions', 'Change log')
Set-JsonFile "$wd/s0.json" @{ kind = 'feature'; title = 'Sort orders'; rules = @(@{ id = 'X1'; text = 'sorts' }) }
$r0 = Dt spec write T1 "$wd/s0.json"
Expect "spec write: a rule id that is no S<n> is refused, nothing written ($($r0.code))" ($r0.code -ne 0 -and $r0.out -match "rule id 'X1'" -and (Dt spec show T1).out -match 'no spec')
Set-JsonFile "$wd/d0.json" @{ kind = 'bug'; title = 'Totals off'; goal = 'totals match'; risks = @{ na = '' }; rules = @(@{ id = 'S1'; text = 'total = sum of lines' }) }
$rd = Dt spec write T9 "$wd/d0.json"; $dd = Get-Content -Raw (Join-Path $docs 'T9-spec.md'); $dq = Dt spec questions T9
Expect "spec draft: every section heading, open ones as questions, n/a without reason is open; questions exit 1 ($($rd.code)$($dq.code))" ($rd.code -eq 0 -and
  @($heads | Where-Object { $dd -notmatch "(?m)^## $([regex]::Escape($_))$" }).Count -eq 0 -and $dd -match '\| Status \| draft · \d+ open' -and $dd -match '(?m)^\*\*Open:\*\* Which design choices exist' -and
  $dd -match '(?m)^\*\*Open:\*\* Repro steps' -and $dq.code -eq 1 -and $dq.out -match 'Q\d+ S1: acceptance\?' -and $dq.out -match 'Q\d+ Risks: .* \(n/a needs its reason\)' -and $dq.out -match 'Q\d+ Bug: ')
Set-JsonFile "$wd/d1.json" @{ rules = @(@{ id = 'S1'; acceptance = 'Given 2 lines Then total = their sum' }); change = 'interview answer' }
$r9 = Dt spec write T9 "$wd/d1.json"
Expect 'spec: an interview answer to a draft is v2 with no RETEST mark' ($r9.code -eq 0 -and $r9.out -match 'spec T9 v2' -and $r9.out -notmatch 'RETEST' -and (Dt spec show T9).out -notmatch 'retest')
$lb = & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d; print(d.links_block('Spec: the list must sort\n**Spec:** [open](https://x/s) · v1\nBody', {'spec': '[open](https://x/s) · v2'}))" 2>&1 | Out-String
Expect "links_block: the Spec link line is replaced, a person's own 'Spec:' line stays ($($lb.Trim() -replace '\s+', ' '))" ($lb -match '(?s)^\*\*Spec:\*\* \[open\]\(https://x/s\) · v2\s+Spec: the list must sort\s+Body' -and $lb -notmatch 'v1')
$s1 = @{ kind = 'feature'; title = 'Sort orders'; goal = 'newest orders first'; scope = @('orders list'); nonGoals = @('export')
  users = @(@{ who = 'dispatcher'; flow = 'opens Orders, reads newest' })
  rules = @(@{ id = 'S1'; text = 'the list sorts by date, newest first'; acceptance = 'Given 2 orders When Orders opens Then the newer is on top' },
            @{ id = 'S2'; text = 'a Date header click flips the order'; acceptance = 'Given the list When Date is clicked Then oldest first' })
  options = @(@{ choice = 'where to sort'; options = @(@{ id = 'A'; text = 'server'; pros = 'paging'; cons = 'API change' }, @{ id = 'B'; text = 'client'; pros = 'no API'; cons = 'one page' }); chosen = 'A'; why = 'paging'; rejected = 'B: one page only'; revisit = 'never' })
  approach = 'sort param on GET /orders'; impact = @('OrderController', 'orders.created_at index'); risks = @(@{ text = 'slow sort'; mitigation = 'index' })
  rollout = @{ flag = 'sortV2'; enable = 'Settings > Orders'; rollback = 'flag off' }; tests = @('unit', 'API', 'UI'); diagrams = @(@{ title = 'Sort flow'; mermaid = 'flowchart LR; A-->B' })
  decisions = @{ na = 'no choice left' }; questions = @()
  contracts = @(@{ name = 'GET /orders sort'; ref = 'wave.contracts.md row 1' }); ui = @{ screens = 'Orders'; states = 'empty, loaded'; theme = 'app theme colours only' }
  edges = @(@{ text = 'two orders with one timestamp'; rule = 'S1' }) }
Set-JsonFile "$wd/s1.json" $s1
$r1 = Dt spec write T1 "$wd/s1.json" --by briefy-1
$doc = Get-Content -Raw (Join-Path $docs 'T1-spec.md') -ErrorAction SilentlyContinue
Expect "spec write v1 ready: standard sections, options table, Mermaid source, n/a with reason, change log row ($($r1.code))" ($r1.code -eq 0 -and $doc -match '(?m)^# T1 Spec v1 — Sort orders' -and
  @($heads | Where-Object { $doc -notmatch "(?m)^## $([regex]::Escape($_))$" }).Count -eq 0 -and $doc -match '\| Status \| ready \|' -and $doc -match '\| S2 \| a Date header click' -and
  $doc -match '\*\*where to sort\*\* · chosen: A' -and $doc -match '\| B \| client \| no API \| one page \|' -and $doc -match '```mermaid\s+flowchart LR; A-->B' -and $doc -match 'n/a — not a bug' -and
  $doc -match 'n/a — no choice left' -and $doc -match '\| v1 \| \S+ \| briefy-1 \| first version \| S1, S2 \|' -and $doc -match 'two orders with one timestamp \(S1\)' -and (Dt spec questions T1).code -eq 0)
$sh = Dt spec show T1
Expect "spec show: version, ready and S-ids ($($sh.out))" ($sh.code -eq 0 -and $sh.out -match 'T1:spec v1 ready .* S-ids S1, S2')

# ---- change: a change line is required; the touched S-id is logged and marked for retest
Set-JsonFile "$wd/s2.json" @{ rules = @(@{ id = 'S2'; acceptance = 'Given the list When Date is clicked twice Then newest first again' }) }
$r2 = Dt spec write T1 "$wd/s2.json"
Set-JsonFile "$wd/s3.json" @{ rules = @(@{ id = 'S2'; acceptance = 'Given the list When Date is clicked twice Then newest first again' }); change = 'owner: a second click restores the order' }
$r3 = Dt spec write T1 "$wd/s3.json" --by briefy-1; $doc = Get-Content -Raw (Join-Path $docs 'T1-spec.md')
Expect "spec v2: refused without a change line; with one: RETEST S2, change log v2 names S2 only ($($r2.code)$($r3.code))" ($r2.code -ne 0 -and $r2.out -match 'needs a "change" line' -and
  $r3.code -eq 0 -and $r3.out -match 'RETEST T1: S2 \(spec T1 v2\)' -and $doc -match '(?m)^# T1 Spec v2' -and $doc -match '\| v2 \| \S+ \| briefy-1 \| owner: a second click restores the order \| S2 \|' -and (Dt spec show T1).out -match 'retest S2 \(v2\)')
$r4 = Dt spec write T1 "$wd/s3.json"
Expect 'spec write: the same content again is no new version' ($r4.code -eq 0 -and $r4.out -match 'unchanged \(v2\)')

# ---- traceability: cases cite S-ids in every rendered doc; gaps name the uncited one
$cs = @{ title = 'Sort orders'; checks = @(@{ id = 'T1'; area = 'Orders'; steps = 'Open Orders'; expected = 'newest first'; spec = 'S1' })
  cases = @(@{ id = 'A1'; type = 'positive'; check = 'T1'; steps = 'open'; expected = 'newest first'; spec = @('S1') }, @{ id = 'A2'; type = 'negative'; steps = 'bad sort'; expected = '400'; spec = 'X9' }) }
Set-JsonFile "$wd/c1.json" $cs; $ca = Dt cases add T1 "$wd/c1.json"
Expect 'cases add: a spec ref that is no S-id is a spec gap' ($ca.out -match "spec 'X9' is no S-id")
$cs.cases[1].spec = 'S1'; Set-JsonFile "$wd/c1.json" $cs; $ca = Dt cases add T1 "$wd/c1.json"
$hu = Get-Content -Raw (Dt cases render T1 human).out; $ai = Get-Content -Raw (Dt cases render T1 ai).out; $g = Dt spec trace T1
Expect "cases cite S-ids (human + AI rows); spec trace + cases add WARN name S2 ($($g.code))" ($hu -match '\| T1 \| Open Orders \| newest first \[S1\] \|' -and $ai -match '\| A1 \(T1\) \| positive \| open \| newest first \[S1\] \|' -and
  $ca.out -match 'WARN cases T1: spec S-id\(s\) S2' -and $g.code -eq 1 -and $g.out -match 'T1: S2 has no test case')
$cs.cases += @{ id = 'A3'; type = 'edge'; steps = 'click Date twice'; expected = 'newest first'; spec = 'S2' }; Set-JsonFile "$wd/c1.json" $cs; $null = Dt cases add T1 "$wd/c1.json"
Expect 'spec trace: every S-id cited -> exit 0' ((Dt spec trace T1).code -eq 0)

# ---- standing subject spec linked to a task: only the ids it names count; a change marks that task
$sub = @{ kind = 'subject'; title = 'Orders list'; goal = 'one behaviour for every orders screen'
  rules = @(@{ id = 'S1'; text = 'rows page by 50'; acceptance = 'Given 51 orders Then page 2 holds 1' }, @{ id = 'S2'; text = 'filters persist'; acceptance = 'Given a filter When reopened Then kept' }) }
foreach ($f in 'scope', 'nonGoals', 'users', 'options', 'approach', 'impact', 'contracts', 'ui', 'edges', 'risks', 'rollout', 'tests', 'diagrams', 'decisions', 'questions') { $sub[$f] = @{ na = 'subject-wide rules only' } }
Set-JsonFile "$wd/sub.json" $sub
$sw = Dt spec write orders-list "$wd/sub.json" --subject; $ln = Dt spec link T2 orders-list --ids S2; $gp = Dt spec trace T2
Set-JsonFile "$wd/sub2.json" @{ rules = @(@{ id = 'S1'; text = 'rows page by 100'; acceptance = 'Given 101 orders Then page 2 holds 1' }); change = 'page size 100' }
$s2w = Dt spec write orders-list "$wd/sub2.json"
Set-JsonFile "$wd/sub3.json" @{ rules = @(@{ id = 'S2'; text = 'filters persist per user'; acceptance = 'Given a filter When reopened Then kept' }); change = 'per user' }
$s3w = Dt spec write orders-list "$wd/sub3.json"
Expect "subject spec: link names S2; trace wants S2 only; a change to S1 marks nothing, to S2 marks T2 ($($sw.code)$($ln.code))" ($sw.code + $ln.code -eq 0 -and $ln.out -match 'orders-list v1 linked on T2 \(S2\)' -and
  $gp.out -match 'T2: S2 has no test case' -and $gp.out -notmatch 'S1' -and $s2w.out -notmatch 'RETEST' -and $s3w.out -match 'RETEST T2: S2 \(spec orders-list v3\)' -and (Dt spec show T2).out -match 'orders-list:spec v3')

# ---- thin brief: spec links per task; the args file is what buildy accepts (`run`, never `name`)
Set-JsonFile "$wd/wb.json" @{ name = 'orders-sort'; run = 'buildy-20261123-01'; mandate = @('sort orders'); specs = @('T1'); agents = @(@{ id = 'area-01'; items = 'T1'; area = 'Orders'; repos = 'web'; kind = 'foundation' })
  openQuestions = @('Which index serves the sort?', @{ question = 'Page size?'; answers = 'owner' }, @{ question = 'Is the lib licensed?'; answers = 'rechy' }) }
$wb = Dt render wave-brief "$wd/wb.json" "$wd/brief.md"; $wa = Get-Content -Raw "$wd/brief.args.json" | ConvertFrom-Json -AsHashtable
$ok = ([regex]::Match((Get-Content -Raw (Join-Path $PSScriptRoot '../workflows/buildy.js')), "unk\(A0, '([^']+)'\)").Groups[1].Value -split ' ')
Expect "wave-brief: Specs line with version; args carry run (no name), agents' kind, rechy openQuestions (a plain string too), only keys buildy accepts ($($wb.code))" ($wb.code -eq 0 -and
  (Get-Content -Raw "$wd/brief.md") -match '\*\*Specs\*\* .*T1 v2 ' -and $wa.run -eq 'buildy-20261123-01' -and -not $wa.ContainsKey('name') -and $wa.agents[0].kind -eq 'foundation' -and
  "$($wa.openQuestions -join '|')" -eq 'Which index serves the sort?|Is the lib licensed?' -and $ok.Count -gt 5 -and @($wa.Keys | Where-Object { $_ -notin $ok }).Count -eq 0)
Set-JsonFile "$wd/wb2.json" @{ name = 'totals'; mandate = @('fix totals'); specs = @('T9'); agents = @(@{ id = 'area-01'; items = 'T9'; area = 'Totals' }) }
$w2 = Dt render wave-brief "$wd/wb2.json" "$wd/brief2.md"
Expect 'wave-brief: a draft spec refuses the brief (spec before build)' ($w2.code -ne 0 -and $w2.out -match 'spec of T9 not ready' -and -not (Test-Path "$wd/brief2.md"))

# ---- interview questions in plain words (decide ask): today + why, each option's effect, a default; the bare ask kept for rules
$O = Join-Path $k 'skills/bossy/bossy.ps1'
$qa = pwsh -NoProfile -File $O decide ask -Run r1 -Agent briefy-1 -Item T1 -Context 'today: the list shows oldest first' -Question 'Sort newest first?' -Options 'A: newest first — dispatchers see new work at once', 'B: keep — no change for users' -Recommend A 2>&1 | Out-String
$qb = pwsh -NoProfile -File $O decide ask -Run r1 -Agent briefy-1 -Item T1 -Question 'Sort?' -Options 'A: yes', 'B: no' 2>&1 | Out-String; $qbc = $LASTEXITCODE
$qr = @(pwsh -NoProfile -File $O decide list -Pending -Json | ConvertFrom-Json) | Where-Object { $_.ask -eq 'Sort newest first?' }
Expect "decide ask: the owner reads today (said once) + the question + its default; a bare one refused (exit $qbc) naming context, effects, recommendation" ($qa -match 'DECISION \S+ pending' -and $qa -notmatch 'refused' -and
  $qr.question -eq 'Today: the list shows oldest first. Sort newest first? Not sure? The default is A.' -and $qbc -eq 2 -and $qb -match 'decide ask refused: missing -Context .*each option .*-Recommend')

# ---- MR body + commit cite S-ids; usage
Set-JsonFile "$wd/mr.json" @{ type = 'feat'; change = 'sort orders'; summary = 'Orders sort by date'; specIds = 'S1,S2'; changes = @(@{ text = 'sort by date' }) }
$mb = Dt render mr-body "$wd/mr.json"; $cm = Dt render commit "$wd/mr.json"
Expect 'MR body Links: Spec S-ids line; commit body: Spec line' ($mb.out -match '(?m)^- \*\*Spec S-ids:\*\* S1, S2$' -and $cm.out -match '(?m)^- Spec: S1, S2$')
$hp = Dt spec --help
Expect 'spec --help: verbs and the JSON fields, exit 0' ($hp.code -eq 0 -and $hp.out -match 'rules \[\{id: S1, text,' -and $hp.out -match 'spec write T1')
# ---- wave brief (moved from render.tests: room): one spec -> brief + contracts + /buildy args; empty sections n/a — <why> (A3)
function Gold($a, $b) { ("$a" -replace "`r`n", "`n").TrimEnd() -eq ("$b" -replace "`r`n", "`n").TrimEnd() }
Set-JsonFile "$wd/wb.json" ([ordered]@{ name = 'orders-sort'; date = '2026-11-13'; items = 'T-1 epic'; decisions = 'none'; localEnv = 'r3'; testEnv = 'stg'; kitDir = 'K'
  repos = @([ordered]@{ repo = 'web'; checkout = 'R/web'; target = 'main'; migrations = 'none' }); agents = @([ordered]@{ id = 'X1'; items = 'A1'; area = 'orders screen'; repos = 'web'; services = 'api'; complex = 'new grid' }, [ordered]@{ id = 'X2'; items = 'A2'; area = 'api sort'; repos = 'api'; dependsOn = @('X1'); migrations = $true; debate = [ordered]@{ item = 'A2'; options = 'A: x', 'B: y' } })
  contracts = @([ordered]@{ name = 'GET /orders?sort'; type = 'query'; producer = 'X2'; consumers = 'X1'; order = 'X2 first'; compatible = $true }); openQuestions = @([ordered]@{ question = 'Which index?'; blocks = 'A2'; answers = 'rechy' }); mandate = @('sort orders'); mode = 'feature' })
$wbo = Dt render wave-brief "$wd/wb.json" "$wd/wb.md"; $wbArgs = Get-Content -Raw "$wd/wb.args.json" | ConvertFrom-Json
Expect "render wave-brief: golden brief + contracts; args = brief, agents (empty keys dropped, debate kept), mode, mandate, rechy questions ($($wbo.code))" ($wbo.code -eq 0 -and (Gold ((Get-Content -Raw "$wd/wb.md") -creplace '\*\*MR limits.*\n') @"
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
n/a — no spike yet (the Spike phase appends here)
## Rule changes during the wave (newest last)
n/a — none yet (appended during the wave)
"@) -and (Gold (Get-Content -Raw "$wd/wb.contracts.md") "# Contracts: orders-sort`n| Field / endpoint | Type | Producer | Consumers | Merge / deploy order | Backward-compatible |`n|---|---|---|---|---|---|`n| GET /orders?sort | query | X2 | X1 | X2 first | yes |`n## Rule changes during the wave (newest last)`nn/a — none yet (appended during the wave)") -and
  $wbArgs.brief -like '*/wb.md' -and ($wbArgs.agents[1] | ConvertTo-Json -Compress) -eq '{"id":"X2","items":"A2","area":"api sort","dependsOn":["X1"],"migrations":true,"debate":{"item":"A2","options":["A: x","B: y"]}}' -and $wbArgs.openQuestions[0] -eq 'Which index?' -and $wbArgs.mandate[0] -eq 'sort orders')
Remove-TestKit $k
Complete-Tests
