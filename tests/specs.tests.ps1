#Requires -Version 7
<#
specs.tests.ps1: spec docs (devtools.py spec): the standard layout, versions + change log, S-id traceability into cases, MR bodies,
commits and the finish gate, standing subject specs linked to tasks, retest marks on a changed S-id; task order (spec waitsOn / wave, tracker order waves).
Usage: pwsh -NoProfile -File <kit>/tests/specs.tests.ps1 (or tests/kit-tests.ps1 -Area specs).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit specs; $DT = Join-Path $k 'skills/crafty/devtools.py'; $wd = Join-Path (Kd) 'w'; New-Item -ItemType Directory -Force $wd | Out-Null
$docs = TkPath $k docs
function Dt { $o = & $py -X utf8 $DT @args 2>&1 | Out-String; [pscustomobject]@{ out = $o.Trim(); code = $LASTEXITCODE } }

# ---- write: a bad S-id refused; a draft renders every section, open ones as their question (the interview)
$heads = @('Summary', 'Problem and evidence', 'Success metrics', 'Scope, no-gos and appetite', 'Users and flows', 'Behaviour rules', 'Algorithm', 'Design', 'UI screens and states',
  'Cross-cutting', 'Risks and rabbit holes', 'Rollout', 'Acceptance and test strategy', 'Dependencies', 'Decisions', 'Open questions', 'Change log')
$bugHeads = @('Summary', 'Impact', 'Reproduce', 'Regression range', 'Root cause', 'Fix and rules', 'Rules', 'Fix algorithm', 'Detection gap', 'Data repair', 'Rollout', 'Decisions', 'Open questions', 'Change log')
Set-JsonFile "$wd/s0.json" @{ kind = 'feature'; title = 'Sort orders'; rules = @(@{ id = 'X1'; text = 'sorts' }) }
$r0 = Dt spec write T1 "$wd/s0.json"
Expect "spec write: a rule id that is no S<n> is refused, nothing written ($($r0.code))" ($r0.code -ne 0 -and $r0.out -match "rule id 'X1'" -and (Dt spec show T1).out -match 'no spec')
Set-JsonFile "$wd/d0.json" @{ kind = 'bug'; title = 'Totals off'; goal = 'totals match'; dataRepair = @{ na = '' }; repro = @{ steps = 'open totals'; rootCause = 'rounding per line' }
  approach = 'round once'; rules = @(@{ id = 'S1'; text = 'total = sum of lines' }) }
$rd = Dt spec write T9 "$wd/d0.json"; $dd = Get-Content -Raw (Join-Path $docs 'T9-spec.md'); $dq = Dt spec questions T9
Expect "spec draft (bug, v1-shape input): the bug sections only, open ones as purpose + question, parts asked, n/a without reason open; questions exit 1 ($($rd.code)$($dq.code))" ($rd.code -eq 0 -and
  @($bugHeads | Where-Object { $dd -notmatch "(?m)^#{2,3} $([regex]::Escape($_))$" }).Count -eq 0 -and $dd -notmatch '(?m)^## (Design|Problem and evidence)$' -and $dd -match '\| Status \| draft · \d+ open' -and
  $dd -match '(?m)^\*\*Open\*\* \(last good version or date, first bad\): Did it ever work' -and $dd -match '(?s)## Summary\s+totals match' -and $dd -match '- \*\*Root cause:\*\* rounding per line' -and
  $dd -match '(?s)## Fix and rules\s+- \*\*Approach:\*\* round once' -and $dq.code -eq 1 -and $dq.out -match 'Q\d+ S1: acceptance\?' -and $dq.out -match 'Q\d+ Data repair .* \(n/a needs its reason\)' -and
  $dq.out -match 'Q\d+ Reproduce: Frequency\?' -and $dq.out -notmatch 'which diagram')
