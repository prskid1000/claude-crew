# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
"""Report adapter notion: reports.type notion = a child page of reports.parent via REST (env NOTION_TOKEN): heading, paragraph,
bulleted, table and code blocks, 100 per call; evidence = files uploaded to one child page. Readers = the parent page's sharing.
Sections: L11 rest · L26 blocks · L87 evidence
"""
import html, json, mimetypes, os, re, sys

dt = None
API = 'https://api.notion.com/v1/'

# ---- rest: JSON or multipart calls, text runs
def _http(method, url, body=None, headers=None):
    import urllib.request, urllib.error
    data = body if isinstance(body, bytes) else body and json.dumps(body).encode()   # bytes: a multipart upload
    q = urllib.request.Request(url, data, {'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(q, timeout=int((dt.CFG.get('net') or {}).get('timeoutSec') or 60)) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise SystemExit(f'{method} {url}: HTTP {e.code} {e.read()[:300]}')

def _rich(s):
    return [{'type': 'text', 'text': {'content': s[i:i + 2000]}} for i in range(0, len(s), 2000)]


# ---- blocks: Markdown -> Notion blocks, the page publish
_RULE = re.compile(r'^\s*\|(\s*:?-+:?\s*\|)+\s*$')


def _cells(line):
    return [c.strip().replace('\\|', '|').replace('<br>', '\n') for c in re.split(r'(?<!\\)\|', line.strip()[1:-1])]


def _blocks(text):
    blocks, code, lines, i = [], None, text.splitlines() + ['```'], -1   # the added fence closes an open code block
    while i + 1 < len(lines):
        i += 1
        line = lines[i]
        if code is None and re.match(r'^\s*\|.*\|\s*$', line) and i + 1 < len(lines) and _RULE.match(lines[i + 1]):   # a table block
            rows = [_cells(line)]
            i += 1
            while i + 1 < len(lines) and re.match(r'^\s*\|.*\|\s*$', lines[i + 1]):
                i += 1
                rows.append(_cells(lines[i]))
            w = len(rows[0])
            blocks.append({'type': 'table', 'table': {'table_width': w, 'has_column_header': True, 'has_row_header': False, 'children': [
                {'type': 'table_row', 'table_row': {'cells': [_rich(c) for c in (r + [''] * w)[:w]]}} for r in rows]}})
        elif line.strip().startswith('```'):
            if code:
                blocks.append({'type': 'code', 'code': {'language': 'plain text', 'rich_text': _rich('\n'.join(code))}})
            code = [] if code is None else None
        elif code is not None:
            code.append(line)
        elif line.strip() and not re.match(r'^\s*(\|[\s:|-]+\|?|([-*_])(\s*\2){2,})\s*$', line):   # table rules and <hr> dropped
            head, bullet = re.match(r'(#{1,6})\s+(.*)', line), re.match(r'\s*(?:[-*+]|\d+[.)])\s+(.*)', line)
            kind, s = (f'heading_{min(3, len(head[1]))}', head[2]) if head else ('bulleted_list_item', bullet[1]) if bullet else ('paragraph', line)
            blocks.append({'type': kind, kind: {'rich_text': _rich(s)}})
    return blocks


def _auth(parent, need_parent=True):
    token = os.environ.get('NOTION_TOKEN')
    if not token or (need_parent and not parent):
        raise SystemExit('notion needs env NOTION_TOKEN and reports.parent (a page shared with the integration)')
    return {'Authorization': 'Bearer ' + token, 'Notion-Version': '2022-06-28'}


def _page(parent, title, children, headers):
    page = _http('POST', API + 'pages', {'parent': {'page_id': parent}, 'properties': {'title': {'title': [{'text': {'content': title}}]}}, 'children': children}, headers)
    return page if page.get('id') else sys.exit(f'notion: no page in the reply: {str(page)[:300]}')


def publish(a):
    parent = a['parent'] or dt.RCFG.get('parent')
    headers = _auth(parent)
    with open(a['path'], encoding='utf-8') as fh:
        text = fh.read()
    if not a['path'].lower().endswith(('.md', '.markdown')):   # HTML: its text lines
        text = html.unescape(re.sub(r'<[^>]+>', '\n', re.sub(r'(?is)<(head|style|script)\b.*?</\1>', '', text)))
    blocks = _blocks(text)
    page = _page(parent, a['title'], blocks[:100], headers)
    for i in range(100, len(blocks), 100):
        _http('PATCH', f"{API}blocks/{page['id']}/children", {'children': blocks[i:i + 100]}, headers)
    return page.get('url') or 'https://www.notion.so/' + page['id'].replace('-', '')


# ---- evidence: File Upload API (developers.notion.com/docs/uploading-small-files): create, send, attach as an image / file block
def evidence(a):
    """Evidence files as image / file blocks of one evidence page (a.folder = that page id, reused by key; new: under reports.parent)
    -> {folderId, folderLink, label, files}; a file over 20 MB (single-part limit) or a failed upload is left out (the caller warns)."""
    pid, parent = a.get('folder'), a.get('parent') or dt.RCFG.get('parent')
    headers = _auth(parent, not pid)
    pid = pid or _page(parent, a['name'], [], headers)['id']
    web, out = 'https://www.notion.so/' + pid.replace('-', ''), {}
    for p in a['files']:
        name = os.path.basename(p)
        ct = mimetypes.guess_type(name)[0] or 'application/octet-stream'
        try:
            if os.path.getsize(p) > 20 * 1024 * 1024:
                raise SystemExit('over 20 MB (single-part upload limit)')
            fu = _http('POST', API + 'file_uploads', {'filename': name, 'content_type': ct}, headers)
            fu.get('id') or sys.exit(f'no file upload in the reply: {str(fu)[:200]}')
            bd, qn = 'kit' + os.urandom(8).hex(), name.replace('\\', '\\\\').replace('"', '\\"')
            with open(p, 'rb') as fh:
                data = f'--{bd}\r\nContent-Disposition: form-data; name="file"; filename="{qn}"\r\nContent-Type: {ct}\r\n\r\n'.encode() + fh.read() + f'\r\n--{bd}--\r\n'.encode()
            _http('POST', fu.get('upload_url') or f"{API}file_uploads/{fu['id']}/send", data, {**headers, 'Content-Type': f'multipart/form-data; boundary={bd}'})
            kind = 'image' if ct.startswith('image/') else 'file'
            r = _http('PATCH', f'{API}blocks/{pid}/children', {'children': [{'type': kind, kind: {'type': 'file_upload', 'file_upload': {'id': fu['id']}}}]}, headers)
        except (SystemExit, OSError) as e:
            print(f'notion: {name} not uploaded: {e}', file=sys.stderr)
            continue
        bid = ((r.get('results') or [{}])[0].get('id') or '').replace('-', '')
        # the block link, no 'src': Notion file URLs are signed and expire within an hour (a spec diagram falls back to its source)
        out[name] = {'id': bid or fu['id'], 'link': web + (f'#{bid}' if bid else '')}
    return {'folderId': pid, 'folderLink': web, 'label': 'Notion page', 'files': out}


def selftest(expect, tmp, md):
    global _http
    calls, saved, env0 = [], _http, dict(os.environ)
    page = {'object': 'page', 'id': '59833787-2cf9-4fdf-8782-e53db20768a5', 'url': 'https://www.notion.so/T-598337872cf94fdf8782e53db20768a5'}
    os.environ['NOTION_TOKEN'] = 'secret_x'
    _http = lambda *a, **k: calls.append(a) or (page if a[0] == 'POST' else {'object': 'list', 'results': []})
    try:
        u = publish({'title': 'T', 'path': md, 'parent': 'p1', 'keep': None})
        first, second = (c[2]['children'] for c in calls)
        expect('notion: blocks 100 per call', u == page['url'] and (len(first), len(second), first[0]['type'], second[-1]['type']) == (100, 53, 'heading_1', 'code'))
        tb = _blocks('| A | B |\n|---|---|\n| x \\| y | 1<br>2 |\n| z |\nafter')
        expect('notion: a Markdown table = one table block (header row, cells padded, <br> -> line break)', [b['type'] for b in tb] == ['table', 'paragraph']
               and tb[0]['table']['table_width'] == 2 and [[c[0]['text']['content'] if c else '' for c in r['table_row']['cells']] for r in tb[0]['table']['children']] == [['A', 'B'], ['x | y', '1\n2'], ['z', '']])
        rb = next(b for b in _blocks(open(dt.sample_run_doc(tmp), encoding='utf-8').read()) if b['type'] == 'table')
        row = [c[0]['text']['content'] if c else '' for c in rb['table']['children'][1]['table_row']['cells']]
        expect('notion: an env run fills the human doc row: result with check ids, each check\'s evidence (image link, JSON excerpt + link) on its own line',
               row[0] == 'T1' and row[3] == 'PASS (V1, V2)' and 'https://img/v1.png' in row[4] and 'GET /a -> 200' in row[4] and 'https://f/v2' in row[4] and '\n' in row[4])
        r2 = [c[0]['text']['content'] if c else '' for c in rb['table']['children'][2]['table_row']['cells']]
        expect('notion: a later run\'s NOT TESTED keeps the earlier PASS, both envs and the why in the row',
               r2[0] == 'T2' and r2[3] == 'PASS (stg V3) · local: not tested (T2) — read-only' and 'GET /b -> 200' in r2[4] and 'read-only' in r2[4])
        png, ev_calls = os.path.join(tmp, 'n1.png'), []   # recorded replies (no Notion account): page, file upload, send, attach
        with open(png, 'wb') as fh:
            fh.write(b'PNG1')
        fid = '43833259-72ae-404e-8441-b6577f3159b4'
        _http = lambda *a, **k: ev_calls.append(a) or (
            {'id': fid, 'upload_url': f'https://api.notion.com/v1/file_uploads/{fid}/send'} if a[1].endswith('/file_uploads')
            else {'id': fid, 'status': 'uploaded'} if a[1].endswith('/send')
            else {'results': [{'id': 'b10c0000-0000-0000-0000-000000000001'}]} if a[0] == 'PATCH' else page)
        ev = dt.make_evidence('T9 evidence', [png], parent='p1')
        ev_calls.clear(); ev2 = dt.make_evidence('T9 evidence', [png], folder=page['id'])
        pg = 'https://www.notion.so/598337872cf94fdf8782e53db20768a5'
        att = ev_calls[2][2]['children'][0]
        expect('notion evidence: one page under reports.parent, each file uploaded (create, multipart send) and attached as an image block; a reused page only uploads',
               ev['folderId'] == page['id'] and ev['files']['n1.png']['link'] == pg + '#b10c0000000000000000000000000001' and ev['folderLink'] == pg
               and [c[0] + ' ' + c[1].rsplit('/', 1)[-1] for c in ev_calls] == ['POST file_uploads', 'POST send', 'PATCH children']
               and ev_calls[0][2] == {'filename': 'n1.png', 'content_type': 'image/png'} and b'filename="n1.png"' in ev_calls[1][2] and b'PNG1' in ev_calls[1][2]
               and ev_calls[1][3]['Content-Type'].startswith('multipart/form-data; boundary=') and att == {'type': 'image', 'image': {'type': 'file_upload', 'file_upload': {'id': fid}}}
               and ev2['folderId'] == page['id'] and 'src' not in ev['files']['n1.png'])
    finally:
        _http = saved
        os.environ.clear(); os.environ.update(env0)


def register(module):
    global dt
    dt = module
    dt.ADAPTERS['report']['notion'] = {'publish': publish, 'evidence': evidence, 'selftest': selftest}