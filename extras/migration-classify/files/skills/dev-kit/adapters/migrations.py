"""Extra migration-classify: devtools.py migrations classify|plan|rules|detect|selftest (LIGHT / HEAVY migration classes and
exact revert plans for the local env). Loaded by devtools.py from skills/dev-kit/adapters/; installed by kittool.py extra add."""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile
import xml.etree.ElementTree as ET
# ===== migrations: local env migration audit (run by localenv.ps1). LIGHT changeSets revert when their layer leaves; HEAVY need a snapshot.
#   python devtools.py migrations classify --repo <checkout> --base <ref> --head <sha> [--config <json>] [--under a,b] [--save <dir>]
#   | plan --leaving <manifest,..> [--staying <manifest,..>] [--repo <worktree>] [--out <dir>] | rules|detect [--repo <dir>] | selftest
# Exit: 0 ok · 1 error · 2 usage. classify -> { class: light|heavy|none, changesets [ file, path, id, author, hash, status, class, rule,
#   why, guarded, creates, refs, x (tool vars) ], reasons, tools }. plan -> { revert (newest first), kept, blocked, commands, hook (count
#   left to db.rollback) }; --out: revert.json, files/, localenv-revert.xml. Rules: DEFAULT_RULES ("rules" replaces, "extraRules" first;
#   first match decides); SQL lists per "dialect". Parsers: Liquibase, MIG_TOOLS, config "parsers" [ { match, parser | cmd } ].
# Sections: L76 config · L115 parse · L373 rules · L440 classify · L552 plan · L640 cli · L673 selftest · L978 entry
KNOWN = {'createTable', 'dropTable', 'addColumn', 'dropColumn', 'renameColumn', 'renameTable', 'modifyDataType', 'createIndex',
  'dropIndex', 'addForeignKeyConstraint', 'dropForeignKeyConstraint', 'addUniqueConstraint', 'dropUniqueConstraint',
  'addPrimaryKey', 'dropPrimaryKey', 'addNotNullConstraint', 'dropNotNullConstraint', 'addDefaultValue', 'dropDefaultValue',
  'createView', 'dropView', 'renameView', 'createSequence', 'dropSequence', 'alterSequence', 'renameSequence',
  'addAutoIncrement', 'setTableRemarks', 'setColumnRemarks', 'insert', 'update', 'delete', 'loadData', 'loadUpdateData',
  'sql', 'sqlFile', 'tagDatabase', 'customChange', 'executeCommand', 'createProcedure', 'dropProcedure', 'output', 'stop',
  'mergeColumns', 'addLookupTable', 'dropAllForeignKeyConstraints', 'empty'}
# change types Liquibase auto-reverses (no <rollback> needed)
AUTO = {'createTable', 'addColumn', 'renameColumn', 'renameTable', 'renameView', 'createIndex', 'addForeignKeyConstraint',
  'addUniqueConstraint', 'addPrimaryKey', 'addNotNullConstraint', 'dropNotNullConstraint', 'addDefaultValue', 'createView',
  'createSequence', 'tagDatabase', 'empty', 'setTableRemarks', 'setColumnRemarks'}
NON_CHANGE = {'preConditions', 'rollback', 'comment', 'validCheckSum', 'property'}

DEFAULTS = {
 'pattern': r'(?i)(^|/)(db/)?(changelog|migrations?|migrate|liquibase|flyway|alembic)(/|\.)(?!(?:.*\.)?(?:md|txt|rst)$)',   # not docs
 'logicalRoot': r'^(?:.*/)?src/main/resources/',   # classpath path (DATABASECHANGELOG.FILENAME)
 'smallDataRows': 20,
 'referenceTables': r'(?i)(^|_)(ref|lookup|types?|status(es)?|configs?|settings?|authorit(y|ies)|permissions?|roles?|menus?|features?|translations?)$',
 'dialect': '',   # a DIALECTS key (localenv: db.engine); '' = every set (strictest)
 'heavySql': [r'\bDROP\s+(TABLE|COLUMN|DATABASE|SCHEMA)\b', r'\bTRUNCATE\b', r'\bCREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION|TRIGGER)\b',
    r'\bRENAME\s+TABLE\b', r'\bALTER\s+TABLE\b.*\bDROP\s+(?!(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK|PRIMARY\s+KEY|DEFAULT)\b)[`"]?\w',
    r'\bWHERE\s+(1\s*=\s*1|TRUE|1)\s*$'],
 'lightSql': [r'^SET\s', r'^ALTER\s+TABLE\s+\S+\s+(ADD|RENAME|DROP\s+(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK))\b',
    r'^CREATE\s+(UNIQUE\s+)?INDEX\b', r'^CREATE\s+TABLE\b', r'^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b', r'^(BEGIN|COMMIT|END|START\s+TRANSACTION)$',
    r'^DROP\s+(INDEX|VIEW)\b', r'^INSERT\s+INTO\b', r'^UPDATE\b.+\bWHERE\b', r'^DELETE\s+FROM\b.+\bWHERE\b'],
}
# dialect: (heavySql, lightSql) added to the common lists
DIALECTS = {
 'mysql': ([r'\bMODIFY\b', r'\bCHANGE\s+(COLUMN\s+)?\w', r'\bDELIMITER\b', r'\bCREATE\s+(DEFINER|EVENT)\b', r'\bON\s+DUPLICATE\s+KEY\s+UPDATE\b',
      r'\bREPLACE\s+INTO\b'], [r'^INSERT\s+IGNORE\s+INTO\b', r'^CREATE\s+FULLTEXT\s+INDEX\b']),
 'postgres': ([r'\bALTER\s+COLUMN\s+\S+\s+(SET\s+DATA\s+)?TYPE\b', r'\bON\s+CONFLICT\b.*\bDO\s+UPDATE\b', r'\bDO\s+\$', r'\bCREATE\s+(OR\s+REPLACE\s+)?RULE\b'],
       [r'^CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY\b', r'^CREATE\s+(TYPE|SEQUENCE|EXTENSION\s+IF\s+NOT\s+EXISTS)\b', r'^COMMENT\s+ON\b']),
 'sqlserver': ([r'\bsp_rename\b', r'\bALTER\s+COLUMN\b', r'^MERGE\b', r'^EXEC(UTE)?\b'], [r'^CREATE\s+(UNIQUE\s+)?(NON)?CLUSTERED\s+INDEX\b']),
 'sqlite': ([r'^PRAGMA\b', r'\bINSERT\s+INTO\s+\S+\s+SELECT\b'], []),
 'oracle': ([r'\bMODIFY\b', r'^MERGE\s+INTO\b', r'^(BEGIN|DECLARE)\s+\S', r'\bEXECUTE\s+IMMEDIATE\b'], [r'^CREATE\s+SEQUENCE\b', r'^COMMENT\s+ON\b']),
}
DIALECTS['mariadb'] = DIALECTS['mysql']
DIALECT_ALIAS = {'postgresql': 'postgres', 'pg': 'postgres', 'mssql': 'sqlserver', 'mongo': 'mongodb'}
# first match decides each item (changeSet, then each change); a HEAVY item makes the changeSet HEAVY
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