Set-JsonFile "$wd/d1.json" @{ rules = @(@{ id = 'S1'; acceptance = 'Given 2 lines Then total = their sum' }); change = 'interview answer' }
$r9 = Dt spec write T9 "$wd/d1.json"
Expect 'spec: an interview answer to a draft is v2 with no RETEST mark' ($r9.code -eq 0 -and $r9.out -match 'spec T9 v2' -and $r9.out -notmatch 'RETEST' -and (Dt spec show T9).out -notmatch 'retest')
$lb = & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d; print(d.links_block('Spec: the list must sort\n**Spec:** [open](https://x/s) · v1\nBody', {'spec': '[open](https://x/s) · v2'}))" 2>&1 | Out-String
Expect "links_block: the Spec link line is replaced, a person's own 'Spec:' line stays ($($lb.Trim() -replace '\s+', ' '))" ($lb -match '(?s)^\*\*Spec:\*\* \[open\]\(https://x/s\) · v2\s+Spec: the list must sort\s+Body' -and $lb -notmatch 'v1')
$s1 = @{ kind = 'feature'; title = 'Sort orders'; goal = 'newest orders first'; scope = @{ in = @('orders list'); out = @('export'); appetite = '2 days' }
  problem = 'dispatchers miss new orders'; metrics = @(@{ metric = 'missed orders'; target = '0'; by = 'one week after deploy' }); dependencies = @{ na = 'none' }
  crossCutting = 'none: same screen, same data'; algorithm = @{ inputs = 'orders'; steps = @('read sort param', 'order by created_at desc'); outputs = 'sorted page'; limits = 'one indexed query'; failures = 'bad sort -> 400' }
  users = @(@{ who = 'dispatcher'; flow = 'opens Orders, reads newest' })
  rules = @(@{ id = 'S1'; text = 'the list sorts by date, newest first'; acceptance = 'Given 2 orders When Orders opens Then the newer is on top' },
            @{ id = 'S2'; text = 'a Date header click flips the order'; acceptance = 'Given the list When Date is clicked Then oldest first' })
  options = @(@{ choice = 'where to sort'; options = @(@{ id = 'A'; text = 'server'; pros = 'paging'; cons = 'API change' }, @{ id = 'B'; text = 'client'; pros = 'no API'; cons = 'one page' }); chosen = 'A'; why = 'paging'; rejected = 'B: one page only'; revisit = 'never' })
  approach = 'sort param on GET /orders'; impact = @('OrderController', 'orders.created_at index'); risks = @(@{ text = 'slow sort'; mitigation = 'index' })
  rollout = @{ flag = 'sortV2'; enable = 'Settings > Orders'; rollback = 'flag off'; migration = 'none'; tell = 'dispatchers' }; tests = @('unit', 'API', 'UI'); diagrams = @(@{ title = 'Sort flow'; mermaid = 'flowchart LR; A-->B' })
  decisions = @{ na = 'no choice left' }; questions = @()
  contracts = @(@{ name = 'GET /orders sort'; ref = 'wave.contracts.md row 1' }); ui = @{ screens = 'Orders'; states = 'empty, loaded'; theme = 'app theme colours only' }
  edges = @(@{ text = 'two orders with one timestamp'; rule = 'S1' }) }
