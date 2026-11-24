"""android: APK / XAPK / APKS: entries, manifest (apktool), classes (jadx CLI), Flutter / Dart / React Native / Unity hints; device verbs.
Usage: python -X utf8 <kit>/skills/reversy/reversy.py android <apk> [--quick]  (then find / show <class>)
  reversy.py android device packages [regex] | pull <package> | logcat [lines] | screencap | props   (ANDROID_SERIAL = your phoney lease)
Safe unzip: budget max(256 MiB, 500 x compressed), path rules, O_EXCL (lib.py). Exit codes: as reversy.py.
Sections: L15 args · L22 flutter · L53 run · L171 device · L225 show
"""
import os
import os.path as osp
import re
import xml.etree.ElementTree as ET
import zipfile

import lib

# ---- args: the verb's options
def add(p):
    p.add_argument('path', help='an .apk / .xapk / .apks, or "device"')
    p.add_argument('op', nargs='?', help='device: packages | pull | logcat | screencap | props')
    p.add_argument('arg', nargs='?')
    p.add_argument('--quick', action='store_true', help='entries and native hints only, no apktool / jadx')

# ---- flutter: snapshot hash (one F5F5DCDC candidate), Dart AOT strings near _kDartIsolateSnapshotData
def flutter_hash(b):
    """(hash or None, candidates): the 32 hex chars 20 bytes after the snapshot magic; counts only when exactly one."""
    cands = []
    for m in re.finditer(rb'\xf5\xf5\xdc\xdc', b):
        h = b[m.start() + 20:m.start() + 52]
        if re.fullmatch(rb'[0-9a-f]{32}', h):
            cands.append(h.decode())
    uniq = sorted(set(cands))
    return (uniq[0] if len(uniq) == 1 else None), uniq

def dart_strings(b):
    """(package/dart URIs <= 500, class-like tokens <= 2000) from the isolate snapshot data (whole file when no symbol)."""
    import binary
    secs = binary.elf_sections(b)
    syms = binary.elf_symbols(b, secs) if secs else {}
    region = b
    if '_kDartIsolateSnapshotData' in syms:
        val, size = syms['_kDartIsolateSnapshotData']
        off = binary.elf_off(secs, val)
        if off is not None:
            region = b[off:off + (size or 64 << 20)]
    uris, classes = [], []
    for _, s in lib.printable_runs(region, 5, 200000):
        for u in re.findall(r'(?:package|dart):[\w./-]+', s):
            if len(uris) < 500 and u not in uris:
                uris.append(u)
        if re.fullmatch(r'_?[A-Z][A-Za-z0-9]{3,40}', s) and len(classes) < 2000:
            classes.append(s)
    return uris, classes

# ---- run: entries + hints, then apktool manifest and jadx classes into the index
def run(a, out):
    if a.path == 'device':
        return device(a, out)
    subj = lib.subject(a.path)
    lib.set_last(subj, 'android')
    cache = lib.cache_dir(subj['sha256'])
    with zipfile.ZipFile(a.path) as z:
        names = z.namelist()
        inner = [n for n in names if n.endswith('.apk')]
    out.add(f'reversy android: {subj["name"]} · {lib.fmt_size(subj["size"])} · sha256 {subj["sha256"]} · {len(names)} entries')
    apks = [a.path]
    if inner:   # xapk / apks: unzip the split apks safely, read the base one
        res = lib.safe_unzip(a.path, osp.join(cache, 'splits'), only=lambda n: n.endswith('.apk')) if not osp.isdir(osp.join(cache, 'splits')) else None
        apks = [osp.join(cache, 'splits', *lib.safe_name(n).split('/')) for n in inner if lib.safe_name(n)]
        out.add(f'bundle of {len(inner)} split APKs: {", ".join(inner[:8])}' + (f' · refused {res["refused"][:3]}' if res and res['refused'] else ''))
    base = next((p for p in apks if re.search(r'base|^(?!.*config\.)', osp.basename(p))), apks[0])
    with zipfile.ZipFile(base) as z:
        ents = z.namelist()
        dex = [n for n in ents if re.fullmatch(r'classes\d*\.dex', n)]
        libs = sorted({n for n in ents if n.startswith('lib/')})
        abis = sorted({n.split('/')[1] for n in libs if n.count('/') >= 2})
        hints = []
        if any(n.endswith('libflutter.so') for n in libs):
            hints.append('Flutter')
        if 'assets/index.android.bundle' in ents:
            hints.append('React Native (assets/index.android.bundle: run `web` on it)')
        if any(n.endswith('libil2cpp.so') for n in libs):
            hints.append('Unity IL2CPP (global-metadata.dat)')
        if any(n.endswith(('.dll', 'libmonodroid.so')) or 'assemblies/' in n for n in ents):
            hints.append('Xamarin / .NET MAUI (assemblies: `managed`)')
        if any(n.startswith('assets/www/') or n.startswith('assets/public/') for n in ents):
            hints.append('Cordova / Capacitor web assets (`web`)')
        signers = [n for n in ents if re.match(r'META-INF/.*\.(RSA|DSA|EC)$', n)]
        out.add(f'{len(dex)} dex · ABIs {", ".join(abis) or "none"} · {len(libs)} native libs · signer files {len(signers)}' +
                (f' · {"; ".join(hints)}' if hints else ''))
        lib_app = next((n for n in libs if n.endswith('/libapp.so')), None)
        recs = [{'kind': 'entry', 'verb': 'android', 'name': n} for n in ents[:20000]]
        if lib_app:
            data = z.read(lib_app)
            h, c = flutter_hash(data)
            uris, classes = dart_strings(data)
            out.add(f'Flutter snapshot hash {h or "unknown"} ({len(c)} candidates) · {len(uris)} Dart URIs · {len(classes)} class-like tokens ({lib_app})')
            pk = sorted({u.split('/')[0] for u in uris if u.startswith('package:')})
            if pk:
                out.untrusted('Dart packages', '\n'.join(pk[:40]))
            recs += [{'kind': 'dart', 'verb': 'android', 'name': u} for u in uris] + [{'kind': 'dart-class', 'verb': 'android', 'name': x} for x in classes]
    lims = []
    if not a.quick:
        recs += manifest(base, cache, out, lims)
        recs += classes_jadx(base, cache, out, lims)
    lib.write_index(subj['sha256'], 'android', recs)
    rid = lib.evidence(a.agent, subj, 'android', {'quick': a.quick}, {'dex': len(dex), 'hints': hints, 'records': len(recs)},
                       coverage='partial' if lims or a.quick else 'complete', limitations=lims)
    for l in lims:
        out.add(f'limit: {l}')
    out.add(f'evidence {rid} · next: find <regex> --kind class|component|permission|entry · show <class>')
    return 0

