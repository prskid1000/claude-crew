"""db_flashback.py (extra db-engine-presets): MySQL / MariaDB layered restore for localenv.ps1 marks (a mark = a binlog position).
  plan|apply --from <file>:<pos> [--to <file>:<pos>] --schemas a,b [--skip <f>:<p>~<f>:<p>,..] [--exclude s.t,..] [--batch 1000]
      [--out <file.sql>]: row flashback: the row events after --from inverted newest first across all tables (WRITE -> DELETE,
      DELETE -> REPLACE of the before image, UPDATE -> the before image), whole transactions per batch; a statement group on a
      table with triggers or with cascade journal rows: its binlog row events inverted (BINLOG, no trigger fires; a group after
      DDL on its table: SQL with that table's triggers suspended); each batch checks FK orphans and unique keys of what it touched
      and rolls back if they grew; a table it cannot restore exactly -> fallback (left out, the rest goes on); then
      AUTO_INCREMENT of touched tables = max + 1. Lists the DDL after --from.
  slice --spec <json> --out <dir> [--objects a,b]: before a migration release, per touched table: its CREATE TABLE text, +
      (primary key, column) rows of a column it drops / retypes, + all rows of a table it drops / truncates (gzip); the view /
      routine / trigger / event definitions of the schemas; index.json with the bytes
  structure --dir <slice dir> --tables s.t,.. [--apply]: each table back to its CREATE text (inverse ALTER, recreate, drop),
      column / table slices refilled (triggers suspended), foreign keys added last, a recreated table's triggers back; verified
  objects --dir <slice dir> --names TYPE:s.n,.. [--apply]: each object dropped, created again when the slice has it
  guard --schemas a,b [--remove]: the cascade guard: BEFORE DELETE / key-UPDATE triggers on parents of CASCADE / SET NULL
      foreign keys copy the child rows (whole tree) into kit_journal mirrors (binlogged); --remove: triggers + kit_journal gone
  touched --files <f,..>: tables / columns the SQL (a tool's dry-run output) or migration files change -> slice spec items
Common: --host --port --user (password: MYSQL_PWD) [--mysql <exe>] [--mysqlbinlog <exe>] [--mysqldump <exe>]. Out: JSON.
Exit codes: 0 ok · 1 refused or failed · 2 usage.
Sections: L34 binlog · L246 row events · L378 flashback · L635 touched · L671 slices · L713 structure · L806 objects · L858 guard
"""
import argparse, base64, gzip, hashlib, json, os, re, struct, subprocess, sys, tempfile, zlib

SYSTEM = {'mysql', 'sys', 'performance_schema', 'information_schema'}
JOURNAL = 'kit_journal'   # the cascade guard's schema: one mirror table per cascaded child, cg_map, cg_fail
WRITE, UPDATE, DELETE, TMAP, FDE = 30, 31, 32, 19, 15
DIG = [0, 1, 1, 2, 2, 3, 3, 4, 4, 4]
TOOL = r'(?i)^(databasechangelog|flyway_schema_history|alembic_version|schema_migrations|__efmigrationshistory|knex_migrations|goose_db_version)$'
ESC = {ord('n'): 10, ord('t'): 9, ord('r'): 13, ord('b'): 8, ord('f'): 12, ord('v'): 11, ord('a'): 7, ord('0'): 0, ord('\\'): 92, ord("'"): 39, ord('"'): 34}
ROW = re.compile(rb'^### (INSERT INTO|UPDATE|DELETE FROM) `((?:[^`]|``)+)`\.`((?:[^`]|``)+)`')
ACTS = ('CASCADE', 'SET NULL', 'SET DEFAULT')


# ---- binlog: positions, values, the server's metadata, DDL statements, the scan
def key(fp):
    """'binlog.000012:4567' -> (12, 4567): binlog order"""
    f, p = fp.rsplit(':', 1)
    return (int(re.search(r'(\d+)$', f).group(1)), int(p))


def q(n): return '`' + n.replace('`', '``') + '`'


def unquote(b):
    out, i = bytearray(), 0
    while i < len(b):
        c = b[i]
        if c == 92 and i + 1 < len(b):
            n = b[i + 1]
            if n == ord('x') and i + 3 < len(b): out.append(int(b[i + 2:i + 4], 16)); i += 4; continue
            out.append(ESC.get(n, n)); i += 2; continue
        out.append(c); i += 1
    return bytes(out)


def value(raw):
    """one ###   @N=<v> -> [kind, text]: null, str (hex), bits, num (+ the unsigned reading), partial (a partial JSON update)"""
    raw = raw.rstrip()
    if raw == b'NULL': return ['null', '']
    if raw.startswith(b"'") and raw.endswith(b"'"): return ['str', unquote(raw[1:-1]).hex()]
    if raw.startswith(b"b'"): return ['bits', raw[2:-1].decode()]
    if raw.startswith(b'JSON_'): return ['partial', '']
    m = re.match(rb'^(\S+)(?: \((\d+)\))?', raw)
    return ['num', m.group(1).decode(), (m.group(2) or b'').decode()]


class Db:
    def __init__(s, a): s.a = a
    def base(s, exe): return [exe, '-h', s.a.host, '-P', str(s.a.port), '-u', s.a.user]
    def rows(s, sql):
        r = subprocess.run(s.base(s.a.mysql) + ['--default-character-set=utf8mb4', '-N', '-B', '-e', sql], capture_output=True, timeout=600)
        if r.returncode: raise RuntimeError(f'mysql: {r.stderr.decode(errors="replace").strip()[-300:]}')
        bs = {'n': '\n', 't': '\t', '0': '\0', '\\': '\\'}   # -B escapes these in each field
        return [[re.sub(r'\\(.)', lambda x: bs.get(x.group(1), '\\' + x.group(1)), f) for f in l.split('\t')] for l in r.stdout.decode('utf-8', errors='replace').splitlines() if l]
    def run_file(s, path):
        with open(path, 'rb') as fh:
            return subprocess.run(s.base(s.a.mysql) + ['--default-character-set=utf8mb4', '-N', '-B', '--comments'], stdin=fh, capture_output=True, timeout=7200)
    def script(s, sql):
        """statements (DELIMITER lines allowed) through a temp file; raises on failure"""
        fd, path = tempfile.mkstemp(suffix='.sql'); os.close(fd)
        try:
            with open(path, 'w', encoding='utf-8', newline='\n') as fh: fh.write(sql)
            r = s.run_file(path)
        finally: os.remove(path)
        if r.returncode: raise RuntimeError(f'mysql: {r.stderr.decode(errors="replace").strip()[-300:]}')
        return r.stdout.decode('utf-8', errors='replace')
    def create(s, sch, t):
        try: return s.rows(f'SHOW CREATE TABLE {q(sch)}.{q(t)}')[0][1]
        except (RuntimeError, IndexError): return None


def inl(xs): return ','.join("'" + x.replace('\\', '\\\\').replace("'", "''") + "'" for x in sorted(xs)) or "''"


def meta(db, schemas):
    """columns, primary keys, unique keys, FKs (child -> parent, rules), triggers of the schemas"""
    m = {'cols': {}, 'uniq': {}, 'fks': [], 'trig': {}}
    for sch, t, name, dt, ct, extra, ck in db.rows('SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, EXTRA, COLUMN_KEY FROM information_schema.COLUMNS '
                                                   f'WHERE TABLE_SCHEMA IN ({inl(schemas)}) ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION'):
        m['cols'].setdefault(f'{sch}.{t}', []).append({'name': name, 'type': dt.lower(), 'ctype': ct.lower(), 'gen': bool(re.search(r'(?i)\b(VIRTUAL|STORED) GENERATED', extra)), 'pk': ck == 'PRI', 'ai': 'auto_increment' in extra.lower()})
    for sch, t, ix, cols in db.rows("SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',') FROM information_schema.STATISTICS "
                                    f"WHERE TABLE_SCHEMA IN ({inl(schemas)}) AND NON_UNIQUE = 0 AND INDEX_NAME <> 'PRIMARY' GROUP BY 1, 2, 3"):
        m['uniq'].setdefault(f'{sch}.{t}', []).append((ix, cols.split(',')))
    fk = {}
    for sch, t, name, col, rs, rt, rc in db.rows('SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME '
                                                 f'FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA IN ({inl(schemas)}) AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY 1, 2, 3, ORDINAL_POSITION'):
        f = fk.setdefault((sch, name), {'name': name, 'child': f'{sch}.{t}', 'parent': f'{rs}.{rt}', 'cc': [], 'pc': [], 'del': '', 'upd': ''})
        f['cc'].append(col); f['pc'].append(rc)
    for sch, name, dr, ur in db.rows(f'SELECT CONSTRAINT_SCHEMA, CONSTRAINT_NAME, DELETE_RULE, UPDATE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_SCHEMA IN ({inl(schemas)})'):
        if (sch, name) in fk: fk[(sch, name)].update({'del': dr, 'upd': ur})
    m['fks'] = list(fk.values())
    for sch, t, name in db.rows(f'SELECT EVENT_OBJECT_SCHEMA, EVENT_OBJECT_TABLE, TRIGGER_NAME FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA IN ({inl(schemas)})'):
        m['trig'].setdefault(f'{sch}.{t}', []).append(name)
    return m


