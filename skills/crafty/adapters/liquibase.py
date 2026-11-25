# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
"""Liquibase plugin: `devtools.py lbcheck <master.xml> [since]`, the Liquibase sanity check `crafty.ps1 check -Step migrations` runs
for a repo without its own `repos[].migrations.check`. Loaded by devtools.py from skills/crafty/adapters/.
Sections: L8 lbcheck · L105 keepboth"""
import os, re, sys
import xml.etree.ElementTree as ET

# ---- lbcheck: Liquibase XML changes
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


_DT = None   # devtools module (register): its CFG = kit.local.json
LBCHECK_DEFAULTS = {'preconditions': True, 'requireRollback': False, 'tagDatabaseAlone': False, 'stampPattern': '',
                    'roots': [r'^(.*[\\/]resources)[\\/]']}


def lb_rules():
    """migrations.lbcheck: preconditions (create / add of an existing table or column without <preConditions>), requireRollback
    (schema changeSets need a <rollback>; a "not reversible" one a real one), tagDatabaseAlone (a <tagDatabase> changeSet holds
    nothing else), stampPattern (a regex whose group 1 of a file name is compared with since), roots (regexes: group 1 = an include root)."""
    own = ((getattr(_DT, 'CFG', None) or {}).get('migrations') or {}).get('lbcheck') or {}
    return {k: own.get(k, v) if own.get(k) is not None else v for k, v in LBCHECK_DEFAULTS.items()}


def lbcheck(argv):
    """Liquibase sanity check (crafty.ps1 check): replays master.xml's includes; flags (migrations.lbcheck, lb_rules) create / add
of an existing table / column without <preConditions>; requireRollback: schema changeSets without <rollback> (beyond auto-rollback
types), not-reversible ones with an empty one; tagDatabaseAlone: a <tagDatabase> changeSet with anything beside it.
Reports files whose stampPattern stamp >= since, or whose path ends with one in env LBCHECK_CHANGED ('|', repo-relative), or all
when since is 0; prints issues + 'ISSUES <n>', exit 1 if n."""
    if not argv or argv[0] in ('-h', '--help'):
        print('python devtools.py lbcheck <master.xml> [since]   Liquibase sanity check (run by crafty.ps1 check -Step migrations)')
        return 0 if argv else 2
    sys.stdout.reconfigure(encoding='utf-8')
    master, since = os.path.abspath(argv[0]), argv[1] if len(argv) > 1 else '0'
    rules = lb_rules()
    m = next((x for x in (re.search(rx, master) for rx in rules['roots'] or []) if x), None)
    roots = [m.group(1) if m else os.path.dirname(master), os.path.dirname(master)]
    changed = {f.replace('\\', '/').lower() for f in os.environ.get('LBCHECK_CHANGED', '').split('|') if f}
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
        ts = re.match(rules['stampPattern'], os.path.basename(fname)) if rules['stampPattern'] else None
        full = os.path.abspath(path).replace('\\', '/').lower()
        report = (bool(ts) and ts.group(1) >= since) or any(full.endswith('/' + c) for c in changed) or since == '0'   # a changed old one counts
        for mm in re.finditer(r'<changeSet\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</changeSet>', raw, re.S) if report and rules['requireRollback'] else ():   # ET drops comments
            rb = re.search(r'<rollback\s*/>|<rollback\b[^>]*>(.*?)</rollback>', mm.group(2), re.S)
            if re.search(r'not\s+reversible|irreversible|non-reversible|cannot\s+be\s+(rolled|reverted)|no\s+rollback', mm.group(2), re.I) and not (rb and (rb.group(1) or '').strip()):
                issues.append(f'{fname} {mm.group(1)}: marked not reversible but its <rollback> is missing or empty (a revert would fail): write a real reverse statement')
        for node in root:
            t = local(node.tag)
            if t == 'changeSet':
                kids = [k for k in node if local(k.tag) not in NON_CHANGE]
                guarded, cid = any(local(k.tag) == 'preConditions' for k in node), node.get('id')
                tagged = [local(k.tag) for k in node if local(k.tag) not in ('tagDatabase', 'preConditions', 'validCheckSum', 'modifySql')]   # a <comment> fails too (4.23 parse)
                if report and rules['tagDatabaseAlone'] and any(local(k.tag) == 'tagDatabase' for k in node) and tagged:   # the XSD allows tagDatabase alone: api start fails
                    issues.append(f'{fname} {cid}: <tagDatabase> beside <{tagged[0]}>: a tagDatabase changeSet holds nothing else (no <rollback>: Liquibase rolls a tag back itself)')
                for ch in map(xml_change, kids):
                    tb, have = ch['table'], cols.setdefault(ch['table'], set()) if ch['type'] in ('createTable', 'addColumn') else cols.get(ch['table'], set())
                    hit = ([tb] if tb in cols and ch['type'] == 'createTable' and have else []) + ([f'{tb}.{c}' for c in ch['columns'] if c in have] if ch['type'] == 'addColumn' else [])
                    if hit and report and rules['preconditions'] and not guarded: issues.append(f'{fname} {cid}: {ch["type"]} {", ".join(hit)} already exists')
                    if ch['type'] == 'dropTable': cols.pop(tb, None)
                    elif ch['type'] == 'renameColumn' and ch['attrs'].get('oldColumnName', '').lower() in have:
                        have.discard(ch['attrs']['oldColumnName'].lower()); have.add(ch['attrs'].get('newColumnName', '').lower())
                    else:
                        (have.difference_update if ch['type'] == 'dropColumn' else have.update if ch['type'] in ('createTable', 'addColumn') else len)(ch['columns'])
                kinds = {local(k.tag) for k in kids} & schema
                if report and rules['requireRollback'] and kinds and not any(local(k.tag) == 'rollback' for k in node) and not kinds <= auto:
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

# ---- keepboth: append-only rebase conflicts (any repo; a changelog master is the common case)
def keepboth(paths):
    """Resolve conflict blocks as OURS then THEIRS; append-only files only (changelog includes, route/nav lists, i18n keys,
    DI registrations, barrel exports, requirements.txt), never real code. A plugin verb (devtools.py token cap): devtools.py keepboth <file> [...]."""
    left = 0

    pat = re.compile(r'<<<<<<< [^\r\n]*\r?\n(.*?)(?:\|\|\|\|\|\|\| [^\r\n]*\r?\n.*?)?=======\r?\n(.*?)>>>>>>> [^\r\n]*(?:\r?\n|\Z)', re.S)   # last block may end the file
    for path in paths:
        text = open(path, encoding='utf-8', newline='').read()
        n = len(pat.findall(text))
        text = pat.sub(lambda m: m.group(1) + m.group(2), text)
        open(path, 'w', encoding='utf-8', newline='').write(text)
        print(path, 'resolved', n, 'block(s)')
        if re.search(r'^(<<<<<<<|>>>>>>>) ', text, re.M):   # a block the pattern missed
            print(path, 'STILL HAS CONFLICT MARKERS: resolve by hand', file=sys.stderr)
            left += 1
    return 1 if left else 0


def register(dt):
    global _DT
    _DT = dt
    dt.VERBS['lbcheck'] = lbcheck
    dt.VERBS['keepboth'] = keepboth
