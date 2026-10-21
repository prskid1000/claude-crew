"""Extra report-gdocs: reports.type gdocs = a Google Doc through the gws CLI (Markdown converted to HTML first), shared per
reports.share (anyone (default) | domain:<domain> | none); evidence = a Drive folder (reports.driveParent / driveParent), one
image src per file. Loaded by devtools.py from skills/dev-kit/adapters/."""
import json, os, sys

dt = None   # devtools.py, set by register


def gws(*args, params=None, body=None, upload=None):
    if not dt.GWS:
        raise SystemExit('reports.type is gdocs but the gws CLI is not on PATH (or set "reports": {"type": "markdown"})')
    cmd = [dt.GWS, *args] + (['--params', json.dumps(params)] if params is not None else []) + (['--json', json.dumps(body)] if body is not None else [])
    # gws uploads only cwd files
    return dt._json(dt._run(cmd + ['--upload', os.path.basename(upload)] if upload else cmd, cwd=upload and os.path.dirname(os.path.abspath(upload))))


def _share(fid, what, warn=False):
    s = str(dt.RCFG.get('share') or 'anyone')   # anyone | domain:<domain> | none
    p = s != 'none' and gws('drive', 'permissions', 'create', params={'fileId': fid, 'supportsAllDrives': True},
                body={'type': 'domain', 'role': 'reader', 'domain': s[7:]} if s[:7] == 'domain:' else {'type': 'anyone', 'role': 'reader'})
    if p is not False and not (isinstance(p, dict) and p.get('id')):
        m = f'{what} was uploaded but not shared ({s}): {str(p)[:300]} - share it by hand or fix gws auth'
        if not warn:
            raise SystemExit(m)
        print('warning: ' + m, file=sys.stderr)


def _create(name, mime, parent, upload=None):
    b = {'name': name, **({'mimeType': mime} if mime else {}), **({'parents': [parent]} if parent else {})}
    return gws('drive', 'files', 'create', params={'supportsAllDrives': True, 'fields': 'id,webViewLink'}, body=b, upload=upload)


def publish(a):
    r = _create(a['title'], 'application/vnd.google-apps.document', a.get('parent') or dt.CFG.get('driveParent'), dt._html_of(a))
    if 'id' not in r:
        raise SystemExit(f'gws upload failed: {r}')
    url = f"https://docs.google.com/document/d/{r['id']}/edit"
    _share(r['id'], url)
    return url


def evidence(a):
    fid, link, out = a.get('folder'), None, {}
    if not fid:
        f = _create(a['name'], 'application/vnd.google-apps.folder', a.get('parent') or dt.CFG.get('driveParent'))
        fid, link = f.get('id') or sys.exit(f'gws: evidence folder not created: {str(f)[:300]}'), f.get('webViewLink')
        _share(fid, link, warn=True)
    for p in a['files']:   # a failed upload is left out (the caller warns)
        r = _create(os.path.basename(p), None, fid, p)
        if r.get('id'):
            out[os.path.basename(p)] = {'id': r['id'], 'link': r.get('webViewLink'), 'src': 'https://drive.google.com/uc?export=view&id=' + r['id']}
    return {'folderId': fid, 'folderLink': link, 'label': 'Drive folder', 'files': out}


def selftest(expect, tmp, md):
    """On recorded gws replies (no network); devtools.py selftest calls it with reports.type gdocs set."""
    global gws
    calls, real, gws0 = [], dt.GWS, gws
    png = os.path.join(tmp, 'g.png')
    open(png, 'wb').close()
    FILE = {'kind': 'drive#file', 'id': '1AbC', 'webViewLink': 'https://docs.google.com/document/d/1AbC/edit?usp=drivesdk'}

    def use(rcfg, reply=lambda a: {'kind': 'drive#permission', 'id': 'anyoneWithLink'} if 'permissions' in a else FILE):
        global gws
        calls.clear()
        dt.RCFG = rcfg
        gws = lambda *a, **k: calls.append((a, k)) or reply(a)
        return lambda: [k['body'] for a, k in calls if 'permissions' in a]
    try:
        dt.GWS = 'gws'
        perms = use({}); u = dt.make_doc('T', md); anyone = perms()
        perms = use({'share': 'domain:ex.com'}); dt.make_doc('T', md); domain = perms()
        perms = use({'share': 'none'}); dt.make_doc('T', md)
        expect('gdocs: Markdown as HTML; share anyone (default) / domain:<d> / none', u == 'https://docs.google.com/document/d/1AbC/edit'
           and calls[0][1]['upload'].endswith('r.doc.html') and anyone == [{'type': 'anyone', 'role': 'reader'}] and domain[0]['domain'] == 'ex.com' and not perms())
        use({}, lambda a: FILE if 'files' in a else {'error': 'insufficient permissions'})
        try:
            dt.make_doc('t', md); expect('gdocs: an unshared doc is refused', False)
        except SystemExit as e:
            expect('gdocs: an unshared doc is refused', 'not shared' in str(e))
        use({}); ev = dt.make_evidence('ev', [png])
        expect('gdocs evidence: a Drive folder, an image src per file', calls[0][1]['body']['mimeType'].endswith('folder') and ev['files']['g.png']['src'].endswith('id=1AbC'))
    finally:
        dt.GWS, gws = real, gws0


def register(d):
    global dt
    dt = d
    d.ADAPTERS['report']['gdocs'] = {'publish': publish, 'evidence': evidence, 'selftest': selftest}
