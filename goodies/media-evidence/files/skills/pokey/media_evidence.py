"""media_evidence.py (goody media-evidence): tester evidence links (videos, recordings, screenshots) -> a cheap time-indexed
text index + frames on demand. Called by pokey.ps1 evidence (it holds the per-video lock, the local-stt / local-vision leases
and the memory gate); every stage also runs alone:
  python -X utf8 media_evidence.py select <link>                      the fetcher for a link (JSON)
  python -X utf8 media_evidence.py fetch <link> [--refresh]           link -> local file + sidecars (<key>/fetch.json)
  python -X utf8 media_evidence.py detect|transcribe|vision|build <key>  index stages (cached per pipeline version)
  python -X utf8 media_evidence.py needs <key> transcribe|vision     does the stage call a local AI server (JSON)
  python -X utf8 media_evidence.py read <key> [<start> <end>] [--at mm:ss --window s] [--around-error] [--frames 3]
                                                  [--size 1280] [--out <dir>]   chunk text + JPEG frames for the Read tool
  python -X utf8 media_evidence.py window <start> <end> --duration <s> [--at t --window s]   the read window (tests)
  python -X utf8 media_evidence.py paths <key>                       key folder, index folder, status (JSON)
In: kit.local.json `media` (GOODY.md), yt-dlp, ffmpeg + ffprobe, OpenCV, node (headless grabs), gws, env JIRA_*. Out: text,
JSON, files under <runtime>/cache/media/<key>/. Exit codes: 0 ok · 1 problem (unreadable link, stage failed) · 2 usage.
Sections: L26 config · L141 fetchers · L395 probe · L414 detect · L593 transcribe · L713 vision · L801 index · L909 read ·
  L980 cli
"""
import base64, hashlib, http.client, json, os, re, shutil, subprocess, sys, threading, time, urllib.error, urllib.parse, urllib.request
import os.path as osp

PIPE = 1   # bump when a stage's output changes: old indexes are rebuilt
HERE = osp.dirname(osp.abspath(__file__))
KIT = osp.dirname(osp.dirname(HERE))
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36'
ERR_RE = re.compile(r"(?i)\b(error|exception|failed|failure|invalid|not found|denied|forbidden|unauthori[sz]ed|time[d ]?out|crash\w*|unable|cannot|can't|wrong|went wrong|(?:http|status|code)\s*[:=]?\s*[45]\d\d)\b")   # a bare 3-digit number is an id or amount, not a status

# ---- config: kit.local.json media + defaults
DEFAULTS = {
    'fetchers': ['file', 'jam-public', 'sharepoint', 'gdrive', 'jira', 'image', 'ytdlp', 'http', 'manual'],
    'jam': {'hosts': ['jam.dev'], 'videoWaitMs': 30000},
    'sharepoint': {'hosts': ['*.sharepoint.com'], 'cookies': {}},
    'gdrive': {'hosts': ['drive.google.com', 'docs.google.com']},
    'jira': {'hosts': ['*.atlassian.net']},
    'image': {'hosts': {'prnt.sc': '#screenshot-image', 'prntscr.com': '#screenshot-image'}},
    'ytdlp': {'hosts': ['loom.com', '*.loom.com', 'youtube.com', '*.youtube.com', 'youtu.be', 'vimeo.com', '*.vimeo.com', '*.wistia.com', '*.vidyard.com']},
    'detect': {'fps': 12, 'width': 640, 'pixel': 18, 'cursorPx': 26, 'settleMs': 400, 'pageFrac': 0.25, 'idleSec': 3, 'maxCrops': 60},
    'chunk': {'minSec': 20, 'maxSec': 60, 'sectionSec': 300, 'twoLevelOverSec': 3600},
    'stt': {'baseUrl': '', 'model': 'whisper-1', 'path': '/v1/audio/transcriptions', 'pieceSec': 30, 'timeoutSec': 300},
    'vision': {'baseUrl': '', 'model': '', 'enabled': True, 'path': '/v1/chat/completions', 'maxFrames': 40, 'maxEdge': 1280, 'timeoutSec': 300, 'gpuStopGB': 0,
               'system': 'You read screenshots. Reply with only the text visible in the image, exactly as written (ids, amounts, dates, error messages), one item per line, then one line starting "UI:" describing the screen. Do not call tools. No commentary.',
               'prompt': 'Visible text:'},
}

