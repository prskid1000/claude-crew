"""Migration audit for the local env: classify the changeSets a branch adds as LIGHT (reverted exactly when its layer leaves)
or HEAVY (sandbox / DB snapshot), and plan exact reverts. Called by localenv.ps1; never needed by hand.

  python migrations.py classify --repo <checkout> --base <ref> --head <sha> [--config <json file>] [--under a,b] [--save <dir>]
  python migrations.py plan --leaving <manifest.json,..> [--staying <manifest.json,..>] [--repo <worktree>] [--out <dir>]
  python migrations.py rules [--config <json file>]
  python migrations.py selftest
Exit codes: 0 ok · 1 error (unreadable repo, bad config) · 2 usage error.

classify: changed migration files (config "pattern", only below --under dirs) between merge-base(base, head) and head ->
  { class: light|heavy|none, changesets: [ { file, path, id, author, hash, status, class, rule, why, guarded, creates, refs } ],
    reasons: [ "<file>::<id> <rule>: <why>" ] }; --save writes <dir>/manifest.json and the files at head under <dir>/files/<file>.
plan: changeSets of the leaving layers (manifests in live order) that are not in the new release (same file/id/author/hash in
  --repo or in a staying manifest) -> { revert: [ newest first ], kept, blocked: [ staying changeSets that use what a revert
  removes ] }; --out writes <dir>/revert.json and <dir>/files: the changelog files cut down to the changeSets to revert, plus
  localenv-revert.xml including them (a Liquibase rollback-count on it can only touch those changeSets).
Rules: data-driven (DEFAULT_RULES; config "rules" replaces, "extraRules" go first); first matching rule decides; no match = light.
Parsers: Liquibase XML / YAML / JSON / formatted SQL; config "parsers" [ { match, parser | cmd } ] adds others (cmd prints the
  same changeset JSON for the file path appended to it). A migration file no parser reads is HEAVY (cannot be audited).
"""
import argparse, hashlib, json, os, re, subprocess, sys
import xml.etree.ElementTree as ET

sys.stdout.reconfigure(encoding='utf-8')

KNOWN = {'createTable', 'dropTable', 'addColumn', 'dropColumn', 'renameColumn', 'renameTable', 'modifyDataType', 'createIndex',
         'dropIndex', 'addForeignKeyConstraint', 'dropForeignKeyConstraint', 'addUniqueConstraint', 'dropUniqueConstraint',
         'addPrimaryKey', 'dropPrimaryKey', 'addNotNullConstraint', 'dropNotNullConstraint', 'addDefaultValue', 'dropDefaultValue',
         'createView', 'dropView', 'renameView', 'createSequence', 'dropSequence', 'alterSequence', 'renameSequence',
         'addAutoIncrement', 'setTableRemarks', 'setColumnRemarks', 'insert', 'update', 'delete', 'loadData', 'loadUpdateData',
         'sql', 'sqlFile', 'tagDatabase', 'customChange', 'executeCommand', 'createProcedure', 'dropProcedure', 'output', 'stop',
         'mergeColumns', 'addLookupTable', 'dropAllForeignKeyConstraints', 'empty'}
# change types Liquibase reverses by itself (no <rollback> needed)
AUTO = {'createTable', 'addColumn', 'renameColumn', 'renameTable', 'renameView', 'createIndex', 'addForeignKeyConstraint',
        'addUniqueConstraint', 'addPrimaryKey', 'addNotNullConstraint', 'dropNotNullConstraint', 'addDefaultValue', 'createView',
        'createSequence', 'tagDatabase', 'empty', 'setTableRemarks', 'setColumnRemarks'}
NON_CHANGE = {'preConditions', 'rollback', 'comment', 'validCheckSum', 'property'}