def manifest(apk, cache, out, lims):
    ws = osp.join(cache, 'apktool')
    mf = osp.join(ws, 'AndroidManifest.xml')
    if not osp.exists(mf):
        try:
            code, txt, _ = lib.run([lib.tool('java'), '-jar', lib.tool('apktool'), 'd', '--no-src', '-f', '-o', ws, '--frame-path',
                                    osp.join(cache, 'apktool-fw'), apk], timeout=600)
        except lib.ToolMissing as e:
            lims.append(str(e))
            return []
        if not osp.exists(mf):
            lims.append(f'apktool exit {code}: {txt[-300:]}')
            return []
    ns = '{http://schemas.android.com/apk/res/android}'
    root = ET.parse(mf).getroot()
    pkg = root.get('package', '?')
    perms = [e.get(ns + 'name') for e in root.iter('uses-permission')]
    comps = []
    for tag in ('activity', 'activity-alias', 'service', 'receiver', 'provider'):
        for e in root.iter(tag):
            exp = e.get(ns + 'exported')
            filt = [d.get(ns + 'scheme') for d in e.iter('data') if d.get(ns + 'scheme')]
            comps.append((tag, e.get(ns + 'name'), exp == 'true' or (exp is None and e.find('intent-filter') is not None), filt))
    yml = osp.join(ws, 'apktool.yml')   # apktool keeps version and sdk here, not in the manifest
    y = open(yml, encoding='utf-8', errors='replace').read() if osp.exists(yml) else ''
    yv = lambda k: (re.search(rf"{k}: '?([^'\n]*)", y) or [None, '?'])[1]
    out.add(f'manifest: package {pkg} · version {root.get(ns + "versionName") or yv("versionName")} ({root.get(ns + "versionCode") or yv("versionCode")})'
            f' · sdk {yv("minSdkVersion")}-{yv("targetSdkVersion")}' +
            f' · {len(perms)} permissions · {len(comps)} components ({sum(1 for c in comps if c[2])} exported)')
    out.untrusted('permissions and exported components', '\n'.join(perms[:30] + [f'{t} {n}{" schemes " + ",".join(f) if f else ""}'
                                                                              for t, n, e, f in comps if e][:30]))
    return [{'kind': 'permission', 'verb': 'android', 'name': p} for p in perms] + \
           [{'kind': 'component', 'verb': 'android', 'name': n, 'value': f'{t}{" exported" if e else ""}'} for t, n, e, f in comps]

