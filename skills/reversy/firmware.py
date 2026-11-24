"""firmware: images and blobs: signature scan, entropy map, UEFI (UEFIExtract report, ifrextractor); binwalk / unblob need WSL.
Usage: python -X utf8 <kit>/skills/reversy/reversy.py firmware <image> [--wsl]  (then find <regex>)
Limits: 128 MiB read, 256 MiB written, 10k files. --wsl: also runs binwalk (inspect) through WSL when it is installed there.
Exit codes: as reversy.py.
Sections: L13 args · L18 scan · L45 run
"""
import os
import os.path as osp
import shutil

import lib

# ---- args: the verb's options
def add(p):
    p.add_argument('path')
    p.add_argument('--wsl', action='store_true', help='also binwalk through WSL (Linux tools; named fallback otherwise)')

# ---- scan: magic bytes (name, bytes, offset of the magic inside the structure)
SIGS = [('UEFI firmware volume', b'_FVH', 40), ('Intel flash descriptor', b'\x5a\xa5\xf0\x0f', 16), ('gzip', b'\x1f\x8b\x08', 0),
        ('xz', b'\xfd7zXZ\x00', 0), ('zip', b'PK\x03\x04', 0), ('squashfs', b'hsqs', 0), ('squashfs (BE)', b'sqsh', 0),
        ('cramfs', b'\x45\x3d\xcd\x28', 0), ('uImage', b'\x27\x05\x19\x56', 0), ('ELF', b'\x7fELF', 0), ('cpio', b'070701', 0),
        ('UBI', b'UBI#', 0), ('Android boot', b'ANDROID!', 0), ('device tree', b'\xd0\x0d\xfe\xed', 0), ('JFFS2', b'\x85\x19', 0),
        ('7z', b"7z\xbc\xaf'\x1c", 0), ('bzip2', b'BZh91AY', 0), ('lzma', b'\x5d\x00\x00\x80\x00', 0), ('U-Boot', b'U-Boot ', 0)]
READ_CAP, OUT_CAP, FILE_CAP = 128 << 20, 256 << 20, 10000

def scan(b):
    hits = []
    for name, magic, back in SIGS:
        at = b.find(magic)
        while at >= 0 and len(hits) < 2000:
            start = at - back
            if start >= 0 and not (name == 'JFFS2' and start % 4):   # a 2-byte magic: 4-aligned only
                hits.append((start, name))
            at = b.find(magic, at + 1)
    pe = 0
    while (pe := b.find(b'MZ', pe)) >= 0 and len(hits) < 2500:   # a PE counts only with its PE\0\0 header
        import struct
        if pe + 0x40 <= len(b):
            lfa = struct.unpack_from('<I', b, pe + 0x3c)[0]
            if lfa < 0x1000 and b[pe + lfa:pe + lfa + 4] == b'PE\0\0':
                hits.append((pe, 'PE image'))
        pe += 2
    return sorted(set(hits))