DEFAULTS = {
    'pattern': r'(?i)(^|/)(db/)?(changelog|migrations?|liquibase|flyway|alembic)(/|\.)',
    'logicalRoot': r'^(?:.*/)?src/main/resources/',   # the classpath path Liquibase records in DATABASECHANGELOG.FILENAME
    'smallDataRows': 20,
    'referenceTables': r'(?i)(^|_)(ref|lookup|types?|status(es)?|configs?|settings?|authorit(y|ies)|permissions?|roles?|menus?|features?|translations?)$',
    'heavySql': [r'\bDROP\s+(TABLE|COLUMN|DATABASE|SCHEMA)\b', r'\bTRUNCATE\b', r'\bMODIFY\b', r'\bCHANGE\s+(COLUMN\s+)?\w',
                 r'\bDELIMITER\b', r'\bCREATE\s+(DEFINER|PROCEDURE|FUNCTION|TRIGGER|EVENT)\b', r'\bRENAME\s+TABLE\b',
                 r'\bALTER\s+TABLE\b.*\bDROP\s+(?!(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK|PRIMARY\s+KEY|DEFAULT)\b)[`"]?\w',
                 r'\bON\s+DUPLICATE\s+KEY\s+UPDATE\b', r'\bREPLACE\s+INTO\b', r'\bWHERE\s+(1\s*=\s*1|TRUE|1)\s*$'],
    'lightSql': [r'^SET\s', r'^ALTER\s+TABLE\s+\S+\s+(ADD|RENAME|DROP\s+(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK))\b',
                 r'^CREATE\s+(UNIQUE\s+|FULLTEXT\s+)?INDEX\b', r'^CREATE\s+TABLE\b', r'^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b',
                 r'^DROP\s+(INDEX|VIEW)\b', r'^INSERT\s+(IGNORE\s+)?INTO\b', r'^UPDATE\b.+\bWHERE\b', r'^DELETE\s+FROM\b.+\bWHERE\b'],
}
# first matching rule decides an item (a changeSet, then each of its changes); a changeSet is HEAVY when any item is
DEFAULT_RULES = [
    {'id': 'runs-always', 'scope': 'changeset', 'attr': {'runAlways': '(?i)^true$'}, 'class': 'heavy', 'why': 'runAlways: runs on every start, no exact rollback'},
    {'id': 'runs-on-change', 'scope': 'changeset', 'attr': {'runOnChange': '(?i)^true$'}, 'class': 'heavy', 'why': 'runOnChange: re-runs when edited, no exact rollback'},
    {'id': 'edits-applied', 'scope': 'changeset', 'status': '^modified$', 'class': 'heavy', 'why': 'edits a changeSet the target already has (checksum change)'},
    {'id': 'removes-applied', 'scope': 'changeset', 'status': '^removed$', 'class': 'heavy', 'why': 'removes a changeSet the target already has'},
    {'id': 'moved-file', 'scope': 'changeset', 'status': '^renamed$', 'class': 'heavy', 'why': 'moved changelog file: its changeSets get a new identity and run again'},
    {'id': 'empty-rollback', 'scope': 'changeset', 'rollback': 'empty', 'onlyTag': False, 'class': 'heavy', 'why': 'empty <rollback>: a revert would undo nothing'},
    {'id': 'no-rollback', 'scope': 'changeset', 'rollback': 'missing', 'autoRollback': False, 'class': 'heavy', 'why': 'no <rollback>, and {types} has no automatic rollback'},
    {'id': 'tag', 'change': '^tagDatabase$', 'class': 'light'},
    {'id': 'drop-own', 'change': '^(dropTable|dropColumn)$', 'createdHere': True, 'class': 'light'},
    {'id': 'drop-data', 'change': '^(dropTable|dropColumn)$', 'class': 'heavy', 'why': 'drops {target}, which may hold data'},
    {'id': 'retype', 'change': '^modifyDataType$', 'createdHere': False, 'class': 'heavy', 'why': 'changes the type of existing column {target} (may truncate data)'},
    {'id': 'unbounded', 'change': '^(update|delete)$', 'where': False, 'class': 'heavy', 'why': 'unbounded {type} on {table} (no WHERE)'},
    {'id': 'delete-reference', 'change': '^delete$', 'table': '@referenceTables', 'class': 'light'},
    {'id': 'delete-rows', 'change': '^delete$', 'class': 'heavy', 'why': 'deletes rows of {table}: a rollback cannot restore them exactly'},
    {'id': 'bulk-file', 'change': '^(loadData|loadUpdateData|sqlFile)$', 'class': 'heavy', 'why': '{type} reads an external file that is not audited'},
    {'id': 'big-insert', 'change': '^insert$', 'rowsOver': '@smallDataRows', 'class': 'heavy', 'why': '{rows} rows into {table} (over smallDataRows)'},
    {'id': 'raw-sql', 'change': '^sql$', 'sqlUnsafe': True, 'class': 'heavy', 'why': 'raw SQL outside the light list: {stmt}'},
    {'id': 'custom', 'change': '^(customChange|executeCommand|createProcedure|dropProcedure|output|stop|mergeColumns|addLookupTable|dropAllForeignKeyConstraints)$', 'class': 'heavy', 'why': '{type}: custom or procedural change'},
    {'id': 'unknown', 'known': False, 'class': 'heavy', 'why': 'unknown change type {type}'},
]
FILE_RULES = {'unparsed': 'cannot be audited: {why}', 'raw-sql-file': 'raw SQL file outside a formatted changelog: no changeSet ids or rollback'}


def load_cfg(path):
    cfg = dict(DEFAULTS)
    if path:
        with open(path, encoding='utf-8-sig') as f:
            user = json.load(f) or {}
        cfg.update({k: v for k, v in user.items() if v is not None})
    rules = cfg.get('rules') or DEFAULT_RULES
    cfg['rules'] = list(cfg.get('extraRules') or []) + list(rules)
    return cfg


def git(repo, *a, ok=False):
    p = subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, encoding='utf-8', errors='replace')
    if p.returncode and not ok:
        raise SystemExit(f'git {" ".join(a)}: {p.stderr.strip()}')
    return p.stdout if p.returncode == 0 else None


def norm(s):
    return re.sub(r'\s+', ' ', s or '').strip()


def h(s):
    return hashlib.sha1(norm(s).encode('utf-8')).hexdigest()[:16]


def local(tag):
    return tag.split('}', 1)[-1]


def split_names(v):
    return [x.strip().strip('`"').lower() for x in (v or '').split(',') if x.strip()]


# ---------------------------------------------------------------- normalized changes
def change_from(t, attrs, cols, where, text):
    """t: change type; attrs: dict; cols: column names; where: WHERE text or None; text: SQL body."""
    tbl = (attrs.get('tableName') or attrs.get('baseTableName') or attrs.get('viewName') or '').strip('`"').lower()
    c = {'type': t, 'table': tbl, 'columns': cols, 'where': bool(norm(where)) and not re.fullmatch(r'(?i)\(?\s*(1\s*=\s*1|true|1)\s*\)?', norm(where)), 'rows': 1 if t == 'insert' else 0, 'sql': text or '',
         'creates': [], 'refs': [], 'attrs': {k: v for k, v in attrs.items() if isinstance(v, str)}}
    if t == 'createTable':
        c['creates'] = [tbl] + [f'{tbl}.{x}' for x in cols]
    elif t == 'addColumn':
        c['creates'] = [f'{tbl}.{x}' for x in cols]; c['refs'] = [tbl]
    elif t == 'createView':
        c['creates'] = [tbl]
    elif t == 'renameColumn':
        c['creates'] = [f'{tbl}.{attrs.get("newColumnName", "").lower()}']; c['refs'] = [tbl, f'{tbl}.{attrs.get("oldColumnName", "").lower()}']
    elif t == 'renameTable':
        c['creates'] = [attrs.get('newTableName', '').lower()]; c['refs'] = [attrs.get('oldTableName', '').lower()]
    elif t == 'addForeignKeyConstraint':
        rt = attrs.get('referencedTableName', '').lower()
        c['refs'] = [tbl, rt] + [f'{tbl}.{x}' for x in split_names(attrs.get('baseColumnNames'))] + [f'{rt}.{x}' for x in split_names(attrs.get('referencedColumnNames'))]
    elif t == 'sql':
        body = text or ''
        for m in re.finditer(r'(?is)\bCREATE\s+TABLE\s+(?!IF\s+NOT\s+EXISTS\b)[`"]?(\w+)', body):
            c['creates'].append(m.group(1).lower())
        for m in re.finditer(r'(?is)\bALTER\s+TABLE\s+[`"]?(\w+)[`"]?\s+ADD\s+(?:COLUMN\s+)?[`"]?(\w+)', body):
            if m.group(2).upper() not in ('INDEX', 'KEY', 'CONSTRAINT', 'UNIQUE', 'FOREIGN', 'PRIMARY', 'FULLTEXT', 'CHECK'):
                c['creates'].append(f'{m.group(1).lower()}.{m.group(2).lower()}')
        c['refs'] = sorted({m.group(1).lower() for m in re.finditer(r'(?i)\b(?:TABLE|INTO|UPDATE|FROM|JOIN|REFERENCES|ON)\s+[`"]?(\w+)', body)})
    else:
        c['refs'] = [x for x in [tbl] + [f'{tbl}.{x}' for x in cols] if x]
    return c