Set-JsonFile "$wd/s1.json" $s1
$r1 = Dt spec write T1 "$wd/s1.json" --by briefy-1
$doc = Get-Content -Raw (Join-Path $docs 'T1-spec.md') -ErrorAction SilentlyContinue
Expect "spec write v1 ready: feature sections, v1 fields mapped (options -> Decisions, approach / contracts / diagrams -> Design), algorithm steps, Mermaid source, n/a with reason, change log row ($($r1.code))" (
  $r1.code -eq 0 -and $doc -match '(?m)^# T1 Spec v1 — Sort orders' -and @($heads | Where-Object { $doc -notmatch "(?m)^## $([regex]::Escape($_))$" }).Count -eq 0 -and $doc -notmatch '(?m)^## (Reproduce|Glossary)$' -and
  $doc -match '\| Status \| ready \|' -and $doc -match '\| S2 \| a Date header click' -and $doc -match '\*\*where to sort\*\* · drivers: — · chosen: A · why: paging; rejected: B: one page only' -and
  $doc -match '\| B \| client \| no API \| one page \|' -and $doc -match '(?s)## Design\s+- \*\*Approach:\*\* sort param on GET /orders.*\| GET /orders sort \| wave.contracts.md row 1 \|.*```mermaid\s+flowchart LR; A-->B' -and
  $doc -match '(?m)^- \*\*Steps:\*\*\s+1\. read sort param\s+2\. order by created_at desc' -and $doc -match '(?s)## Dependencies\s+n/a — none' -and $doc -match '- \*\*Out \(no-gos\):\*\* export' -and
  $doc -match '\| v1 \| \S+ \| briefy-1 \| first version \| S1, S2 \|' -and $doc -match '(?s)\*\*Edge cases\*\*.*two orders with one timestamp \(S1\)' -and (Dt spec questions T1).code -eq 0)
# owner 2026-11-24 (proper diagrams): a feature Design without a diagram is open (draft) and finish refuses it; n/a + why passes; an answer merges by part
$dg = & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d; f = {'kind': 'feature', 'design': {'approach': 'x'}}; print(d.spec_diagram_gap(f), '|', d.spec_diagram_gap({**f, 'design': {'approach': 'x', 'diagrams': {'na': 'text only'}}}) or '-', '|', d.spec_diagram_gap({'kind': 'bug'}) or '-', '|', any('which diagram' in q for q in d.spec_questions(f)))" 2>&1 | Out-String
$null = Dt spec write T5 "$wd/s1.json"
Set-JsonFile "$wd/s1b.json" @{ rollout = @{ tell = 'dispatchers and support' }; change = 'who is told' }; $r1b = Dt spec write T5 "$wd/s1b.json"; $doc1b = Get-Content -Raw (Join-Path $docs 'T5-spec.md')
Expect "spec diagrams: Design with none = gap + interview question; n/a passes; bug needs none; an object answer merges by part ($($dg.Trim()))" ($dg.Trim() -eq 'Design | - | - | True' -and $r1b.code -eq 0 -and
  $doc1b -match '- \*\*Who is told:\*\* dispatchers and support' -and $doc1b -match '- \*\*Flag:\*\* sortV2')
Set-JsonFile "$wd/s1c.json" @{ change = 'diagram dropped'; design = @{ diagrams = @() } }; $null = Dt spec write T5 "$wd/s1c.json"; $fq = Dt spec questions T5
# a stand-in for the pinned mmdc (spec setup): writes the -o file; the image line goes above the kept Mermaid source
$mmBin = Join-Path (TkPath $k tools) 'mmdc/node_modules/.bin'; $mmFake = Join-Path $mmBin ($IsWindows ? 'mmdc.cmd' : 'mmdc'); $null = New-Item -ItemType Directory -Force $mmBin
Set-Content -LiteralPath $mmFake ($IsWindows ? "@echo off`r`ntype nul > %4" : "#!/bin/sh`ntouch `"`$4`""); if (-not $IsWindows) { chmod +x $mmFake }
Set-JsonFile "$wd/s1d.json" @{ change = 'diagram back'; design = @{ diagrams = @(@{ title = 'Sort flow'; type = 'flowchart'; mermaid = 'flowchart LR; A-->C' }) } }; $null = Dt spec write T5 "$wd/s1d.json"
$doc1d = Get-Content -Raw (Join-Path $docs 'T5-spec.md'); Remove-Item -LiteralPath $mmFake
Expect "spec questions: a dropped diagram reopens the spec; mmdc renders an image above the Mermaid source ($($fq.code))" ($fq.code -eq 1 -and $fq.out -match 'Design: which diagram' -and (Dt spec questions T5).code -eq 0 -and
  $doc1d -match '(?s)### Sort flow \(flowchart\)\s+!\[Sort flow\]\([^)]*T5-d1-[0-9a-f]{8}\.png\)\s+```mermaid\s+flowchart LR; A-->C')
