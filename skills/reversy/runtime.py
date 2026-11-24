"""runtime: captures and live processes: pcap summaries, a read-only SQLite snapshot, frida in its own process.
Usage: python -X utf8 <kit>/skills/reversy/reversy.py runtime pcap <file> | sqlite <db> [--table t] | procs |
  frida <pid|name> --script <hook.js> [--seconds n]   (browsers: CDP through <kit>/skills/pokey/browser.mjs, not here)
pcap: our reader (pcap + pcapng: endpoints, DNS names, TLS SNI); tshark adds its protocol table when installed.
Exit codes: as reversy.py.
Sections: L16 args · L24 pcap · L113 sqlite · L135 frida · L154 run
"""
import os
import os.path as osp
import shutil
import sqlite3
import struct

import lib

# ---- args: the verb's options
def add(p):
    p.add_argument('op', choices=['pcap', 'sqlite', 'procs', 'frida'])
    p.add_argument('path', nargs='?', help='pcap / db file, or the pid / process name for frida')
    p.add_argument('--table')
    p.add_argument('--script', help='frida hook script')
    p.add_argument('--seconds', type=int, default=10)

# ---- pcap: frames -> IPv4 / IPv6 -> TCP / UDP; DNS queries, TLS ClientHello SNI
def frames(b):
    """(link type, [frame bytes]) of a pcap or pcapng file."""
    if b[:4] in (b'\xd4\xc3\xb2\xa1', b'\x4d\x3c\xb2\xa1'):
        link, = struct.unpack_from('<I', b, 20)
        at, out = 24, []
        while at + 16 <= len(b):
            incl, = struct.unpack_from('<I', b, at + 8)
            out.append(b[at + 16:at + 16 + incl])
            at += 16 + incl
        return link, out
    if b[:4] == b'\x0a\x0d\x0d\x0a':
        at, out, link = 0, [], 1
        while at + 12 <= len(b):
            ty, ln = struct.unpack_from('<II', b, at)
            if ln < 12:
                break
            if ty == 1:
                link, = struct.unpack_from('<H', b, at + 8)
            elif ty == 6:
                cap, = struct.unpack_from('<I', b, at + 20)
                out.append(b[at + 28:at + 28 + cap])
            at += ln
        return link, out
    raise ValueError('not a pcap / pcapng file')

def dns_name(b, at):
    parts = []
    while at < len(b) and b[at] and len(parts) < 64:
        if b[at] & 0xc0:
            break
        parts.append(b[at + 1:at + 1 + b[at]].decode('ascii', 'replace'))
        at += 1 + b[at]
    return '.'.join(parts)

def sni(p):
    """The server name of a TLS ClientHello payload, or None."""
    try:
        if p[0] != 0x16 or p[5] != 1:
            return None
        at = 9 + 2 + 32
        at += 1 + p[at]
        at += 2 + struct.unpack_from('>H', p, at)[0]
        at += 1 + p[at]
        end = at + 2 + struct.unpack_from('>H', p, at)[0]
        at += 2
        while at + 4 <= end:
            et, el = struct.unpack_from('>HH', p, at)
            if et == 0:
                n = struct.unpack_from('>H', p, at + 7)[0]
                return p[at + 9:at + 9 + n].decode('ascii', 'replace')
            at += 4 + el
    except (IndexError, struct.error):
        return None
    return None

def pcap_summary(path):
    b = open(path, 'rb').read(256 << 20)
    link, fr = frames(b)
    conv, dns, snis, protos = {}, set(), set(), {}
    for f in fr:
        ip = f[14:] if link == 1 else f[16:] if link == 113 else f
        if link == 1 and f[12:14] == b'\x81\x00':
            ip = f[18:]
        if not ip:
            continue
        v = ip[0] >> 4
        if v == 4:
            hl, proto, src, dst, pay = (ip[0] & 15) * 4, ip[9], '.'.join(map(str, ip[12:16])), '.'.join(map(str, ip[16:20])), None
            pay = ip[hl:]
        elif v == 6 and len(ip) >= 40:
            proto, src, dst, pay = ip[6], ip[8:24].hex(':'), ip[24:40].hex(':'), ip[40:]
        else:
            continue
        name = {6: 'TCP', 17: 'UDP', 1: 'ICMP', 58: 'ICMPv6'}.get(proto, str(proto))
        protos[name] = protos.get(name, 0) + 1
        if proto in (6, 17) and len(pay) >= 8:
            sp, dp = struct.unpack_from('>HH', pay)
            body = pay[(pay[12] >> 4) * 4:] if proto == 6 and len(pay) >= 20 else pay[8:]
            k = (name, src, dst, dp)
            conv[k] = conv.get(k, 0) + 1
            if proto == 17 and 53 in (sp, dp) and len(body) > 12:
                dns.add(dns_name(body, 12))
            if proto == 6 and body:
                s = sni(body)
                if s:
                    snis.add(s)
    return len(fr), protos, conv, sorted(d for d in dns if d), sorted(snis)