def xml_change(el):
    t = local(el.tag)
    a = dict(el.attrib)
    cols = [c.get('name', '').lower() for c in el.iter() if local(c.tag) == 'column' and c.get('name')]
    cols += [x for k in ('columnName', 'columnNames') for x in split_names(a.get(k))]
    where = ''.join(w.text or '' for w in el if local(w.tag) == 'where')
    text = (el.text or '') if t in ('sql', 'createProcedure') else ''
    return change_from(t, a, cols, where, text)


def yaml_change(d):
    (t, body), = d.items() if isinstance(d, dict) and len(d) == 1 else (('?', {}),)
    body = body if isinstance(body, dict) else {}
    cols = []
    for c in body.get('columns') or []:
        col = c.get('column') if isinstance(c, dict) else None
        if isinstance(col, dict) and col.get('name'):
            cols.append(str(col['name']).lower())
    cols += [x for k in ('columnName', 'columnNames') for x in split_names(str(body.get(k) or ''))]
    return change_from(t, {k: str(v) for k, v in body.items() if not isinstance(v, (list, dict))}, cols, str(body.get('where') or ''), str(body.get('sql') or ''))


# ---------------------------------------------------------------- parsers: text -> [ changeset ]
def cs_record(id_, author, attrs, changes, rb_state, rb_changes, on_fail, raw):
    return {'id': str(id_), 'author': str(author), 'attrs': {k: str(v) for k, v in attrs.items()}, 'changes': changes,
            'rollback': rb_state, 'rollbackChanges': rb_changes, 'onFail': on_fail or '', 'hash': h(raw)}


def parse_xml(text):
    root = ET.fromstring(text.lstrip('﻿').encode('utf-8'))
    if local(root.tag) != 'databaseChangeLog':
        raise ValueError('not a Liquibase XML changelog')
    out = []
    raws = re.findall(r'<changeSet\b.*?</changeSet>', re.sub(r'<!--.*?-->', '', text, flags=re.S), re.S)
    for i, cs in enumerate(el for el in root if local(el.tag) == 'changeSet'):
        changes, rb, rbc, on_fail = [], 'missing', [], ''
        for ch in cs:
            t = local(ch.tag)
            if t == 'rollback':
                kids = list(ch)
                rb = 'present' if kids or norm(ch.text) else 'empty'
                rbc = [local(k.tag) for k in kids]
            elif t == 'preConditions':
                on_fail = ch.get('onFail', 'HALT')
            elif t not in NON_CHANGE:
                changes.append(xml_change(ch))
        out.append(cs_record(cs.get('id'), cs.get('author'), cs.attrib, changes, rb, rbc, on_fail, raws[i] if i < len(raws) else ET.tostring(cs, encoding='unicode')))
    return out


def parse_struct(doc):
    out = []
    for item in (doc or {}).get('databaseChangeLog') or []:
        cs = item.get('changeSet') if isinstance(item, dict) else None
        if not isinstance(cs, dict):
            continue
        changes = [yaml_change(c) for c in cs.get('changes') or []]
        rbv = cs.get('rollback', None)
        rb = 'missing' if 'rollback' not in cs else ('present' if rbv not in (None, '', [], {}) else 'empty')
        pre = cs.get('preConditions') or []
        on_fail = next((str(p.get('onFail')) for p in pre if isinstance(p, dict) and p.get('onFail')), '') if isinstance(pre, list) else ''
        attrs = {k: v for k, v in cs.items() if not isinstance(v, (list, dict)) and k not in ('id', 'author')}
        out.append(cs_record(cs.get('id'), cs.get('author'), attrs, changes, rb, [], on_fail, json.dumps(cs, sort_keys=True, default=str)))
    return out


def parse_yaml(text):
    import yaml   # PyYAML; without it a YAML changelog is HEAVY (cannot be audited)
    return parse_struct(yaml.safe_load(text))


def parse_formatted_sql(text):
    out = []
    blocks = re.split(r'(?m)^--\s*changeset\s+', text)
    for b in blocks[1:]:
        head, _, body = b.partition('\n')
        m = re.match(r'(?:"([^"]+)"|([^:\s]+)):(\S+)(.*)', head.strip())
        if not m:
            continue
        author, id_, rest = m.group(1) or m.group(2), m.group(3), m.group(4)
        attrs = dict(re.findall(r'(\w+):(\S+)', rest))
        rb_lines = [l.split('rollback', 1)[1].strip() for l in body.splitlines() if re.match(r'\s*--\s*rollback\b', l)]
        rb = 'missing' if not rb_lines else ('empty' if all(not x or re.match(r'(?i)not\s+required|empty', x) for x in rb_lines) else 'present')
        on_fail = (re.search(r'(?im)^--\s*preconditions\s+.*onFail:(\w+)', body) or [None, ''])[1]
        sql = '\n'.join(l for l in body.splitlines() if not re.match(r'\s*--', l))
        out.append(cs_record(id_, author, attrs, [change_from('sql', {}, [], '', sql)], rb, ['sql'] if rb == 'present' else [], on_fail, b))
    return out


def parse(path, text, cfg):
    """-> (changesets or None, why-not, parser)"""
    for p in cfg.get('parsers') or []:
        if re.search(p.get('match', '$^'), path):
            if p.get('cmd'):
                r = subprocess.run(f'{p["cmd"]} "{path}"', shell=True, capture_output=True, text=True, input=text)
                if r.returncode:
                    return None, f'parser command failed: {r.stderr.strip()[:200]}', 'cmd'
                return json.loads(r.stdout).get('changesets', []), '', 'cmd'
            if p.get('parser') == 'heavy':
                return None, f'parser "heavy" set for {path}', 'heavy'
            return run_parser(p.get('parser'), path, text)
    ext = os.path.splitext(path)[1].lower()
    if ext == '.xml':
        return run_parser('liquibase-xml', path, text)
    if ext in ('.yaml', '.yml'):
        return run_parser('liquibase-yaml', path, text)
    if ext == '.json':
        return run_parser('liquibase-json', path, text)
    if ext == '.sql':
        if re.match(r'\s*--\s*liquibase\s+formatted\s+sql', text, re.I):
            return run_parser('liquibase-sql', path, text)
        return None, FILE_RULES['raw-sql-file'], 'raw-sql-file'
    return None, f'no parser for {ext or "this file"}', 'unparsed'


