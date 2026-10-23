"""Goody liquibase: `devtools.py lbcheck <master.xml> [since]`, the Liquibase sanity check `crafty.ps1 check -Step migrations` runs
for a repo without its own `repos[].migrations.check`. Loaded by devtools.py from skills/crafty/adapters/."""
import os, re, sys
import xml.etree.ElementTree as ET

# --- Liquibase XML changes
NON_CHANGE = {'preConditions', 'rollback', 'comment', 'validCheckSum', 'property'}


def local(tag):
    return tag.split('}', 1)[-1]


def xml_change(el):
    """{type, table, columns, attrs} of one change element."""
    attrs = {k: v for k, v in el.attrib.items() if isinstance(v, str)}
    table = (attrs.get('tableName') or attrs.get('baseTableName') or attrs.get('viewName') or '').strip('`"').lower()
    columns = [c.get('name', '').lower() for c in el.iter() if local(c.tag) == 'column' and c.get('name')]
    columns += [x.strip().strip('`"').lower() for k in ('columnName', 'columnNames') for x in (attrs.get(k) or '').split(',') if x.strip()]
    return {'type': local(el.tag), 'table': table, 'columns': columns, 'attrs': attrs}


def lbcheck(argv):
    """Liquibase sanity check (crafty.ps1 check): replays master.xml's includes; flags create / add of an existing table / column
without <preConditions>, schema changeSets without <rollback> (beyond auto-rollback types), not-reversible ones with an empty one.
Reports files named >= since (yyyyMMddHHmmss) or listed in env LBCHECK_CHANGED ('|'); prints issues + 'ISSUES <n>', exit 1 if n."""
    if not argv or argv[0] in ('-h', '--help'):
        print('python devtools.py lbcheck <master.xml> [since]   Liquibase sanity check (run by crafty.ps1 check -Step migrations)')
        return 0 if argv else 2
    sys.stdout.reconfigure(encoding='utf-8')
    master, since = os.path.abspath(argv[0]), argv[1] if len(argv) > 1 else '0'
    m = re.search(r'^(.*?)[\\/]config[\\/]liquibase[\\/]', master) or re.search(r'^(.*[\\/]resources)[\\/]', master)
    roots = [m.group(1) if m else os.path.dirname(master), os.path.dirname(master)]
    changed = {f for f in os.environ.get('LBCHECK_CHANGED', '').split('|') if f}
    schema = {'createTable', 'addColumn', 'dropColumn', 'dropTable', 'renameColumn', 'modifyDataType', 'addForeignKeyConstraint', 'createIndex',
         'addUniqueConstraint', 'sql', 'update', 'insert', 'delete'}
    auto = {'createTable', 'addColumn', 'renameColumn', 'createIndex', 'addForeignKeyConstraint', 'addUniqueConstraint'}
    cols, issues = {}, []   # table -> its columns, replayed

    def resolve(f, base):
        ps = [os.path.join(base, f)] + [os.path.join(r, f.lstrip('/')) for r in roots]
        return next((p for p in ps if os.path.exists(p)), ps[1])

    def walk(path, fname):
        try:
            raw = open(path, encoding='utf-8', errors='replace').read()
            root = ET.fromstring(raw.lstrip('\ufeff').encode('utf-8'))
        except Exception as e: return issues.append(f'PARSE ERROR {fname}: {e}')
        ts = re.match(r'(\d{14})', os.path.basename(fname))
        report = (bool(ts) and ts.group(1) >= since) or os.path.basename(fname) in changed or (not ts and since == '0')   # a changed old one counts
        for mm in re.finditer(r'<changeSet\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</changeSet>', raw, re.S) if report else ():   # ET drops comments
            rb = re.search(r'<rollback\s*/>|<rollback\b[^>]*>(.*?)</rollback>', mm.group(2), re.S)
            if re.search(r'not\s+reversible|irreversible|non-reversible|cannot\s+be\s+(rolled|reverted)|no\s+rollback', mm.group(2), re.I) and not (rb and (rb.group(1) or '').strip()):
                issues.append(f'{fname} {mm.group(1)}: marked not reversible but its <rollback> is missing or empty (a revert would fail): write a real reverse statement')
        for node in root:
            t = local(node.tag)
            if t == 'changeSet':
                kids = [k for k in node if local(k.tag) not in NON_CHANGE]
                guarded, cid = any(local(k.tag) == 'preConditions' for k in node), node.get('id')
                for ch in map(xml_change, kids):
                    tb, have = ch['table'], cols.setdefault(ch['table'], set()) if ch['type'] in ('createTable', 'addColumn') else cols.get(ch['table'], set())
                    hit = ([tb] if tb in cols and ch['type'] == 'createTable' and have else []) + ([f'{tb}.{c}' for c in ch['columns'] if c in have] if ch['type'] == 'addColumn' else [])
                    if hit and report and not guarded: issues.append(f'{fname} {cid}: {ch["type"]} {", ".join(hit)} already exists')
                    if ch['type'] == 'dropTable': cols.pop(tb, None)
                    elif ch['type'] == 'renameColumn' and ch['attrs'].get('oldColumnName', '').lower() in have:
                        have.discard(ch['attrs']['oldColumnName'].lower()); have.add(ch['attrs'].get('newColumnName', '').lower())
                    else:
                        (have.difference_update if ch['type'] == 'dropColumn' else have.update if ch['type'] in ('createTable', 'addColumn') else len)(ch['columns'])
                kinds = {local(k.tag) for k in kids} & schema
                if report and kinds and not any(local(k.tag) == 'rollback' for k in node) and not kinds <= auto:
                    issues.append(f'{fname} {cid}: {", ".join(sorted(kinds))} without a <rollback>')
            elif t == 'include' and (node.get('file') or '').lower().endswith('.xml'):   # .sql / .yaml includes are valid Liquibase
                walk(resolve(node.get('file'), os.path.dirname(path)), node.get('file'))
            elif t == 'includeAll':
                d = resolve(node.get('path') or '', os.path.dirname(path))
                for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
                    if f.endswith('.xml'): walk(os.path.join(d, f), f)

    walk(master, 'master.xml')
    print('\n'.join(issues + [f'ISSUES {len(issues)}']))
    return 1 if issues else 0

def register(dt):
    dt.VERBS['lbcheck'] = lbcheck