Set-Content -LiteralPath "$wd/mg.py" -Encoding utf8 @"
import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools as d
v1 = {'kind': 'subject', 'title': 't', 'approach': 'old way', 'contracts': [{'name': 'GET /x', 'ref': 'r1'}], 'diagrams': [{'title': 'L', 'mermaid': 'stateDiagram-v2; A-->B'}], 'rules': [{'id': 'S1', 'text': 'r', 'acceptance': 'a'}]}
m = d.spec_migrate(v1); md = d.render_spec(v1, 's', 1, [{'v': 1}])
b = d.render_spec({'kind': 'bug', 'title': 'b', 'risks': [{'text': 'RISKY'}]}, 'b', 1, [{'v': 1}])
print(m['rules'] == v1['rules'], d.spec_migrate(m) == m, 'approach' in v1, d.spec_diagram_gap(v1) or '-', m['interfaces'][0]['name'], 'Earlier approach:** old way' in md, 'GET /x' in md, 'RISKY' in b,
      d.spec_diagram_gap({'kind': 'feature', 'design': {'diagrams': [{'title': 'x', 'mermaid': ''}]}}))
"@
$mg = & $py -X utf8 "$wd/mg.py" 2>$null | Out-String
Expect "spec_migrate (v1 -> v2): rules kept, idempotent, input untouched; a subject's diagrams -> Data model, contracts -> Interfaces, the rest carried (shown); an empty Mermaid is no diagram ($($mg.Trim()))" ($mg.Trim() -eq 'True True True - GET /x True True True Design')
Set-JsonFile "$wd/s1e.json" @{ change = 'a decision'; decisions = @(@{ id = 'D1'; question = 'q'; chosen = 'A' }) }; $null = Dt spec write T5 "$wd/s1e.json"
Set-JsonFile "$wd/s1f.json" @{ change = 'a better why'; decisions = @(@{ id = 'D1'; why = 'w' }) }; $null = Dt spec write T5 "$wd/s1f.json"
Expect 'spec write: a partial decision update keeps its chosen option (ready stays)' ((Dt spec questions T5).code -eq 0 -and (Get-Content -Raw (Join-Path $docs 'T5-spec.md')) -match '\*\*q\*\* \(D1\) · drivers: — · chosen: A · why: w')
$tp = Dt spec template bug
Expect 'spec template bug: the bug sections with purpose and questions, no feature section' ($tp.code -eq 0 -and $tp.out -match '(?m)^### Regression range' -and $tp.out -match 'Ask: Did it ever work' -and $tp.out -match '(?m)^#### Fix algorithm' -and $tp.out -notmatch 'Success metrics')
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
$cs.cases[1].spec = 'S1'; Set-JsonFile "$wd/c1.json" $cs; $ca = Dt cases add T1 "$wd/c1.json" --replace
$hu = Get-Content -Raw (Dt cases render T1 human).out; $ai = Get-Content -Raw (Dt cases render T1 ai).out; $g = Dt spec trace T1
Expect "cases cite S-ids (human + AI rows); spec trace + cases add WARN name S2 ($($g.code))" ($hu -match '\| T1 \| Open Orders \| newest first \[S1\] \|' -and $ai -match '\| A1 \(T1\) \| positive \| open \| newest first \[S1\] \|' -and
  $ca.out -match 'WARN cases T1: spec S-id\(s\) S2' -and $g.code -eq 1 -and $g.out -match 'T1: S2 has no test case')
$cs.cases += @{ id = 'A3'; type = 'edge'; steps = 'click Date twice'; expected = 'newest first'; spec = 'S2' }; Set-JsonFile "$wd/c1.json" $cs; $null = Dt cases add T1 "$wd/c1.json"
Expect 'spec trace: every S-id cited -> exit 0' ((Dt spec trace T1).code -eq 0)