# ---- config: rules config, git, small helpers
def load_cfg(path):
    cfg = dict(DEFAULTS)
    if path:
        with open(path, encoding='utf-8-sig') as f: user = json.load(f) or {}
        cfg.update({k: v for k, v in user.items() if v is not None})
    rules = cfg.get('rules') or DEFAULT_RULES
    cfg['rules'] = list(cfg.get('extraRules') or []) + list(rules)
    dia = (cfg.get('dialect') or '').lower()
    cfg['dialect'] = DIALECT_ALIAS.get(dia, dia)   # db.engine spellings
    for d, (hv, lt) in DIALECTS.items():
        if (cfg['dialect'] or d) == d:
            cfg['heavySql'], cfg['lightSql'] = list(cfg['heavySql']) + hv, list(cfg['lightSql']) + lt
    return cfg


def git(repo, *a, ok=False):
    p = subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, encoding='utf-8', errors='replace')
    if p.returncode and not ok: raise SystemExit(f'git {" ".join(a)}: {p.stderr.strip()}')
    return p.stdout if p.returncode == 0 else None


def norm(s):
    return re.sub(r'\s+', ' ', s or '').strip()


def h(s):
    return hashlib.sha1(norm(s).encode('utf-8')).hexdigest()[:16]


def local(tag):
    return tag.split('}', 1)[-1]


def split_names(v):
    return [x.strip().strip('`"').lower() for x in (v or '').split(',') if x.strip()]


# --- normalized changes
# ---- parse: changeSets from Liquibase XML / YAML / SQL and other tools
def change_from(t, attrs, cols, where, text):
    """t: change type; attrs: dict; cols: column names; where: WHERE text or None; text: SQL body."""
    tbl = (attrs.get('tableName') or attrs.get('baseTableName') or attrs.get('viewName') or '').strip('`"').lower()
    c = {'type': t, 'table': tbl, 'columns': cols, 'where': bool(norm(where)) and not re.fullmatch(r'(?i)\(?\s*(1\s*=\s*1|true|1)\s*\)?', norm(where)), 'rows': 1 if t == 'insert' else 0, 'sql': text or '',
     'creates': [], 'refs': [], 'attrs': {k: v for k, v in attrs.items() if isinstance(v, str)}}
    if t == 'createTable': c['creates'] = [tbl] + [f'{tbl}.{x}' for x in cols]
    elif t == 'addColumn': c['creates'] = [f'{tbl}.{x}' for x in cols]; c['refs'] = [tbl]
    elif t == 'createView': c['creates'] = [tbl]
    elif t == 'renameColumn':
        c['creates'] = [f'{tbl}.{attrs.get("newColumnName", "").lower()}']; c['refs'] = [tbl, f'{tbl}.{attrs.get("oldColumnName", "").lower()}']
    elif t == 'renameTable': c['creates'] = [attrs.get('newTableName', '').lower()]; c['refs'] = [attrs.get('oldTableName', '').lower()]
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
        if isinstance(col, dict) and col.get('name'): cols.append(str(col['name']).lower())
    cols += [x for k in ('columnName', 'columnNames') for x in split_names(str(body.get(k) or ''))]
    return change_from(t, {k: str(v) for k, v in body.items() if not isinstance(v, (list, dict))}, cols, str(body.get('where') or ''), str(body.get('sql') or ''))


# --- parsers: text -> [ changeset ]
def cs_record(id_, author, attrs, changes, rb_state, rb_changes, on_fail, raw):
    return {'id': str(id_), 'author': str(author), 'attrs': {k: str(v) for k, v in attrs.items()}, 'changes': changes,
      'rollback': rb_state, 'rollbackChanges': rb_changes, 'onFail': on_fail or '', 'hash': h(raw)}


def parse_xml(text):
    root = ET.fromstring(text.lstrip('﻿').encode('utf-8'))
    if local(root.tag) != 'databaseChangeLog': raise ValueError('not a Liquibase XML changelog')
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
            elif t == 'preConditions': on_fail = ch.get('onFail', 'HALT')
            elif t not in NON_CHANGE: changes.append(xml_change(ch))
        out.append(cs_record(cs.get('id'), cs.get('author'), cs.attrib, changes, rb, rbc, on_fail, raws[i] if i < len(raws) else ET.tostring(cs, encoding='unicode')))
    return out


def parse_struct(doc):
    out = []
    for item in (doc or {}).get('databaseChangeLog') or []:
        cs = item.get('changeSet') if isinstance(item, dict) else None
        if not isinstance(cs, dict): continue
        changes = [yaml_change(c) for c in cs.get('changes') or []]
        rbv = cs.get('rollback', None)
        rb = 'missing' if 'rollback' not in cs else ('present' if rbv not in (None, '', [], {}) else 'empty')
        pre = cs.get('preConditions') or []
        on_fail = next((str(p.get('onFail')) for p in pre if isinstance(p, dict) and p.get('onFail')), '') if isinstance(pre, list) else ''
        attrs = {k: v for k, v in cs.items() if not isinstance(v, (list, dict)) and k not in ('id', 'author')}
        out.append(cs_record(cs.get('id'), cs.get('author'), attrs, changes, rb, [], on_fail, json.dumps(cs, sort_keys=True, default=str)))
    return out


def parse_yaml(text):
    import yaml   # PyYAML; absent -> YAML is HEAVY
    return parse_struct(yaml.safe_load(text))


def parse_formatted_sql(text):
    out = []
    blocks = re.split(r'(?m)^--\s*changeset\s+', text)
    for b in blocks[1:]:
        head, _, body = b.partition('\n')
        m = re.match(r'(?:"([^"]+)"|([^:\s]+)):(\S+)(.*)', head.strip())
        if not m: continue
        author, id_, rest = m.group(1) or m.group(2), m.group(3), m.group(4)
        attrs = dict(re.findall(r'(\w+):(\S+)', rest))
        rb_lines = [l.split('rollback', 1)[1].strip() for l in body.splitlines() if re.match(r'\s*--\s*rollback\b', l)]
        rb = 'missing' if not rb_lines else ('empty' if all(not x or re.match(r'(?i)not\s+required|empty', x) for x in rb_lines) else 'present')
        on_fail = (re.search(r'(?im)^--\s*preconditions\s+.*onFail:(\w+)', body) or [None, ''])[1]
        sql = '\n'.join(l for l in body.splitlines() if not re.match(r'\s*--', l))
        out.append(cs_record(id_, author, attrs, [change_from('sql', {}, [], '', sql)], rb, ['sql'] if rb == 'present' else [], on_fail, b))
    return out


