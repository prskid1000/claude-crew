"""web: JS bundles, source maps, Electron (asar, IPC, fuses), wasm, HAR / SAZ: read from literals and the AST, never executed.
Usage: python -X utf8 <kit>/skills/reversy/reversy.py web <file|folder> [--source <dir>]  (then find / show <module|source>)
Engines: @babel/parser with error recovery (node, installed into the tools folder on first need; regex fallback), our asar
  reader, wasm-objdump when present. --source: score local source files against the source map (digest 100 · path 70 ·
  exact name 60 · suffix 40 · basename 20; under 20 dropped). Exit codes: as reversy.py.
Sections: L19 args · L26 ast · L113 collect · L175 sourcemaps · L246 electron · L272 wasm-har · L349 run · L414 show
"""
import base64
import hashlib
import json
import os
import os.path as osp
import re
import struct
import zipfile

import lib

# ---- args: the verb's options
def add(p):
    p.add_argument('path')
    p.add_argument('--source', help='a local source folder to match against the source maps')

JS_EXT = ('.js', '.mjs', '.cjs', '.jsx', '.bundle')

# ---- ast: one node pass per file: bundler modules, rename-resistant fingerprints, IPC calls
AST_JS = r'''// reversy-ast.mjs: reversy's AST pass (our own). argv: <babel dir> <list.json>; prints one JSON line per file
import { createRequire } from 'node:module'
import fs from 'node:fs'
import crypto from 'node:crypto'
const [, , babelDir, listFile] = process.argv
const { parse } = createRequire(babelDir + '/')('@babel/parser')
const SKIP = new Set(['loc', 'start', 'end', 'extra', 'comments', 'leadingComments', 'trailingComments', 'innerComments', 'range', 'errors'])
const IPC = new Set(['send', 'sendSync', 'invoke', 'on', 'once', 'handle', 'handleOnce', 'postMessage'])
function kids(n) { const o = []; for (const k in n) { if (SKIP.has(k)) continue; const v = n[k]; if (Array.isArray(v)) { for (const x of v) if (x && typeof x.type === 'string') o.push(x) } else if (v && typeof v.type === 'string') o.push(v) } return o }
function fp(root) {   // node types, operators and literals; identifier names left out
  const h = crypto.createHash('sha256'), st = [root]
  while (st.length) { const n = st.pop(); h.update(n.type); if (n.operator) h.update(n.operator); if ('value' in n && typeof n.value !== 'object') h.update(String(n.value)); st.push(...kids(n).reverse()) }
  return h.digest('hex').slice(0, 16)
}
const nm = n => !n ? '' : n.type === 'Identifier' ? n.name : n.type === 'MemberExpression' ? nm(n.object) + '.' + (n.property.name || n.property.value || '') : n.type === 'StringLiteral' ? n.value
  : n.type === 'AssignmentExpression' || n.type === 'LogicalExpression' ? nm(n.left) : n.type === 'ParenthesizedExpression' ? nm(n.expression) : ''
const key = p => p.key ? (p.key.name ?? p.key.value ?? '') : ''
for (const f of JSON.parse(fs.readFileSync(listFile, 'utf8'))) {
  const r = { file: f, errors: 0, bundler: [], modules: [], ipc: [], viteDeps: [] }
  try {
    const ast = parse(fs.readFileSync(f, 'utf8'), { sourceType: 'unambiguous', errorRecovery: true, allowReturnOutsideFunction: true, allowAwaitOutsideFunction: true, plugins: ['jsx'] })
    r.errors = (ast.errors || []).length
    r.fp = fp(ast.program)
    const st = [ast.program]
    while (st.length) {
      const n = st.pop()
      if (n.type === 'CallExpression') {
        const c = nm(n.callee), a0 = n.arguments[0]
        if (/\.push$/.test(c) && /(webpack|rspack)Chunk/i.test(c) && a0 && a0.type === 'ArrayExpression' && a0.elements[1] && a0.elements[1].type === 'ObjectExpression') {
          r.bundler.push(/rspack/i.test(c) ? 'rspack' : 'webpack')
          for (const p of a0.elements[1].properties) r.modules.push({ id: String(key(p)), line: p.loc.start.line, fp: fp(p.value || p) })
        } else if ((c === '__commonJS' || c === '__esm') && a0 && a0.type === 'ObjectExpression') {
          r.bundler.push('esbuild')
          for (const p of a0.properties) r.modules.push({ id: String(key(p)), line: p.loc.start.line, fp: fp(p.value || p) })
        } else if (c === '__vite__mapDeps') r.bundler.push('vite')
        const m = /(?:^|\.)(ipcRenderer|ipcMain)\.(\w+)$/.exec(c)
        if (m && IPC.has(m[2]) && a0 && a0.type === 'StringLiteral') r.ipc.push({ side: m[1] === 'ipcMain' ? 'main' : 'renderer', method: m[2], channel: a0.value, line: n.loc.start.line })
      }
      if (n.type === 'VariableDeclarator' && n.id.name === '__webpack_modules__' && n.init && n.init.type === 'ObjectExpression') {
        r.bundler.push('webpack')
        for (const p of n.init.properties) r.modules.push({ id: String(key(p)), line: p.loc.start.line, fp: fp(p.value || p) })
      }
      if (n.type === 'AssignmentExpression' && n.left.type === 'MemberExpression' && (n.left.property.name === 'f' || n.left.property.name === 'viteFileDeps') && n.right.type === 'ArrayExpression')
        r.viteDeps.push(...n.right.elements.filter(e => e && e.type === 'StringLiteral').map(e => e.value))
      st.push(...kids(n))
    }
  } catch (e) { r.fatal = String(e.message || e).slice(0, 200) }
  r.bundler = [...new Set(r.bundler)]
  process.stdout.write(JSON.stringify(r) + '\n')
}
'''

