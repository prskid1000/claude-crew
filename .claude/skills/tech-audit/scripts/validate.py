"""Validate a findings file against the 23-key schema (see ../reference/output-schema.md).

  python validate.py <module>.json [more.json ...]

Checks: valid JSON array, exact key set, all values strings, allowed vocab, unique ids, in-scope triage columns filled,
out-of-scope analytical columns empty. Exit code 1 if any problem.
"""
import json, re, sys

KEYS = ['id', 'module', 'layer', 'type', 'in_scope', 'subtype', 'title', 'area', 'severity', 'current', 'expected',
        'business_impact', 'root_cause', 'why_today', 'why_not_prod', 'customer_impact', 'db_migration', 'suggested_fix',
        'code_location', 'product_decision', 'effort', 'existing_notes', 'source']
VOCAB = {
    'type': {'Bug', 'Performance', 'Tech Debt', 'Functional Gap', 'UX', 'Reporting'},
    'in_scope': {'Yes', 'No'},
    'severity': {'Critical', 'High', 'Medium', 'Low'},
    'db_migration': {'Yes', 'No', 'Maybe', ''},
    'product_decision': {'Yes', 'No'},
    'effort': {'Low', 'Medium', 'High', ''},
}
IN_SCOPE = {'Bug', 'Performance', 'Tech Debt'}
ID = re.compile(r'^[A-Z0-9]+(-[A-Z0-9]+)*-(BUG|PERF|REF|GAP|UX|RPT)-\d+$')

problems, seen, rows = [], set(), 0
for path in sys.argv[1:]:
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
        fid = o.get('id', '?')
        if set(o) != set(KEYS):
            problems.append(f'{fid}: keys differ (missing {sorted(set(KEYS) - set(o))}, extra {sorted(set(o) - set(KEYS))})')
            continue
        if any(not isinstance(v, str) for v in o.values()):
            problems.append(f'{fid}: all values must be strings')
        if fid in seen:
            problems.append(f'{fid}: duplicate id')
        seen.add(fid)
        if not ID.match(fid):
            problems.append(f'{fid}: id should look like ABBR-BUG-001')
        for k, allowed in VOCAB.items():
            if o[k] not in allowed:
                problems.append(f'{fid}: {k}={o[k]!r} not in {sorted(allowed)}')
        if o['type'] in IN_SCOPE:
            if o['in_scope'] != 'Yes':
                problems.append(f'{fid}: {o["type"]} must be in_scope Yes')
            for k in ('root_cause', 'why_today', 'why_not_prod', 'db_migration', 'code_location'):
                if not o[k]:
                    problems.append(f'{fid}: in-scope finding needs {k}')
            if o['severity'] == 'Critical' and o['current'].startswith('(unverified)'):
                problems.append(f'{fid}: unverified finding cannot be Critical')
        else:
            if o['in_scope'] != 'No' or o['product_decision'] != 'Yes':
                problems.append(f'{fid}: {o["type"]} must be in_scope No, product_decision Yes')
            for k in ('root_cause', 'why_today', 'why_not_prod', 'customer_impact'):
                if o[k]:
                    problems.append(f'{fid}: out-of-scope finding should leave {k} empty')
        if o['current'].startswith('(unverified)') and o['severity'] in ('Critical', 'High'):
            problems.append(f'{fid}: unverified findings are capped at Medium')

for p in problems:
    print(p)
print('rows', rows, '| schema problems:', 'none' if not problems else len(problems))
sys.exit(1 if problems else 0)