# ---- standing subject spec linked to a task: only the ids it names count; a change marks that task
$sub = @{ kind = 'subject'; title = 'Orders list'; goal = 'one behaviour for every orders screen'
  rules = @(@{ id = 'S1'; text = 'rows page by 50'; acceptance = 'Given 51 orders Then page 2 holds 1' }, @{ id = 'S2'; text = 'filters persist'; acceptance = 'Given a filter When reopened Then kept' }) }
foreach ($f in 'purpose', 'glossary', 'users', 'algorithm', 'dataModel', 'interfaces', 'quality', 'risks', 'decisions', 'questions') { $sub[$f] = @{ na = 'subject-wide rules only' } }
Set-JsonFile "$wd/sub.json" $sub
$sw = Dt spec write orders-list "$wd/sub.json" --subject; $ln = Dt spec link T2 orders-list --ids S2; $gp = Dt spec trace T2
Set-JsonFile "$wd/sub2.json" @{ rules = @(@{ id = 'S1'; text = 'rows page by 100'; acceptance = 'Given 101 orders Then page 2 holds 1' }); change = 'page size 100' }
$s2w = Dt spec write orders-list "$wd/sub2.json"
Set-JsonFile "$wd/sub3.json" @{ rules = @(@{ id = 'S2'; text = 'filters persist per user'; acceptance = 'Given a filter When reopened Then kept' }); change = 'per user' }
$s3w = Dt spec write orders-list "$wd/sub3.json"
Expect "subject spec: link names S2; trace wants S2 only; a change to S1 marks nothing, to S2 marks T2 ($($sw.code)$($ln.code))" ($sw.code + $ln.code -eq 0 -and $ln.out -match 'orders-list v1 linked on T2 \(S2\)' -and
  $gp.out -match 'T2: S2 has no test case' -and $gp.out -notmatch 'S1' -and $s2w.out -notmatch 'RETEST' -and $s3w.out -match 'RETEST T2: S2 \(spec orders-list v3\)' -and (Dt spec show T2).out -match 'orders-list:spec v3')
# ---- retire a superseded spec (briefys 2026-11-23): no reason refused; doc SUPERSEDED, v+1 logged, its task unlinked, no trace gaps
$rt0 = Dt spec retire orders-list; $rt1 = Dt spec retire orders-list --reason 'superseded by T7'; $rtDoc = Get-Content -Raw (Join-Path $docs 'orders-list-spec.md')
Expect "spec retire: --reason required; doc SUPERSEDED + change log v4; T2 loses the spec; show says retired ($($rt0.code) $($rt1.code))" ($rt0.code -ne 0 -and $rt0.out -match '--reason' -and $rt1.code -eq 0 -and
  $rtDoc -match '^\*\*SUPERSEDED\*\* \S+: superseded by T7' -and $rtDoc -match 'retired: superseded by T7' -and (Dt spec show T2).out -match 'no spec' -and (Dt spec trace T2).code -eq 0 -and (Dt spec show orders-list).out -match 'v4 retired: superseded by T7')
