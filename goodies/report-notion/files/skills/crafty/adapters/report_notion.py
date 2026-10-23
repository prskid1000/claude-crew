"""Goody report-notion: reports.type notion = a child page of reports.parent via REST (env NOTION_TOKEN): heading, paragraph,
bulleted and code blocks, 100 per call. Readers = the parent page's sharing."""
import html, json, os, re

dt = None

def _http(method, url, body=None, headers=None):
    import urllib.request, urllib.error
    q = urllib.request.Request(url, body and json.dumps(body).encode(), {'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with urllib.request.urlopen(q, timeout=int((dt.CFG.get('net') or {}).get('timeoutSec') or 60)) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise SystemExit(f'{method} {url}: HTTP {e.code} {e.read()[:300]}')

def _rich(s):
    return [{'type': 'text', 'text': {'content': s[i:i + 2000]}} for i in range(0, len(s), 2000)]


def _blocks(text):
    blocks, code = [], None
    for line in text.splitlines() + ['```']:   # the goody fence closes an open code block
        if line.strip().startswith('```'):
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


def publish(a):
    token, parent = os.environ.get('NOTION_TOKEN'), a['parent'] or dt.RCFG.get('parent')
    if not (token and parent):
        raise SystemExit('notion needs env NOTION_TOKEN and reports.parent (a page shared with the integration)')
    with open(a['path'], encoding='utf-8') as fh:
        text = fh.read()
    if not a['path'].lower().endswith(('.md', '.markdown')):   # HTML: its text lines
        text = html.unescape(re.sub(r'<[^>]+>', '\n', re.sub(r'(?is)<(head|style|script)\b.*?</\1>', '', text)))
    blocks = _blocks(text)
    headers, api = {'Authorization': 'Bearer ' + token, 'Notion-Version': '2022-06-28'}, 'https://api.notion.com/v1/'
    title = {'title': [{'text': {'content': a['title']}}]}
    page = _http('POST', api + 'pages', {'parent': {'page_id': parent}, 'properties': {'title': title}, 'children': blocks[:100]}, headers)
    if not page.get('id'):
        raise SystemExit(f'notion: no page in the reply: {str(page)[:300]}')
    for i in range(100, len(blocks), 100):
        _http('PATCH', f"{api}blocks/{page['id']}/children", {'children': blocks[i:i + 100]}, headers)
    return page.get('url') or 'https://www.notion.so/' + page['id'].replace('-', '')


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
    finally:
        _http = saved
        os.environ.clear(); os.environ.update(env0)


def register(module):
    global dt
    dt = module
    dt.ADAPTERS['report']['notion'] = {'publish': publish, 'selftest': selftest}