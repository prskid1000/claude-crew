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
    return dt.keep_doc(a['title'], out, a['keep'])


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
    finally:
        _browser = saved


def register(module):
    global dt
    dt = module
    dt.ADAPTERS['report']['pdf'] = {'publish': publish, 'selftest': selftest, 'evidence': dt.kept_evidence}
    dt.find_browser = find_browser