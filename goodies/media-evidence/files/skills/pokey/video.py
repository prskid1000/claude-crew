"""video.py (goody media-evidence): the whole video flow in one script: tester evidence links (videos, recordings, screenshots)
-> a cheap time-indexed text index + frames on demand; the vidy agent reads the keyframes and writes them back. pokey.ps1 evidence
<verb> passes its arguments here (-Name or --name, any case):
  fetch <link> [--refresh] [--json]                                   link -> local file + sidecars (one lock per video)
  index <link> [--refresh] [--wait-minutes 30] [--lock-minutes 90] [--no-transcript] [--agent a] [--json]
                                                  fetch, detect, transcribe (local-stt lease + memory gate), vision, build
  read-chunk <key> [<start> <end>] [--at mm:ss --window s] [--around-error] [--frames 3] [--size 1280] [--item <task>]
                                                  that window's text + JPEG frames for the Read tool
  frames <key> [--segment n]                      the detector's keyframes vidy has not read: batches, segments
  write-vision <key> --file <items.json> [--model m] [--tokens n]    vidy's screen text -> vision.json, index rebuilt, logged
  status [<key or link>]                          the local-stt lease, a video's folders
  feedback <key> --file <verify.json>             vidy's verify phase: labels, feedback rows, the corpus (perfect -> passed)
  bench [--key k] [--names a,b] [--no-crf36] [--no-corpus] [--record] [--json]
                                                  the detector gate: synthetic clips + crf-36 variants + the cached corpus
  Stages alone: select <link> · detect|transcribe|vision|build <key> · needs <key> transcribe · window <start> <end>
  --duration <s> [--at t --window s] (tests) · paths <key>.
In: kit.local.json `media` (GOODY.md), yt-dlp, ffmpeg + ffprobe, OpenCV, node (adapters/media_grab.mjs: headless grabs), gws,
env JIRA_*, CLAUDE_AGENT. Out: text, JSON, files under <runtime>/cache/media/<key>/. Exit codes: 0 ok · 1 problem (unreadable
link, busy, stage failed) · 2 usage.
Sections: L32 config · L147 fetchers · L402 probe · L421 detect · L1309 transcribe · L1429 vision · L1525 index · L1647 read ·
  L1722 bench · L2208 verbs · L2354 cli
"""
import base64, contextlib, hashlib, http.client, json, math, os, re, shutil, subprocess, sys, time, urllib.error, urllib.parse, urllib.request
import os.path as osp

PIPE = 3   # bump when a stage's output changes: old indexes are rebuilt
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
    'detect': {'fps': 10, 'edge': 960, 'edgeHi': 1280, 'idleSec': 3, 'frames': 24, 'framesPerMin': 6, 'maxFrames': 120, 'fillSec': 8},   # keyframes: frames + framesPerMin, <= maxFrames; fills over it
    'chunk': {'minSec': 20, 'maxSec': 60, 'sectionSec': 300, 'twoLevelOverSec': 3600},
    'stt': {'baseUrl': '', 'model': 'whisper-1', 'path': '/v1/audio/transcriptions', 'pieceSec': 30, 'timeoutSec': 300},
    'corpus': {'keep': 10, 'pin': []},   # media kept for the newest <keep> corpus clips; pin: keys or links never evicted
    'vidy': {'model': 'sonnet', 'batch': 8, 'segmentSec': 300, 'labelTokens': 80000},   # one vidy per segment; labelTokens: the verify phase's cap per video
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
    st = {k: {x: y for x, y in CFG[k].items() if x not in ('baseUrl', 'ramGB', 'maxConcurrent', 'timeoutSec')} for k in ('detect', 'chunk', 'stt')}
    st['vidy'] = {'segmentSec': CFG['vidy']['segmentSec']}   # vidy's model and batch never re-index
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
    side = next((x for x in (link + '.events.json', osp.splitext(link)[0] + '.events.json') if osp.isfile(x)), None)   # pokey / lane action log
    return {'kind': kind_of_file(link), 'file': link, 'sidecars': {'events': side} if side else {}}

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

# ---- detect: keyframes from pixels (block change map vs a reference frame -> episodes -> greedy coverage), sidecar actions first
KP = dict(B=16, settle=0.3, tau0=12, tau_min=5, tau_max=30, mu_min=1.5, mu_max=6, blk_px=2, cur_px=24, thin=3, anim_win=4.0, anim_hits=4,
          anim_span=2.0, anim_off=3.0, anim_gap=3.0, scroll_step=0.6, photo_frac=0.30, page_frac=0.35, toast_frac=0.08, long_ep=4.0,
          gain_min=2.0, state_cover=0.99, fill_cover=0.98, fill_floor=0.95, flat_w=0.05, strong=16, anim_sample=15.0, after_cap=2.0, act_wait=0.6)
cv2 = np = None

def need_cv():
    global cv2, np
    if cv2 is None:
        import cv2 as c_, numpy as n_
        cv2, np = c_, n_

def scaled_size(W, H):
    c, B = CFG['detect'], KP['B']
    s = min(1.0, float(c['edge'] if max(W, H) <= 1920 else c['edgeHi']) / max(W, H))   # never upscaled
    return max(B, int(round(W * s / B)) * B), max(B, int(round(H * s / B)) * B)