RX_IPC = re.compile(r'(ipcRenderer|ipcMain)\s*\.\s*(send|sendSync|invoke|on|once|handle|handleOnce)\s*\(\s*["\']([^"\']{1,200})["\']')

def regex_pass(f):
    """The fallback when node or @babel/parser is missing: bundler markers and IPC calls by regex (derived)."""
    t = open(f, encoding='utf-8', errors='replace').read()
    bund = [n for n, rx in (('webpack', r'webpackChunk|__webpack_require__'), ('rspack', r'rspackChunk'), ('esbuild', r'__commonJS\(|__esm\('),
                            ('vite', r'__vite__mapDeps')) if re.search(rx, t)]
    ipc = [{'side': 'main' if m.group(1) == 'ipcMain' else 'renderer', 'method': m.group(2), 'channel': m.group(3),
            'line': t.count('\n', 0, m.start()) + 1} for m in RX_IPC.finditer(t)]
    return {'file': f, 'errors': 0, 'bundler': bund, 'modules': [], 'ipc': ipc, 'viteDeps': [], 'regex': True}

def ast_pass(files, cache, lims):
    if not files:
        return []
    try:
        node, bab = lib.tool('node'), lib.tool('babel')
    except lib.ToolMissing as e:
        lims.append(f'{e}: regex fallback (no modules, no fingerprints)')
        return [regex_pass(f) for f in files]
    sdir = osp.join(lib.kit_path('cache'), 'reversy', '_scripts')
    os.makedirs(sdir, exist_ok=True)
    js = osp.join(sdir, 'reversy-ast.mjs')
    if not osp.exists(js) or open(js, encoding='utf-8').read() != AST_JS:
        with open(js, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(AST_JS)
    lst = osp.join(cache, 'ast-files.json')
    json.dump(files, open(lst, 'w', encoding='utf-8'))
    babel_dir = osp.dirname(osp.dirname(osp.dirname(bab)))   # .../node_modules/@babel/parser/package.json -> node_modules/..
    code, txt, cut = lib.run([node, js, osp.dirname(babel_dir), lst], timeout=600, cap=64 << 20)
    rows = [json.loads(l) for l in txt.splitlines() if l.startswith('{')]
    if cut or len(rows) < len(files):
        lims.append(f'AST pass read {len(rows)} of {len(files)} files (exit {code})')
    return rows

# ---- collect: the files of a target (folder walk, asar extraction), capped
def asar_extract(path, dest):
    """Our asar reader: pickle sizes, JSON header, files at 8 + header size; returns (files written, refused)."""
    b = open(path, 'rb').read()
    hsize, = struct.unpack_from('<I', b, 4)
    budget, total = max(256 << 20, 5 * len(b)), [0]   # bytes written: one offset listed 20k times cannot fill the disk
    jlen, = struct.unpack_from('<I', b, 12)
    header = json.loads(b[16:16 + jlen].decode('utf-8'))
    base, seen, n, refused = 8 + hsize, set(), 0, []
    os.makedirs(dest, exist_ok=True)

    def walk(node, prefix):
        nonlocal n
        for name, e in node.get('files', {}).items():
            rel = lib.safe_name(f'{prefix}/{name}' if prefix else name)
            if not rel:
                refused.append(name)
                continue
            if 'files' in e:
                walk(e, rel)
            elif not e.get('unpacked') and 'offset' in e and n < 20000 and total[0] < budget:
                off, size = base + int(e['offset']), max(0, int(e.get('size', 0)))
                if off < base or off + size > len(b):
                    refused.append(name)
                    continue
                if lib.safe_write(dest, rel, b[off:off + size], seen):
                    total[0] += size
                    n += 1
    walk(header, '')
    return n, refused

def collect(path, cache, out):
    files, exes, others = [], [], []
    roots = [path]
    if osp.isfile(path) and path.endswith('.asar'):
        dest = osp.join(cache, 'asar')
        if not osp.isdir(dest):
            n, bad = asar_extract(path, dest)
            out.add(f'asar: {n} files extracted to {dest}' + (f' · refused {bad[:5]}' if bad else ''))
        roots = [dest]
    for r in roots:
        if osp.isfile(r):
            (files if r.endswith(JS_EXT) else exes if r.endswith('.exe') else others).append(r)
            continue
        for d, dirs, fs in os.walk(r):
            dirs[:] = [x for x in dirs if x not in ('.git',)]
            for f in fs:
                p = osp.join(d, f)
                if f.endswith('.asar'):
                    dest = osp.join(cache, 'asar-' + hashlib.sha256(p.encode()).hexdigest()[:8])
                    if not osp.isdir(dest):
                        n, bad = asar_extract(p, dest)
                        out.add(f'asar {osp.relpath(p, r)}: {n} files')
                    sub, _, _ = collect(dest, cache, out)
                    files += sub
                elif f.endswith(JS_EXT):
                    files.append(p)
                elif f.endswith(('.exe', '.map', '.wasm', '.har', '.saz')) or f in ('electron', 'electron.exe'):
                    (exes if f.endswith('.exe') else others).append(p)
    files = [f for f in files if os.path.getsize(f) <= 32 << 20][:3000]
    return files, exes, others

# ---- sourcemaps: map files and inline maps; recover sourcesContent; score local sources
def maps_of(files, others):
    maps = [osp.normpath(m) for m in others if m.endswith('.map')]
    for f in files:
        with open(f, 'rb') as fh:
            fh.seek(max(0, os.path.getsize(f) - 4096))
            tail = fh.read().decode('utf-8', 'replace')
        m = re.search(r'[#@] sourceMappingURL=(\S+)\s*$', tail)
        if not m:
            continue
        u = m.group(1)
        if u.startswith('data:'):
            maps.append(('inline', f, u))
        elif not re.match(r'^[a-z]+://', u):
            p = osp.normpath(osp.join(osp.dirname(f), u))
            if osp.exists(p) and p not in maps:
                maps.append(p)
    return maps

def read_map(m):
    if isinstance(m, tuple):
        data = m[2].split(',', 1)[1]
        return json.loads(base64.b64decode(data) if ';base64' in m[2] else data), m[1] + ' (inline map)'
    return json.load(open(m, encoding='utf-8', errors='replace')), m

def recover(maps, cache):
    """[(map path, source path, recovered file or None)]."""
    rows, seen = [], set()
    dest = osp.join(cache, 'sources')
    for m in maps:
        try:
            sm, where = read_map(m)
        except (ValueError, OSError):
            continue
        content = sm.get('sourcesContent') or []
        for i, s in enumerate(sm.get('sources', [])):
            rel = lib.safe_name('/'.join(p for p in re.sub(r'^[a-z-]+://', '', s or '').split('/') if p not in ('..', '.')))
            got = None
            if rel and i < len(content) and content[i] is not None:
                p = osp.join(dest, *rel.split('/'))
                if not osp.exists(p) and lib.safe_write(dest, rel, content[i].encode('utf-8'), seen):
                    got = p
                elif osp.exists(p):
                    got = p
            rows.append((where, s, got))
    return rows

def score(rows, src_dir):
    local = {}
    for d, _, fs in os.walk(src_dir):
        for f in fs:
            p = osp.join(d, f)
            local[osp.relpath(p, src_dir).replace('\\', '/')] = p
    digests = {}
    out = []
    for where, s, got in rows:
        norm = re.sub(r'^[a-z-]+://[^/]*/?', '', s or '').lstrip('./')
        best = (0, None)
        for rel, p in local.items():
            sc = 0
            if got:
                dg = digests.setdefault(p, hashlib.sha256(open(p, 'rb').read()).hexdigest())
                sc = 100 if dg == hashlib.sha256(open(got, 'rb').read()).hexdigest() else 0
            sc = sc or (70 if rel == norm else 60 if rel.lower() == norm.lower() else 40 if norm.endswith(rel) or rel.endswith(norm)
                        else 20 if osp.basename(rel) == osp.basename(norm) else 0)
            if sc > best[0]:
                best = (sc, rel)
        if best[0] >= 20:
            out.append((s, best[1], best[0]))
    return out

# ---- electron: fuses sentinel, IPC pairing
FUSE_SENTINEL = b'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'
FUSES_V1 = ('RunAsNode', 'EnableCookieEncryption', 'EnableNodeOptionsEnvironmentVariable', 'EnableNodeCliInspectArguments',
            'EnableEmbeddedAsarIntegrityValidation', 'OnlyLoadAppFromAsar', 'LoadBrowserProcessSpecificV8Snapshot',
            'GrantFileProtocolExtraPrivileges', 'WasmTrapHandlers')

def fuses(path):
    b = open(path, 'rb').read()
    at = b.find(FUSE_SENTINEL)
    if at < 0:
        return None
    ver, n = b[at + 32], b[at + 33]
    state = {0x30: 'off', 0x31: 'on', 0x72: 'removed'}
    return ver, [(FUSES_V1[i] if i < len(FUSES_V1) else f'fuse{i}', state.get(b[at + 34 + i], hex(b[at + 34 + i]))) for i in range(n)]

def pair_ipc(calls):
    """{channel: (status, renderer calls, main handlers)}: invoke pairs only with handle(Once); one match = paired, more = ambiguous."""
    res = {}
    for ch in sorted({c['channel'] for c in calls}):
        r = [c for c in calls if c['channel'] == ch and c['side'] == 'renderer']
        m = [c for c in calls if c['channel'] == ch and c['side'] == 'main']
        inv = any(c['method'] == 'invoke' for c in r)
        match = [c for c in m if (c['method'] in ('handle', 'handleOnce')) == inv] if r else m
        res[ch] = ('paired' if len(match) == 1 and r else 'ambiguous' if len(match) > 1 and r else 'renderer only' if r else 'main only', r, m)
    return res

# ---- wasm-har: wasm imports / exports (own reader), HAR and SAZ request lists
def leb(b, at):
    n = shift = 0
    while True:
        if at >= len(b):   # truncated: the reader stops at the end
            return n, len(b)
        x = b[at]
        at += 1
        n |= (x & 0x7f) << shift
        shift += 7
        if x < 0x80:
            return n, at

def wasm_names(path):
    b = open(path, 'rb').read()
    if b[:4] != b'\0asm':
        return None
    at, imps, exps = 8, [], []
    while at < len(b):
        sid, at = leb(b, at)
        size, at = leb(b, at)
        end = at + size
        if sid in (2, 7):
            n, p = leb(b, at)
            for _ in range(n):
                if sid == 2:
                    l, p = leb(b, p)
                    mod = b[p:p + l].decode('utf-8', 'replace')
                    p += l
                l, p = leb(b, p)
                name = b[p:p + l].decode('utf-8', 'replace')
                p += l
                kind = b[p]
                p += 1
                if sid == 7:
                    _, p = leb(b, p)
                    exps.append(f'{"func table memory global tag".split()[kind] if kind < 5 else kind} {name}')
                else:
                    if kind == 0:
                        _, p = leb(b, p)
                    elif kind == 1:
                        p += 1
                        fl, p = leb(b, p)
                        _, p = leb(b, p)
                        if fl & 1:
                            _, p = leb(b, p)
                    elif kind == 2:
                        fl, p = leb(b, p)
                        _, p = leb(b, p)
                        if fl & 1:
                            _, p = leb(b, p)
                    elif kind == 3:
                        p += 2
                    else:
                        p += 1
                        _, p = leb(b, p)
                    imps.append(f'{mod}.{name}')
        at = end
    return imps, exps

def har_rows(path):
    if path.endswith('.saz'):
        rows = []
        with zipfile.ZipFile(path) as z:
            for n in sorted(z.namelist()):
                m = re.match(r'raw/(\d+)_c\.txt$', n)
                if m:
                    req = z.read(n)[:2048].decode('utf-8', 'replace').split('\r\n', 1)[0]
                    sn = f'raw/{m.group(1)}_s.txt'
                    st = z.read(sn)[:256].decode('utf-8', 'replace').split('\r\n', 1)[0] if sn in z.namelist() else '?'
                    rows.append(f'{req} -> {st}')
        return rows
    h = json.load(open(path, encoding='utf-8', errors='replace'))
    return [f'{e["request"].get("method")} {e["request"].get("url", "")[:200]} -> {e.get("response", {}).get("status")} '
            f'{e.get("response", {}).get("content", {}).get("mimeType", "")} {e.get("response", {}).get("content", {}).get("size", "")}'
            for e in h.get('log', {}).get('entries', [])]

# ---- run: collect, AST, maps, Electron, wasm, HAR; summary + index
def run(a, out):
    subj = lib.subject(a.path)
    lib.set_last(subj, 'web')
    cache = lib.cache_dir(subj['sha256'])
    out.add(f'reversy web: {subj["name"]} · {"folder" if subj["dir"] else lib.fmt_size(subj["size"])} · sha256 {subj["sha256"][:16]}')
    files, exes, others = collect(a.path, cache, out)
    lims, recs = [], []
    rows = ast_pass(files, cache, lims)
    bund, nmod, calls, vite = {}, 0, [], []
    for r in rows:
        for x in r['bundler']:
            bund[x] = bund.get(x, 0) + 1
        for m in r['modules']:
            recs.append({'kind': 'module', 'verb': 'web', 'name': m['id'], 'file': r['file'], 'addr': f'line {m["line"]}', 'value': m['fp']})
        nmod += len(r['modules'])
        calls += [{**c, 'file': r['file']} for c in r['ipc']]
        vite += r['viteDeps']
        recs.append({'kind': 'file', 'verb': 'web', 'name': osp.basename(r['file']), 'file': r['file'], 'value': r.get('fp', ''),
                     'errors': r.get('errors', 0)})
    errs = sum(r.get('errors', 0) for r in rows)
    out.add(f'{len(files)} JS files · bundlers: ' + (', '.join(f'{k} ({v} files)' for k, v in bund.items()) or 'none found') +
            f' · {nmod} modules · {errs} recovered parse errors' + (f' · vite deps {len(vite)}' if vite else ''))
    if calls:
        pairs = pair_ipc(calls)
        out.add(f'Electron IPC: {len(pairs)} channels · ' + ', '.join(f'{k} {sum(1 for v in pairs.values() if v[0] == k)}'
                                                                      for k in ('paired', 'ambiguous', 'renderer only', 'main only')))
        out.untrusted('IPC channels (status: renderer -> main)', '\n'.join(
            f'{ch}: {st}: {", ".join(c["method"] for c in r)} -> {", ".join(c["method"] for c in m)} ({osp.basename((r or m)[0]["file"])}:{(r or m)[0]["line"]})'
            for ch, (st, r, m) in list(pairs.items())[:40]), 2500)
        recs += [{'kind': 'ipc', 'verb': 'web', 'name': ch, 'value': st, 'file': (r or m)[0]['file'], 'addr': f'line {(r or m)[0]["line"]}'}
                 for ch, (st, r, m) in pairs.items()]
    for e in exes[:5]:
        fz = fuses(e)
        if fz:
            out.add(f'Electron fuses {osp.basename(e)} (v{fz[0]}): ' + ', '.join(f'{n}={s}' for n, s in fz[1]))
    maps = maps_of(files, others)
    if maps:
        rec = recover(maps, cache)
        got = [x for x in rec if x[2]]
        out.add(f'source maps: {len(maps)} · {len(rec)} sources named · {len(got)} recovered to {osp.join(cache, "sources")}')
        recs += [{'kind': 'source', 'verb': 'web', 'name': s, 'file': g or '', 'value': w} for w, s, g in rec]
        if a.source:
            sc = score(rec, a.source)
            out.add(f'source match vs {a.source}: {len(sc)} of {len(rec)} sources score >= 20 · ' +
                    ', '.join(f'{s} -> {l} {p}' for s, l, p in sorted(sc, key=lambda x: -x[2])[:12]))
    for w in [o for o in others if o.endswith('.wasm')] + ([a.path] if a.path.endswith('.wasm') else []):
        names = wasm_names(w)
        if names:
            out.add(f'wasm {osp.basename(w)}: {len(names[0])} imports · {len(names[1])} exports: ' + ', '.join(names[1][:15]))
            recs += [{'kind': 'wasm', 'verb': 'web', 'name': n, 'file': w} for n in names[0] + names[1]]
    for h in [o for o in others if o.endswith(('.har', '.saz'))] + ([a.path] if a.path.endswith(('.har', '.saz')) else []):
        hr = har_rows(h)
        hosts = sorted({re.sub(r'^\w+ (https?://[^/ ]+).*', r'\1', r) for r in hr})
        out.add(f'{osp.basename(h)}: {len(hr)} requests · {len(hosts)} hosts')
        out.untrusted('requests', '\n'.join(hr[:40]), 3000)
        recs += [{'kind': 'request', 'verb': 'web', 'name': r[:300], 'file': h} for r in hr]
    lib.write_index(subj['sha256'], 'web', recs)
    rid = lib.evidence(a.agent, subj, 'web', {'source': a.source}, {'files': len(files), 'modules': nmod, 'ipc': len(calls)},
                       confidence='derived', coverage='partial' if lims else 'complete', limitations=lims)
    for l in lims:
        out.add(f'limit: {l}')
    out.add(f'evidence {rid} (static: nothing was executed) · next: find <regex> --kind module|ipc|source|file|wasm|request · show <name>')
    return 0

# ---- show: a recovered source, a module's code span, or a file head
def show(rec, subj, a, out):
    f = rec.get('file')
    if not f or not osp.exists(f):
        out.add(f'{rec["kind"]} {rec["name"]} {rec.get("value", "")}')
        return 0
    if rec['kind'] == 'wasm':   # the module as text (WABT wasm2wat)
        code, text, _ = lib.run([lib.tool('wasm2wat'), f], timeout=120)
        out.add(f'wasm {rec["name"]} {f} (wasm2wat exit {code}, derived)')
        out.untrusted('wat', text, 10000)
        return 0
    text = open(f, encoding='utf-8', errors='replace').read()
    if rec['kind'] in ('module', 'ipc') and rec.get('addr', '').startswith('line '):
        ln = int(rec['addr'][5:])
        lines = text.split('\n')
        if len(lines) > 3:   # a pretty bundle: the module's lines; a one-line bundle: the slice around it
            text = '\n'.join(lines[max(0, ln - 1):ln + 120])
    out.add(f'{rec["kind"]} {rec["name"]} {f} {rec.get("addr", "")} fp {rec.get("value", "")}')
    out.untrusted(f'{rec["kind"]} text', text, 10000)
    return 0
