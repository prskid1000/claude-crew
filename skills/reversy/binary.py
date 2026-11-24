"""binary: native PE / ELF / Mach-O / raw: headers, imports, exports, resources, Go / Rust build facts; Ghidra indexes every function.
Usage: python -X utf8 <kit>/skills/reversy/reversy.py binary <file> [--quick] [--timeout s] (then find / show).
Engines: Ghidra analyzeHeadless + the ReversyExport post-script below (one pass: functions.jsonl, strings.jsonl; show
  decompiles one function on the kept project); fallback rizin (aflj) with lib caps. Exit codes: as reversy.py.
Sections: L16 args · L24 elf · L74 build-facts · L127 pe-tables · L222 run · L290 ghidra · L471 show
"""
import json
import os
import os.path as osp
import re
import struct
import zlib

import lib

# ---- args: the verb's options
def add(p):
    p.add_argument('path')
    p.add_argument('--quick', action='store_true', help='headers only, no Ghidra')
    p.add_argument('--timeout', type=int, default=3600, help='Ghidra analysis seconds')

KINDS = {b'MZ': 'PE', b'\x7fELF': 'ELF', b'\xcf\xfa\xed\xfe': 'Mach-O', b'\xce\xfa\xed\xfe': 'Mach-O', b'\xca\xfe\xba\xbe': 'Mach-O fat or Java class'}