# --- other tools: one file (prisma: folder) = one changeSet, id = its version, rollback = its down part (a down file: regex
# + replacement on the path, or the in-file split). Commands run in the folder of the nearest marker: {id} {v} {prev} {app}
# {file} {down} {dir}; ordered: a revert also undoes every newer migration of its folder (2: any other, a revision chain).
SQLF = r'[^/]*\.sql$'
MIG_TOOLS = {
 'flyway': {'file': r'(^|/)(?:(?P<r>R)|V(?P<v>\d[\w.]*?))__(?P<n>[^/]*)\.sql$', 'down': (r'(^|/)V([^/]*)$', r'\1U\2'), 'marker': ('flyway.conf', 'flyway.toml'),
      'apply': 'flyway migrate', 'revert': 'flyway undo', 'dry': 'flyway migrate -dryRunOutput=flyway-dry-run.sql', 'ordered': 1},
 'prisma': {'file': r'(^|/)migrations/(?P<v>\d+_[^/]+)/migration\.sql$', 'down': (r'migration\.sql$', 'down.sql'), 'marker': ('package.json',),
      'apply': 'npx prisma migrate deploy', 'revert': 'npx prisma db execute --file "{down}" && npx prisma migrate resolve --rolled-back {id}', 'dry': 'npx prisma migrate status'},
 'sqitch': {'file': r'(^|/)deploy/(?P<v>[^/]+)\.sql$', 'down': (r'(^|/)deploy/', r'\1revert/'), 'marker': ('sqitch.plan',),
      'apply': 'sqitch deploy', 'revert': 'sqitch revert -y --to {id}^', 'dry': 'sqitch status', 'ordered': 1},
 'goose': {'file': r'(^|/)(?P<v>\d+)_' + SQLF, 'split': (r'(?im)^--\s*\+goose\s+up\b', r'(?im)^--\s*\+goose\s+down\b'),
      'apply': 'goose -dir "{dir}" up', 'revert': 'goose -dir "{dir}" down-to {prev}', 'dry': 'goose -dir "{dir}" status', 'first': '0', 'ordered': 1},
 'sql': {'file': r'(^|/)(?P<v>\d+)[_.-]' + SQLF, 'down': (r'\.up\.sql$', '.down.sql'), 'revert': '{exec}'},
 'alembic': {'file': r'(^|/)versions/(?P<v>\w+?)(_\w*)?\.py$', 'split': (r'(?m)^def\s+upgrade\b', r'(?m)^def\s+downgrade\b'), 'marker': ('alembic.ini',),
       'id': r'(?m)^revision\s*(?::[^=\n]*)?=\s*[\'"](\w+)', 'prev': r'(?m)^down_revision\s*(?::[^=\n]*)?=\s*[\'"](\w+)', 'first': 'base',
       'apply': 'alembic upgrade head', 'revert': 'alembic downgrade {prev}', 'dry': 'alembic upgrade head --sql', 'ordered': 2},
 'django': {'file': r'(^|/)(?P<app>\w+)/migrations/(?P<v>\d{4}_\w+)\.py$', 'auto': '', 'marker': ('manage.py',), 'first': 'zero',
      'apply': 'python manage.py migrate', 'revert': 'python manage.py migrate {app} {prev}', 'dry': 'python manage.py sqlmigrate {app} {id}', 'ordered': 1},
 'efcore': {'file': r'(^|/)(?P<v>\d{14}_\w+)\.cs$', 'split': (r'\bvoid\s+Up\s*\(', r'\bvoid\s+Down\s*\('), 'marker': ('.csproj',), 'first': '0',
      'apply': 'dotnet ef database update', 'revert': 'dotnet ef database update {prev}', 'dry': 'dotnet ef migrations script --idempotent', 'ordered': 1},
 'rails': {'file': r'(^|/)db/migrate/(?P<v>\d{14})_\w+\.rb$', 'split': (r'\bdef\s+(up|change)\b', r'\bdef\s+down\b'), 'auto': r'\bdef\s+change\b', 'marker': ('Gemfile',),
      'apply': 'bin/rails db:migrate', 'revert': 'bin/rails db:migrate:down VERSION={v}', 'dry': 'bin/rails db:migrate:status'},
 'knex': {'file': r'(^|/)migrations/(?P<v>\d{14})_[^/]+\.[cm]?[jt]s$', 'split': (r'\bup\b\s*[(=:]|function\s+up\b', r'\bdown\b\s*[(=:]|function\s+down\b'),
     'marker': ('knexfile.js', 'knexfile.ts', 'package.json'), 'apply': 'npx knex migrate:latest', 'revert': 'npx knex migrate:down {file}', 'dry': 'npx knex migrate:list'},
}
# down files (read with their up) and tool plumbing: never a changeSet of their own
NOT_MIG = re.compile(r'\.down\.sql$|(^|/)U\d[^/]*__[^/]*\.sql$|(^|/)revert/[^/]+\.sql$|/down\.sql$|(^|/)(__init__|env)\.py$|\.Designer\.cs$|ModelSnapshot\.cs$|'
                     r'migration_lock\.toml$|(^|/)sqitch\.(plan|conf)$|\.(md|txt|mako)$')
MIG_EXT = r'(?i)\.(sql|xml|ya?ml|json|py|rb|php|exs?|[cm]?[jt]s|go|cs|java|kt)$'
# code calls -> change types; '' = a table block (its column calls belong to it)
OPS = {'createtable': 'createTable', 'createmodel': 'createTable', 'addcolumn': 'addColumn', 'addfield': 'addColumn', 'addreference': 'addColumn',
 'dropcolumn': 'dropColumn', 'removecolumn': 'dropColumn', 'removefield': 'dropColumn', 'droptable': 'dropTable', 'deletemodel': 'dropTable',
 'droptableifexists': 'dropTable', 'altercolumn': 'modifyDataType', 'alterfield': 'modifyDataType', 'changecolumn': 'modifyDataType', 'alter': 'modifyDataType',
 'renamecolumn': 'renameColumn', 'renamefield': 'renameColumn', 'renametable': 'renameTable', 'renamemodel': 'renameTable', 'createindex': 'createIndex',
 'addindex': 'createIndex', 'index': 'createIndex', 'dropindex': 'dropIndex', 'removeindex': 'dropIndex', 'createforeignkey': 'addForeignKeyConstraint',
 'addforeignkey': 'addForeignKeyConstraint', 'dropforeignkey': 'dropForeignKeyConstraint', 'removeforeignkey': 'dropForeignKeyConstraint',
 'createuniqueconstraint': 'addUniqueConstraint', 'addconstraint': 'addUniqueConstraint', 'unique': 'addUniqueConstraint', 'dropconstraint': 'dropUniqueConstraint',
 'execute': 'sql', 'sql': 'sql', 'raw': 'sql', 'runsql': 'sql', 'bulkinsert': 'insert', 'insertdata': 'insert', 'insert': 'insert', 'updatedata': 'update',
 'update': 'update', 'deletedata': 'delete', 'del': 'delete', 'runpython': 'customChange', 'altertable': '', 'table': '', 'changetable': ''}
COL_TYPES = set('string text integer int bigint biginteger smallint float decimal double boolean bool date datetime timestamp timestamps time uuid json jsonb '
                'binary enu enum increments bigincrements references belongs_to'.split())
CALL = re.compile(r'(?:\b(\w+)\.)?\b([A-Za-z_]\w*)\s*(?:<[^<>()]*>)?(\(|[ \t]+:(?=\w))')


def mig_tool(path, text, cfg):
    """-> (name, preset, path match) of the tool owning path, else (None, None, None)"""
    for n, t in MIG_TOOLS.items():
        m = re.search(t['file'], path)
        if m and cfg.get('tool') in (None, '', 'auto', n) and not NOT_MIG.search(path) and (not t.get('split') or re.search(t['split'][0], text or '')):
            return n, t, m
    return None, None, None


