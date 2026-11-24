"""reversy.py: clean-room reverse engineering of shipped apps and binaries without source: one capped summary per verb, a
cached index that find / show read, evidence records. Run from pwsh 7:
  python -X utf8 <kit>/skills/reversy/reversy.py <verb> <target> [options] [--agent <id>] [--page n] [--again]
Verbs: binary <exe|dll|so|elf|raw> [--quick] [--timeout s]   PE/ELF facts, Go / Rust / PE resources, Ghidra index of every function
  managed <.NET dll|exe>   CLI metadata: types, methods, P/Invoke, user strings (show <Type> = ilspycmd source)
  android <apk|xapk|apks> [--quick] · android device packages|pull|logcat|screencap|props [arg]   manifest, classes (jadx), Flutter / Dart
  web <js|map|asar|wasm|har|saz|folder>   bundler modules, fingerprints, source maps, Electron IPC + fuses, wasm, HAR / SAZ
  firmware <image> [--wsl]   signatures, entropy, UEFI (UEFIExtract, ifrextractor); binwalk / unblob only through WSL
  runtime pcap <file> · runtime sqlite <db> [--table t] · runtime procs · runtime frida <pid|name> --script <js> [--seconds n]
  find <regex> [--kind k] [--target <file>]   search the index (functions, strings, exports, classes, types, modules)
  show <name|0xaddr> [--target <file>]   one function / class / type / source: callers, callees, strings, code (<= 3k tokens)
  tools [--install <name>]   which engines are found, where
Inputs: lib.py header (REVERSY_TOOLS, REVERSY_OFFLINE). Outputs: a summary <= 2k tokens; full text + evidence.jsonl in
  <runtime>/work/agents/<agent>/reversy/<sha16>/; the index and engine caches in <runtime>/cache/reversy/<sha16>/.
Exit codes: 0 ok · 1 problem (target unreadable, engine failed) · 2 usage error.
Sections: L18 imports · L33 find · L77 show · L118 tools · L133 main
"""
# ---- imports: one module per verb
import argparse
import hashlib
import os
import os.path as osp
import re
import sqlite3
import struct
import sys
import zipfile

import lib
import binary, managed, android, web, firmware, runtime
VERBS = {'binary': binary, 'managed': managed, 'android': android, 'web': web, 'firmware': firmware, 'runtime': runtime}

# ---- find: regex over the index records of one target
def find(a, out):
    subj = target_subject(a)
    recs = lib.read_index(subj['sha256'])
    if not recs:
        out.add(f'reversy find: no index for {subj["name"]}: run its verb first (binary / managed / android / web)')
        return 1
    try:
        rx = re.compile(a.pattern, re.I)
    except re.error as e:
        out.add(f'reversy find: bad regex: {e}')
        return 2
    hits = []
    for r in recs:
        if a.kind and r.get('kind') != a.kind:
            continue
        hay = [r.get('name', ''), r.get('value', ''), r.get('file', '')] + [s for s in r.get('strings', [])]
        if any(rx.search(h or '') for h in hay):
            hits.append(r)
    kinds = {}
    for r in recs:
        kinds[r.get('kind')] = kinds.get(r.get('kind'), 0) + 1
    shown, label = lib.page(hits, a.page)
    out.add(f'reversy find /{a.pattern}/ in {subj["name"]} ({subj["sha256"][:16]}): {len(hits)} hits · {label}')
    out.add('searched: ' + ', '.join(f'{k} {n}' for k, n in sorted(kinds.items(), key=lambda x: str(x[0]))) +
            ' (no hit proves nothing beyond these records)')
    if shown:   # names and strings come from the target
        out.untrusted('hits', '\n'.join(line_of(r, rx) for r in shown), 7000)
    if hits:
        out.add('next: show <name|addr> for one record')
    return 0

def line_of(r, rx=None):
    k = r.get('kind')
    if k == 'function':
        s = [x for x in r.get('strings', []) if rx and rx.search(x)][:2]
        return f'function {r["addr"]} {r["name"]} size {r.get("size", 0)} callers {r.get("ncallers", 0)} callees {len(r.get("callees", []))}' + \
            (f' strings {s!r}' if s else '')
    if k == 'string':
        refs = r.get('refs', [])
        return f'string {r.get("addr", "")} {r.get("value", "")[:120]!r} used in {len(refs)}: {", ".join(refs[:5])}'
    where = r.get('addr') or r.get('file') or ''
    return f'{k} {r.get("name", "")} {where}'.rstrip()

# ---- show: one record in full (callers, callees, strings, code), capped at 3k tokens
def show(a, out):
    subj = target_subject(a)
    recs = lib.read_index(subj['sha256'])
    key = a.name.lower()
    rec = None
    if re.match(r'^(0x)?[0-9a-f]{4,16}$', key):   # an address: the function holding it
        addr = int(key, 16)
        best = None
        for r in recs:
            if r.get('kind') == 'function' and r.get('addr'):
                st = int(r['addr'], 16)
                if st <= addr < st + max(1, r.get('size', 1)) and (not best or st > int(best['addr'], 16)):
                    best = r
        rec = best
    if not rec:
        rank = lambda r: (r.get('kind') not in ('function', 'class', 'type', 'module', 'source'), not r.get('file'))   # code first
        exact = sorted((r for r in recs if r.get('name', '').lower() == key), key=rank)
        part = [r for r in recs if key in r.get('name', '').lower() and r.get('kind') != 'string']
        cands = exact or part
        if len(cands) > 1 and not exact:
            out.add(f'reversy show: "{a.name}" matches {len(cands)} records; rerun show with one exact name:')
            out.untrusted('candidates', '\n'.join(line_of(r) for r in cands[:20]), 4000)
            return 1
        rec = (exact or part or [None])[0]
    if not rec:
        out.add(f'reversy show: "{a.name}" not in the index of {subj["name"]} (find <regex> first)')
        return 1
    mod = VERBS.get(rec.get('verb')) or binary
    return mod.show(rec, subj, a, out)