DDL = [(r'(?i)^CREATE\s+(?:TEMPORARY\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([`\w.]+)', 'create'), (r'(?i)^DROP\s+(?:TEMPORARY\s+)?TABLE\s+(?:IF\s+EXISTS\s+)?(.+?)(?:\s*/\*.*)?$', 'drop'),
       (r'(?i)^TRUNCATE\s+(?:TABLE\s+)?([`\w.]+)', 'truncate'), (r'(?i)^RENAME\s+TABLE\s+(.+)$', 'rename'), (r'(?i)^ALTER\s+TABLE\s+([`\w.]+)', 'alter'),
       (r'(?i)^(?:CREATE|DROP)\s+(?:UNIQUE\s+|FULLTEXT\s+|SPATIAL\s+)?INDEX\s+\S+\s+ON\s+([`\w.]+)', 'alter'),
       (r'(?i)^(?:CREATE|ALTER|DROP)\s+(?:OR\s+REPLACE\s+)?(?:(?:DEFINER\s*=\s*\S+|SQL\s+SECURITY\s+\w+|ALGORITHM\s*=\s*\w+)\s+)*(VIEW|PROCEDURE|FUNCTION|TRIGGER|EVENT)\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?([`\w.]+)', 'object')]


def split_name(n, db):
    p = [x.strip('` ') for x in re.findall(r'`(?:[^`]|``)+`|[^.`\s]+', n.strip())]
    return (p[0], p[1]) if len(p) > 1 else (db, p[0] if p else '')


def ddl_of(sql, db):
    """[{schema, table, kind, to}] of one DDL statement"""
    s = re.sub(r'^/\*.*?\*/\s*', '', sql.strip(), flags=re.S)
    for rx, kind in DDL:
        m = re.match(rx, s, re.S)
        if not m: continue
        if re.match(r'(?i)^(CREATE|DROP)\s+TEMPORARY\b', s): return []
        if kind == 'drop': return [dict(zip(('schema', 'table'), split_name(x, db)), kind='drop') for x in m.group(1).split(',')]
        if kind == 'rename':
            out = []
            for pair in m.group(1).split(','):
                a, _, b = pair.partition(re.search(r'(?i)\s+TO\s+', pair).group(0) if re.search(r'(?i)\s+TO\s+', pair) else ' TO ')
                sa, ta = split_name(a, db); sb, tb = split_name(b, db)
                out.append({'schema': sa, 'table': ta, 'kind': 'rename', 'to': f'{sb}.{tb}'})
            return out
        if kind == 'object': sch, t = split_name(m.group(2), db); return [{'schema': sch, 'table': t, 'kind': 'object', 'object': m.group(1).upper(), 'op': s.split()[0].upper()}]
        sch, t = split_name(m.group(1), db)
        r = {'schema': sch, 'table': t, 'kind': kind}
        rn = re.search(r'(?i)\bRENAME\s+(?:TO|AS)?\s*([`\w.]+)\s*$', s) if kind == 'alter' else None
        if rn: sb, tb = split_name(rn.group(1), sch); r.update(kind='rename', to=f'{sb}.{tb}')
        return [r]
    if re.match(r'(?i)^(CREATE|DROP|ALTER)\s+(DATABASE|SCHEMA)\b', s): return [{'schema': split_name(s.split()[-1], db)[1], 'table': '', 'kind': 'database'}]
    return [{'schema': db, 'table': '', 'kind': 'unknown'}] if re.match(r'(?i)^(CREATE|DROP|ALTER|RENAME|TRUNCATE)\b', s) else []


def stmt_schemas(sql):
    """schema names a statement qualifies a table with (`s`.t, s.t), string literals left out"""
    q = re.sub(r"'(?:[^'\\]|\\.|'')*'|\"(?:[^\"\\]|\\.)*\"", "''", sql)
    return {x.replace('``', '`') for p in re.findall(r'`((?:[^`]|``)+)`\s*\.\s*[`\w]|(?<![.`\w])([A-Za-z_]\w*)\s*\.\s*[`A-Za-z_]', q) for x in p if x}


def scan(a, schemas, skips, frm, to, spool, keep=frozenset()):
    """the binlog from frm: row events of the schemas -> spool (JSON lines, with their transaction and statement group); DDL +
    bookkeeping rows -> res; the raw events of a statement group that touches a table in keep (it has triggers) or the journal ->
    res['groups'], the format description event -> res['fde']"""
    res = {'tables': {}, 'ddl': [], 'toolRows': [], 'refused': [], 'warnings': [], 'names': {}, 'groups': {}, 'fde': None}
    cmd = [a.mysqlbinlog, '-R', '-h', a.host, '-P', str(a.port), '-u', a.user, '-v', '--print-table-metadata',
           '--to-last-log', f'--start-position={frm[1]}', a.start_file]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    st = {'file': a.start_file, 'at': 0, 'db': '', 'tx': 0, 'q': None, 'row': None, 'part': None, 'tm': None, 'g': 0, 'b64': None}
    cols_of = {}
    def pos(): return key(f"{st['file']}:{st['at']}")
    def inside(): k = pos(); return k >= frm and (to is None or k < to) and not any(s <= k < e for s, e in skips)
    def flush():
        row = st['row']; st['row'] = None
        if not (row and inside()): return
        t = f"{row['s']}.{row['t']}"
        if row['s'] != JOURNAL: c = res['tables'].setdefault(t, {'insert': 0, 'update': 0, 'delete': 0}); c[row['op']] += 1
        if t in cols_of: res['names'][t] = cols_of[t]
        row['tx'] = st['tx']; row['at'] = f"{st['file']}:{st['at']}"; row['g'] = st['g']
        spool.write(json.dumps(row) + '\n')
        if re.search(a.tool, row['t']) and row['op'] == 'insert' and t in cols_of:
            n = cols_of[t]
            res['toolRows'].append({'at': row['at'], 'schema': row['s'], 'table': row['t'], 'row': {(n[int(k) - 1] if int(k) <= len(n) else k): (bytes.fromhex(v[1]).decode('utf-8', 'replace') if v[0] == 'str' else v[1]) for k, v in row['after'].items()}})
    def block(text):   # one BINLOG '...' statement: the format description, or a statement group's table maps + rows events
        evs = b64_events(text)
        if evs and evs[0][4] == FDE: res['fde'] = res['fde'] or evs[0]; return
        st['g'] += 1
        g = parse_group(evs)
        if inside() and any(t in keep or t.startswith(JOURNAL + '.') for t in g['names'].values()): res['groups'][st['g']] = g
    for line in p.stdout:
        line = line.rstrip(b'\r\n')
        if st['b64'] is not None:
            if line.endswith(b"'/*!*/;"): st['b64'].append(line[:-7]); block(b''.join(st['b64']).decode('ascii', 'replace')); st['b64'] = None
            else: st['b64'].append(line)
            continue
        if line == b"BINLOG '": flush(); st['b64'] = []; continue
        if line.startswith(b'# at '): flush(); st['at'] = int(line[5:]); continue
        m = re.search(rb'Rotate to (\S+)\s+pos: (\d+)', line)
        if m: flush(); st['file'] = m.group(1).decode(); continue
        if re.match(rb'^#\d{6} ', line):
            flush(); st['q'] = [] if b'\tQuery\t' in line else None
            if b'\tXid = ' in line: st['tx'] += 1
            m = re.search(rb'Table_map: `((?:[^`]|``)+)`\.`((?:[^`]|``)+)`', line)
            st['tm'] = f'{m.group(1).decode()}.{m.group(2).decode()}' if m else None
            continue
        if st['tm'] and (line.startswith(b'# Columns(') or line.startswith(b'#         `')):
            n = re.match(rb'^#(?: Columns\(|\s+)`((?:[^`]|``)+)`', line)
            if n:
                if line.startswith(b'# Columns('): cols_of[st['tm']] = []
                cols_of.setdefault(st['tm'], []).append(n.group(1).decode())
            continue
        if st['q'] is not None and not line.startswith(b'#'):
            s = line.decode('utf-8', 'replace')
            m = re.match(r'^use `((?:[^`]|``)+)`/\*!\*/;$', s)
            if m: st['db'] = m.group(1); continue
            end = s.endswith('/*!*/;'); body = s[:-6] if end else s
            if body.strip() and not re.match(r'^(SET\s|/\*!)', body, re.I): st['q'].append(body)
            if end and st['q']:
                sql = ' '.join(st['q']).strip(); st['q'] = []
                if re.match(r'(?i)^COMMIT$', sql): st['tx'] += 1; continue
                if re.match(r'(?i)^(BEGIN|ROLLBACK|SAVEPOINT\b.*|XA\b.*)$', sql): continue
                if inside() and re.match(r'(?i)^(INSERT|UPDATE|DELETE|REPLACE|LOAD)\b', sql) and {str(x).lower() for x in {st['db']} | stmt_schemas(sql)} & {x.lower() for x in schemas}:   # case-folded (lower_case_table_names)
                    res['refused'].append(f"statement-format DML at {st['file']}:{st['at']}: its rows are not in the binlog (binlog_format = ROW)"); continue
                st['tx'] += 1   # DDL commits implicitly
                for d in ddl_of(sql, st['db']):
                    if d['schema'] in schemas and inside(): res['ddl'].append(d | {'at': f"{st['file']}:{st['at']}", 'sql': sql[:300]})
            continue
        m = ROW.match(line)
        if m:
            flush()
            s, t = m.group(2).decode().replace('``', '`'), m.group(3).decode().replace('``', '`')
            if s in schemas or s == JOURNAL:
                st['row'] = {'s': s, 't': t, 'op': {b'INSERT INTO': 'insert', b'UPDATE': 'update', b'DELETE FROM': 'delete'}[m.group(1)]}
                st['part'] = 'after' if st['row']['op'] == 'insert' else 'before'
            continue
        if st['row'] is not None:
            if line == b'### WHERE': st['part'] = 'before'
            elif line == b'### SET': st['part'] = 'after'
            else:
                m = re.match(rb'^###   @(\d+)=(.*)$', line)
                if m: st['row'].setdefault(st['part'], {})[m.group(1).decode()] = value(m.group(2))
    flush()
    err = p.stderr.read().decode(errors='replace').strip()
    if p.wait(): raise RuntimeError(f'mysqlbinlog exit {p.returncode}: {err[-400:]}')
    return res


