"""Goody report-confluence: reports.type confluence = a page via REST. Env CONFLUENCE_URL (wiki base), CONFLUENCE_TOKEN (bearer;
+ CONFLUENCE_EMAIL: basic); reports.space, reports.parent (page id). Readers = the space / parent page permissions."""
import base64, json, os, re, sys

dt = None

def _http(method, url, body=None, headers=None):
    import urllib.request, urllib.error
    q = urllib.request.Request(url, body and json.dumps(body).encode(), {'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(q, timeout=int((dt.CFG.get('net') or {}).get('timeoutSec') or 60)) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise SystemExit(f'{method} {url}: HTTP {e.code} {e.read()[:300]}')

def publish(a):
    base, token, email = (os.environ.get('CONFLUENCE_' + k, '') for k in ('URL', 'TOKEN', 'EMAIL'))
    if not (base and token and dt.RCFG.get('space')):
        raise SystemExit('confluence needs env CONFLUENCE_URL, CONFLUENCE_TOKEN and reports.space')
    with open(dt._html_of(a), encoding='utf-8') as fh:   # storage format = XHTML: the body, void tags closed
        body = re.sub(r'<(br|hr|img|meta|input|col)\b([^>]*?)/?>', r'<\1\2/>', re.sub(r'(?is)^.*?<body[^>]*>|</body>.*$', '', fh.read()))
    parent, base = a['parent'] or dt.RCFG.get('parent'), base.rstrip('/')
    auth = 'Basic ' + base64.b64encode(f'{email}:{token}'.encode()).decode() if email else 'Bearer ' + token
    page = {'type': 'page', 'title': a['title'], 'space': {'key': dt.RCFG['space']}, 'body': {'storage': {'value': body, 'representation': 'storage'}}}
    if parent:
        page['ancestors'] = [{'id': str(parent)}]
    links = _http('POST', base + '/rest/api/content', page, {'Authorization': auth}).get('_links') or {}
    return links.get('base', base) + links['webui'] if links.get('webui') else sys.exit(f'confluence: no page link in the reply: {links}')


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
    finally:
        _http, dt.RCFG = saved, rcfg0
        os.environ.clear(); os.environ.update(env0)


def register(module):
    global dt
    dt = module
    dt.ADAPTERS['report']['confluence'] = {'publish': publish, 'selftest': selftest}