def split_ud(text, t):
    sp = t.get('split')
    if not sp: return text, None
    d = re.search(sp[1], text)
    return (text[:d.start()], text[d.end():]) if d else (text, None)


def code_changes(up):
    out, cur = [], ''
    for m in CALL.finditer(up):
        pre, k = (m.group(1) or '').lower(), m.group(2).replace('_', '').lower()
        col = pre in ('t', 'table', 'tbl') and k in COL_TYPES
        if k not in OPS and not col: continue
        if m.group(3) == '(':
            d, j = 1, m.end()
            while j < len(up) and d: d += {'(': 1, ')': -1}.get(up[j], 0); j += 1
            a = up[m.end():j]
        else:
            a = up[m.end():].split('\n', 1)[0]
        kw = dict(re.findall(r'(\w+)\s*[=:]\s*[\'"`](\w+)', a))
        lits = [x or y for x, y in re.findall(r'[\'"`](\w+)[\'"`]|(?<![\w:]):(\w+)', a)]
        tbl = next((kw[x] for x in ('table', 'table_name', 'model_name', 'tableName') if x in kw), '')
        if col: out.append(change_from('addColumn', {'tableName': cur}, lits[:1], '', '')); continue
        typ = OPS[k]
        tbl = tbl or (lits[0] if lits else cur)
        if not typ: cur = tbl; continue
        if typ == 'createTable': cur = tbl
        cols = [kw['name'].lower()] if 'name' in kw and tbl != kw['name'] else [x.lower() for x in lits[1:2]]
        s = re.search(r'(?s)("""|\'\'\'|"|\'|`)(.*?)(?<!\\)\1', a) if typ == 'sql' else None
        h = re.match(r'(?s)\s*<<[~-]?([A-Z]+)\n(.*?)\n\s*\1', up[m.end():]) if typ == 'sql' else None
        out.append(change_from(typ, {'tableName': tbl} if typ != 'sql' else {}, cols, 'x' if re.search(r'(?i)\bwhere\b|keyColumn|filter\(', a) else '',
                   (h.group(2) if h else s.group(2) if s else a)))
    return out


def parse_tool(path, text, cfg, read):
    """a migration of a MIG_TOOLS tool -> [ its one changeSet ]"""
    n, t, m = mig_tool(path, text, cfg)
    up, down = split_ud(text, t)
    if t.get('down'):
        dp = re.sub(*t['down'], path)
        down = read(dp) if dp != path else None
    sql = path.endswith('.sql')
    ch = [change_from('sql', {}, [], '', up)] if sql else code_changes(up)
    live = lambda s: s is not None and bool(re.sub(r'(?m)^\s*(--|#|//).*$|\bpass\b|[\s{}();]|\bend\b|\breturn\b', '', s))
    rb = 'missing' if down is None else ('present' if (live(down) if sql else code_changes(down) or re.search(r'\bexecute|\.sql\(|raw\(', down)) else 'empty')
    if 'auto' in t and (not t['auto'] or re.search(t['auto'], text)):
        rb = 'present' if len(re.findall(r'reverse_\w+\s*=', text)) >= len(re.findall(r'\bRun(SQL|Python)\(', text)) > 0 else 'missing'
    idm = re.search(t['id'], text) if t.get('id') else None
    v = idm.group(1) if idm else m.group('v') or m.group('n')
    attrs = {'runOnChange': 'true'} if m.groupdict().get('r') == 'R' else {}
    x = {'tool': n, 'v': m.group('v') or m.group('n'), 'app': m.groupdict().get('app') or '', 'file': os.path.basename(path), 'prev': ''}
    if t.get('prev'): p = re.search(t['prev'], text); x['prev'] = p.group(1) if p else t.get('first', '')
    cs = cs_record(v, '', attrs, ch, rb, [], '', text + (down or ''))
    cs['x'] = x
    return [cs]


def parse(path, text, cfg, read=None):
    """-> (changesets or None, why-not, parser); read(path) -> text of another file (a down file)"""
    for p in cfg.get('parsers') or []:
        if re.search(p.get('match', '$^'), path):
            if p.get('cmd'):
                r = subprocess.run(f'{p["cmd"]} "{path}"', shell=True, capture_output=True, text=True, input=text)
                if r.returncode: return None, f'parser command failed: {r.stderr.strip()[:200]}', 'cmd'
                return json.loads(r.stdout).get('changesets', []), '', 'cmd'
            if p.get('parser') == 'heavy': return None, f'parser "heavy" set for {path}', 'heavy'
            return run_parser(p.get('parser'), path, text)
    ext = os.path.splitext(path)[1].lower()
    if ext == '.xml': return run_parser('liquibase-xml', path, text)
    if ext in ('.yaml', '.yml'): return run_parser('liquibase-yaml', path, text)
    if ext == '.json': return run_parser('liquibase-json', path, text)
    if ext == '.sql' and re.match(r'\s*--\s*liquibase\s+formatted\s+sql', text, re.I): return run_parser('liquibase-sql', path, text)
    if mig_tool(path, text, cfg)[0]:
        try:
            return parse_tool(path, text, cfg, read or (lambda p: None)), '', 'tool'
        except Exception as ex:  # noqa: BLE001 - HEAVY
            return None, f'parse failed: {str(ex)[:160]}', 'unparsed'
    if ext == '.sql': return None, FILE_RULES['raw-sql-file'], 'raw-sql-file'
    return None, f'no parser for {ext or "this file"}', 'unparsed'


def run_parser(name, path, text):
    try:
        fn = {'liquibase-xml': parse_xml, 'liquibase-yaml': parse_yaml, 'liquibase-json': lambda t: parse_struct(json.loads(t)),
         'liquibase-sql': parse_formatted_sql}[name]
        return fn(text), '', name
    except KeyError: return None, f'unknown parser {name}', 'unparsed'
    except Exception as ex:  # noqa: BLE001 - any parse failure makes the file HEAVY
        return None, f'{name} parse failed: {str(ex)[:160]}', 'unparsed'


# --- rules
# ---- rules: the LIGHT / HEAVY judgement
def setting(v, cfg):
    return cfg.get(v[1:]) if isinstance(v, str) and v.startswith('@') else v


def sql_unsafe(body, cfg):
    s = re.sub(r'/\*.*?\*/', ' ', body or '', flags=re.S)
    s = '\n'.join(l for l in s.splitlines() if not l.strip().startswith('--'))
    for stmt in (norm(x) for x in s.split(';')):
        if not stmt: continue
        if any(re.search(p, stmt, re.I) for p in cfg['heavySql']) or not any(re.search(p, stmt, re.I | re.S) for p in cfg['lightSql']): return stmt[:90]
        if re.match(r'(?i)INSERT\b', stmt) and len(re.findall(r'\)\s*,\s*\(', stmt)) + 1 > int(cfg['smallDataRows']):
            return f'{stmt[:60]}... (over smallDataRows rows)'
        m = re.match(r'(?i)DELETE\s+FROM\s+[`"]?(?:\w+\.)?(\w+)', stmt)
        if m and not re.search(cfg['referenceTables'], m.group(1)): return stmt[:90]
    return None


