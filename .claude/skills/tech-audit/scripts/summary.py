"""Build the audit summary from a findings file: <module>-summary.md (for chat/MR) and <module>-summary.html
(Google-Docs friendly, same look as the QA reports). Publish the HTML with devtools.py doc if it should be shared.

  python summary.py <module>.json [--sources "code, schema, staging data"] [--out <dir>]
"""
import argparse, html, json, os
from collections import Counter

ap = argparse.ArgumentParser()
ap.add_argument('file')
ap.add_argument('--sources', default='')
ap.add_argument('--out', default=None)
a = ap.parse_args()
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