# ---- row events: a statement group inverted as BINLOG '<base64>' (no trigger fires; the cascade journal back into its child)
def b64_events(text):
    """the base64 of one BINLOG statement -> raw events (each was encoded on its own: padding ends a chunk)"""
    raw = b''.join(base64.b64decode(c + '=' * (-len(c) % 4)) for c in re.findall(r'[A-Za-z0-9+/]+=*', re.sub(r'\s+', '', text)))
    out, i = [], 0
    while i + 19 <= len(raw):
        n = struct.unpack_from('<I', raw, i + 9)[0]; out.append(raw[i:i + n]); i += n
    return out


def packed(b, i):
    c = b[i]
    if c < 251: return c, i + 1
    if c == 252: return struct.unpack_from('<H', b, i + 1)[0], i + 3
    if c == 253: return int.from_bytes(b[i + 1:i + 4], 'little'), i + 4
    return struct.unpack_from('<Q', b, i + 1)[0], i + 9


def crc_on(ev): return len(ev) > 23 and zlib.crc32(ev[:-4]) & 0xffffffff == struct.unpack_from('<I', ev, len(ev) - 4)[0]


def seal(body, crc):
    """event bytes without a checksum -> size field set, CRC32 appended when the binlog has checksums"""
    ev = bytearray(body); struct.pack_into('<I', ev, 9, len(ev) + (4 if crc else 0))
    return bytes(ev) + (struct.pack('<I', zlib.crc32(bytes(ev)) & 0xffffffff) if crc else b'')


def tmap(ev, crc):
    """a Table_map event -> {id, db, table, types, meta (bytes per column), end (offset after the names)}"""
    b = ev[:-4] if crc else ev
    i = 27; dl = b[i]; db = b[i + 1:i + 1 + dl].decode(); i += dl + 2
    tl = b[i]; tb = b[i + 1:i + 1 + tl].decode(); i += tl + 2
    end = i
    n, i = packed(b, i); types = list(b[i:i + n]); i += n
    ml, i = packed(b, i); mb = b[i:i + ml]; j = 0; meta = []
    for t in types:
        w = 1 if t in (4, 5, 252, 255, 245, 17, 18, 19) else 2 if t in (15, 253, 254, 246, 16, 247, 248) else 0
        meta.append(mb[j:j + w]); j += w
    return {'id': int.from_bytes(b[19:25], 'little'), 'db': db, 'table': tb, 'types': types, 'meta': meta, 'end': end}


def retarget(ev, crc, db, table):
    """a Table_map event naming db.table instead (a journal mirror -> its child table: same column types)"""
    b = ev[:-4] if crc else ev
    nb = b''.join(bytes([len(x.encode())]) + x.encode() + b'\0' for x in (db, table))
    return seal(b[:27] + nb + b[tmap(ev, crc)['end']:], crc)