# ---- sqlite: a copied snapshot, read-only, query_only, trusted_schema off, 20 sample rows
def sqlite_summary(path, table, work, out):
    snap = osp.join(work, 'snapshot-' + osp.basename(path))
    shutil.copyfile(path, snap)
    con = sqlite3.connect(f'file:{snap}?mode=ro', uri=True)
    con.execute('PRAGMA query_only = ON')
    con.execute('PRAGMA trusted_schema = OFF')
    tabs = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    out.add(f'{len(tabs)} tables (snapshot {snap}):')
    for t in tabs[:60]:
        cols = [r[1] for r in con.execute(f'PRAGMA table_info("{t.replace(chr(34), "")}")')]
        n = con.execute(f'SELECT COUNT(*) FROM "{t.replace(chr(34), "")}"').fetchone()[0]
        out.add(f'  {t}: {n} rows · {", ".join(cols[:20])}')
    if table:
        if table not in tabs:
            out.add(f'no table {table}')
            return 1
        rows = con.execute(f'SELECT * FROM "{table.replace(chr(34), "")}" LIMIT 20').fetchall()
        out.untrusted(f'{table}: first 20 rows', '\n'.join(repr(r)[:300] for r in rows), 4000)
    con.close()
    return 0

# ---- frida: the CLI in its own process, quiet mode with a timeout
def frida(a, out, work):
    fr = lib.tool('frida')
    if a.op == 'procs':
        ps = osp.join(osp.dirname(fr), 'frida-ps' + lib.EXE)
        code, txt, _ = lib.run([ps], timeout=60)
        out.add(f'frida-ps exit {code}')
        out.untrusted('processes', txt, 5000)
        return code
    if not a.path or not a.script:
        out.add('usage: runtime frida <pid|name> --script <hook.js> [--seconds n]')
        return 2
    tgt = ['-p', a.path] if a.path.isdigit() else ['-n', a.path]
    log = osp.join(work, 'frida.log')
    code, txt, _ = lib.run([fr, *tgt, '-l', a.script, '-q', '-t', str(a.seconds)], timeout=a.seconds + 60, log=log)
    out.add(f'frida exit {code} · {a.seconds} s · log {log} (runtime observation: only what the hook printed)')
    out.untrusted('hook output', txt[-6000:], 6000)
    return 0 if code in (0, 124) else 1

# ---- run: dispatch by op
def run(a, out):
    work = osp.join(lib.kit_path('agents'), a.agent, 'reversy', 'runtime')
    os.makedirs(work, exist_ok=True)
    if a.op in ('procs', 'frida'):
        return frida(a, out, work)
    if not a.path or not osp.exists(a.path):
        out.add(f'usage: runtime {a.op} <file>')
        return 2
    subj = lib.subject(a.path)
    lib.set_last(subj, 'runtime')
    out.add(f'reversy runtime {a.op}: {subj["name"]} · {lib.fmt_size(subj["size"])} · sha256 {subj["sha256"][:16]}')
    if a.op == 'sqlite':
        code = sqlite_summary(a.path, a.table, work, out)
        lib.evidence(a.agent, subj, 'runtime sqlite', {'table': a.table}, {'code': code})
        return code
    n, protos, conv, dns, snis = pcap_summary(a.path)
    out.add(f'{n} frames · ' + ', '.join(f'{k} {v}' for k, v in sorted(protos.items(), key=lambda x: -x[1])))
    top = sorted(conv.items(), key=lambda x: -x[1])[:25]
    out.add('top flows (proto src -> dst:port frames): ' + ' · '.join(f'{p} {s} -> {d}:{dp} {c}' for (p, s, d, dp), c in top))
    out.untrusted('DNS names and TLS SNI', '\n'.join([f'dns {d}' for d in dns[:60]] + [f'sni {s}' for s in snis[:60]]), 3000)
    ts = shutil.which('tshark')
    if ts:
        code, txt, _ = lib.run([ts, '-r', a.path, '-q', '-z', 'io,phs'], timeout=120)
        out.add('tshark protocol table:\n' + txt[:2000])
    lib.write_index(subj['sha256'], 'runtime', [{'kind': 'dns', 'verb': 'runtime', 'name': d} for d in dns] +
                    [{'kind': 'sni', 'verb': 'runtime', 'name': s} for s in snis] +
                    [{'kind': 'flow', 'verb': 'runtime', 'name': f'{p} {s} -> {d}:{dp}', 'value': str(c)} for (p, s, d, dp), c in conv.items()])
    rid = lib.evidence(a.agent, subj, 'runtime pcap', {}, {'frames': n, 'dns': len(dns), 'sni': len(snis)})
    out.add(f'evidence {rid} (observed in the capture) · next: find <regex> --kind dns|sni|flow')
    return 0

def show(rec, subj, a, out):
    out.add(f'{rec["kind"]} {rec["name"]} {rec.get("value", "")}')
    return 0