Set-JsonFile "$wd/sub4.json" @{ change = 'back in use'; goal = 'a revived goal' }; $null = Dt spec write orders-list "$wd/sub4.json"
Expect 'spec write after retire: a new version is live again (not retired)' ((Dt spec show orders-list).out -match 'orders-list:spec v5 (ready|draft)')

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
Expect 'MR body Links: Spec S-ids line; commit body: Spec line' ($mb.out -match '(?m)^- .* · \*\*Spec S-ids:\*\* S1, S2$' -and $cm.out -match '(?m)^- Spec: S1, S2$')
$hp = Dt spec --help
Expect 'spec --help: verbs and the JSON fields, exit 0' ($hp.code -eq 0 -and $hp.out -match 'rules \[\{id: S1, text,' -and $hp.out -match 'spec write T1')
# ---- wave brief (moved from render.tests: room): one spec -> brief + contracts + /buildy args; empty sections n/a — <why> (A3)
function Gold($a, $b) { ("$a" -replace "`r`n", "`n").TrimEnd() -eq ("$b" -replace "`r`n", "`n").TrimEnd() }
Set-JsonFile "$wd/wb.json" ([ordered]@{ name = 'orders-sort'; date = '2026-11-13'; items = 'T-1 epic'; decisions = 'none'; localEnv = 'r3'; testEnv = 'stg'; kitDir = 'K'
  repos = @([ordered]@{ repo = 'web'; checkout = 'R/web'; target = 'main'; migrations = 'none' }); agents = @([ordered]@{ id = 'X1'; items = 'A1'; area = 'orders screen'; repos = 'web'; services = 'api'; complex = 'new grid' }, [ordered]@{ id = 'X2'; items = 'A2'; area = 'api sort'; repos = 'api'; dependsOn = @('X1'); migrations = $true; debate = [ordered]@{ item = 'A2'; options = 'A: x', 'B: y' } })
  contracts = @([ordered]@{ name = 'GET /orders?sort'; type = 'query'; producer = 'X2'; consumers = 'X1'; order = 'X2 first'; compatible = $true }); openQuestions = @([ordered]@{ question = 'Which index?'; blocks = 'A2'; answers = 'rechy' }); mandate = @('sort orders'); mode = 'feature' })
