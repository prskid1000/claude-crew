"""managed: .NET assemblies by their CLI metadata (BSJB root, #~ tables, #Strings, #US, #Blob), never executed.
Usage: python -X utf8 <kit>/skills/reversy/reversy.py managed <dll|exe> (then find; show <Namespace.Type> = ilspycmd C#).
Reads: assembly + refs, types and methods (ECMA-335 II.22 row layouts), P/Invoke (ImplMap), ldstr user strings per method.
Exit codes: as reversy.py.
Sections: L13 args · L17 tables · L54 parse · L154 run · L211 show
"""
import os.path as osp
import re
import struct

import lib

# ---- args: the verb's options
def add(p):
    p.add_argument('path')

# ---- tables: column kinds per table (s string, g guid, b blob, 2/4 fixed, t:<table> index, c:<coded> coded index)
CODED = {'TypeDefOrRef': [2, 1, 0x1b], 'HasConstant': [4, 8, 0x17],
         'HasCustomAttribute': [6, 4, 1, 2, 8, 9, 0xa, 0, 0xe, 0x17, 0x14, 0x11, 0x1a, 0x1b, 0x20, 0x23, 0x26, 0x27, 0x28, 0x2a, 0x2c, 0x2b],
         'HasFieldMarshal': [4, 8], 'HasDeclSecurity': [2, 6, 0x20], 'MemberRefParent': [2, 1, 0x1a, 6, 0x1b], 'HasSemantics': [0x14, 0x17],
         'MethodDefOrRef': [6, 0xa], 'MemberForwarded': [4, 6], 'Implementation': [0x26, 0x23, 0x27], 'CustomAttributeType': [-1, -1, 6, 0xa, -1],
         'ResolutionScope': [0, 0x1a, 0x23, 1], 'TypeOrMethodDef': [2, 6]}
T = lambda n: f't:{n}'
C = lambda n: f'c:{n}'
SCHEMA = {
    0x00: ('Module', ['2', 's', 'g', 'g', 'g']), 0x01: ('TypeRef', [C('ResolutionScope'), 's', 's']),
    0x02: ('TypeDef', ['4', 's', 's', C('TypeDefOrRef'), T(4), T(6)]), 0x03: ('FieldPtr', [T(4)]), 0x04: ('Field', ['2', 's', 'b']),
    0x05: ('MethodPtr', [T(6)]), 0x06: ('MethodDef', ['4', '2', '2', 's', 'b', T(8)]), 0x07: ('ParamPtr', [T(8)]),
    0x08: ('Param', ['2', '2', 's']), 0x09: ('InterfaceImpl', [T(2), C('TypeDefOrRef')]), 0x0a: ('MemberRef', [C('MemberRefParent'), 's', 'b']),
    0x0b: ('Constant', ['2', C('HasConstant'), 'b']), 0x0c: ('CustomAttribute', [C('HasCustomAttribute'), C('CustomAttributeType'), 'b']),
    0x0d: ('FieldMarshal', [C('HasFieldMarshal'), 'b']), 0x0e: ('DeclSecurity', ['2', C('HasDeclSecurity'), 'b']),
    0x0f: ('ClassLayout', ['2', '4', T(2)]), 0x10: ('FieldLayout', ['4', T(4)]), 0x11: ('StandAloneSig', ['b']),
    0x12: ('EventMap', [T(2), T(0x14)]), 0x13: ('EventPtr', [T(0x14)]), 0x14: ('Event', ['2', 's', C('TypeDefOrRef')]),
    0x15: ('PropertyMap', [T(2), T(0x17)]), 0x16: ('PropertyPtr', [T(0x17)]), 0x17: ('Property', ['2', 's', 'b']),
    0x18: ('MethodSemantics', ['2', T(6), C('HasSemantics')]), 0x19: ('MethodImpl', [T(2), C('MethodDefOrRef'), C('MethodDefOrRef')]),
    0x1a: ('ModuleRef', ['s']), 0x1b: ('TypeSpec', ['b']), 0x1c: ('ImplMap', ['2', C('MemberForwarded'), 's', T(0x1a)]),
    0x1d: ('FieldRVA', ['4', T(4)]), 0x1e: ('EncLog', ['4', '4']), 0x1f: ('EncMap', ['4']),
    0x20: ('Assembly', ['4', '2', '2', '2', '2', '4', 'b', 's', 's']), 0x21: ('AssemblyProcessor', ['4']), 0x22: ('AssemblyOS', ['4', '4', '4']),
    0x23: ('AssemblyRef', ['2', '2', '2', '2', '4', 'b', 's', 's', 'b']), 0x24: ('AssemblyRefProcessor', ['4', T(0x23)]),
    0x25: ('AssemblyRefOS', ['4', '4', '4', T(0x23)]), 0x26: ('File', ['4', 's', 'b']), 0x27: ('ExportedType', ['4', '4', 's', 's', C('Implementation')]),
    0x28: ('ManifestResource', ['4', '4', 's', C('Implementation')]), 0x29: ('NestedClass', [T(2), T(2)]),
    0x2a: ('GenericParam', ['2', '2', C('TypeOrMethodDef'), 's']), 0x2b: ('MethodSpec', [C('MethodDefOrRef'), 'b']),
    0x2c: ('GenericParamConstraint', [T(0x2a), C('TypeDefOrRef')]),
}