def merge(a, b):
    out = dict(a)
    for k, v in (b or {}).items():
        out[k] = merge(a[k], v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return out

def load_json(p, d=None):
    try:
        with open(p, encoding='utf-8-sig') as f:
            return json.load(f)
    except (OSError, ValueError):
        return d

def local_config_file():
    f = osp.join(KIT, 'skills', 'crafty', 'kit.local.json')
    if osp.isfile(f):
        return f
    try:   # a kit worktree reads the main clone's local config (as lib.ps1)
        cd = subprocess.run(['git', '-C', KIT, 'rev-parse', '--path-format=absolute', '--git-common-dir'], capture_output=True, text=True, timeout=10).stdout.strip()
        alt = osp.join(osp.dirname(cd), 'skills', 'crafty', 'kit.local.json') if cd else ''
        return alt if alt and osp.isfile(alt) else f
    except (OSError, subprocess.SubprocessError):
        return f

CFG = merge(DEFAULTS, (load_json(local_config_file(), {}) or {}).get('media') or {})
if os.environ.get('KIT_MEDIA_CONFIG'):   # a JSON file with a media object on top (tests, a one-off run)
    CFG = merge(CFG, load_json(os.environ['KIT_MEDIA_CONFIG'], {}) or {})

def cache_root():
    sys.path.insert(0, osp.join(KIT, 'skills', 'bossy'))
    from kitbag import kit_path   # the one _paths map
    try:
        return kit_path('media')
    except KeyError:   # an older core without _paths.media
        return osp.join(kit_path('cache'), 'media')

def norm_link(link):
    link = link.strip().strip('"\'')
    if link.lower().startswith('file://'):
        link = urllib.parse.unquote(urllib.parse.urlparse(link).path).lstrip('/') if os.name == 'nt' else urllib.parse.unquote(urllib.parse.urlparse(link).path)
    if not re.match(r'(?i)^https?://', link) and osp.exists(link):
        link = osp.normcase(osp.abspath(link))
    return link

def key_of(link):
    return hashlib.sha256(norm_link(link).encode('utf-8')).hexdigest()[:16]

def key_dir(key):
    return osp.join(cache_root(), key)

def sha_file(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()

def ix_dir(key):
    f = load_json(osp.join(key_dir(key), 'fetch.json'))
    if not f or not f.get('sha'):
        return None
    st = {k: {x: y for x, y in CFG[k].items() if x not in ('baseUrl', 'enabled', 'gpuStopGB', 'ramGB', 'maxConcurrent', 'timeoutSec')} for k in ('detect', 'chunk', 'stt', 'vision')}
    return osp.join(key_dir(key), f"v{PIPE}-{f['sha'][:12]}-{hashlib.sha1(json.dumps(st, sort_keys=True).encode()).hexdigest()[:6]}")

def save_json(p, o):
    os.makedirs(osp.dirname(p), exist_ok=True)
    tmp = f'{p}.{os.getpid()}.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(o, f, indent=1, ensure_ascii=False)
    os.replace(tmp, p)

def run(cmd, timeout=600, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, -1, '', f'{cmd[0]} timed out after {timeout} s')
    except OSError as e:
        return subprocess.CompletedProcess(cmd, 127, '', f'{cmd[0]}: {e}')

def tool(name):
    return shutil.which(name)

def mmss(t):
    t = max(0, int(round(t)))
    return f'{t // 3600}:{t % 3600 // 60:02d}:{t % 60:02d}' if t >= 3600 else f'{t // 60}:{t % 60:02d}'

def parse_time(s):
    s = str(s).strip()
    if re.fullmatch(r'\d+(\.\d+)?', s):
        return float(s)
    parts = s.split(':')
    if not all(re.fullmatch(r'\d+(\.\d+)?', p) for p in parts) or len(parts) > 3:
        raise ValueError(f'bad time "{s}" (seconds, m:ss or h:mm:ss)')
    v = 0.0
    for p in parts:
        v = v * 60 + float(p)
    return v

# ---- fetchers: link -> {kind: video|image|unreadable, file, sidecars, meta, reason}
def host_of(link):
    return (urllib.parse.urlparse(link).hostname or '').lower()

def host_in(host, pats):
    for p in pats or []:
        p = p.lower()
        if host == p or (p.startswith('*.') and (host.endswith(p[1:]) or host == p[2:])):
            return True
    return False

MEDIA_EXT = re.compile(r'(?i)\.(mp4|webm|mov|mkv|avi|m4v|m3u8|png|jpe?g|gif|webp|bmp)(\?|$)')

def matches(name, link):
    c, web = CFG.get(name.replace('-public', ''), {}) or {}, bool(re.match(r'(?i)^https?://', link))
    h = host_of(link) if web else ''
    if name == 'file':
        return not web and osp.isfile(link)
    if name == 'manual':
        return True
    if not web:
        return False
    if name == 'jam-public':
        return host_in(h, c.get('hosts')) and '/c/' in urllib.parse.urlparse(link).path
    if name == 'image':
        return h in {k.lower() for k in (c.get('hosts') or {})}
    if name == 'jira':
        jb = host_of(os.environ.get('JIRA_BASE_URL', ''))
        return (host_in(h, c.get('hosts')) or (jb and h == jb)) and '/attachment' in urllib.parse.urlparse(link).path
    if name == 'http':
        return bool(MEDIA_EXT.search(urllib.parse.urlparse(link).path))
    return host_in(h, c.get('hosts'))

def select(link):
    link = norm_link(link)
    order = [f for f in CFG.get('fetchers') or DEFAULTS['fetchers'] if f in FETCHERS]
    if 'manual' not in order:
        order.append('manual')
    for name in order:
        if matches(name, link):
            return name
    return 'manual'

def unreadable(reason):
    return {'kind': 'unreadable', 'reason': reason}

class SameHostAuth(urllib.request.HTTPRedirectHandler):
    """A redirect to another host (a signed storage URL) never carries the Authorization header."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and host_of(newurl) != host_of(req.full_url):
            new.remove_header('Authorization')
        return new

def http_get(url, dest=None, headers=None, timeout=60):
    req = urllib.request.Request(url, headers={'User-Agent': UA, **(headers or {})})
    with urllib.request.build_opener(SameHostAuth).open(req, timeout=timeout) as r:
        ctype = r.headers.get('Content-Type', '')
        if dest:
            with open(dest, 'wb') as f:
                shutil.copyfileobj(r, f)
            return ctype, None
        return ctype, r.read()

def kind_of_file(p, ctype=''):
    if re.search(r'(?i)^image/', ctype) or re.search(r'(?i)\.(png|jpe?g|gif|webp|bmp)$', p):
        return 'image'
    return 'video'

def ytdlp(url, out_dir, extra=()):
    exe = tool('yt-dlp')
    if not exe:
        return None, 'yt-dlp is not on PATH'
    r = run([exe, '-q', '--no-warnings', '--no-playlist', '-f', 'bv*+ba/b', '--merge-output-format', 'mp4', '--write-subs', '--write-auto-subs',
             '--sub-format', 'vtt', '--sub-langs', 'en.*,en', '-o', osp.join(out_dir, 'video.%(ext)s'), *extra, url], timeout=1800)
    vids = [f for f in os.listdir(out_dir) if f.startswith('video.') and not f.endswith(('.vtt', '.part', '.ytdl'))]
    if r.returncode or not vids:
        return None, (r.stderr or r.stdout or 'no file').strip().splitlines()[-1][:300]
    return osp.join(out_dir, sorted(vids, key=lambda f: -osp.getsize(osp.join(out_dir, f)))[0]), None

def node_grab(*args):
    js, node = osp.join(HERE, 'adapters', 'media_grab.mjs'), tool('node')
    if not node or not osp.isfile(js):
        return {'error': 'node or adapters/media_grab.mjs missing'}
    r = run([node, js, *args], timeout=120, cwd=HERE)
    try:
        return json.loads((r.stdout or '').strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {'error': (r.stderr or 'no answer').strip()[:300]}

def f_file(link, d):
    return {'kind': kind_of_file(link), 'file': link}

def f_jam(link, d):
    m = re.search(r'/c/([0-9a-f-]{8,})', link)
    if not m:
        return unreadable('not a jam.dev/c/<id> link')
    base = f'https://jam.dev/c/{m.group(1)}'
    side, meta = {}, {}
    try:
        _, md = http_get(base + '.md', timeout=30)
        p = osp.join(d, 'jam.md')
        open(p, 'wb').write(md)
        side['jam'] = p
        fm = re.search(rb'^---\n(.*?)\n---', md, re.S)
        for line in (fm.group(1).decode('utf-8', 'replace').splitlines() if fm else []):
            k, _, v = line.partition(':')
            if k.strip() in ('type', 'browser', 'os', 'screen', 'date', 'capturedOn'):
                meta[k.strip()] = v.strip().strip('"')
    except urllib.error.HTTPError as e:
        return unreadable(f'jam not public (HTTP {e.code}): ask the tester to set "Anyone with the link" or attach the file')
    except (urllib.error.URLError, OSError) as e:
        return unreadable(f'jam.dev not reachable: {e}')
    try:
        _, tr = http_get(base + '/transcript.md', timeout=30)
        p = osp.join(d, 'transcript.md')
        open(p, 'wb').write(tr)
        side['transcript'] = p
    except (urllib.error.URLError, OSError):
        pass
    if meta.get('type') and meta['type'] != 'video':
        return {**unreadable(f'jam type {meta["type"]}: no video (an Instant Replay is a DOM replay); ask the tester for a screen recording'), 'sidecars': side, 'meta': meta}
    g = node_grab(link, 'video', str(CFG['jam'].get('videoWaitMs', 30000)))
    media = [u for u in g.get('media') or [] if re.search(r'(?i)\.(m3u8|mpd|mp4|webm)', u)]
    if not media:
        return {**unreadable(f'jam video stream not found ({g.get("error", "no media request")})'), 'sidecars': side, 'meta': meta}
    f, err = ytdlp(media[0], d)
    if not f:
        return {**unreadable(f'jam video download failed: {err}'), 'sidecars': side, 'meta': meta}
    return {'kind': 'video', 'file': f, 'sidecars': side, 'meta': meta}

def f_sharepoint(link, d):
    h, cookies = host_of(link), CFG['sharepoint'].get('cookies') or {}
    c = cookies.get(h) or cookies.get('*') or ''
    if not c or not osp.isfile(c):
        return unreadable(f're-auth needed: no cookies file for {h} (media.sharepoint.cookies); ask the tester to share or attach the file')
    f, err = ytdlp(link, d, ['--cookies', c])
    if not f:
        auth = re.search(r'(?i)login|sign.?in|cookies|401|403', err or '')
        return unreadable(f're-auth needed: the cookies for {h} are expired' if auth else f'sharepoint download failed: {err}')
    return {'kind': 'video', 'file': f}

def f_gdrive(link, d):
    m = re.search(r'/d/([\w-]{10,})|[?&]id=([\w-]{10,})', link)
    gws = tool('gws')
    if not m:
        return unreadable('no Drive file id in the link')
    if not gws:
        return unreadable('gws is not configured (Drive / Meet recordings need it)')
    fid = m.group(1) or m.group(2)
    r = run([gws, 'drive', 'files', 'get', '--params', json.dumps({'fileId': fid, 'fields': 'name,mimeType', 'supportsAllDrives': True})], timeout=60)
    try:
        info = json.loads(r.stdout)
    except ValueError:
        return unreadable(f'Drive file not readable with this account: {(r.stderr or r.stdout).strip()[:200]}')
    ext = osp.splitext(info.get('name', ''))[1] or ('.png' if 'image' in info.get('mimeType', '') else '.mp4')
    out = osp.join(d, f'drive{ext}')
    r = run([gws, 'drive', 'files', 'get', '--params', json.dumps({'fileId': fid, 'alt': 'media', 'supportsAllDrives': True}), '-o', out], timeout=1800)
    if r.returncode or not osp.isfile(out):
        return unreadable(f'Drive download failed: {(r.stderr or r.stdout).strip()[:200]}')
    return {'kind': kind_of_file(out, info.get('mimeType', '')), 'file': out, 'meta': {'name': info.get('name', '')}}

def f_jira(link, d):
    e, tok = os.environ, os.environ.get('JIRA_TOKEN')
    if e.get('JIRA_EMAIL') and e.get('JIRA_API_TOKEN'):
        auth = 'Basic ' + base64.b64encode(f"{e['JIRA_EMAIL']}:{e['JIRA_API_TOKEN']}".encode()).decode()
    elif tok:
        auth = f'Bearer {tok}'
    else:
        return unreadable('no Jira credentials (JIRA_EMAIL + JIRA_API_TOKEN or JIRA_TOKEN, as the tracker adapter)')
    name = urllib.parse.unquote(urllib.parse.urlparse(link).path.rstrip('/').split('/')[-1]) or 'attachment'
    out = osp.join(d, re.sub(r'[^\w.-]', '_', name) if '.' in name else 'attachment.bin')
    try:
        ctype, _ = http_get(link, out, {'Authorization': auth}, timeout=600)
    except (urllib.error.URLError, OSError) as x:
        return unreadable(f'Jira attachment download failed: {x}')
    return {'kind': kind_of_file(out, ctype), 'file': out}

def f_image(link, d):
    sel = {k.lower(): v for k, v in (CFG['image'].get('hosts') or {}).items()}.get(host_of(link), 'img')
    out = osp.join(d, 'image.png')
    g = node_grab(link, 'image', sel, out)
    if g.get('image') and not osp.isfile(out):   # the page's fetch was refused (CORS): the image URL directly, as the page's visitor
        try:
            http_get(g['image'], out, {'Referer': link}, timeout=60)
        except (urllib.error.URLError, OSError):
            pass
    if not osp.isfile(out) or osp.getsize(out) < 100:
        return unreadable(f'image not found on the page ({g.get("error", "no image")})')
    return {'kind': 'image', 'file': out, 'meta': {'src': g.get('image', '')}}

def f_ytdlp(link, d):
    f, err = ytdlp(link, d)
    return {'kind': 'video', 'file': f} if f else unreadable(f'yt-dlp could not read it: {err}')

def f_http(link, d):
    if re.search(r'(?i)\.m3u8(\?|$)', link):
        return f_ytdlp(link, d)
    ext = (MEDIA_EXT.search(urllib.parse.urlparse(link).path) or [None, 'bin'])[1].lower()
    out = osp.join(d, f'download.{ext}')
    try:
        ctype, _ = http_get(link, out, timeout=600)
    except (urllib.error.URLError, OSError) as e:
        return unreadable(f'download failed: {e}')
    if re.search(r'(?i)text/html', ctype):
        return unreadable('the link is a web page, not a media file')
    return {'kind': kind_of_file(out, ctype), 'file': out}

def f_manual(link, d):
    return unreadable('no fetcher reads this link')

FETCHERS = {'file': f_file, 'jam-public': f_jam, 'sharepoint': f_sharepoint, 'gdrive': f_gdrive, 'jira': f_jira, 'image': f_image,
            'ytdlp': f_ytdlp, 'http': f_http, 'manual': f_manual}

def seekable(path, src):
    """A recording without a duration (a browser's live WebM) cannot be seeked: one H.264 copy that can."""
    r = run([tool('ffprobe'), '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path], timeout=60)
    if re.fullmatch(r'\s*\d+(\.\d+)?\s*', r.stdout or ''):
        return path
    out = osp.join(src, 'video-seekable.mp4')
    r = run([tool('ffmpeg') or 'ffmpeg', '-v', 'error', '-y', '-i', path, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-c:a', 'aac', out], timeout=3600)
    return out if not r.returncode and osp.isfile(out) else path

def fetch(link, refresh=False):
    link = norm_link(link)
    key, name = key_of(link), select(link)
    d = key_dir(key)
    fj = osp.join(d, 'fetch.json')
    old = load_json(fj)
    if old and not refresh and old.get('kind') in ('video', 'image') and osp.isfile(old.get('file', '')) and (name != 'file' or old.get('srcSha') == sha_file(link)):
        old['cached'] = True
        return old
    src = osp.join(d, 'src')
    if osp.isdir(src):
        shutil.rmtree(src, ignore_errors=True)
    os.makedirs(src, exist_ok=True)
    t0 = time.time()
    try:
        res = FETCHERS[name](link, src)
    except Exception as e:   # one broken fetcher never hides the link: it is unreadable, with the reason
        res = unreadable(f'{name} failed: {type(e).__name__}: {e}')
    res.update({'key': key, 'link': link, 'fetcher': name, 'fetchSec': round(time.time() - t0, 1), 'pipeline': PIPE})
    res.setdefault('sidecars', {})
    res.setdefault('meta', {})
    if res['kind'] == 'video' and tool('ffprobe'):
        res['srcSha'] = sha_file(res['file'])
        res['file'] = seekable(res['file'], src)
    if res['kind'] in ('video', 'image'):
        res['sha'] = sha_file(res['file'])
        res.setdefault('srcSha', res['sha'])
        res['bytes'] = osp.getsize(res['file'])
        save_json(fj, res)
    return res

# ---- probe: ffprobe facts
def probe(path):
    exe = tool('ffprobe')
    if not exe:
        raise RuntimeError('ffprobe is not on PATH')
    r = run([exe, '-v', 'error', '-show_entries', 'format=duration:stream=codec_type,width,height,avg_frame_rate', '-of', 'json', path], timeout=60)
    j = json.loads(r.stdout or '{}')
    v = next((s for s in j.get('streams', []) if s.get('codec_type') == 'video'), {})
    info = {'duration': float(j.get('format', {}).get('duration') or 0), 'width': int(v.get('width') or 0), 'height': int(v.get('height') or 0),
            'audio': any(s.get('codec_type') == 'audio' for s in j.get('streams', []))}
    if info['audio']:   # a recorder without a mic writes a silent track: no STT call for it
        r = run([tool('ffmpeg') or 'ffmpeg', '-hide_banner', '-i', path, '-vn', '-af', 'volumedetect', '-f', 'null', '-'], timeout=600)
        m = re.search(r'max_volume: (-?[\d.]+) dB', r.stderr or '')
        info['maxDb'] = float(m.group(1)) if m else None
        if m and float(m.group(1)) < -60:
            info['audio'] = False
            info['silent'] = True
    return info

# ---- detect: dense change-then-settle events on downscaled grey frames
def detect(path, info, out_dir):
    import numpy as np, cv2
    c = CFG['detect']
    fps, w = float(c['fps']), int(c['width'])
    W, H = info['width'] or 1280, info['height'] or 720
    w = min(w, W - W % 2)
    h = max(2, int(round(H * w / W / 2)) * 2)
    cmd = [tool('ffmpeg') or 'ffmpeg', '-v', 'error', '-i', path, '-vf', f'fps={fps},scale={w}:{h},format=gray', '-f', 'rawvideo', '-pix_fmt', 'gray', '-']
    size = w * h

    def masks():   # (t, changed-pixel mask) per frame pair
        p, prev, i = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL), None, -1
        while True:
            buf = p.stdout.read(size)
            if len(buf) < size:
                break
            i += 1
            f = np.frombuffer(buf, np.uint8).reshape(h, w)
            if prev is not None:
                yield i / fps, (cv2.absdiff(f, prev) > int(c['pixel'])).astype(np.uint8)
            prev = f
        p.wait()

    # pass 1: tickers (a recorder's clock, a spinner): one small 32 px cell changing in most seconds of a 5 s+ span is no event
    cell, hits, i, kernel = 32, {}, 0, np.ones((3, 3), np.uint8)
    for t, m in masks():
        i += 1
        if not 3 <= int(m.sum()) <= 0.02 * size:
            continue
        n, _, st, cen = cv2.connectedComponentsWithStats(cv2.dilate(m, kernel), 8)
        for k in range(1, n):   # small comps, not a text caret (thin: filtered below anyway)
            if st[k][4] >= 3 and not (st[k][2] <= 4 and st[k][3] <= 24) and st[k][2] <= 2 * cell and st[k][3] <= 2 * cell:
                hits.setdefault((int(cen[k][1]) // cell, int(cen[k][0]) // cell), set()).add(int(t))
    tick = np.ones((h, w), np.uint8)
    tickers = []
    for (cy, cx), secs in hits.items():
        span = max(secs) - min(secs) + 1
        if len(secs) >= 5 and span >= 5 and len(secs) >= 0.6 * span:
            tick[cy * cell:(cy + 1) * cell, cx * cell:(cx + 1) * cell] = 0
            tickers.append([round(cx * cell / w, 2), round(cy * cell / h, 2)])
    settle = max(1, int(round(float(c['settleMs']) / 1000 * fps)))
    cur_px, ev, events, cursor, quiet, last_any = int(c['cursorPx']), None, [], [], 0, 0.0
    burst, last_cur_t, cur_pos = None, -9.0, None
    kernel = np.ones((3, 3), np.uint8)
    for t, mask in masks():
        if tickers:
            mask &= tick
        if mask.sum() < 3:
            content = []
            curs = []
        else:
            n, _, st, cen = cv2.connectedComponentsWithStats(cv2.dilate(mask, kernel), 8)
            # a blinking text caret (<= 4 px wide after the 3x3 dilation) is no change
            comps = [(st[k], cen[k]) for k in range(1, n) if st[k][4] >= 3 and not (st[k][2] <= 4 and st[k][3] <= 24)]
            small = [x for x in comps if x[0][2] <= cur_px and x[0][3] <= cur_px]
            # the pointer: two small blobs (old + new place) or one that continues a fresh move; a lone small blob = a typed key
            moving = cur_pos is not None and t - last_cur_t <= 0.35 and len(small) == 1 and (small[0][1][0] - cur_pos[0]) ** 2 + (small[0][1][1] - cur_pos[1]) ** 2 <= 60 ** 2
            curs = small if len(small) == 2 or moving else []
            content = [x for x in comps if not any(x is y for y in curs)]
        if curs:
            pts = [tuple(x[1]) for x in curs]
            pos = max(pts, key=lambda q: (q[0] - cur_pos[0]) ** 2 + (q[1] - cur_pos[1]) ** 2) if cur_pos else pts[-1]
            if burst is None or t - burst['t_end'] > 0.5:
                if burst:
                    cursor.append(burst)
                burst = {'t': round(t, 2), 't_end': round(t, 2), 'from': [cur_pos[0] if cur_pos else pos[0], cur_pos[1] if cur_pos else pos[1]], 'to': list(pos)}
            burst['t_end'], burst['to'] = round(t, 2), list(pos)
            cur_pos, last_cur_t, last_any = pos, t, t
        if content:
            x0 = min(s[0] for s, _ in content); y0 = min(s[1] for s, _ in content)
            x1 = max(s[0] + s[2] for s, _ in content); y1 = max(s[1] + s[3] for s, _ in content)
            frac = float(sum(s[4] for s, _ in content)) / size
            if ev is None:
                ev = {'t': round(t - 1 / fps, 2), 't_end': round(t, 2), 'box': [x0, y0, x1, y1], 'frac': frac, 'frames': 1,
                      'cursor': list(cur_pos) if cur_pos and t - last_cur_t <= 1.0 else None, 'cursorStill': t - last_cur_t > 0.15}
            else:
                b = ev['box']
                ev['box'] = [min(b[0], x0), min(b[1], y0), max(b[2], x1), max(b[3], y1)]
                ev['t_end'], ev['frac'], ev['frames'] = round(t, 2), max(ev['frac'], frac), ev['frames'] + 1
            quiet, last_any = 0, t
        elif ev is not None:
            quiet += 1
            if quiet >= settle:
                events.append(ev)
                ev, quiet = None, 0
    if ev:
        events.append(ev)
    if burst:
        cursor.append(burst)
    dur = info['duration'] or i / fps
    rows = classify(events, cursor, w, h, dur)
    for r in rows:   # boxes and points as fractions of the frame (any resolution)
        if 'box' in r:
            r['box'] = [round(r['box'][0] / w, 3), round(r['box'][1] / h, 3), round(r['box'][2] / w, 3), round(r['box'][3] / h, 3)]
        for k in ('cursor', 'from', 'to'):
            if r.get(k):
                r[k] = [round(r[k][0] / w, 3), round(r[k][1] / h, 3)]
    crops(path, rows, out_dir, W, H)
    return {'fps': fps, 'scaled': [w, h], 'duration': dur, 'events': rows, 'tickers': tickers, 'counts': {k: sum(1 for r in rows if r['kind'] == k) for k in sorted({r['kind'] for r in rows})}}

def classify(events, cursor, w, h, dur):
    c, rows = CFG['detect'], []
    for e in events:
        x0, y0, x1, y1 = e['box']
        kind = 'page-change' if e['frac'] >= float(c['pageFrac']) or ((x1 - x0) * (y1 - y0) >= 0.6 * w * h and e['frac'] >= 0.05) else 'change'
        r = {'t': e['t'], 't_end': e['t_end'], 'kind': kind, 'box': e['box'], 'frac': round(e['frac'], 4), 'source': 'detect'}
        if e['cursor'] and e['cursorStill']:   # the screen changed right after the pointer stopped near it: a click, guessed
            cx, cy = e['cursor']
            near = x0 - 60 <= cx <= x1 + 60 and y0 - 60 <= cy <= y1 + 60
            if near or kind == 'page-change':
                r['click'], r['cursor'] = 'guess', e['cursor']
        rows.append(r)
    merged = []
    for r in rows:   # typing: small same-line changes in a row, < 1.5 s apart
        bh = r['box'][3] - r['box'][1]
        p = merged[-1] if merged else None
        if p and r['kind'] == 'change' and p['kind'] in ('change', 'typing') and bh <= 0.06 * h and (p['box'][3] - p['box'][1]) <= 0.08 * h \
                and r['t'] - p['t_end'] <= 1.5 and abs(r['box'][1] - p['box'][1]) <= 0.03 * h and 'click' not in r:
            p['kind'], p['keys'] = 'typing', p.get('keys', 1) + 1
            b = p['box']
            p['box'], p['t_end'] = [min(b[0], r['box'][0]), min(b[1], r['box'][1]), max(b[2], r['box'][2]), max(b[3], r['box'][3])], r['t_end']
            continue
        merged.append(r)
    for b in cursor:
        merged.append({'t': b['t'], 't_end': b['t_end'], 'kind': 'cursor', 'from': b['from'], 'to': b['to'], 'source': 'detect'})
    marks = sorted([0.0] + [x['t'] for x in merged] + [x['t_end'] for x in merged] + [dur])
    for a, b in zip(marks, marks[1:]):
        if b - a >= float(c['idleSec']) and not any(x['t'] < b and x['t_end'] > a for x in merged):
            merged.append({'t': round(a, 2), 't_end': round(b, 2), 'kind': 'idle', 'source': 'detect'})
    merged.sort(key=lambda x: (x['t'], x['kind']))
    for n, r in enumerate(merged, 1):
        r['id'] = f'e{n:03d}'
    return merged

def grab(path, t, cap=None):
    import cv2
    own = cap is None
    cap = cap or cv2.VideoCapture(path)
    cap.set(cv2.CAP_PROP_POS_MSEC, max(0.0, t) * 1000)
    ok, fr = cap.read()
    if own:
        cap.release()
    return fr if ok else None

def save_jpeg(img, out, edge):
    import cv2
    hh, ww = img.shape[:2]
    s = min(1.0, edge / max(hh, ww))
    if s < 1:
        img = cv2.resize(img, (int(ww * s), int(hh * s)), interpolation=cv2.INTER_AREA)
    os.makedirs(osp.dirname(out), exist_ok=True)
    cv2.imwrite(out, img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    return out

def crops(path, rows, out_dir, W, H):
    import cv2
    want = [r for r in rows if r['kind'] in ('change', 'typing', 'page-change')]
    want = sorted(want, key=lambda r: (r['kind'] != 'page-change', 'click' not in r, -r.get('frac', 0)))[:int(CFG['detect']['maxCrops'])]
    cap = cv2.VideoCapture(path)
    for r in want:
        settle = float(CFG['detect']['settleMs']) / 1000
        for side, t in (('before', r['t'] - 0.05), ('after', r['t_end'] + settle)):
            fr = grab(path, t, cap)
            if fr is None:
                continue
            if r['kind'] == 'page-change':
                if side == 'after':
                    r['keyframe'] = osp.relpath(save_jpeg(fr, osp.join(out_dir, 'frames', f"{r['id']}-after.jpg"), 1280), out_dir)
                continue
            fh, fw = fr.shape[:2]
            x0, y0, x1, y1 = r['box']
            x0, y0 = max(0, int(x0 * fw) - 24), max(0, int(y0 * fh) - 24)
            x1, y1 = min(fw, int(x1 * fw) + 24), min(fh, int(y1 * fh) + 24)
            if x1 - x0 < 8 or y1 - y0 < 8:
                continue
            r[f'crop_{side}'] = osp.relpath(save_jpeg(fr[y0:y1, x0:x1], osp.join(out_dir, 'frames', f"{r['id']}-{side}.jpg"), 400), out_dir)
    cap.release()

# ---- transcribe: sidecars first (Jam transcript, VTT), else the local OpenAI-compatible STT server on speech pieces
def parse_vtt(p):
    segs, cur = [], None
    for line in open(p, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*((?:\d+:)?\d+:\d+[.,]\d+)\s*-->\s*((?:\d+:)?\d+:\d+[.,]\d+)', line)
        if m:
            cur = {'t': parse_time(m.group(1).replace(',', '.')), 't_end': parse_time(m.group(2).replace(',', '.')), 'text': '', 'source': 'vtt'}
            segs.append(cur)
        elif cur is not None and line.strip() and not line.strip().isdigit():
            txt = re.sub(r'<[^>]+>', '', line.strip())
            if txt and not cur['text'].endswith(txt):
                cur['text'] = (cur['text'] + ' ' + txt).strip()
    out = []
    for s in segs:   # auto-subs repeat the previous line: keep only new words
        if s['text'] and (not out or s['text'] != out[-1]['text']):
            out.append(s)
    return out

def parse_jam_transcript(p):
    segs = []
    for line in open(p, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*[-*]?\s*\[(\d+:\d+(?::\d+)?)\]\s*(.+)', line)
        if m:
            segs.append({'t': parse_time(m.group(1)), 'text': m.group(2).strip(), 'source': 'jam'})
    for a, b in zip(segs, segs[1:]):
        a['t_end'] = b['t']
    if segs:
        segs[-1]['t_end'] = segs[-1]['t'] + 10
    return segs

def endpoint_up(base, timeout=5):
    try:
        urllib.request.urlopen(urllib.request.Request(base.rstrip('/') + '/v1/models', headers={'User-Agent': 'kit-media-evidence'}), timeout=timeout).read(200)
        return True
    except urllib.error.HTTPError:   # it answered (no /v1/models route): up
        return True
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException):
        return False

def speech_pieces(wav, dur):
    r = run([tool('ffmpeg') or 'ffmpeg', '-hide_banner', '-i', wav, '-af', 'silencedetect=noise=-35dB:d=0.6', '-f', 'null', '-'], timeout=600)
    sil, start = [], None
    for m in re.finditer(r'silence_(start|end): (-?[\d.]+)', r.stderr or ''):
        if m.group(1) == 'start':
            start = float(m.group(2))
        else:
            sil.append((max(0.0, start or 0.0), float(m.group(2))))
            start = None
    if start is not None:
        sil.append((start, dur))
    speech, t = [], 0.0
    for a, b in sil:
        if a - t >= 0.4:
            speech.append((t, a))
        t = b
    if dur - t >= 0.4:
        speech.append((t, dur))
    piece, out = max(5.0, float(CFG['stt']['pieceSec'])), []
    for a, b in speech:
        while b - a > piece:
            out.append((a, a + piece))
            a += piece
        out.append((a, b))
    return out

def multipart(fields, file_field, file_path):
    bnd = 'kit' + hashlib.md5(file_path.encode()).hexdigest()
    body = b''
    for k, v in fields.items():
        body += f'--{bnd}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
    body += f'--{bnd}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{osp.basename(file_path)}"\r\nContent-Type: audio/wav\r\n\r\n'.encode()
    body += open(file_path, 'rb').read() + f'\r\n--{bnd}--\r\n'.encode()
    return body, f'multipart/form-data; boundary={bnd}'

def transcribe(path, info, fj, out_dir):
    side = fj.get('sidecars') or {}
    if side.get('transcript'):
        segs = parse_jam_transcript(side['transcript'])
        if segs:
            return {'source': 'jam', 'segments': segs}
    src = osp.join(key_dir(fj['key']), 'src')   # never the tester's own folder (a file link)
    vtts = [osp.join(src, f) for f in os.listdir(src) if f.endswith('.vtt')] if osp.isdir(src) else []
    if vtts:
        return {'source': 'vtt', 'segments': parse_vtt(vtts[0])}
    if not info.get('audio'):
        return {'source': 'none', 'reason': 'silent audio track (no mic)' if info.get('silent') else 'no audio track', 'segments': []}
    c = CFG['stt']
    if not c.get('baseUrl'):
        return {'source': 'none', 'reason': 'no local STT configured (media.stt.baseUrl)', 'segments': [], 'degraded': True}
    if not endpoint_up(c['baseUrl']):
        return {'source': 'none', 'reason': 'waiting for local STT: it does not answer', 'segments': [], 'degraded': True}
    wav = osp.join(out_dir, 'audio.wav')
    r = run([tool('ffmpeg') or 'ffmpeg', '-v', 'error', '-y', '-i', path, '-vn', '-ac', '1', '-ar', '16000', wav], timeout=900)
    if r.returncode:
        return {'source': 'none', 'reason': f'audio extract failed: {r.stderr.strip()[:200]}', 'segments': [], 'degraded': True}
    segs, t0 = [], time.time()
    for n, (a, b) in enumerate(speech_pieces(wav, info['duration'])):
        piece = osp.join(out_dir, f'piece-{n:03d}.wav')
        cut = run([tool('ffmpeg') or 'ffmpeg', '-v', 'error', '-y', '-ss', f'{a:.2f}', '-to', f'{b:.2f}', '-i', wav, piece], timeout=120)
        if cut.returncode or not osp.isfile(piece):
            return {'source': 'stt', 'reason': f'audio cut failed at {mmss(a)}', 'segments': segs, 'degraded': True}
        try:
            body, ctype = multipart({'model': c['model']}, 'file', piece)
            req = urllib.request.Request(c['baseUrl'].rstrip('/') + c['path'], body, {'Content-Type': ctype, 'User-Agent': 'kit-media-evidence'})
            txt = json.loads(urllib.request.urlopen(req, timeout=int(c['timeoutSec'])).read()).get('text', '').strip()
        except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as e:
            return {'source': 'stt', 'reason': f'local STT failed at {mmss(a)}: {e}', 'segments': segs, 'degraded': True, 'sec': round(time.time() - t0, 1)}
        finally:
            try:
                os.remove(piece)
            except OSError:
                pass
        if txt:
            segs.append({'t': round(a, 2), 't_end': round(b, 2), 'text': txt, 'source': 'stt'})
    try:
        os.remove(wav)
    except OSError:
        pass
    return {'source': 'stt', 'segments': segs, 'sec': round(time.time() - t0, 1)}

# ---- vision: screen text + a UI line per keyframe / event crop, through the local OpenAI-compatible vision LLM
def gpu_gb():
    exe = tool('nvidia-smi')
    if not exe:
        return None
    r = run([exe, '--query-gpu=memory.used', '--format=csv,noheader,nounits'], timeout=10)
    try:
        return max(int(x) for x in r.stdout.split()) / 1024
    except ValueError:
        return None

def vision_targets(det, fj, out_dir):
    if fj.get('kind') == 'image':
        return [{'ref': 'image', 't': 0, 'file': fj['file']}]
    rows = det.get('events', [])
    tg = [{'ref': r['id'], 't': r['t_end'], 'file': osp.join(out_dir, r['keyframe'])} for r in rows if r.get('keyframe')]
    tg += [{'ref': r['id'], 't': r['t_end'], 'file': osp.join(out_dir, r['crop_after'])} for r in sorted(rows, key=lambda r: ('click' not in r, -r.get('frac', 0))) if r.get('crop_after')]
    first = osp.join(out_dir, 'frames', 'start.jpg')
    fr = grab(fj['file'], 0.5)
    if fr is not None:
        tg.insert(0, {'ref': 'start', 't': 0.5, 'file': save_jpeg(fr, first, 1280)})
    seen, out = set(), []
    for x in tg:
        if x['file'] not in seen and osp.isfile(x['file']):
            seen.add(x['file'])
            out.append(x)
    return out[:int(CFG['vision']['maxFrames'])]

def ask_vision(c, img_path):
    import cv2
    img = cv2.imread(img_path)
    hh, ww = img.shape[:2]
    s = min(1.0, int(c['maxEdge']) / max(hh, ww))
    if s < 1:
        img = cv2.resize(img, (int(ww * s), int(hh * s)), interpolation=cv2.INTER_AREA)
    ok, jpg = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    body = {'model': c['model'], 'messages': ([{'role': 'system', 'content': c['system']}] if c.get('system') else []) + [{'role': 'user', 'content': [
            {'type': 'image_url', 'image_url': {'url': 'data:image/jpeg;base64,' + base64.b64encode(jpg.tobytes()).decode()}}, {'type': 'text', 'text': c['prompt']}]}]}
    req = urllib.request.Request(c['baseUrl'].rstrip('/') + c['path'], json.dumps(body).encode(), {'Content-Type': 'application/json', 'User-Agent': 'kit-media-evidence'})
    d = json.loads(urllib.request.urlopen(req, timeout=int(c['timeoutSec'])).read())
    txt = re.sub(r'(?s)<think>.*?(</think>|$)', '', (d.get('choices') or [{}])[0].get('message', {}).get('content') or '').strip()
    return txt

def vision(det, fj, out_dir, model=None):
    c = dict(CFG['vision'])
    if model:
        c['model'] = model
    if not c.get('enabled', True):
        return {'reason': 'vision off (media.vision.enabled false)', 'items': [], 'degraded': True}
    if not (c.get('baseUrl') and c.get('model')):
        return {'reason': 'no local vision model configured (media.vision.baseUrl + model)', 'items': [], 'degraded': True}
    if not endpoint_up(c['baseUrl']):
        return {'reason': 'waiting for local vision: it does not answer', 'items': [], 'degraded': True}
    stop_gb, items, peak, t0, why = float(c.get('gpuStopGB') or 0), [], [0.0], time.time(), ''
    halt = threading.Event()
    def watch():   # GPU memory near the limit: no next request
        while not halt.wait(1.0):
            g = gpu_gb()
            if g is not None:
                peak[0] = max(peak[0], g)
    if stop_gb and gpu_gb() is None:
        return {'reason': 'media.vision.gpuStopGB is set but nvidia-smi does not answer: not run', 'items': [], 'degraded': True}
    if stop_gb:
        threading.Thread(target=watch, daemon=True).start()
    for x in vision_targets(det, fj, out_dir):
        if stop_gb:
            peak[0] = max(peak[0], gpu_gb() or 0)
        if stop_gb and peak[0] >= stop_gb:
            why = f'stopped: GPU memory {peak[0]:.2f} GB >= media.vision.gpuStopGB {stop_gb}'
            break
        s0 = time.time()
        try:   # one failure stops the stage: never retried into a crashed or busy backend
            txt = ask_vision(c, x['file'])
        except urllib.error.HTTPError as e:
            why = f'stopped: the vision backend answered HTTP {e.code}'
            break
        except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException, AttributeError, KeyError, IndexError) as e:
            why = f'stopped: the vision backend failed ({type(e).__name__}: {e})'
            break
        ui = '\n'.join(l for l in txt.splitlines() if l.strip().upper().startswith('UI:'))
        items.append({'ref': x['ref'], 't': x['t'], 'text': '\n'.join(l for l in txt.splitlines() if l.strip() and not l.strip().upper().startswith('UI:')),
                      'ui': ui[3:].strip() if ui else '', 'sec': round(time.time() - s0, 1)})
    halt.set()
    res = {'model': c['model'], 'items': items, 'sec': round(time.time() - t0, 1), 'gpuPeakGB': round(peak[0], 2) if stop_gb else None}
    if why:
        res.update({'reason': why, 'degraded': True})
    return res

# ---- index: chunks of 20-60 s split at page changes / idle, one row each; two levels for long videos
def chunks_of(dur, cuts):
    c = CFG['chunk']
    lo, hi = max(1.0, float(c['minSec'])), max(2.0, float(c['maxSec']), float(c['minSec']))
    cuts = sorted({round(x, 2) for x in cuts if 0 < x < dur})
    out, s = [], 0.0
    while s < dur - 0.01:
        cand = [x for x in cuts if lo <= x - s <= hi]
        e = cand[0] if cand else min(dur, s + hi)
        if dur - e < lo / 2:
            e = dur
        out.append((round(s, 2), round(e, 2)))
        s = e
    return out or [(0.0, round(dur, 2))]

def pt(p):
    return f'({p[0]:.2f},{p[1]:.2f})' if p else ''

def ev_line(r):
    b = r.get('box')
    where = f' at {pt(b[:2])} {b[2] - b[0]:.2f}x{b[3] - b[1]:.2f}' if b else ''
    if r['kind'] == 'cursor':
        return f"{mmss(r['t'])} cursor {pt(r['from'])}->{pt(r['to'])}"
    if r['kind'] == 'idle':
        return f"{mmss(r['t'])}-{mmss(r['t_end'])} idle"
    click = f"click? {pt(r['cursor'])} -> " if r.get('click') == 'guess' else ('click ' if r.get('click') else '')
    keys = f" x{r['keys']}" if r.get('keys') else ''
    src = '' if r.get('source', 'detect') == 'detect' else f" [{r['source']}]"
    return f"{mmss(r['t'])} {click}{r['kind']}{keys}{where}{src}"

def clip(s, n):
    s = re.sub(r'\s+', ' ', s or '').strip()
    return s if len(s) <= n else s[:n - 1] + '…'

def build(key):
    kd, ix = key_dir(key), ix_dir(key)
    fj = load_json(osp.join(kd, 'fetch.json')) or {}
    det = load_json(osp.join(ix, 'detect.json')) or {'events': [], 'duration': 0}
    tr = load_json(osp.join(ix, 'transcribe.json')) or {'segments': [], 'source': 'none', 'reason': 'not run'}
    vi = load_json(osp.join(ix, 'vision.json')) or {'items': [], 'reason': 'not run'}
    info = load_json(osp.join(ix, 'probe.json')) or {}
    dur = float(info.get('duration') or det.get('duration') or 0)
    rows = [r for r in det.get('events', []) if r['kind'] != 'cursor']
    if fj.get('kind') == 'image':
        spans = [(0.0, 0.0)]
    else:
        cuts = [r['t'] for r in rows if r['kind'] == 'page-change'] + [(r['t'] + r['t_end']) / 2 for r in rows if r['kind'] == 'idle']
        spans = chunks_of(dur, cuts)
    vis = {x['ref']: x for x in vi.get('items', [])}
    out = []
    for n, (s, e) in enumerate(spans, 1):
        inside = lambda x: (s <= x['t'] < e) or (s == e == 0) or (n == len(spans) and x['t'] >= s)
        evs = [r for r in rows if inside(r)]
        curs = [r for r in det.get('events', []) if r['kind'] == 'cursor' and inside(r)]
        say = ' '.join(x['text'] for x in tr.get('segments', []) if inside(x))
        screen = [vis[x]['text'] for x in vis if inside(vis[x])]
        ui = [vis[x]['ui'] for x in vis if inside(vis[x]) and vis[x].get('ui')]
        flags = sorted({m.group(1).lower() for m in ERR_RE.finditer(say + ' ' + ' '.join(screen))})
        out.append({'id': f'c{n:02d}', 'start': s, 'end': e, 'say': clip(say, 400), 'screen': clip(' | '.join(screen), 300), 'ui': clip(' | '.join(ui), 200),
                    'events': [ev_line(r) for r in evs if r['kind'] != 'idle'][:12], 'more': max(0, len([r for r in evs if r['kind'] != 'idle']) - 12),
                    'cursorMoves': len(curs), 'flags': flags, 'error': bool(flags)})
    meta = fj.get('meta') or {}
    mtxt = ' · '.join(f'{k} {meta[k]}' for k in ('type', 'browser', 'os', 'screen', 'date', 'capturedOn', 'name') if meta.get(k))
    head = [f"# media {key} · {fj.get('fetcher', '?')} · {fj.get('kind', '?')}" + (f" · {mmss(dur)}" if dur else '') + (f" · {info.get('width')}x{info.get('height')}" if info.get('width') else ''),
            f"link: {fj.get('link', '')}" + (f' · {mtxt}' if mtxt else ''),
            f"events: {', '.join(f'{k} {v}' for k, v in (det.get('counts') or {}).items()) or 'none'}{' · ignored: ' + str(len(det['tickers'])) + ' ticking cells (a clock)' if det.get('tickers') else ''} (click? = guessed from the pointer; boxes and points are fractions of the frame)",
            f"speech: {tr.get('source')}{' (' + tr['reason'] + ')' if tr.get('reason') else ''} · screen text: {len(vi.get('items', []))} frames{' (' + vi['reason'] + ')' if vi.get('reason') else ''}",
            f"read: pokey.ps1 evidence read-chunk {key} <start> <end> | -At <m:ss> -Window <s> | -AroundError", '']
    def row(c):
        r = [f"## {c['id']} {mmss(c['start'])}-{mmss(c['end'])}{' [error: ' + ', '.join(c['flags']) + ']' if c['flags'] else ''}"]
        if c['say']:
            r.append(f"say: {c['say']}")
        if c['screen']:
            r.append(f"screen: {c['screen']}")
        if c['ui']:
            r.append(f"ui: {c['ui']}")
        r += [f'- {x}' for x in c['events']]
        if c['more']:
            r.append(f"- +{c['more']} more events (read-chunk lists them)")
        if c['cursorMoves']:
            r.append(f"cursor: {c['cursorMoves']} moves")
        return '\n'.join(r)
    files = {}
    if dur > float(CFG['chunk']['twoLevelOverSec']):
        sec = float(CFG['chunk']['sectionSec'])
        lines = list(head)
        for n in range(int(dur // sec) + 1):
            part = [c for c in out if n * sec <= c['start'] < (n + 1) * sec]
            if not part:
                continue
            name = f'index-s{n:02d}.md'
            files[name] = '\n\n'.join(row(c) for c in part) + '\n'
            fl = sorted({f for c in part for f in c['flags']})
            pages = sum(1 for c in part for x in c['events'] if 'page-change' in x)
            lines.append(f"## s{n:02d} {mmss(n * sec)}-{mmss(min(dur, (n + 1) * sec))} · {len(part)} chunks · {pages} page changes{' · error: ' + ', '.join(fl) if fl else ''} -> {name}")
            say = clip(' '.join(c['say'] for c in part), 160)
            if say:
                lines.append(f'say: {say}')
        files['index.md'] = '\n'.join(lines) + '\n'
    else:
        files['index.md'] = '\n'.join(head) + '\n'.join(row(c) for c in out).replace('\n## ', '\n\n## ') + '\n'
    for name, txt in files.items():
        with open(osp.join(ix, name), 'w', encoding='utf-8') as f:
            f.write(txt)
    tok = len(files['index.md'].encode('utf-8')) // 4
    save_json(osp.join(ix, 'index.json'), {'key': key, 'duration': dur, 'kind': fj.get('kind'), 'chunks': out, 'tokens': tok, 'files': sorted(files)})
    return {'index': osp.join(ix, 'index.md'), 'tokens': tok, 'chunks': len(out), 'files': sorted(files)}

# ---- read: one window's text + frames as JPEGs
def window(start, end, at, win, dur):
    if at is not None:
        w = float(win if win is not None else 20)
        s, e = parse_time(at) - w / 2, parse_time(at) + w / 2
    else:
        s, e = parse_time(start if start is not None else 0), parse_time(end) if end is not None else dur
    if dur:
        s, e = max(0.0, min(s, dur)), max(0.0, min(e, dur))
    else:
        s = max(0.0, s)
    if e < s or (e == s and dur):
        raise ValueError(f'empty window {mmss(s)}-{mmss(e)} (video {mmss(dur)})')
    return round(s, 2), round(e, 2)

def error_windows(ixj, det, win):
    w, pts = float(win or 20), []
    for c in ixj.get('chunks', []):
        if c.get('error'):
            pts.append((c['start'], c['end']))
    out = []
    for s, e in sorted(pts):
        s, e = max(0.0, s - w / 2), min(ixj.get('duration') or e + w, e + w / 2)
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return [(round(a, 2), round(b, 2)) for a, b in out]

def read(key, start=None, end=None, at=None, win=None, around_error=False, frames=3, size=1280, out=None):
    kd, ix = key_dir(key), ix_dir(key)
    fj, ixj = load_json(osp.join(kd, 'fetch.json')), load_json(osp.join(ix, 'index.json') if ix else '')
    if not fj or not ixj:
        raise FileNotFoundError(f'no index for {key}: run pokey.ps1 evidence index <link> first')
    det = load_json(osp.join(ix, 'detect.json')) or {'events': []}
    tr = load_json(osp.join(ix, 'transcribe.json')) or {'segments': []}
    vi = load_json(osp.join(ix, 'vision.json')) or {'items': []}
    dur = float(ixj.get('duration') or 0)
    out = out or osp.join(kd, 'reads')
    os.makedirs(out, exist_ok=True)
    if fj['kind'] == 'image':
        import cv2
        p = save_jpeg(cv2.imread(fj['file']), osp.join(out, f'{key}-image.jpg'), size)
        return [f'image {key}: {p}'] + [f"screen: {x['text']}" for x in vi.get('items', [])]
    wins = error_windows(ixj, det, win) if around_error else [window(start, end, at, win, dur)]
    if around_error and not wins:
        return [f'{key}: no chunk has an error flag (index.md); read a window by time instead']
    lines = []
    for s, e in wins:
        lines.append(f'# {key} {mmss(s)}-{mmss(e)}')
        lines += [f"chunk {c['id']} {mmss(c['start'])}-{mmss(c['end'])}{' [error]' if c.get('error') else ''}" for c in ixj['chunks'] if c['start'] < e and c['end'] > s or c['start'] == s]
        lines += [f"say {mmss(x['t'])}: {x['text']}" for x in tr.get('segments', []) if s <= x['t'] <= e]
        lines += [f'- {ev_line(r)}' for r in det.get('events', []) if s <= r['t'] <= e]
        lines += [f"screen {mmss(x['t'])}: {clip(x['text'], 500)}" for x in vi.get('items', []) if s <= x['t'] <= e]
        ts = [s] + [r['t_end'] + 0.4 for r in det.get('events', []) if r['kind'] in ('change', 'typing', 'page-change') and s < r['t_end'] + 0.4 < e] + [max(s, e - 0.1)]
        pick = []
        for t in ts:
            if not pick or t - pick[-1] >= 1.0:
                pick.append(t)
        n = max(1, int(frames))
        if len(pick) > n:
            pick = [pick[round(i * (len(pick) - 1) / (n - 1))] for i in range(n)] if n > 1 else [pick[-1]]
        import cv2
        cap = cv2.VideoCapture(fj['file'])
        for t in pick:
            fr = grab(fj['file'], t, cap)
            if fr is not None:
                lines.append(f"frame {mmss(t)}: {save_jpeg(fr, osp.join(out, f'{key}-{int(t * 10):06d}.jpg'), int(size))}")
        cap.release()
    return lines

# ---- cli: stage runner, needs, argv
def stage(key, name):
    kd, ix = key_dir(key), ix_dir(key)
    fj = load_json(osp.join(kd, 'fetch.json'))
    if not fj or not ix:
        raise FileNotFoundError(f'no fetched file for {key}: run fetch first')
    os.makedirs(ix, exist_ok=True)
    target = osp.join(ix, f'{name}.json')
    old = load_json(target)
    if old is not None and not old.get('degraded') and '--refresh' not in sys.argv:
        return {'stage': name, 'cached': True, 'reason': old.get('reason', '')}
    info = None if '--refresh' in sys.argv else load_json(osp.join(ix, 'probe.json'))
    if info is None:
        info = probe(fj['file']) if fj['kind'] == 'video' else {'duration': 0, 'width': 0, 'height': 0, 'audio': False}
        save_json(osp.join(ix, 'probe.json'), info)
    t0 = time.time()
    if name == 'detect':
        res = detect(fj['file'], info, ix) if fj['kind'] == 'video' else {'events': [], 'duration': 0, 'counts': {}}
    elif name == 'transcribe':
        res = transcribe(fj['file'], info, fj, ix) if fj['kind'] == 'video' else {'source': 'none', 'segments': []}
    else:
        res = vision(load_json(osp.join(ix, 'detect.json')) or {'events': []}, fj, ix, model=arg('--model'))
    res['stageSec'] = round(time.time() - t0, 1)
    save_json(target, res)
    return {'stage': name, 'sec': res['stageSec'], 'reason': res.get('reason', ''), 'degraded': bool(res.get('degraded')),
            **({'counts': res.get('counts')} if name == 'detect' else {}), **({'segments': len(res.get('segments', []))} if name == 'transcribe' else {}),
            **({'items': len(res.get('items', []))} if name == 'vision' else {})}

def needs(key, name):
    """Does this stage call a local AI server (so pokey.ps1 takes its lease + gate first)? Cached, sidecar or off -> no."""
    kd, ix = key_dir(key), ix_dir(key)
    fj = load_json(osp.join(kd, 'fetch.json')) or {}
    old = load_json(osp.join(ix, f'{name}.json') if ix else '')
    if not fj or (old is not None and not old.get('degraded') and '--refresh' not in sys.argv):
        return False
    if name == 'vision':
        c = CFG['vision']
        return bool(c.get('enabled', True) and c.get('baseUrl') and c.get('model'))
    if fj.get('kind') != 'video' or (fj.get('sidecars') or {}).get('transcript') or not CFG['stt'].get('baseUrl'):
        return False
    src = osp.join(key_dir(key), 'src')
    if osp.isdir(src) and any(f.endswith('.vtt') for f in os.listdir(src)):
        return False
    info = load_json(osp.join(ix, 'probe.json'))
    if info is None:
        info = probe(fj['file'])
        save_json(osp.join(ix, 'probe.json'), info)
    return bool(info.get('audio'))

def arg(name, default=None):
    a = sys.argv
    return a[a.index(name) + 1] if name in a and a.index(name) + 1 < len(a) else default

def main():
    a = [x for i, x in enumerate(sys.argv[1:], 1) if not x.startswith('--') and not (i > 1 and sys.argv[i - 1] in ('--at', '--window', '--frames', '--size', '--out', '--duration', '--model'))]
    if not a:
        print(__doc__)
        return 2
    cmd, rest = a[0], a[1:]
    try:
        if cmd == 'select' and rest:
            print(json.dumps({'fetcher': select(rest[0]), 'key': key_of(rest[0]), 'link': norm_link(rest[0])}))
        elif cmd == 'fetch' and rest:
            r = fetch(rest[0], '--refresh' in sys.argv)
            r['ixDir'] = ix_dir(r['key']) if r['kind'] != 'unreadable' else None
            print(json.dumps(r, ensure_ascii=False))
            return 0 if r['kind'] != 'unreadable' else 1
        elif cmd in ('detect', 'transcribe', 'vision') and rest:
            print(json.dumps(stage(rest[0], cmd), ensure_ascii=False))
        elif cmd == 'needs' and len(rest) >= 2:
            print(json.dumps({'need': needs(rest[0], rest[1])}))
        elif cmd == 'build' and rest:
            print(json.dumps(build(rest[0])))
        elif cmd == 'read' and rest:
            print('\n'.join(read(rest[0], rest[1] if len(rest) > 1 else None, rest[2] if len(rest) > 2 else None, arg('--at'), arg('--window'),
                                 '--around-error' in sys.argv, int(arg('--frames', 3)), int(arg('--size', 1280)), arg('--out'))))
        elif cmd == 'window' and len(rest) >= 2:
            print(json.dumps(window(rest[0], rest[1], arg('--at'), arg('--window'), float(arg('--duration', 0)))))
        elif cmd == 'paths' and rest:
            k = rest[0] if re.fullmatch(r'[0-9a-f]{16}', rest[0]) else key_of(rest[0])
            ix = ix_dir(k)
            print(json.dumps({'key': k, 'keyDir': key_dir(k), 'ixDir': ix, 'index': osp.join(ix, 'index.md') if ix and osp.isfile(osp.join(ix, 'index.md')) else None}))
        else:
            print(__doc__)
            return 2
    except (ValueError, FileNotFoundError, RuntimeError) as e:
        print(f'media-evidence {cmd}: {e}', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
