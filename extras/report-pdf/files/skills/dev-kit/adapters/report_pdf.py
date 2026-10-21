"""Extra report-pdf: reports.type pdf = the HTML printed by a headless Chrome / Chromium / Edge (or reports.pdfCommand with
{in} {out}), kept like markdown. Loaded by devtools.py from skills/dev-kit/adapters/."""
import os, shutil, subprocess, sys
from pathlib import Path

dt = None


def _browser():
    b = next(filter(None, map(shutil.which, ('chrome', 'google-chrome', 'chromium', 'chromium-browser', 'msedge',
        r'C:\Program Files\Google\Chrome\Application\chrome.exe', r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'))), None)
    return b and [b]


def publish(a):
    src = os.path.abspath(dt._html_of(a))
    out = os.path.abspath(os.path.splitext(a['path'])[0] + '.pdf')
    cmd = dt.RCFG.get('pdfCommand')
    if os.path.exists(out):
        os.remove(out)
    if cmd:
        r = subprocess.run(cmd.replace('{in}', dt._q(src)).replace('{out}', dt._q(out)), shell=True, capture_output=True, text=True, errors='replace', timeout=180)
    else:
        browser = _browser() or sys.exit('pdf: no Chrome / Chromium / Edge: install one or set reports.pdfCommand')
        r = subprocess.run(browser + ['--headless', '--disable-gpu', '--no-pdf-header-footer', '--print-to-pdf=' + out, Path(src).as_uri()],
                           capture_output=True, text=True, errors='replace', timeout=180)
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
    finally:
        _browser = saved


def register(module):
    global dt
    dt = module
    dt.ADAPTERS['report']['pdf'] = {'publish': publish, 'selftest': selftest}