# ---- elf: sections, symbols, vaddr -> offset (android reads Dart symbols with it)
def elf_sections(b):
    """[(name, type, addr, offset, size, link, entsize)] or [] (32/64-bit little-endian)."""
    if b[:4] != b'\x7fELF' or b[5] != 1:
        return []
    is64 = b[4] == 2
    if is64:
        shoff, = struct.unpack_from('<Q', b, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    else:
        shoff, = struct.unpack_from('<I', b, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x2e)
    raw = []
    for i in range(shnum):
        at = shoff + i * shentsize
        if at + shentsize > len(b):
            break
        if is64:
            nm, ty, _, addr, off, size, link, _, _, ent = struct.unpack_from('<IIQQQQIIQQ', b, at)
        else:
            nm, ty, _, addr, off, size, link, _, _, ent = struct.unpack_from('<IIIIIIIIII', b, at)
        raw.append((nm, ty, addr, off, size, link, ent))
    if not raw or shstrndx >= len(raw):
        return []
    stroff = raw[shstrndx][3]
    return [(lib.cstr(b, stroff + r[0], 64), *r[1:]) for r in raw]

def elf_symbols(b, secs):
    """{name: (value, size)} from .dynsym and .symtab."""
    is64, out = b[4] == 2, {}
    for nm, ty, addr, off, size, link, ent in secs:
        if ty not in (2, 11) or link >= len(secs):
            continue
        stro = secs[link][3]
        step = ent or (24 if is64 else 16)
        for at in range(off, off + size - step + 1, step):
            if is64:
                n, _, _, _, val, sz = struct.unpack_from('<IBBHQQ', b, at)
            else:
                n, val, sz, _, _, _ = struct.unpack_from('<IIIBBH', b, at)
            if n:
                out[lib.cstr(b, stro + n, 256)] = (val, sz)
    return out

def elf_off(secs, vaddr):
    for nm, ty, addr, off, size, link, ent in secs:
        if ty != 8 and addr and addr <= vaddr < addr + size:
            return vaddr - addr + off
    return None

# ---- build-facts: Go buildinfo, Rust .dep-v0, rustc commit
def uvarint(b, at):
    n = shift = 0
    while at < len(b):
        x = b[at]
        at += 1
        n |= (x & 0x7f) << shift
        if x < 0x80:
            break
        shift += 7
    return n, at

def go_buildinfo(b):
    """{'go': version, 'path': ..., 'deps': [...], 'build': [...], 'offset'} or None. Only the inline (Go 1.18+) form is read."""
    at = b.find(b'\xff Go buildinf:')
    while at >= 0 and at % 16:
        at = b.find(b'\xff Go buildinf:', at + 1)
    if at < 0:
        return None
    flags = b[at + 15]
    if not flags & 2:
        return {'offset': at, 'go': '?', 'limitation': 'pre-1.18 pointer form: version not read'}
    n, p = uvarint(b, at + 32)
    ver = b[p:p + n].decode('utf-8', 'replace')
    n, p = uvarint(b, p + n)
    mod = b[p:p + n]
    mod = mod[16:-16] if len(mod) >= 33 else mod   # 16-byte sentinels frame the module text
    lines = mod.decode('utf-8', 'replace').split('\n')
    pick = lambda k: [l.split('\t', 1)[1] for l in lines if l.startswith(k + '\t')]
    return {'offset': at, 'go': ver, 'path': (pick('path') or [''])[0], 'main': (pick('mod') or [''])[0],
            'deps': pick('dep'), 'replaced': pick('=>'), 'build': pick('build')}

def rust_facts(b, pe, secs):
    """{'packages': [...], 'rustc': commit} or None."""
    data = None
    if pe:
        s = next((x for x in pe['sections'] if x[0] == '.dep-v0'), None)
        data = b[s[3]:s[3] + s[4]] if s else None
    elif secs:
        s = next((x for x in secs if x[0] == '.dep-v0'), None)
        data = b[s[3]:s[3] + s[4]] if s else None
    commit = re.search(rb'/rustc/([0-9a-f]{40})/', b)
    if not data and not commit:
        return None
    out = {'rustc': commit.group(1).decode() if commit else None, 'packages': []}
    if data:
        try:
            js = json.loads(zlib.decompress(data.rstrip(b'\0')))
            out['packages'] = [f'{p.get("name")}@{p.get("version")}' + (' (root)' if p.get('root') else '') for p in js.get('packages', [])]
        except (zlib.error, ValueError) as e:
            out['limitation'] = f'.dep-v0 unreadable: {e}'
    return out

# ---- pe-tables: imports, exports, resources, version strings
def pe_imports(b, pe):
    rva, size = pe['dirs'][1] if len(pe['dirs']) > 1 else (0, 0)
    off, out = lib.rva_off(pe, rva), []
    while off is not None and off + 20 <= len(b) and len(out) < 500:
        oft, _, _, name, ft = struct.unpack_from('<IIIII', b, off)
        if not (oft or name or ft):
            break
        dll, fns = lib.cstr(b, lib.rva_off(pe, name)), []
        t = lib.rva_off(pe, oft or ft)
        step, flag = (8, 1 << 63) if pe['bits'] == 64 else (4, 1 << 31)
        while t is not None and t + step <= len(b) and len(fns) < 5000:
            v = struct.unpack_from('<Q' if step == 8 else '<I', b, t)[0]
            if not v:
                break
            fns.append(f'#{v & 0xffff}' if v & flag else lib.cstr(b, (lib.rva_off(pe, v & 0x7fffffff) or 0) + 2, 256))
            t += step
        out.append((dll, fns))
        off += 20
    return out

def pe_exports(b, pe):
    rva, size = pe['dirs'][0] if pe['dirs'] else (0, 0)
    off = lib.rva_off(pe, rva) if rva else None
    if off is None:
        return '', []
    name, base, nfun, nnam, afun, anam, aord = struct.unpack_from('<IIIIIII', b, off + 12)
    fo, no, oo = lib.rva_off(pe, afun), lib.rva_off(pe, anam), lib.rva_off(pe, aord)
    funcs = [struct.unpack_from('<I', b, fo + 4 * i)[0] for i in range(min(nfun, 100000))] if fo is not None else []
    named = {}
    for i in range(min(nnam, 100000)):
        if no is None or oo is None:
            break
        nm = lib.cstr(b, lib.rva_off(pe, struct.unpack_from('<I', b, no + 4 * i)[0]), 512)
        named[struct.unpack_from('<H', b, oo + 2 * i)[0]] = nm
    out = []
    for i, f in enumerate(funcs):
        if not f:
            continue
        fwd = rva <= f < rva + size   # a forwarder string, not code
        out.append((named.get(i, f'#{base + i}'), pe['image_base'] + f, lib.cstr(b, lib.rva_off(pe, f)) if fwd else None))
    return lib.cstr(b, lib.rva_off(pe, name)), out

RT = {1: 'CURSOR', 2: 'BITMAP', 3: 'ICON', 4: 'MENU', 5: 'DIALOG', 6: 'STRING', 9: 'ACCELERATOR', 10: 'RCDATA', 12: 'GROUP_CURSOR',
      14: 'GROUP_ICON', 16: 'VERSION', 23: 'HTML', 24: 'MANIFEST'}

def pe_resources(b, pe):
    """[(type, name, lang, file offset, size, sha256)]: the three-level directory (type, name, language)."""
    rva, size = pe['dirs'][2] if len(pe['dirs']) > 2 else (0, 0)
    root = lib.rva_off(pe, rva) if rva else None
    if root is None:
        return []
    out = []

    def label(v):
        if v & 0x80000000:
            at = root + (v & 0x7fffffff)
            n = struct.unpack_from('<H', b, at)[0]
            return b[at + 2:at + 2 + 2 * n].decode('utf-16le', 'replace')
        return v

    def walk(at, path, depth):
        if depth > 2 or at + 16 > len(b) or len(out) > 5000:
            return
        named, ids = struct.unpack_from('<HH', b, at + 12)
        for i in range(named + ids):
            nid, ptr = struct.unpack_from('<II', b, at + 16 + 8 * i)
            if ptr & 0x80000000:
                walk(root + (ptr & 0x7fffffff), path + [label(nid)], depth + 1)
            else:
                drva, dsz = struct.unpack_from('<II', b, root + ptr)
                fo = lib.rva_off(pe, drva)
                if fo is not None:
                    import hashlib
                    out.append((*(path + [label(nid)] + ['', ''])[:3], fo, dsz, hashlib.sha256(b[fo:fo + dsz]).hexdigest()))
    walk(root, [], 0)
    return out

VERSION_KEYS = ('CompanyName', 'FileDescription', 'FileVersion', 'InternalName', 'OriginalFilename', 'ProductName', 'ProductVersion', 'LegalCopyright')

def version_strings(blob):
    out = {}
    for k in VERSION_KEYS:
        at = blob.find((k + '\0').encode('utf-16le'))
        if at < 0:
            continue
        p = at + 2 * len(k) + 2
        while p + 1 < len(blob) and blob[p:p + 2] == b'\0\0':
            p += 2
        end = p
        while end + 1 < len(blob) and blob[end:end + 2] != b'\0\0':
            end += 2
        out[k] = blob[p:end].decode('utf-16le', 'replace')
    return out

# ---- run: quick facts always, then the Ghidra index (cached per sha256)
def run(a, out):
    subj = lib.subject(a.path)
    lib.set_last(subj, 'binary')
    with open(a.path, 'rb') as fh:
        b = fh.read(1 << 30)
    kind = next((v for k, v in KINDS.items() if b.startswith(k)), 'raw')
    pe = lib.parse_pe(b) if kind == 'PE' else None
    secs = elf_sections(b) if kind == 'ELF' else []
    out.add(f'reversy binary: {subj["name"]} · {kind} · {lib.fmt_size(subj["size"])} · sha256 {subj["sha256"]}')
    recs, lims = [], []
    if pe:
        cli = len(pe['dirs']) > 14 and pe['dirs'][14][0]
        out.add(f'PE {pe["machine"]} {pe["bits"]}-bit {"DLL" if pe["dll"] else "EXE"} · base {pe["image_base"]:#x} · entry {pe["image_base"] + pe["entry"]:#x} · '
                f'timestamp {pe["timestamp"]}' + (' · .NET (CLI header): use `managed` for types and IL' if cli else ''))
        out.add('sections: ' + ' · '.join(f'{n} {lib.fmt_size(rs)} H{lib.entropy(b[raw:raw + min(rs, 1 << 22)]):.1f} @{raw:#x}'
                                         for n, va, vs, raw, rs, ch in pe['sections']))
        dll, exps = pe_exports(b, pe)
        imps = pe_imports(b, pe)
        recs += [{'kind': 'export', 'name': n, 'addr': f'{va:#x}', 'value': fwd or '', 'verb': 'binary'} for n, va, fwd in exps]
        recs += [{'kind': 'import', 'name': f'{d}!{f}', 'verb': 'binary'} for d, fs in imps for f in fs]
        out.add(f'exports: {len(exps)} · imports: {sum(len(f) for _, f in imps)} from {len(imps)} DLLs')
        out.untrusted('export and import names', (f'module name {dll}\n' if dll else '') + 'exports: ' + ', '.join(n for n, _, _ in exps[:12]) +
                      '\nimport DLLs: ' + ', '.join(f'{d} {len(f)}' for d, f in imps[:15]), 1500)
        res = pe_resources(b, pe)
        if res:
            kinds = {}
            for t, *_ in res:
                kinds[RT.get(t, t)] = kinds.get(RT.get(t, t), 0) + 1
            out.add('resources: ' + ', '.join(f'{k} {n}' for k, n in kinds.items()) + f' (sha256 per payload in the full file)')
            ver = next((r for r in res if r[0] == 16), None)
            if ver:
                vs = version_strings(b[ver[3]:ver[3] + ver[4]])
                if vs:
                    out.untrusted('version strings', '\n'.join(f'{k}: {v}' for k, v in vs.items()))
            out.lines.append('')
            full = [f'resource {RT.get(t, t)}/{n}/{l} @{fo:#x} {sz} B sha256 {h}' for t, n, l, fo, sz, h in res]
            recs += [{'kind': 'resource', 'name': f'{RT.get(t, t)}/{n}/{l}', 'addr': f'{fo:#x}', 'value': h, 'verb': 'binary'} for t, n, l, fo, sz, h in res]
            with open(osp.join(lib.out_dir(a.agent, subj['sha256']), 'resources.txt'), 'w', encoding='utf-8') as fh:
                fh.write('\n'.join(full) + '\n')
    elif secs:
        out.add('ELF sections: ' + ' · '.join(f'{s[0]} {lib.fmt_size(s[4])}' for s in secs if s[0])[:1500])
    elif kind != 'raw':
        lims.append(f'{kind}: headers not parsed here (Ghidra reads it)')
    go = go_buildinfo(b)
    if go:
        out.add(f'Go {go["go"]} @{go["offset"]:#x} · main {go.get("path", "")} {go.get("main", "")} · {len(go.get("deps", []))} deps')
        if go.get('deps'):
            out.untrusted('Go deps', '\n'.join(go['deps'][:40]))
    rs = rust_facts(b, pe, secs)
    if rs:
        out.add(f'Rust: rustc {rs["rustc"] or "?"} · {len(rs["packages"])} packages (.dep-v0)' + (f' · {rs["limitation"]}' if rs.get('limitation') else ''))
        if rs['packages']:
            out.untrusted('Rust packages', '\n'.join(rs['packages'][:40]))
    lib.write_index(subj['sha256'], 'quick', recs)
    coverage, engine = 'partial', 'quick'
    if not a.quick:
        n, engine, why = index_functions(a, subj, out)
        coverage = 'complete' if engine == 'ghidra' else 'partial'
        if why:
            lims.append(why)
    rid = lib.evidence(a.agent, subj, 'binary', {'quick': a.quick}, {'kind': kind, 'records': len(recs), 'engine': engine},
                       coverage=coverage, limitations=lims)
    for l in lims:
        out.add(f'limit: {l}')
    out.add(f'evidence {rid} (observed, coverage {coverage}) · next: find <regex> (functions, strings, exports) · show <fn|0xaddr>')
    return 0

# ---- ghidra: the post-script (our own), one index pass, per-function decompile on the kept project
EXPORT_JAVA = r'''// ReversyExport.java: reversy's Ghidra post-script. index <out>: functions.jsonl + strings.jsonl; decompile <out> <addr,..>: fn/<addr>.c
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class ReversyExport extends GhidraScript {
  static String q(String s) {
    StringBuilder b = new StringBuilder("\"");
    for (char c : s.toCharArray()) {
      if (c == '"' || c == '\\') b.append('\\').append(c);
      else if (c == '\n') b.append("\\n");
      else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
      else b.append(c);
    }
    return b.append('"').toString();
  }
  static String cut(String s, int n) { return s.length() > n ? s.substring(0, n) : s; }
  String str(Address to) {
    Data d = getDataAt(to);
    if (d != null && d.isPointer() && d.getValue() instanceof Address) d = getDataAt((Address) d.getValue());
    return d != null && d.hasStringValue() ? String.valueOf(d.getValue()) : null;
  }
  @Override public void run() throws Exception {
    String[] a = getScriptArgs();
    File out = new File(a[1]);
    out.mkdirs();
    if (a[0].equals("index")) index(out); else decompile(out, a[2].split(","));
  }
  void index(File out) throws Exception {
    Listing lst = currentProgram.getListing();
    ReferenceManager rm = currentProgram.getReferenceManager();
    SymbolTable st = currentProgram.getSymbolTable();
    try (Writer w = new OutputStreamWriter(new FileOutputStream(new File(out, "functions.jsonl")), StandardCharsets.UTF_8)) {
      FunctionIterator it = lst.getFunctions(true);
      while (it.hasNext() && !monitor.isCancelled()) {
        Function f = it.next();
        Address e = f.getEntryPoint();
        StringBuilder callers = new StringBuilder();
        int nc = 0;
        ReferenceIterator ri = rm.getReferencesTo(e);
        while (ri.hasNext()) {
          Reference r = ri.next();
          if (!r.getReferenceType().isCall() && !r.getReferenceType().isJump()) continue;
          Function c = getFunctionContaining(r.getFromAddress());
          if (nc++ < 300) callers.append(nc > 1 ? "," : "").append("[").append(q(c == null ? "?" : c.getName(true))).append(",\"0x").append(r.getFromAddress()).append("\"]");
        }
        StringBuilder callees = new StringBuilder();
        int ne = 0;
        for (Function g : f.getCalledFunctions(monitor)) {
          if (ne++ < 300) callees.append(ne > 1 ? "," : "").append("[").append(q(g.getName(true))).append(",\"0x").append(g.getEntryPoint()).append("\"]");
        }
        LinkedHashSet<String> strs = new LinkedHashSet<>();
        InstructionIterator ii = lst.getInstructions(f.getBody(), true);
        while (ii.hasNext() && strs.size() < 40) {
          for (Reference r : ii.next().getReferencesFrom()) {
            String s = str(r.getToAddress());
            if (s != null) strs.add(q(cut(s, 200)));
          }
        }
        w.write("{\"kind\":\"function\",\"verb\":\"binary\",\"name\":" + q(f.getName(true)) + ",\"addr\":\"0x" + e + "\",\"size\":" + f.getBody().getNumAddresses()
          + ",\"thunk\":" + f.isThunk() + ",\"exported\":" + st.isExternalEntryPoint(e) + ",\"ncallers\":" + nc + ",\"callers\":[" + callers
          + "],\"callees\":[" + callees + "],\"strings\":[" + String.join(",", strs) + "]}\n");
      }
    }
    try (Writer w = new OutputStreamWriter(new FileOutputStream(new File(out, "strings.jsonl")), StandardCharsets.UTF_8)) {
      DataIterator di = lst.getDefinedData(true);
      int n = 0;
      while (di.hasNext() && n < 300000 && !monitor.isCancelled()) {
        Data d = di.next();
        if (!d.hasStringValue()) continue;
        n++;
        LinkedHashSet<String> refs = new LinkedHashSet<>();
        ReferenceIterator ri = rm.getReferencesTo(d.getAddress());
        while (ri.hasNext() && refs.size() < 50) {
          Function c = getFunctionContaining(ri.next().getFromAddress());
          if (c != null) refs.add(q(c.getName(true) + "@0x" + c.getEntryPoint()));
        }
        w.write("{\"kind\":\"string\",\"verb\":\"binary\",\"addr\":\"0x" + d.getAddress() + "\",\"value\":" + q(cut(String.valueOf(d.getValue()), 300)) + ",\"refs\":[" + String.join(",", refs) + "]}\n");
      }
    }
  }
  void decompile(File out, String[] addrs) throws Exception {
    DecompInterface d = new DecompInterface();
    d.openProgram(currentProgram);
    File dir = new File(out, "fn");
    dir.mkdirs();
    for (String s : addrs) {
      Function f = getFunctionContaining(toAddr(s));
      if (f == null) continue;
      DecompileResults r = d.decompileFunction(f, 120, monitor);
      String c = r.decompileCompleted() ? r.getDecompiledFunction().getC() : "// decompile failed: " + r.getErrorMessage();
      try (Writer w = new OutputStreamWriter(new FileOutputStream(new File(dir, "0x" + f.getEntryPoint() + ".c")), StandardCharsets.UTF_8)) { w.write(c); }
    }
    d.dispose();
  }
}
'''

def _ghidra_cmd(subj, mode, extra, timeout=None):
    head = lib.tool('ghidra')
    lib.tool('java', install=False) if not os.environ.get('JAVA_HOME') else None
    sdir = osp.join(lib.kit_path('cache'), 'reversy', '_scripts')
    os.makedirs(sdir, exist_ok=True)
    sp = osp.join(sdir, 'ReversyExport.java')
    if not osp.exists(sp) or open(sp, encoding='utf-8').read() != EXPORT_JAVA:
        with open(sp, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(EXPORT_JAVA)
    proj, cache = lib.ghidra_project(subj['sha256']), lib.cache_dir(subj['sha256'])
    base = [head, proj, 'rv']
    if mode == 'index':
        base += ['-import', subj['path'], '-overwrite', '-analysisTimeoutPerFile', str(timeout)]
    else:
        base += ['-process', subj['name'], '-noanalysis', '-readOnly']
    return base + ['-scriptPath', sdir, '-postScript', 'ReversyExport.java', mode, cache, *extra, '-log', osp.join(cache, f'ghidra-{mode}.log')]

def index_functions(a, subj, out):
    """(functions, engine, limitation or ''): cached Ghidra index, else a Ghidra pass, else rizin."""
    cache = lib.cache_dir(subj['sha256'])
    fj, sj = osp.join(cache, 'functions.jsonl'), osp.join(cache, 'strings.jsonl')
    if not osp.exists(osp.join(cache, 'index-ghidra.jsonl')):
        why = ''
        try:
            mem = '6G' if subj['size'] > 16 << 20 else '4G' if subj['size'] > 4 << 20 else '2G'
            code, txt, _ = lib.run(_ghidra_cmd(subj, 'index', [], a.timeout), timeout=a.timeout + 600, env={'GHIDRA_HEADLESS_MAXMEM': mem},
                                   log=osp.join(cache, 'ghidra-index.out'))
            if not osp.exists(fj):
                why = f'Ghidra exit {code}: ' + ' | '.join(l for l in txt.splitlines() if re.search(r'ERROR|Exception|timeout', l))[:400]
        except lib.ToolMissing as e:
            why = str(e)
        if osp.exists(fj):
            with open(osp.join(cache, 'index-ghidra.jsonl'), 'w', encoding='utf-8', newline='\n') as dst:
                for p in (fj, sj):
                    if osp.exists(p):
                        with open(p, encoding='utf-8', errors='replace') as src:
                            for l in src:
                                dst.write(l)
        else:
            return rizin_index(subj, out, why)
    recs = [json.loads(l) for l in open(osp.join(cache, 'index-ghidra.jsonl'), encoding='utf-8')]
    fns = [r for r in recs if r['kind'] == 'function']
    nstr = len(recs) - len(fns)
    named = [r for r in fns if not re.match(r'^(FUN|thunk_FUN|LAB)_', r['name'])]
    out.add(f'Ghidra index: {len(fns)} functions ({len(named)} named, {sum(1 for r in fns if r.get("exported"))} exported) · {nstr} strings · cache {cache}')
    top = sorted(fns, key=lambda r: -r.get('ncallers', 0))[:10]
    out.untrusted('most called functions', ', '.join(f'{r["name"]} {r["ncallers"]}' for r in top), 1000)
    return len(fns), 'ghidra', ''

def rizin_index(subj, out, why):
    try:
        rz = lib.tool('rizin')
    except lib.ToolMissing as e:
        return 0, 'quick', f'{why} · no fallback: {e}'
    code, txt, cut = lib.run([rz, '-N', '-q', '-c', 'aa;aflj', subj['path']])
    m = re.search(r'\[\{|\[\]', txt)   # the JSON follows terminal escapes
    try:
        fl = json.loads(txt[m.start():].strip()) if m else None
    except ValueError:
        fl = None
    if fl is None:
        return 0, 'quick', f'{why} · rizin exit {code}, no JSON' + (' (cut at 16 MiB)' if cut else '')
    names = {f.get('offset'): f.get('name') for f in fl}
    callers = {}
    for f in fl:
        for c in f.get('callrefs', []):
            if c.get('type') == 'CALL' and c.get('addr') in names:
                callers.setdefault(c['addr'], []).append([f.get('name'), hex(c.get('at', 0))])
    recs = [{'kind': 'function', 'verb': 'binary', 'name': f.get('name'), 'addr': hex(f.get('offset', 0)), 'size': f.get('size', 0),
             'ncallers': len(callers.get(f.get('offset'), [])), 'callers': callers.get(f.get('offset'), [])[:300],
             'callees': [[names[c['addr']], hex(c['addr'])] for c in f.get('callrefs', []) if c.get('type') == 'CALL' and c.get('addr') in names][:300],
             'strings': []} for f in fl]
    lib.write_index(subj['sha256'], 'rizin', recs)
    out.add(f'rizin index: {len(recs)} functions with call graph (no strings, no pseudo-C: coverage partial)')
    return len(recs), 'rizin', f'{why} · rizin fallback: functions and calls only'

# ---- show: one function (callers with call sites, callees, strings, pseudo-C); exports map to their function
def show(rec, subj, a, out):
    recs = lib.read_index(subj['sha256'])
    if rec['kind'] in ('export', 'import'):
        fns = [r for r in recs if r.get('kind') == 'function']
        short = rec['name'].split('!')[-1]
        fn = next((r for r in fns if rec.get('addr') and r.get('addr') == rec['addr']), None) or \
            next((r for r in fns if r['name'] == short or r['name'].endswith('::' + short)), None)   # an address beats a name
        if not fn:
            out.add(line_rec(rec))
            out.add('no function record for it: run binary without --quick (Ghidra index)')
            return 0
        rec = fn
    if rec['kind'] == 'string':
        out.add(f'string {rec["addr"]} used in {len(rec.get("refs", []))} functions: ' + ', '.join(rec.get('refs', [])[:40]))
        out.untrusted('string', rec.get('value', ''))
        return 0
    if rec['kind'] != 'function':
        out.add(line_rec(rec))
        return 0
    out.add(f'function {rec["name"]} @{rec["addr"]} size {rec.get("size")} · {rec.get("ncallers", 0)} callers · {len(rec.get("callees", []))} callees'
            + (' · exported' if rec.get('exported') else '') + (' · thunk' if rec.get('thunk') else ''))
    out.untrusted('callers (function @ call site) and callees', 'callers: ' + ', '.join(f'{n} @{at}' for n, at in rec.get('callers', [])[:40]) +
                  '\ncallees: ' + ', '.join(f'{n} {at}' for n, at in rec.get('callees', [])[:40]), 3000)
    if rec.get('strings'):
        out.untrusted('strings it references', '\n'.join(rec['strings'][:20]), 800)
    cache = lib.cache_dir(subj['sha256'])
    c = osp.join(cache, 'fn', f'{rec["addr"]}.c')
    if not osp.exists(c) and rec.get('ix') == 'ghidra':
        lib.run(_ghidra_cmd(subj, 'decompile', [rec['addr'][2:]]), timeout=600, log=osp.join(cache, 'ghidra-decompile.out'))
    if osp.exists(c):
        out.untrusted(f'pseudo-C (Ghidra decompiler, derived) {c}', open(c, encoding='utf-8', errors='replace').read(), 9000)
    else:
        out.add('no pseudo-C (needs the Ghidra index; see ghidra-decompile.out in the cache)')
    out.add('next: show <callee or caller name> · find <regex>')
    return 0

def line_rec(r):
    return f'{r.get("kind")} {r.get("name")} {r.get("addr", "")} {r.get("value", "")}'.rstrip()