def run_parser(name, path, text):
    try:
        fn = {'liquibase-xml': parse_xml, 'liquibase-yaml': parse_yaml, 'liquibase-json': lambda t: parse_struct(json.loads(t)),
              'liquibase-sql': parse_formatted_sql}[name]
        return fn(text), '', name
    except KeyError:
        return None, f'unknown parser {name}', 'unparsed'
    except Exception as ex:  # noqa: BLE001 - any parse failure makes the file HEAVY
        return None, f'{name} parse failed: {str(ex)[:160]}', 'unparsed'


# ---------------------------------------------------------------- rules
def setting(v, cfg):
    return cfg.get(v[1:]) if isinstance(v, str) and v.startswith('@') else v


def sql_unsafe(body, cfg):
    s = re.sub(r'/\*.*?\*/', ' ', body or '', flags=re.S)
    s = '\n'.join(l for l in s.splitlines() if not l.strip().startswith('--'))
    for stmt in (norm(x) for x in s.split(';')):
        if not stmt:
            continue
        if any(re.search(p, stmt, re.I) for p in cfg['heavySql']) or not any(re.search(p, stmt, re.I | re.S) for p in cfg['lightSql']):
            return stmt[:90]
        if re.match(r'(?i)INSERT\b', stmt) and len(re.findall(r'\)\s*,\s*\(', stmt)) + 1 > int(cfg['smallDataRows']):
            return f'{stmt[:60]}... (over smallDataRows rows)'
        m = re.match(r'(?i)DELETE\s+FROM\s+[`"]?(?:\w+\.)?(\w+)', stmt)
        if m and not re.search(cfg['referenceTables'], m.group(1)):
            return stmt[:90]
    return None


def match(rule, item, ctx, cfg):
    """item: the changeset (scope changeset) or one change; ctx: { cs, created, rows }"""
    cs = ctx['cs']
    for k, want in rule.items():
        want = setting(want, cfg)
        if k in ('id', 'class', 'why', 'scope'):
            continue
        if k == 'status' and not re.search(want, cs['status']):
            return False
        if k == 'attr' and not all(re.search(p, cs['attrs'].get(a, '')) for a, p in want.items()):
            return False
        if k == 'rollback' and cs['rollback'] != want:
            return False
        if k == 'onlyTag' and (all(c['type'] == 'tagDatabase' for c in cs['changes'])) != want:
            return False
        if k == 'autoRollback' and (all(c['type'] in AUTO for c in cs['changes'])) != want:
            return False
        if k == 'onFail' and not re.search(want, cs['onFail']):
            return False
        if k == 'change' and not re.search(want, item.get('type', '')):
            return False
        if k == 'known' and (item.get('type') in KNOWN) != want:
            return False
        if k == 'createdHere':
            t = item.get('table', '')
            targets = [t] if item.get('type') in ('dropTable', 'createTable') or not item.get('columns') else [f'{t}.{c}' for c in item['columns']]
            if all(x in ctx['created'] or x.split('.')[0] in ctx['created'] for x in targets) != want:
                return False
        if k == 'where' and item.get('where') != want:
            return False
        if k == 'table' and not re.search(want, item.get('table', '')):
            return False
        if k == 'rowsOver' and ctx['rows'].get(item.get('table'), 0) <= int(want):
            return False
        if k == 'sqlUnsafe':
            ctx['stmt'] = sql_unsafe(item.get('sql'), cfg)
            if bool(ctx['stmt']) != want:
                return False
    return True


def judge(cs, created, cfg):
    """-> (class, rule id, why) of one changeset"""
    rows = {}
    for c in cs['changes']:
        if c['type'] == 'insert':
            rows[c['table']] = rows.get(c['table'], 0) + 1
    ctx = {'cs': cs, 'created': created, 'rows': rows, 'stmt': ''}
    items = [('changeset', cs)] + [('change', c) for c in cs['changes']]
    for scope, item in items:
        for r in cfg['rules']:
            rs = r.get('scope') or 'change'
            if rs != scope or not match(r, item, ctx, cfg):
                continue
            if r.get('class', 'heavy') == 'heavy':
                t = item.get('table', '') if scope == 'change' else ''
                tgt = ', '.join(f'{t}.{c}' for c in item.get('columns') or []) if scope == 'change' and item.get('columns') and item.get('type') != 'dropTable' else t
                why = r.get('why', r['id']).format(type=item.get('type', ''), table=t, target=tgt or t, rows=rows.get(t, 0), stmt=ctx.get('stmt') or '',
                                                   types=', '.join(sorted({c['type'] for c in cs['changes'] if c['type'] not in AUTO})) or 'it')
                return 'heavy', r['id'], why
            break   # a light rule decides this item; next item
    return 'light', '', ''


# ---------------------------------------------------------------- classify
def logical(path, cfg):
    return re.sub(cfg['logicalRoot'], '', path)