# ---- run: signatures, entropy, UEFI tools, the WSL fallback
def run(a, out):
    subj = lib.subject(a.path)
    lib.set_last(subj, 'firmware')
    cache = lib.cache_dir(subj['sha256'])
    with open(a.path, 'rb') as fh:
        b = fh.read(READ_CAP)
    lims = [f'read the first {lib.fmt_size(READ_CAP)} only'] if subj['size'] > READ_CAP else []
    hits = scan(b)
    blk = 1 << 16
    ent = [(i, lib.entropy(b[i:i + blk])) for i in range(0, len(b), blk)]
    high = [i for i, e in ent if e > 7.5]
    out.add(f'reversy firmware: {subj["name"]} · {lib.fmt_size(subj["size"])} · sha256 {subj["sha256"]}')
    counts = {}
    for _, n in hits:
        counts[n] = counts.get(n, 0) + 1
    out.add(f'{len(hits)} signatures: ' + ', '.join(f'{n} {c}' for n, c in sorted(counts.items(), key=lambda x: -x[1])))
    out.add(f'entropy (64 KiB blocks): min {min((e for _, e in ent), default=0):.2f} max {max((e for _, e in ent), default=0):.2f} · '
            f'{len(high)} blocks > 7.5 (compressed or encrypted)' + (f' from {high[0]:#x}' if high else ''))
    out.add('first hits: ' + ' · '.join(f'{o:#x} {n}' for o, n in hits[:40]))
    recs = [{'kind': 'signature', 'verb': 'firmware', 'name': n, 'addr': f'{o:#x}'} for o, n in hits]
    if any(n in ('UEFI firmware volume', 'Intel flash descriptor') for _, n in hits):
        recs += uefi(subj, cache, out, lims)
    if a.wsl:
        wsl = shutil.which('wsl')
        code, txt, _ = lib.run([wsl, '-e', 'binwalk', '--quiet', subj['path'].replace('\\', '/')], timeout=300) if wsl else (127, 'no wsl', False)
        out.add(f'binwalk (WSL) exit {code}')
        out.untrusted('binwalk', txt[:3000], 3000)
    else:
        out.add('carving / extraction (binwalk -e, unblob): needs WSL: rerun with --wsl, or in WSL: binwalk -e <image>')
    lib.write_index(subj['sha256'], 'firmware', recs)
    rid = lib.evidence(a.agent, subj, 'firmware', {'wsl': a.wsl}, {'signatures': len(hits)}, confidence='derived',
                       coverage='partial' if lims else 'complete', limitations=lims + ['magic bytes can match by chance: derived'])
    for l in lims:
        out.add(f'limit: {l}')
    out.add(f'evidence {rid} · next: find <regex> --kind signature|uefi|ifr')
    return 0

def uefi(subj, cache, out, lims):
    """UEFIExtract report + ifrextractor on a copy in the cache (both write next to their input)."""
    work = osp.join(cache, 'uefi')
    os.makedirs(work, exist_ok=True)
    img = osp.join(work, 'image.bin')
    if not osp.exists(img):
        shutil.copyfile(subj['path'], img)
    recs = []
    try:
        ue = lib.tool('uefiextract')
        rep = img + '.report.txt'
        if not osp.exists(rep):
            lib.run([ue, img, 'report'], timeout=600, cwd=work)
        if osp.exists(rep):
            lines = [l for l in open(rep, encoding='utf-8', errors='replace').read().splitlines() if '|' in l]
            names = [l.split('|')[-1].strip() for l in lines]
            out.add(f'UEFIExtract: {len(lines)} tree rows ({rep})')
            out.untrusted('UEFI tree (names)', '\n'.join(n for n in names if n)[:2500], 2500)
            recs += [{'kind': 'uefi', 'verb': 'firmware', 'name': l.strip()[:300]} for l in lines]
        else:
            lims.append('UEFIExtract wrote no report')
    except lib.ToolMissing as e:
        lims.append(str(e))
    try:
        ifr = lib.tool('ifrextractor')
        before = set(os.listdir(work))
        lib.run([ifr, img, 'verbose'], timeout=600, cwd=work)
        made = sorted(set(os.listdir(work)) - before)
        if made:
            out.add(f'ifrextractor: {len(made)} files in {work}: ' + ', '.join(made[:8]))
            recs += [{'kind': 'ifr', 'verb': 'firmware', 'name': m, 'file': osp.join(work, m)} for m in made]
    except lib.ToolMissing as e:
        lims.append(str(e))
    return recs

def show(rec, subj, a, out):
    f = rec.get('file')
    out.add(f'{rec["kind"]} {rec["name"]} {rec.get("addr", "")}')
    if f and osp.exists(f):
        out.untrusted(rec['kind'], open(f, encoding='utf-8', errors='replace').read(), 10000)
    return 0
