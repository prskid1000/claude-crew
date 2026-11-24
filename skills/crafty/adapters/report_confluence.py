# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
"""Report adapter confluence: reports.type confluence = a page via REST. Env CONFLUENCE_URL (wiki base), CONFLUENCE_TOKEN (bearer;
+ CONFLUENCE_EMAIL: basic); reports.space, reports.parent (page id). Readers = the space / parent page permissions.
Sections: L10 rest · L35 publish · L46 evidence · L79 selftest
"""
import base64, json, os, re, sys, time

dt = None

# ---- rest: HTTP, auth and page creation

def _http(method, url, body=None, headers=None):
    import urllib.request, urllib.error
    q = urllib.request.Request(url, body if isinstance(body, bytes) else body and json.dumps(body).encode(), {'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(q, timeout=int((dt.CFG.get('net') or {}).get('timeoutSec') or 60)) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise SystemExit(f'{method} {url}: HTTP {e.code} {e.read()[:300]}')

def _conf():
    """(wiki base, Authorization header) from the env; refused without URL, token or reports.space."""
    base, token, email = (os.environ.get('CONFLUENCE_' + k, '') for k in ('URL', 'TOKEN', 'EMAIL'))
    if not (base and token and dt.RCFG.get('space')):
        raise SystemExit('confluence needs env CONFLUENCE_URL, CONFLUENCE_TOKEN and reports.space')
    return base.rstrip('/'), 'Basic ' + base64.b64encode(f'{email}:{token}'.encode()).decode() if email else 'Bearer ' + token

def _page(base, auth, title, body, parent):
    """A storage-format page under parent -> the REST reply."""
    page = {'type': 'page', 'title': title, 'space': {'key': dt.RCFG['space']}, 'body': {'storage': {'value': body, 'representation': 'storage'}}}
    if parent:
        page['ancestors'] = [{'id': str(parent)}]
    return _http('POST', base + '/rest/api/content', page, {'Authorization': auth})

# ---- publish: the report page (+ the task's tags as labels)
def publish(a):
    base, auth = _conf()
    with open(dt._html_of(a), encoding='utf-8') as fh:   # storage format = XHTML: the body, void tags closed
        body = re.sub(r'<(br|hr|img|meta|input|col)\b([^>]*?)/?>', r'<\1\2/>', re.sub(r'(?is)^.*?<body[^>]*>|</body>.*$', '', fh.read()))
    rep = _page(base, auth, a['title'], body, a['parent'] or dt.RCFG.get('parent')); links = rep.get('_links') or {}
    if a.get('tags') and rep.get('id'):   # page labels = the task's tags (search: label = wave-2)
        _http('POST', f'{base}/rest/api/content/{rep["id"]}/label', [{'prefix': 'global', 'name': t} for t in a['tags']], {'Authorization': auth})
    return links.get('base', base) + links['webui'] if links.get('webui') else sys.exit(f'confluence: no page link in the reply: {links}')


# ---- evidence: files as page attachments
def evidence(a):
    """Evidence files as attachments of one evidence page (a.folder = that page id, reused by key; new: under reports.parent) ->
    {folderId, folderLink, label, files}; REST: developer.atlassian.com/cloud/confluence/rest/v1/api-group-content---attachments/"""
    base, auth = _conf()
    pid, link, out = a.get('folder'), None, {}
    if not pid:
        body, par = '<p>Evidence files: the attachments of this page.</p>', a.get('parent') or dt.RCFG.get('parent')
        try:
            rep = _page(base, auth, a['name'], body, par)
        except SystemExit as e:   # a title is unique per space: a second page of that name gets the time
            if 'HTTP 400' not in str(e):
                raise
            rep = _page(base, auth, f"{a['name']} {time.strftime('%Y-%m-%d %H%M%S')}", body, par)
        lk = rep.get('_links') or {}
        pid = rep.get('id') or sys.exit(f'confluence: evidence page not created: {str(rep)[:300]}')
        link = lk.get('base', base) + lk['webui'] if lk.get('webui') else None
    for p in a['files']:   # a failed upload is left out (the caller warns)
        bd, name = 'kit' + os.urandom(8).hex(), os.path.basename(p)
        qn = name.replace('\\', '\\\\').replace('"', '\\"')   # a quoted multipart filename
        with open(p, 'rb') as fh:
            data = (f'--{bd}\r\nContent-Disposition: form-data; name="file"; filename="{qn}"\r\nContent-Type: application/octet-stream\r\n\r\n').encode() + fh.read() + f'\r\n--{bd}--\r\n'.encode()
        try:   # PUT = create or update: a reused page's same-name file gets a new version
            r = _http('PUT', f'{base}/rest/api/content/{pid}/child/attachment', data, {'Authorization': auth, 'X-Atlassian-Token': 'no-check', 'Content-Type': f'multipart/form-data; boundary={bd}'})
        except SystemExit as e:
            print(f'confluence: {name} not attached: {e}', file=sys.stderr)
            continue
        at = (r.get('results') or [r])[0]; al = at.get('_links') or {}
        if at.get('id'):
            out[name] = {'id': at['id'], 'link': base + al.get('webui', ''), 'src': base + al.get('download', '')}
    return {'folderId': pid, 'folderLink': link, 'label': 'Confluence page', 'files': out}


# ---- selftest: recorded REST replies
def selftest(expect, tmp, md):
    global _http
    calls, saved = [], _http
    env0 = dict(os.environ)
    os.environ.update(CONFLUENCE_URL='https://ex.atlassian.net/wiki/', CONFLUENCE_TOKEN='tk')
    rcfg0, dt.RCFG = dt.RCFG, {'space': 'QA', 'parent': '42'}
    _http = lambda *a, **k: calls.append(a) or {'id': '65601', '_links': {'webui': '/spaces/QA/pages/65601/T', 'base': 'https://ex.atlassian.net/wiki'}}
    try:
        u = publish({'title': 'T', 'path': md, 'parent': None, 'keep': None})
        _, url, b, hd = calls[0]
        expect('confluence: a storage page under reports.parent, bearer auth', u == 'https://ex.atlassian.net/wiki/spaces/QA/pages/65601/T'
               and url.endswith('/wiki/rest/api/content') and b['ancestors'] == [{'id': '42'}] and '<hr/>' in b['body']['storage']['value']
               and hd['Authorization'] == 'Bearer tk')
        calls.clear(); publish({'title': 'T', 'path': md, 'parent': None, 'keep': None, 'tags': ['wave-2']})
        expect('confluence: task tags as page labels', calls[1][1].endswith('/rest/api/content/65601/label') and calls[1][2] == [{'prefix': 'global', 'name': 'wave-2'}])
        calls.clear(); publish({'title': 'T', 'path': dt.sample_run_doc(tmp), 'parent': None, 'keep': None})
        sv = calls[0][2]['body']['storage']['value']
        expect('confluence: an env run fills the human doc row: result with check ids, the screenshot inline (closed img), the JSON excerpt + link',
               re.search(r'>T1</td>.*PASS \(V1, V2\)</td>.*<img [^>]*src="https://img/v1\.png"[^>]*/>.*GET /a -&gt; 200.*href="https://f/v2"', sv, re.S) is not None)
        expect('confluence: a later run\'s NOT TESTED keeps the earlier PASS, both envs and the why in the row',
               re.search(r'>T2</td>.*PASS \(stg V3\) · local: not tested \(T2\) — read-only</td>', sv, re.S) is not None)
        png = os.path.join(tmp, 'c1.png')   # recorded replies (no Confluence account): evidence = a page + its attachments
        with open(png, 'wb') as fh:
            fh.write(b'PNG1')
        calls.clear()
        _http = lambda *a, **k: calls.append(a) or ({'results': [{'id': 'att9', '_links': {'webui': '/pages/viewpageattachments.action?pageId=65601', 'download': '/download/attachments/65601/c1.png'}}]}
                                                    if a[1].endswith('/child/attachment') else {'id': '65601', '_links': {'webui': '/spaces/QA/pages/65601/E', 'base': 'https://ex.atlassian.net/wiki'}})
        ev = evidence({'name': 'T9 evidence', 'files': [png], 'folder': None, 'parent': None})
        up = calls[1]
        calls.clear(); ev2 = evidence({'name': 'T9 evidence', 'files': [png], 'folder': '65601', 'parent': None})
        expect('confluence evidence: one page under reports.parent, each file a multipart attachment (no-check header), its download link; a reused page only attaches',
               ev['folderId'] == '65601' and ev['folderLink'] == 'https://ex.atlassian.net/wiki/spaces/QA/pages/65601/E' and calls[0][1].endswith('/content/65601/child/attachment')
               and calls[0][0] == 'PUT' and len(calls) == 1 and up[3]['X-Atlassian-Token'] == 'no-check' and b'filename="c1.png"' in up[2] and b'PNG1' in up[2]
               and ev['files']['c1.png']['src'] == 'https://ex.atlassian.net/wiki/download/attachments/65601/c1.png' and ev2['folderId'] == '65601')
        q = os.path.join(tmp, 'c2.png')
        open(q, 'wb').close(); calls.clear(); hit = []
        def clash(*a, **k):   # the first page title exists (HTTP 400), the retry carries the time
            calls.append(a)
            if a[1].endswith('/rest/api/content') and not hit:
                hit.append(1); raise SystemExit('POST x: HTTP 400 b\'title exists\'')
            return {'id': '7', '_links': {}} if a[1].endswith('/rest/api/content') else {'results': [{'id': 'a1', '_links': {}}]}
        _http = clash; ev3 = evidence({'name': 'T9 evidence', 'files': [q], 'folder': None, 'parent': None})
        expect('confluence evidence: a page title clash retries once with the time in the title; PUT creates or updates the attachment',
               ev3['folderId'] == '7' and re.match(r'T9 evidence \d{4}-\d\d-\d\d \d{6}$', calls[1][2]['title']) is not None and calls[2][0] == 'PUT')
    finally:
        _http, dt.RCFG = saved, rcfg0
        os.environ.clear(); os.environ.update(env0)


def register(module):
    global dt
    dt = module
    dt.ADAPTERS['report']['confluence'] = {'publish': publish, 'evidence': evidence, 'selftest': selftest, 'tags': 'page labels'}