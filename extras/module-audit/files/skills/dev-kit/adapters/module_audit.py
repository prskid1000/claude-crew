"""Extra module-audit: `devtools.py findings schema | validate <module>.json [...] | summary <module>.json [--sources ".."]
[--out <dir>]` for revy's module audits (agents/revy.md kind module). Loaded by devtools.py from skills/dev-kit/adapters/."""
import argparse, json, os, re
from collections import Counter
# Sections: L9 schema · L51 validate · L110 summary · L154 entry

CFG = {}   # devtools.py's kit.local.json, set by register

# ---- schema: the finding format and the project profile
# ===== findings (revy module audits)
FINDINGS_SCHEMA = r'''A finding: exactly these 23 string keys ("" when unknown).

| Key | Format |
|---|---|
| `id` | `<MODULE>-<BUG\|PERF\|REF\|GAP\|UX\|RPT>-NNN` |
| `module`, `area`, `title`, `subtype`, `source` | short text (`subtype` e.g. Data Integrity, Validation, Concurrency, Memory leak, Schema/Migration) |
| `layer` | `Web UI` \| `Java API` \| `.NET API` \| `Python` \| `Node API` \| `Mobile` \| `Desktop` \| `DB` \| `Jobs` \| `Integration` \| `Cross-cutting` (or the profile's own) |
| `type` | `Bug` \| `Performance` \| `Tech Debt` \| `Functional Gap` \| `UX` \| `Reporting` |
| `in_scope` | `Yes` (Bug / Performance / Tech Debt) \| `No` |
| `severity` | `Critical` \| `High` \| `Medium` \| `Low` |
| `current`, `expected`, `suggested_fix` | 1-2 sentences (`current` prefixed `(unverified)` when inferred) |
| `business_impact`, `root_cause`, `customer_impact` | 1 sentence (in scope only) |
| `why_today`, `why_not_prod` | in scope only, prefixed `(inferred)` unless evidenced; concrete |
| `db_migration` | `Yes` \| `No` \| `Maybe` |
| `code_location` | `file:line`, table or endpoint |
| `product_decision` | `Yes` \| `No` |
| `effort` | `Low` \| `Medium` \| `High` \| `""` |
| `existing_notes` | prior comments, links, cross-refs, the evidence tier |

Example finding: `{"id": "NOTIF-BUG-002", "module": "Notifications", "layer": "Node API", "type": "Bug", "in_scope": "Yes", "subtype":
"Data Integrity", "title": "Digest ignores the unsubscribe flag", "area": "Email settings", "severity": "High", "current": "Opted-out
users get the digest.", "expected": "They never get it.", "business_impact": "Unwanted email.", "root_cause": "The job never reads the
flag.", "why_today": "(inferred) The flag came after the job.", "why_not_prod": "(inferred) Few opt-outs so far.", "customer_impact":
"Opted-out users get mail.", "db_migration": "No", "suggested_fix": "Filter on the flag; add a test.", "code_location":
"DigestJob.buildRecipients()", "product_decision": "No", "effort": "Low", "existing_notes": "Evidence: 3 of 3 test users.", "source": "module review"}`

Project profile (<kit>/skills/dev-kit/projects/<project>.local.md, local; one per project):
# Project profile: <name>
## Repo layout
| Layer | Repo / folder | Stack (dev.ps1 stack) | Notes (migration tool, single- or multi-tenant, ...) |
## Intended-behaviour sources
- docs / knowledge base / MCP tools / decision records
## Live / test data (read-only)
- how to query a test environment; never production writes
## Findings output
- folder, id prefix, workbook generator (if any)
## Known by-design behaviours (not bugs)
## Review lessons
'''

