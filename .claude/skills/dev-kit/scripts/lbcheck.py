"""Liquibase sanity check for any repo: replays the changelogs in master.xml order (schema only, approximate) and
flags addColumn of a column that already exists, or createTable of a table that already exists, when the changeSet
has no guarding <preConditions>. Also flags schema changeSets without a <rollback>.

  python lbcheck.py <path/to/master.xml> [sinceTimestamp]

Only files whose name starts with a timestamp >= sinceTimestamp (yyyyMMddHHmmss) are reported (default: all).
Includes are resolved relative to the classpath root (the folder above 'config/...') or to master.xml's folder.
Prints one line per issue and ends with 'ISSUES <n>'; the exit code is 1 when n > 0.
"""
import os, re, sys
import xml.etree.ElementTree as ET

sys.stdout.reconfigure(encoding='utf-8')
MASTER = os.path.abspath(sys.argv[1])
SINCE = sys.argv[2] if len(sys.argv) > 2 else '0'
MASTER_DIR = os.path.dirname(MASTER)
# classpath root: for .../resources/config/liquibase/master.xml it is .../resources
m = re.search(r'^(.*?)[\\/]config[\\/]liquibase[\\/]', MASTER)
CP_ROOT = m.group(1) if m else MASTER_DIR
SCHEMA_TAGS = {'createTable', 'addColumn', 'dropColumn', 'dropTable', 'renameColumn', 'modifyDataType',
               'addForeignKeyConstraint', 'createIndex', 'addUniqueConstraint', 'sql', 'update', 'insert', 'delete'}
AUTO_ROLLBACK = {'createTable', 'addColumn', 'renameColumn', 'createIndex', 'addForeignKeyConstraint', 'addUniqueConstraint'}

tables, issues = {}, []


def local(tag):
    return tag.split('}', 1)[-1]


def resolve(f, base):
    for p in (os.path.join(base, f), os.path.join(CP_ROOT, f.lstrip('/')), os.path.join(MASTER_DIR, f.lstrip('/'))):
        if os.path.exists(p):
            return p
    return os.path.join(CP_ROOT, f.lstrip('/'))


def apply(fname, cs, report):
    guarded = any(local(ch.tag) == 'preConditions' for ch in cs)
    has_rb = any(local(ch.tag) == 'rollback' for ch in cs)
    kinds = set()
    for el in cs.iter():
        t = local(el.tag)
        if el is not cs and t in SCHEMA_TAGS:
            kinds.add(t)
        tn = (el.get('tableName') or '').lower()
        if t == 'createTable':
            if tn in tables and report and not guarded:
                issues.append(f'{fname} {cs.get("id")}: createTable {tn} but the table already exists')
            tables.setdefault(tn, {})
            for c in el:
                if local(c.tag) == 'column':
                    tables[tn][c.get('name').lower()] = c.get('type')
        elif t == 'addColumn':
            tables.setdefault(tn, {})
            for c in el:
                if local(c.tag) == 'column':
                    cn = c.get('name').lower()
                    if cn in tables[tn] and report and not guarded:
                        issues.append(f'{fname} {cs.get("id")}: addColumn {tn}.{cn} already exists ({tables[tn][cn]})')
                    tables[tn][cn] = c.get('type')
        elif t == 'dropTable':
            tables.pop(tn, None)
        elif t == 'dropColumn':
            if tn in tables:
                tables[tn].pop((el.get('columnName') or '').lower(), None)
        elif t == 'renameColumn':
            old, new = (el.get('oldColumnName') or '').lower(), (el.get('newColumnName') or '').lower()
            if tn in tables and old in tables[tn]:
                tables[tn][new] = tables[tn].pop(old)
    if report and kinds and not has_rb and not kinds <= AUTO_ROLLBACK:
        issues.append(f'{fname} {cs.get("id")}: {", ".join(sorted(kinds))} without a <rollback>')


def walk(path, fname):
    try:
        root = ET.parse(path).getroot()
    except Exception as e:
        issues.append(f'PARSE ERROR {fname}: {e}')
        return
    ts = re.match(r'(\d{14})', os.path.basename(fname))
    report = bool(ts) and ts.group(1) >= SINCE
    for node in root:
        t = local(node.tag)
        if t == 'changeSet':
            for rb in [c for c in node if local(c.tag) == 'rollback']:
                node.remove(rb)
                node.append(ET.Element('rollback'))  # keep the marker, drop its content
            apply(fname, node, report)
        elif t == 'include':
            f = node.get('file')
            walk(resolve(f, os.path.dirname(path)), f)
        elif t == 'includeAll':
            d = resolve(node.get('path'), os.path.dirname(path))
            for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
                if f.endswith('.xml'):
                    walk(os.path.join(d, f), f)


walk(MASTER, 'master.xml')
for i in issues:
    print(i)
print('ISSUES', len(issues))
sys.exit(1 if issues else 0)