def match(rule, item, ctx, cfg):
    """item: the changeset (scope changeset) or one change; ctx: { cs, created, rows }"""
    cs = ctx['cs']
    for k, want in rule.items():
        want = setting(want, cfg)
        if k in ('id', 'class', 'why', 'scope'): continue
        if k == 'status' and not re.search(want, cs['status']): return False
        if k == 'attr' and not all(re.search(p, cs['attrs'].get(a, '')) for a, p in want.items()): return False
        if k == 'rollback' and cs['rollback'] != want: return False
        if k == 'onlyTag' and (all(c['type'] == 'tagDatabase' for c in cs['changes'])) != want: return False
        if k == 'autoRollback' and (all(c['type'] in AUTO for c in cs['changes'])) != want: return False
        if k == 'onFail' and not re.search(want, cs['onFail']): return False
        if k == 'change' and not re.search(want, item.get('type', '')): return False
        if k == 'known' and (item.get('type') in KNOWN) != want: return False
        if k == 'createdHere':
            t = item.get('table', '')
            targets = [t] if item.get('type') in ('dropTable', 'createTable') or not item.get('columns') else [f'{t}.{c}' for c in item['columns']]
            if all(x in ctx['created'] or x.split('.')[0] in ctx['created'] for x in targets) != want: return False
        if k == 'where' and item.get('where') != want: return False
        if k == 'table' and not re.search(want, item.get('table', '')): return False
        if k == 'rowsOver' and ctx['rows'].get(item.get('table'), 0) <= int(want): return False
        if k == 'sqlUnsafe':
            ctx['stmt'] = sql_unsafe(item.get('sql'), cfg)
            if bool(ctx['stmt']) != want: return False
    return True


def judge(cs, created, cfg):
    """-> (class, rule id, why) of one changeset"""
    rows = {}
    for c in cs['changes']:
        if c['type'] == 'insert': rows[c['table']] = rows.get(c['table'], 0) + 1
    ctx = {'cs': cs, 'created': created, 'rows': rows, 'stmt': ''}
    items = [('changeset', cs)] + [('change', c) for c in cs['changes']]
    for scope, item in items:
        for r in cfg['rules']:
            rs = r.get('scope') or 'change'
            if rs != scope or not match(r, item, ctx, cfg): continue
            if r.get('class', 'heavy') == 'heavy':
                t = item.get('table', '') if scope == 'change' else ''
                tgt = ', '.join(f'{t}.{c}' for c in item.get('columns') or []) if scope == 'change' and item.get('columns') and item.get('type') != 'dropTable' else t
                why = r.get('why', r['id']).format(type=item.get('type', ''), table=t, target=tgt or t, rows=rows.get(t, 0), stmt=ctx.get('stmt') or '',
                        types=', '.join(sorted({c['type'] for c in cs['changes'] if c['type'] not in AUTO})) or 'it')
                return 'heavy', r['id'], why
            break   # light rule decides; next item
    return 'light', '', ''


# --- classify
# ---- classify: the classify verb
def logical(path, cfg):
    return re.sub(cfg['logicalRoot'], '', path)


def vkey(v):
    return [(0, int(p), '') if p.isdigit() else (1, 0, p) for p in re.split(r'(\d+)', str(v)) if p]


def tool_ctx(x, path, repo, head, tree):
    """x += cwd (nearest marker folder, else the repo top), dir, down (relative to cwd), prev (the version before, by order)"""
    if not tree:
        for f in (git(repo, 'ls-tree', '-r', '--name-only', head, ok=True) or '').splitlines(): tree.setdefault(os.path.dirname(f), []).append(f)
    t = MIG_TOOLS[x['tool']]
    d = os.path.dirname(path)
    folder = os.path.dirname(d) if x['tool'] == 'prisma' else d
    cwd = d
    while cwd and not any(os.path.basename(f) == mk or (mk[0] == '.' and f.endswith(mk)) for f in tree.get(cwd, []) for mk in t.get('marker', ())):
        cwd = os.path.dirname(cwd)
    rel = lambda p: os.path.relpath(p or '.', cwd or '.').replace('\\', '/')
    x.update(cwd=cwd, dir=rel(d))
    if t.get('down'): x['down'] = rel(re.sub(*t['down'], path))
    if not x['prev']:
        sib = sorted({mm.group('v') for f in (tree.get(folder, []) if x['tool'] != 'prisma' else [g for k, fs in tree.items() if os.path.dirname(k) == folder for g in fs])
               for mm in [re.search(t['file'], f)] if mm and not NOT_MIG.search(f) and (mm.groupdict().get('app') or '') == x['app']}, key=vkey)
        before = [s for s in sib if vkey(s) < vkey(x['v'])]
        x['prev'] = before[-1] if before else t.get('first', '0')


def fill_cmd(cmd, id_, x, exec_=''):
    cmd = (cmd or '').replace('{exec}', (exec_ or '').replace('{file}', '"{down}"'))
    for k in ('v', 'prev', 'app', 'file', 'down', 'dir'): cmd = cmd.replace('{' + k + '}', str(x.get(k, '')))
    return cmd.replace('{id}', str(id_))