def classify(a, cfg):
    repo = a.repo
    mb = (git(repo, 'merge-base', a.base, a.head, ok=True) or '').strip() or a.base
    under = [u.strip().strip('/').replace('\\', '/') for u in (a.under or '').split(',') if u.strip()]
    tok = (git(repo, 'diff', '--name-status', '-z', '-M', mb, a.head) or '').split('\0')
    rows, i = [], 0
    while i < len(tok) and tok[i]:
        n = 3 if tok[i][0] in 'RC' else 2   # R<score>\0old\0new, else <st>\0path
        rows.append(tok[i:i + n]); i += n
    out, reasons, files, created = [], [], [], set()
    parsed = []
    for r in rows:
        st, path, old = r[0][0], r[-1], r[1] if len(r) > 2 else r[1]
        if not re.search(cfg['pattern'], path) or (under and not any(path == u or path.startswith(u + '/') for u in under)):
            continue
        head_text = git(repo, 'show', f'{a.head}:{path}', ok=True) if st != 'D' else None
        base_text = git(repo, 'show', f'{mb}:{old}', ok=True) if st in 'MRD' else None
        files.append({'path': path, 'logical': logical(path, cfg), 'status': st})
        parsed.append((st, path, old, head_text, base_text))
    for st, path, old, head_text, base_text in parsed:
        lp = logical(path, cfg)
        if (st != 'D' and head_text is None) or (st in 'MRD' and base_text is None):
            out.append({'file': lp, 'path': path, 'id': '*', 'author': '', 'hash': '', 'status': 'unparsed', 'class': 'heavy', 'rule': 'unparsed',
                        'why': FILE_RULES['unparsed'].format(why='git show could not read it'), 'guarded': False, 'creates': [], 'refs': [], 'changes': []})
            continue
        new_cs, why_h, _ = parse(path, head_text, cfg) if head_text is not None else ([], '', '')
        old_cs, why_b, _ = parse(old, base_text, cfg) if base_text is not None else ([], '', '')
        if new_cs is None or old_cs is None:
            why = why_h or why_b
            rule = 'raw-sql-file' if why == FILE_RULES['raw-sql-file'] else 'unparsed'
            out.append({'file': lp, 'path': path, 'id': '*', 'author': '', 'hash': '', 'status': 'unparsed', 'class': 'heavy', 'rule': rule,
                        'why': FILE_RULES['unparsed'].format(why=why) if rule == 'unparsed' else why, 'guarded': False, 'creates': [], 'refs': [], 'changes': []})
            continue
        if not new_cs and not old_cs:
            continue   # a master file that only includes others
        base_keys = {(c['id'], c['author']): c['hash'] for c in old_cs}
        for c in new_cs:
            k = (c['id'], c['author'])
            c['status'] = 'renamed' if st == 'R' and k in base_keys else ('added' if k not in base_keys else ('modified' if base_keys[k] != c['hash'] else 'same'))
        for c in old_cs:
            if (c['id'], c['author']) not in {(x['id'], x['author']) for x in new_cs}:
                c['status'] = 'removed'; new_cs.append(c)
        for c in new_cs:
            if c['status'] == 'same':
                continue
            c.update({'file': lp, 'path': path})
            out.append(c)
    for c in out:   # in file order: only objects EARLIER changeSets created count as "created here"
        if c['id'] == '*':
            continue
        c['class'], c['rule'], c['why'] = judge(c, created, cfg)
        if c['status'] == 'added':
            for ch in c['changes']:
                created.update(ch['creates'])
        c['guarded'] = bool(re.search(r'(?i)MARK_RAN|CONTINUE', c['onFail']))
        c['creates'] = sorted({x for ch in c['changes'] for x in ch['creates']})
        c['refs'] = sorted({x for ch in c['changes'] for x in ch['refs']} - set(c['creates']))
    for c in out:
        if c['class'] == 'heavy':
            reasons.append(f"{c['file']}::{c['id']} {c['rule']}: {c['why']}")
    res = {'repo': repo, 'base': a.base, 'mergeBase': mb, 'head': a.head, 'class': 'none' if not out else ('heavy' if reasons else 'light'),
           'reasons': reasons, 'files': files,
           'changesets': [{k: c.get(k) for k in ('file', 'path', 'id', 'author', 'hash', 'status', 'class', 'rule', 'why', 'guarded', 'creates', 'refs')} | {'types': [ch['type'] for ch in c.get('changes', [])]} for c in out]}
    if a.save:
        os.makedirs(os.path.join(a.save, 'files'), exist_ok=True)
        for f in files:
            t = git(repo, 'show', f'{a.head}:{f["path"]}', ok=True)
            if t is not None:
                dst = os.path.join(a.save, 'files', *f['logical'].split('/'))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, 'w', encoding='utf-8', newline='') as fh:
                    fh.write(t)
        res['saved'] = os.path.abspath(a.save)
        with open(os.path.join(a.save, 'manifest.json'), 'w', encoding='utf-8') as fh:
            json.dump(res, fh, indent=1)
    return res


# ---------------------------------------------------------------- plan
def key(c):
    return f"{c['file']}::{c['id']}::{c['author']}"


def cut_file(text, path, ids):
    """the changelog text with only the changeSets whose (id, author) is in ids"""
    ext = os.path.splitext(path)[1].lower()
    if ext == '.xml':
        def keep(m):
            mi, ma = re.search(r'\bid\s*=\s*"([^"]*)"', m.group(0)), re.search(r'\bauthor\s*=\s*"([^"]*)"', m.group(0))
            return m.group(0) if mi and ma and (mi.group(1), ma.group(1)) in ids else ''
        return re.sub(r'<changeSet\b.*?</changeSet>', keep, text, flags=re.S)
    if ext == '.sql':
        parts = re.split(r'(?m)^(?=--\s*changeset\s+)', text)
        kept = [parts[0]]
        for p in parts[1:]:
            m = re.match(r'--\s*changeset\s+(?:"([^"]+)"|([^:\s]+)):(\S+)', p)
            if m and ((m.group(3), m.group(1) or m.group(2)) in ids):
                kept.append(p)
        return ''.join(kept)
    doc = json.loads(text) if ext == '.json' else __import__('yaml').safe_load(text)
    doc['databaseChangeLog'] = [x for x in doc.get('databaseChangeLog') or [] if not (isinstance(x, dict) and 'changeSet' in x) or (str(x['changeSet'].get('id')), str(x['changeSet'].get('author'))) in ids]
    return json.dumps(doc, indent=1) if ext == '.json' else __import__('yaml').safe_dump(doc, sort_keys=False)