def blob_len(b, at):
    x = b[at]
    if x & 0x80 == 0:
        return x, at + 1
    if x & 0xc0 == 0x80:
        return ((x & 0x3f) << 8) | b[at + 1], at + 2
    return ((x & 0x1f) << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3], at + 4

# ---- parse: metadata root -> streams -> tables
def parse(b):
    """dict of streams and rows per table name, or raises ValueError."""
    pe = lib.parse_pe(b)
    if not pe or len(pe['dirs']) < 15 or not pe['dirs'][14][0]:
        raise ValueError('not a .NET assembly (no CLI header, data directory 14): try `binary`')
    cli = lib.rva_off(pe, pe['dirs'][14][0])
    md_rva, md_size = struct.unpack_from('<II', b, cli + 8)
    flags, = struct.unpack_from('<I', b, cli + 16)
    root = lib.rva_off(pe, md_rva)
    if b[root:root + 4] != b'BSJB':
        raise ValueError('metadata root has no BSJB signature')
    vlen, = struct.unpack_from('<I', b, root + 12)
    runtime = b[root + 16:root + 16 + vlen].rstrip(b'\0').decode('latin-1')
    at = root + 16 + vlen + 2
    nstreams, = struct.unpack_from('<H', b, at)
    at += 2
    streams = {}
    for _ in range(nstreams):
        off, size = struct.unpack_from('<II', b, at)
        end = b.index(b'\0', at + 8)
        name = b[at + 8:end].decode('latin-1')
        at = (end + 4) & ~3
        streams[name] = (root + off, size)
    tl = streams.get('#~') or streams.get('#-')
    if not tl:
        raise ValueError('no #~ table stream')
    t0 = tl[0]
    heap, = struct.unpack_from('<B', b, t0 + 6)
    valid, = struct.unpack_from('<Q', b, t0 + 8)
    at = t0 + 24
    rows = {}
    for i in range(64):
        if valid >> i & 1:
            rows[i] = struct.unpack_from('<I', b, at)[0]
            at += 4
    if heap & 0x40:   # extra data (uncompressed #- streams)
        at += 4
    ssz, gsz, bsz = (4 if heap & 1 else 2), (4 if heap & 2 else 2), (4 if heap & 4 else 2)

    def width(col):
        if col in ('2', '4'):
            return int(col)
        if col == 's':
            return ssz
        if col == 'g':
            return gsz
        if col == 'b':
            return bsz
        if col.startswith('t:'):
            return 4 if rows.get(int(col[2:]), 0) > 0xffff else 2
        tabs = CODED[col[2:]]
        bits = (len(tabs) - 1).bit_length()
        return 4 if max(rows.get(t, 0) for t in tabs if t >= 0) >= 1 << (16 - bits) else 2
    tables = {}
    for i in sorted(rows):
        if i not in SCHEMA:
            raise ValueError(f'unknown metadata table {i:#x}: layout not read')
        name, cols = SCHEMA[i]
        ws = [width(c) for c in cols]
        out = []
        for _ in range(rows[i]):
            r = []
            for c, w in zip(cols, ws):
                v = struct.unpack_from('<H' if w == 2 else '<I', b, at)[0]
                at += w
                if c.startswith('c:'):
                    bits = (len(CODED[c[2:]]) - 1).bit_length()
                    v = (CODED[c[2:]][v & ((1 << bits) - 1)], v >> bits)
                r.append(v)
            out.append(r)
        tables[name] = out
    s_off = streams.get('#Strings', (0, 0))[0]
    us_off, us_size = streams.get('#US', (0, 0))
    return {'pe': pe, 'runtime': runtime, 'flags': flags, 'tables': tables, 'str': lambda i: lib.cstr(b, s_off + i, 1024),
            'us': (us_off, us_size)}