def target_subject(a):
    if a.target:   # becomes the last target: later calls and the full-text file follow it
        subj = lib.subject(a.target)
        lib.set_last(subj, a.verb)
        return subj
    last = lib.get_last()
    if not last:
        raise SystemExit('reversy: no target yet: name one with --target <file>, or run a verb on it first')
    return last

# ---- tools: what is found where (install one on demand)
def tools(a, out):
    if a.install:
        out.add(f'{a.install}: {lib.tool(a.install)}')
        return 0
    out.add(f'reversy tools (folder {lib.TOOLS_DIR}; missing ones install on first need):')
    for name in lib.TOOLS:
        try:
            out.add(f'  {name:13} {lib.tool(name, install=False)}')
        except lib.ToolMissing:
            pat = lib.TOOLS[name][2]
            old = pat and lib.TOOLS[name][3].get('adopt', True) and osp.isdir(lib.LEGACY_DIR) and lib._glob_one(pat, lib.LEGACY_DIR)
            out.add(f'  {name:13} ' + (f'- (in {lib.LEGACY_DIR}: copied on first need)' if old else '-'))
    return 0

# ---- main: parse, same-call check, dispatch, emit
def main(argv):
    ap = argparse.ArgumentParser(prog='reversy.py', description='clean-room reverse engineering (SKILL.md)')
    ap.add_argument('--agent', default=os.environ.get('KIT_AGENT_ID', 'reversy'), help='your RUN-ID: evidence folder')
    ap.add_argument('--page', type=int, default=1)
    ap.add_argument('--again', action='store_true', help='re-run an identical call')
    sp = ap.add_subparsers(dest='verb', required=True)
    for name, mod in VERBS.items():
        mod.add(sp.add_parser(name, help=mod.__doc__.split('\n')[0]))
    f = sp.add_parser('find')
    f.add_argument('pattern')
    f.add_argument('--kind')
    f.add_argument('--target')
    s = sp.add_parser('show')
    s.add_argument('name')
    s.add_argument('--target')
    t = sp.add_parser('tools')
    t.add_argument('--install')
    for p in (f, s, t, *[sp.choices[v] for v in VERBS]):   # global options after the verb too
        p.add_argument('--agent', default=argparse.SUPPRESS)
        p.add_argument('--page', type=int, default=argparse.SUPPRESS)
        p.add_argument('--again', action='store_true', default=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    out = lib.Out(lib.SHOW_TOKENS if a.verb == 'show' else lib.SUMMARY_TOKENS)
    tgt = getattr(a, 'target', None) or (getattr(a, 'path', None) if a.verb not in ('runtime',) else None)
    sha = lib.subject(tgt)['sha256'] if tgt and osp.exists(tgt) else (lib.get_last() or {}).get('sha256', '')
    memo, prior = lib.same_call([x for x in argv if x != '--again'], sha)
    live = a.verb in ('runtime', 'tools') or (a.verb == 'android' and getattr(a, 'path', '') == 'device')   # answers that change: never memoized
    if prior and not a.again and not live:
        print('SAME CALL as before (answer below, not re-run; --again re-runs):')
        print(prior)
        return 0
    try:
        if a.verb == 'find':
            code = find(a, out)
        elif a.verb == 'show':
            code = show(a, out)
        elif a.verb == 'tools':
            code = tools(a, out)
        else:
            code = VERBS[a.verb].run(a, out)
    except lib.ToolMissing as e:
        out.add(f'reversy {a.verb}: {e}')
        code = 1
    except (OSError, ValueError, KeyError, IndexError, TypeError, struct.error, zipfile.BadZipFile, sqlite3.Error, RuntimeError,
            NotImplementedError, RecursionError) as e:   # a malformed target: exit 1 with the reason, never a traceback
        out.add(f'reversy {a.verb}: target unreadable or malformed: {type(e).__name__}: {str(e)[:300]}')
        code = 1
    last = lib.get_last()
    tag = hashlib.sha256(' '.join(argv).encode('utf-8')).hexdigest()[:8]   # one full-text file per distinct call
    full = osp.join(lib.out_dir(a.agent, last['sha256']), f'{a.verb}-{a.page}-{tag}.txt') if last else None
    text = out.emit(full)
    if code == 0 and not live:
        memo, _ = lib.same_call([x for x in argv if x != '--again'], sha)   # keyed on the index as this run left it
        os.makedirs(osp.dirname(memo), exist_ok=True)
        with open(memo, 'w', encoding='utf-8') as fh:
            fh.write(text)
    return code

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