def classify(a, cfg):
    repo = a.repo
    mb = (git(repo, 'merge-base', a.base, a.head, ok=True) or '').strip() or a.base
    under = [u.strip().strip('/').replace('\\', '/') for u in (a.under or '').split(',') if u.strip()]
    tok = (git(repo, 'diff', '--name-status', '-z', '-M', mb, a.head) or '').split('\0')
    rows, i = [], 0
    while i < len(tok) and tok[i]:
        n = 3 if tok[i][0] in 'RC' else 2   # R<score>\0old\0new, else <st>\0path
        rows.append(tok[i:i + n]); i += n
    out, reasons, files, created, tree = [], [], [], set(), {}
    parsed = []
    for r in rows:
        st, path, old = r[0][0], r[-1], r[1] if len(r) > 2 else r[1]
        if not (re.search(cfg['pattern'], path) or any(re.search(t['file'], path) for t in MIG_TOOLS.values())) or NOT_MIG.search(path) or (
          under and not any(path == u or path.startswith(u + '/') for u in under)):
            continue
        head_text = git(repo, 'show', f'{a.head}:{path}', ok=True) if st != 'D' else None
        base_text = git(repo, 'show', f'{mb}:{old}', ok=True) if st in 'MRD' else None
        if not re.search(cfg['pattern'], path) and not mig_tool(path, head_text or base_text or '', cfg)[0]:
            continue   # a tool's file name only, not its content
        files.append({'path': path, 'logical': logical(path, cfg), 'status': st})
        parsed.append((st, path, old, head_text, base_text))
    for st, path, old, head_text, base_text in parsed:
        lp = logical(path, cfg)
        if (st != 'D' and head_text is None) or (st in 'MRD' and base_text is None):
            out.append({'file': lp, 'path': path, 'id': '*', 'author': '', 'hash': '', 'status': 'unparsed', 'class': 'heavy', 'rule': 'unparsed',
               'why': FILE_RULES['unparsed'].format(why='git show could not read it'), 'guarded': False, 'creates': [], 'refs': [], 'changes': []})
            continue
        new_cs, why_h, _ = parse(path, head_text, cfg, lambda p: git(repo, 'show', f'{a.head}:{p}', ok=True)) if head_text is not None else ([], '', '')
        old_cs, why_b, _ = parse(old, base_text, cfg, lambda p: git(repo, 'show', f'{mb}:{p}', ok=True)) if base_text is not None else ([], '', '')
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
            if (c['id'], c['author']) not in {(x['id'], x['author']) for x in new_cs}: c['status'] = 'removed'; new_cs.append(c)
        for c in new_cs:
            if c['status'] == 'same': continue
            c.update({'file': lp, 'path': path})
            if c.get('x'): tool_ctx(c['x'], path, repo, a.head, tree)
            out.append(c)
    for c in out:   # file order: only EARLIER changeSets' objects count as "created here"
        if c['id'] == '*': continue
        c['class'], c['rule'], c['why'] = judge(c, created, cfg)
        if c['status'] == 'added':
            for ch in c['changes']: created.update(ch['creates'])
        c['guarded'] = bool(re.search(r'(?i)MARK_RAN|CONTINUE', c['onFail']))
        c['creates'] = sorted({x for ch in c['changes'] for x in ch['creates']})
        c['refs'] = sorted({x for ch in c['changes'] for x in ch['refs']} - set(c['creates']))
    for c in out:
        if c['class'] == 'heavy': reasons.append(f"{c['file']}::{c['id']} {c['rule']}: {c['why']}")
    res = {'repo': repo, 'base': a.base, 'mergeBase': mb, 'head': a.head, 'class': 'none' if not out else ('heavy' if reasons else 'light'),
     'reasons': reasons, 'files': files, 'tools': {c['x']['tool']: {'cwd': c['x']['cwd'], **{k: fill_cmd(MIG_TOOLS[c['x']['tool']].get(k), c['id'], c['x'])
      for k in ('apply', 'dry')}} for c in out if c.get('x')},
     'changesets': [{k: c.get(k) for k in ('file', 'path', 'id', 'author', 'hash', 'status', 'class', 'rule', 'why', 'guarded', 'creates', 'refs', 'x')} | {'types': [ch['type'] for ch in c.get('changes', [])]} for c in out]}
    if a.save:
        os.makedirs(os.path.join(a.save, 'files'), exist_ok=True)
        for f in files:
            t = git(repo, 'show', f'{a.head}:{f["path"]}', ok=True)
            if t is not None:
                dst = os.path.join(a.save, 'files', *f['logical'].split('/'))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, 'w', encoding='utf-8', newline='') as fh: fh.write(t)
        res['saved'] = os.path.abspath(a.save)
        with open(os.path.join(a.save, 'manifest.json'), 'w', encoding='utf-8') as fh: json.dump(res, fh, indent=1)
    return res


# --- plan
# ---- plan: the exact revert plan
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
            if m and ((m.group(3), m.group(1) or m.group(2)) in ids): kept.append(p)
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
                        rd = lambda q: open(os.path.join(a.repo, *q.split('/')), encoding='utf-8').read() if os.path.exists(os.path.join(a.repo, *q.split('/'))) else None
                        cs, _, _ = parse(f, rd(f), cfg, rd) if os.path.exists(p) else ([], '', '')
                    except OSError: cs = []
                    in_tree[f] = {(c['id'], c['author']): c['hash'] for c in cs or []}
    revert, kept = [], []
    for m in reversed(leaving):   # newest layer first, its changeSets newest first
        for c in reversed(m.get('changesets', [])):
            if c['id'] == '*' or c['status'] == 'removed': continue
            if (key(c), c['hash']) in stay or in_tree.get(c['path'], {}).get((c['id'], c['author'])) == c['hash']:
                kept.append({'key': key(c), 'why': 'still in the release (target or another layer)'})
            else:
                revert.append(c | {'layer': m.get('layer') or os.path.dirname(m['_path'])})
    # a staying changeSet using what a revert drops (and nothing recreates) blocks it
    gone = {x for c in revert for x in c.get('creates', [])} - {x for m in staying for c in m.get('changesets', []) for x in c.get('creates', [])}
    blocked = []
    for m in staying:
        for c in m.get('changesets', []):
            hit = sorted(set(c.get('refs', [])) & gone)
            sx = c.get('x') or {}   # an ordered tool reverts by version: a newer staying migration of the folder goes too
            hit += [f"{sx['tool']} order: newer than {r['id']}" for r in revert if MIG_TOOLS.get(sx.get('tool'), {}).get('ordered') and (r.get('x') or {}).get('tool') == sx['tool']
                and (r['x']['cwd'], r['x']['dir']) == (sx['cwd'], sx['dir']) and (vkey(sx['v']) > vkey(r['x']['v']) or MIG_TOOLS[sx['tool']]['ordered'] == 2)][:1]
            if hit: blocked.append({'key': key(c), 'layer': m.get('layer') or os.path.dirname(m['_path']), 'uses': hit})
    for c in revert:
        x = c.get('x')
        c['cmd'] = fill_cmd(MIG_TOOLS[x['tool']].get('revert'), c['id'], x, cfg.get('exec')) if x else ''
        if x and x['tool'] == 'sql' and not (cfg.get('exec') and x.get('down')):
            c['cmd'] = ''   # no down script or no migrations.exec: db.rollback decides
    res = {'revert': [{k: c.get(k) for k in ('file', 'path', 'id', 'author', 'hash', 'guarded', 'layer', 'x', 'cmd')} for c in revert], 'kept': kept, 'blocked': blocked, 'count': len(revert),
       'commands': [{'cwd': c['x']['cwd'], 'cmd': c['cmd']} for c in revert if c['cmd']], 'hook': sum(1 for c in revert if not c['cmd'])}
    if a.out and revert:
        fd = os.path.join(a.out, 'files')
        os.makedirs(fd, exist_ok=True)
        by_file = {}
        for c in (c for c in revert if not c.get('x')): by_file.setdefault((c['file'], c['path']), set()).add((c['id'], c['author']))
        src_dirs = {c['file']: m.get('saved') for m in leaving for c in m.get('changesets', [])}
        for (lf, path), ids in by_file.items():
            src = os.path.join(src_dirs.get(lf) or '', 'files', *lf.split('/'))
            text = open(src, encoding='utf-8').read() if os.path.exists(src) else ''
            dst = os.path.join(fd, *lf.split('/'))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, 'w', encoding='utf-8', newline='') as fh: fh.write(cut_file(text, path, ids))
        inc = ''.join(f'  <include file="{lf}" relativeToChangelogFile="false"/>\n' for lf, _ in by_file)
        with open(os.path.join(fd, 'localenv-revert.xml'), 'w', encoding='utf-8') as fh:
            fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog" '
                   'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog '
                   'http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">\n' + inc + '</databaseChangeLog>\n')
        res['searchPath'] = os.path.abspath(fd); res['changelog'] = 'localenv-revert.xml'
        with open(os.path.join(a.out, 'revert.json'), 'w', encoding='utf-8') as fh: json.dump(res, fh, indent=1)
        res['manifest'] = os.path.abspath(os.path.join(a.out, 'revert.json'))
    return res


