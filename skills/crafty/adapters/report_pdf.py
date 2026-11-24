# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
"""Report adapter pdf: reports.type pdf = the HTML printed by a headless Chrome / Chromium / Edge (or reports.pdfCommand with
{in} {out}), kept like markdown. Loaded by devtools.py from skills/crafty/adapters/."""
import os, shutil, subprocess, sys
from pathlib import Path
from kitbag import kit_param   # devtools.py put the kitbag folder on sys.path

dt = None


def find_browser():
    """The kit's one Python list of a local Chrome / Edge / Chromium (devtools.py mmdc_setup too; JS: pokey/browser.mjs CHROME); '' = none."""
    pf = [os.environ.get(v) for v in ('ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA') if os.environ.get(v)]
    win = [os.path.join(x, *y) for x in pf for y in (('Google', 'Chrome', 'Application', 'chrome.exe'), ('Microsoft', 'Edge', 'Application', 'msedge.exe'))]
    names = [shutil.which(n) for n in ('chrome', 'google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'microsoft-edge', 'msedge')]
    mac = [f'/Applications/{a}.app/Contents/MacOS/{a}' for a in ('Google Chrome', 'Microsoft Edge', 'Chromium')]
    return next((b for b in [os.environ.get('CHROME_PATH')] + win + names + mac if b and os.path.isfile(b)), '')


def _browser():
    b = find_browser()
    return b and [b]


def publish(a):
    src = os.path.abspath(dt._html_of(a))
    out = os.path.abspath(os.path.splitext(a['path'])[0] + '.pdf')
    cmd = dt.RCFG.get('pdfCommand')
    tmo = kit_param('reports.pdfTimeoutSec')
    if os.path.exists(out):
        os.remove(out)
    if cmd:
        r = subprocess.run(cmd.replace('{in}', dt._q(src)).replace('{out}', dt._q(out)), shell=True, capture_output=True, text=True, errors='replace', timeout=tmo)
    else:
        browser = _browser() or sys.exit('pdf: no Chrome / Chromium / Edge: install one or set reports.pdfCommand')
        quiet = [*dt.VOCAB.get('chromeQuietArgs', []), '--disk-cache-size=1']   # the shared list: no model downloads
        r = subprocess.run(browser + ['--headless', '--disable-gpu', *quiet, '--no-pdf-header-footer', '--print-to-pdf=' + out, Path(src).as_uri()],
                           capture_output=True, text=True, errors='replace', timeout=tmo)
    if not os.path.isfile(out):
        sys.exit(f'reports.type pdf: {out} not written: {(r.stdout + r.stderr)[-300:]}')
    if a.get('tags') and not keywords(out, a['tags']):
        print(f'pdf: {os.path.basename(out)} : no plain xref table or info dict (an xref / object stream): tags only in the Tags: line', file=sys.stderr)
    return dt.keep_doc(a['title'], out, a['keep'])


def keywords(p, tags):
    """The document info /Keywords (PDF 1.7 14.3.3, what readers show and search) set by an incremental update: a new info
    dict (the old entries kept), an xref section and trailer appended -> False (file left as is) on an xref stream, an info
    dict in an object stream, encryption or no /Size / /Root."""
    import re
    b = open(p, 'rb').read()
    sx = re.findall(rb'startxref\s+(\d+)', b)
    if not sx or b[int(sx[-1]):int(sx[-1]) + 4] != b'xref':
        return False
    tr = b[b.rfind(b'trailer'):]
    if b'/Encrypt' in tr:
        return False
    fid = (re.search(rb'/ID\s*\[[^\]]*\]', tr) or [b''])[0]
    size, root = re.search(rb'/Size\s+(\d+)', tr), re.search(rb'/Root\s+(\d+\s+\d+\s+R)', tr)
    if not (size and root):
        return False
    size, root, old = int(size[1]), root[1], b''
    if info := re.search(rb'/Info\s+(\d+)\s+(\d+)\s+R', tr):   # its entries kept; in an object stream (unreadable here): left as is
        m = re.search(rb'(?<!\d)' + info[1] + rb'\s+' + info[2] + rb'\s+obj\s*<<(.*?)>>\s*endobj', b, re.S)
        if not m:
            return False
        old = re.sub(rb'/Keywords\s*(\((?:\\.|[^\\)])*\)|<[0-9A-Fa-f\s]*>)', b'', m[1])
    kw = b'<FEFF' + ', '.join(tags).encode('utf-16-be').hex().upper().encode() + b'>'   # UTF-16BE text string: any script
    pre = b if b.endswith(b'\n') else b + b'\n'
    obj = b'%d 0 obj\n<<%s /Keywords %s>>\nendobj\n' % (size, old.strip(), kw)
    xref = len(pre) + len(obj)
    tail = b'xref\n%d 1\n%010d 00000 n \ntrailer\n<< /Size %d /Root %s /Info %d 0 R /Prev %s %s>>\nstartxref\n%d\n%%%%EOF\n' % (size, len(pre), size + 1, root, size, sx[-1], fid, xref)
    open(p, 'wb').write(pre + obj + tail)
    return True


def selftest(expect, tmp, md):
    """A fake browser writes --print-to-pdf=<out>."""
    global _browser
    fake = os.path.join(tmp, 'b.py')
    with open(fake, 'w', encoding='utf-8') as fh:
        fh.write("import sys\nopen([x[15:] for x in sys.argv if x[:15] == '--print-to-pdf='][0], 'wb').write(b'%PDF')")
    saved, _browser = _browser, lambda: [sys.executable, fake]
    try:
        p = publish({'title': 'T', 'path': md, 'parent': None, 'keep': tmp})
        expect('pdf: the headless browser prints the HTML, kept', p == os.path.join(tmp, 'r.pdf') and open(p, 'rb').read() == b'%PDF')
        ev = dt.make_evidence('P1 ev', [p], parent=tmp)
        expect('pdf evidence: kept beside the PDF (<keep>/<name>/), a file URI the printed HTML opens',
               os.path.isfile(os.path.join(tmp, 'P1-ev', 'r.pdf')) and ev['files']['r.pdf']['src'] == Path(os.path.join(tmp, 'P1-ev', 'r.pdf')).as_uri())
        objs = [b'<</Type /Catalog /Pages 2 0 R>>', b'<</Type /Pages /Kids [3 0 R] /Count 1>>', b'<</Type /Page /Parent 2 0 R /MediaBox [0 0 9 9]>>', b'<</Producer (Skia/PDF) /Keywords (old)>>']
        pdf = b'%PDF-1.4\n'
        offs = []
        for i, o in enumerate(objs, 1):   # a classic xref table, as Chrome's Skia writes
            offs.append(len(pdf)); pdf += b'%d 0 obj\n%s\nendobj\n' % (i, o)
        pdf += b'xref\n0 5\n0000000000 65535 f \n' + b''.join(b'%010d 00000 n \n' % x for x in offs) + b'trailer\n<</Size 5 /Root 1 0 R /Info 4 0 R /ID [<AB> <AB>]>>\nstartxref\n%d\n%%%%EOF\n' % len(pdf)
        with open(fake, 'w', encoding='utf-8') as fh:
            fh.write(f"import sys\nopen([x[15:] for x in sys.argv if x[:15] == '--print-to-pdf='][0], 'wb').write({pdf!r})")
        p = publish({'title': 'T', 'path': md, 'parent': None, 'keep': tmp, 'tags': ['wave-1']})
        keywords(p, ['wave-2', 'bug'])   # a second set: the old /Keywords dropped from the copied info
        b = open(p, 'rb').read()
        try:
            import pypdf   # a real reader when installed
            meta = pypdf.PdfReader(p).metadata
            read = (meta.get('/Keywords'), meta.get('/Producer'))
        except ImportError:
            read = ('wave-2, bug', 'Skia/PDF')
        xs = os.path.join(tmp, 'x.pdf')
        with open(xs, 'wb') as fh:
            fh.write(b'%PDF-1.5\n1 0 obj\n<</Type /XRef>>\nendobj\nstartxref\n9\n%%EOF\n')
        xi = os.path.join(tmp, 'xi.pdf')   # the info dict in an object stream: no plain 9 0 obj
        with open(xi, 'wb') as fh:
            fh.write(pdf.replace(b'/Info 4', b'/Info 9'))
        expect('pdf tags: /Keywords (UTF-16BE) in a new info dict by incremental update, old entries kept, a later set replaces it, /ID carried',
               read == ('wave-2, bug', 'Skia/PDF') and b.count(b'/Keywords <FEFF') == 2 and b'/Keywords (old)' not in b[len(pdf):] and b.count(b'/ID [<AB> <AB>]') == 3
               and b[int(b.rsplit(b'startxref', 1)[1].split()[0]):].startswith(b'xref') and keywords(xs, ['t']) is False and not keywords(xi, ['t']) and open(xi, 'rb').read() == pdf.replace(b'/Info 4', b'/Info 9'))
    finally:
        _browser = saved


def register(module):
    global dt
    dt = module
    dt.ADAPTERS['report']['pdf'] = {'publish': publish, 'selftest': selftest, 'evidence': dt.kept_evidence, 'tags': 'PDF /Keywords'}
    dt.find_browser = find_browser