def plan(a, cfg):
    load = lambda paths: [json.load(open(p, encoding='utf-8-sig')) | {'_path': p} for p in (paths or '').split(',') if p.strip()]
    leaving, staying = load(a.leaving), load(a.staying)
    stay = {(key(c), c['hash']) for m in staying for c in m.get('changesets', [])}
    in_tree = {}
    if a.repo:
        for m in leaving:
            for f in {c['path'] for c in m.get('changesets', [])}:
                p = os.path.join(a.repo, *f.split('/'))
                if f not in in_tree:
                    try:
                        cs, _, _ = parse(f, open(p, encoding='utf-8').read(), cfg) if os.path.exists(p) else ([], '', '')
                    except OSError:
                        cs = []
                    in_tree[f] = {(c['id'], c['author']): c['hash'] for c in cs or []}
    revert, kept = [], []
    for m in reversed(leaving):   # newest layer first, its changeSets newest first
        for c in reversed(m.get('changesets', [])):
            if c['id'] == '*' or c['status'] == 'removed':
                continue
            if (key(c), c['hash']) in stay or in_tree.get(c['path'], {}).get((c['id'], c['author'])) == c['hash']:
                kept.append({'key': key(c), 'why': 'still in the release (target or another layer)'})
            else:
                revert.append(c | {'layer': m.get('layer') or os.path.dirname(m['_path'])})
    # objects a revert removes that no staying changeSet creates again; a staying changeSet that uses one blocks the revert
    gone = {x for c in revert for x in c.get('creates', [])} - {x for m in staying for c in m.get('changesets', []) for x in c.get('creates', [])}
    blocked = []
    for m in staying:
        for c in m.get('changesets', []):
            hit = sorted(set(c.get('refs', [])) & gone)
            if hit:
                blocked.append({'key': key(c), 'layer': m.get('layer') or os.path.dirname(m['_path']), 'uses': hit})
    res = {'revert': [{k: c[k] for k in ('file', 'path', 'id', 'author', 'hash', 'guarded', 'layer')} for c in revert], 'kept': kept, 'blocked': blocked, 'count': len(revert)}
    if a.out and revert:
        fd = os.path.join(a.out, 'files')
        os.makedirs(fd, exist_ok=True)
        by_file = {}
        for c in revert:
            by_file.setdefault((c['file'], c['path']), set()).add((c['id'], c['author']))
        src_dirs = {c['file']: m.get('saved') for m in leaving for c in m.get('changesets', [])}
        for (lf, path), ids in by_file.items():
            src = os.path.join(src_dirs.get(lf) or '', 'files', *lf.split('/'))
            text = open(src, encoding='utf-8').read() if os.path.exists(src) else ''
            dst = os.path.join(fd, *lf.split('/'))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, 'w', encoding='utf-8', newline='') as fh:
                fh.write(cut_file(text, path, ids))
        inc = ''.join(f'  <include file="{lf}" relativeToChangelogFile="false"/>\n' for lf, _ in by_file)
        with open(os.path.join(fd, 'localenv-revert.xml'), 'w', encoding='utf-8') as fh:
            fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog" '
                     'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog '
                     'http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">\n' + inc + '</databaseChangeLog>\n')
        res['searchPath'] = os.path.abspath(fd); res['changelog'] = 'localenv-revert.xml'
        with open(os.path.join(a.out, 'revert.json'), 'w', encoding='utf-8') as fh:
            json.dump(res, fh, indent=1)
        res['manifest'] = os.path.abspath(os.path.join(a.out, 'revert.json'))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['classify', 'plan', 'rules'])
    for o in ('--repo', '--base', '--head', '--config', '--under', '--save', '--leaving', '--staying', '--out'):
        ap.add_argument(o)
    a = ap.parse_args()
    cfg = load_cfg(a.config)
    if a.cmd == 'rules':
        res = {'rules': cfg['rules'], **{k: cfg[k] for k in DEFAULTS}}
    elif a.cmd == 'classify':
        res = classify(a, cfg)
    else:
        res = plan(a, cfg)
    print(json.dumps(res, indent=1))