# ---- cli: arguments and the JSON result
def mig_main(argv):
    print(json.dumps(mig_result(argv), indent=1))


def mig_result(argv):
    ap = argparse.ArgumentParser(prog='devtools.py migrations')
    ap.add_argument('cmd', choices=['classify', 'plan', 'rules', 'detect'])
    for o in ('--repo', '--base', '--head', '--config', '--under', '--save', '--leaving', '--staying', '--out'): ap.add_argument(o)
    a = ap.parse_args(argv)
    cfg = load_cfg(a.config)
    if a.cmd == 'rules': res = {'rules': cfg['rules'], **{k: cfg[k] for k in DEFAULTS}}
    elif a.cmd == 'detect':   # tracked migrations per tool, Liquibase aside (dev.ps1 check -Step migrations)
        res, unknown = {}, []
        fs = (git(a.repo, 'ls-files') or '').splitlines()
        lb_master = any(re.search(r'(?i)master\.(xml|ya?ml|json|sql)$', f) for f in fs)
        for f in fs:
            lb, n = re.search(r'(?i)liquibase|changelog', f), None
            if any(re.search(t['file'], f) for t in MIG_TOOLS.values()) and not lb:
                p = os.path.join(a.repo, *f.split('/'))
                n = mig_tool(f, open(p, encoding='utf-8', errors='replace').read() if os.path.isfile(p) else '', cfg)[0]
                if n: res[n] = res.get(n, 0) + 1
            # no tool parses it: UNRUN
            if not n and re.search(cfg['pattern'], f) and not NOT_MIG.search(f) and not (lb and lb_master) and re.search(MIG_EXT, f):
                unknown.append(f)
        if unknown: res['unknown tool'] = ', '.join(unknown[:5])
    elif a.cmd == 'classify': res = classify(a, cfg)
    else:
        res = plan(a, cfg)
    return res



# ---- selftest: temp-repo cases (python -X utf8 devtools.py migrations selftest)
# --- selftest (git, temp repos): python -X utf8 devtools.py migrations selftest; exit 0 = all pass
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
ADD = lambda c: f'<addColumn tableName="orders"><column name="{c}" type="INT"/></addColumn>'
DROP = lambda c: f'<dropColumn tableName="orders" columnName="{c}"/>'
SEL, MK, DT = '<sql>SELECT 1</sql>', '<sql>CREATE TABLE orders (id BIGINT)</sql>', '<dropTable tableName="orders"/>'


def run(*a):   # in-process: a python start per call made the selftest 30 s
 return json.loads(json.dumps(mig_result(list(a))))


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
     DROP('note'), pre='<preConditions onFail="MARK_RAN"><not><columnExists tableName="orders" columnName="note"/></not></preConditions>'),
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
  self.heavy('dropcol', DROP('qty'), 'drop-data', ADD('qty'))
  self.heavy('droptable', DT, 'drop-data', MK)
  self.heavy('unbounded', '<update tableName="orders"><column name="qty" valueNumeric="0"/></update>', 'unbounded', '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>')
  self.heavy('delrows', '<delete tableName="orders"><where>qty = 0</where></delete>', 'delete-rows', SEL)
  self.heavy('emptyrb', ADD('x'), 'empty-rollback', '')
  self.heavy('norb', '<sql>ALTER TABLE orders ADD COLUMN y INT</sql>', 'no-rollback', None)
  self.heavy('always', '<sql>ALTER TABLE orders ADD COLUMN z INT</sql>', 'runs-always', '<sql>ALTER TABLE orders DROP INDEX z</sql>', attrs=' runAlways="true"')
  self.heavy('rawsql', '<sql>ALTER TABLE orders MODIFY qty BIGINT</sql>', 'raw-sql', '<sql>ALTER TABLE orders MODIFY qty INT</sql>')
  self.heavy('retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="SMALLINT"/>', 'retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="INT"/>')
  self.heavy('loaddata', '<loadData tableName="orders" file="x.csv"/>', 'bulk-file', SEL)

 def test_order_and_sql_gaps_are_heavy(self):
  # drop an existing column, add it back later: the first changeSet still drops data
  sha = self.r.branch('dropreadd', {f'{CL}/20260402000000_x.xml': xml(
   cs('20260402000000-1', DROP('qty'), ADD('qty')),
   cs('20260402000000-2', ADD('qty')))})
  res = self.r.classify(sha)
  self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'drop-data'), res['reasons'])
  # CREATE TABLE IF NOT EXISTS then a drop of it: the table may have existed
  sha = self.r.branch('ifnot', {f'{CL}/20260403000000_x.xml': xml(
   cs('20260403000000-1', '<sql>CREATE TABLE IF NOT EXISTS orders (id BIGINT)</sql>', SEL),
   cs('20260403000000-2', DT, MK))})
  self.assertEqual(self.r.classify(sha)['changesets'][1]['rule'], 'drop-data')
  for name, body in (('altdrop', 'ALTER TABLE orders ADD note INT, DROP qty'), ('upsert', 'INSERT INTO orders (id) VALUES (1) ON DUPLICATE KEY UPDATE qty = 0'),
             ('trivwhere', 'UPDATE orders SET qty = 0 WHERE 1=1')):
   self.heavy(name, f'<sql>{body}</sql>', 'raw-sql', SEL)
  self.heavy('trivxml', '<update tableName="orders"><column name="qty" valueNumeric="0"/><where>1=1</where></update>', 'unbounded', SEL)

 def test_non_ascii_path_is_read(self):
  sha = self.r.branch('uml', {f'{CL}/20260404000000_bestellung_\u00e4.xml': xml(cs('20260404000000-1', DT, MK))})
  self.assertEqual(self.r.classify(sha)['class'], 'heavy')

 def test_drop_own_is_light(self):
  sha = self.r.branch('dropown', {f'{CL}/20260401000000_own.xml': xml(
   cs('20260401000000-1', ADD('tmp')),
   cs('20260401000000-2', DROP('tmp'), ADD('tmp')))})
  self.assertEqual(self.r.classify(sha)['class'], 'light')

 def test_edit_applied_and_raw_file(self):
  base = f'{CL}/20260101000000_base.xml'
  sha = self.r.branch('edit', {base: xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/></createTable>'))})
  res = self.r.classify(sha)
  self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'edits-applied'))
  sha = self.r.branch('rawfile', {'api/src/main/resources/db/migrations/fix.sql': 'UPDATE orders SET qty = 1;'})
  res = self.r.classify(sha)
  self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'raw-sql-file'))

 def test_mixed_is_heavy_and_names_the_changeset(self):
  sha = self.r.branch('mixed', {f'{CL}/20260501000000_mixed.xml': xml(
   TAG('20260501000000'), cs('20260501000000-1', ADD('ok')),
   cs('20260501000000-2', '<delete tableName="orders"/>', SEL))})
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
  sha = self.r.branch('cfg', {f'{CL}/20260801000000_x.xml': xml(cs('20260801000000-1', '<delete tableName="orders"><where>id = 1</where></delete>', SEL))})
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