def classes_jadx(apk, cache, out, lims):
    src = osp.join(cache, 'jadx')
    if not osp.isdir(osp.join(src, 'sources')):
        try:
            code, txt, _ = lib.run([lib.tool('jadx'), '-d', src, '--no-res', apk], timeout=1800, log=osp.join(cache, 'jadx.log'))
        except lib.ToolMissing as e:
            lims.append(str(e))
            return []
        if not osp.isdir(osp.join(src, 'sources')):
            lims.append(f'jadx exit {code}: {txt[-300:]}')
            return []
    recs, pk = [], {}
    root = osp.join(src, 'sources')
    for d, _, files in os.walk(root):
        for f in files:
            if f.endswith('.java'):
                rel = osp.relpath(osp.join(d, f), root).replace('\\', '/')
                name = rel[:-5].replace('/', '.')
                recs.append({'kind': 'class', 'verb': 'android', 'name': name, 'file': osp.join(d, f)})
                top = '.'.join(name.split('.')[:3])
                pk[top] = pk.get(top, 0) + 1
    out.add(f'jadx: {len(recs)} classes')
    out.untrusted('top packages (classes)', ', '.join(f'{k} {v}' for k, v in sorted(pk.items(), key=lambda x: -x[1])[:15]), 1500)
    return recs

# ---- device: the adb verb set on your leased phone only (ANDROID_SERIAL)
PROPS = ('ro.product.manufacturer', 'ro.product.brand', 'ro.product.model', 'ro.product.device', 'ro.build.version.release',
         'ro.build.version.sdk', 'ro.build.version.security_patch', 'ro.build.fingerprint', 'ro.build.type', 'ro.product.cpu.abi',
         'ro.product.cpu.abilist', 'ro.debuggable', 'ro.secure')

def device(a, out):
    serial = os.environ.get('ANDROID_SERIAL')
    if not serial:
        out.add('reversy android device: set ANDROID_SERIAL to the phone your phoney.ps1 acquire lease gave you (never another one)')
        return 2
    adb = lib.tool('adb')
    sh = lambda *c, t=60: lib.run([adb, '-s', serial, *c], timeout=t)
    op = a.op or 'packages'
    work = osp.join(lib.kit_path('agents'), a.agent, 'reversy', 'device')
    os.makedirs(work, exist_ok=True)
    if op == 'packages':
        code, txt, _ = sh('shell', 'pm', 'list', 'packages', '-f')
        rows = [l[8:] for l in txt.splitlines() if l.startswith('package:') and (not a.arg or re.search(a.arg, l, re.I))]
        out.add(f'{len(rows)} packages on {serial}' + (f' matching /{a.arg}/' if a.arg else ''))
        out.add('\n'.join(rows[:150]))
    elif op == 'pull':
        if not a.arg:
            out.add('usage: android device pull <package>')
            return 2
        code, txt, _ = sh('shell', 'pm', 'path', a.arg)
        paths = [l[8:].strip() for l in txt.splitlines() if l.startswith('package:')]
        dest = osp.join(work, re.sub(r'[^\w.-]', '_', a.arg))
        os.makedirs(dest, exist_ok=True)
        for p in paths:
            local = osp.join(dest, osp.basename(p))
            sh('pull', p, local, t=600)
            _, rs, _ = sh('shell', 'sha256sum', p)
            same = osp.exists(local) and rs.split()[0:1] == [lib.sha256_file(local)]
            out.add(f'{p} -> {local} · sha256 {"match" if same else "MISMATCH or unread"}')
        out.add(f'next: android {osp.join(dest, "base.apk")}')
    elif op == 'logcat':
        n = int(a.arg or 500)
        code, txt, _ = sh('logcat', '-d', '-b', 'main', '-t', str(min(n, 5000)))
        p = osp.join(work, 'logcat.txt')
        open(p, 'w', encoding='utf-8').write(txt)
        out.untrusted(f'logcat last {n} lines (full {p})', txt[-5000:], 5000)
    elif op == 'screencap':
        p = osp.join(work, 'screen.png')
        code, _, _ = lib.run([adb, '-s', serial, 'exec-out', 'screencap', '-p'], log=p, cap=1)
        out.add(f'screen: {p} ({lib.fmt_size(osp.getsize(p))}); read it with the Read tool')
    elif op == 'props':
        for k in PROPS:
            _, v, _ = sh('shell', 'getprop', k)
            out.add(f'{k}={v.strip()}')
    else:
        out.add(f'unknown device op {op}: packages | pull | logcat | screencap | props')
        return 2
    return 0

# ---- show: one class's Java (jadx, derived) or a record
def show(rec, subj, a, out):
    if rec.get('file') and osp.exists(rec['file']):
        out.add(f'{rec["kind"]} {rec["name"]} (jadx Java, derived) {rec["file"]}')
        out.untrusted('decompiled Java', open(rec['file'], encoding='utf-8', errors='replace').read(), 10000)
    else:
        out.add(f'{rec["kind"]} {rec["name"]} {rec.get("value", "")}')
    return 0