$wbo = Dt render wave-brief "$wd/wb.json" "$wd/wb.md"; $wbArgs = Get-Content -Raw "$wd/wb.args.json" | ConvertFrom-Json
Expect "render wave-brief: golden brief + contracts; args = brief, agents (empty keys dropped, debate kept), mode, mandate, rechy questions ($($wbo.code))" ($wbo.code -eq 0 -and (Gold ((Get-Content -Raw "$wd/wb.md") -creplace '(?s)\*\*MR limits.*?(?=Rule changes during)') @"
# Wave brief: orders-sort, 2026-11-13
**Read first:** ``K/skills/crafty/SKILL.md``; this brief wins where they differ.
**Items:** T-1 epic · **Decisions:** none; final, don't re-ask (a NEW choice -> crafty D1).
**User-visible change** the items do not ask for -> ``bossy.ps1 decide ask`` first (crafty D1); that item waits.
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

## Order (waves: a row runs in parallel; ``crafty.ps1 tracker order <parent> -Apply <brief>.order.json`` links the tasks)
| Wave | Areas (parallel) | Tasks | Waits on |
|---|---|---|---|
| cycle | X1, X2 | — | X1, X2 |
## openQuestions
Which index? · blocks A2 · answers: rechy
## Findings (rechy)
n/a — no spike yet (the Spike phase appends here)
## Rule changes during the wave (newest last)
n/a — none yet (appended during the wave)
"@) -and (Gold (Get-Content -Raw "$wd/wb.contracts.md") "# Contracts: orders-sort`n| Field / endpoint | Type | Producer | Consumers | Merge / deploy order | Backward-compatible |`n|---|---|---|---|---|---|`n| GET /orders?sort | query | X2 | X1 | X2 first | yes |`n## Rule changes during the wave (newest last)`nn/a — none yet (appended during the wave)") -and
  $wbArgs.brief -like '*/wb.md' -and ($wbArgs.agents[1] | ConvertTo-Json -Compress) -eq '{"id":"X2","items":"A2","area":"api sort","dependsOn":["X1"],"migrations":true,"debate":{"item":"A2","options":["A: x","B: y"]}}' -and $wbArgs.openQuestions[0] -eq 'Which index?' -and $wbArgs.mandate[0] -eq 'sort orders')
$wbLong = @((Get-Content "$wd/wb.md") | Where-Object { $_.Length -gt 130 -and $_ -notmatch '^\||https?://' })
Expect "render wave-brief: its own lines fit the brief's 130ch prose cap (MR limits wrapped; briefys 2026-11-23) ($($wbLong -join ' // '))" (-not $wbLong.Count -and ((Get-Content -Raw "$wd/wb.md") -match '\*\*MR limits\*\*[^#]*mr-title[^#]*mr-body'))
# order (owner 2026-11-23): spec waitsOn / wave -> waits-on links (native verb) or a kit:order description section; tracker order = waves + flags
$tor = Invoke-PsTest taskorder @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $ErrorActionPreference = 'Stop'
$base = @{ kind = 'Feature'; problem = 'p.'; goal = 'g.'; acceptance = @('a'); links = @('https://t/9'); newTask = 'fixture'; proseOk = 'order fixture' }
$pid0 = (Publish-KitTaskSpec ($base + @{ title = 'Order parent'; items = @(@{ code = 'O1'; desc = 'o' }) })).id
$mk = { param($t, $w, $wv) (Publish-KitTaskSpec ($base + @{ title = $t; parent = $pid0; items = @(@{ code = $t; desc = $t }); waitsOn = $w; wave = $wv })).id }
$a = & $mk 'Alpha' @() 'v2 wave 1'; $b = & $mk 'Beta' @($a) 'v2 wave 2'; $c = & $mk 'Gamma' @() 'v2 wave 1'; $d = & $mk 'Delta' @($b, $c) 'v2 wave 3'
$o = Get-KitTaskOrder $pid0; "waves:$((@($o.tasks | Sort-Object wave, id | ForEach-Object { "$($_.wave)=$($_.id)" })) -join ',')"
"section:$((Get-TrackerTask $b).description -match "(?s)<!-- kit:order -->\n\*\*Waits on:\*\* $a\n<!-- /kit:order -->" -and "$((Get-TrackerTask $b).tags)" -eq 'Wave: v2 wave 2')"   # tracker none labels natively (owner 2026-11-24 tags)
"flags:$(@($o.flags).Count)"; "table:$((Format-KitTaskOrder $o) -join '//')"
$null = Set-KitTaskOrder $a @($d) 'v2 wave 1'; "cycle:$(@((Get-KitTaskOrder $pid0).flags) -join '//')"
$e = & $mk 'Eps' @() 'v2 wave 2'; "missing:$(@((Get-KitTaskOrder $pid0).flags -match "^MISSING: $e").Count)"
$got = [Collections.Generic.List[string]]::new(); $KitAdapters['tracker']['none']['dependencies'] = { param($x) foreach ($n in @($x.on)) { $got.Add("$($x.id)<-$n") }; @($x.on) }
$null = Set-KitTaskOrder $c @($a) ''; "native:$($got -join ',')|$((Get-TrackerTask $c).description -match 'Waits on')"
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
$tw ="$($tor -match '^waves:')" -replace '^waves:'
Expect "tracker order: spec waitsOn / wave -> a kit:order section (no native verb); waves: Alpha + Gamma, Beta, Delta; table rows per wave; a cycle and a later wave with no link flagged; a native dependencies verb gets the links ($($tor -join ' // '))" (
  $tw -match '^1=LOCAL-\d+,1=LOCAL-\d+,2=LOCAL-\d+,3=LOCAL-\d+$' -and @($tor -match '^section:True').Count -and @($tor -match '^flags:0$').Count -and @($tor -match '^table:.*\| 1 \| [^|]*(Alpha[^|]*Gamma|Gamma[^|]*Alpha)[^|]*\|.*\| 3 \| [^|]*Delta').Count -and
  @($tor -match '^cycle:CYCLE: LOCAL-\d+, LOCAL-\d+, LOCAL-\d+ wait on each other').Count -and @($tor -match '^missing:1$').Count -and @($tor -match '^native:LOCAL-\d+<-LOCAL-\d+\|False$').Count)
Remove-TestKit $k
Complete-Tests