PY = 'revision = "{}"\ndown_revision = "{}"\ndef upgrade():\n  {}\ndef downgrade():\n  {}\n'
GO = '-- +goose Up\n{};\n-- +goose Down\n{}\n'
AC, DC = 'ALTER TABLE t ADD c INT;', 'ALTER TABLE t DROP COLUMN c;'
TOOLS = [   # (base files, branch files, class, rule, revert command)
 ({'a/alembic.ini': ''}, {'a/versions/b2_c.py': PY.format('b2', 'a1', 'op.add_column("t", sa.Column("c"))', 'op.drop_column("t", "c")')}, 'light', '', 'alembic downgrade a1'),
 ({}, {'a/versions/c3_x.py': PY.format('c3', 'b2', 'op.drop_column("t", "c")', 'pass')}, 'heavy', 'empty-rollback', None),
 ({'manage.py': '', 's/migrations/0001_a.py': ''}, {'s/migrations/0002_b.py': "migrations.AddField(model_name='book', name='isbn')"}, 'light', '', 'python manage.py migrate s 0001_a'),
 ({}, {'s/migrations/0003_c.py': 'migrations.RunPython(fill)'}, 'heavy', 'no-rollback', None),
 ({'A/A.csproj': '', 'A/Migrations/20240101000000_I.cs': ''}, {'A/Migrations/20240201000000_E.cs': 'void Up(M b) { b.AddColumn<string>(name: "Email", table: "U"); }\n'
  'void Down(M b) { b.DropColumn(name: "Email", table: "U"); }', 'A/Migrations/AModelSnapshot.cs': 'x'}, 'light', '', 'dotnet ef database update 20240101000000_I'),
 ({}, {'db/migrate/20240201000000_e.rb': 'def change\n  add_column :users, :email, :string\nend'}, 'light', '', 'bin/rails db:migrate:down VERSION=20240201000000'),
 ({}, {'db/migrate/20240301000000_r.rb': 'def change\n  remove_column :users, :email\nend'}, 'heavy', 'no-rollback', None),
 ({}, {'migrations/20240201000000_u.js': "exports.up = (knex) => knex.schema.createTable('u', (t) => { t.string('e') })\n"
  "exports.down = (knex) => knex.schema.dropTable('u')"}, 'light', '', 'npx knex migrate:down 20240201000000_u.js'),
 ({'m/00001_a.sql': GO.format('CREATE TABLE t (id INT)', 'DROP TABLE t;')}, {'m/00002_b.sql': GO.format(AC[:-1], DC)}, 'light', '', 'goose -dir "m" down-to 00001'),
 ({}, {'f/V2__c.sql': AC, 'f/U2__c.sql': DC}, 'light', '', 'flyway undo'),
 ({}, {'f/V2__c.sql': AC}, 'heavy', 'no-rollback', None),
 ({}, {'f/R__v.sql': 'CREATE OR REPLACE VIEW v AS SELECT 1;'}, 'heavy', 'runs-on-change', None),
 ({}, {'p/migrations/2024_a/migration.sql': AC, 'p/migrations/2024_a/down.sql': DC}, 'light', '',
 'npx prisma db execute --file "p/migrations/2024_a/down.sql" && npx prisma migrate resolve --rolled-back 2024_a'),
 ({'sqitch.plan': ''}, {'deploy/c.sql': f'BEGIN;\n{AC}\nCOMMIT;', 'revert/c.sql': DC}, 'light', '', 'sqitch revert -y --to c^'),
 ({}, {'q/0002_c.up.sql': AC, 'q/0002_c.down.sql': DC}, 'light', '', 'psql -f "q/0002_c.down.sql"'),
]

class Tools(unittest.TestCase):
 def test_each_tool(self):
  for i, (base, br, cls, rule, cmd) in enumerate(TOOLS):
   r = Repo(); tmp = tempfile.mkdtemp(prefix='mig-tool-')
   try:
    for k, v in base.items():
     r.write(k, v)
    if base:
     r.commit('tool base')
    sha = r.branch(f't{i}', br)
    res = r.classify(sha, save=tmp, cfg={'exec': 'psql -f {file}'})
    self.assertEqual((res['class'], res['changesets'][-1]['rule']), (cls, rule), f'{i}: {res["reasons"]}')
    p = run('plan', '--leaving', os.path.join(tmp, 'manifest.json'), '--config', os.path.join(r.d, '..', os.path.basename(r.d) + '-cfg.json'))
    if cmd:
     self.assertEqual(p['revert'][0]['cmd'], cmd, i)
   finally:
    shutil.rmtree(r.d, ignore_errors=True); shutil.rmtree(tmp, ignore_errors=True)

 def test_dialect_detect_and_order(self):
  r = Repo()
  sha = r.branch('d', {f'{CL}/20261101000000_x.xml': xml(cs('20261101000000-1', '<sql>INSERT IGNORE INTO orders (id) VALUES (1)</sql>', SEL))})
  self.assertEqual([r.classify(sha, cfg={'dialect': d})['class'] for d in ('mysql', 'postgres')], ['light', 'heavy'])
  g2 = r.branch('g2', {'db/m/00002_b.sql': GO.format('CREATE TABLE b (id INT)', 'DROP TABLE b;')})
  g3 = r.branch('g3', {'db/m/00003_c.sql': GO.format('CREATE TABLE c (id INT)', 'DROP TABLE c;')})
  d = tempfile.mkdtemp(prefix='mig-ord-'); r.classify(g2, save=d + '/a'); r.classify(g3, save=d + '/b')
  self.assertEqual(list(run('detect', '--repo', r.d)), ['unknown tool'])   # a changelog, no master: UNRUN
  r.g('checkout', '-q', 'g3'); self.assertEqual(run('detect', '--repo', r.d)['goose'], 1)
  p = run('plan', '--leaving', d + '/a/manifest.json', '--staying', d + '/b/manifest.json')
  self.assertIn('goose order', p['blocked'][0]['uses'][0])
  shutil.rmtree(r.d, ignore_errors=True); shutil.rmtree(d, ignore_errors=True)
'''


def mig_selftest():
    import unittest
    ns = {'__file__': os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'devtools.py'), '__name__': 'migrations_selftest', 'mig_result': mig_result}
    exec(compile(SELFTEST, 'migrations-selftest', 'exec'), ns)
    from concurrent.futures import ThreadPoolExecutor   # tests are git-bound and independent: run them side by side
    cases = [unittest.defaultTestLoader.loadTestsFromTestCase(v) for v in ns.values() if isinstance(v, type) and issubclass(v, unittest.TestCase)]   # one suite per class: class fixtures run
    def one(t):
        r = unittest.TestResult(); t.run(r); return [(c.id(), e) for c, e in r.failures + r.errors]
    with ThreadPoolExecutor(len(cases)) as ex:
        bad = [x for xs in ex.map(one, cases) for x in xs]
    for i, e in bad:
        print(f'FAIL {i}\n{e}')
    print(f'{sum(s.countTestCases() for s in cases)} tests, {len(bad)} failed')
    return 1 if bad else 0


# ---- entry: devtools.py verb
def main(argv):
    return mig_selftest() if argv[:1] == ['selftest'] else (mig_main(argv) or 0)


def register(dt):
    dt.VERBS['migrations'] = main