# ---------------------------------------------------------------- selftest: classification of sample changelog diffs + revert plans
# (needs git; builds throwaway repos in a temp folder)   python -X utf8 migrations.py selftest   exit 0 = all pass
SELFTEST = r'''import json, os, shutil, subprocess, sys, tempfile, unittest

SCRIPT = os.path.abspath(__file__)
CL = 'api/src/main/resources/config/liquibase/changelog'
HEAD = ('<?xml version="1.0" encoding="utf-8"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">\n')
TAIL = '</databaseChangeLog>\n'


def xml(*changesets):
    return HEAD + ''.join(changesets) + TAIL


def cs(id_, body, rollback=None, attrs='', pre=''):
    rb = '' if rollback is None else (f'<rollback>{rollback}</rollback>' if rollback else '<rollback/>')
    return f'  <changeSet id="{id_}" author="dev"{attrs}>{pre}{body}{rb}</changeSet>\n'


TAG = lambda t: cs(f'{t}-0', f'<tagDatabase tag="{t}"/>')


def run(*a):
    p = subprocess.run([sys.executable, '-X', 'utf8', SCRIPT, *a], capture_output=True, text=True, encoding='utf-8')
    if p.returncode:
        raise AssertionError(p.stderr)
    return json.loads(p.stdout)


class Repo:
    def __init__(self):
        self.d = tempfile.mkdtemp(prefix='mig-test-')
        self.g('init', '-q', '-b', 'main'); self.g('config', 'user.email', 't@t'); self.g('config', 'user.name', 't')
        self.write(f'{CL}/20260101000000_base.xml', xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/><column name="qty" type="INT"/></createTable>')))
        self.write('api/src/main/java/App.java', 'class App {}')
        self.commit('base')

    def g(self, *a):
        return subprocess.run(['git', '-C', self.d, *a], capture_output=True, text=True, check=True).stdout.strip()

    def write(self, rel, text):
        p = os.path.join(self.d, *rel.split('/'))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w', encoding='utf-8', newline='\n').write(text)

    def commit(self, msg):
        self.g('add', '-A'); self.g('commit', '-q', '-m', msg); return self.g('rev-parse', 'HEAD')

    def branch(self, name, files, base='main'):
        self.g('checkout', '-q', '-b', name, base)
        for rel, text in files.items():
            if text is None:
                os.remove(os.path.join(self.d, *rel.split('/')))
            else:
                self.write(rel, text)
        sha = self.commit(name); self.g('checkout', '-q', 'main'); return sha

    def classify(self, sha, save=None, cfg=None):
        a = ['classify', '--repo', self.d, '--base', 'main', '--head', sha]
        if save:
            a += ['--save', save]
        if cfg:
            p = os.path.join(self.d, '..', os.path.basename(self.d) + '-cfg.json'); open(p, 'w', encoding='utf-8').write(json.dumps(cfg)); a += ['--config', p]
        return run(*a)


LIGHT_FILE = xml(TAG('20260201000000'),
                 cs('20260201000000-1', '<addColumn tableName="orders"><column name="note" type="VARCHAR(80)"/></addColumn>',
                    '<dropColumn tableName="orders" columnName="note"/>', pre='<preConditions onFail="MARK_RAN"><not><columnExists tableName="orders" columnName="note"/></not></preConditions>'),
                 cs('20260201000000-2', '<createTable tableName="order_status"><column name="id" type="INT"/><column name="code" type="VARCHAR(20)"/></createTable>'),
                 cs('20260201000000-3', '<insert tableName="order_status"><column name="id" valueNumeric="1"/><column name="code" value="NEW"/></insert>',
                    '<delete tableName="order_status"><where>id = 1</where></delete>'),
                 cs('20260201000000-4', '<update tableName="orders"><column name="qty" valueNumeric="0"/><where>qty IS NULL AND id IN (SELECT id FROM orders WHERE 1=0)</where></update>',
                    '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>'),
                 cs('20260201000000-5', '<sql>ALTER TABLE orders ADD INDEX ix_orders_qty (qty)</sql>', '<sql>ALTER TABLE orders DROP INDEX ix_orders_qty</sql>'))


class Classify(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.r = Repo()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.r.d, ignore_errors=True)

    def test_light(self):
        sha = self.r.branch('light', {f'{CL}/20260201000000_light.xml': LIGHT_FILE})
        res = self.r.classify(sha)
        self.assertEqual(res['class'], 'light', res['reasons'])
        self.assertEqual([c['id'] for c in res['changesets']], [f'20260201000000-{i}' for i in range(6)])
        self.assertEqual(res['changesets'][0]['file'], 'config/liquibase/changelog/20260201000000_light.xml')
        self.assertTrue(res['changesets'][1]['guarded'])
        self.assertIn('order_status', res['changesets'][2]['creates'])

    def test_no_migrations(self):
        sha = self.r.branch('code-only', {'api/src/main/java/App.java': 'class App { int x; }'})
        self.assertEqual(self.r.classify(sha)['class'], 'none')

    def heavy(self, name, body, rule, rollback='', **kw):
        sha = self.r.branch(name, {f'{CL}/20260301000000_{name}.xml': xml(TAG('20260301000000'), cs('20260301000000-1', body, rollback, **kw))})
        res = self.r.classify(sha)
        self.assertEqual(res['class'], 'heavy', f'{name}: {res}')
        self.assertEqual(res['changesets'][1]['rule'], rule, res['reasons'])
        return res

    def test_heavy_rules(self):
        self.heavy('dropcol', '<dropColumn tableName="orders" columnName="qty"/>', 'drop-data', '<addColumn tableName="orders"><column name="qty" type="INT"/></addColumn>')
        self.heavy('droptable', '<dropTable tableName="orders"/>', 'drop-data', '<sql>CREATE TABLE orders (id BIGINT)</sql>')
        self.heavy('unbounded', '<update tableName="orders"><column name="qty" valueNumeric="0"/></update>', 'unbounded', '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>')
        self.heavy('delrows', '<delete tableName="orders"><where>qty = 0</where></delete>', 'delete-rows', '<sql>SELECT 1</sql>')
        self.heavy('emptyrb', '<addColumn tableName="orders"><column name="x" type="INT"/></addColumn>', 'empty-rollback', '')
        self.heavy('norb', '<sql>ALTER TABLE orders ADD COLUMN y INT</sql>', 'no-rollback', None)
        self.heavy('always', '<sql>ALTER TABLE orders ADD COLUMN z INT</sql>', 'runs-always', '<sql>ALTER TABLE orders DROP INDEX z</sql>', attrs=' runAlways="true"')
        self.heavy('rawsql', '<sql>ALTER TABLE orders MODIFY qty BIGINT</sql>', 'raw-sql', '<sql>ALTER TABLE orders MODIFY qty INT</sql>')
        self.heavy('retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="SMALLINT"/>', 'retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="INT"/>')
        self.heavy('loaddata', '<loadData tableName="orders" file="x.csv"/>', 'bulk-file', '<sql>SELECT 1</sql>')

    def test_order_and_sql_gaps_are_heavy(self):
        # drop an existing column, add it back later: the first changeSet still drops data
        sha = self.r.branch('dropreadd', {f'{CL}/20260402000000_x.xml': xml(
            cs('20260402000000-1', '<dropColumn tableName="orders" columnName="qty"/>', '<addColumn tableName="orders"><column name="qty" type="INT"/></addColumn>'),
            cs('20260402000000-2', '<addColumn tableName="orders"><column name="qty" type="INT"/></addColumn>'))})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'drop-data'), res['reasons'])
        # CREATE TABLE IF NOT EXISTS then a drop of it: the table may have existed
        sha = self.r.branch('ifnot', {f'{CL}/20260403000000_x.xml': xml(
            cs('20260403000000-1', '<sql>CREATE TABLE IF NOT EXISTS orders (id BIGINT)</sql>', '<sql>SELECT 1</sql>'),
            cs('20260403000000-2', '<dropTable tableName="orders"/>', '<sql>CREATE TABLE orders (id BIGINT)</sql>'))})
        self.assertEqual(self.r.classify(sha)['changesets'][1]['rule'], 'drop-data')
        for name, body in (('altdrop', 'ALTER TABLE orders ADD note INT, DROP qty'), ('upsert', 'INSERT INTO orders (id) VALUES (1) ON DUPLICATE KEY UPDATE qty = 0'),
                           ('trivwhere', 'UPDATE orders SET qty = 0 WHERE 1=1')):
            self.heavy(name, f'<sql>{body}</sql>', 'raw-sql', '<sql>SELECT 1</sql>')
        self.heavy('trivxml', '<update tableName="orders"><column name="qty" valueNumeric="0"/><where>1=1</where></update>', 'unbounded', '<sql>SELECT 1</sql>')

    def test_non_ascii_path_is_read(self):
        sha = self.r.branch('uml', {f'{CL}/20260404000000_bestellung_\u00e4.xml': xml(cs('20260404000000-1', '<dropTable tableName="orders"/>', '<sql>CREATE TABLE orders (id BIGINT)</sql>'))})
        self.assertEqual(self.r.classify(sha)['class'], 'heavy')

    def test_drop_own_is_light(self):
        sha = self.r.branch('dropown', {f'{CL}/20260401000000_own.xml': xml(
            cs('20260401000000-1', '<addColumn tableName="orders"><column name="tmp" type="INT"/></addColumn>'),
            cs('20260401000000-2', '<dropColumn tableName="orders" columnName="tmp"/>', '<addColumn tableName="orders"><column name="tmp" type="INT"/></addColumn>'))})
        self.assertEqual(self.r.classify(sha)['class'], 'light')

    def test_edit_applied_and_raw_file(self):
        base = f'{CL}/20260101000000_base.xml'
        sha = self.r.branch('edit', {base: xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/></createTable>'))})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'edits-applied'))
        sha = self.r.branch('rawfile', {'api/src/main/resources/db/migrations/V2__x.sql': 'UPDATE orders SET qty = 1;'})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'raw-sql-file'))

    def test_mixed_is_heavy_and_names_the_changeset(self):
        sha = self.r.branch('mixed', {f'{CL}/20260501000000_mixed.xml': xml(
            TAG('20260501000000'), cs('20260501000000-1', '<addColumn tableName="orders"><column name="ok" type="INT"/></addColumn>'),
            cs('20260501000000-2', '<delete tableName="orders"/>', '<sql>SELECT 1</sql>'))})
        res = self.r.classify(sha)
        self.assertEqual(res['class'], 'heavy')
        self.assertEqual([c['class'] for c in res['changesets']], ['light', 'light', 'heavy'])
        self.assertEqual(res['reasons'], ['config/liquibase/changelog/20260501000000_mixed.xml::20260501000000-2 unbounded: unbounded delete on orders (no WHERE)'])

    def test_formatted_sql_and_yaml(self):
        sql = ('--liquibase formatted sql\n--changeset dev:20260601000000-1\nALTER TABLE orders ADD COLUMN s INT;\n'
               '--rollback ALTER TABLE orders DROP COLUMN s;\n--changeset dev:20260601000000-2\nDELETE FROM orders WHERE id > 5;\n--rollback not required\n')
        sha = self.r.branch('fsql', {f'{CL}/20260601000000_x.sql': sql})
        res = self.r.classify(sha)
        self.assertEqual([(c['class'], c['rule']) for c in res['changesets']], [('light', ''), ('heavy', 'empty-rollback')])
        yml = ('databaseChangeLog:\n- changeSet:\n    id: 20260701000000-1\n    author: dev\n    changes:\n    - addColumn:\n        tableName: orders\n'
               '        columns:\n        - column:\n            name: y\n            type: INT\n')
        sha = self.r.branch('yml', {f'{CL}/20260701000000_x.yaml': yml})
        res = self.r.classify(sha)
        try:
            import yaml  # noqa: F401
            self.assertEqual(res['class'], 'light', res)
        except ImportError:
            self.assertEqual(res['changesets'][0]['rule'], 'unparsed')

    def test_rules_are_configurable(self):
        sha = self.r.branch('cfg', {f'{CL}/20260801000000_x.xml': xml(cs('20260801000000-1', '<delete tableName="orders"><where>id = 1</where></delete>', '<sql>SELECT 1</sql>'))})
        self.assertEqual(self.r.classify(sha)['class'], 'heavy')
        self.assertEqual(self.r.classify(sha, cfg={'referenceTables': '^orders$'})['class'], 'light')
        res = self.r.classify(sha, cfg={'extraRules': [{'id': 'no-orders', 'table': '^orders$', 'class': 'heavy', 'why': 'org rule'}], 'referenceTables': '^orders$'})
        self.assertEqual(res['changesets'][0]['rule'], 'no-orders')


class Plan(unittest.TestCase):
    def setUp(self):
        self.r = Repo(); self.tmp = tempfile.mkdtemp(prefix='mig-plan-')

    def tearDown(self):
        shutil.rmtree(self.r.d, ignore_errors=True); shutil.rmtree(self.tmp, ignore_errors=True)

    def manifest(self, name, sha):
        d = os.path.join(self.tmp, name); self.r.classify(sha, save=d); return os.path.join(d, 'manifest.json')

    def test_revert_only_the_leaving_layer_newest_first(self):
        a = self.manifest('a', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
        b = self.manifest('b', self.r.branch('b', {f'{CL}/20260901000000_b.xml': xml(cs('20260901000000-1', '<createIndex tableName="orders" indexName="ix_q"><column name="qty"/></createIndex>'))}))
        out = os.path.join(self.tmp, 'out')
        res = run('plan', '--leaving', a, '--staying', b, '--repo', self.r.d, '--out', out)
        self.assertEqual([c['id'] for c in res['revert']], [f'20260201000000-{i}' for i in (5, 4, 3, 2, 1, 0)])
        self.assertEqual(res['blocked'], [])
        cut = open(os.path.join(res['searchPath'], 'config', 'liquibase', 'changelog', '20260201000000_light.xml'), encoding='utf-8').read()
        self.assertEqual(cut.count('<changeSet'), 6)
        self.assertIn('config/liquibase/changelog/20260201000000_light.xml', open(os.path.join(res['searchPath'], 'localenv-revert.xml'), encoding='utf-8').read())

    def test_dependent_layer_blocks(self):
        a = self.manifest('a', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
        c = self.manifest('c', self.r.branch('c', {f'{CL}/20261001000000_c.xml': xml(cs('20261001000000-1',
            '<addForeignKeyConstraint baseTableName="orders" baseColumnNames="qty" constraintName="fk_orders_qty" referencedTableName="order_status" referencedColumnNames="id"/>'))}))
        res = run('plan', '--leaving', a, '--staying', c)
        self.assertEqual(res['blocked'][0]['uses'], ['order_status', 'order_status.id'])

    def test_changesets_still_in_release_are_kept(self):
        sha = self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE})
        a = self.manifest('a', sha)
        self.r.g('merge', '-q', '--no-ff', '-m', 'merged', 'a')   # the layer was merged into the target: nothing to revert
        res = run('plan', '--leaving', a, '--repo', self.r.d)
        self.assertEqual((res['count'], len(res['kept'])), (0, 6))

    def test_replaced_layer_reverts_only_what_changed(self):
        a1 = self.manifest('a1', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
        self.r.g('checkout', '-q', 'a')
        self.r.write(f'{CL}/20260201000000_light.xml', LIGHT_FILE.replace('VARCHAR(80)', 'VARCHAR(120)'))
        a2sha = self.r.commit('a v2'); self.r.g('checkout', '-q', 'main')
        a2 = self.manifest('a2', a2sha)
        res = run('plan', '--leaving', a1, '--staying', a2)
        self.assertEqual([c['id'] for c in res['revert']], ['20260201000000-1'])
'''


def selftest():
    import unittest
    ns = {'__file__': os.path.abspath(__file__), '__name__': 'migrations_selftest'}
    exec(compile(SELFTEST, 'migrations-selftest', 'exec'), ns)
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(v) for v in ns.values() if isinstance(v, type) and issubclass(v, unittest.TestCase))
    return 0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1


if __name__ == '__main__':
    if sys.argv[1:2] == ['selftest']:
        sys.exit(selftest())
    main()
