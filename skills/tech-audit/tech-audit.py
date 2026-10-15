#!/usr/bin/env python3
"""tech-audit.py: validate and summarise a module audit's findings (tech-audit SKILL.md steps 5-6). Python 3.8+.

  python -X utf8 tech-audit.py validate <module>.json [...]
  python -X utf8 tech-audit.py summary <module>.json [--sources "code, schema, staging data"] [--out <dir>]

Inputs: the findings JSON (shape: SKILL.md "Output schema"). Outputs: problems (validate); <module>-summary.md + .html (summary).
Exit codes: 0 ok · 1 invalid findings · 2 usage error.

validate: Validate a findings file against the 23-key schema (see ../reference/output-schema.md).

  python validate.py <module>.json [more.json ...]

Checks: valid JSON array, exact key set, all values strings, allowed vocab, unique ids, in-scope triage columns filled,
out-of-scope analytical columns empty. Exit code 1 if any problem.

summary: Build the audit summary from a findings file: <module>-summary.md (for chat/MR) and <module>-summary.html
(Google-Docs friendly, same look as the QA reports). Publish the HTML with devtools.py doc if it should be shared.

  python summary.py <module>.json [--sources "code, schema, staging data"] [--out <dir>]
"""
import argparse, html, json, os, re, sys
from collections import Counter


def validate(argv):


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

    if len(argv) < 1:
        print(__doc__.strip())
        return (2)

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
                continue   # the checks below assume strings (hashable id, .startswith)
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
    return (1 if problems else 0)


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
    COL = {'Critical': ('#7f1d1d', '#fee2e2'), 'High': ('#991b1b', '#fde8e8'), 'Medium': ('#92400e', '#fef3c7'), 'Low': ('#374151', '#f3f4f6')}
    ins = [r for r in rows if r['in_scope'] == 'Yes']
    outs = [r for r in rows if r['in_scope'] != 'Yes']
    by_type = Counter(r['type'] for r in ins)
    by_sev = Counter(r['severity'] for r in ins)
    top = sorted([r for r in ins if r['severity'] in ('Critical', 'High')], key=lambda r: SEV.index(r['severity']))
    decide = [r for r in ins if r['product_decision'] == 'Yes']
    unverified = [r for r in ins if r['current'].startswith('(unverified)')]
    dbm = [r for r in ins if r['db_migration'] == 'Yes']

    # ---------- Markdown ----------
    md = [f'# Technical audit — {module}', '']
    md.append(f'**{len(ins)} in-scope findings** ({", ".join(f"{by_type[t]} {t}" for t in ("Bug", "Performance", "Tech Debt") if by_type[t])}) · '
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
    md += [f"| {r['id']} | {r['type']} | {r['severity']} | {r['title']} | {r['effort']} |" for r in sorted(ins, key=lambda r: (SEV.index(r['severity']), r['id']))]
    if outs:
        md += ['', '## Out of scope (captured for product)', ''] + [f"- {r['id']} ({r['type']}): {r['title']}" for r in outs]
    open(base + '.md', 'w', encoding='utf-8').write('\n'.join(md) + '\n')

    # ---------- HTML ----------
    E = html.escape
    cell = 'border:1px solid #d1d5db;padding:6px 8px;vertical-align:top;font-size:10pt'
    h2 = "font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px"
    H = [f"<html><head><meta charset='utf-8'></head><body style='font-family:Arial,Helvetica,sans-serif;color:#111827;font-size:10.5pt'>",
         "<p style='font-size:9pt;color:#6b7280;margin:0'>TECHNICAL AUDIT</p>",
         f"<h1 style='font-size:20pt;margin:2px 0 8px 0'>{E(module)}</h1><table style='border-collapse:collapse;margin:6px 0 12px 0'><tr>"]
    for s in SEV:
        fg, bg = COL[s]
        H.append(f"<td style='background:{bg};color:{fg};padding:8px 14px;text-align:center;border:1px solid #fff'><span style='font-size:18pt;font-weight:bold'>{by_sev[s]}</span><br><span style='font-size:8pt;font-weight:bold'>{s.upper()}</span></td>")
    H.append(f"<td style='background:#f3f4f6;color:#374151;padding:8px 14px;text-align:center;border:1px solid #fff'><span style='font-size:18pt;font-weight:bold'>{len(outs)}</span><br><span style='font-size:8pt;font-weight:bold'>OUT OF SCOPE</span></td></tr></table>")
    H.append(f"<p>{len(ins)} in-scope findings: " + ', '.join(f'{by_type[t]} {t}' for t in ('Bug', 'Performance', 'Tech Debt') if by_type[t]) +
             f". {len(unverified)} rest on unverified inference; {len(dbm)} need a DB migration." + (f" Sources: {E(a.sources)}." if a.sources else '') + "</p>")


    def table(items, cols):
        t = ["<table style='border-collapse:collapse;width:100%'><tr>"] + [f"<td style='{cell};background:#1f3a68;color:#fff'><b>{c}</b></td>" for c, _ in cols] + ['</tr>']
        for i, r in enumerate(items):
            z = '#f8fafc' if i % 2 else '#ffffff'
            t.append(f"<tr style='background:{z}'>")
            for c, k in cols:
                v = E(r[k])
                if k == 'severity':
                    fg, bg = COL.get(r[k], ('#111', '#fff'))
                    t.append(f"<td style='{cell};background:{bg};color:{fg}'><b>{v}</b></td>")
                elif k == 'code_location':
                    t.append(f"<td style='{cell};font-family:Consolas,monospace;font-size:9pt'>{v}</td>")
                else:
                    t.append(f"<td style='{cell}'>{v}</td>")
            t.append('</tr>')
        return ''.join(t) + '</table>'


    if top:
        H.append(f"<h2 style='{h2}'>Critical and High</h2>" + table(top, [('ID', 'id'), ('Sev', 'severity'), ('Title', 'title'), ('Current', 'current'), ('Where', 'code_location'), ('Fix', 'suggested_fix')]))
    if decide:
        H.append(f"<h2 style='{h2}'>Needs a product decision</h2>" + table(decide, [('ID', 'id'), ('Title', 'title'), ('Expected', 'expected'), ('Business impact', 'business_impact')]))
    H.append(f"<h2 style='{h2}'>All in-scope findings</h2>" + table(sorted(ins, key=lambda r: (SEV.index(r['severity']), r['id'])),
             [('ID', 'id'), ('Type', 'type'), ('Sev', 'severity'), ('Title', 'title'), ('Why not visible in prod', 'why_not_prod'), ('Effort', 'effort'), ('DB', 'db_migration')]))
    if outs:
        H.append(f"<h2 style='{h2}'>Out of scope (captured for product)</h2>" + table(outs, [('ID', 'id'), ('Type', 'type'), ('Title', 'title'), ('Expected', 'expected')]))
    H.append("<p style='font-size:8pt;color:#9ca3af;margin-top:18px'>Generated by the tech-audit skill. Unverified findings are marked and capped at Medium.</p></body></html>")
    open(base + '.html', 'w', encoding='utf-8').write(''.join(H))
    print(base + '.md'); print(base + '.html')


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    if cmd == 'validate':
        sys.exit(validate(rest) or 0)
    if cmd == 'summary':
        sys.exit(summary(rest) or 0)
    print(__doc__)
    sys.exit(2)