def user_string(b, md, idx):
    off, size = md['us']
    if not off or idx >= size:
        return None
    n, p = blob_len(b, off + idx)
    return b[p:p + n - 1].decode('utf-16le', 'replace') if n else ''

def method_ldstr(b, md, rva):
    """User-string tokens the method body loads (ldstr 0x72 + 0x70xxxxxx; a byte scan: derived, may over-match)."""
    off = lib.rva_off(md['pe'], rva) if rva else None
    if off is None:
        return []
    h = b[off]
    if h & 3 == 2:
        code, size = off + 1, h >> 2
    elif h & 3 == 3:
        size, = struct.unpack_from('<I', b, off + 4)
        code = off + 4 * (struct.unpack_from('<H', b, off)[0] >> 12)
    else:
        return []
    body = b[code:code + min(size, 1 << 20)]
    return [int.from_bytes(m.group(1), 'little') for m in re.finditer(rb'\x72(...)\x70', body, re.S)]

# ---- run: summary + index (types, methods, pinvoke, strings)
def run(a, out):
    subj = lib.subject(a.path)
    lib.set_last(subj, 'managed')
    b = open(a.path, 'rb').read()
    md = parse(b)
    t, s = md['tables'], md['str']
    asm = t.get('Assembly', [[0, 0, 0, 0, 0, 0, 0, 0, 0]])[0]
    out.add(f'reversy managed: {subj["name"]} · sha256 {subj["sha256"]} · runtime {md["runtime"]} · '
            f'{"IL only" if md["flags"] & 1 else "mixed / native code inside"}')
    out.add(f'assembly {s(asm[7]) or "?"} {asm[1]}.{asm[2]}.{asm[3]}.{asm[4]} · refs: ' +
            ', '.join(f'{s(r[6])} {r[0]}.{r[1]}' for r in t.get('AssemblyRef', [])[:20]))
    types, methods, recs = t.get('TypeDef', []), t.get('MethodDef', []), []
    owner, outer = {}, {r[0]: r[1] for r in t.get('NestedClass', [])}

    def tname(i):   # 1-based TypeDef row; nested types: Outer+Inner
        ty = types[i - 1]
        return f'{tname(outer[i])}+{s(ty[1])}' if i in outer and outer[i] != i else f'{s(ty[2])}.{s(ty[1])}'.lstrip('.')
    for i, ty in enumerate(types):
        end = types[i + 1][5] if i + 1 < len(types) else len(methods) + 1
        full = tname(i + 1)
        recs.append({'kind': 'type', 'verb': 'managed', 'name': full, 'value': f'{end - ty[5]} methods'})
        for m in range(ty[5], end):
            owner[m] = full
    ustr = {}
    for i, m in enumerate(methods, 1):
        name = f'{owner.get(i, "?")}::{s(m[3])}'
        recs.append({'kind': 'method', 'verb': 'managed', 'name': name, 'addr': f'{m[0]:#x}' if m[0] else ''})
        for tok in method_ldstr(b, md, m[0]):
            v = user_string(b, md, tok)
            if v is not None:
                ustr.setdefault(v, set()).add(name)
    pinv = []
    mods = t.get('ModuleRef', [])
    for r in t.get('ImplMap', []):
        tab, row = r[1]
        target = f'{owner.get(row, "?")}::{s(methods[row - 1][3])}' if tab == 6 and 0 < row <= len(methods) else f'field {row}'
        dll = s(mods[r[3] - 1][0]) if 0 < r[3] <= len(mods) else '?'
        pinv.append(f'{dll}!{s(r[2])} <- {target}')
        recs.append({'kind': 'pinvoke', 'verb': 'managed', 'name': f'{dll}!{s(r[2])}', 'value': target})
    recs += [{'kind': 'string', 'verb': 'managed', 'value': v[:300], 'refs': sorted(u)[:50]} for v, u in ustr.items()]
    res = [s(r[2]) for r in t.get('ManifestResource', [])]
    lib.write_index(subj['sha256'], 'managed', recs)
    ns = {}
    for r in recs:
        if r['kind'] == 'type':
            ns[r['name'].rsplit('.', 1)[0] if '.' in r['name'] else '-'] = ns.get(r['name'].rsplit('.', 1)[0] if '.' in r['name'] else '-', 0) + 1
    out.add(f'{len(types)} types · {len(methods)} methods · {len(pinv)} P/Invoke · {len(ustr)} user strings in code · {len(res)} resources')
    out.untrusted('namespaces (types) and P/Invoke (dll!entry <- method)', 'namespaces: ' + ', '.join(
        f'{k} {v}' for k, v in sorted(ns.items(), key=lambda x: -x[1])[:20]) + ('\nP/Invoke:\n' + '\n'.join(pinv[:25]) if pinv else ''), 3000)
    if ustr:
        out.untrusted('first user strings', '\n'.join(list(ustr)[:30]), 1200)
    rid = lib.evidence(a.agent, subj, 'managed', {}, {'types': len(types), 'methods': len(methods), 'pinvoke': len(pinv)},
                       limitations=['ldstr found by byte pattern: derived'])
    out.add(f'evidence {rid} (observed) · next: find <regex> --kind type|method|pinvoke|string · show <Namespace.Type> (C# via ilspycmd)')
    return 0

# ---- show: a type's C# from ilspycmd (cached), else its record
def show(rec, subj, a, out):
    if rec['kind'] == 'string':
        out.add('used in: ' + ', '.join(rec.get('refs', [])))
        out.untrusted('user string', rec.get('value', ''))
        return 0
    tname = rec['name'].split('::')[0] if rec['kind'] in ('type', 'method') else None
    if not tname:
        out.add(f'{rec["kind"]} {rec["name"]} {rec.get("value", "")}')
        return 0
    cs = osp.join(lib.cache_dir(subj['sha256'], 'cs'), re.sub(r'[^\w.-]', '_', tname) + '.cs')
    if not osp.exists(cs):
        code, txt, _ = lib.run([lib.tool('ilspycmd'), '-t', tname, subj['path']], timeout=300)
        if code:
            out.add(f'ilspycmd exit {code}: {txt[:400]}')
            return 1
        with open(cs, 'w', encoding='utf-8') as fh:
            fh.write(txt)
    out.add(f'type {tname} (ilspycmd C#, derived) {cs}')
    out.untrusted('decompiled C#', open(cs, encoding='utf-8').read(), 10000)
    return 0