# ---- validate: findings files against the schema
def validate(argv):
    KEYS = ['id', 'module', 'layer', 'type', 'in_scope', 'subtype', 'title', 'area', 'severity', 'current', 'expected',
      'business_impact', 'root_cause', 'why_today', 'why_not_prod', 'customer_impact', 'db_migration', 'suggested_fix',
      'code_location', 'product_decision', 'effort', 'existing_notes', 'source']
    VOCAB = {'type': {'Bug', 'Performance', 'Tech Debt', 'Functional Gap', 'UX', 'Reporting'}, 'in_scope': {'Yes', 'No'},
        'severity': {'Critical', 'High', 'Medium', 'Low'}, 'db_migration': {'Yes', 'No', 'Maybe', ''},
        'product_decision': {'Yes', 'No'}, 'effort': {'Low', 'Medium', 'High', ''}}
    IN_SCOPE = {'Bug', 'Performance', 'Tech Debt'}
    ID = re.compile(r'^[A-Z0-9]+(-[A-Z0-9]+)*-(BUG|PERF|REF|GAP|UX|RPT)-\d+$')

    if len(argv) < 1:
        print(__doc__.strip())
        return 2

    problems, seen, rows = [], set(), 0
    for path in argv:
        try:
            data = json.load(open(path, encoding='utf-8'))
        except Exception as e:
            problems.append(f'{path}: not valid JSON ({e})')
            continue
        if not isinstance(data, list):
            problems.append(f'{path}: top level must be a JSON array')
            continue
        for o in data:
            rows += 1
            if not isinstance(o, dict):
                problems.append(f'{path}: row {rows} is not a JSON object')
                continue
            fid = o.get('id', '?')
            if set(o) != set(KEYS):
                problems.append(f'{fid}: keys differ (missing {sorted(set(KEYS) - set(o))}, extra {sorted(set(o) - set(KEYS))})')
                continue
            if any(not isinstance(v, str) for v in o.values()):
                problems.append(f'{fid!r}: all values must be strings')
                continue   # checks below need strings
            if fid in seen: problems.append(f'{fid}: duplicate id')
            seen.add(fid)
            if not ID.match(fid): problems.append(f'{fid}: id should look like ABBR-BUG-001')
            for k, allowed in VOCAB.items():
                if o[k] not in allowed: problems.append(f'{fid}: {k}={o[k]!r} not in {sorted(allowed)}')
            if o['type'] in IN_SCOPE:
                if o['in_scope'] != 'Yes': problems.append(f'{fid}: {o["type"]} must be in_scope Yes')
                for k in (CFG.get('findings') or {}).get('required') or ('root_cause', 'why_today', 'why_not_prod', 'db_migration', 'code_location'):   # kit.local.json findings.required
                    if not o.get(k): problems.append(f'{fid}: in-scope finding needs {k}')
                if o['severity'] == 'Critical' and o['current'].startswith('(unverified)'): problems.append(f'{fid}: unverified finding cannot be Critical')
            else:
                if o['in_scope'] != 'No' or o['product_decision'] != 'Yes': problems.append(f'{fid}: {o["type"]} must be in_scope No, product_decision Yes')
                for k in ('root_cause', 'why_today', 'why_not_prod', 'customer_impact'):
                    if o[k]: problems.append(f'{fid}: out-of-scope finding should leave {k} empty')
            if o['current'].startswith('(unverified)') and o['severity'] in ('Critical', 'High'):
                problems.append(f'{fid}: unverified findings are capped at Medium')

    for p in problems: print(p)
    print('rows', rows, '| schema problems:', 'none' if not problems else len(problems))
    return (1 if problems else 0)


# ---- summary: counts and the report
def summary(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--sources', default='')
    ap.add_argument('--out', default=None)
    a = ap.parse_args(argv)
    rows = json.load(open(a.file, encoding='utf-8'))
    module = rows[0]['module'] if rows else os.path.splitext(os.path.basename(a.file))[0]
    out = a.out or os.path.dirname(os.path.abspath(a.file))
    base = os.path.join(out, os.path.splitext(os.path.basename(a.file))[0] + '-summary')

    SEV = ['Critical', 'High', 'Medium', 'Low']
    ins = [r for r in rows if r['in_scope'] == 'Yes']
    outs = [r for r in rows if r['in_scope'] != 'Yes']
    by_type = Counter(r['type'] for r in ins)
    by_sev = Counter(r['severity'] for r in ins)
    top = sorted([r for r in ins if r['severity'] in ('Critical', 'High')], key=lambda r: SEV.index(r['severity']))
    decide = [r for r in ins if r['product_decision'] == 'Yes']
    unverified = [r for r in ins if r['current'].startswith('(unverified)')]
    dbm = [r for r in ins if r['db_migration'] == 'Yes']


    md = [f'# Technical audit — {module}', '']
    types = ', '.join(f'{by_type[t]} {t}' for t in ('Bug', 'Performance', 'Tech Debt') if by_type[t])
    ranked = sorted(ins, key=lambda r: (SEV.index(r['severity']), r['id']))
    md.append(f'**{len(ins)} in-scope findings** ({types}) · '
      f'**{len(outs)} out-of-scope** captured for product · severity: ' + ', '.join(f'{by_sev[s]} {s}' for s in SEV if by_sev[s]))
    if a.sources:
        md.append(f'\nSources used: {a.sources}')
    md.append(f'\n{len(unverified)} finding(s) rest on unverified inference (capped at Medium); {len(dbm)} need a DB migration.')
    if top:
        md += ['', '## Critical / High', '', '| ID | Sev | Title | Where | Fix |', '|---|---|---|---|---|']
        md += [f"| {r['id']} | {r['severity']} | {r['title']} | `{r['code_location']}` | {r['suggested_fix']} |" for r in top]
    if decide:
        md += ['', '## Needs a product decision', ''] + [f"- **{r['id']}** {r['title']} — {r['expected']}" for r in decide]
    md += ['', '## All in-scope findings', '', '| ID | Type | Sev | Title | Effort |', '|---|---|---|---|---|']
    md += [f"| {r['id']} | {r['type']} | {r['severity']} | {r['title']} | {r['effort']} |" for r in ranked]
    if outs:
        md += ['', '## Out of scope (captured for product)', ''] + [f"- {r['id']} ({r['type']}): {r['title']}" for r in outs]
    open(base + '.md', 'w', encoding='utf-8').write('\n'.join(md) + '\n')
    print(base + '.md')


# ---- entry: devtools.py findings verb
def findings(argv):
    """findings schema | validate <file> ... | summary <file> [--sources ..] [--out <dir>]"""
    sub = argv[0] if argv else ''
    if sub == 'schema':
        print(FINDINGS_SCHEMA)
        return 0
    if sub in ('validate', 'summary') and len(argv) > 1:
        return (validate if sub == 'validate' else summary)(argv[1:]) or 0
    print(__doc__.strip())
    return 2


def register(dt):
    global CFG
    CFG = dt.CFG
    dt.VERBS['findings'] = findings