def vlen(t, m, b, i):
    """bytes of one column value of type t (metadata m) at b[i]"""
    fixed = {1: 1, 13: 1, 2: 2, 9: 3, 10: 3, 11: 3, 14: 3, 3: 4, 7: 4, 8: 8, 12: 8, 6: 0}
    if t in fixed: return fixed[t]
    if t in (4, 5): return m[0]
    if t in (15, 253): return 1 + b[i] if struct.unpack('<H', m)[0] < 256 else 2 + struct.unpack_from('<H', b, i)[0]
    if t == 16: return m[1] + (1 if m[0] else 0)
    if t in (17, 18, 19): return {17: 4, 18: 5, 19: 3}[t] + (m[0] + 1) // 2
    if t in (245, 252, 255): return m[0] + int.from_bytes(b[i:i + m[0]], 'little')
    if t == 246: g = m[0] - m[1]; return (g // 9) * 4 + DIG[g % 9] + (m[1] // 9) * 4 + DIG[m[1] % 9]
    if t in (247, 248): return m[1]
    if t == 254:
        real, fl = (m[0] | 0x30, m[1] | (((m[0] & 0x30) ^ 0x30) << 4)) if (m[0] & 0x30) != 0x30 else (m[0], m[1])
        if real in (247, 248): return fl
        return 1 + b[i] if fl < 256 else 2 + struct.unpack_from('<H', b, i)[0]
    raise ValueError(f'column type {t} is not supported in row events')


def image(tm, present, b, i):
    cols = [k for k in range(len(tm['types'])) if present[k // 8] >> (k % 8) & 1]
    nb = (len(cols) + 7) // 8; nulls = b[i:i + nb]; j = i + nb
    for x, k in enumerate(cols):
        if not nulls[x // 8] >> (x % 8) & 1: j += vlen(tm['types'][k], tm['meta'][k], b, j)
    return b[i:j], j


def invert_rows(ev, crc, tm, keep_type=False, last=False):
    """a rows event -> its inverse: write <-> delete, update images swapped, rows newest first; FK checks off, unique checks
    relaxed, statement end on the last; keep_type: the same rows written again (a journal mirror's rows back into the child)"""
    b = ev[:-4] if crc else ev
    typ = b[4]
    if typ not in (WRITE, UPDATE, DELETE): raise ValueError(f'rows event type {typ} (partial JSON / v1 events) cannot be inverted')
    i = 27 + struct.unpack_from('<H', b, 27)[0]
    n, i = packed(b, i); bl = (n + 7) // 8
    head = bytearray(b[:i]); bm1 = b[i:i + bl]; i += bl
    if typ != WRITE and not all(bm1[k // 8] >> (k % 8) & 1 for k in range(n)): raise ValueError('the before image is not FULL (binlog_row_image)')
    bm2 = b''
    if typ == UPDATE: bm2 = b[i:i + bl]; i += bl
    imgs = []
    while i < len(b):
        im, i = image(tm, bm1, b, i)
        if typ == UPDATE: im2, i = image(tm, bm2, b, i); im = (im, im2)
        imgs.append(im)
    head[4] = typ if keep_type else {WRITE: DELETE, DELETE: WRITE, UPDATE: UPDATE}[typ]
    struct.pack_into('<H', head, 25, 0x2 | 0x4 | (0x1 if last else 0))
    body = bm2 + bm1 + b''.join(after + before for before, after in imgs[::-1]) if typ == UPDATE else bm1 + b''.join(imgs[::-1])
    return seal(bytes(head) + body, crc)


def parse_group(evs):
    """the events of one statement group -> {crc, tmes, rows, names {table id: schema.table}}"""
    crc = crc_on(evs[0]) if evs else False
    g = {'crc': crc, 'tmes': [e for e in evs if e[4] == TMAP], 'rows': [e for e in evs if e[4] != TMAP], 'names': {}}
    for e in g['tmes']: t = tmap(e, crc); g['names'][t['id']] = f"{t['db']}.{t['table']}"
    return g


def group_tables(g, cmap):
    """the env tables a group changes (journal mirrors as their child table)"""
    out = set()
    for n in g['names'].values():
        s, t = n.split('.', 1)
        if s != JOURNAL: out.add(n)
        elif t in cmap: out.add('.'.join(cmap[t]))
    return out


def invert_group(g, schemas, fb, cmap):
    """BINLOG statement undoing one statement group: its table maps (journal mirrors retargeted to their child), then its rows
    events inverted newest first; tables outside the schemas or in fb are left out; '' when nothing is left"""
    crc, keep, tms = g['crc'], {}, []
    for ev in g['tmes']:
        tm = tmap(ev, crc); n = f"{tm['db']}.{tm['table']}"
        if tm['db'] == JOURNAL:
            c = cmap.get(tm['table'])
            if c and '.'.join(c) not in fb: keep[tm['id']] = (tm, True); tms.append(retarget(ev, crc, *c))
        elif tm['db'] in schemas and n not in fb: keep[tm['id']] = (tm, False); tms.append(ev)
    rows = [ev for ev in g['rows'] if int.from_bytes(ev[19:25], 'little') in keep][::-1]
    if not rows: return ''
    inv = [invert_rows(ev, crc, *keep[int.from_bytes(ev[19:25], 'little')], last=k == len(rows) - 1) for k, ev in enumerate(rows)]
    mode = 'IDEMPOTENT' if any(j for _, j in keep.values()) else 'STRICT'   # a journal row overwrites a SET NULL child
    return f"SET SESSION rbr_exec_mode = '{mode}';\nBINLOG '\n" + '\n'.join(base64.b64encode(e).decode() for e in tms + inv) + "\n';"


# ---- flashback: inverse statements, checks, cascades, batches
def literal(v, col):
    kind, dt, ct = v[0], col['type'], col['ctype']
    if kind == 'null': return 'NULL'
    if kind == 'bits': return str(int(v[1], 2)) if dt == 'set' else f"b'{v[1]}'"
    if kind == 'num':
        if dt == 'timestamp': return "'0000-00-00 00:00:00'" if v[1] in ('0', '0.0') else f'FROM_UNIXTIME({v[1]})'
        return v[2] if v[2] and 'unsigned' in ct else v[1]
    return hexlit(v[1], dt)


def hexlit(h, dt):
    b = bytes.fromhex(h)
    if dt == 'json': return f"CONVERT(X'{h}' USING utf8mb4)"
    if all(32 <= c < 127 for c in b) and b"'" not in b and b'\\' not in b: return "'" + b.decode() + "'"
    return f"X'{h}'" if b else "''"


def resolve(row, cols, names):
    """{column: value} of each image by column name; None when the values cannot be mapped (positions without names after DDL)"""
    by = {c['name']: c for c in cols}
    out = {}
    for part in ('before', 'after'):
        img = row.get(part)
        if img is None: continue
        if not names and len(img) != len(cols): return None
        d = {}
        for i, v in img.items():
            n = names[int(i) - 1] if names and int(i) <= len(names) else (cols[int(i) - 1]['name'] if not names and int(i) <= len(cols) else None)
            if n is None: return None
            if n in by: d[n] = v   # a column dropped after the event: the table is at the mark's structure now
        if part == 'before' and names and len(img) < len(names): return None   # not a FULL image (binlog_row_image)
        out[part] = d
    return out


def inverse(row, cols, names):
    s, t = q(row['s']), q(row['t'])
    by = {c['name']: c for c in cols}
    img = resolve(row, cols, names)
    if img is None: return None
    def where(d):
        ps = [(by[n], v) for n, v in d.items() if not by[n]['gen']]
        keyed = [(c, v) for c, v in ps if c['pk']] or [(c, v) for c, v in ps if c['type'] not in ('float', 'double', 'json')]
        return ' AND '.join(f"{q(c['name'])} <=> {literal(v, c)}" for c, v in keyed)
    if row['op'] == 'insert': return f"DELETE FROM {s}.{t} WHERE {where(img['after'])} LIMIT 1;"
    ps = [(by[n], v) for n, v in img['before'].items() if not by[n]['gen']]   # generated columns are never written
    if row['op'] == 'delete': return f"REPLACE INTO {s}.{t} ({', '.join(q(c['name']) for c, _ in ps)}) VALUES ({', '.join(literal(v, c) for c, v in ps)});"
    return f"UPDATE {s}.{t} SET {', '.join(f'{q(c['name'])} = {literal(v, c)}' for c, v in ps)} WHERE {where(img['after'])} LIMIT 1;"


def checks(m, touched, fb=()):
    """(name, count SQL) per FK and unique key of the touched tables: a batch may not grow them (tables in fb: not checked)"""
    out = []
    for f in m['fks']:
        if (f['child'] in touched or f['parent'] in touched) and f['child'] not in fb and f['parent'] not in fb:
            cs, ps = f['child'].split('.', 1), f['parent'].split('.', 1)
            on = ' AND '.join(f"c.{q(a)} = p.{q(b)}" for a, b in zip(f['cc'], f['pc']))
            out.append((f"orphans {f['child']} -> {f['parent']} ({f['name']})",
                        f"SELECT COUNT(*) FROM {q(cs[0])}.{q(cs[1])} c LEFT JOIN {q(ps[0])}.{q(ps[1])} p ON {on} WHERE {' AND '.join(f'c.{q(a)} IS NOT NULL' for a in f['cc'])} AND p.{q(f['pc'][0])} IS NULL"))
    for t in sorted(set(touched) - set(fb)):
        sch, tb = t.split('.', 1)
        for ix, cols in m['uniq'].get(t, []):
            out.append((f'duplicates {t} ({ix})', f"SELECT COUNT(*) FROM (SELECT 1 FROM {q(sch)}.{q(tb)} WHERE {' AND '.join(q(c) + ' IS NOT NULL' for c in cols)} GROUP BY {', '.join(q(c) for c in cols)} HAVING COUNT(*) > 1) x"))
    return out


def guard_name(kind, sch, t):
    """the cascade guard's names: trigger kit_cg_d_<t> / kit_cg_u_<t>, mirror <schema>__<table> (hashed past 64 chars)"""
    h = hashlib.sha1(f'{sch}.{t}'.encode()).hexdigest()
    if kind == 'mirror': n = f'{sch}__{t}'; return n if len(n) <= 64 and '__' not in sch + t else f'{sch[:24]}__{t[:24]}_{h[:10]}'   # one name per table
    n = f'kit_cg_{kind}_{t}'; return n if len(n) <= 64 else f'kit_cg_{kind}_{h[:20]}'


def guard_on(t, op, at, m, ddl):
    """was the guard trigger of parent t for op (d / u) installed at binlog position at? (DDL in the range, else it exists now)"""
    sch, tb = t.split('.', 1); n = guard_name(op, sch, tb)
    ops = [(key(d['at']), d.get('op')) for d in ddl if d['kind'] == 'object' and d.get('object') == 'TRIGGER' and d['schema'] == sch and d['table'] == n]
    on = ops[0][1] == 'DROP' if ops else n in m['trig'].get(t, [])
    for k, o in ops:
        if k < key(at): on = o == 'CREATE'
    return on


def cascade_gaps(rows, m, ddl):
    """children of parent deletes / key updates under CASCADE / SET NULL whose changed rows are neither in the binlog (explicit
    child changes first) nor journaled by the cascade guard (not installed then, or its journal insert failed) -> {child: why}"""
    gone, out, failed = {}, {}, {}
    for r in rows:
        if r['s'] == JOURNAL and r['t'] == 'cg_fail' and r['op'] == 'insert':
            v = (r.get('after') or {}).get('2')
            if v and v[0] == 'str': failed.setdefault(r.get('g'), set()).add(bytes.fromhex(v[1]).decode('utf-8', 'replace'))
    for r in rows:   # binlog order
        if r['s'] == JOURNAL: continue
        t = f"{r['s']}.{r['t']}"
        b = r.get('rimg', {}).get('before', {}); a = r.get('rimg', {}).get('after', {})
        for f in m['fks']:
            if f['child'] == t and r['op'] in ('delete', 'update'):
                k = tuple(str(b.get(c)) for c in f['cc'])
                if r['op'] == 'delete' or any(str(a.get(c)) != str(b.get(c)) for c in f['cc']): gone.setdefault(f"{f['child']}.{f['name']}", set()).add(k)
            if f['parent'] == t and 'rimg' in r:
                rule = f['del'] if r['op'] == 'delete' else (f['upd'] if r['op'] == 'update' else '')
                if rule not in ACTS: continue
                if r['op'] == 'update' and all(str(a.get(c)) == str(b.get(c)) for c in f['pc']): continue
                if tuple(str(b.get(c)) for c in f['pc']) in gone.get(f"{f['child']}.{f['name']}", set()): continue
                op = 'd' if r['op'] == 'delete' else 'u'
                if guard_on(t, op, r['at'], m, ddl) and t not in failed.get(r.get('g'), set()): continue
                why = 'its cascade guard journal insert failed' if t in failed.get(r.get('g'), set()) else 'no cascade guard then (localenv.ps1 doctor installs it)'
                out.setdefault(f['child'], f"{t} rows {'deleted' if op == 'd' else 're-keyed'} at {r['at']} with ON {'DELETE' if op == 'd' else 'UPDATE'} {rule} children here: the cascaded rows are not in the binlog ({why})")
    return out


def suspended_file(db): return os.path.join(tempfile.gettempdir(), f'kit-triggers-suspended-{db.a.host}-{db.a.port}.json')


def triggers_off(db, tables):
    """drop the triggers of tables (unlogged) -> what triggers_on creates again: the kit's own writes fire none; their CREATE
    text goes to a file first (a killed run: the next triggers_heal puts them back)"""
    tl = sorted(tables)
    if not tl: return []
    rows = db.rows("SELECT TRIGGER_SCHEMA, TRIGGER_NAME FROM information_schema.TRIGGERS WHERE CONCAT(EVENT_OBJECT_SCHEMA, '.', EVENT_OBJECT_TABLE) IN (" + inl(tl) + ") ORDER BY ACTION_ORDER")
    saved = [(sch, db.rows(f'SHOW CREATE TRIGGER {q(sch)}.{q(n)}')[0]) for sch, n in rows]
    if not saved: return []
    with open(suspended_file(db), 'w', encoding='utf-8') as fh: json.dump(saved, fh)
    try: db.script('SET SESSION sql_log_bin = 0;\n' + '\n'.join(f'DROP TRIGGER IF EXISTS {q(sch)}.{q(r[0])};' for sch, r in saved) + '\n')
    except RuntimeError: triggers_on(db, saved); raise
    return saved


def triggers_on(db, saved):
    """create the saved triggers that are missing (unlogged), then forget the file"""
    if not saved: return
    have = {(r[0], r[1]) for r in db.rows('SELECT TRIGGER_SCHEMA, TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA IN (' + inl({sch for sch, _ in saved}) + ')')}
    todo = [(sch, r) for sch, r in saved if (sch, r[0]) not in have]
    if todo: db.script('SET SESSION sql_log_bin = 0;\nDELIMITER //kit//\n' + ''.join(f"SET SESSION sql_mode = '{r[1]}'//kit//\nSET NAMES {r[3]}//kit//\nUSE {q(sch)}//kit//\n{r[2]}//kit//\n" for sch, r in todo) + 'DELIMITER ;\n')
    if os.path.exists(suspended_file(db)): os.remove(suspended_file(db))


def triggers_heal(db):
    """triggers a killed run left dropped: back (every command that changes data starts with it)"""
    p = suspended_file(db)
    if os.path.exists(p): triggers_on(db, [tuple(x) for x in json.load(open(p, encoding='utf-8'))])


def journal_map(db):
    """mirror table -> (schema, table) of the cascade guard (empty without the journal schema)"""
    try: return {r[0]: (r[1], r[2]) for r in db.rows(f'SELECT mirror, sch, tbl FROM {q(JOURNAL)}.cg_map')}
    except RuntimeError: return {}


def flashback(a, db, schemas, frm, to, skips):
    m = meta(db, schemas)
    fb = {}   # table -> why: left out of the flashback, seed restores it (localenv.ps1)
    for t in [x for x in (a.exclude or '').split(',') if x]: fb[t] = 'left out by the restore plan'
    with tempfile.TemporaryDirectory(prefix='flashback-') as tmp:
        sp = os.path.join(tmp, 'rows.jsonl')
        with open(sp, 'w', encoding='utf-8') as spool: res = scan(a, schemas, skips, frm, to, spool, frozenset(m['trig']) | {t for t, cs in m['cols'].items() if any(c['type'] == 'float' for c in cs)})
        names, groups, fde = res.pop('names'), res.pop('groups'), res.pop('fde')
        cmap = journal_map(db)
        with open(sp, encoding='utf-8') as fh: rows = [json.loads(l) for l in fh]
        made = {f"{d['schema']}.{d['table']}" for d in res['ddl'] if d['kind'] == 'create'}   # created after the mark: gone again, rows too
        for t in sorted(res['tables']):
            if t not in m['cols'] and t not in made: fb.setdefault(t, 'it does not exist now and no mark kept its slice')
        ddl_at = {}
        for d in res['ddl']:
            if d['table'] and d['kind'] != 'object': ddl_at.setdefault(f"{d['schema']}.{d['table']}", []).append(key(d['at']))
        first = {}
        for r in rows: first.setdefault(r.get('g'), key(r['at']))
        misfit = set()   # groups whose row events no longer fit: a table changed by DDL before them, or events that cannot be inverted
        for gi, g in groups.items():
            if any(t in m['cols'] and any(k < first.get(gi, (0, 0)) for k in ddl_at.get(t, [])) for t in group_tables(g, cmap)): misfit.add(gi); continue
            try: invert_group(g, schemas, {}, cmap)
            except (ValueError, IndexError, struct.error): misfit.add(gi)
        suspend = set()   # their tables' triggers are dropped while the SQL inverse runs, then created again
        for gi in misfit:
            suspend |= {t for t in group_tables(groups[gi], cmap) if t in m['trig']}
            for t in group_tables(groups[gi], cmap):
                if any(c['type'] == 'float' for c in m['cols'].get(t, [])): fb.setdefault(t, 'FLOAT values: the binlog text has 6 digits and its row events no longer fit')
            del groups[gi]
        for r in rows:   # a misfit group's journal rows: the child's before image put back by SQL
            if r['s'] == JOURNAL and r.get('g') in misfit and r['op'] == 'insert' and r['t'] in cmap:
                r['names'] = names.get(f"{JOURNAL}.{r['t']}"); cs, ct = cmap[r['t']]
                r.update(s=cs, t=ct, op='delete', before=r.pop('after'))
        for r in rows:
            t = f"{r['s']}.{r['t']}"
            if r['s'] == JOURNAL or t not in m['cols'] or t in fb: continue
            if any(v[0] == 'partial' for img in (r.get('before') or {}, r.get('after') or {}) for v in img.values()): fb[t] = 'partial JSON updates in the binlog (binlog_row_value_options = PARTIAL_JSON): no before image'; continue
            if not (r.get('names') or names.get(t)) and t in ddl_at: fb[t] = 'its structure changed after the mark and the binlog has no column names (binlog_row_metadata = FULL)'; continue
            r['rimg'] = {k: {n: v[1] for n, v in d.items()} for k, d in (resolve(r, m['cols'][t], r.get('names') or names.get(t)) or {}).items()}
        for t, why in cascade_gaps(rows, m, res['ddl']).items(): fb.setdefault(t, why)
        res['suspended'] = sorted(suspend)
        txs, cur, seen = [], None, set()
        for r in reversed(rows):   # one global order, newest first: FK order holds by construction
            t, gi = f"{r['s']}.{r['t']}", r.get('g')
            if gi in groups:   # triggers or the cascade journal: the group as inverted row events
                if gi in seen: continue
                seen.add(gi); item = ('raw', gi, {x for x in group_tables(groups[gi], cmap) if x in m['cols']})
            else:
                if r['s'] == JOURNAL or t not in m['cols'] or t in fb: continue
                x = inverse(r, m['cols'][t], r.get('names') or names.get(t))
                if x is None: fb[t] = 'its values cannot be mapped to columns (structure changed after the mark)'; continue
                item = ('sql', x, {t})
            if cur is None or cur['tx'] != r['tx']: cur = {'tx': r['tx'], 'items': []}; txs.append(cur)
            cur['items'].append(item)
        if a.order == 'tables': txs = [{'tx': i, 'items': [it]} for i, it in enumerate(sorted((it for x in txs for it in x['items']), key=lambda it: str(it[1])))]   # test only: wrong order
        def live(): return {t: c for t, c in res['tables'].items() if t in m['cols'] and t not in fb}
        res['statements'] = sum(c['insert'] + c['update'] + c['delete'] for c in live().values())
        res['ai'] = sorted(t for t, c in live().items() if any(x['ai'] for x in m['cols'][t]) and c['insert'])
        res['fallback'] = [{'table': t, 'why': w} for t, w in sorted(fb.items())]
        if groups and not fde: res['refused'].append('the binlog gave no format description event: row events cannot be applied')
        if a.cmd == 'plan' or res['refused']: return res
        def sql_of(it): return (it[1] if not (it[2] & set(fb)) else '') if it[0] == 'sql' else invert_group(groups[it[1]], schemas, fb, cmap)
        out = a.out or os.path.join(tmp, 'flashback.sql')
        start, rounds = 0, 0
        saved = triggers_off(db, suspend)
        try:
            while True:   # whole transactions per batch; a batch that fails on one table: that table falls back, the rest goes on
                batches, i = [], start
                while i < len(txs):
                    b, tabs, s0 = [], set(), i
                    while i < len(txs) and (not b or len(b) + len(txs[i]['items']) <= a.batch):
                        for it in txs[i]['items']:
                            x = sql_of(it)
                            if x: b.append(x); tabs |= it[2] - set(fb)
                        i += 1
                    if b: batches.append((s0, b, tabs))
                with open(out, 'w', encoding='utf-8', newline='\n') as fh:
                    fh.write("SET SESSION sql_log_bin = 0; SET SESSION foreign_key_checks = 0; SET SESSION unique_checks = 0; SET SESSION time_zone = '+00:00'; SET SESSION sql_mode = 'NO_AUTO_VALUE_ON_ZERO'; SET NAMES utf8mb4;\n")
                    if fde and groups: fh.write(f"BINLOG '{base64.b64encode(fde).decode()}';\n")
                    for n, (_, b, tabs) in enumerate(batches, 1):
                        cs = checks(m, tabs, fb)
                        fh.write(f"SELECT 'BATCH {n}';\nSTART TRANSACTION;\n")
                        for j, (_, sql) in enumerate(cs): fh.write(f'SET @c{j} = ({sql});\n')
                        fh.write('\n'.join(b) + '\n')
                        for j, (name, sql) in enumerate(cs): fh.write(f"SELECT {inl(['CHECK ' + name])}; DO JSON_EXTRACT('[1]', IF(({sql}) > @c{j}, 'grew', '$'));\n")
                        fh.write('COMMIT;\n')
                    for t in [x for x in res['ai'] if x not in fb]: fh.write(f"ALTER TABLE {q(t.split('.', 1)[0])}.{q(t.split('.', 1)[1])} AUTO_INCREMENT = 1;\n")   # InnoDB takes max + 1
                r = db.run_file(out)
                res['applied'] = r.returncode == 0; res['out'] = a.out or ''
                if not r.returncode: break
                said = re.findall(r'^(BATCH \d+|CHECK .+)$', r.stdout.decode(errors='replace'), re.M)
                err = r.stderr.decode(errors='replace').strip()
                nb = int(([x for x in said if x.startswith('BATCH')][-1:] or ['BATCH 1'])[0].split()[1])
                chk = said[-1][6:] if said and said[-1].startswith('CHECK') and 'Invalid JSON path' in err else ''
                tabs = batches[nb - 1][2] if nb <= len(batches) else set()
                hit = re.match(r'(?:orphans|duplicates) (\S+)', chk).group(1) if chk else next((t for t in sorted(tabs) if re.search(r'(?i)`?%s`?\.`?%s`?' % tuple(re.escape(x) for x in t.split('.', 1)), err)), None)
                if not hit and len(tabs) == 1: hit = next(iter(tabs))
                if not hit or hit in fb or rounds >= 50:   # TODO-PARAM (fixed default)
                    res['error'] = f"BATCH {nb} rolled back{(': ' + chk + ' grew') if chk else ''} ({err[-200:]}); earlier batches are committed"; break
                fb[hit] = f"batch {nb} failed on it: {chk + ' grew' if chk else err[-160:]}"
                res['fallback'] = [{'table': t, 'why': w} for t, w in sorted(fb.items())]
                start, rounds = batches[nb - 1][0], rounds + 1
        finally: triggers_on(db, saved)   # the suspended triggers back, unlogged: the same definitions as before
        res['statements'] = sum(c['insert'] + c['update'] + c['delete'] for c in live().values())
        return res


# ---- touched: which tables / columns pending migrations change (their SQL, else their files' text: a superset)
def touched_sql(sql, out):
    sql = re.sub(r'/\*.*?\*/', ' ', sql, flags=re.S)
    for st in (' '.join(x.split()) for x in '\n'.join(l for l in sql.splitlines() if not l.strip().startswith('--')).split(';')):
        for d in ddl_of(st, ''):
            if not d['table'] or d['kind'] in ('database', 'unknown', 'object'): continue
            kind = {'drop': 'table', 'truncate': 'table'}.get(d['kind'], 'create')
            cols = [x.group(2).strip('`"') for x in re.finditer(r'(?i)\b(DROP|MODIFY|CHANGE)\s+(?:COLUMN\s+)?(?!(?:INDEX|KEY|FOREIGN|PRIMARY|CONSTRAINT|CHECK|UNIQUE|PARTITION)\b)([`"\w]+)', st)] if d['kind'] == 'alter' else []
            out.append({'table': d['table'], 'kind': 'column' if cols else kind, 'columns': cols})
            if d.get('to'): out.append({'table': d['to'].split('.')[-1], 'kind': 'create', 'columns': []})


def touched_cmd(a):
    out = []
    for f in [x for x in (a.files or '').split(',') if x]:
        text = open(f, encoding='utf-8', errors='replace').read()
        if f.lower().endswith(('.xml', '.yaml', '.yml', '.json')):   # Liquibase-style changelogs: tags / keys naming tables
            for m in re.finditer(r'<(\w+)\b([^>]*)>|-\s*(\w+):\s*\n((?:\s+\w+:.*\n)+)', text):
                tag, attrs = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
                at = dict(re.findall(r'(\w+)\s*[=:]\s*"?([\w.]+)"?', attrs or ''))
                t = (at.get('tableName') or at.get('baseTableName') or '').split('.')[-1]
                if not t: continue
                if tag in ('dropColumn', 'modifyDataType'): out.append({'table': t, 'kind': 'column', 'columns': [at['columnName']] if at.get('columnName') else []})
                elif tag == 'dropTable': out.append({'table': t, 'kind': 'table', 'columns': []})
                elif tag not in ('insert', 'update', 'delete', 'loadData', 'loadUpdateData', 'column', 'where'): out.append({'table': t, 'kind': 'create', 'columns': []})
            for m in re.finditer(r'(?s)<(sql|createProcedure)\b[^>]*>(.*?)</\1>', text): touched_sql(re.sub(r'<!\[CDATA\[|\]\]>', '', m.group(2)), out)
        else: touched_sql(text, out)
    by = {}
    for x in out:   # one item per table: table > column > create, columns merged
        y = by.setdefault(x['table'].lower(), {'table': x['table'], 'kind': 'create', 'columns': []})
        rank = {'create': 0, 'column': 1, 'table': 2}
        if rank[x['kind']] > rank[y['kind']]: y['kind'] = x['kind']
        y['columns'] = sorted(set(y['columns']) | set(x['columns']))
    return {'items': sorted(by.values(), key=lambda x: x['table'].lower())}


# ---- slices: what a migration release destroys, kept before it runs
def pk_of(db, sch, t):
    return [r[0] for r in db.rows(f"SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = {inl([sch])} AND TABLE_NAME = {inl([t])} AND CONSTRAINT_NAME = 'PRIMARY' ORDER BY ORDINAL_POSITION")]


def slice_cmd(a, db):
    spec = json.load(open(a.spec, encoding='utf-8'))
    os.makedirs(a.out, exist_ok=True)
    items, total = [], 0
    for it in spec:
        sch, t, kind = it['schema'], it['table'], it.get('kind', 'create')
        x = {'schema': sch, 'table': t, 'kind': kind, 'create': db.create(sch, t), 'columns': {}, 'rows': '', 'pk': [], 'noPk': False}
        if x['create'] is None: items.append(x); continue   # the migration creates it: the reverse is a drop
        total += len(x['create'])
        base = hashlib.sha1(f'{sch}.{t}'.encode()).hexdigest()[:12]
        if kind == 'table':
            f = os.path.join(a.out, f'{base}.rows.sql.gz')
            with gzip.open(f, 'wb') as gz:
                p = subprocess.Popen([a.mysqldump, '-h', a.host, '-P', str(a.port), '-u', a.user, '--single-transaction', '--no-create-info', '--hex-blob', '--skip-triggers',
                                      '--compact', '--skip-extended-insert', '--set-gtid-purged=OFF', '--default-character-set=utf8mb4', sch, t], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                for chunk in iter(lambda: p.stdout.read(1 << 20), b''): gz.write(chunk)
                if p.wait(): raise RuntimeError(f'mysqldump {sch}.{t}: {p.stderr.read().decode(errors="replace")[-200:]}')
            x['rows'] = os.path.basename(f); total += os.path.getsize(f)
        elif kind == 'column':
            x['pk'] = pk_of(db, sch, t)
            if not x['pk']: x['noPk'] = True
            for c in [] if x['noPk'] else it.get('columns') or []:
                f = os.path.join(a.out, f'{base}.{hashlib.sha1(c.encode()).hexdigest()[:8]}.tsv.gz')
                sel = ', '.join(f'HEX(CAST({q(k)} AS BINARY))' for k in x['pk']) + f', HEX(CAST({q(c)} AS BINARY)), {q(c)} IS NULL'
                with gzip.open(f, 'wb') as gz:
                    p = subprocess.Popen(db.base(a.mysql) + ['-N', '-B', '-e', f'SELECT {sel} FROM {q(sch)}.{q(t)}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    for chunk in iter(lambda: p.stdout.read(1 << 20), b''): gz.write(chunk)
                    if p.wait(): raise RuntimeError(f'slice {sch}.{t}.{c}: {p.stderr.read().decode(errors="replace")[-200:]}')
                x['columns'][c] = os.path.basename(f); total += os.path.getsize(f)
        items.append(x)
    objs = objects_of(db, [x for x in (a.objects or '').split(',') if x]) if a.objects else []
    total += sum(len(o['create']) for o in objs)
    idx = {'items': items, 'bytes': total, 'objects': objs}
    with open(os.path.join(a.out, 'index.json'), 'w', encoding='utf-8') as fh: json.dump(idx, fh)
    return {'bytes': total, 'items': len(items), 'objects': len(objs), 'noPk': [f"{x['schema']}.{x['table']}" for x in items if x['noPk']], 'dir': os.path.abspath(a.out)}


# ---- structure: back to the CREATE text of a slice
def norm_create(t): return re.sub(r' AUTO_INCREMENT=\d+', '', (t or '').strip())


def parts(create):
    """(columns {name: def} in order, keys {name: line}, fks {name: line}) of a CREATE TABLE text"""
    cols, keys, fks = {}, {}, {}
    body = create[create.index('(') + 1:create.rindex(')')]
    for line in (l.strip().rstrip(',') for l in body.split('\n') if l.strip()):
        if line.startswith('`'):
            m = re.match(r'`((?:[^`]|``)+)`\s+(.*)$', line); cols[m.group(1)] = m.group(2)
        elif line.startswith('CONSTRAINT') and 'FOREIGN KEY' in line: fks[re.match(r'CONSTRAINT `([^`]+)`', line).group(1)] = line
        elif line.startswith('PRIMARY KEY'): keys['PRIMARY'] = line
        else:
            m = re.match(r'(?:UNIQUE |FULLTEXT |SPATIAL )?KEY `([^`]+)`|CONSTRAINT `([^`]+)`', line)
            if m: keys[m.group(1) or m.group(2)] = line
    return cols, keys, fks


def inverse_alter(sch, t, cur, old):
    """ALTER statements that turn CREATE text cur into old"""
    cc, ck, cf = parts(cur); oc, ok, of = parts(old)
    tn, out = f'{q(sch)}.{q(t)}', []
    out += [f'ALTER TABLE {tn} DROP FOREIGN KEY {q(n)};' for n in cf if of.get(n) != cf[n]]
    for n in ck:
        if ok.get(n) != ck[n]: out.append(f'ALTER TABLE {tn} DROP PRIMARY KEY;' if n == 'PRIMARY' else (f'ALTER TABLE {tn} DROP CHECK {q(n)};' if ck[n].startswith('CONSTRAINT') else f'ALTER TABLE {tn} DROP INDEX {q(n)};'))
    out += [f'ALTER TABLE {tn} DROP COLUMN {q(n)};' for n in cc if n not in oc]
    names = list(oc)
    for i, n in enumerate(names):
        if n in cc and cc[n] != oc[n]: out.append(f'ALTER TABLE {tn} MODIFY COLUMN {q(n)} {oc[n]};')
        elif n not in cc: out.append(f"ALTER TABLE {tn} ADD COLUMN {q(n)} {oc[n]} {'FIRST' if i == 0 else 'AFTER ' + q(names[i - 1])};")
    out += [f'ALTER TABLE {tn} ADD {ok[n]};' for n in ok if ck.get(n) != ok[n]]
    return out, [f'ALTER TABLE {tn} ADD {of[n]};' for n in of if cf.get(n) != of[n]]


def structure_cmd(a, db):
    d = a.dir; idx = json.load(open(os.path.join(d, 'index.json'), encoding='utf-8'))
    want = {x for x in (a.tables or '').split(',') if x}
    sql, fk_last, done, fb = ["SET SESSION sql_log_bin = 0; SET SESSION foreign_key_checks = 0; SET NAMES utf8mb4; SET SESSION time_zone = '+00:00';"], [], [], {}
    items = [x for x in idx['items'] if f"{x['schema']}.{x['table']}" in want]
    for x in items:
        sch, t, tn = x['schema'], x['table'], f"{q(x['schema'])}.{q(x['table'])}"
        cur = db.create(sch, t)
        if x['create'] is None:
            if cur: sql.append(f'DROP TABLE {tn};'); done.append(f'{sch}.{t}: dropped (created after the mark)')
            continue
        if cur is None:
            if x['kind'] != 'table' or not x['rows']: fb[f'{sch}.{t}'] = 'dropped after the mark and no row slice kept'; continue
            cols, keys, fks = parts(x['create'])
            body = ',\n'.join([f'  {q(n)} {v}' for n, v in cols.items()] + [f'  {v}' for v in keys.values()])
            tail = x['create'][x['create'].rindex(')') + 1:]
            sql.append(f'CREATE TABLE {tn} (\n{body}\n){tail};')
            sql += [f'USE {q(sch)};', f"SOURCE {os.path.join(d, x['rows'][:-3]).replace(os.sep, '/')}"]
            fk_last += [f'ALTER TABLE {tn} ADD {v};' for v in fks.values()]
            done.append(f'{sch}.{t}: recreated, rows from the slice')
        elif norm_create(cur) != norm_create(x['create']):
            alters, fadd = inverse_alter(sch, t, cur, x['create']); sql += alters; fk_last += fadd
            done.append(f'{sch}.{t}: {len(alters) + len(fadd)} inverse ALTER(s)')
        if x['noPk'] and x['kind'] == 'column': fb[f'{sch}.{t}'] = 'no primary key: its dropped / changed column values cannot be put back exactly'
        for c, f in (x['columns'] or {}).items():
            cmap = {r[0]: r[1].lower() for r in db.rows(f"SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = {inl([sch])} AND TABLE_NAME = {inl([t])}")} if cur else {}
            dt = cmap.get(c) or (re.match(r'(\w+)', parts(x['create'])[0].get(c, 'x')).group(1).lower())
            pkt = {p: (cmap.get(p) or re.match(r'(\w+)', parts(x['create'])[0].get(p, 'x')).group(1).lower()) for p in x['pk']}
            n = 0
            with gzip.open(os.path.join(d, f), 'rt', encoding='utf-8') as fh:
                for line in fh:
                    v = line.rstrip('\n').split('\t'); k = len(x['pk'])
                    val = 'NULL' if v[k + 1] == '1' else hexlit(v[k], dt)
                    sql.append(f"UPDATE {tn} SET {q(c)} = {val} WHERE {' AND '.join(f'{q(p)} = {hexlit(h, pkt.get(p, ""))}' for p, h in zip(x['pk'], v[:k]))};"); n += 1
            done.append(f'{sch}.{t}.{c}: {n} value(s) refilled')
    fbl = [{'table': t, 'why': w} for t, w in sorted(fb.items())]
    if not a.apply: return {'refused': [], 'fallback': fbl, 'done': done, 'statements': len(sql) + len(fk_last) - 1}
    for x in items:   # dropped tables first (rows go in before FKs come back)
        if x['kind'] == 'table' and x['rows'] and db.create(x['schema'], x['table']) is None:
            with gzip.open(os.path.join(d, x['rows']), 'rb') as gz, open(os.path.join(d, x['rows'][:-3]), 'wb') as fh: fh.write(gz.read())
    path = a.out or os.path.join(tempfile.gettempdir(), f'structure-{os.getpid()}.sql')
    with open(path, 'w', encoding='utf-8', newline='\n') as fh: fh.write('\n'.join(sql + fk_last) + '\n')
    saved = triggers_off(db, {f"{x['schema']}.{x['table']}" for x in items if x['columns'] and db.create(x['schema'], x['table'])})   # refills fire no app trigger
    try: r = db.run_file(path)
    finally: triggers_on(db, saved)
    if not a.out: os.remove(path)
    for x in items:
        if x['rows'] and os.path.exists(os.path.join(d, x['rows'][:-3])): os.remove(os.path.join(d, x['rows'][:-3]))
    if r.returncode: return {'refused': [], 'fallback': fbl, 'done': done, 'error': r.stderr.decode(errors='replace').strip()[-300:]}
    made = {(x['schema'], x['table']) for x in items if x['kind'] == 'table' and x['rows'] and f"{x['schema']}.{x['table']}" not in fb}
    have = {(r[0], r[1]) for r in db.rows('SELECT TRIGGER_SCHEMA, TRIGGER_NAME FROM information_schema.TRIGGERS')} if made else set()
    tg = [o for o in idx.get('objects') or [] if o['type'] == 'TRIGGER' and (o['schema'], o.get('table')) in made and (o['schema'], o['name']) not in have]
    triggers_on(db, [(o['schema'], [o['name'], o['sqlMode'], o['create'], o['cs'] or 'utf8mb4']) for o in tg]); done += [f"{o['schema']}.{o['table']}: trigger {o['name']} back" for o in tg]
    diff = [f"{x['schema']}.{x['table']}" for x in items if x['create'] is not None and f"{x['schema']}.{x['table']}" not in fb and norm_create(db.create(x['schema'], x['table'])) != norm_create(x['create'])]
    diff += [f"{x['schema']}.{x['table']}" for x in items if x['create'] is None and db.create(x['schema'], x['table'])]
    return {'refused': [], 'fallback': fbl, 'done': done, 'verified': not diff, 'differs': diff}


# ---- objects: view / procedure / function / trigger / event definitions (the guard's own triggers left out)
OBJ = {'VIEW': ('SHOW CREATE VIEW', 1, None, 2), 'PROCEDURE': ('SHOW CREATE PROCEDURE', 2, 1, 3), 'FUNCTION': ('SHOW CREATE FUNCTION', 2, 1, 3),
       'TRIGGER': ('SHOW CREATE TRIGGER', 2, 1, 3), 'EVENT': ('SHOW CREATE EVENT', 3, 1, 4)}   # statement, CREATE, sql_mode, character_set_client columns


def objects_of(db, schemas):
    s = inl(schemas); found = []
    found += [('VIEW', r[0], r[1]) for r in db.rows(f'SELECT TABLE_SCHEMA, TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA IN ({s})')]
    found += [(r[2], r[0], r[1]) for r in db.rows(f'SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA IN ({s})')]
    on = {(r[0], r[1]): r[2] for r in db.rows(f"SELECT TRIGGER_SCHEMA, TRIGGER_NAME, EVENT_OBJECT_TABLE FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA IN ({s}) AND TRIGGER_NAME NOT LIKE 'kit\\_cg\\_%' ORDER BY ACTION_ORDER")}
    found += [('TRIGGER', sch, n) for sch, n in on]
    found += [('EVENT', r[0], r[1]) for r in db.rows(f'SELECT EVENT_SCHEMA, EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA IN ({s})')]
    out = []
    for typ, sch, n in found:
        st, ci, mi, si = OBJ[typ]
        r = db.rows(f'{st} {q(sch)}.{q(n)}')[0]
        out.append({'type': typ, 'schema': sch, 'name': n, 'create': r[ci], 'sqlMode': r[mi] if mi is not None else '', 'cs': r[si], 'tz': r[2] if typ == 'EVENT' else '', 'table': on.get((sch, n), '') if typ == 'TRIGGER' else ''})
    return out


def objects_cmd(a, db):
    """--dir <slice dir> --names TYPE:schema.name,..: each object dropped, then created again from the slice when it existed then"""
    idx = json.load(open(os.path.join(a.dir, 'index.json'), encoding='utf-8'))
    have = {f"{o['type']}:{o['schema']}.{o['name']}": o for o in idx.get('objects') or []}
    want = [x for x in (a.names or '').split(',') if x]
    order = ['FUNCTION', 'PROCEDURE', 'VIEW', 'TRIGGER', 'EVENT']   # what a later one may call first
    bad = [n for n in want if n.split(':', 1)[0] not in OBJ or '.' not in n.split(':', 1)[-1]]
    if bad: raise ValueError(f"not TYPE:schema.name ({', '.join(OBJ)}): {', '.join(bad)}")
    drops, creates, done = [], [], []
    for n in want:
        typ, rest = n.split(':', 1); sch, name = rest.split('.', 1)
        drops.append(f'DROP {typ} IF EXISTS {q(sch)}.{q(name)};')
    for n in sorted(want, key=lambda x: order.index(x.split(':', 1)[0])):
        o = have.get(n)
        if not o: done.append(f'{n}: dropped (created after the mark)'); continue
        sql = [f"SET SESSION sql_mode = '{o['sqlMode']}'//kit//", f"SET NAMES {o['cs'] or 'utf8mb4'}//kit//", f"USE {q(o['schema'])}//kit//"]
        if o.get('tz'): sql.append(f"SET SESSION time_zone = '{o['tz']}'//kit//")
        creates.append((n, '\n'.join(sql + [o['create'] + '//kit//'])))
    if not a.apply: return {'done': done + [f'{n}: created again from the slice' for n, _ in creates]}
    db.script('SET SESSION sql_log_bin = 0;\n' + '\n'.join(drops) + '\n')
    left, err = creates, {}
    while left:   # a view on a view: what failed goes again after the rest, until a round makes no progress
        nxt = []
        for n, sql in left:
            try: db.script('SET SESSION sql_log_bin = 0;\nDELIMITER //kit//\n' + sql + '\nDELIMITER ;\n'); done.append(f'{n}: created again from the slice')
            except RuntimeError as e: nxt.append((n, sql)); err[n] = str(e)[-160:]
        if len(nxt) == len(left): break
        left = nxt
    if left: return {'done': done, 'error': '; '.join(f'{n} still missing: {err[n]}' for n, _ in left)}
    return {'done': done}


# ---- guard: BEFORE DELETE / key-UPDATE triggers on parents of CASCADE / SET NULL foreign keys copy the child rows (the whole
#      tree) into kit_journal mirrors, so the binlog has what InnoDB cascades change without logging
def guard_paths(m, parent, op, path=(), depth=0):
    out = []
    for f in m['fks']:
        rule = f['del'] if op == 'd' else f['upd']
        if f['parent'] != parent or rule not in ('CASCADE', 'SET NULL'): continue
        p = path + (f,); out.append(p)
        if rule == 'CASCADE' and depth < 5: out += guard_paths(m, f['child'], op, p, depth + 1)   # TODO-PARAM (fixed default)
    return out


def guard_cmd(a, db, schemas):
    have = {(r[0], r[1]): r[2] for r in db.rows(f"SELECT TRIGGER_SCHEMA, TRIGGER_NAME, ACTION_STATEMENT FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA IN ({inl(schemas)}) AND TRIGGER_NAME LIKE 'kit\\_cg\\_%'")}
    if a.remove:
        sql = [f'DROP TRIGGER IF EXISTS {q(s)}.{q(n)};' for s, n in sorted(have)]
        db.script('\n'.join(sql + [f'DROP DATABASE IF EXISTS {q(JOURNAL)};']) + '\n')
        return {'removed': len(sql), 'installed': 0, 'kept': 0}
    m = meta(db, schemas)
    cdef = {}
    for sch, t, n, ct, cs, co in db.rows(f'SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IFNULL(CHARACTER_SET_NAME, \'\'), IFNULL(COLLATION_NAME, \'\') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA IN ({inl(schemas)}) ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION'):
        cdef.setdefault(f'{sch}.{t}', []).append(f"{q(n)} {ct}{f' CHARACTER SET {cs} COLLATE {co}' if cs else ''} NULL")
    J = q(JOURNAL)
    pre = [f'CREATE DATABASE IF NOT EXISTS {J};', f'CREATE TABLE IF NOT EXISTS {J}.cg_map (mirror varchar(64) PRIMARY KEY, sch varchar(64), tbl varchar(64), sig char(40));',
           f'CREATE TABLE IF NOT EXISTS {J}.cg_fail (id bigint AUTO_INCREMENT PRIMARY KEY, tbl varchar(200), at datetime(6) DEFAULT CURRENT_TIMESTAMP(6));']
    db.script('\n'.join(pre) + '\n')
    sigs = {r[0]: r[1] for r in db.rows(f'SELECT mirror, sig FROM {J}.cg_map')}
    mirrors, trig = [], {}
    parents = sorted({f['parent'] for f in m['fks'] if f['del'] in ('CASCADE', 'SET NULL') or f['upd'] in ('CASCADE', 'SET NULL')})
    for p in parents:
        ps, pt = p.split('.', 1)
        for op in ('d', 'u'):
            paths = guard_paths(m, p, op)
            if not paths: continue
            stmts = []
            for path in paths:
                c = path[-1]['child']; cs, ct = c.split('.', 1); mn = guard_name('mirror', cs, ct)
                body = ', '.join(cdef.get(c, []))
                sig = hashlib.sha1(body.encode()).hexdigest()
                if sigs.get(mn) != sig:
                    mirrors += [f'DROP TABLE IF EXISTS {J}.{q(mn)};', f'CREATE TABLE {J}.{q(mn)} ({body}) ENGINE=InnoDB;',
                                f"REPLACE INTO {J}.cg_map VALUES ({inl([mn])}, {inl([cs])}, {inl([ct])}, '{sig}');"]; sigs[mn] = sig
                cols = [x['name'] for x in m['cols'][c]]
                frm = f"{q(cs)}.{q(ct)} x{len(path)}"
                for k in range(len(path) - 1, 0, -1):
                    f = path[k]; ss, st = f['parent'].split('.', 1)
                    frm += f" JOIN {q(ss)}.{q(st)} x{k} ON " + ' AND '.join(f'x{k + 1}.{q(a)} = x{k}.{q(b)}' for a, b in zip(f['cc'], f['pc']))
                w = ' AND '.join(f'x1.{q(a)} = OLD.{q(b)}' for a, b in zip(path[0]['cc'], path[0]['pc']))
                ins = f"INSERT INTO {J}.{q(mn)} ({', '.join(q(x) for x in cols)}) SELECT {', '.join(f'x{len(path)}.{q(x)}' for x in cols)} FROM {frm} WHERE {w};"
                if op == 'u': ins = f"IF NOT ({' AND '.join(f'OLD.{q(b)} <=> NEW.{q(b)}' for b in path[0]['pc'])}) THEN {ins} END IF;"
                stmts.append(ins)
            text = ' '.join(stmts)
            ver = hashlib.sha1(text.encode()).hexdigest()[:16]
            on_err = f"BEGIN DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END; INSERT INTO {J}.cg_fail (tbl) VALUES ({inl([p])}); END"
            tb = f"BEGIN DECLARE kit_cg_version CHAR(16) DEFAULT '{ver}'; DECLARE CONTINUE HANDLER FOR SQLEXCEPTION {on_err}; {text} END"
            trig[(ps, guard_name(op, ps, pt))] = (f"CREATE TRIGGER {q(ps)}.{q(guard_name(op, ps, pt))} BEFORE {'DELETE' if op == 'd' else 'UPDATE'} ON {q(ps)}.{q(pt)} FOR EACH ROW {tb}", ver)
    sql, kept = [], 0
    for k, (create, ver) in sorted(trig.items()):
        if ver in (have.get(k) or ''): kept += 1; continue
        sql += [f'DROP TRIGGER IF EXISTS {q(k[0])}.{q(k[1])}//kit//', create + '//kit//']
    gone = [k for k in have if k not in trig]
    sql += [f'DROP TRIGGER IF EXISTS {q(s)}.{q(n)}//kit//' for s, n in gone]
    old = [r[0] for r in db.rows(f"SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '{JOURNAL}' AND TABLE_NAME NOT IN ('cg_map', 'cg_fail')")]
    full = [r[0] for r in db.rows(f"SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '{JOURNAL}' AND TABLE_ROWS > 0")] if old else []
    prune = [f'TRUNCATE TABLE {J}.{q(t)};' for t in full]   # the binlog keeps the journal rows; the tables need none
    db.script('SET SESSION lock_wait_timeout = 10;\n' + '\n'.join(mirrors + prune) + '\nDELIMITER //kit//\n' + '\n'.join(sql) + '\nDELIMITER ;\n')   # TODO-PARAM (fixed default)
    return {'installed': len(trig) - kept, 'kept': kept, 'removed': len(gone), 'parents': len(parents), 'triggers': len(trig)}


# ---- cli
def main(argv):
    ap = argparse.ArgumentParser(prog='db_flashback.py')
    ap.add_argument('cmd', choices=['plan', 'apply', 'slice', 'structure', 'objects', 'guard', 'touched'])
    for o in ('--from', '--to', '--schemas', '--host', '--port', '--user', '--skip', '--out', '--spec', '--dir', '--tables', '--files', '--exclude', '--objects', '--names'): ap.add_argument(o)
    ap.add_argument('--tool', default=TOOL); ap.add_argument('--batch', type=int, default=1000)   # TODO-PARAM (fixed default)
    ap.add_argument('--order', default='global'); ap.add_argument('--apply', action='store_true'); ap.add_argument('--remove', action='store_true')
    ap.add_argument('--mysqlbinlog', default='mysqlbinlog'); ap.add_argument('--mysql', default='mysql'); ap.add_argument('--mysqldump', default='mysqldump')
    a = ap.parse_args(argv)
    if a.cmd == 'touched': print(json.dumps(touched_cmd(a))); return 0
    if not a.user: ap.print_usage(sys.stderr); return 2
    a.host, a.port = a.host or '127.0.0.1', a.port or '3306'
    db = Db(a)
    try:
        if a.cmd in ('apply', 'structure', 'objects') and a.apply or a.cmd == 'apply': triggers_heal(db)
        if a.cmd == 'slice': res = slice_cmd(a, db)
        elif a.cmd == 'structure': res = structure_cmd(a, db)
        elif a.cmd == 'objects': res = objects_cmd(a, db)
        elif a.cmd == 'guard':
            if not a.schemas: ap.print_usage(sys.stderr); return 2
            res = guard_cmd(a, db, sorted({x.strip() for x in a.schemas.split(',') if x.strip()} - SYSTEM - {JOURNAL}))
        else:
            if not (a.__dict__['from'] and a.schemas): ap.print_usage(sys.stderr); return 2
            a.start_file = a.__dict__['from'].rsplit(':', 1)[0]
            skips = [tuple(key(x) for x in r.split('~', 1)) for r in (a.skip or '').split(',') if r.strip()]
            schemas = {x.strip() for x in a.schemas.split(',') if x.strip()} - SYSTEM - {JOURNAL}
            res = flashback(a, db, schemas, key(a.__dict__['from']), key(a.to) if a.to else None, skips)
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError, KeyError) as e:
        print(json.dumps({'error': f'{type(e).__name__}: {e}'})); return 1
    print(json.dumps(res, indent=1))
    return 1 if res.get('refused') or res.get('error') or (a.cmd == 'apply' and not res.get('applied')) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