def decode(path, w, h, fps):
    p = subprocess.Popen([tool('ffmpeg') or 'ffmpeg', '-v', 'error', '-i', path, '-vf', f'fps={fps},scale={w}:{h}:flags=area', '-f', 'rawvideo',
                          '-pix_fmt', 'bgr24', '-'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=w * h * 12)
    n = w * h * 3
    try:
        while True:
            b = p.stdout.read(n)
            if len(b) < n:
                break
            yield np.frombuffer(b, np.uint8).reshape(h, w, 3)   # a fresh read-only buffer per frame: kept without a copy
    finally:
        p.stdout.close()
        p.wait()

def decode_at(path, w, h, t):   # one frame at t, scaled as the detector sees it
    p = subprocess.run([tool('ffmpeg') or 'ffmpeg', '-v', 'error', '-ss', f'{max(0.0, t):.2f}', '-i', path, '-frames:v', '1', '-vf', f'scale={w}:{h}:flags=area',
                        '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-'], capture_output=True, timeout=120)
    if len(p.stdout) >= w * h * 3:
        yield np.frombuffer(p.stdout[:w * h * 3], np.uint8).reshape(h, w, 3)

class Blocks:
    def __init__(s, w, h, B):
        s.B, s.bx, s.by, s.w, s.h = B, w // B, h // B, w, h
        s.iy, s.ix = np.arange(0, h + 1, B), np.arange(0, w + 1, B)

    def count(s, m):   # set pixels per block of a 0/255 mask (area mean x 256/255: +-0.5 px)
        return cv2.resize(m, (s.bx, s.by), interpolation=cv2.INTER_AREA).astype(np.float32) * (s.B * s.B / 255.0)

    def mean(s, g):   # block means from the integral image (exact, no float frame)
        I = cv2.integral(g)[np.ix_(s.iy, s.ix)].astype(np.float32)
        return (I[1:, 1:] - I[:-1, 1:] - I[1:, :-1] + I[:-1, :-1]) * (1.0 / (s.B * s.B))

    def cells(s, boxes, pad=4):   # blocks a pixel box (x0, y0, x1, y1) touches
        m = np.zeros((s.by, s.bx), bool)
        for x0, y0, x1, y1 in boxes:
            m[max(0, y0 - pad) // s.B:(y1 + pad) // s.B + 1, max(0, x0 - pad) // s.B:(x1 + pad) // s.B + 1] = True
        return m

def keyframes(path, W, H, dur=0.0, anchors=(), params=None):
    """One recording -> {frames (kept, time order), events, revisits, cursor, ...}. Per-video noise model (max-RGB block counts +
    block means, codec pulses) -> pointer, caret and animation masks -> episodes against a reference frame K (settle, transient
    peak, scroll, fade / dim) -> candidates -> lazy greedy coverage under the budget. anchors: sidecar action times (s): the
    frame before each and the first settled frame after it are candidates, the after frame always kept."""
    need_cv()
    p = dict(KP, **(params or {}))
    c = CFG['detect']
    fps, B = float(p.get('fps') or c['fps']), p['B']
    S = max(2, int(round(p['settle'] * fps)))
    w, h = scaled_size(W, H)
    bl = Blocks(w, h, B)
    nb = bl.bx * bl.by
    kern, k13 = np.ones((3, 3), np.uint8), np.ones((1, 3), np.uint8)
    ksc = max(w, h) / 960.0
    cur_max, thin = p['cur_px'] * ksc, p['thin']
    tau, tau_mu, quiet_q, quiet_mu = p['tau0'], 3.0, [], []
    prev = prevg = prevmu = None
    K = None   # reference state: g, bgr, mu, cur (pointer boxes), curf (pointer found by template), t
    cands, events = [], []
    last_act = np.full((bl.by, bl.bx), -99.0, np.float32)
    anim = np.zeros((bl.by, bl.bx), bool)
    anim_since, anim_last, anim_box, anim_samples = None, -99.0, None, []
    nring = max(2, int(p['anim_win'] * fps))
    ring, rtim, ridx = np.zeros((nring, bl.by, bl.bx), bool), np.full(nring, -99.0), 0
    ring_n = np.zeros((bl.by, bl.bx), np.int16)   # activations per block inside the ring (kept incrementally)
    hann = {}
    cur = dict(pos=None, t=-9, boxes=[], box=None, v=0.0)
    cursor_path, tmpl, noise = [], dict(patch=None, n=0), dict(pulse=0.0, pulses=0, pend=None)
    ep, q, i, t_cpu, first_quiet = None, S, -1, 0.0, None
    anc = [dict(t=float(a), before=None, after=None, q=0, seen=False, fq=None) for a in sorted(anchors)]
    masks = []

    def maxdiff(a, b):   # per-pixel max channel difference: a field turning red counts, not only luma
        if a.ndim == 2:
            return cv2.absdiff(a, b)
        return np.ascontiguousarray(cv2.dilate(cv2.absdiff(a, b).reshape(h, w * 3), k13)[:, 1::3])

    def sth():   # a strong luma difference: above glyph-edge contrast, 3x pair noise and the codec pulse level
        return int(max(p['strong'], 3 * tau, noise['pulse']))

    def ccs(M):   # connected components on the bounding box of the changed pixels only
        x, y, ww_, hh_ = cv2.boundingRect(cv2.findNonZero(M))
        ox, oy, ox1, oy1 = max(0, x - 2), max(0, y - 2), min(w, x + ww_ + 2), min(h, y + hh_ + 2)
        n, lab, st, cen = cv2.connectedComponentsWithStats(cv2.dilate(M[oy:oy1, ox:ox1], kern), 8)
        st = st.copy()
        st[:, 0] += ox
        st[:, 1] += oy
        return n, lab, st, cen + [ox, oy], (ox, oy, ox1, oy1)

    def comp_cells(st, ks):
        m = np.zeros((bl.by, bl.bx), bool)
        for k in ks:
            x0, y0, ww_, hh_ = st[k][:4]
            m[y0 // B:(y0 + hh_ - 1) // B + 1, x0 // B:(x0 + ww_ - 1) // B + 1] = True
        return m

    def cursor_comps(small, st, cen, g, pg, t):
        """The pointer is a small rigid patch that moves: comp j now looks like comp i did in the previous frame. Learned once
        (template), then any small comp the template matches in this or the previous frame is the pointer."""
        out, newpos = [], None
        if len(small) > 4:   # many small blobs = text or content changing, not one pointer
            return [], None
        crop = lambda img, k, ww, hh: img[int(st[k][1]):int(st[k][1]) + hh, int(st[k][0]):int(st[k][0]) + ww]
        sm = [k for k in small if st[k][2] <= cur_max and st[k][3] <= cur_max]
        for i1 in (sm if len(sm) <= 3 else []):
            for j1 in sm:
                if i1 == j1 or abs(int(st[i1][2]) - int(st[j1][2])) > 3 or abs(int(st[i1][3]) - int(st[j1][3])) > 3:
                    continue
                ww, hh = int(max(st[i1][2], st[j1][2])), int(max(st[i1][3], st[j1][3]))
                a = crop(pg, i1, ww, hh)
                xj, yj = int(st[j1][0]), int(st[j1][1])
                b = g[max(0, yj - 2):yj + hh + 2, max(0, xj - 2):xj + ww + 2]
                if a.size >= 30 and a.std() > 2 and b.shape[0] >= a.shape[0] and b.shape[1] >= a.shape[1] \
                        and float(cv2.matchTemplate(b, a, cv2.TM_CCOEFF_NORMED).max()) >= 0.5:
                    out += [i1, j1]
                    newpos = tuple(cen[j1])
                    if tmpl['n'] < 20 and len(sm) == 2:
                        tmpl['patch'] = crop(g, j1, ww, hh).copy()
                        tmpl['n'] += 1
        if tmpl['patch'] is not None:
            th, tw = tmpl['patch'].shape
            fresh = cur['pos'] is not None and t - cur['t'] <= 0.5
            for k in small:
                if k in out or fresh and math.dist(cen[k], cur['pos']) > max(80 * ksc, 3 * cur['v']):   # one pointer: a far blob is content
                    continue
                x, y, ww, hh = [int(v) for v in st[k][:4]]
                x0, y0 = max(0, x - 2), max(0, y - 2)
                for img, isnew in ((g, True), (pg, False)):
                    reg = img[y0:y + hh + 2, x0:x + ww + 2]
                    if reg.shape[0] >= th and reg.shape[1] >= tw and reg.std() > 1 and float(cv2.matchTemplate(reg, tmpl['patch'], cv2.TM_CCOEFF_NORMED).max()) >= 0.7:
                        out.append(k)
                        if isnew:
                            newpos = tuple(cen[k])
                        break
            if cur['pos'] is not None and t - cur['t'] <= 0.5:   # continuation of a fresh move
                for k in small:
                    if k not in out and 0.6 * tw <= st[k][2] <= 2.2 * tw and 0.6 * th <= st[k][3] <= 2.2 * th \
                            and math.dist(cen[k], cur['pos']) <= max(60 * ksc, 2.5 * cur['v']):
                        out.append(k)
                        newpos = tuple(cen[k])
        out = sorted(set(out))
        return (out, newpos) if len(out) <= 3 else ([], None)

    def find_cursor(g, hint=None):
        """Pointer box in one frame: the learned template, near the tracked position when known."""
        if tmpl['patch'] is None:
            return []
        th, tw = tmpl['patch'].shape
        x0 = y0 = 0
        reg = g
        if hint is not None:
            x0, y0 = max(0, int(hint[0]) - 60), max(0, int(hint[1]) - 60)
            reg = g[y0:int(hint[1]) + 60, x0:int(hint[0]) + 60]
            if reg.shape[0] < th or reg.shape[1] < tw:
                reg, x0, y0 = g, 0, 0
        _, mx, _, loc = cv2.minMaxLoc(cv2.matchTemplate(reg, tmpl['patch'], cv2.TM_CCOEFF_NORMED))
        if mx < 0.6 and hint is not None:
            return find_cursor(g)
        return [(x0 + loc[0], y0 + loc[1], x0 + loc[0] + tw, y0 + loc[1] + th)] if mx >= 0.6 else []

    def ref_diff(fb, g, mu, Kr, boxes):
        """Blocks where a frame differs from the reference (stricter: two encodings of the same pixels drift), without the
        pointer (both frames), thin carets and animated blocks -> (R, changed px)."""
        if Kr.get('curf') is None:
            Kr['curf'] = find_cursor(Kr['g'])
        bx = list(boxes or []) + find_cursor(g, cur['pos']) + Kr['curf'] + Kr['cur']
        M = cv2.threshold(maxdiff(fb, Kr['bgr']), max(tau + 4, int(1.5 * tau)), 255, cv2.THRESH_BINARY)[1]
        for x0, y0, x1, y1 in bx:
            M[max(0, y0 - 4):y1 + 4, max(0, x0 - 4):x1 + 4] = 0
        npx, badb = cv2.countNonZero(M), np.zeros((bl.by, bl.bx), bool)
        if 0 < npx < 0.05 * w * h:   # real components only: not a thin caret, and strong (glyph edges) or large (fills)
            Dg = cv2.absdiff(g, Kr['g'])
            n, lab, st, _, (ox, oy, ox1, oy1) = ccs(M)
            strong, bad = sth(), []
            for k in range(1, n):
                x0, y0, ww_, hh_, ar = [int(v) for v in st[k]]
                if ww_ <= thin + 2 and hh_ <= 48 * ksc:
                    bad.append(k)
                    continue
                sub = Dg[y0:y0 + hh_, x0:x0 + ww_][lab[y0 - oy:y0 - oy + hh_, x0 - ox:x0 - ox + ww_] == k]
                if not (sub.size and int(sub.max()) >= strong and ar >= 6) and not dim_glyph(Dg, st[k], lab, k, ox, oy):
                    bad.append(k)
            if bad:
                M[oy:oy1, ox:ox1][np.isin(lab, bad)] = 0
                npx = cv2.countNonZero(M)
                badb = comp_cells(st, bad)
        R = (bl.count(M) >= 2 * p['blk_px']) | ((np.abs(mu - Kr['mu']) >= tau_mu + (3.0 if Kr.get('pulsed') else 1.0)) & ~badb)
        R &= ~anim & ~bl.cells(bx)
        return R, npx

    def dim_glyph(Dg, s_, lab, k, ox, oy):
        """A dim glyph under heavy compression (crf 36 dark themes): edges below the strong level, but a compact text-sized
        component whose pixels clear twice the pair noise in most of its area."""
        x0, y0, ww_, hh_, ar = [int(v) for v in s_]
        if ar < 12 or ww_ < 4 or hh_ < 6 or hh_ > 64 * ksc or ww_ > 400 * ksc:
            return False
        sub = Dg[y0:y0 + hh_, x0:x0 + ww_][lab[y0 - oy:y0 - oy + hh_, x0 - ox:x0 - ox + ww_] == k]
        return sub.size > 0 and float(np.percentile(sub, 75)) >= max(10, 2 * tau)

    def red_new(a, b, R):
        if not R.any():
            return False
        red = lambda hv: ((hv[..., 0] <= 8) | (hv[..., 0] >= 172)) & (hv[..., 1] > 120) & (hv[..., 2] > 90)
        return float((red(cv2.cvtColor(a, cv2.COLOR_BGR2HSV)) & ~red(cv2.cvtColor(b, cv2.COLOR_BGR2HSV))).mean()) >= 0.0005

    def edge_blocks(a, b, thr=None):   # blocks where strong luma edges differ (text, icons) rather than a fill
        return bl.count(cv2.threshold(cv2.absdiff(a, b), thr or sth(), 255, cv2.THRESH_BINARY)[1]) >= 2 * p['blk_px']

    def modal(R, munew):
        """A panel over a dimmed page: most blocks darken by 10-70% while one compact changed box does not ('modal'); the
        reverse brightening = 'modal-closed'."""
        ok = K['mu'] > 24
        r = munew / np.maximum(K['mu'], 1.0)
        for kind, sh in (('modal', (r <= 0.9) & (r >= 0.3)), ('modal-closed', (r >= 1.1) & (r <= 3.4))):
            sh &= ok
            if sh.mean() < 0.3:
                continue
            ys, xs = np.nonzero(R & ~sh & ok)
            if len(ys):
                ba = (ys.max() - ys.min() + 1) * (xs.max() - xs.min() + 1) / nb
                inside = np.zeros_like(sh)
                inside[ys.min():ys.max() + 1, xs.min():xs.max() + 1] = True
                if 0.04 <= ba <= 0.6 and sh[~inside & ok].mean() >= 0.6:
                    return kind
        return None

    def classify(e, R, area, box, gnew, munew, curb):
        if e is None:
            return 'start'
        fr = max(1, e['frames'])
        if e['scroll'] >= max(2, 0.4 * fr):
            return 'scroll'
        if e['photo'] >= max(2, 0.4 * fr) or area >= p['page_frac'] or e['broad'] >= 0.12 and e['frames'] >= 3:   # broad and gradual: a cross-fade
            return modal(R, munew) or 'page'
        if box and area >= 0.12 and (box[2] - box[0]) * (box[3] - box[1]) >= 0.5 * nb:   # changes spread over most of the screen
            return 'page'
        if box and area <= p['toast_frac']:
            x0, y0, x1, y1 = box
            if 4 * int((edge_blocks(gnew, K['g'], max(12, 2 * tau)) & R & ~bl.cells(curb)).sum()) < int(R.sum()):
                return 'highlight'   # a fill (selection, hover, a dark theme's row tint): text unchanged
            one_line = (y1 - y0) <= 3 * max(1, round(ksc))
            corner = (x1 - x0) <= 0.45 * bl.bx and (x0 >= 0.55 * bl.bx or x1 <= 0.45 * bl.bx) and (y0 <= 0.2 * bl.by or y1 >= 0.8 * bl.by)
            return 'toast?' if corner else ('text' if one_line else 'change')
        return 'change'

    def cand(t, g, mu, kind, wt, why, curb, red=False, an=None, ev=None, forced=False, delta=None):
        cands.append(dict(t=t, g=g, mu=mu, kind=kind, w=wt, red=red, anim=anim.copy() if an is None else an, why=why, curb=curb, ev=ev, forced=forced, delta=delta))
        return len(cands) - 1

    def news(g1, mu1, g0, mu0):   # the blocks a state changed against the one before it (its news)
        return (edge_blocks(g1, g0, max(12, 2 * tau)) | (np.abs(mu1 - mu0) >= tau_mu + 1.0)) & ~anim

    def commit(t, fb, g, mu, R, e, why, boxes_at=()):
        nonlocal K
        ys, xs = np.nonzero(R)
        box = [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1] if len(xs) else None
        area = float(R.sum()) / nb
        curb = list(boxes_at) + find_cursor(g, cur['pos'])
        kind = classify(e, R, area, box, g, mu, curb)
        red = red_new(fb, K['bgr'], R)
        ev = dict(kind=kind, t0=round(e['t0'] if e else t, 2), t1=round(t, 2), area=round(area, 4),
                  box=[round(v * B / (w if k % 2 == 0 else h), 3) for k, v in enumerate(box)] if box else None, error=bool(red))
        events.append(ev)
        if e is not None and e.get('peak_f') is not None and e['peak_f'][0] < t - 0.5:   # a state inside the transition (a modal,
            tp, fp, gp, mp, bp = e['peak_f']                                               # a loading screen) that never held still
            ev['peak'] = cand(tp, gp, mp, 'intermediate', 1.0, 'peak', bp + find_cursor(gp), red_new(fp, K['bgr'], R), ev=len(events) - 1)
        last = e.get('last') if e else None
        ev['cand'] = cand(t, g, mu, kind, 1.0 + (1.0 if red else 0), why, curb, red, ev=len(events) - 1, delta=R & (news(g, mu, *last) if last else True))
        for c_ in cands:   # a state 'held' just before this settle is the same screen arriving: never a frame of its own
            if c_['why'] == 'held' and c_['ev'] == len(events) - 1 and c_['t'] >= t - 0.5:
                c_['w'] = 0.0
        for o in events:   # toast: an earlier small change whose region now shows its old pixels again
            if o.get('kind') == 'toast?' and t - o['t1'] <= 10 and o.get('_pre') is not None:
                x0, y0, x1, y1 = o['_pb']
                if not edge_blocks(g[y0:y1, x0:x1], o['_pre']).any():
                    o['kind'], o['shown_until'] = 'toast', round(t, 2)
                    o.pop('_pre')
        if kind == 'toast?' and box:
            x0, y0, x1, y1 = box[0] * B, box[1] * B, box[2] * B, box[3] * B
            ev['_pre'], ev['_pb'] = K['g'][y0:y1, x0:x1].copy(), (x0, y0, x1, y1)
        K = dict(g=g, bgr=fb, mu=mu, cur=list(boxes_at), t=t, curf=None)

    def anchor_step(t, fb, g, mu, active):
        for a in anc:
            if a['after'] is not None:
                continue
            if a['before'] is None:
                if t >= a['t']:
                    a['before'] = (round(t - 1 / fps, 2), prevg, prevmu)
                else:
                    continue
            a['seen'] = a['seen'] or active
            if active:
                a['q'], a['fq'] = 0, None
            elif a['seen'] or t - a['t'] >= p['act_wait']:   # wait for the screen to answer, then for it to settle
                a['q'] += 1
                a['fq'] = a['fq'] or (round(t, 2), g, mu)
                if a['q'] >= S:
                    a['after'] = a['fq']
            if a['after'] is None and t - a['t'] >= p['after_cap']:
                a['after'] = (round(t, 2), g, mu)

    for f in decode(path, w, h, fps):
        i += 1
        t = i / fps
        c0 = time.perf_counter()
        g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
        mu = bl.mean(g)
        if prev is None:
            K = dict(g=g, bgr=f, mu=mu, cur=[], t=0.0, curf=None)
            cand(0.0, g, mu, 'start', 1.0, 'first', [], ev=0)
            events.append(dict(kind='start', t0=0.0, t1=0.0, cand=0))
            prev, prevg, prevmu = f, g, mu
            anchor_step(t, f, g, mu, False)
            t_cpu += time.perf_counter() - c0
            continue
        D = maxdiff(f, prev)
        if cv2.countNonZero(cv2.threshold(D, 40, 255, cv2.THRESH_BINARY)[1]) < 0.0002 * w * h:   # quiet pair: codec noise only
            if i % 3 == 0:
                cdf = np.cumsum(cv2.calcHist([D], [0], None, [256], [0, 256]).ravel()) / D.size
                quiet_q.append(int(np.searchsorted(cdf, 0.9995)))
                quiet_mu.append(float(np.percentile(np.abs(mu - prevmu), 99.5)))
                del quiet_q[:-60], quiet_mu[:-60]
                if len(quiet_q) >= 5:
                    tau = int(np.clip(np.median(quiet_q) + 3, p['tau_min'], p['tau_max']))
                    tau_mu = float(np.clip(np.median(quiet_mu) + 1.0, p['mu_min'], p['mu_max']))
        M = cv2.threshold(D, tau, 255, cv2.THRESH_BINARY)[1]
        npx = cv2.countNonZero(M)
        dropb = None
        if 0 < npx < 0.01 * w * h:   # small changes: pointer and caret separation
            n, lab, st, cen, (ox, oy, ox1, oy1) = ccs(M)
            thin_k = [k for k in range(1, n) if st[k][2] <= thin + 2 and st[k][3] <= 48 * ksc]
            small = [k for k in range(1, n) if k not in thin_k and st[k][2] <= 2 * cur_max and st[k][3] <= 2 * cur_max]
            curk, newpos = cursor_comps(small, st, cen, g, prevg, t)
            if curk:
                pos = newpos if newpos is not None else tuple(cen[curk[-1]])
                kn = min(curk, key=lambda k: math.dist(cen[k], pos))
                cur['v'] = math.dist(pos, cur['pos']) if cur['pos'] is not None and t - cur['t'] <= 0.25 else 0.0
                cur.update(pos=pos, t=t, boxes=[(int(st[k][0]), int(st[k][1]), int(st[k][0] + st[k][2]), int(st[k][1] + st[k][3])) for k in curk],
                           box=(int(st[kn][0]), int(st[kn][1]), int(st[kn][0] + st[kn][2]), int(st[kn][1] + st[kn][3])))
                cursor_path.append((round(t, 2), round(pos[0] / w, 3), round(pos[1] / h, 3)))
            drop = thin_k + curk
            if drop:
                M[oy:oy1, ox:ox1][np.isin(lab, drop)] = 0
                dropb = comp_cells(st, drop)
        dmu = np.abs(mu - prevmu)
        A = (bl.count(M) >= p['blk_px']) | ((dmu >= tau_mu) & (True if dropb is None else ~dropb))
        # codec pulse (a keyframe re-quantises the whole picture): broad, weak, no mean shift, isolated in time
        if noise['pend'] is not None:   # confirm the previous candidate: the next pair is calm again
            if A.mean() < 0.02:
                noise['pulse'] = min(48.0, max(noise['pulse'], noise['pend']))
                noise['pulses'] += 1
                K['pulsed'] = True   # a re-quantised picture shifts block means a little: the reference needs a larger shift
                if ep is None:   # re-anchor the reference, except blocks whose mean moved (a real change riding on the pulse)
                    keep = np.abs(prevmu - K['mu']) >= tau_mu + 1.0
                    km = cv2.resize(keep.astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST).astype(bool)
                    g2, f2, m2 = prevg.copy(), prev.copy(), prevmu.copy()
                    g2[km], f2[km], m2[keep] = K['g'][km], K['bgr'][km], K['mu'][keep]
                    K.update(g=g2, bgr=f2, mu=m2, curf=None, pulsed=False)
            noise['pend'] = None
        elif ep is None and q >= S and A.mean() >= 0.08 and float(np.median(dmu[A])) < 1.0:
            if cv2.countNonZero(cv2.threshold(D, max(24, 3 * tau), 255, cv2.THRESH_BINARY)[1]) < 0.15 * max(1, npx):
                noise['pend'] = float(np.percentile(cv2.absdiff(g, prevg)[M > 0], 97)) + 4 if npx else 0.0
                A = np.zeros_like(A)
        # motion on the changed region (before the animation update: a scroll or a fade is no animation)
        Aeff0 = A & ~anim
        area0 = float(Aeff0.sum()) / nb
        is_scroll = is_photo = photo_dim = False
        scroll_info = None
        if area0 >= 0.06:
            ys3, xs3 = np.nonzero(Aeff0)
            y0, y1, x0, x1 = ys3.min() * B, (ys3.max() + 1) * B, xs3.min() * B, (xs3.max() + 1) * B
            if y1 - y0 >= 64 and x1 - x0 >= 64:
                ds = 2 if (y1 - y0) * (x1 - x0) > 200000 else 1   # phase correlation at half size on big regions
                a2, b2 = prevg[y0:y1, x0:x1], g[y0:y1, x0:x1]
                if ds > 1:
                    a2, b2 = cv2.resize(a2, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA), cv2.resize(b2, None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA)
                if a2.shape not in hann:
                    hann[a2.shape] = cv2.createHanningWindow((a2.shape[1], a2.shape[0]), cv2.CV_32F)
                (sx, sy), resp = cv2.phaseCorrelate(a2.astype(np.float32), b2.astype(np.float32), hann[a2.shape])
                sx, sy, hh, ww = sx * ds, sy * ds, y1 - y0, x1 - x0
                if resp >= 0.08 and (abs(sy) >= 1 or abs(sx) >= 1) and (abs(sx) < 1.5 or abs(sy) < 1.5) and abs(sy) < hh / 2 and abs(sx) < ww / 2:
                    # a rigid shift, checked on a low-pass copy (sub-pixel text aliasing fails a raw-pixel test)
                    ab, bb = cv2.GaussianBlur(a2, (0, 0), 1.5), cv2.GaussianBlur(b2, (0, 0), 1.5)
                    aw = cv2.warpAffine(ab, np.float32([[1, 0, sx / ds], [0, 1, sy / ds]]), (ab.shape[1], ab.shape[0]), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
                    my, mx = int(abs(sy / ds)) + 2, int(abs(sx / ds)) + 2
                    r0 = float(cv2.absdiff(ab, bb)[my:-my, mx:-mx].mean())
                    r1 = float(cv2.absdiff(aw, bb)[my:-my, mx:-mx].mean())
                    if r0 >= 1.0 and r1 <= 0.25 * r0:
                        is_scroll, scroll_info = True, (abs(sy) + abs(sx), hh if abs(sy) >= abs(sx) else ww)
        if area0 >= p['photo_frac'] and not is_scroll:   # a global gain / offset on block means: a fade, or the dim behind a modal
            x_, y_ = prevmu.ravel(), mu.ravel()
            (ga, gc), *_ = np.linalg.lstsq(np.vstack([x_, np.ones_like(x_)]).T, y_, rcond=None)
            res = np.abs(y_ - (ga * x_ + gc))
            expl = res <= max(2.0, 3 * 1.4826 * float(np.median(res)))
            if expl.mean() >= 0.5 and (abs(ga - 1) >= 0.02 or abs(gc) >= 2):
                is_photo, photo_dim = True, ga < 0.98 and expl.mean() < 0.97
        # animation: a block active >= anim_hits times spread over >= anim_span s within the last anim_win s
        last_act[A] = t
        motion_ep = ep is not None and (ep['scroll'] + ep['photo']) >= 0.5 * max(1, ep['frames'])
        slot = ridx % nring
        ring_n -= ring[slot]
        ring[slot] = A if not (is_scroll or is_photo or motion_ep) else False
        ring_n += ring[slot]
        rtim[slot] = t
        ridx += 1
        hot = ring_n >= p['anim_hits']
        if hot.any():
            sub, tt = ring[:, hot], rtim[:, None]
            was = anim.copy()
            anim[hot] |= (np.where(sub, tt, -np.inf).max(axis=0) - np.where(sub, tt, np.inf).min(axis=0)) >= p['anim_span']
            if (anim & ~was).any():   # it moved since anim_win s ago: the coverage fill's earlier samples ignore it too
                for m_ in masks[max(0, int((t - p['anim_win']) * 2)):]:
                    m_[0][anim & ~was] = True
        if anim.any():   # blocks leave the animated set after anim_off s without activity
            anim &= ~(t - last_act > p['anim_off'])
        if anim.any():
            if anim_since is None:
                anim_since, anim_samples = t, []
            anim_last = float(last_act[anim].max())
            ys2, xs2 = np.nonzero(anim)
            b_ = [round(xs2.min() * B / w, 3), round(ys2.min() * B / h, 3), round((xs2.max() + 1) * B / w, 3), round((ys2.max() + 1) * B / h, 3)]
            anim_box = b_ if anim_box is None else [min(anim_box[0], b_[0]), min(anim_box[1], b_[1]), max(anim_box[2], b_[2]), max(anim_box[3], b_[3])]
        elif anim_since is not None and t - anim_last >= p['anim_gap']:   # one animated event; gaps < anim_gap s bridged
            if anim_last - anim_since + p['anim_span'] >= 3.0:
                events.append(dict(kind='animated', t0=round(anim_since - p['anim_span'], 2), t1=round(anim_last, 2), box=anim_box, samples=anim_samples))
            anim_since, anim_box = None, None
        Aeff = A & ~anim
        active = bool(Aeff.any())
        if active:
            if ep is None:
                ep = dict(t0=t - 1 / fps, peak=-1e9, peak_f=None, scroll=0, scroll_acc=0.0, photo=0, photo_dim=0, frames=0, last_force=t, broad=0.0)
            ep['frames'] += 1
            ep['broad'] = max(ep['broad'], area0) if not is_scroll else ep['broad']
            q, first_quiet = 0, None
            if is_scroll:
                ep['scroll'] += 1
                ep['scroll_acc'] += scroll_info[0]
                if ep['scroll_acc'] >= p['scroll_step'] * scroll_info[1]:   # a frame per 0.6 viewport: every line fully seen once
                    ep['scroll_acc'] = 0.0
                    cand(t, g, mu, 'scroll', 1.0, 'scroll-step', find_cursor(g, cur['pos']), ev=len(events))
            if is_photo:
                ep['photo'] += 1
                ep['photo_dim'] += int(photo_dim)
            # transient peak: most different from the reference, least moving
            bnow = (cur['boxes'] if cur['t'] == t else []) + ([cur['box']] if cur['box'] else [])
            asum = float(Aeff.sum())
            if not (is_scroll or is_photo) and asum <= 0.02 * nb:   # near-still frames only
                Rc = edge_blocks(g, K['g']) & ~anim & ~bl.cells(bnow)
                rs = float(Rc.sum())
                if rs > 0 and rs - 2.0 * asum > ep['peak']:
                    ep['peak'], ep['peak_f'] = rs - 2.0 * asum, (t, f, g, mu, list(bnow))
            # a state held inside a long episode (a blank window, a spinner page, a half-loaded screen): only a little still moves
            ep['qq'], ep['hot'] = (ep.get('qq', 0) + 1, Aeff | (ep['hot'] if ep.get('hot') is not None else Aeff)) if asum <= 0.01 * nb else (0, None)
            if ep['qq'] == S and not (is_scroll or is_photo or ep['scroll'] or ep['photo']):   # scroll steps and fades have their own frames
                g0, m0 = ep.get('last') or (K['g'], K['mu'])
                d_ = news(g, mu, g0, m0) & ~ep['hot'] & ~bl.cells(bnow)
                if d_.sum() >= 2:
                    cand(t, g, mu, 'state', 1.0, 'held', bnow, an=anim | ep['hot'], ev=len(events), delta=d_)
                    ep['last'] = (g, mu)
            if t - ep['last_force'] >= p['long_ep'] and ep['peak_f'] is not None:   # no settle for long_ep s: a progress frame
                tp, fp, gp, mp, bp = ep['peak_f']
                cand(tp, gp, mp, 'progress', 0.7, 'long-episode', bp, ev=len(events))
                ep['last_force'], ep['peak'] = t, -1e9
        else:
            q += 1
            if q == 1:
                first_quiet = (t, f, g, mu, (list(cur['boxes']) if cur['t'] == t else []) + ([cur['box']] if cur['box'] else []))
            if q == S and ep is not None:
                tq, fq, gq, mq, cq = first_quiet
                R, rpx = ref_diff(fq, gq, mq, K, cq)
                moved = R.sum() >= 1 and (rpx >= 12 or R.sum() >= 2)
                if moved:
                    commit(tq, fq, gq, mq, R, ep, 'settled', cq)
                else:   # same state: re-anchor the reference so codec drift never accumulates
                    K.update(g=gq, bgr=fq, mu=mq, curf=None, cur=list(cq))
                    if ep['peak_f'] is not None and ep['frames'] >= 2 and ep['photo'] < max(2, 0.4 * ep['frames']):
                        tp, fp, gp, mp, bp = ep['peak_f']
                        Rp, _ = ref_diff(fp, gp, mp, K, bp)
                        if Rp.sum() >= 2:
                            red = red_new(fp, K['bgr'], Rp)
                            events.append(dict(kind='transient', t0=round(ep['t0'], 2), t1=round(t, 2), error=bool(red)))
                            events[-1]['cand'] = cand(tp, gp, mp, 'transient', 1.2, 'reverted', bp + find_cursor(gp), red, ev=len(events) - 1, delta=Rp)
                ep = None
        if anim_since is not None and (not anim_samples or t - anim_samples[-1] >= p['anim_sample']):   # one sample per anim_sample s
            anim_samples.append(round(t, 2))
            if len(anim_samples) > 1:
                cand(t, g, mu, 'anim-sample', 0.5, 'animated', find_cursor(g, cur['pos']), an=np.zeros_like(anim))
        anchor_step(t, f, g, mu, active)
        if int(t * 2 + 1e-6) > len(masks) - 1:   # the animation mask and the pointer every 0.5 s: the coverage fill ignores them
            masks.append((anim.copy(), (list(cur['boxes']) if cur['t'] == t else []) + ([cur['box']] if cur['box'] else []), is_scroll or is_photo or motion_ep))
        prev, prevg, prevmu = f, g, mu
        t_cpu += time.perf_counter() - c0
    if prev is None:
        return None
    if ep is not None and first_quiet is None:
        R, _ = ref_diff(prev, prevg, prevmu, K, None)
        if R.sum() >= 1:
            commit(i / fps, prev, prevg, prevmu, R, ep, 'end', [cur['box']] if cur['box'] else [])
    if anim_since is not None and i / fps - anim_since + p['anim_span'] >= 3.0:
        events.append(dict(kind='animated', t0=round(anim_since - p['anim_span'], 2), t1=round(i / fps, 2), box=anim_box, samples=anim_samples))
    for a in anc:   # a sidecar action: the frame before (a candidate) and the settled frame after (always kept)
        if a['before'] is None:
            continue
        ta, ga_, ma = a['after'] or (round(i / fps, 2), prevg, prevmu)
        a['bc'] = cand(a['before'][0], a['before'][1], a['before'][2], 'before', 1.0, 'action', [], an=np.zeros_like(anim))
        a['ac'] = cand(ta, ga_, ma, 'action', 1.0, 'action', [], an=np.zeros_like(anim), forced=True)
    for e in events:
        if e.get('kind') == 'toast?':
            e['kind'] = 'text' if e.get('box') and e['box'][3] - e['box'][1] <= 3 * B / h * max(1, round(ksc)) + 1e-6 else 'change'
        e.pop('_pre', None)
        e.pop('_pb', None)
    c1 = time.perf_counter()
    budget = int(min(float(c['maxFrames']), float(c['frames']) + float(c['framesPerMin']) * (dur or (i + 1) / fps) / 60.0))
    resample = lambda: ((n / 2.0, cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)) for n, fr in enumerate(decode(path, w, h, 2)))
    sel = choose(cands, bl, tau, tau_mu, dict(p, pulse=noise['pulse']), budget, resample, masks)
    t_sel = time.perf_counter() - c1
    return dict(size=[W, H], analysis=[w, h], fps=fps, frames_analysed=i + 1, tau=tau, tau_mu=round(tau_mu, 2), pulse=round(noise['pulse'], 1),
                budget=budget, cands=cands, kept=sel['kept'], revisits=sel['revisits'], cover=sel['cover'], fills=sel['fills'], shown=sel['shown'], events=events, anchors=anc,
                cursor=cursor_path, ms_per_frame=round(1000 * (t_cpu + t_sel) / max(1, i + 1), 2), ms_select=round(1000 * t_sel))

def choose(cands, bl, tau, tau_mu, p, budget, resample=None, masks=()):
    """Lazy greedy coverage: a block of a candidate is covered when a kept frame shows the same pixels there (directly or after a
    scroll shift); gain = weight x uncovered block value (edges = content, 3x; flat fills, the pointer and animation ~0)."""
    B = bl.B
    def value(c):   # block value: content = edges (text, icons) up to 3; a flat fill, the pointer and animation ~0
        gx, gy = cv2.Sobel(c['g'], cv2.CV_16S, 1, 0), cv2.Sobel(c['g'], cv2.CV_16S, 0, 1)
        e = bl.mean(cv2.addWeighted(cv2.convertScaleAbs(gx), 0.5, cv2.convertScaleAbs(gy), 0.5, 0))
        en = max(6.0, 0.5 * float(np.percentile(e[e > 2], 90)) if (e > 2).any() else 6.0)
        u = np.maximum(p['flat_w'], 3.0 * np.minimum(1.0, e / en))
        u[c['anim']] = 0.0
        u[bl.cells(c.get('curb') or [])] = 0.0
        c.update(u=u, cov=np.zeros_like(u, bool), upto=0)
    for c in cands:
        value(c)
    tcov = max(p['strong'], 2 * tau + 6, p.get('pulse', 0))
    memo = {}

    def lags(a, b, n):   # the n best shifts m of b against a (b[y] = a[y - m]) by normalised cross-correlation
        a, b, L = a - a.mean(), b - b.mean(), len(a)
        nf = 1 << (2 * L).bit_length()
        r = np.fft.irfft(np.conj(np.fft.rfft(a, nf)) * np.fft.rfft(b, nf), nf)
        r, lag = np.concatenate([r[nf - L + 1:], r[:L]]), np.arange(-L + 1, L)
        r[(lag == 0) | (np.abs(lag) >= L // 2)] = -np.inf
        top = np.argsort(-r)[:n]
        nr = math.sqrt(float((a * a).sum() * (b * b).sum())) or 1.0
        return [int(lag[j]) for j in top if r[j] / nr >= 0.5]

    def covered(c, k, keep=True):
        key = (id(c), id(k))
        if keep and key in memo:
            return memo[key]
        cov = np.abs(c['mu'] - k['mu']) < tau_mu + 1.0   # same block means first: the pixel test only where they hold
        if cov.any():
            cov &= bl.count(cv2.threshold(cv2.absdiff(c['g'], k['g']), tcov, 255, cv2.THRESH_BINARY)[1]) < p['blk_px']
        if cov.mean() < 0.5 and abs(c['t'] - k['t']) <= 30:   # the same content scrolled (nearby in time): shifts from row / column profiles
            ys, xs = np.nonzero(~cov)
            y0, y1, x0, x1 = ys.min() * B, (ys.max() + 1) * B, xs.min() * B, (xs.max() + 1) * B
            a_, b_ = k['g'][y0:y1, x0:x1].astype(np.float32), c['g'][y0:y1, x0:x1].astype(np.float32)
            hh, ww = c['g'].shape
            for dy, dx in [(m, 0) for m in lags(a_.mean(1), b_.mean(1), 2)] + [(0, m) for m in lags(a_.mean(0), b_.mean(0), 1)]:
                d2 = cv2.absdiff(c['g'], np.roll(k['g'], (dy, dx), (0, 1)))
                if dy > 0:
                    d2[:dy] = 255
                if dy < 0:
                    d2[dy:] = 255
                if dx > 0:
                    d2[:, :dx] = 255
                if dx < 0:
                    d2[:, dx:] = 255
                cov |= bl.count(cv2.threshold(d2, tcov, 255, cv2.THRESH_BINARY)[1]) < p['blk_px']
        if keep:
            memo[key] = cov
        return cov

    def gain(c):
        while c['upto'] < len(kept):
            c['cov'] |= covered(c, kept[c['upto']])
            c['upto'] += 1
        return c['w'] * float(c['u'][~c['cov']].sum())

    import heapq
    first = cands[0]
    first['gain'] = float(first['u'].sum())
    kept = [first]
    for c in sorted((c for c in cands[1:] if c['forced']), key=lambda c: c['t']):   # sidecar actions: kept unless a kept frame shows them
        if len(kept) < budget and gain(c) >= p['gain_min']:
            c['gain'] = gain(c)
            kept.append(c)
    rest = [c for c in cands[1:] if not any(c is k for k in kept)]
    heap = [(-float('inf'), j) for j in range(len(rest))]
    heapq.heapify(heap)
    while heap and len(kept) < budget:
        _, j = heapq.heappop(heap)
        c = rest[j]
        gnow = gain(c)
        if heap and gnow < -heap[0][0] - 1e-9:
            if gnow >= p['gain_min']:   # gains only shrink: one under the floor never comes back
                heapq.heappush(heap, (-gnow, j))
            continue
        if gnow < p['gain_min']:
            break
        c['gain'] = gnow
        kept.append(c)
    # every distinct state shown whole by ONE kept frame (a reader cannot merge two frames): the rest of the budget goes to the
    # states that no single kept frame covers to state_cover, the least covered first
    def single(c):   # the best share of the state's news (else its whole content) that one kept frame shows
        d = c['delta'] if c.get('delta') is not None and c['delta'].any() else np.ones_like(c['u'], bool)
        tot = float(c['u'][d].sum()) or 1.0
        return max((float(c['u'][d & covered(c, k)].sum()) / tot for k in sorted(kept, key=lambda k: abs(k['t'] - c['t']))[:8]), default=0.0)
    states = [c for c in cands if c['w'] > 0 and c['kind'] not in ('scroll', 'anim-sample', 'progress') and not any(c is k for k in kept)]
    while states and len(kept) < budget:
        sc = [(single(c), c) for c in states]
        v, c = min(sc, key=lambda x: x[0])
        if v >= p['state_cover']:
            break
        c['gain'] = (1 - v) * float(c['u'].sum())
        kept.append(c)
        states = [x for v_, x in sc if x is not c and v_ < p['state_cover']]
    fills = fill(kept, resample, masks, value, covered, p) if resample else []
    kept.sort(key=lambda c: c['t'])
    ids = {id(k): n for n, k in enumerate(kept)}

    def cover(c):   # the kept frame that shows this candidate's screen (itself, else the best earlier match), or None
        if id(c) in ids:
            return ids[id(c)], 1.0
        if c.get('same') is not None:
            return c['same'], 1.0
        best = (None, 0.0)
        for n, k in sorted(enumerate(kept), key=lambda x: abs(x[1]['t'] - c['t']))[:6]:
            v = float(covered(c, k).mean())
            if v > best[1]:
                best = (n, v)
        return best
    revisits = []
    for c in rest:   # an unselected state a kept earlier frame shows whole: "same as kNNN"
        if id(c) in ids or c['kind'] in ('scroll', 'anim-sample', 'progress'):
            continue
        for n, k in enumerate(kept):
            if k['t'] < c['t'] - 0.5 and covered(c, k).mean() >= 0.995:
                c['same'] = n
                revisits.append(dict(t=round(c['t'], 2), same_as=n))
                break
    def shown(t, g):   # the best share of a frame's content one kept frame shows (the pointer and animation aside)
        c = dict(t=t, g=g, mu=bl.mean(g), anim=masks[min(len(masks) - 1, int(t * 2))][0] if masks else np.zeros((bl.by, bl.bx), bool), curb=[])
        value(c)
        tot = float(c['u'].sum()) or 1.0
        return max(float(c['u'][covered(c, k, False)].sum()) / tot for k in kept)
    return dict(kept=kept, revisits=revisits, cover=cover, fills=fills, shown=shown)

def fill(kept, resample, masks, value, covered, p):
    """The safety net: a 0.5 s sample whose content no kept frame shows (>= fill_cover of its block value, the pointer and
    animation aside) is a gap; a gap run of >= detect.fillSec, or one with a clearly other screen (< fill_floor shown), gets one
    more keyframe, even over the budget, until no such run is left. Returns the fills [{t0, t1, t}]."""
    fsec, need, floor, out = float(CFG['detect']['fillSec']), p['fill_cover'], p['fill_floor'], []

    def gap(sm):
        sm['shw'], tot = 1.0, float(sm['u'].sum())
        if tot <= 0:
            return False
        sm['shw'] = 0.0
        for k in sorted(kept, key=lambda k: abs(k['t'] - sm['t'])):   # nearest first; a screen seen long before counts too
            sm['shw'] = max(sm['shw'], float(sm['u'][covered(sm, k, False)].sum()) / tot)
            if sm['shw'] >= need:   # shown: no need for the exact share
                return False
        k1 = max((k for k in kept if k['t'] < sm['t']), key=lambda k: k['t'], default=None)
        k2 = min((k for k in kept if k['t'] > sm['t']), key=lambda k: k['t'], default=None)
        if k1 is not None and k2 is not None:   # a blend of the kept frames around it (a cross-fade) is no screen of its own
            x1, x2, y = k1['mu'].ravel(), k2['mu'].ravel(), sm['mu'].ravel()
            a_ = float(np.clip(np.dot(y - x2, x1 - x2) / max(1e-6, float(np.dot(x1 - x2, x1 - x2))), 0, 1))
            if 0.05 < a_ < 0.95 and float(np.mean(np.abs(y - (a_ * x1 + (1 - a_) * x2)) < 2.5)) >= 0.97:
                sm['shw'] = need
                return False
        return True

    def close(run):
        while run and (run[-1]['t'] - run[0]['t'] + 0.5 >= fsec or min(x['shw'] for x in run) < floor):
            mid = run[len(run) // 2] if run[-1]['t'] - run[0]['t'] + 0.5 >= fsec else min(run, key=lambda x: x['shw'])
            c = dict(t=mid['t'], g=mid['g'], mu=mid['mu'], kind='coverage-fill', w=1.0, red=False, anim=mid['anim'], why='coverage fill', curb=mid['curb'], ev=None, forced=True)
            value(c)
            c['gain'] = 0.0
            kept.append(c)
            out.append(dict(t0=run[0]['t'], t1=round(run[-1]['t'] + 0.5, 2), t=mid['t'], cand=c))
            left = [x for x in run if gap(x)]
            parts, cur_ = [], []
            for x in left:   # what the new frame still leaves open, split into runs
                if cur_ and x['t'] - cur_[-1]['t'] > 0.51:
                    parts.append(cur_)
                    cur_ = []
                cur_.append(x)
            parts.append(cur_)
            run = max(parts, key=len)
            for q_ in parts:
                if q_ is not run:
                    close(q_)
    run, last, bl = [], None, None
    for t, g in resample():
        am, cb, moving = masks[min(len(masks) - 1, int(t * 2))] if masks else (None, [], False)
        if moving:   # mid-scroll or mid-fade: no screen state of its own (the scroll steps and the settled end cover it)
            close(run)
            run, last = [], None
            continue
        bl = bl or Blocks(g.shape[1], g.shape[0], KP['B'])
        sm = dict(t=t, g=g, mu=bl.mean(g), anim=am, curb=cb)
        if last is not None and not last['gap'] and cv2.countNonZero(cv2.threshold(cv2.absdiff(g, last['g']), 24, 255, cv2.THRESH_BINARY)[1]) < 8:
            sm.update(u=last['u'], shw=last['shw'], gap=False)   # the same screen as a shown sample: shown (fills only add)
        else:
            value(sm)
            sm['gap'] = gap(sm)
        isgap = sm['gap']
        last = sm
        if isgap:
            run.append(sm)
        else:
            close(run)
            run = []
    close(run)
    return out

def load_sidecar(fj, dur):
    """A sidecar action log next to the media (pokey browser.mjs record(), phoney.ps1 events): [{t, action, target, box, text}]
    with t in seconds from the recording start (`start` epoch ms, else the file time minus the duration)."""
    sp = (fj.get('sidecars') or {}).get('events')
    j = load_json(sp) if sp else None
    if not isinstance(j, dict) or not isinstance(j.get('events'), list):
        return [], None
    start = j.get('start')
    if start is None:
        try:
            start = osp.getmtime(fj.get('link') or fj['file']) * 1000 - dur * 1000
        except OSError:
            start = None
    out = []
    for e in j['events']:
        if not isinstance(e, dict):
            continue
        try:   # one bad row is skipped, never the whole video
            t = float(e['t']) if e.get('t') is not None else (float(e['at']) - float(start)) / 1000 if e.get('at') is not None and start is not None else None
        except (TypeError, ValueError):
            continue
        if t is None or not (-0.5 <= t <= (dur or 1e9) + 0.5):
            continue
        box, size = e.get('box'), j.get('size')
        if isinstance(box, list) and len(box) == 4 and isinstance(size, list) and len(size) == 2 and all(isinstance(z, (int, float)) and z > 0 for z in size + box[2:]):   # [x, y, w, h] px -> fractions
            box = [round(box[0] / size[0], 3), round(box[1] / size[1], 3), round((box[0] + box[2]) / size[0], 3), round((box[1] + box[3]) / size[1], 3)]
        else:
            box = None
        out.append({'t': round(max(0.0, float(t)), 2), 'action': str(e.get('action') or 'action'), 'target': clip(str(e.get('target') or ''), 120),
                    'text': clip(str(e.get('text') or ''), 120), 'box': box})
    return sorted(out, key=lambda e: e['t']), str(j.get('source') or 'sidecar')

def detect(path, info, out_dir, fj=None):
    """The detect stage: keyframes() + sidecar actions -> detect.json events (before / after / peak frames, kinds, durations,
    revisits) and the keyframes as JPEGs (native resolution, long edge <= 2000 px) that vidy reads."""
    need_cv()
    W, H = info['width'] or 1280, info['height'] or 720
    dur = float(info.get('duration') or 0)
    side, src = load_sidecar(fj or {}, dur)
    r = keyframes(path, W, H, dur, [e['t'] for e in side])
    if r is None:
        return {'fps': float(CFG['detect']['fps']), 'duration': dur, 'events': [], 'keyframes': [], 'counts': {}, 'reason': 'no frames decoded'}
    dur = dur or r['frames_analysed'] / r['fps']
    kept, cands = r['kept'], r['cands']
    kref = lambda n: f'k{n:03d}' if n is not None else None
    kf = []
    vc = cv2.VideoCapture(path)
    for n, c in enumerate(kept):
        fr = grab(path, c['t'], vc)
        ev = r['events'][c['ev']] if c.get('ev') is not None and c['ev'] < len(r['events']) else None
        kind = c['kind'] if c['kind'] in ('start', 'scroll', 'action', 'before', 'anim-sample', 'progress', 'intermediate') or ev is None else ev['kind']
        kf.append({'ref': kref(n), 't': round(c['t'], 2), 'kind': kind, 'gain': round(c.get('gain', 0), 1),
                   'file': save_jpeg(fr, osp.join(out_dir, 'keyframes', f"{kref(n)}-{int(round(c['t'] * 100)):06d}.jpg"), VIDY_EDGE) if fr is not None else None})   # by time: a re-detect never overwrites a frame vidy read
    vc.release()
    rows = []

    def before_of(t0):   # the screen before: the last keyframe at or before the start
        n = max((m for m, k in enumerate(kept) if k['t'] <= t0 + 1e-6), default=None)
        return kref(n)

    def frames_of(ci, t0, peak=None):
        out = {'before': before_of(t0)}
        if ci is not None:
            n, v = r['cover'](cands[ci])
            if n is not None and v >= 0.9:
                out['after'] = kref(n)
                if id(cands[ci]) not in {id(k) for k in kept}:
                    out['same'] = True
        if peak is not None:
            n, v = r['cover'](cands[peak])
            if n is not None and v >= 0.9 and kref(n) != out.get('after'):
                out['peak'] = kref(n)
        return out
    for e in r['events']:
        if e['kind'] == 'start':
            continue
        row = {'t': e['t0'], 't_end': e['t1'], 'kind': {'page': 'page-change'}.get(e['kind'], e['kind']), 'source': 'detect'}
        if e.get('box'):
            row['box'] = e['box']
        if e.get('area') is not None:
            row['frac'] = e['area']
        if e.get('error'):
            row['error'] = True
        if e.get('shown_until'):
            row['shown_until'] = e['shown_until']
        if e['kind'] == 'animated':
            row['dur'] = round(max(0.0, e['t1'] - e['t0']), 1)
            row['frames'] = {'before': before_of(e['t0'])}
            during = [kref(n) for n, k in enumerate(kept) if e['t0'] <= k['t'] <= e['t1'] + 0.5]
            if during:
                row['frames']['during'] = during[:3]
            after = next((kref(n) for n, k in enumerate(kept) if k['t'] > e['t1']), None)
            if after:
                row['frames']['after'] = after
        else:
            row['frames'] = frames_of(e.get('cand'), e['t0'], e.get('peak'))
        rows.append(row)
    for a, sa in zip(r['anchors'], side):   # sidecar actions: real clicks, typed text, screens
        if a['before'] is None:
            continue
        row = {'t': sa['t'], 't_end': round(cands[a['ac']]['t'], 2), 'kind': sa['action'], 'source': src, 'click': sa['action'] in ('click', 'tap')}
        row.update({k: sa[k] for k in ('target', 'text', 'box') if sa.get(k)})
        row['frames'] = {'before': frames_of(a['bc'], sa['t']).get('after') or before_of(sa['t'])}
        n, v = r['cover'](cands[a['ac']])
        if n is not None and v >= 0.9:
            row['frames']['after'] = kref(n)
        rows.append(row)
    moves, cp = [], r['cursor']
    for k, (t, x, y) in enumerate(cp):   # pointer moves: bursts split at 0.5 s pauses
        if not moves or t - moves[-1]['t_end'] > 0.5:
            moves.append({'t': t, 't_end': t, 'kind': 'cursor', 'from': list(cp[k - 1][1:]) if k and t - cp[k - 1][0] <= 1.0 else [x, y], 'to': [x, y], 'source': 'detect'})
        moves[-1].update(t_end=t, to=[x, y])
    for row in rows:   # a change right after the pointer stopped near it: a click, guessed (a sidecar says so for real)
        if row['source'] != 'detect' or row['kind'] in ('scroll', 'animated', 'transient'):
            continue
        m = max((m for m in moves if m['t_end'] <= row['t'] + 0.05 and row['t'] - m['t_end'] <= 0.6), key=lambda m: m['t_end'], default=None)
        b = row.get('box')
        if m and (row['kind'] == 'page-change' or (b and b[0] - 0.05 <= m['to'][0] <= b[2] + 0.05 and b[1] - 0.05 <= m['to'][1] <= b[3] + 0.05)):
            row['click'], row['cursor'] = 'guess', m['to']
    rows += moves
    marks = sorted([0.0, dur] + [x['t'] for x in rows] + [x['t_end'] for x in rows])
    for a, b in zip(marks, marks[1:]):
        if b - a >= float(CFG['detect']['idleSec']) and not any(x['t'] < b and x['t_end'] > a for x in rows):
            rows.append({'t': round(a, 2), 't_end': round(b, 2), 'kind': 'idle', 'source': 'detect'})
    rows.sort(key=lambda x: (x['t'], x['kind']))
    for n, row in enumerate(rows, 1):
        row['id'] = f'e{n:03d}'
    for x in r['revisits']:
        x['same_as'] = kref(x['same_as'])
    return {'fps': r['fps'], 'scaled': r['analysis'], 'duration': dur, 'events': rows, 'keyframes': kf, 'revisits': r['revisits'], 'budget': r['budget'],
            'noise': {'tau': r['tau'], 'tauMu': r['tau_mu'], 'pulse': r['pulse']}, 'msPerFrame': r['ms_per_frame'], 'sidecar': src,
            'counts': {k: sum(1 for x in rows if x['kind'] == k) for k in sorted({x['kind'] for x in rows})}}

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

# ---- vision: the keyframes vidy reads (Read tool, batches) and writes back as screen text + a UI line each; no model call here
VIDY_EDGE = 2000   # the frame vidy reads: native resolution, long edge <= 2000 px

def segments_of(dur):
    n = max(1, -(-int(dur) // max(1, int(CFG['vidy']['segmentSec'])))) if dur else 1
    step = dur / n if dur else 0
    return [(round(i * step, 2), round((i + 1) * step, 2)) for i in range(n)]

def vision_targets(det, fj):
    """The detector's keyframes as they are (full frames, native size up to 2000 px, the budget already applied), each in its
    segment; vidy reads only these."""
    if fj.get('kind') == 'image':
        return [{'ref': 'image', 't': 0, 'file': fj['file'], 'segment': 1}]
    segs = segments_of(float(det.get('duration') or 0))
    return [{'ref': k['ref'], 't': k['t'], 'file': k['file'], 'kind': k.get('kind'), 'segment': next((i for i, (s, e) in enumerate(segs, 1) if s <= k['t'] < e), len(segs))}
            for k in det.get('keyframes') or [] if k.get('file') and osp.isfile(k['file'])]

def vision(det, fj, out_dir):
    tg = vision_targets(det, fj)
    return {'items': [], 'pending': tg, 'segments': len(segments_of(float(det.get('duration') or 0))), 'maxFrames': len(tg), 'budget': det.get('budget'),
            'reason': f'{len(tg)} keyframes unread: run vidy' if tg else 'no keyframes'}

def image_tokens(p):
    """Claude's image input cost: w * h / 750 after its resize to <= 1568 px long edge and <= 1.15 MP."""
    import cv2
    img = cv2.imread(p)
    if img is None:
        return 0
    h, w = img.shape[:2]
    s = min(1.0, 1568 / max(h, w), (1150000 / (w * h)) ** 0.5)
    return int(w * s * h * s / 750) + 1

def frames(key, segment=None):
    ix = ix_dir(key)
    vi = load_json(osp.join(ix, 'vision.json') if ix else '')
    if vi is None:
        raise FileNotFoundError(f'no index for {key}: run pokey.ps1 evidence index <link> first')
    pend, c = vi.get('pending') or [], CFG['vidy']
    nseg, bat = int(vi.get('segments') or 1), max(1, int(c['batch']))
    lines = [f"# {key}: {len(pend)} keyframes unread, {len(vi.get('items', []))} read · {nseg} segment(s) · the detector's {vi.get('maxFrames', len(pend))} keyframes"
             f" (read only these) · read {bat} per turn (parallel Read calls, time order)"]
    if nseg > 1 and segment is None:
        lines.append(f'segments: one vidy per segment (pokey.ps1 evidence frames {key} -Segment <n>), then one merge of the timeline and answer')
    for sg in ([int(segment)] if segment else range(1, nseg + 1)):
        mine = [x for x in pend if int(x.get('segment') or 1) == sg]
        if nseg > 1:
            lines.append(f'## segment {sg}/{nseg}: {len(mine)} unread')
        for n in range(0, len(mine), bat):
            lines.append(f'batch {n // bat + 1}:')
            lines += [f"{x['ref']} {mmss(x['t'])}: {x['file']}" for x in mine[n:n + bat]]
    lines.append(f"items: {osp.join(ix, 'vision-items' + (f'-s{segment}' if segment else '') + '.json')} -> pokey.ps1 evidence write-vision {key} -File <items>")
    return lines

def write_vision(key, items_file, model=None, tokens=None):
    ix = ix_dir(key)
    old = load_json(osp.join(ix, 'vision.json') if ix else '')
    if old is None:
        raise FileNotFoundError(f'no index for {key}: run pokey.ps1 evidence index <link> first')
    rows = load_json(items_file)
    rows = rows.get('items') if isinstance(rows, dict) else rows
    if not isinstance(rows, list) or not rows:
        raise ValueError(f'{items_file}: a JSON list of {{ref, t, text, ui, frames}} is required')
    items, read = [], []
    for n, r in enumerate(rows, 1):
        fr = [str(p) for p in (r.get('frames') or [])] if isinstance(r, dict) else []
        if not fr or not (str(r.get('text') or '').strip() or str(r.get('ui') or '').strip()):
            raise ValueError(f'{items_file} item {n}: text or ui, and the frames read, are required')
        gone = [p for p in fr if not osp.isfile(p)]
        if gone:
            raise ValueError(f'{items_file} item {n}: frame not found: {gone[0]}')
        read += [p for p in fr if p not in read]
        items.append({'ref': str(r.get('ref') or f'f{n:02d}'), 't': round(parse_time(r.get('t', 0)), 2), 'text': str(r.get('text') or '').strip(),
                      'ui': clip(str(r.get('ui') or ''), 300), 'frames': fr})
    same = lambda p: osp.normcase(osp.abspath(p))
    img, kfs = sum(image_tokens(p) for p in read), {same(x['file']) for x in (load_json(osp.join(ix, 'detect.json')) or {}).get('keyframes') or [] if x.get('file')}
    extra = [p for p in read if kfs and same(p) not in kfs]   # vidy reads the detector's keyframes only
    lk = os_lock(osp.join(ix, 'vision.json.lock'), 120)   # segment vidys write one after another: merge, never overwrite
    if not lk:
        raise RuntimeError('vision.json is locked by another write-vision for 120 s')
    try:
        old = load_json(osp.join(ix, 'vision.json')) or old
        keep = [x for x in old.get('items') or [] if (x['ref'], x['t']) not in {(y['ref'], y['t']) for y in items}]
        seen = {same(p) for x in old.get('items') or [] for p in x.get('frames') or []}
        new = [p for p in read if same(p) not in seen]   # a frame read again is counted once
        done = seen | {same(p) for p in read}
        res = dict(old, by='vidy', model=model or CFG['vidy']['model'], items=sorted(keep + items, key=lambda x: x['t']),
                   framesRead=len(done), imageTokens=int(old.get('imageTokens') or 0) + sum(image_tokens(p) for p in new),
                   tokens=(int(old.get('tokens') or 0) + int(tokens)) if tokens else old.get('tokens'),
                   pending=[x for x in old.get('pending') or [] if same(x['file']) not in done])
        save_json(osp.join(ix, 'vision.json'), res)
    finally:
        lk.close()
    b = build(key)
    return {'key': key, 'items': len(items), 'framesRead': len(read), 'maxFrames': int(res.get('maxFrames') or 0), 'extra': len(extra), 'imageTokens': img,
            'tokens': int(tokens) if tokens else None, 'model': res['model'], 'unread': len(res['pending']), 'index': b['index']}

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
    click = f"click? {pt(r['cursor'])} -> " if r.get('click') == 'guess' else ('click ' if r.get('click') and r['kind'] not in ('click', 'tap') else '')
    what = f"{r['kind']} {mmss(r['t'])}-{mmss(r['t_end'])} ({r['dur']:g} s)" if r.get('dur') is not None else r['kind']
    said = ''.join(f' "{r[k]}"' for k in ('target', 'text') if r.get(k))
    src = '' if r.get('source', 'detect') == 'detect' else f" [{r['source']}]"
    fr = r.get('frames') or {}
    refs = (f" {fr.get('before') or '-'}->{fr['after']}" if fr.get('after') else '') + (' (same)' if fr.get('same') else '') +         (f" peak {fr['peak']}" if fr.get('peak') else '') + (f" during {','.join(fr['during'])}" if fr.get('during') else '')
    return f"{mmss(r['t'])} {click}{what}{said}{where}{' error' if r.get('error') else ''}{src}{refs}"

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
        cuts = [r['t'] for r in rows if r['kind'] in ('page-change', 'modal')] + [(r['t'] + r['t_end']) / 2 for r in rows if r['kind'] == 'idle']
        spans = chunks_of(dur, cuts)
    vis = {f"{x['ref']}@{x['t']}": x for x in vi.get('items', [])}
    pend = vi.get('pending') or []
    def rel(p):
        try:
            return osp.relpath(p, ix)
        except ValueError:   # another drive
            return p
    out = []
    for n, (s, e) in enumerate(spans, 1):
        inside = lambda x: (s <= x['t'] < e) or (s == e == 0) or (n == len(spans) and x['t'] >= s)
        evs = [r for r in rows if inside(r)]
        curs = [r for r in det.get('events', []) if r['kind'] == 'cursor' and inside(r)]
        say = ' '.join(x['text'] for x in tr.get('segments', []) if inside(x))
        screen = [vis[x]['text'] for x in vis if inside(vis[x])]
        ui = [vis[x]['ui'] for x in vis if inside(vis[x]) and vis[x].get('ui')]
        unread = [f"{x['ref']} {mmss(x['t'])} {rel(x['file'])}" for x in pend if inside(x)]
        flags = sorted({m.group(1).lower() for m in ERR_RE.finditer(say + ' ' + ' '.join(screen))})
        out.append({'id': f'c{n:02d}', 'start': s, 'end': e, 'say': clip(say, 400), 'screen': clip(' | '.join(screen), 300), 'ui': clip(' | '.join(ui), 200), 'unread': unread,
                    'events': [ev_line(r) for r in evs if r['kind'] != 'idle'][:12], 'more': max(0, len([r for r in evs if r['kind'] != 'idle']) - 12),
                    'cursorMoves': len(curs), 'flags': flags, 'error': bool(flags)})
    meta = fj.get('meta') or {}
    mtxt = ' · '.join(f'{k} {meta[k]}' for k in ('type', 'browser', 'os', 'screen', 'date', 'capturedOn', 'name') if meta.get(k))
    head = [f"# media {key} · {fj.get('fetcher', '?')} · {fj.get('kind', '?')}" + (f" · {mmss(dur)}" if dur else '') + (f" · {info.get('width')}x{info.get('height')}" if info.get('width') else ''),
            f"link: {fj.get('link', '')}" + (f' · {mtxt}' if mtxt else ''),
            f"events: {', '.join(f'{k} {v}' for k, v in (det.get('counts') or {}).items()) or 'none'}{' · ignored: ' + str(len(det['tickers'])) + ' ticking cells (a clock)' if det.get('tickers') else ''} (click? = guessed from the pointer; boxes and points are fractions of the frame)",
            f"speech: {tr.get('source')}{' (' + tr['reason'] + ')' if tr.get('reason') else ''} · screen text: {len(vi.get('items', []))} frames" +
            (f" (vidy {vi.get('model')})" if vi.get('by') == 'vidy' else '') + (f" · {len(pend)} keyframes unread: run vidy (pokey.ps1 evidence frames {key}; paths under {ix})" if pend else
            (f" ({vi['reason']})" if vi.get('reason') and not vi.get('items') else '')),
            f"read: pokey.ps1 evidence read-chunk {key} <start> <end> | -At <m:ss> -Window <s> | -AroundError", '']
    def row(c):
        r = [f"## {c['id']} {mmss(c['start'])}-{mmss(c['end'])}{' [error: ' + ', '.join(c['flags']) + ']' if c['flags'] else ''}"]
        if c['say']:
            r.append(f"say: {c['say']}")
        if c['screen']:
            r.append(f"screen: {c['screen']}")
        if c['ui']:
            r.append(f"ui: {c['ui']}")
        if c['unread']:
            r.append(f"keyframes (unread: run vidy): {' · '.join(c['unread'])}")
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
        return [f'image {key}: {p}'] + [f"screen: {x['text']}" for x in vi.get('items', [])] + [f"unread image: {x['file']} (run vidy)" for x in vi.get('pending') or []]
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
        lines += [f"unread {x['ref']} {mmss(x['t'])}: {x['file']} (run vidy)" for x in vi.get('pending') or [] if s <= x['t'] <= e]
        ts = [s] + [k['t'] for k in det.get('keyframes') or [] if s < k['t'] < e] + [max(s, e - 0.1)]   # the detector's keyframes in the window
        pick = []
        for t in ts:
            if not pick or t - pick[-1] >= 1.0:
                pick.append(t)
        n = max(1, int(frames))
        if len(pick) > n:
            pick = [pick[round(i * (len(pick) - 1) / (n - 1))] for i in range(n)] if n > 1 else [pick[-1]]
        elif len(pick) < n and n > 1:   # dense reading (vidy's verify phase): evenly spaced frames fill the rest
            pick = sorted(set(pick) | {round(s + i * (e - s) / (n - 1), 2) for i in range(n)})[:max(n, len(pick))]
            pick = [pick[round(i * (len(pick) - 1) / (n - 1))] for i in range(n)]
        import cv2
        cap = cv2.VideoCapture(fj['file'])
        for t in pick:
            fr = grab(fj['file'], t, cap)
            if fr is not None:
                lines.append(f"frame {mmss(t)}: {save_jpeg(fr, osp.join(out, f'{key}-{int(t * 10):06d}.jpg'), int(size))}")
        cap.release()
    return lines

# ---- bench: synthetic clips with exact ground truth, the regression corpus, feedback (vidy's verify phase)
SYNTH = 1   # bump when a synthetic clip changes: cached clips are rebuilt
KEY_ITEMS = ('toast:', 'modal:', 'val:', 'st:', 'sel:', 'badge:4', 'r7:amt', 'r15:appr', 'step:Step 2', 'banner', 'det:', 'row:new', 'Rep:', 'Bra:', 'Cha:', 'title:')
SYNTH_Q = ('scroll', 'toast', 'modal', 'typing', 'page', 'dark')   # also encoded at crf 36 (q-<name>)

def synth(out, name, crf=None):
    """One synthetic screen recording (x264, 30 fps) + <name>.gt.json {fps, size, frames, items: {id: [[f0, f1, box]]}, events}.
    An item (a text line, a toast, a typed value) is visible only fully drawn, settled-opaque and inside the viewport."""
    need_cv()
    F, FPS = cv2.FONT_HERSHEY_SIMPLEX, 30
    vis = {}

    def add(f, iid, box):
        vis.setdefault(iid, {})[f] = [int(v) for v in box]

    def text(img, s_, x, y, sc=0.6, col=(40, 40, 40), th=1):
        cv2.putText(img, s_, (int(x), int(y)), F, sc, col, th, cv2.LINE_AA)
        (tw, th_), b = cv2.getTextSize(s_, F, sc, th)
        return [int(x), int(y - th_ - 2), int(x + tw), int(y + b)]

    def pointer(img, x, y):
        q = (np.array([[0, 0], [0, 17], [4, 13], [7, 20], [10, 19], [7, 12], [12, 12]], np.float32) + [x, y]).astype(np.int32)
        cv2.fillPoly(img, [q], (255, 255, 255), cv2.LINE_AA)
        cv2.polylines(img, [q], True, (0, 0, 0), 1, cv2.LINE_AA)

    ease = lambda u: min(1, max(0, u)) ** 2 * (3 - 2 * min(1, max(0, u)))
    lerp = lambda a, b, u: a + (b - a) * u

    def at(t, keys):
        if t <= keys[0][0]:
            return keys[0][1:]
        for (t0, x0, y0), (t1, x1, y1) in zip(keys, keys[1:]):
            if t0 <= t <= t1:
                u = ease((t - t0) / max(1e-6, t1 - t0))
                return lerp(x0, x1, u), lerp(y0, y1, u)
        return keys[-1][1:]

    def chrome(img, title, W, f, dark=False, rec=True):
        H = img.shape[0]
        cv2.rectangle(img, (0, 0), (W, 56), (45, 45, 48) if dark else (60, 90, 160), -1)
        b = text(img, title, 24, 38, 0.9, (230, 230, 230) if dark else (255, 255, 255), 2)
        if rec:
            add(f, 'title:' + title, b)
        cv2.rectangle(img, (0, 56), (220, H), (40, 40, 42) if dark else (232, 234, 238), -1)
        for k, m in enumerate(['Dashboard', 'Orders', 'Invoices', 'Drivers', 'Settings']):
            bb = text(img, m, 24, 100 + 40 * k, 0.6, (150, 150, 150) if dark else (60, 60, 60))
            if rec:
                add(f, 'menu:' + m, bb)

    blank = lambda W, H, dark=False: np.full((H, W, 3), (30, 30, 30) if dark else (250, 250, 250), np.uint8)

    def lines(img, f, pre, n, y0=110, rec=True):
        for k in range(n):
            b = text(img, f'{pre} {k + 1:02d}: Order {2000 + k * 7} - Depot road 6B - GBP {113 + k * 13.5:.2f}', 260, y0 + k * 34)
            if rec and b[1] >= 56 and b[3] <= img.shape[0]:
                add(f, f'{pre}:{k + 1}', b)

    W, H, dur, crf0, events = 1920, 1080, 15, 24, []
    if name == 'scroll':
        doc = np.full((4300, W - 220, 3), 250, np.uint8)
        rows = []
        for k in range(120):
            s_ = f'Row {k + 1:03d}: Order {2000 + k * 7} - Depot road 6B - GBP {113 + k * 13.5:.2f}'
            cv2.putText(doc, s_, (40, 60 + k * 34), F, 0.6, (40, 40, 40), 1, cv2.LINE_AA)
            (tw, th_), b = cv2.getTextSize(s_, F, 0.6, 1)
            rows.append((k + 1, 40, 60 + k * 34 - th_ - 2, 40 + tw, 60 + k * 34 + b))
        off = lambda t: 0 if t < 3 else 1300 * ease((t - 3) / 4) if t < 7 else 1300 if t < 10 else 1300 + 750 * (t - 10) if t < 12 else 2800 if t < 16 else 2800 * (1 - ease((t - 16) / 1.5)) if t < 17.5 else 0
        keys = [(0, 900, 600), (2, 1200, 500), (20, 1200, 500)]

        def r(t, f):
            img, o = blank(W, H), int(round(off(t)))
            img[56:H, 220:W] = doc[o:o + H - 56]
            chrome(img, 'Orders', W, f)
            for k, x0, y0, x1, y1 in rows:
                if y0 - o + 56 >= 56 and y1 - o + 56 <= H:
                    add(f, f'row:{k}', [x0 + 220, y0 - o + 56, x1 + 220, y1 - o + 56])
            pointer(img, *at(t, keys))
            return img
        dur, events = 20, [['scroll', 3, 7], ['scroll', 10, 12], ['scroll', 16, 17.5]]
    elif name == 'toast':
        keys = [(0, 700, 700), (4.3, 1500, 300), (5, 1500, 300), (9, 900, 600), (10.7, 1000, 200), (15, 1000, 200)]

        def r(t, f):
            img = blank(W, H)
            chrome(img, 'Invoices', W, f)
            lines(img, f, 'Inv', 18)
            cv2.rectangle(img, (1400, 270), (1600, 320), (60, 140, 60), -1)
            add(f, 'btn:save', text(img, 'Save', 1470, 303, 0.7, (255, 255, 255), 2))
            for t0, t1, fin, fout, box, msg, col, iid in ((5.0, 8.3, 0.25, 0.3, None, 'Invoice 919 saved successfully', (50, 50, 50), 'toast:saved'),
                                                         (11.0, 12.2, 0.15, 0.15, (W - 520, 70), 'Error: saving failed (code 500)', (40, 40, 200), 'toast:error')):
                if t0 <= t < t1:
                    if box is None:   # slides in from the right, stays, fades
                        x = int(lerp(W, W - 460, ease((t - t0) / fin)))
                        a, (bx, by_) = (1.0 if t < t1 - fout else (t1 - t) / fout), (x, H - 120)
                        ok = t >= t0 + fin
                    else:
                        a, (bx, by_) = min(1, (t - t0) / fin, (t1 - t) / fout), box
                        ok = True
                    ov = img.copy()
                    cv2.rectangle(ov, (bx, by_), (bx + (420 if box is None else 480), by_ + (70 if box is None else 60)), col, -1)
                    bb = text(ov, msg, bx + 20, by_ + (43 if box is None else 38), 0.65, (255, 255, 255))
                    img[:] = cv2.addWeighted(ov, a, img, 1 - a, 0)
                    if a >= 0.95 and ok:
                        add(f, iid, bb)
            pointer(img, *at(t, keys))
            return img
        events = [['toast', 5.0, 8.3], ['toast', 11.0, 12.2]]
    elif name == 'modal':
        keys = [(0, 600, 800), (3.5, 1500, 290), (4, 1500, 290), (6, 960, 560), (6.8, 960, 560), (8.5, 1100, 700), (9, 1100, 700), (15, 800, 900)]

        def r(t, f):
            img = blank(W, H)
            chrome(img, 'Drivers', W, f)
            lines(img, f, 'Drv', 15, rec=not (4 <= t < 9.15))
            if t >= 9.15:
                add(f, 'row:new', text(img, 'Drv 16: New driver Salvatori added', 260, 620, 0.6, (20, 120, 20)))
            cv2.rectangle(img, (1400, 270), (1600, 320), (160, 90, 60), -1)
            b = text(img, 'Add driver', 1440, 303, 0.7, (255, 255, 255), 2)
            if not (4 <= t < 9.15):
                add(f, 'btn:add', b)
            if 4 <= t < 9.15:
                u = ease((t - 4) / 0.2) if t < 9 else 1 - (t - 9) / 0.15
                m = (img.astype(np.float32) * (1 - 0.5 * u)).astype(np.uint8)
                sc = 0.9 + 0.1 * u
                mw, mh = int(700 * sc), int(420 * sc)
                x0, y0 = (W - mw) // 2, (H - mh) // 2
                cv2.rectangle(m, (x0, y0), (x0 + mw, y0 + mh), (255, 255, 255), -1)
                if u >= 0.95:
                    add(f, 'modal:title', text(m, 'Add driver', x0 + 30, y0 + 50, 0.9, (30, 30, 30), 2))
                    add(f, 'modal:name', text(m, 'Name:  Salvatori', x0 + 30, y0 + 130, 0.65))
                    add(f, 'modal:lic', text(m, 'Licence no:', x0 + 30, y0 + 190, 0.65))
                    if t >= 7:
                        add(f, 'modal:err', text(m, 'Licence no is a required field', x0 + 30, y0 + 230, 0.6, (30, 30, 210)))
                    cv2.rectangle(m, (x0 + mw - 180, y0 + mh - 80), (x0 + mw - 30, y0 + mh - 30), (60, 140, 60), -1)
                    add(f, 'modal:ok', text(m, 'Save', x0 + mw - 135, y0 + mh - 45, 0.7, (255, 255, 255), 2))
                img = m if t < 9 else cv2.addWeighted(m, u, img, 1 - u, 0)
            pointer(img, *at(t, keys))
            return img
        events = [['modal', 4, 9.15]]
    elif name == 'typing':
        s1, s2, rng = 'qa.tester@example.com', '********', np.random.default_rng(1)
        t1, t2 = [2.3], [7.0]
        for _ in s1[1:]:
            t1.append(t1[-1] + float(rng.uniform(0.08, 0.22)))
        for _ in s2[1:]:
            t2.append(t2[-1] + float(rng.uniform(0.08, 0.2)))
        keys = [(0, 1200, 800), (1.5, 700, 342), (6.4, 700, 342), (6.7, 700, 442), (15, 700, 442)]

        def r(t, f):
            img = blank(W, H)
            chrome(img, 'Sign in', W, f)
            add(f, 'lbl:user', text(img, 'User name', 500, 320))
            add(f, 'lbl:pw', text(img, 'Password', 500, 420))
            for y in (330, 430):
                cv2.rectangle(img, (500, y), (1000, y + 40), (150, 150, 150), 1)
            n1, n2 = sum(1 for x in t1 if x <= t), sum(1 for x in t2 if x <= t)
            if n1:
                b = text(img, s1[:n1], 510, 358, 0.65)
                if n1 == len(s1):
                    add(f, 'val:user', b)
            if n2:
                b = text(img, s2[:n2], 510, 458, 0.65)
                if n2 == len(s2):
                    add(f, 'val:pw', b)
            foc = 1 if 2.0 <= t < 6.7 else (2 if t >= 6.7 else 0)
            if foc and int(t / 0.53) % 2 == 0:   # a blinking caret
                s_, y = (s1[:n1], 336) if foc == 1 else (s2[:n2], 436)
                x = 510 + (cv2.getTextSize(s_, F, 0.65, 1)[0][0] if s_ else 0) + 2
                cv2.line(img, (x, y), (x, y + 28), (20, 20, 20), 1)
            pointer(img, *at(t, keys))
            return img
        events = [['typing', 2.3, t1[-1]], ['typing', 7.0, t2[-1]]]
    elif name == 'spinner':
        keys = [(0, 900, 700), (1.6, 300, 150), (2, 300, 150), (6, 1100, 800), (40, 1100, 800)]

        def r(t, f):
            img = blank(W, H)
            chrome(img, 'Reports', W, f)
            cv2.rectangle(img, (260, 120), (420, 170), (60, 90, 160), -1)
            add(f, 'btn:load', text(img, 'Load', 300, 153, 0.7, (255, 255, 255), 2))
            st = 'Step 1 of 3' if t < 17 else 'Step 2 of 3'
            b = text(img, st, 1650, 100, 0.6, (90, 90, 90))
            if 2 <= t < 32:
                add(f, 'step:' + st, b)
                cv2.rectangle(img, (260, 200), (1860, 260), (230, 240, 250), -1)
                add(f, 'banner', text(img, 'Loading report, please wait...', 340, 238, 0.65, (90, 60, 30)))
                cv2.ellipse(img, (300, 230), (16, 16), (t * 360) % 360, 0, 270, (200, 120, 40), 3, cv2.LINE_AA)
                for k in range(8):   # skeleton shimmer
                    y, cx = 300 + k * 50, int(260 + ((t * 600 + k * 90) % 1600))
                    cv2.rectangle(img, (260, y), (1600, y + 26), (225, 225, 225), -1)
                    cv2.rectangle(img, (max(260, cx - 80), y), (min(1600, cx + 80), y + 26), (240, 240, 240), -1)
            elif t >= 32:
                lines(img, f, 'Rep', 10, y0=230)
            pointer(img, *at(t, keys))
            return img
        dur, events = 40, [['loading', 2, 32], ['change', 17, 17]]
    elif name == 'page':
        keys = [(0, 900, 700), (3.6, 1450, 295), (4, 1450, 295), (5.5, 1200, 600), (7.6, 300, 140), (8, 300, 140), (12, 600, 500)]

        def r(t, f):
            img = blank(W, H)
            if t < 4 or t >= 8.1:
                chrome(img, 'Orders', W, f)
                lines(img, f, 'Ord', 20)
                cv2.rectangle(img, (1400, 270), (1600, 320), (60, 90, 160), -1)
                add(f, 'btn:open', text(img, 'Open 2001', 1420, 303, 0.7, (255, 255, 255), 2))
            elif t >= 4.1:   # 4.0-4.1: a white flash
                chrome(img, 'Order 2001', W, f, rec=t >= 5.0)
                if t >= 4.4:
                    for k, s_ in enumerate(['Customer: Example Foods Ltd', 'Collection: 21/10/2026 09:00 AB1 2CD', 'Delivery: 21/10/2026 17:00 EF3 4GH', 'Rate: GBP 604.80', 'Status: Approved']):
                        b = text(img, s_, 260, 120 + 40 * k, 0.7, (30, 30, 30))
                        if t >= 5.0:
                            add(f, f'det:{k}', b)
                if t >= 5.0:
                    cv2.rectangle(img, (1000, 120), (1700, 600), (180, 200, 220), -1)
                    cv2.line(img, (1000, 120), (1700, 600), (120, 140, 160), 3)
                    add(f, 'det:map', text(img, 'Route map', 1300, 370, 0.9, (60, 60, 60), 2))
                cv2.rectangle(img, (260, 360), (420, 400), (120, 120, 120), -1)
                b = text(img, 'Back', 300, 388, 0.7, (255, 255, 255), 2)
                if t >= 5.0:
                    add(f, 'btn:back', b)
            pointer(img, *at(t, keys))
            return img
        dur, events = 12, [['page', 4, 5.0], ['page', 8, 8.1]]
    elif name == 'cursor':
        rng = np.random.default_rng(3)
        pts = [(0, 900, 600)] + [(k * 0.5, float(rng.uniform(250, 1850)), float(rng.uniform(80, 1050))) for k in range(1, 30)]

        def r(t, f):
            img = blank(W, H)
            chrome(img, 'Dashboard', W, f)
            lines(img, f, 'Dash', 25)
            pointer(img, *at(t, pts))
            return img
    elif name == 'dark':
        keys = [(0, 900, 700), (3.6, 1500, 295), (4, 1500, 295), (7.6, 700, 245), (8, 700, 245), (15, 900, 900)]

        def r(t, f):
            img = blank(W, H, True)
            chrome(img, 'Settings', W, f, dark=True)
            for k in range(12):
                y0 = 110 + k * 40
                if k == 3 and t >= 8:   # a selected row: +10 grey levels
                    cv2.rectangle(img, (240, y0 - 26), (1300, y0 + 12), (40, 40, 40), -1)
                add(f, f'set:{k}', text(img, f'Setting {k + 1:02d}: notifications for depot {k + 3}', 260, y0, 0.6, (110, 110, 110)))
            if t >= 8:
                add(f, 'sel:row4', [240, 204, 1300, 242])
            st = 'Saving...' if 4 <= t < 5 else ('Saved' if t >= 5 else '')
            if st:
                add(f, 'st:' + st, text(img, st, 1640, 300, 0.6, (90, 90, 90)))
            cv2.rectangle(img, (1400, 270), (1600, 320), (60, 60, 64), -1)
            add(f, 'btn:save', text(img, 'Save', 1470, 303, 0.7, (170, 170, 170)))
            badge = '3' if t < 11 else '4'
            cv2.circle(img, (1800, 28), 14, (55, 55, 58), -1)
            add(f, 'badge:' + badge, text(img, badge, 1793, 36, 0.55, (150, 150, 150)))
            pointer(img, *at(t, keys))
            return img
        crf0, events = 30, [['change', 4, 4], ['change', 5, 5], ['change', 8, 8], ['change', 11, 11]]
    elif name == 'text4k':
        W, H, dur = 3840, 2160, 12
        keys = [(0, 2000, 1500), (3.6, 2600, 700), (4, 2600, 700), (12, 2600, 1200)]

        def r(t, f):
            img = blank(W, H)
            chrome(img, 'Invoices', W, f)
            for k in range(40):
                amt = '1,240.50' if k == 7 and t >= 4 else '1,204.50'
                stt = 'Approved' if k == 15 and t >= 8 else 'Pending'
                b = text(img, f'INV-{5231600 + k}   13/10/2026   GBP {amt}   {stt}', 300, 140 + k * 26, 0.5)
                add(f, f'r{k}' + (':amt' if k == 7 and t >= 4 else '') + (':appr' if k == 15 and t >= 8 else ''), b)
            pointer(img, *at(t, keys))
            return img
        events = [['change', 4, 4], ['change', 8, 8]]
    elif name == 'fade':
        def pg(title, n, f, rec):
            img = blank(W, H)
            chrome(img, title, W, f, rec=rec)
            lines(img, f, title[:3], n, rec=rec)
            return img

        def r(t, f):
            if t < 4:
                return pg('Alpha', 14, f, True)
            if t < 5:
                u = t - 4
                return cv2.addWeighted(pg('Bravo', 18, f, u >= 0.95), u, pg('Alpha', 14, f, u <= 0.05), 1 - u, 0)
            if t < 8:
                return pg('Bravo', 18, f, True)
            if t < 8.5:
                return (pg('Bravo', 18, f, False).astype(np.float32) * (1 - (t - 8) / 0.5)).astype(np.uint8)
            if t < 9:
                return (pg('Charlie', 10, f, False).astype(np.float32) * ((t - 8.5) / 0.5)).astype(np.uint8)
            return pg('Charlie', 10, f, True)
        dur, events = 12, [['fade', 4, 5], ['fade', 8, 9]]
    else:
        raise ValueError(f'unknown synthetic clip {name}')
    tag = name if crf is None else f'q-{name}'
    n = int(round(dur * FPS))
    pr = subprocess.Popen([tool('ffmpeg') or 'ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-s', f'{W}x{H}', '-r', str(FPS), '-i', '-',
                           '-c:v', 'libx264', '-preset', 'veryfast', '-crf', str(crf or crf0), '-pix_fmt', 'yuv420p', osp.join(out, tag + '.mp4')], stdin=subprocess.PIPE)
    for f in range(n):
        pr.stdin.write(r(f / FPS, f).tobytes())
    pr.stdin.close()
    pr.wait()
    items = {}
    for iid, fr in vis.items():
        segs = []
        for k in sorted(fr):
            if segs and segs[-1][1] == k - 1 and segs[-1][2] == fr[k]:
                segs[-1][1] = k
            else:
                segs.append([k, k, fr[k]])
        items[iid] = segs
    save_json(osp.join(out, tag + '.gt.json'), {'fps': FPS, 'size': [W, H], 'frames': n, 'items': items, 'events': events, 'synth': SYNTH})
    return osp.join(out, tag + '.mp4')

def score_synth(frames, gt, evs):
    """Item recall (items fully shown in >= 1 kept frame / all), key-item recall (the event items), precision (kept frames that
    add >= 1 new item, time order), frames inside a loading window, and label checks."""
    fps, idx, seen, useful = gt['fps'], gt['items'], set(), 0
    for t in sorted(frames):
        f = min(int(round(t * fps)), gt['frames'] - 1)
        s_ = {iid for iid, segs in idx.items() if any(a <= f <= b for a, b, _ in segs)}
        useful += bool(s_ - seen)
        seen |= s_
    key = {i for i in idx if i.startswith(KEY_ITEMS)}
    out = {'n': len(frames), 'recall': round(len(seen & set(idx)) / max(1, len(idx)), 3), 'key': round(len(seen & key) / len(key), 3) if key else 1.0,
           'precision': round(useful / max(1, len(frames)), 3), 'missed': sorted(key - seen)[:8]}
    for e in gt['events']:
        if e[0] == 'loading':
            out['loadingFrames'] = sum(1 for t in frames if e[1] <= t <= e[2])
            out['loadingEvents'] = sum(1 for x in evs if x['kind'] == 'animated' and x['t0'] < e[2] and x['t1'] > e[1])
    out['toasts'] = sum(1 for x in evs if x['kind'] == 'toast')
    return out

def corpus_file():   # durable (<state>/media/): the corpus outlives a runtime wipe
    return osp.join(osp.dirname(kitbag_mod().kit_path('signals')), 'media', 'corpus.json')

def state_recall(r, states, path):
    """A labelled state (t0, t1, what) is shown when a kept frame falls in its window (+-0.3 s) or one kept frame shows >= fill_cover
    (98%) of its middle frame's content (the same screen kept at another time: a revisit)."""
    hit, w, h = [], *r['analysis']
    for st in states:
        t0, t1 = float(st[0]), float(st[1])
        ok = any(t0 - 0.3 <= c['t'] <= t1 + 0.3 for c in r['kept'])
        if not ok:
            fr = next(decode_at(path, w, h, (t0 + t1) / 2), None)
            ok = fr is not None and r['shown']((t0 + t1) / 2, cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)) >= KP['fill_cover']
        hit.append(ok)
    miss = [list(st[:2]) for st, ok in zip(states, hit) if not ok]
    return round(sum(hit) / max(1, len(hit)), 3), miss

def bench_clip(out, n, crf):
    tag = n if crf is None else f'q-{n}'
    v, g = osp.join(out, tag + '.mp4'), load_json(osp.join(out, tag + '.gt.json'))
    if not (g and g.get('synth') == SYNTH and osp.isfile(v)):
        v = synth(out, n, crf)
        g = load_json(osp.join(out, tag + '.gt.json'))
    r = keyframes(v, g['size'][0], g['size'][1], g['frames'] / g['fps'])
    return tag, dict(score_synth([c['t'] for c in r['kept']], g, r['events']), ms=r['ms_per_frame'])

def bench(names=None, crf36=True, corpus=True, only=None, record=False):
    """The detector gate: synthetic clips (generated once per SYNTH into the cache) + their crf-36 variants, then every corpus
    clip whose media is cached. Exit 1 when a synthetic gate fails or a corpus clip's recall drops below its recorded value."""
    need_cv()
    res, fails = {'synthetic': {}, 'corpus': {}}, []
    out = osp.join(cache_root(), f'_bench-v{SYNTH}')
    os.makedirs(out, exist_ok=True)
    clips = [(n, None) for n in (names or ['scroll', 'toast', 'modal', 'typing', 'spinner', 'page', 'cursor', 'dark', 'text4k', 'fade'])]
    clips += [(n, 36) for n, _ in list(clips) if crf36 and n in SYNTH_Q]
    import concurrent.futures as cf
    with cf.ProcessPoolExecutor(max_workers=max(1, min(len(clips), (os.cpu_count() or 2) // 2, 8))) as ex:   # one clip per process
        done = list(ex.map(bench_clip, [out] * len(clips), [n for n, _ in clips], [c for _, c in clips])) if not only else []
    for (n, crf), (tag, sc) in zip(clips, done):
        res['synthetic'][tag] = sc
        if sc['recall'] < 1 or sc['key'] < 1:
            fails.append(f"{tag}: recall {sc['recall']} key {sc['key']} (missed {', '.join(sc['missed'])})")
        if n == 'spinner' and (sc.get('loadingEvents') != 1 or sc.get('loadingFrames', 9) > 3):
            fails.append(f"{tag}: loading = {sc.get('loadingEvents')} animated events, {sc.get('loadingFrames')} frames (want 1, <= 3)")
        if n == 'dark' and sc['toasts']:
            fails.append(f'{tag}: a dark-theme highlight labelled toast')
        if tag == 'toast' and sc['toasts'] < 2:
            fails.append(f"{tag}: {sc['toasts']} toasts labelled (want 2)")
    clean = [v for k, v in res['synthetic'].items() if not k.startswith('q-')]
    if clean and sum(v['precision'] for v in clean) / len(clean) < 0.9:
        fails.append(f"synthetic precision {sum(v['precision'] for v in clean) / len(clean):.3f} < 0.9")
    cj = load_json(corpus_file(), {}) or {}
    for key, e in sorted(cj.items()) if corpus else []:
        if only and key != only:
            continue
        lab = load_json(e.get('labels') or '', {}) or {}
        if e.get('media') == 'evicted':
            res['corpus'][key] = {'skipped': f"media evicted (newest media.corpus.keep kept); re-fetch: pokey.ps1 evidence index {e.get('link')}"}
            continue
        if not osp.isfile(e.get('file') or '') or not lab.get('states'):
            res['corpus'][key] = {'skipped': 'media or labels not cached here'}
            continue
        info = probe(e['file'])
        r = keyframes(e['file'], info['width'], info['height'], info['duration'])
        rec, miss = state_recall(r, lab['states'], e['file'])
        anim = [x for x in lab.get('animations') or []]   # [t0, t1, max frames]
        waste = [a for a in anim if sum(1 for c in r['kept'] if a[0] <= c['t'] <= a[1]) > a[2]]
        res['corpus'][key] = {'name': e.get('name'), 'recall': rec, 'was': e.get('recall'), 'frames': len(r['kept']), 'fills': len(r['fills']), 'missed': miss[:12],
                              'waste': waste, 'ms': r['ms_per_frame']}
        if e.get('recall') is not None and rec < float(e['recall']):
            fails.append(f"corpus {key} ({e.get('name')}): recall {rec} < {e['recall']} recorded")
        if waste:
            fails.append(f'corpus {key}: animation windows over their frame cap: {waste}')
        if record and not (e.get('recall') is not None and rec < float(e['recall'])):   # a drop never lowers the baseline
            e.update(recall=rec, pipe=PIPE, status='passed' if rec >= 1 and not waste else 'open', checked=time.strftime('%Y-%m-%d'))
    if record and corpus:
        save_json(corpus_file(), cj)
    res['fails'] = fails
    return res

def evict(cj):
    """Keep the cached media of the newest media.corpus.keep clips (pinned ones aside); older clips keep their labels and
    feedback rows, lose their cached media and are marked media: evicted (the gate skips them)."""
    c = CFG['corpus']
    pin = {str(x) for x in c.get('pin') or []}
    live = sorted((k for k, e in cj.items() if e.get('media') != 'evicted' and k not in pin and e.get('link') not in pin), key=lambda k: cj[k].get('added', ''))
    gone = live[:max(0, len(live) - int(c['keep']))]
    for k in gone:
        kd = key_dir(k)
        for x in os.listdir(kd) if osp.isdir(kd) else []:
            if x not in ('labels.json', 'fetch.json'):   # a local file the fetcher only pointed at is never ours to delete
                shutil.rmtree(osp.join(kd, x), ignore_errors=True) if osp.isdir(osp.join(kd, x)) else os.remove(osp.join(kd, x))
        cj[k]['media'] = 'evicted'
    return gone

def feedback(key, items_file):
    """vidy's verify phase: {states: [[t0, t1, what]], animations: [[t0, t1, max frames]], findings: [{kind: missed | wasted |
    wrong-label, t0, t1, frames, note}], tokens} -> labels.json next to the media, one feedback.jsonl line per finding, the clip
    in corpus.json (passed when nothing was found: nothing more happens; else open + the tune line)."""
    kd, ix = key_dir(key), ix_dir(key)
    fj = load_json(osp.join(kd, 'fetch.json'))
    if not fj or not ix:
        raise FileNotFoundError(f'no index for {key}: run pokey.ps1 evidence index <link> first')
    j = load_json(items_file)
    if not isinstance(j, dict) or not isinstance(j.get('states'), list) or not j['states']:
        raise ValueError(f'{items_file}: {{states: [[t0, t1, what]], findings: [...]}} is required (states = every distinct screen)')
    for n, st in enumerate(j['states'] + (j.get('animations') or []), 1):
        if not (isinstance(st, list) and len(st) >= 2):
            raise ValueError(f'{items_file} state {n}: [t0, t1, what] (seconds or m:ss)')
        st[0], st[1] = parse_time(st[0]), parse_time(st[1])
        if st[0] > st[1]:
            raise ValueError(f'{items_file} state {n}: t0 > t1')
    kinds, found = ('missed', 'wasted', 'wrong-label'), []
    for n, x in enumerate(j.get('findings') or [], 1):
        if not isinstance(x, dict) or x.get('kind') not in kinds or x.get('t0') is None:
            raise ValueError(f"{items_file} finding {n}: kind ({' | '.join(kinds)}) and t0 are required")
        found.append({'kind': x['kind'], 't0': round(parse_time(x['t0']), 2), 't1': round(parse_time(x.get('t1', x['t0'])), 2),
                      'frames': [str(p) for p in x.get('frames') or []], 'note': clip(str(x.get('note') or ''), 200)})
    lab = osp.join(kd, 'labels.json')
    save_json(lab, {'key': key, 'states': j['states'], 'animations': j.get('animations') or [], 'pipe': PIPE, 'at': time.strftime('%Y-%m-%dT%H:%M:%S')})
    fbf = osp.join(osp.dirname(corpus_file()), 'feedback.jsonl')
    os.makedirs(osp.dirname(fbf), exist_ok=True)
    with open(fbf, 'a', encoding='utf-8') if found else contextlib.nullcontext() as fh:
        for x in found:
            fh.write(json.dumps(dict(x, key=key, link=fj.get('link'), pipe=PIPE, at=time.strftime('%Y-%m-%dT%H:%M:%S')), ensure_ascii=False) + '\n')
    lk = os_lock(corpus_file() + '.lock', 60)   # parallel vidys on other videos: one writer at a time
    if not lk:
        raise RuntimeError('corpus.json is locked by another feedback for 60 s')
    try:
        cj = load_json(corpus_file(), {}) or {}
        e = cj.get(key) or {}
        e.pop('media', None)
        e['added'] = time.strftime('%Y-%m-%dT%H:%M:%S')   # verified now: the newest clip, its media kept
        e.update(name=clip(str(j.get('name') or e.get('name') or osp.basename(fj.get('link') or key)), 80), link=fj.get('link'), file=fj['file'], sha=fj.get('sha'),
                 labels=lab, states=len(j['states']), pipe=PIPE, status='open' if found else 'passed', open=len(found))
        if not found:
            e['recall'] = 1.0   # perfect: the clip guards against regressions from now on
        cj[key] = e
        gone = evict(cj)
        save_json(corpus_file(), cj)
    finally:
        lk.close()
    tok, cap = int(j.get('tokens') or 0), int(CFG['vidy']['labelTokens'])
    log('media-feedback', {'key': key, 'states': len(j['states']), 'findings': len(found), 'tokenCount': tok})
    out = [f"feedback {key}: {len(j['states'])} states, {len(found)} findings ({', '.join(f'{k} {sum(1 for x in found if x['kind'] == k)}' for k in kinds if any(x['kind'] == k for x in found)) or 'none'})"
           + (f' · labelling {tok} tokens' + (f' > media.vidy.labelTokens {cap}' if tok > cap else '') if tok else '')]
    out.append(f'corpus: {key} {e["status"]} · {corpus_file()}' + (f" · media evicted: {', '.join(gone)}" if gone else ''))
    out.append('perfect: nothing more for this video' if not found else
               f'TUNE {key}: spawn kitty (kind fix): video.py bench --key {key} until recall 1.0 on it, then a full bench (no clip drops); push; then pokey.ps1 evidence index {fj.get("link")} -Refresh and a vidy re-check of the missed windows')
    return out

# ---- verbs: fetch, index, status under one lock per video and the local-stt lease (OS locks: a dead holder frees them)
def os_lock(path, wait_sec, say=''):
    """An exclusive OS lock on <path> (msvcrt / fcntl; a handle another process opened without sharing counts as held): the open
    file, or None after wait_sec; prints say once while it waits."""
    os.makedirs(osp.dirname(path), exist_ok=True)
    end, said = time.time() + wait_sec, False
    while True:
        try:
            fh = open(path, 'a+')
            try:
                if os.name == 'nt':
                    import msvcrt
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return fh
            except OSError:
                fh.close()
        except OSError:
            pass
        if say and not said:
            print(say, flush=True)
            said = True
        if time.time() >= end:
            return None
        time.sleep(1)

def kitbag_mod():
    sys.path.insert(0, osp.join(KIT, 'skills', 'bossy'))
    import kitbag
    return kitbag

def log(event, fields):
    try:
        kitbag_mod().kitlog('calls', event, fields)
    except Exception:
        pass

def stt_stage(key, wait_min, agent):
    """transcribe on the local STT server: pokey.ps1 evidence stt holds the local-stt lease (video.ps1) and the memory gate."""
    if not needs(key, 'transcribe'):
        return stage(key, 'transcribe')
    r = run([tool('pwsh') or 'pwsh', '-NoProfile', '-File', osp.join(KIT, 'skills', 'pokey', 'pokey.ps1'), 'evidence', 'stt', key, '-WaitMinutes', f'{wait_min:g}',
             '-Agent', agent] + (['-Refresh'] if '--refresh' in sys.argv else []), timeout=int(wait_min * 60) + 3600)
    for line in (r.stdout or '').splitlines():
        if line.startswith(('waiting for local AI', 'media transcribe:')):
            print(line, flush=True)
    try:
        return json.loads((r.stdout or '').strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {'degraded': True, 'reason': f"FAILED: pokey.ps1 evidence stt (exit {r.returncode}): {(r.stderr or r.stdout or '').strip()[-200:]}"}

def busy(key, minutes):
    return os_lock(key_dir(key) + '.lock', minutes * 60, f'media: another agent is processing this video ({key}); waiting, then reusing its index')

def say_unreadable(f):
    return f"unreadable: {f['reason']}" + ('' if 'ask the tester' in f['reason'] else ', ask the tester for the file')

def v_fetch(link):
    key = key_of(link)
    lk = busy(key, float(arg('--lock-minutes', 90)))
    if not lk:
        raise Busy(f'evidence fetch: {key} is being processed by another agent; run it again later')
    try:
        f = fetch(link, '--refresh' in sys.argv)
    finally:
        lk.close()
    if f['kind'] == 'unreadable':
        print(say_unreadable(f))
        return 1
    f['ixDir'] = ix_dir(key)
    if '--json' in sys.argv:
        print(json.dumps(f, ensure_ascii=False, indent=1))
        return 0
    side = ', '.join(f.get('sidecars') or {})
    print(f"fetched {key} via {f['fetcher']}: {f['kind']} {f['bytes'] / 1048576:.1f} MB" + (' (cached)' if f.get('cached') else f" in {f['fetchSec']} s") + (f'; sidecars: {side}' if side else ''))
    return 0

def v_index(link):
    key, t0 = key_of(link), time.time()
    lk = busy(key, float(arg('--lock-minutes', 90)))
    if not lk:
        raise Busy(f'evidence index: {key} is still being processed by another agent; run it again later')
    try:
        f = fetch(link, '--refresh' in sys.argv)
        if f['kind'] == 'unreadable':
            print(say_unreadable(f))
            return 1
        ix, wait, agent = ix_dir(key), float(arg('--wait-minutes', 30)), arg('--agent') or os.environ.get('CLAUDE_AGENT') or 'main'
        times, notes = {'fetch': 'cached' if f.get('cached') else f"{f['fetchSec']} s"}, []
        for st in ('detect', 'transcribe', 'vision'):
            if st == 'transcribe' and '--no-transcript' in sys.argv:
                times[st] = 'skipped'
                continue
            s0 = time.time()
            try:
                res = stt_stage(key, wait, agent) if st == 'transcribe' else stage(key, st)
            except Exception as e:   # a crashed stage: its part of the index is missing, not empty
                notes.append(f'FAILED {st}: the stage crashed ({type(e).__name__}: {e}): its part of the index is missing, not empty')
                times[st] = 'failed'
                continue
            times[st] = f'{time.time() - s0:.1f} s' + (' (cached)' if res.get('cached') else '')
            if res.get('reason'):
                notes.append(f"{'degraded' if res.get('degraded') else 'note'} {st}: {res['reason']}")
        b = build(key)
    finally:
        lk.close()
    log('media-index', {'key': key, 'fetcher': f['fetcher'], 'tokenCount': b['tokens'], 'sec': int(time.time() - t0)})
    if '--json' in sys.argv:
        print(json.dumps({'key': key, 'fetcher': f['fetcher'], 'index': b['index'], 'tokens': b['tokens'], 'chunks': b['chunks'], 'times': times, 'notes': notes}, ensure_ascii=False))
        return 0
    print(f"index {key} ({f['fetcher']}): {b['chunks']} chunks, ~{b['tokens']} tokens, {b['index']} · " + ' · '.join(f'{k} {v}' for k, v in times.items()))
    print('\n'.join(notes + ['']))
    with open(b['index'], encoding='utf-8') as fh:
        print(fh.read())
    return 0

def v_write_vision(key):
    if not arg('--file'):
        raise Usage('evidence write-vision: <key> --file <items.json> are required')
    w = write_vision(key, arg('--file'), arg('--model'), arg('--tokens'))
    log('media-vision', {'key': key, 'model': w['model'], 'framesRead': w['framesRead'], 'maxFrames': w['maxFrames'], 'imageSpend': w['imageTokens'], 'agentSpend': w['tokens']})
    print(f"vision {key}: {w['items']} items from {w['framesRead']} frames (of {w['maxFrames']} keyframes), ~{w['imageTokens']} image tokens"
          + (f", {w['tokens']} agent tokens" if w['tokens'] else '') + f", {w['unread']} unread · {w['index']}")
    if w['extra']:
        print(f"WARN: {w['extra']} frame(s) read are not the detector's keyframes (vidy reads only those)")
    return 0

def v_status(ref):
    if ref:
        k = ref if re.fullmatch(r'[0-9a-f]{16}', ref) else key_of(ref)
        print(json.dumps({'key': k, 'keyDir': key_dir(k), 'ixDir': ix_dir(k)}))
    return 0

def evidence_dir(item, agent):
    r = run([tool('pwsh') or 'pwsh', '-NoProfile', '-File', osp.join(KIT, 'skills', 'crafty', 'crafty.ps1'), 'dir', '-Kind', 'evidence', '-Item', item, '-Agent', agent], timeout=60)
    return (r.stdout or '').strip().splitlines()[-1] if not r.returncode and (r.stdout or '').strip() else None

class Busy(Exception):
    pass

class Usage(Exception):
    pass

# ---- cli: stage runner, needs, argv
def stage(key, name):
    kd, ix = key_dir(key), ix_dir(key)
    fj = load_json(osp.join(kd, 'fetch.json'))
    if not fj or not ix:
        raise FileNotFoundError(f'no fetched file for {key}: run fetch first')
    os.makedirs(ix, exist_ok=True)
    target = osp.join(ix, f'{name}.json')
    old = load_json(target)
    if old is not None and not old.get('degraded') and ('--refresh' not in sys.argv or old.get('by') == 'vidy'):   # a refresh keeps vidy's reading
        if name == 'vision' and '--refresh' in sys.argv:   # ... and lists the new detect's keyframes it has not read
            fresh, same = vision(load_json(osp.join(ix, 'detect.json')) or {'events': []}, fj, ix), lambda q: osp.normcase(osp.abspath(q))
            seen = {same(q) for x in old.get('items') or [] for q in x.get('frames') or []}
            save_json(target, dict(old, pending=[x for x in fresh['pending'] if same(x['file']) not in seen], maxFrames=fresh['maxFrames'], budget=fresh.get('budget')))
        return {'stage': name, 'cached': True, 'reason': old.get('reason', '')}
    info = None if '--refresh' in sys.argv else load_json(osp.join(ix, 'probe.json'))
    if info is None:
        info = probe(fj['file']) if fj['kind'] == 'video' else {'duration': 0, 'width': 0, 'height': 0, 'audio': False}
        save_json(osp.join(ix, 'probe.json'), info)
    t0 = time.time()
    if name == 'detect':
        res = detect(fj['file'], info, ix, fj) if fj['kind'] == 'video' else {'events': [], 'duration': 0, 'counts': {}}
    elif name == 'transcribe':
        res = transcribe(fj['file'], info, fj, ix) if fj['kind'] == 'video' else {'source': 'none', 'segments': []}
    else:
        res = vision(load_json(osp.join(ix, 'detect.json')) or {'events': []}, fj, ix)
    res['stageSec'] = round(time.time() - t0, 1)
    save_json(target, res)
    return {'stage': name, 'sec': res['stageSec'], 'reason': res.get('reason', ''), 'degraded': bool(res.get('degraded')),
            **({'counts': res.get('counts')} if name == 'detect' else {}), **({'segments': len(res.get('segments', []))} if name == 'transcribe' else {}),
            **({'items': len(res.get('items', []))} if name == 'vision' else {})}

def needs(key, name):
    """Does transcribe call the local STT server (so pokey.ps1 takes its lease + gate first)? Cached, sidecar or off -> no."""
    if name != 'transcribe':
        return False
    kd, ix = key_dir(key), ix_dir(key)
    fj = load_json(osp.join(kd, 'fetch.json')) or {}
    old = load_json(osp.join(ix, f'{name}.json') if ix else '')
    if not fj or (old is not None and not old.get('degraded') and '--refresh' not in sys.argv):
        return False
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

VALUED = ('--key', '--names', '--at', '--window', '--frames', '--size', '--out', '--duration', '--model', '--tokens', '--segment', '--file', '--item', '--agent',
          '--wait-minutes', '--lock-minutes')

def norm_argv(argv):
    """pokey.ps1 evidence passes PowerShell-style switches: -WaitMinutes 5 -> --wait-minutes 5 (any case)."""
    out = []
    for x in argv:
        if re.fullmatch(r'-{1,2}[A-Za-z][A-Za-z-]*', x):
            x = '--' + re.sub(r'(?<=[a-z])(?=[A-Z])', '-', x.lstrip('-')).lower()
        out.append(x)
    return out

def main():
    sys.argv = [sys.argv[0]] + norm_argv(sys.argv[1:])
    a = [x for i, x in enumerate(sys.argv[1:], 1) if not x.startswith('--') and not (i > 1 and sys.argv[i - 1] in VALUED)]
    if not a:
        print(__doc__)
        return 2
    cmd, rest = a[0], a[1:]
    key = lambda r: r if re.fullmatch(r'[0-9a-f]{16}', r) else key_of(r)
    try:
        if cmd == 'fetch' and rest:
            return v_fetch(rest[0])
        elif cmd == 'index' and rest:
            return v_index(rest[0])
        elif cmd == 'read-chunk' and rest:
            out = arg('--out') or (evidence_dir(arg('--item'), arg('--agent') or os.environ.get('CLAUDE_AGENT') or 'main') if arg('--item') else None)
            print('\n'.join(read(key(rest[0]), rest[1] if len(rest) > 1 else None, rest[2] if len(rest) > 2 else None, arg('--at'), arg('--window'),
                                 '--around-error' in sys.argv, int(arg('--frames', 3)), int(arg('--size', 1280)), out)))
        elif cmd == 'frames' and rest:
            print('\n'.join(frames(key(rest[0]), arg('--segment'))))
        elif cmd == 'write-vision' and rest:
            return v_write_vision(key(rest[0]))
        elif cmd == 'status':
            return v_status(rest[0] if rest else None)
        elif cmd == 'feedback' and rest:
            if not arg('--file'):
                raise Usage('evidence feedback: <key> --file <verify.json> are required')
            print('\n'.join(feedback(key(rest[0]), arg('--file'))))
        elif cmd == 'bench':
            r = bench(arg('--names').split(',') if arg('--names') else None, '--no-crf36' not in sys.argv, '--no-corpus' not in sys.argv, arg('--key'), '--record' in sys.argv)
            if '--json' in sys.argv:
                print(json.dumps(r, ensure_ascii=False))
            else:
                for k, v in r['synthetic'].items():
                    print(f"{k}: recall {v['recall']} key {v['key']} precision {v['precision']} frames {v['n']} {v['ms']} ms/frame" + (f" loading {v['loadingEvents']} event, {v['loadingFrames']} frames" if 'loadingFrames' in v else ''))
                for k, v in r['corpus'].items():
                    print(f'corpus {k}: ' + (v['skipped'] if 'skipped' in v else f"{v['name']}: recall {v['recall']} (was {v['was']}) frames {v['frames']} (fills {v['fills']}) {v['ms']} ms/frame" + (f" missed {v['missed']}" if v['missed'] else '')))
                print('\n'.join(f'FAIL {x}' for x in r['fails']) or 'bench: pass')
            return 1 if r['fails'] else 0
        elif cmd == 'select' and rest:
            print(json.dumps({'fetcher': select(rest[0]), 'key': key_of(rest[0]), 'link': norm_link(rest[0])}))
        elif cmd in ('detect', 'transcribe', 'vision') and rest:
            print(json.dumps(stage(rest[0], cmd), ensure_ascii=False))
        elif cmd == 'needs' and len(rest) >= 2:
            print(json.dumps({'need': needs(rest[0], rest[1])}))
        elif cmd == 'build' and rest:
            print(json.dumps(build(rest[0])))
        elif cmd == 'window' and len(rest) >= 2:
            print(json.dumps(window(rest[0], rest[1], arg('--at'), arg('--window'), float(arg('--duration', 0)))))
        elif cmd == 'paths' and rest:
            k = key(rest[0])
            ix = ix_dir(k)
            print(json.dumps({'key': k, 'keyDir': key_dir(k), 'ixDir': ix, 'index': osp.join(ix, 'index.md') if ix and osp.isfile(osp.join(ix, 'index.md')) else None}))
        else:
            print(__doc__)
            return 2
    except Usage as e:
        print(e, file=sys.stderr)
        return 2
    except (ValueError, FileNotFoundError, RuntimeError, Busy) as e:
        print(f'evidence {cmd}: {e}' if not str(e).startswith('evidence ') else str(e), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    try:
        sys.exit(kitbag_mod().audited('video.py', sys.argv, main))
    except ImportError:   # a kit without kitbag.py: no call log
        sys.exit(main())
