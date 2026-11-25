#!/usr/bin/env python3
"""kitbag.py: the kit's own tooling in one file - lint, README graph, audit stamp, prose, budget; plugins (kitbag_<name>.py) add commands.

  python -X utf8 kitbag.py lint  [<kit>] [--summary] [--warn (+ the uncounted warnings, exit 0)] [--no-flow] [--ratchet] [--org-terms <kit.local.json | a,b>] [--json <out>]
  python -X utf8 kitbag.py flow --readme [<kit>]       # README graph sections (the interactive page: kitbag_flow.py)
  python -X utf8 kitbag.py port  [--check]             # Codex / Antigravity ports of agents, hooks, workflows (kitbag_ports.py)
  python -X utf8 kitbag.py tools [--days 14] [--json]  # crew allowlists vs real tool use; MCP servers no role grants (exit 1: a used tool not allowed)
  python -X utf8 kitbag.py audit stamp | scan [--kit <dir>] [--json <file>]   # stamp resets the audit nudge; scan: kitbag_admin.py
  python -X utf8 kitbag.py cost  [<kit>] [--steps] [--json]   # start tokens per agent, workflow prompts (kitbag_admin.py)
  python -X utf8 kitbag.py prose --kind <kind> <file | -> [--json] · prose --kinds   # vs templates.md "Writing standards"
  python -X utf8 kitbag.py release [--tag] [--publish]   # next SemVer + notes from Conventional Commits (kitbag_admin.py)
  python -X utf8 kitbag.py faults [next] [--n 3] [--days 7] [--json]   # agents' failed commands -> recurring script-fault items (kitbag_admin.py)
  python -X utf8 kitbag.py sections [--fix] [<file> ...]   # section maps vs `---- <name>:` markers (lint SECTION-*)
  python -X utf8 kitbag.py budget [show]   # start tokens per role vs START_CAP (lint START-BUDGET); repo and tests totals (INFO)
  python -X utf8 kitbag.py naming check|next|make|scan|rename ...   # the naming standard: keys, titles, docs, runs, branches (kitbag_naming.py)
  python -X utf8 kitbag.py parity [--json] | parity next [--n 3]   # adapter x verb, harness x feature: native / fallback / gap (lint PARITY; skills/crafty/parity.json); next: cells to close first
  python -X utf8 kitbag.py migrate         # one-time: retired install records out (.githooks/post-merge runs it)
  python -X utf8 kitbag.py state lint [--since <min>] [--json] | state writers | state todo add|done|lint <file> ...   # state files vs STATE.md Inventory; run files vs its Artefacts (drift guard)
  python -X utf8 kitbag.py ui-check <page.html> [--widths 1920,1366,900,390] [--click 'sel,sel;sel']   # headless shots (<shots>/ui-check) + clipped text

lint problem codes: each message says what is wrong and the fix; skills/bossy/kit-admin.md lists them.
audit output: `<LEVEL> <CODE> <where>: <what> [-> <fix>]`, LEVEL FIX | ACT | ASK | WARN | INFO.
Exit codes: 0 ok · 1 problems found (lint, stale ports, ACT/ASK audit findings) · 2 usage error (an unknown command or flag,
a non-kit dir).

Sections: L41 paths · L138 state · L186 the one name normaliser (owner 2026-11-25) · L365 kitlog · L467 load · L960 lint ·
  L1381 README graph · L1499 lint command · L1781 audit · L1929 registry · L1989 tools · L2077 parity · L2678 arch lint ·
  L2951 prose · L3134 sections · L3266 budget · L3284 migrate · L3432 plugins · L3489 state lint · L3677 main
"""
import ast, contextlib, datetime, fnmatch, functools, html, importlib.util, io, json, os, re, shutil, subprocess, sys, tempfile, time, traceback
import os.path as osp
from collections import defaultdict, deque
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

KIT_DIR = osp.dirname(osp.dirname(osp.dirname(osp.abspath(__file__))))   # 3 levels up: <kit>
os.environ['GIT_OPTIONAL_LOCKS'] = '0'   # git probes (status, diff) never rewrite a repo's index (lib.ps1 sets it too)
if not os.environ.get('GIT_CONFIG_COUNT'):   # no auto maintenance per kit fetch / commit (lib.ps1 sets it too)
    os.environ.update({'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'maintenance.auto', 'GIT_CONFIG_VALUE_0': 'false'})

# ---- paths: kit.example.json _paths
with open(osp.join(KIT_DIR, 'skills', 'crafty', 'kit.example.json'), encoding='utf-8') as _f:
    MAP = json.load(_f)['_paths']

def kit_stamp(kind='stored', t=None):
    """One time format per use (lib.ps1 Get-KitStamp): stored UTC ISO ms · file UTC yyyyMMdd-HHmmss · day yyyyMMdd · display local yyyy-MM-dd HH:mm."""
    t = t or datetime.datetime.now(datetime.timezone.utc)
    u = t.astimezone(datetime.timezone.utc)
    return {'stored': u.strftime('%Y-%m-%dT%H:%M:%S.') + f'{u.microsecond // 1000:03d}Z', 'file': u.strftime('%Y%m%d-%H%M%S'),
            'day': u.strftime('%Y%m%d'), 'display': t.astimezone().strftime('%Y-%m-%d %H:%M')}[kind]

def runtime_dir(kit=None):
    k, rt = kit or KIT_DIR, os.environ.get('CLAUDE_RUNTIME') or MAP['runtimeDir']   # a relative one: from the kit, never the cwd;
    return osp.join(osp.dirname(osp.normpath(k)) if re.split(r'[\\/]', rt)[0] == osp.basename(osp.normpath(k)) else k, rt)   # '<kit name>/..': the workspace's

def kit_path(name, create=False, kit=None):
    """Absolute path of a named runtime or durable entry. kit= resolves it for another kit folder (kit-lint on a clone)."""
    if name == 'runtime':
        p, is_dir = runtime_dir(kit), True
    elif name in MAP['runtime']:
        rel = MAP['runtime'][name]
        p, is_dir = osp.join(runtime_dir(kit), rel.rstrip('/')), rel.endswith('/')
    elif name in MAP['durable']:
        rel = MAP['durable'][name]
        p, is_dir = osp.join(kit or KIT_DIR, MAP['stateDir'], rel.rstrip('/')), rel.endswith('/')
    else:
        raise KeyError(f'kit_path: unknown name {name!r} (see skills/crafty/kit.example.json _paths)')
    p = osp.normpath(p)
    if create:
        os.makedirs(p if is_dir else osp.dirname(p), exist_ok=True)
    return p

with contextlib.suppress(OSError):   # a read-only kit keeps the OS default rather than failing every import
    tempfile.tempdir = kit_path('tmp', create=True)   # every tempfile.* call of a kit script (it imports kitbag): <runtime>/tmp, never the OS temp

def _lock_byte(fd, on=True):
    """Lock (or unlock) byte 0 of an open lock file, never blocking; OSError when another process holds it."""
    if os.name == 'nt':
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK if on else msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.lockf(fd, (fcntl.LOCK_EX | fcntl.LOCK_NB) if on else fcntl.LOCK_UN, 1, 0)


@contextlib.contextmanager
def locked(path, stale=120):
    """A lock file beside path for one writer at a time (devtools.py imports it), kept between uses (no create / delete per
    update): held = byte 0 locked (lib.ps1 Invoke-KitLocked locks the same byte), freed by the OS when the holder dies.
    macOS (lib.ps1 has no byte lock there): created new, removed after, a dead writer's stale lock taken over."""
    lock = path + '.lock'
    fd, end = None, time.time() + stale + 10
    if sys.platform != 'darwin':
        while fd is None:
            try:
                fd = os.open(lock, os.O_RDWR | os.O_CREAT)
                _lock_byte(fd)
            except OSError:   # held, or a pre-change holder (share none) refuses the open
                if fd is not None:
                    os.close(fd)
                    fd = None
                if time.time() > end:   # never run unlocked (that lost concurrent writes)
                    raise TimeoutError(f'could not lock {path} within {stale + 10} s ({lock} is held)') from None
                time.sleep(0.1)
        try:
            yield
        finally:
            with contextlib.suppress(OSError):
                _lock_byte(fd, False)
            os.close(fd)
            if os.name == 'nt' and not osp.exists(path):   # its file went: the lock too (an open handle keeps it; POSIX would unlink a held one)
                with contextlib.suppress(OSError):
                    os.remove(lock)
        return
    while fd is None:
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                if time.time() - osp.getmtime(lock) > stale:
                    os.remove(lock)
                    continue
            except OSError:
                pass
            if time.time() > end:   # never run unlocked (that lost concurrent writes)
                raise TimeoutError(f'could not lock {path} within {stale + 10} s ({lock} is held)')
            time.sleep(0.1)
    try:
        yield
    finally:
        os.close(fd)
        try:
            os.remove(lock)
        except OSError:
            pass

# ---- state: skills/bossy/STATE.md (lib.ps1 Read-/Write-KitState, Update-KitTaskIndex, Read-KitTracking)
def state_read(path):
    """A state file's object; None when missing or unreadable (tolerant reader: state-lint flags the bad file)."""
    try:
        with open(path, encoding='utf-8-sig') as fh:
            o = json.load(fh)
        return o if isinstance(o, dict) else None
    except (OSError, ValueError):
        return None

def state_write(path, data, version=1):
    """schemaVersion, updated (ISO + offset), holder; an atomic replace."""
    data = dict(data, schemaVersion=version, updated=kit_stamp(),
                holder={'agent': kit_who().get('agent', ''), 'session': os.environ.get('KIT_SESSION', ''), 'pid': os.getpid()})
    os.makedirs(osp.dirname(path), exist_ok=True)
    tmp = f'{path}.{os.getpid()}.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(data, fh, indent=1, ensure_ascii=False)
    os.replace(tmp, path)
    return data

# names the kit makes (owner 2026-11-24): words first (next_name), a counter only where no word names it (next_id); never a date or padding
def _counter(group):
    """The next number of a counter group under its lock (.state naming.json: {group: last})."""
    f = kit_path('naming', create=True)
    with locked(f):
        x = state_read(f) or {}
        if group.startswith('id:') and group not in x:   # migrate: the old per-day counters of this kind fold into one, past every id they made
            days = [k for k in x if k.startswith(group + ':')]
            x[group] = sum(int(x.pop(k) or 0) for k in days)
        x[group] = int(x.get(group) or 0) + 1
        state_write(f, x)
        return x[group]

def next_id(kind):
    """<kind>-<n>, unpadded (owner 2026-11-24: a number only where no word names it; old <kind>-<nnnn> ids resolve, Resolve-KitIdAlias)."""
    if not re.match(r'^[a-z]+(?:-[a-z]+)*$', kind):
        raise SystemExit(f'naming next id: kind {kind!r}: lowercase words joined by -')
    live = board_live('run')
    for _ in range(100):   # a reset counter never hands out a run id live on the board
        rid = f'{kind}-{_counter(f"id:{kind}")}'
        if rid not in live:
            return rid
    raise SystemExit(f'naming next id: 100 {kind} ids live on the board')

NAME_STOP = {'a', 'an', 'the', 'and', 'or', 'of', 'for', 'to', 'in', 'on', 'at', 'by', 'with', 'after', 'before', 'from', 'via', 'all', 'are',
             'is', 'be', 'do', 'does', 'should', 'can', 'this', 'that', 'it', 'now', 'then', 'will', 'what', 'which', 'how', 'when', 'why',
             'who', 'we', 'you', 'every', 'each', 'any', 'some', 'not', 'yes', 'its', 'our', 'your'}
# ---- the one name normaliser (owner 2026-11-25): every id the kit makes or shows is `<role>-<2-3 topic words>`, its text
# `<short lowercase plain words>`: words split by single hyphens, codes, waves, versions, dates and padding out; lanes / slots never
NAME_VOCAB = frozenset('''ai ui ux api qa db sql e2e s3 k8s i18n css js ts img image edit fix test lane env deploy build cart pick wave
prompt reason cancel order account pay price list page menu run check lint name gate dev prod local data seed mark repo web app mobile
phone lease slot doc spec brief plan review retro tidy kit audit ask only create other type field lost new old auto merge task bug view
show hide sync report log user login cost time home flow item role tag key mr branch ship proof rest live envfix typecheck oauth2 http2
http3 ipv4 ipv6 utf8 sha256 base64 mp4 h264 s3'''.split())
NAME_DATE = r'(?<!\d)(?:19|20)\d\d-?(?:0[1-9]|1[0-2])-?(?:0[1-9]|[12]\d|3[01])(?:-\d{2,6})?(?!\d)'
CODE_RX = re.compile(r'(?<![\w-])[A-Za-z]{2,6}-[A-Za-z]{2,6}-\d+(?:\.\d+)?(?![\w-])|[\w.-]+![0-9]+\b|(?<![\w.])!\d+\b|#\d+\b|(?<![\w-])cu-[0-9a-z]{5,}\b'
                     r'|(?<![\w.])v?\d+(?:\.\d+)+\b|(?<![\w-])v\d+\b'
                     r'|(?<![a-z])waves?[\s-]*\d+\b|' + NAME_DATE, re.I)

@functools.lru_cache(None)
def role_words():
    """The crew and workflow names (_manifest agents + workflows)."""
    m = (load_json(osp.join(KIT_DIR, 'skills', 'crafty', 'kit.example.json'))[0] or {}).get('_manifest') or {}
    return {str(x).lower() for k in ('agents', 'workflows') for x in (m.get(k) or {})}

@functools.lru_cache(None)
def name_vocab():
    """NAME_VOCAB + the crew names + the words of naming.products / naming.areas (kit.local.json): the known words a jam splits into."""
    c = local_config(KIT_DIR, 'kit.local.json').get('naming') or {}
    org = {w for k in ('products', 'areas') for v in (c.get(k) or {}).values() for w in re.findall(r'[a-z0-9]+', str(v).lower())}
    return NAME_VOCAB | role_words() | org

def name_words(text, vocab=None):
    """Lowercase words of a name: camelCase and jams split (ask011 -> ask 11, aiedit -> ai edit: both halves known), padding off."""
    vocab = name_vocab() if vocab is None else vocab
    out = []
    for w in re.findall(r'[a-z0-9]+', re.sub(r'([a-z])([A-Z])', r'\1 \2', str(text or '')).lower()):
        m = w not in vocab and re.fullmatch(r'([a-z]{3,})(\d+)', w)
        for p in ([m[1], m[2]] if m else [w]):
            if p.isdigit():
                out.append(str(int(p)))
                continue
            cut = next((i for i in range(len(p) - 2, 1, -1) if p not in vocab and len(p) >= 5 and p[:i] in vocab and p[i:] in vocab), 0)
            out += [p[:cut], p[cut:]] if cut else [p]
    return out

def name_code(w, vocab):
    """A word that is a code, not a word: digits only, or letters and digits mixed (t15, s42, x7k9q2m4) and not a known word."""
    return w.isdigit() or (bool(re.search(r'\d', w)) and w not in vocab)

def name_describe(text, cap=60):
    """The text after an id (owner 2026-11-25): short lowercase plain words, no task code, wave, version, date or leading role word."""
    vocab = name_vocab()
    t = CODE_RX.sub(' ', str(text or ''))
    t = re.sub(r'\s*[:;|·—–]\s*|\s+-\s+', ' ', t).lower()
    toks = [' '.join(name_words(w, vocab)) if re.fullmatch(r'[a-z]+\d*', w) else w for w in re.findall(r"[\w'+&/.-]+|,", t)]   # jams split first (ask011 -> ask 11)
    toks = [w for w in toks if not (re.fullmatch(r'[\w -]+', w) and not w.replace(' ', '').isdigit() and all(name_code(p, vocab) for p in re.split(r'[\s-]+', w.strip('-')) if p))]
    while toks and (toks[0] in role_words() or toks[0] == ','):
        toks.pop(0)
    s = re.sub(r'\s+,', ',', ' '.join(toks))
    s = re.sub(r'\b(\w+)( \1\b)+', r'\1', re.sub(r'(?:,\s*)+', ', ', s)).strip(' ,.-')
    if len(s) > cap:   # a summary, never a cut word: the last whole clause, else the last whole word
        s = (s[:cap].rsplit(', ', 1)[0] if ', ' in s[:cap] else s[:cap].rsplit(' ', 1)[0]).strip(' ,.-')
    return s

def name_normal(kind, name, topic='', live=(), role=''):
    """The shown form of an id: words split by single hyphens; numbers and codes give way to <topic> words; a tie suffix
    (-b, -2) only when another live name has the same base; <role> leads when given. lane / slot: as given (owner)."""
    if kind in ('lane', 'slot') or not str(name or '').strip():
        return str(name or '')
    vocab, roles = name_vocab(), role_words()
    ws = name_words(re.sub(NAME_DATE, ' ', str(name)), vocab) or name_words(name, vocab)   # a dated old id (buildy-20261123-01) loses the date
    head = [ws[0]] if ws and ws[0] in roles else [role] if role in roles else []
    rest = ws[1:] if head and ws and ws[0] == head[0] else ws
    room = 16 - (len(head[0]) + 1 if head else 0)
    if topic and (not rest or any(name_code(w, vocab) for w in rest)):
        tt = CODE_RX.sub(' ', str(topic)).split(':', 1)   # 'Website v2 wave 3: payments, ...': the words after the colon say the work
        tp = name_slug(tt[1] if len(tt) > 1 and re.search(r'[a-z]{3}', tt[1], re.I) else tt[0], set(head), words=3, room=room, tail=kind == 'agent')
        rest = tp.split('-') if tp else rest
    elif len(rest) > 1 and re.fullmatch(r'[a-z]|\d+', rest[-1]):
        base = '-'.join(head + rest[:-1])
        if not any(name_normal(kind, o, '', (), role) == base for o in live if o != name and name_words(o, vocab) != ws):
            rest = rest[:-1]
    return '-'.join(head + (rest[:3] + rest[-1:] if len(rest) > 3 and re.fullmatch(r'[a-z]|\d+', rest[-1]) else rest[:3]))   # 2-3 topic words (+ a kept tie)

def name_shown(kind, name, topic='', live=(), role=''):
    """`<id> · <description>`; the description never repeats a word of the id or itself (owner 2026-11-25), under 2 words left: none."""
    if kind == 'desc':
        return name_describe(name)
    n, d = name_normal(kind, name, topic, live, role), name_describe(topic)
    seen, out = set(n.split('-')), []
    for tok in d.split(' '):
        core = tok.rstrip(',')
        parts = [p for p in core.split('-') if p and p not in seen and not any(w.startswith(p) for w in n.split('-'))]   # kit under kitty-ask
        seen.update(parts)
        out += ['-'.join(parts) + tok[len(core):]] if parts else []
    d = ' '.join(out).strip(' ,')
    return f'{n} · {d}' if len(re.findall(r'[a-z0-9]+', d)) >= 2 else n   # 'testy-retest · retest-staging rm-staging' -> 'testy-retest · staging rm'

def name_slug(text, drop=(), words=2, room=12, tail=False):
    """A topic as kebab words (no code, date, stop word or word <drop> says; 3+ letter words first), <= <words> words and <room>
    characters: too long drops the last word (tail: the first, a product word the run already says); one long word is cut."""
    vocab = name_vocab()
    ws = list(dict.fromkeys(w for w in name_words(CODE_RX.sub(' ', str(text or '')), vocab) if w not in drop and not name_code(w, vocab)))
    ws = [w for w in ws if w not in NAME_STOP] or ws   # only stop words (pause 'all'): they are the topic
    ws = [w for w in ws if len(w) > 2] or ws
    ws = ws[-words:] if tail else ws[:words]
    while len(ws) > 1 and len('-'.join(ws)) > room:
        ws.pop(0 if tail else -1)
    return '-'.join(ws)[:max(room + (0 if tail or len(ws) > 1 else 4), 0)].strip('-')   # one word stays whole up to 4 more (no gibberish)

def next_name(kind, topic='', folder='', cap=12):
    """<kind>-<topic> (owner 2026-11-24: short words, <= 12 characters; 16 for a <role>-<area> agent id); a tie gets -2, -3: against
    the names in <folder> (a record there), else every name issued before and the live board runs."""
    if not re.match(r'^[a-z]+(?:-[a-z0-9]+)*$', kind):
        raise SystemExit(f'naming next name: kind {kind!r}: lowercase words joined by -')
    slug = next((s for alt in str(topic or '').split(' ~ ') if (s := name_slug(alt, set(kind.split('-')), room=cap - len(kind) - 1, tail=cap > 12 and kind in role_words()))), '')   # 'a ~ b': the first with words; an agent's area: its last words
    base = '-'.join(x for x in (kind, slug) if x)
    cands = (base if n == 1 else f'{base}-{n}' for n in range(1, 10000))
    f, live = kit_path('naming', create=True), set() if folder else board_live('run')
    with locked(f):
        x = state_read(f) or {}
        if folder:   # vs its files, and a name handed out in the last 2 min under this lock (two parallel askers never share one)
            have, now, fk = {osp.splitext(n)[0] for n in os.listdir(folder)} if osp.isdir(folder) else set(), time.time(), osp.abspath(folder).lower()
            hold = {k: v for k, v in (x.get('hold') or {}).items() if now - float(v) < 120}
            name = next(c for c in cands if c not in have and f'{fk}|{c}' not in hold)
            hold[f'{fk}|{name}'] = now
            x['hold'] = hold
        else:
            used = set(x.get('names') or [])
            name = next(c for c in cands if c not in used and c not in live)
            x['names'] = (list(x.get('names') or []) + [name])[-5000:]
        state_write(f, x)
    return name

def bak_name(path):
    """<path>.bak, the one before it moved to <path>.bak.prev (owner 2026-11-24: no counter, no date; lib Get-KitBakName)."""
    if osp.isfile(path + '.bak'):
        os.replace(path + '.bak', path + '.bak.prev')
    return path + '.bak'

def board_live(field):
    """{field value} of the board rows not left (board join, kitbag.py naming next id)."""
    d, out = kit_path('board'), set()
    for f in (osp.join(d, n) for n in os.listdir(d) if n.endswith('.json')) if os.path.isdir(d) else []:
        row, err = load_json(f)
        if not err and isinstance(row, dict) and row.get('status') != 'left' and row.get(field):
            out.add(str(row[field]))
    return out

def task_file(task):
    return osp.join(kit_path('tasks'), re.sub(r'[^\w.-]', '_', str(task)) + '.json')

def task_index(task, change, folder=None):
    """Change .state/tasks/<id>.json (docs.<kind>, comments.<kind>, envRuns, track) under its lock; folder: another tasks/ dir."""
    if not str(task) or str(task).startswith('-'):   # `cases round --help` wrote tasks/--help.json
        raise SystemExit(f'no task id: {task!r} (a flag is no task id)')
    f = osp.join(folder, re.sub(r'[^\w.-]', '_', str(task)) + '.json') if folder else task_file(task)
    os.makedirs(osp.dirname(f), exist_ok=True)
    with locked(f):
        x = state_read(f) or {'task': task}
        for k in ('docs', 'comments'):
            x[k] = x[k] if isinstance(x.get(k), dict) else {}
        x['envRuns'] = [r for r in x.get('envRuns') or [] if r]
        change(x)
        return state_write(f, x)

def read_tracking(legacy=None):
    """{tasks: {id: track}, automerge: {ref: at}} from tasks/*.json and automerge.json, plus tracking.json until its move;
    a bad tracking.json raises (callers wait, never read it as 'no tasks')."""
    t, old = {'tasks': {}, 'automerge': {}}, legacy or kit_path('tracking')
    if osp.exists(old):
        with open(old, encoding='utf-8-sig') as fh:
            d = json.load(fh) or {}
        t['tasks'].update(d.get('tasks') or {})
        t['automerge'].update(d.get('automerge') or {})
    if legacy:
        return t
    d = kit_path('tasks')
    for f in sorted(os.listdir(d)) if osp.isdir(d) else []:
        x = state_read(osp.join(d, f)) if f.endswith('.json') else None
        if x and x.get('task') and isinstance(x.get('track'), dict):
            t['tasks'][x['task']] = x['track']
    t['automerge'].update((state_read(kit_path('automerge')) or {}).get('refs') or {})
    return t

# ---- kitlog: every log line (_paths.log; lib.ps1 Write-KitLog writes the same lines)
LOG = MAP['log']
_MASKS = [(re.compile(p, re.I), re.sub(r'\$(\d)', r'\\g<\1>', r)) for p, r in LOG['mask']]   # case-insensitive, as .NET -replace

def mask(v, d=0):
    """Secrets out of a value: keys matching secretKey -> [redacted], strings through the mask patterns."""
    if isinstance(v, str):
        for rx, r in _MASKS:
            v = rx.sub(r, v)
        return v
    if isinstance(v, dict) and d < 5:
        return {k: '[redacted]' if re.search(LOG['secretKey'], str(k)) else mask(x, d + 1) for k, x in v.items()}
    if isinstance(v, (list, tuple)) and d < 5:
        return [mask(x, d + 1) for x in v]
    return v if v is None or isinstance(v, (bool, int, float)) else mask(str(v))

def log_file(stream, day=None, create=False):
    if stream not in LOG['streams']:
        raise KeyError(f'kitlog: unknown stream {stream!r} (kit.example.json _paths.log.streams)')
    if stream in MAP['durable']:
        return kit_path(stream, create)
    p = osp.join(kit_path('audit'), (day or datetime.date.today()).isoformat(), stream + '.jsonl')
    if create:
        os.makedirs(osp.dirname(p), exist_ok=True)
    return p

def kit_who(args=()):
    """run / agent: KIT_RUN / KIT_AGENT, else the board entry claiming a folder among the arguments."""
    who = {'run': os.environ.get('KIT_RUN', ''), 'agent': os.environ.get('KIT_AGENT', '')}
    dirs = [osp.normcase(osp.abspath(a)) for a in args if isinstance(a, str) and len(a) > 3 and osp.isdir(a)]
    bd = kit_path('board')
    if not who['agent'] and dirs and osp.isdir(bd):
        for n in os.listdir(bd):
            p = osp.join(bd, n)
            if not n.endswith('.json') or time.time() - osp.getmtime(p) > 86400:
                continue
            try:
                e = json.load(open(p, encoding='utf-8-sig'))
            except (OSError, ValueError):
                continue
            if e.get('status') != 'left' and any(d.startswith(osp.normcase(osp.abspath(w))) for w in e.get('worktrees') or [] if w for d in dirs):
                who = {'run': who['run'] or e.get('run') or '', 'agent': e.get('agent') or ''}
                break
    return who

_CALL = {}

def kitlog(stream, event='', fields=None, who=None):
    """Append one masked JSON line to a stream; never raises."""
    try:
        o = {'at': kit_stamp()}
        o.update({k: v for k, v in (who or _CALL.get('who') or kit_who()).items() if v})
        o.update(script=_CALL.get('script', ''), verb=_CALL.get('verb', ''), **({'event': event} if event else {}))
        o.update(mask(fields or {}))
        with open(log_file(stream, create=True), 'a', encoding='utf-8') as fh:
            fh.write(json.dumps(o, ensure_ascii=False, default=str) + '\n')
    except Exception:
        pass

def audited(script, argv, cli):
    """Runs a CLI (cli() -> exit code) between its call lines (stream calls): start with masked arguments, end with rc and ms."""
    sub = 2 if argv[1:2] and re.match(r'^[a-z][\w-]*$', argv[1]) else 1
    _CALL.update(script=script, verb=' '.join(argv[:sub]), who=kit_who(argv))
    out, hide = [], False
    for x in argv[sub:]:
        out.append('[redacted]' if hide else mask(re.sub(r'\s+', ' ', x))[:120])
        hide = x.startswith('-') and bool(re.search(LOG['secretKey'], x))
    kitlog('calls', 'start', {'pid': os.getpid(), 'args': ' '.join(out)[:500]})
    t0, rc, err = time.time(), 1, None
    real_err, said = sys.stderr, []

    class _Tee:   # a usage exit (2) prints its why to stderr only: the call line keeps it too
        def write(self, s):
            if sum(map(len, said)) < 2000:
                said.append(s)
            try:
                return real_err.write(s)
            except (OSError, ValueError):   # a gone or invalid stderr (Errno 22 on Windows) never fails the command (retro 2026-11-23: devtools.py doc)
                return len(s)

        def __getattr__(self, name):
            return getattr(real_err, name)
    sys.stderr = _Tee()
    try:
        rc = cli() or 0
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
        if rc and not isinstance(e.code, int):   # sys.exit('<why>') printed nothing here: callers saw a bare exit 1
            err = str(e.code)
            print(err, file=sys.stderr)
    except Exception as e:   # uncaught error: one readable line (where + why) in output and call log
        at = traceback.extract_tb(e.__traceback__)[-1]
        err = f'{script} {_CALL.get("verb") or ""}: {type(e).__name__}: {e} (at {os.path.basename(at.filename)}:{at.lineno})'
        print(err, file=sys.stderr)
    finally:
        sys.stderr = real_err
        if rc and not err:
            ls = [x.strip() for x in ''.join(said).splitlines() if x.strip()]
            err = next((x for x in ls if 'error:' in x), ls[0] if ls else None)   # argparse: usage first, the why after
        kitlog('calls', 'end', {'pid': os.getpid(), 'rc': rc, 'ms': int((time.time() - t0) * 1000), **({'error': err[:300]} if err else {})})
    return rc

# ---- load: kit files, the reach graph
SKIP_DIRS = {'node_modules', '__pycache__', '.git', '.runtime', '.state', '.claude-runtime', 'worktrees', 'memory'}
# outside the graph: generated ports, git / legal files, assets (README images, never loaded by agents)
REPO_ONLY = ('LICENSE', '.gitignore', '.gitattributes', 'GEMINI.md', '.codex', '.agents', '.github', 'assets')
GENERATED = ('.codex/', '.agents/', 'GEMINI.md')
ASSETS = ('assets/',)   # outside the token budget and the file caps
# caps: content = read by agents / people; plumbing = read only by git, CI, harness
PLUMBING = ('LICENSE', '.gitignore', '.gitattributes', '.githooks/', '.github/', 'settings.json')
START_CAP = 12000   # what one role loads at start (always-loaded + its agent file + its skill + its lessons; lint START-BUDGET)

def size_tokens(kdir, f):   # git blob size (LF: a CRLF checkout must not count more)
    t = read(os.path.join(kdir, f))
    if f == 'README.md':   # generated graph blocks excluded, like ports
        t = re.sub(r'<!-- kit-graph:start .*?<!-- kit-graph:end -->', '', t, flags=re.S)
    return len(t.encode('utf-8')) // 4

def counted_files(kdir):
    """Tracked files the budget counts: all but the generated ports and assets (a deletion not staged yet is gone)."""
    return [x for x in tracked(kdir) if not x.startswith(GENERATED + ASSETS) and osp.isfile(osp.join(kdir, x))]

def split_total(sizes):
    """(repo total, tests total) of {file: tokens}: INFO only; what agents load is capped per role (start_rows)."""
    tests = sum(n for f, n in sizes.items() if f.startswith('tests/'))
    return sum(sizes.values()) - tests, tests

def start_rows(k):
    """[(role, always, own)]: tokens a role loads at start: always-loaded files + every skill description, then its agent file,
    its skill and both LESSONS.md sections. Everything else loads later, through a pointer (progressive)."""
    tok = lambda s: (len(s.encode('utf-8')) + 3) // 4
    ftok = lambda rel: tok(read(osp.join(k.dir, rel)) or '')   # the file as stored (k.texts inlines CLAUDE.md's @AGENTS.md)
    rules = [f for f in k.files if re.match(r'rules/[^/]+\.md$', f) and not f.endswith('.local.md') and 'paths' not in frontmatter(k.texts.get(f, ''))]
    always = ftok('CLAUDE.md') + ftok('AGENTS.md') + sum(ftok(r) for r in rules)
    always += sum(tok(frontmatter(k.texts.get(f'skills/{s}/SKILL.md', '')).get('description', '')) for s in k.skills)
    lessons = k.texts.get('LESSONS.md') or ''
    section_tok = lambda name: tok((re.search(r'^## ' + re.escape(name) + r'\r?\n(.*?)(?=^## |\Z)', lessons, re.S | re.M) or [''])[0])
    rows = []
    for agent, m in (manifest(k.dir).get('agents') or {}).items():
        skill = m.get('skill') or ''
        own = ftok(f'agents/{agent}.md') + (ftok(f'skills/{skill}/SKILL.md') if skill else 0) + sum(section_tok(x) for x in {agent, skill} if x)
        rows.append((agent, always, own))
    return rows

# buildy.js PH: a fresh devy per phase (crafty steps); its lessons: untagged + '- [<phase>|...]' ones (learn -Read -Phase; local reads code)
PHASES = {'devy': {'code': 0, 'local': 5, 'ship': 6}}
PHASE_SEES = {'local': ('local', 'code')}
def phase_rows(k):
    """[(role:phase, always, own)]: a phased role's start per phase: agent file, skill, its lessons for that phase and the entry
    doc the phase prompt names: a Files-index doc whose step range starts at the phase's first step (ship: ship.md); docs read
    later in the phase (templates.md, testing.md, envy) count in READ-BUDGET. Lint START-BUDGET, like start_rows."""
    tok = lambda s: (len(s.encode('utf-8')) + 3) // 4
    lessons = k.texts.get('LESSONS.md') or ''
    section = lambda x: (re.search(r'^## ' + re.escape(x) + r'\r?\n(.*?)(?=^## |\Z)', lessons, re.S | re.M) or [''])[0]
    rows, base = [], {r: (a, o) for r, a, o in start_rows(k)}
    for role, phases in PHASES.items():
        skill = ((manifest(k.dir).get('agents') or {}).get(role) or {}).get('skill') or ''
        if role not in base:
            continue
        always, own = base[role]
        full = sum(tok(section(x)) for x in {role, skill} if x)
        for ph, first in phases.items():
            see = PHASE_SEES.get(ph, (ph,))
            keep = ''.join(l + '\n' for x in {role, skill} if x for l in section(x).splitlines()
                           if not (m := re.match(r'- \[([a-z|]+)\] ', l)) or any(t in see or t not in phases for t in m.group(1).split('|')))
            docs = sum(tok(read(osp.join(k.dir, f)) or '') for n, when, hits in k.index.get(skill, []) for f in hits[:1]
                       if f.endswith('.md') and (m := re.search(r'\bsteps? (\d+)(?:-\d+)?\b', when)) and int(m.group(1)) == first and first)
            rows.append((f'{role}:{ph}', always, own - full + tok(keep) + docs))
    return rows

def phase_sync(k):
    """Phases PHASES names that workflows/buildy.js PH no longer prompts (`PHASE <name>`): START-BUDGET would measure a ghost."""
    wf = k.texts.get('workflows/buildy.js') or ''
    return [f'{r}:{p}' for r, ps in PHASES.items() for p in ps if wf and f'PHASE {p} ' not in wf]
def instr_cap(kdir, key='cap', dflt=75000):
    """budget.instructions.<key> of kit.example.json: cap = kit-instruction tokens one agent may hold (75k at the 200k design
    window), start = a role's kit files at start (START-BUDGET), skillAlways = a SKILL.md (BUDGET skill)."""
    try:
        return int(json.loads(read(osp.join(kdir, PATHS_JSON)))['budget']['instructions'][key])
    except Exception:
        return dflt

def read_rows(k, sizes):
    """[(role, start + required reads, largest reads)]: the worst case of one run: its start, every doc of its skill folder
    and templates.md (lint READ-BUDGET)."""
    rows = []
    for role, always, own in start_rows(k):
        skill = (manifest(k.dir).get('agents') or {}).get(role, {}).get('skill') or ''
        docs = {f: n for f, n in sizes.items() if skill and f.startswith(f'skills/{skill}/') and f.endswith('.md') and not f.endswith('SKILL.md')}
        docs['skills/crafty/templates.md'] = sizes.get('skills/crafty/templates.md', 0)
        rows.append((role, always + own + sum(docs.values()), [f for f, _ in sorted(docs.items(), key=lambda x: -x[1])]))
    return rows
# token budgets (UTF-8 bytes / 4), README "Extending"; skill = its always-part (budget.instructions.skillAlways): the rest in references
BUDGETS = {'always': 3500, 'skill': 3000, 'agent': 2400, 'rule': 900, 'template': 2600, 'templates': 4000, 'doc': 7000, 'lessons': 30000,
  'workflow': 16500, 'ps1': 58000, 'py': 77000, 'mjs': 8000, 'json': 7000, 'config': 9975, 'tests': 9000}   # config +5% (retro 1549: 3-6 lint rounds per new key)

def budget_type(f):
    """The BUDGETS key of a tracked kit file (relative, /), None = no per-file cap (CLAUDE.md, AGENTS.md: the 'always' cap)."""
    b = osp.basename(f)
    if f in ('CLAUDE.md', 'AGENTS.md'):
        return None
    if f.startswith('tests/'):
        return 'tests'
    if b == 'SKILL.md':
        return 'skill'
    if f.startswith('agents/'):
        return 'agent'
    if f.startswith('rules/'):
        return 'rule'
    if b == 'LESSONS.md':
        return 'lessons'
    if f == 'README.md':
        return 'doc'
    if f == 'skills/crafty/templates.md':   # every template + Writing standards
        return 'templates'
    if f.startswith('workflows/'):
        return 'workflow'
    if f == PATHS_JSON:   # every config key's sample + doc, read on demand (never at start)
        return 'config'
    if f.endswith('.md'):
        return 'template'
    ext = osp.splitext(f)[1][1:]
    return ext if ext in BUDGETS else None
# files allowed raw runtime paths (lint RUNTIME-RAW)
PATHS_JSON = 'skills/crafty/kit.example.json'
PATH_HELPERS = {PATHS_JSON, 'skills/crafty/lib.ps1', 'skills/crafty/devtools.py', 'skills/pokey/browser.mjs', 'skills/bossy/kitbag.py', 'skills/crafty/spec.mjs',
                'skills/bossy/ctx_hook.mjs'}   # a per-call hook: no helper import (browser.mjs loads puppeteer)
TEXT_EXT = ('.md', '.ps1', '.psm1', '.py', '.js', '.mjs', '.json', '.html', '.txt', '.sh', '.yml', '.yaml', '.ini')
JUNK_EXT = ('.apk', '.aab', '.log', '.zip', '.tmp')
RESERVED = {'nul', 'con', 'prn', 'aux'}
BLOCKS = ('Load when', 'Not when', 'Hands off to', 'Files')
LESSON_SHAPE = re.compile(r'^- (?:\(fixed in kit\) )?\S.*? -> \S.*\((?!\d+[x×]\)).+?\)')   # - <when> -> <do> (<why>) [. <appended>] [(n×)]
FUZZY = re.compile(r'(?<!")read (it |this )?(only )?when (you need|needed)|\(read only when', re.I)   # quoted = named, not used
IMPORT_RE = re.compile(r'^@([\w./-]+\.md)\s*$', re.MULTILINE)

def resolve_imports(text, base_dir, _seen=None):
    """Expand Claude Code's `@<path>.md` import lines (CLAUDE.md -> AGENTS.md) so text checks see what Claude Code loads."""
    seen = _seen if _seen is not None else set()

    def repl(m):
        path = m.group(1)
        if path in seen:
            return ''
        full = osp.join(base_dir, path)
        if not osp.isfile(full):
            return m.group(0)
        seen.add(path)
        return resolve_imports(read(full), base_dir, seen)

    return IMPORT_RE.sub(repl, text)

def read(p, raw=False):
    """File text with LF line endings (a core.autocrlf clone checks out CRLF); raw=True keeps them (WF-CRLF)."""
    try:
        with open(p, encoding='utf-8', errors='replace', newline='') as f:
            text = f.read()
    except OSError:
        return ''
    return text if raw else text.replace('\r\n', '\n')

def frontmatter(text):
    m = re.match(r'^---\s*\n(.*?)\n---', text, re.S)
    fm, key = {}, None
    if not m:
        return fm
    for line in m.group(1).splitlines():
        mm = re.match(r'^([\w-]+):\s*(.*)$', line)
        if mm:
            key, val = mm.group(1), mm.group(2).strip()
            fm[key] = '' if val in ('>-', '>', '|', '|-') else val.strip('"\'')
        elif key and line.startswith((' ', '\t')):
            fm[key] = (fm[key] + ' ' + line.strip().strip('"\'')).strip()
    return fm

def section(text, heading):
    m = re.search(r'^##\s+' + re.escape(heading) + r'.*?$(.*?)(?=^##\s|\Z)', text, re.S | re.M)
    return m.group(1) if m else None

def norm(s):
    return re.sub(r'\s+', ' ', re.sub(r'[`*_]', '', s)).strip().lower()

def table_rows(text):
    """Data rows of the first Markdown table in text, as lists of cells."""
    rows = [l for l in (text or '').splitlines() if l.startswith('|')]
    out = []
    for l in rows[1:]:
        if re.match(r'^\|[\s:|-]+\|?$', l):
            continue
        out.append([c.strip() for c in l.strip().strip('|').split('|')])
    return out

class Kit:
    """Everything load() reads (annotated for editors and type checkers)."""
    dir: str
    repo_files: List[str]
    all: List[str]
    junk: List[Tuple[str, str]]
    local_rules: List[str]
    files: List[str]
    fileset: Set[str]
    local_only: List[str]
    skills: List[str]
    agents: Dict[str, str]
    workflows: Dict[str, str]
    texts: Dict[str, str]
    router: Optional[str]
    org_rows: str
    index: Dict[str, list]

def main_clone(d):
    """Main worktree of the repo holding d (d itself if not a linked worktree or git fails)."""
    rc, common, _ = git(d, 'rev-parse', '--path-format=absolute', '--git-common-dir', timeout=20)
    return osp.dirname(osp.normpath(common)) if rc == 0 and common else d

def stray_live(d, minutes=60, cap=2000):
    """True when a file under d changed in the last `minutes` (a bounded walk: at most `cap` files)."""
    if stray_link(d):
        return False   # a junction into the kit runtime: its fresh files are the kit's own writes (a stuck WARN, 2026-11-23)
    cut, n = time.time() - minutes * 60, 0
    for root, _, files in os.walk(d):
        for f in files:
            n += 1
            with contextlib.suppress(OSError):
                if os.path.getmtime(osp.join(root, f)) > cut:
                    return True
            if n >= cap:
                return False
    return False


def stray_link(d):
    """True when d is a symlink or a Windows junction."""
    return osp.islink(d) or getattr(osp, 'isjunction', lambda _: False)(d)


def stray_runtimes(kit):
    """<workspace>/.runtime folders up to 3 levels deep that are no kit checkout's own (an installed <workspace>/.claude only)."""
    main = main_clone(kit)
    if osp.basename(osp.normpath(main)) != '.claude':
        return []
    ws, rt, out = osp.dirname(osp.normpath(main)), MAP['runtimeDir'], []
    level = [ws]
    for depth in range(3):
        out += [osp.join(d, rt) for d in level if osp.isdir(osp.join(d, rt)) and not osp.isfile(osp.join(d, 'skills', 'crafty', 'crafty.ps1'))]
        nxt = []
        for d in level if depth < 2 else []:
            with contextlib.suppress(OSError):
                nxt += [osp.join(d, x) for x in os.listdir(d) if x not in SKIP_DIRS and osp.isdir(osp.join(d, x))]
        level = nxt
    return [p for p in out if osp.normcase(osp.abspath(p)) != osp.normcase(osp.abspath(runtime_dir(main)))]

def load(kit):
    k = Kit()
    k.dir = osp.abspath(kit)
    ign = [l.strip() for l in read(osp.join(k.dir, '.gitignore')).splitlines() if l.strip() and not l.startswith('#')]

    def ignored(rel):
        parts = rel.split('/')
        for pat in ign:
            anchored = pat.startswith('/')
            pat = pat.lstrip('/').replace('**/', '')
            if pat.endswith('/'):
                d = pat.rstrip('/')
                if '/' in d or anchored:
                    if rel.startswith(d + '/') or fnmatch.fnmatch(rel, d + '/*'):
                        return True
                elif any(fnmatch.fnmatch(p, d) for p in parts[:-1]):
                    return True
            elif '/' in pat or anchored:
                if fnmatch.fnmatch(rel, pat):
                    return True
            elif fnmatch.fnmatch(parts[-1], pat):
                return True
        return False

    allf, junk, repo_files = [], [], []
    for d, dirs, fs in os.walk(k.dir):
        top = osp.relpath(d, k.dir) == '.'
        skip = SKIP_DIRS if top else SKIP_DIRS - {'.runtime', '.state', '.claude-runtime', 'worktrees', 'memory'}   # runtime, harness worktrees, memory: kit root only
        dirs[:] = [x for x in dirs if x not in skip]
        for f in fs:
            rel = osp.relpath(osp.join(d, f), k.dir).replace('\\', '/')
            if rel.split('/')[0] in REPO_ONLY:
                repo_files.append(rel)
            elif rel == '.git':   # a worktree's .git file
                continue
            elif f.lower() in RESERVED:
                junk.append((rel, 'reserved-name file (delete it)'))
            elif f.lower().endswith(JUNK_EXT):
                junk.append((rel, 'runtime output among the kit files (runtime belongs in <kit>/.runtime: Get-KitPath; delete it once unused)'))
            else:
                allf.append(rel)
    k.all = sorted(allf)
    k.repo_files = sorted(repo_files)
    k.junk = junk
    k.local_rules = [f for f in k.all if re.match(r'rules/[^/]+\.local\.md$', f)]
    try:
        lj = osp.join(k.dir, 'skills', 'crafty', 'kit.local.json')
        if not osp.isfile(lj):
            lj = osp.join(main_clone(k.dir), 'skills', 'crafty', 'kit.local.json')
        cfg = json.loads(read(lj) or '{}')
        k.local_only = [p.replace('\\', '/').rstrip('/') for p in cfg.get('localOnly', [])]
    except ValueError:
        k.local_only = []
    # published files + local overlay (local skills, project profiles); not configs, state, shims, other git-excluded strays
    gi = git_ignored(k.dir, k.all)
    k.files = sorted(f for f in k.all if f in k.local_rules or not (ignored(f) or (f in gi and not is_overlay(k, f))))
    k.fileset = set(k.files)
    k.skills = sorted({f.split('/')[1] for f in k.files if re.match(r'skills/[^/]+/SKILL\.md$', f)})
    k.agents = {f[7:-3]: f for f in k.files if re.match(r'agents/[^/]+\.md$', f)}
    k.workflows = {f[10:-3]: f for f in k.files if re.match(r'workflows/[^/]+\.js$', f)}
    k.texts = {f: read(osp.join(k.dir, f)) for f in k.files if f.lower().endswith(TEXT_EXT)}
    for f in k.texts:
        if f.lower().endswith('.md'):
            k.texts[f] = resolve_imports(k.texts[f], k.dir)
    claude = k.texts.get('CLAUDE.md', '')
    k.router = section(claude, 'Router')
    k.org_rows = ''.join(section(k.texts.get(r, ''), 'Org router rows') or '' for r in k.local_rules)
    k.index = {}   # skill -> [(entry as written, when-cell, [matching files])]
    for s in k.skills:
        base = f'skills/{s}/'
        text = k.texts.get(base + 'SKILL.md', '')
        m = re.search(r'^\*\*Files:?\*\*[^\n]*\n(?:[ \t]*\n)*((?:\|.*\n?)+)', text, re.M)
        entries = []
        for cells in table_rows(m.group(1) if m else ''):
            if len(cells) < 2 or cells[0].lower() in ('file', 'files'):
                continue
            for n in re.findall(r'`([^`]+)`', cells[0]):
                n = n.strip()
                if n.startswith('<kit>/'):   # a kit-level file bound to a skill step
                    hits = [f for f in k.files if f == n[6:]]
                    entries.append((n, cells[1], hits))
                    continue
                pat = re.sub(r'<[^>]+>', '*', n)
                hits = [f for f in k.files if f.startswith(base) and fnmatch.fnmatch(f[len(base):], pat)]
                entries.append((n, cells[1], hits))
        k.index[s] = entries
    return k

def skill_of(f):
    return f.split('/')[1] if f.startswith('skills/') and f.count('/') >= 2 else None

def is_overlay(k, f):
    """An org-only file (*.local.*, a kit.local.json localOnly path): never published, never registered."""
    return '.local.' in osp.basename(f) or any(f == p or f.startswith(p + '/') for p in k.local_only)

def file_kind(f, texts, hook_targets):
    b = osp.basename(f)
    if f in ('CLAUDE.md', 'AGENTS.md'):
        return 'root'
    if f == 'README.md':
        return 'doc'
    if f.startswith('.githooks/') or f in hook_targets:
        return 'hook'
    if f.startswith('tests/'):
        return 'script'
    if f.startswith('examples/') or b == 'templates.md' or '/templates/' in f:
        return 'template'
    if f.startswith('rules/'):
        return 'rule-scoped' if 'paths' in frontmatter(texts.get(f, '')) else 'rule'
    if b.startswith('settings') and b.endswith('.json') and '/' not in f:
        return 'settings'
    if f.startswith('agents/'):
        return 'agent'
    if f.startswith('workflows/'):
        return 'workflow'
    if b == 'SKILL.md':
        return 'skill'
    if b == 'LESSONS.md':
        return 'lessons'
    if b == 'HISTORY.md':
        return 'history'
    if '/reference/' in f:
        return 'reference'
    if '.example.' in b or b.endswith('.local.json'):
        return 'config'
    if f.endswith(('.ps1', '.psm1', '.py', '.js', '.mjs', '.sh')):
        return 'script'
    return 'other'

def graph(k):
    """Kit files as nodes and the references between them as typed edges; reach = how a file is found from CLAUDE.md."""
    texts, fileset = k.texts, k.fileset
    by_base = defaultdict(list)
    for f in k.files:
        by_base[osp.basename(f).lower()].append(f)
    hook_targets = set()
    try:
        for blocks in (json.loads(texts.get('settings.json', '{}') or '{}').get('hooks') or {}).values():
            for h in (h for b in blocks for h in b.get('hooks', [])):
                m = re.search(r'\.claude[\\/]([\w./\\-]+\.(?:ps1|py|js|sh))', ' '.join([h.get('command', '')] + list(h.get('args', []))))
                if m and m.group(1).replace('\\', '/') in fileset:
                    hook_targets.add(m.group(1).replace('\\', '/'))
    except ValueError:
        pass
    nodes = {f: {'kind': file_kind(f, texts, hook_targets), 'local': is_overlay(k, f)} for f in k.files}
    always = {f for f, n in nodes.items() if n['kind'] in ('root', 'rule')}
    edges = {}

    def etype(src, dst):
        ks, kd = nodes[src]['kind'], nodes[dst]['kind']
        if ks == 'settings' and kd == 'hook':
            return 'hook'
        if src in always and kd in ('skill', 'workflow', 'agent'):
            return 'route'
        if ks == 'rule-scoped' and kd in ('skill', 'workflow', 'agent', 'reference', 'script'):
            return 'scoped'
        if ks == 'workflow' and kd == 'agent':
            return 'spawn'
        if ks in ('lessons', 'history'):
            return 'mention'
        if ks == 'skill' and skill_of(dst) == skill_of(src):
            return 'index'
        if kd == 'skill':
            return 'loads'
        if ks in ('script', 'hook') and kd in ('script', 'hook'):
            return 'calls'
        if ks in ('reference', 'template') and skill_of(src) == skill_of(dst) and kd in ('reference', 'template', 'script'):
            return 'index'
        return 'mention'

    def add(src, dst, typ=None):
        if src != dst and dst in nodes:
            if typ:
                edges[(src, dst)] = typ
            else:
                edges.setdefault((src, dst), etype(src, dst))

    for f, n in nodes.items():   # the harness loads settings and rules with CLAUDE.md
        if n['kind'] in ('settings', 'rule', 'rule-scoped') and 'CLAUDE.md' in nodes:
            add('CLAUDE.md', f, 'route')
    for s, entries in k.index.items():   # Files index = explicit path into a skill (globs cover overlay files)
        for _, _, hits in entries:
            for h in hits:
                add(f'skills/{s}/SKILL.md', h, 'index')
    if 'CLAUDE.md' in nodes and 'AGENTS.md' in nodes:
        add('CLAUDE.md', 'AGENTS.md', 'import')
    router_file = 'AGENTS.md' if 'AGENTS.md' in nodes else 'CLAUDE.md'
    for cells in table_rows(k.router or ''):
        target = ' '.join(cells[2:3])
        for s in k.skills:
            if re.search(r'`' + re.escape(s) + r'[`\s]', target):
                add(router_file, f'skills/{s}/SKILL.md', 'route')
        for w, p in k.workflows.items():
            if '/' + w in target:
                add(router_file, p, 'route')
        for a, p in k.agents.items():
            if '`' + a + '`' in target:
                add(router_file, p, 'route')
    path_rx = re.compile(r'[\w./\\<>*{}$-]*?([\w.-]+\.(?:md|ps1|psm1|py|js|mjs|json|html|txt|sh|ini))\b')
    for src, text in texts.items():
        sdir = osp.dirname(src)
        for m in path_rx.finditer(text):
            full = m.group(0).replace('\\', '/').strip('`\'"()[],:;')
            hit = next((c for c in (osp.normpath(osp.join(sdir, full)).replace('\\', '/'), re.sub(r'^.*?\.claude/', '', full),
               ('skills/' + full.split('skills/', 1)[1]) if 'skills/' in full else None) if c and c in fileset), None)
            if not hit:   # a bare name: the only file so named, or the one in the same skill
                hits = by_base.get(m.group(1).lower(), [])
                same = [h for h in hits if skill_of(h) and skill_of(h) == skill_of(src)]
                hit = (same or hits or [None])[0] if (len(hits) == 1 or same) else None
            if hit:
                add(src, hit)
        for name, f in [(s, f'skills/{s}/SKILL.md') for s in k.skills] + list(k.agents.items()):
            if re.search(r'(?<![\w-])' + re.escape(name) + r'(?![\w-])', text):
                add(src, f)
        for name, f in k.workflows.items():
            if re.search(r'(?<![\w-])/?' + re.escape(name) + r'(?![\w-])', text):
                add(src, f)
    for tgt in hook_targets:
        if 'settings.json' in nodes:
            edges[('settings.json', tgt)] = 'hook'
    for f in nodes:   # tests/kit-tests.ps1 runs every tests/*.tests.ps1 (a glob, no names)
        if re.match(r'tests/[^/]+\.tests\.ps1$', f):
            add('tests/kit-tests.ps1', f, 'calls')
    entries = [f for f in ('CLAUDE.md',) if f in nodes] or [f for f, n in nodes.items() if n['kind'] == 'root']   # ONE root
    out = defaultdict(list)
    for (a, b), typ in edges.items():
        out[a].append((b, typ))

    def reach(start, follow):
        seen, q = set(start), deque(start)
        while q:
            for nxt, typ in out[q.popleft()]:
                if follow(typ) and nxt not in seen:
                    seen.add(nxt)
                    q.append(nxt)
        return seen
    structural = reach(entries, lambda typ: typ != 'mention')
    anyhow = reach(structural, lambda typ: True)
    from_skill = reach([f for f, n in nodes.items() if n['kind'] == 'skill'], lambda typ: typ != 'mention')   # lint ORPHAN-DOC
    for f, n in nodes.items():
        n['reach'] = 'entry' if f in entries else 'structural' if f in structural else 'mention-only' if f in anyhow else 'none'
        n['from_skill'] = f in from_skill
    return {'nodes': nodes, 'edges': edges}

# ---- lint: the checks (problem codes: kit-admin.md)
def js_code(src):
    """Workflow source with comments and string/template literals removed (to look at code only)."""
    out, i, n, st = [], 0, len(src), None
    while i < n:
        c, c2 = src[i], src[i:i + 2]
        if st is None:
            if c2 == '//':
                j = src.find('\n', i); i = n if j < 0 else j; continue
            if c2 == '/*':
                j = src.find('*/', i + 2); i = n if j < 0 else j + 2; continue
            if c in '\'"`':
                st = c; i += 1; continue
            out.append(c)
        elif c == '\\':
            i += 1
        elif c == st:
            st = None
        i += 1
    return ''.join(out)

def lint(k, g=None, org_terms=None):
    probs = []

    def bad(code, where, msg):
        probs.append((code, where, msg))

    g = g or graph(k)
    # ---- router
    if k.local_rules and not k.org_rows:
        bad('OVERLAY-ROUTER', 'rules/*.local.md', 'no "## Org router rows" section: add one (router format) for org-only skills and needs')
    router = k.router
    if router is None:
        bad('ROUTER-MISSING', 'CLAUDE.md', 'no "## Router" section')
        router = ''
    targets = set(k.skills) | {'/' + w for w in k.workflows} | set(k.agents)
    rows = table_rows(router)
    if not rows:
        bad('ROUTER-MISSING', 'CLAUDE.md', 'the Router section has no table rows')
    for cells in rows + table_rows(k.org_rows):
        if len(cells) < 3:
            bad('ROUTER-TARGET', 'router', f'row needs # | conditions | target: {" | ".join(cells)[:60]}')
            continue
        found = {t for t in targets if re.search(r'`' + re.escape(t) + r'[`\s]', cells[2])}
        if len(found) + (1 if re.search(r'\bdirect\b|org row', cells[2], re.I) else 0) != 1:
            bad('ROUTER-TARGET', 'router', f'row {cells[0]}: exactly one target expected, got {sorted(found) or "none"}')
    routed = router + '\n' + k.org_rows
    for s in k.skills:
        if '`' + s + '`' not in routed:
            bad('ROUTER-UNROUTED', f'skills/{s}', 'skill not named (`name`) in the CLAUDE.md router or the org router rows')
    for w in k.workflows:
        if '/' + w not in routed:
            bad('ROUTER-UNROUTED', f'workflows/{w}.js', 'workflow not named (/name) in the router')
    for a in k.agents:
        if '`' + a + '`' not in routed:
            bad('ROUTER-UNROUTED', f'agents/{a}.md', 'agent type not named in the router section (say who spawns it)')
    # ---- skills
    for s in k.skills:
        base, p = f'skills/{s}/', f'skills/{s}/SKILL.md'
        text = k.texts.get(p, '')
        desc = frontmatter(text).get('description', '')
        if not re.match(r'^Load when: .+ Not when: .+->', desc, re.S):
            bad('SKILL-DESC', p, 'description must read "Load when: <conditions>. Not when: <condition> -> <sibling>. ..."')
        if len(desc) > 450:
            bad('SKILL-DESC', p, f'description is {len(desc)} chars (keep it under ~400)')
        for blk in BLOCKS:
            if not re.search(r'^\*\*' + blk + r':?\*\*', text, re.M):
                bad('SKILL-BLOCK', p, f'no **{blk}** block')
        listed = set()
        for n, when, hits in k.index.get(s, []):
            listed.update(hits)
            # absolute = a tool outside the kit: check on disk
            absolute = re.match(r'^(?:[A-Za-z]:[\\/]|/|~[\\/])', n)
            if absolute and osp.exists(osp.expanduser(n)):
                continue
            if not hits and '*' not in n and '<' not in n:
                bad('FILES-MISSING', p, f'Files index lists {n}, which does not exist' + (' (absolute path, not found on this machine)' if absolute else ''))
            if (re.match(r'(reference|templates)/', n) or n.endswith('templates.md')) and not re.search(r'\bsteps?\b|\b[A-Z]\d+[a-z]?\b', when, re.I):
                bad('FILES-UNBOUND', p, f'{n}: say at which step (or event row) it is read or filled')
            if osp.basename(n) == 'LESSONS.md' and not re.search(r'step [A-Z]?0\b|\bstart|\bfirst|before anything', when, re.I):
                bad('FILES-UNBOUND', p, 'LESSONS.md must be read at the start (step 0)')
        for f in k.files:
            if f.startswith(base) and f != p and f not in listed:
                bad('FILES-UNLISTED', p, f'{f[len(base):]} is not in the Files index (add it with the step that reads or runs it)')
        for f in [p] + [f for f in k.files if f.startswith(base + 'reference/') and f.endswith('.md')]:
            if FUZZY.search(k.texts.get(f, '')):
                bad('SKILL-FUZZY', f, '"read when you need it" trigger: bind the file to a numbered step')
    # ---- workflows
    rnorm = norm(routed)
    for w, p in k.workflows.items():
        src = k.texts.get(p, '')
        m = re.search(r"whenToUse:\s*'((?:[^'\\]|\\.)*)'", src)
        if not m:
            bad('WF-WHEN', p, 'meta.whenToUse missing')
        elif norm(m.group(1)) not in rnorm:
            bad('WF-WHEN', p, 'meta.whenToUse is not word for word the conditions of a router row')
        if re.search(r'\bDate\.now\s*\(|\bnew\s+Date\s*\(', js_code(src)):
            bad('WF-CLOCK', p, 'workflow code reads the clock (Date.now / new Date): it breaks resume')
        if '\r' in read(osp.join(k.dir, p), raw=True):
            bad('WF-CRLF', p, 'CR line endings (workflow scripts must be LF)')
    # ---- agents
    agent_skill = {a: m.get('skill') for a, m in (manifest(k.dir).get('agents') or {}).items()}
    for a, p in k.agents.items():
        text = k.texts.get(p, '')
        desc = frontmatter(text).get('description', '')
        if 'Spawned by' not in desc:
            bad('AGENT-SPAWN', p, 'description must say "Spawned by <workflow / coordinator> ..."')
        if 'Not for' not in desc:
            bad('AGENT-SPAWN', p, 'description must say "Not for: ..."')
        if agent_skill.get(a) != '' and not any(f'skills/{s}/SKILL.md' in text for s in k.skills):   # _manifest skill "" = loads none
            bad('AGENT-SKILL', p, 'body must name the skill (skills/<name>/SKILL.md) it loads first')
    # ---- dangling kit paths (Markdown, workflow prompts)
    ext = r'\.(md|ps1|py|mjs|js|json|html|ini|txt)$'
    skip = re.compile(r'[<>*{}$]|\.local\.|^(examples)/|swarm\.(config\.)?json$|^https?:|\.(?:claude-)?runtime|\.state/|^~|^\.\.\./')
    basenames = {osp.basename(f) for f in k.files}
    kit_dirs = tuple(['skills/', 'rules/', 'agents/', 'workflows/'] + [s + '/' for s in k.skills])
    for f in k.files:
        if not f.endswith('.md') or f.endswith('LESSONS.md'):
            continue
        fdir, sk = osp.dirname(f), skill_of(f)
        for tok in re.findall(r'`([^`\n]+)`', k.texts.get(f, '')):
            t = (tok.strip().split() or [''])[0].replace('\\', '/')
            t = re.sub(r'^(<workspace>/)?\.claude/|^<kit>/', '', t).rstrip('.,;:)')
            if not re.search(ext, t) or skip.search(t) or re.match(r'^([A-Za-z]:)?/', t):
                continue   # outside the kit on purpose
            if is_overlay(k, f) and not t.startswith(kit_dirs):
                continue   # org overlay: only kit paths checked
            if t.split('/')[0] in REPO_ONLY:   # docs/examples ship in every clone
                if t not in k.repo_files:
                    bad('REF-DANGLING', f, f'{t}: no such file in the kit repo')
                continue
            if osp.basename(t).startswith('.'):
                continue
            if '/' not in t:
                if t.endswith(('.ps1', '.py', '.mjs')) and t not in basenames:
                    bad('REF-DANGLING', f, f'{t}: no such kit script')
                continue
            cands = [t, osp.normpath(osp.join(fdir, t)).replace('\\', '/'), 'skills/' + t]
            if sk:   # skill-relative, ../other-skill/ too
                cands.append(osp.normpath(f'skills/{sk}/{t}').replace('\\', '/'))
            cands += [f'skills/{s}/{t}' for s in k.skills]   # skill-relative path in another part's text
            if not any(c in k.fileset or c in k.all for c in cands):
                bad('REF-DANGLING', f, f'{t}: no such kit file')
    # ---- reach from CLAUDE.md
    for f, n in sorted(g['nodes'].items()):
        if (n['kind'] in ('history', 'other', 'config') and n['local']) or (osp.basename(f).startswith('.') and not f.startswith('.githooks/')):
            continue   # git / harness dotfiles: not via the router
        if n['reach'] == 'none' and n['kind'] != 'history':
            bad('REACH-NONE', f, 'unreached: nothing in the kit leads here')
        elif n['reach'] == 'mention-only' and n['kind'] != 'history':
            bad('REACH-MENTION', f, 'reached only through a mention: list it in a Files index or the router')
    for f, why in k.junk:
        bad('JUNK', f, why)
    for why in artefact_lint(k.dir, {osp.basename(x) for x in k.files}):
        bad('ARTEFACT', STATE_DOC, why)
    sch = re.search(r'(?s)const CHECKS_SCHEMA = \{.*?checks: \{.*?properties: \{(.*?)\n {4}\},\n {4}required', k.texts.get('workflows/testy.js', ''))
    rk = re.search(r"\$script:ResultRowKeys = ([^\n]+)", k.texts.get('skills/pokey/pokey.ps1', ''))
    if sch and rk:   # pokey.ps1 results patch refuses keys the tester schema lacks
        lost = sorted(set(re.findall(r'(?m)^ {5}(\w+):', sch.group(1))) - set(re.findall(r"'(\w+)'", rk.group(1))))
        if lost:
            bad('RESULT-KEYS', 'skills/pokey/pokey.ps1', f'$script:ResultRowKeys lacks testy.js CHECKS_SCHEMA row key(s) {", ".join(lost)}')
    elif k.texts.get('workflows/testy.js') and k.texts.get('skills/pokey/pokey.ps1'):
        bad('RESULT-KEYS', 'workflows/testy.js', 'CHECKS_SCHEMA rows or pokey.ps1 $script:ResultRowKeys not found (the results row schema)')
    for d in stray_runtimes(k.dir):
        if stray_live(d):   # a live run still writes there: never block an unrelated commit; counted once it is idle
            print(f'WARN RUNTIME-STRAY {d}: a live run writes there (changed in the last hour): move it once that run ends', file=sys.stderr)
            continue
        if stray_link(d):
            print(f'WARN RUNTIME-STRAY {d}: a link to {osp.realpath(d)} (writes land there): repoint run.json files that name it, '
                  'then delete the link only (rmdir, never its content)', file=sys.stderr)
            continue
        bad('RUNTIME-STRAY', d, f'a {MAP["runtimeDir"]} outside the kit (a relative path from the wrong folder; the guard denies new ones): '
            f'move what is needed under <kit>/{MAP["runtimeDir"]} (crafty.ps1 dir), then delete it')
    # ---- file caps (ports excluded), per group
    counted = counted_files(k.dir) or [x for x in k.files if not x.startswith(GENERATED)]
    plumbing = [x for x in counted if x.startswith(PLUMBING)]
    content = [x for x in counted if x not in plumbing and x.endswith('.md')]   # docs agents or people read; scripts run, never read
    caps = manifest(k.dir).get('caps') or {}
    if not all(isinstance(caps.get(x), int) for x in ('content', 'plumbing')):
        bad('MANIFEST', PATHS_JSON, '_manifest.caps needs integer content and plumbing')
        caps = {'content': 30, 'plumbing': 8, **caps}
    cap_c, cap_p = caps['content'], caps['plumbing']
    if len(content) > cap_c:
        bad('FILE-CAP', 'kit', f'{len(content)} docs (cap {cap_c}: .md files outside .githooks / .github; ports excluded): merge docs '
         '(kit-admin.md "Hard rules")')
    if len(plumbing) > cap_p:
        bad('PLUMBING-CAP', 'kit', f'{len(plumbing)} plumbing files (cap {cap_p}: LICENSE, .gitignore, .gitattributes, .githooks/*, '
         f'.github/*, settings.json): {", ".join(plumbing)}')
    # ---- token budgets: per role (and devy phase) at start, per file type
    for role, always, own in start_rows(k) + phase_rows(k):
        if always + own > instr_cap(k.dir, 'start', START_CAP):
            bad('START-BUDGET', f'agents/{role.split(":")[0]}.md', f'{role} loads {always + own} tokens at start (always-loaded {always} + own {own}; cap '
                f'{START_CAP}): move detail behind a pointer (a doc its skill names at the step that needs it)')
    for ghost in phase_sync(k):
        bad('START-BUDGET', 'workflows/buildy.js', f'{ghost}: kitbag.py PHASES names a phase PH no longer prompts ("PHASE <name> "): update PHASES')
    sizes = {f: size_tokens(k.dir, f) for f in counted}
    icap = instr_cap(k.dir)
    for role, total, reads in read_rows(k, sizes):
        if total > icap:
            bad('READ-BUDGET', f'agents/{role}.md', f'{role} start + every doc its skill can read = {total} tokens (cap {icap}, '
                f'budget.instructions.cap): split a reference so a step reads only its section ({", ".join(reads[:4])})')
    caps_t = {**BUDGETS, 'skill': instr_cap(k.dir, 'skillAlways', BUDGETS['skill'])}
    over = [(f, n, caps_t[b]) for f, n in sizes.items() if (b := budget_type(f)) and n > caps_t[b]]
    always = sum(sizes.get(f, 0) for f in ('CLAUDE.md', 'AGENTS.md') + tuple(f for f in counted if re.match(r'rules/[^/]+\.md$', f) and 'paths' not in frontmatter(k.texts.get(f, ''))))
    if always > BUDGETS['always']:
        over.append(('always-loaded (CLAUDE.md + AGENTS.md + rules)', always, BUDGETS['always']))
    for f, n, cap in over:
        fix = 'move a self-contained block to an area file with room' if f.startswith('tests/') else 'trim it (dense prose, dedupe) or move text to a file with room'
        bad('BUDGET', f, f'{n} tokens (cap {cap}): {fix}')
    # ---- ORPHAN-DOC: a doc outside the start set is found through a skill (its Files index, or a doc that one leads to)
    for f, n in sorted(g['nodes'].items()):
        if f.endswith('.md') and n['kind'] in ('reference', 'template', 'other', 'config') and not n['local'] and not n.get('from_skill') \
           and f != 'README.md' and not f.startswith(('.githooks/', '.github/')):
            bad('ORPHAN-DOC', f, 'no SKILL.md pointer leads here: name it in the Files index of the skill whose step reads it')
    for f in k.files:   # scripts are run (their --help, header, output), never loaded as reading
        for i, line in enumerate((k.texts.get(f, '') if f.endswith('.md') and f != 'LESSONS.md' else '').split('\n')):
            if re.search(r'(?i)\b(read|open|load)s?\b[^.`]{0,20}`[^`]+\.(ps1|py|mjs|js)`', line):
                bad('SCRIPT-READ', f'{f}:{i + 1}', 'a doc names a script as text to read: say which verb to run (its header prints the usage)')
    # ---- CI workflow YAML (an invalid one fails its run in 0 s)
    for f in counted:
        if re.match(r'\.github/workflows/[^/]+\.ya?ml$', f):
            for ln, why in yaml_problems(read(osp.join(k.dir, f))):
                bad('YAML', f, f'line {ln}: {why}')
    # ---- script headers: usage + exit codes up top
    for f in counted:
        if not f.endswith(('.ps1', '.py', '.mjs')) or f.startswith(GENERATED):
            continue
        head = '\n'.join(k.texts.get(f, '').splitlines()[:40])
        if not re.search(r'Exit codes?:', head, re.I) or not re.search(r'usage|verbs?:|\bpython\b|\bpwsh\b|^\s*[#/]*\s*&\s', head, re.I | re.M):
            bad('SCRIPT-HEADER', f, 'no header block with usage and "Exit codes:" in the first 40 lines (kit-admin.md "Script header")')
    # ---- section maps: "Sections:" line vs markers; every function and verb in a section
    # Windows PowerShell 5 misreads BOM-less UTF-8 and pwsh 7 syntax: the line stops it with a clear message
    for f in [x for x in counted if x.endswith('.ps1') and not x.startswith(GENERATED)]:
        if not re.search(r'^#requires\s+-version\s+7', read(osp.join(k.dir, f)), re.I | re.M):
            bad('PS-VERSION', f, 'no "#Requires -Version 7" line (Windows PowerShell 5 cannot run kit scripts)')
    for f in sec_files(list(counted)):
        for c, w, m in sec_check(f, read(osp.join(k.dir, f)))[0]:
            bad(c, w, m)
    # ---- nothing opens on the desktop without --open / -Open
    rx_open = {'.py': r'os\.startfile\(|webbrowser\.open|\[\s*[\'"](?:xdg-open|open)[\'"]',
       '.ps1': r'^\s*(?:Invoke-Item|ii)\s|Start-Process\s+(?:-FilePath\s+)?[\'"]?(?:https?://|[^\s\'"]+\.(?:html?|md|pdf|png|jpe?g|txt|csv|log)\b)|\bcmd(?:\.exe)?\s+/c\s+start\b|^\s*(?:start|explorer(?:\.exe)?)\s+\S',
       '.mjs': r'\bexec(?:Sync)?\(\s*[\'"`](?:start|open|xdg-open)\s|\bimport\s.*[\'"]open[\'"]',
       '.js': r'\bexec(?:Sync)?\(\s*[\'"`](?:start|open|xdg-open)\s'}
    for f in counted:
        ext = osp.splitext(f)[1]
        if ext not in rx_open or f.startswith(GENERATED):
            continue
        ls = k.texts.get(f, '').splitlines()
        for i, line in enumerate(ls):
            if re.match(r'\s*(#|//|@\(\s*'')', line) or not re.search(rx_open[ext], line):   # comments, guard self-test data
                continue
            if not re.search(r'--open|\$Open\b|open_it|opts\.open', '\n'.join(ls[max(0, i - 5):i + 1])):
                bad('DESKTOP-OPEN', f'{f}:{i + 1}', 'opens a file, browser or app on the desktop without an explicit --open / -Open flag (kit-admin.md "Shapes")')
    # ---- a shell started without a hidden window opens a console on the owner's screen
    # (Windows Terminal hosts every new visible console); a detached child, or a scheduled task's action, has no console to inherit
    rx_win = {'.ps1': (r'Start-Process\s+(?:-FilePath\s+)?(?:\S*(?:pwsh|powershell|cmd)|\$\w+)|New-ScheduledTaskAction\b|\bschtasks(?:\.exe)?\s+/create\b',
                       r'WindowStyle|NoNewWindow|@\w*hid|--headless|-Verb\s+RunAs'),
              '.py': (r'creationflags\s*=.*(?:DETACHED_PROCESS|CREATE_NEW_CONSOLE)|\bstart_new_session\s*=\s*True', r'CREATE_NO_WINDOW|STARTF_USESHOWWINDOW'),   # arch-ok: flag names
              '.mjs': (r'\bdetached:\s*true', r'windowsHide:\s*true'), '.js': (r'\bdetached:\s*true', r'windowsHide:\s*true')}   # arch-ok: Windows window flags
    for f in counted:
        ext = osp.splitext(f)[1]
        if ext not in rx_win or f.startswith(GENERATED):
            continue
        ls = k.texts.get(f, '').splitlines()
        for i, line in enumerate(ls):
            if re.search(rx_win[ext][0], line, re.I) and not re.match(r"\s*(#|//|@\(\s*')", line) \
                    and not re.search(rx_win[ext][1], '\n'.join(ls[max(0, i - 2):i + 1]), re.I):   # a splat or flags set up to 2 lines above
                bad('HIDDEN-WINDOW', f'{f}:{i + 1}', 'starts a program without a hidden window (-WindowStyle Hidden / -NoNewWindow, windowsHide: true, CREATE_NO_WINDOW, a scheduled task via conhost --headless): a console window opens on the desktop')   # arch-ok: message text
    # ---- waste guards (2026-11-18 audit): a short fixed sleep in a loop that calls the host, ssh or re-reads files polls
    # forever at full rate; a bossy -Recurse over the runtime trees walks ~140k files per sweep
    rx_call = r'Invoke-HostVerb|Invoke-BoundedSsh|\bssh\b|\bglab\b|\bgh\s|ConvertFrom-Json|Get-Content'
    for f in counted:
        if not f.endswith('.ps1') or f.startswith(('tests/',) + GENERATED):
            continue
        ls = k.texts.get(f, '').splitlines()
        for i, line in enumerate(ls):
            if re.match(r'\s*#', line):
                continue
            m = re.search(r'Start-Sleep\s+(?:-Seconds\s+)?(\d+)\b(?!\s*\))|Wait-KitPoll\s+(\d+)', line)
            if m and int(m.group(1) or m.group(2)) <= 60:
                win = '\n'.join(ls[max(0, i - 8):i + 1])
                if re.search(r'\b(while|do|for|foreach)\b', win) and re.search(rx_call, win) and not re.search(r'poll\.maxSec|backoff|poll-ok|\*\s*2\b|Pow\(', win, re.I):
                    bad('POLL-BACKOFF', f'{f}:{i + 1}', 'a fixed short sleep in a loop that calls the host, ssh or re-reads a file: back off (double up to poll.maxSec, reset on a change) or mark the loop "# poll-ok: <why>"')
            if f.startswith('skills/bossy/') and re.search(r'Get-ChildItem\b.*-Recurse\b', line) and not re.search(r'-Depth\b|walk-ok', line) \
                    and re.search(r'qa-runs|\bwork\b|\bcache\b|\blanes\b|\baudit\b|Get-KitRuntime|\$rt\b', line):
                bad('DEEP-WALK', f'{f}:{i + 1}', 'a -Recurse walk over the runtime trees without -Depth: name the depth (Get-KitQaRunFiles for qa-runs) or mark the line "# walk-ok: <why>"')
    # ---- every lease or hold is written with its holder (README "Leases")
    for f in counted:
        if f.endswith('.ps1') and not f.startswith(('tests/',) + GENERATED):
            for i, line in enumerate(k.texts.get(f, '').splitlines()):
                if re.search(r'\.(leases|holds)\[[^\]]+\]\s*=\s*@\{', line) and 'New-KitLease' not in line:
                    bad('LEASE-HOLDER', f'{f}:{i + 1}', 'a lease or hold written without New-KitLease: nothing would free it (README "Leases")')
    # ---- writing standards: kit files, lessons, History lines
    try:
        wkinds, wbanned = writing_standards(k.dir)
    except OSError:   # no templates.md yet
        wkinds, wbanned = {}, []
    if wkinds:
        for f in counted:
            kind = 'skill' if f.endswith('/SKILL.md') else 'agent' if f.startswith('agents/') else \
             'rule' if f.startswith('rules/') and f.endswith('.md') else ''
            if kind in wkinds:
                for p_ in prose_check(kind, k.texts.get(f, ''), wkinds[kind], wbanned):
                    bad('PROSE', f, f'{kind}: {p_} (templates.md "Writing standards")')
        cur = ''
        for ln, line in enumerate(k.texts.get('LESSONS.md', '').split('\n'), 1):
            if line.startswith('## '):
                cur = 'history' if line.startswith('## History') else 'lesson'
            elif line.startswith('- ') and cur in wkinds:
                for p_ in prose_check(cur, line, wkinds[cur], wbanned):
                    bad('PROSE', f'LESSONS.md:{ln}', f'{cur}: {p_}')
    # ---- lessons: 40 lines per skill section
    lt = k.texts.get('LESSONS.md', '')
    for m in re.finditer(r'^## (?!History)(\S+)\n(.*?)(?=^## |\Z)', lt, re.S | re.M):
        n = len([l for l in m.group(2).splitlines() if l.startswith('- ')])
        if n > 40:
            bad('LESSONS-CAP', f'LESSONS.md ## {m.group(1)}', f'{n} lessons (cap 40): bossy.ps1 learn -Skill {m.group(1)} -Trim (forgets the lowest-scored: kitbag.py forget)')
        for l in m.group(2).splitlines():   # learn -When -Do -Why renders it
            if l.startswith('- ') and m.group(1) != 'Decisions' and not LESSON_SHAPE.match(l):
                bad('LESSON-SHAPE', f'LESSONS.md ## {m.group(1)}', f'not "- <when> -> <do> (<why>)": {l[:80]}')
    # ---- README graph sections current
    rd = k.texts.get('README.md', '')
    if '<!-- kit-graph:start' in rd and update_readme(rd, readme_sections(k, g)) != rd:
        bad('README-GRAPH', 'README.md', 'graph sections out of date: python -X utf8 skills/bossy/kitbag.py flow --readme (the pre-commit hook does it)')
    # ---- runtime / durable paths: one map (_paths), resolved only by the helpers
    try:
        pmap = json.loads(k.texts.get(PATHS_JSON) or read(osp.join(k.dir, PATHS_JSON)) or '{}').get('_paths') or {}
    except ValueError:
        pmap = {}
        bad('RUNTIME-MAP', PATHS_JSON, 'invalid JSON')
    raw = [(re.compile(r'\.(?:claude-)?runtime[\\/]+[\w<$]'), 'a hard-coded .runtime/<sub> path'),
     (re.compile(r"""(\$env:|environ(\.get)?\(?['"\[]|process\.env\.)CLAUDE_RUNTIME"""), 'reads $CLAUDE_RUNTIME itself'),
     (re.compile(r'\$KitConf\.Runtime\b'), 'joins onto $KitConf.Runtime'),
     (re.compile(r'\$\{RT\}/'), 'builds ${RT}/<sub> by hand')]
    for f in k.files:
        if f in PATH_HELPERS or not f.endswith(('.ps1', '.py', '.mjs', '.js')):
            continue
        for ln, line in enumerate(k.texts.get(f, '').splitlines(), 1):
            if re.match(r'\s*const rp = ', line):
                continue   # the workflow helper itself
            for rx, what in raw:
                if rx.search(line):
                    bad('RUNTIME-RAW', f'{f}:{ln}', f'{what}: use Get-KitPath / kit_path / kitPath / rp(<name>) (names in {PATHS_JSON})')
                    break
    # ---- log lines only through Write-KitLog / kitlog: no append to a .log / .jsonl / *-log / signals target
    app = re.compile(r'Add-Content|Out-File\b[^|\n]*-Append|AppendAllText|appendFile|\bopen\([^)]*[\'"]a[\'"]|(?<!>)>>(?!>)')
    tgt = re.compile(r'\.jsonl\b|\.log\b|[\w-]-log\b|\bsignals\b', re.I)
    for f in k.files:
        if f.endswith(('.ps1', '.py', '.mjs', '.js')) and not f.startswith('tests/'):
            for ln, line in enumerate(k.texts.get(f, '').splitlines(), 1):
                if app.search(line) and tgt.search(line):
                    bad('LOG-DIRECT', f'{f}:{ln}', 'appends a log line by hand: Write-KitLog <stream> (lib.ps1) / kitlog() (kitbag.py), streams in kit.example.json _paths.log')
    if pmap:
        for w, p in k.workflows.items():
            m = re.search(r'^const KP = (\{.*\})\s*$', k.texts.get(p, ''), re.M)
            if not m:
                if re.search(r'\$\{RT\}|\brp\(', k.texts.get(p, '')):
                    bad('RUNTIME-MAP', p, 'uses runtime paths without a `const KP = {...}` map (copy the names from kit.example.json _paths)')
                continue
            try:
                kp = json.loads(m.group(1))
            except ValueError:
                bad('RUNTIME-MAP', p, 'const KP must be JSON (double quotes) so kit-lint can compare it with kit.example.json _paths')
                continue
            for sect in ('runtime', 'durable'):
                for n, v in (kp.get(sect) or {}).items():
                    if (pmap.get(sect) or {}).get(n) != v:
                        bad('RUNTIME-MAP', p, f'KP.{sect}["{n}"] = "{v}" but kit.example.json _paths says "{(pmap.get(sect) or {}).get(n)}"')
            known = set(kp.get('runtime') or {}) | set(kp.get('durable') or {})   # an rp(<name>) missing from KP resolves to <runtime>/undefined
            for n in sorted(set(re.findall(r"""\brp\(['"]([\w-]+)['"]\)""", k.texts.get(p, ''))) - known):
                bad('RUNTIME-MAP', p, f"rp('{n}') is not in const KP (resolves to .../undefined): add it from kit.example.json _paths")
    # ---- config keys documented (kit copy of the reference)
    conf = section(k.texts.get('README.md', ''), 'Configuration') or ''
    if conf:
        for f in k.files:
            if not f.endswith('.example.json'):
                continue
            try:
                data = json.loads(k.texts.get(f, '') or '{}')
            except ValueError:
                bad('CONFIG-UNDOC', f, 'invalid JSON')
                continue
            for key in data:
                if not key.startswith('_') and f'`{key}' not in conf and f'"{key}"' not in conf:
                    bad('CONFIG-UNDOC', f, f'key "{key}" is not documented in README.md "Configuration"')
    # ---- registry, schemas, old names, agent types, scaffold stubs
    registry_lint(k, bad)
    params_lint(k, bad)
    for c, w, m in arch_lint(k):   # the rest print as WARN (cmd_lint)
        if c in ARCH_COUNTED or c == 'ARCH-VOCAB':
            bad(c, w, m)
    # ---- PS-CASE on the .ps1 files changed vs origin/main (audit scan: every file, as a WARN)
    rc, o, _ = git(k.dir, 'diff', '--name-only', 'origin/main', '--')
    for f in (o.splitlines() if rc == 0 else []):
        if f.endswith('.ps1') and osp.isfile(osp.join(k.dir, f)):
            for lb, b, a, la in ps_case(k.texts.get(f) or read(osp.join(k.dir, f))):
                bad('PS-CASE', f'{f}:{lb}', f'${b} is the same variable as ${a} (line {la}) in this function: rename one')
    # ---- PS-MATH-INT: [math]::Min/Max with an int literal first binds the Int32 overload: Max(0, 1.5) = 2 (K57)
    for f in k.files:
        if f.endswith('.ps1') and f.startswith('skills/'):   # tests/ hold fixtures in strings
            for ln, arg in ps_math_int(k.texts.get(f) or read(osp.join(k.dir, f))):
                bad('PS-MATH-INT', f'{f}:{ln}', f'[math]::Min/Max(<int>, {arg[:40]}) rounds a double side: write the literal as a double (0.0)')
    # ---- org terms (published files + README/docs/examples)
    if org_terms:
        scan = [(f, k.texts.get(f) or read(osp.join(k.dir, f))) for f in k.files if not is_overlay(k, f)]
        scan += [(f, read(osp.join(k.dir, f))) for f in k.repo_files if f.split('/')[0] != 'LICENSE']
        pats = [(t.strip(), r) for t in org_terms for r in org_term_rx([t])]
        for where, text in scan:
            for t, rx in pats:
                if rx.search(text):
                    bad('ORG-TERM', where, f'contains org term "{t}"')
    # ---- the retired optional-part word, in every tracked text file
    retired = re.compile(r'(?i)\bgood(?:y|ies)\b')
    for f in tracked(k.dir):
        if not (f.endswith(TEXT_EXT) or f.startswith(('.githooks/', '.github/'))) or not osp.isfile(osp.join(k.dir, f)):
            continue
        for i, line in enumerate((k.texts.get(f) or read(osp.join(k.dir, f)) or '').split('\n')):
            if retired.search(line):
                bad('RETIRED-WORD', f'{f}:{i + 1}', 'the retired optional-part word: name the file, adapter or feature instead')
    return probs

# ---- README graph: Mermaid and tables; pre-commit keeps them current
def readme_sections(k, g):
    """The README's generated sections: the map (root -> router -> skills / workflows / agents), tables, one per skill."""
    nodes, edges = g['nodes'], g['edges']
    label = lambda f: skill_of(f) if nodes[f]['kind'] == 'skill' else osp.basename(f).rsplit('.', 1)[0]
    nid = lambda f: re.sub(r'[^A-Za-z0-9]', '_', f)
    cut = lambda s, n: s if len(s) <= n else s[:n].rsplit(' ', 1)[0] + '…'   # at a word
    # Mermaid text always quoted (bare ( ) ; : parse as shape tokens); token delimiters entity-escaped
    mq = lambda s: '"' + re.sub(r'["#<>`|]', lambda m: {'"': '#quot;', '#': '#35;', '<': '#lt;', '>': '#gt;', '`': '#96;', '|': '#124;'}[m.group(0)], re.sub(r'\s+', ' ', str(s)).strip()) + '"'
    out = {}
    lines = ['flowchart LR', f'  CLAUDE_md[{mq("CLAUDE.md")}] -->|{mq("import")}| AGENTS_md[{mq("AGENTS.md Router")}]']
    # README is published: no local-overlay parts (localOnly, *.local.*)
    pub = lambda f: f in nodes and not nodes[f].get('local')
    tops = [f for f, n in sorted(nodes.items()) if n['kind'] in ('skill', 'workflow', 'agent') and pub(f)]
    for f in tops:
        shape = {'skill': '[{}]', 'workflow': '[/{}/]', 'agent': '({})'}[nodes[f]['kind']]
        lines.append(f'  {nid(f)}' + shape.format(mq(label(f))))
    for (a, b), typ in sorted(edges.items()):
        if a in ('AGENTS.md',) and b in tops and typ == 'route':
            lines.append(f'  AGENTS_md --> {nid(b)}')
        elif a in tops and b in tops and typ == 'spawn' and nodes[a]['kind'] == 'workflow':
            lines.append(f'  {nid(a)} -->|{mq("spawns")}| {nid(b)}')
    for a, p in sorted(k.agents.items()):   # the skill on its "Load first" line
        m = re.search(r'Load first:\*\*\s*`[^`]*skills/([\w-]+)/SKILL\.md', k.texts.get(p, ''))
        if m and f'skills/{m.group(1)}/SKILL.md' in nodes:
            lines.append(f'  {nid(p)} -->|{mq("loads")}| {nid(f"skills/{m.group(1)}/SKILL.md")}')
    out['map'] = lines
    man = manifest(k.dir)
    out['table-crew'] = ['| Agent | Job | Kinds / roles | Used in | Can\'t | Character |', '|---|---|---|---|---|---|'] + [
     f"| `{a}` | {m.get('job', '')} | {' · '.join(m.get('kinds', []))}{(' (roles: ' + ' / '.join(m['roles']) + ')') if m.get('roles') else ''} | {', '.join(m.get('usedIn', []))} | {m.get('cant', '')} | "
     f"{(m.get('character') or {}).get('traits', '')}: \"{(m.get('character') or {}).get('catchphrase', '')}\" |" for a, m in (man.get('agents') or {}).items()]
    out['table-workflows'] = ['| Workflow | Covers | Crew | Router row |', '|---|---|---|---|'] + [
     f"| `/{w}` | {m.get('covers', '')} | {', '.join('`' + c + '`' for c in m.get('crew', []))} | {m.get('router', '')} |" for w, m in (man.get('workflows') or {}).items()]
    def odd(n, a):   # the family's non-native verbs: fallback / gap, with the adapter count
        if a.get('parity'):
            return 'not walked: ' + a['parity']
        c = defaultdict(int)
        for row in adapter_matrix(k, n, a).values():
            for v, s in row.items():
                if s in ('fallback', 'gap', 'MISSING'):
                    c[(s, v)] += 1
        return ' · '.join(f"{s}: " + ', '.join(f'{v} ({c[(s2, v)]})' for s2, v in sorted(c) if s2 == s) for s in ('fallback', 'gap', 'MISSING') if any(x[0] == s for x in c))
    out['table-adapters'] = ['| Kind | Selected by | Interface (verbs; caps: Test-KitCap) | Built in | Vendor (config-selected) | Not native (adapters) | Code |', '|---|---|---|---|---|---|---|'] + [
     f"| {n} | `{a.get('config', '')}` | {a.get('verbs', '')}{'; caps: ' + a['caps'] if a.get('caps') else ''} | {', '.join(a.get('names', '').split())} | {', '.join(a.get('vendors', '').split())} | {odd(n, a)} | `{a.get('file', '')}` |" for n, a in (man.get('adapters') or {}).items() if isinstance(a, dict)]
    out['table-ports'] = ['| Feature | Codex | Antigravity |', '|---|---|---|'] + [
     f"| {f} | {' | '.join(c[h][0] + (': ' + c[h][1] if c[h][1] else '') for h in HARNESS)} |" for f, c in harness_matrix(k) if any(c[h][0] != 'port' for h in HARNESS)]
    bd = ((json.loads(read(osp.join(k.dir, PATHS_JSON)) or '{}').get('budget') or {}).get('defaults') or {})   # per-tool budget defaults
    out['table-budget'] = ['| Tool / window | Budget | Source |', '|---|---|---|'] + [f"| {n} | {v.get('tokens') or str(v.get('fraction')) + ' x window'} | {v.get('source', '')} |" for n, v in bd.items()]
    ex = json.loads(read(osp.join(k.dir, PATHS_JSON)) or '{}')   # config table: each key's _readme, else its _doc row
    cell = lambda v, n=70: cut(re.sub(r'\s+', ' ', json.dumps(v, ensure_ascii=False) if not isinstance(v, str) else v).replace('|', '/'), n).replace('<', '&lt;').replace('>', '&gt;')
    rows, done = [], set()
    for key, txt in (ex.get('_doc') or {}).items():
        if not key.startswith('_'):
            ks = [x.strip() for x in key.split(',')]; done.update(ks)
            rows.append(f"| {', '.join('`' + x + '`' for x in ks)} | {cell(ex.get(ks[0], ''))} | {cell(txt, 999)} |")
    for key, v in ex.items():
        if not key.startswith('_') and key not in done and isinstance(v, dict):
            rows.append(f"| `{key}` | {cell({a: b for a, b in v.items() if not a.startswith('_')})} | {cell(v.get('_readme', ''), 999)} |")
    out['table-config'] = ['| Key | Example / default | Meaning |', '|---|---|---|'] + rows
    caps = man.get('caps') or {}
    out['table-caps'] = [' · '.join(f'{n} {v}' for n, v in BUDGETS.items()) + f" · start per role {START_CAP} · files:{caps.get('content')} content + {caps.get('plumbing')} plumbing"]
    fid = lambda s: 'F_' + re.sub(r'[^A-Za-z0-9]', '_', s)
    for fn, es in (man.get('flows') or {}).items():   # _manifest.flows: [from, label, to] edges
        if not fn.startswith('_'):
            out[f'flow-{fn}'] = ['flowchart LR'] + [f'  {fid(a)}[{mq(a)}] -->|{mq(lb)}| {fid(b)}[{mq(b)}]' for a, lb, b in es]
    ma, mw = man.get('agents') or {}, man.get('workflows') or {}   # crew hero: who starts whom
    out['crew'] = ['flowchart LR', f'  OW([{mq("owner")}]) -->|{mq("asks, says deploy env")}| CO[{mq("coordinator: Router + Events")}]'] + [
     x for w, m in mw.items() for x in [f"  CO -->|{mq(m.get('router', ''))}| W_{w}[/{mq(w)}/]"] + [f'  W_{w} -->|{mq("spawns")}| A_{c}({mq(c)})' for c in m.get('crew', [])]] + [
     f"  CO -->|{mq(', '.join(u for u in m.get('usedIn', []) if u.startswith('R')))}| A_{a}({mq(a)})" for a, m in ma.items() if any(u.startswith('R') for u in m.get('usedIn', []))]
    for s in k.skills:
        sk = f'skills/{s}/SKILL.md'
        if not pub(sk):
            continue
        lines = ['flowchart LR', f'  {nid(sk)}[{mq(s)}]']
        for n, when, hits in k.index.get(s, []):
            for h in [h for h in hits if pub(h) or h not in nodes]:
                lines.append(f'  {nid(sk)} -->|{mq(cut(re.sub(r"[`]", "", when), 48))}| {nid(h)}[{mq(osp.basename(h))}]')
        out[f'skill-{s}'] = lines
    return out

def update_readme(text, sections):
    """README text with every generated section replaced; missing sections are appended after the map marker."""
    def block(name):
        if name.startswith('table-'):   # generated table (manifest), no diagram
            return f'<!-- kit-graph:start {name} -->\n' + '\n'.join(sections[name]) + '\n<!-- kit-graph:end -->'
        return f'<!-- kit-graph:start {name} -->\n```mermaid\n' + '\n'.join(sections[name]) + '\n```\n<!-- kit-graph:end -->'
    text = text.replace('\r\n', '\n')
    # drop sections no part produces, with the blank line before
    text = re.sub(r'\n*<!-- kit-graph:start ([\w-]+) -->.*?<!-- kit-graph:end -->',
       lambda m: m.group(0) if m.group(1) in sections else '', text, flags=re.S)
    for name in sections:
        rx = re.compile(r'<!-- kit-graph:start ' + re.escape(name) + r' -->.*?<!-- kit-graph:end -->', re.S)
        if rx.search(text):
            text = rx.sub(lambda m: block(name), text)
        else:
            text = text.rstrip('\n') + '\n\n' + block(name) + '\n'
    return text

def write_readme(kit):
    """Rewrite README.md's generated sections when they changed (flow --readme; the pre-commit hook runs it)."""
    k = load(kit)
    p = osp.join(kit, 'README.md')
    old = read(p)
    new = update_readme(old, readme_sections(k, graph(k)))
    if new != old:
        with open(p, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(new)
        print('kitbag flow: README.md graph sections updated')

def cmd_flow(a):
    """flow --readme [<kit>]; any other flow call draws the page (the kitbag_flow.py plugin replaces this command)."""
    if '--readme' not in a:
        print(__doc__)
        return 2
    flags, rest = parse_opts(a)
    write_readme(osp.abspath(rest[0] if rest else KIT_DIR))
    return 0

# ---- lint command: print, --json, exit code
def org_term_rx(terms):
    """One regex per org term: whole words; capitalised = case-sensitive; trailing * = prefix; <placeholders> skipped."""
    return [re.compile(r'(?<![\w-])' + re.escape(t.strip().rstrip('*')) + ('' if t.strip().endswith('*') else r'(?![\w-])'),
                       0 if t.strip() != t.strip().lower() else re.I) for t in terms if isinstance(t, str) and t.strip() and not t.strip().startswith('<')]

def org_terms_of(value):
    """--org-terms: a kit.local.json (its orgTerms) or a comma list."""
    if value.lower().endswith('.json') and not osp.isfile(value):   # a mistyped path as a "term" passes every file
        print(f'kitbag lint: --org-terms {value}: no such file', file=sys.stderr); sys.exit(2)
    if not osp.isfile(value):
        return [x for x in value.split(',') if x.strip()]
    data, err = load_json(value)
    if err:
        sys.exit(f'kitbag lint: {value}: {err}')
    return data.get('orgTerms') or []

def cmd_lint(a):
    flags, rest = parse_opts(a, {'--org-terms', '--json'})
    kit = osp.abspath(rest[0] if rest else KIT_DIR)
    k = load(kit)
    problems = lint(k, graph(k), org_terms_of(flags['--org-terms']) if '--org-terms' in flags else None)
    for hook in LINT_HOOKS:   # plugins (kitbag_flow.py: FLOW-* issues)
        hook(k, problems, flags)
    if '--json' in flags:
        with open(flags['--json'], 'w', encoding='utf-8') as fh:
            json.dump([{'code': c, 'where': w, 'problem': m} for c, w, m in problems], fh, indent=1)
    warns = [] if '--summary' in flags else literal_warns(k, '--ratchet' in flags) + \
        [p for p in arch_lint(k) if p[0] not in ARCH_COUNTED | {'ARCH-VOCAB'}] + [p for h in WARN_HOOKS for p in h(k)]   # not counted (WARN; an error later)
    if '--summary' in flags:
        if problems:
            c, w, m = problems[0]
            print(f'kitbag lint: {len(problems)} problem(s), e.g. {c} {w}: {m} (list: python {osp.abspath(__file__)} lint)')
    else:
        for c, w, m in problems:
            print(f'{c:15} {w}: {m}')
        for c, w, m in (warns if '--warn' in flags else []):   # standing warnings: a count unless asked (they re-read as tokens on every run)
            print(f'WARN {c:10} {w}: {m}')
        if warns and '--warn' not in flags:
            print(f'kitbag lint: {len(warns)} warning(s) not counted (--warn lists them)')
        unmerged = {x.split('\t', 1)[-1] for x in git(kit, 'ls-files', '-u')[1].splitlines() if x}
        if unmerged:   # said once, not per stage entry
            print(f'kitbag lint: rebase / merge in progress: {len(unmerged)} unmerged file(s), each counted once; resolve, then lint again')
        print(f'kitbag lint: {len(problems)} problem(s) in {kit} ({len(k.files)} files, {len(k.skills)} skills, '
         f'{len(k.workflows)} workflows, {len(k.agents)} agents)')
    for c, w, m in ui_check_warns(kit):   # stderr: the pre-commit hook drops lint's stdout
        print(f'WARN {c:10} {w}: {m}', file=sys.stderr)
    return 1 if problems and '--warn' not in flags else 0

UI_MARK = '<!doctype' + ' html'   # split: kitbag.py itself is no page generator

def ui_check_stamp(kit=None):
    return osp.join(kit_path('shots', kit=kit), 'ui-check', 'stamp.json')

def ui_check_warns(kit):
    """WARN UI-CHECK: a changed page generator (a script holding UI_MARK; spec.mjs only seeds a test DOM) newer than the last passing ui-check."""
    code, out, _ = git(kit, 'diff', 'HEAD', '--name-only')
    if code:
        return []
    stamp = ui_check_stamp(kit)
    since = osp.getmtime(stamp) if osp.isfile(stamp) else 0
    hits = []
    for rel in out.splitlines():
        p = osp.join(kit, rel)
        if rel.endswith(('.ps1', '.py', '.mjs', '.js')) and not rel.startswith('tests/') and rel != 'skills/crafty/spec.mjs' and osp.isfile(p) and osp.getmtime(p) > since:
            with open(p, encoding='utf-8', errors='replace') as fh:
                if UI_MARK in fh.read().lower():
                    hits.append(rel)
    return [('UI-CHECK', r, 'page generator changed since the last passing ui-check -> kitbag.py ui-check <its page>, read the 3 shots, then commit') for r in hits]

# node, cwd skills/pokey (its puppeteer-core): per width x theme x state (selectors clicked in order, fresh storage): a full-page shot
# and height as loaded, then every <details> open: a second shot (-open) + the text that is clipped (ellipsis, line-clamp, clip-path, hidden overflow; wider than its box outside a scroll
# box) or squeezed (a few letters a line)
PAGE_JS = r'''import puppeteer from 'puppeteer-core'
import { pathToFileURL } from 'node:url'
import { mkdtempSync, rmSync } from 'node:fs'
import { join } from 'node:path'
const [bm, file, ws, st, out, stem] = process.argv.slice(1), { CHROME, QUIET_ARGS, kitPath } = await import(bm)
const { quietProfile } = await import(new URL('adapters/engine-playwright.mjs', bm))
const ud = quietProfile(mkdtempSync(join(kitPath('tmp', { create: true }), 'ui-check-')))   // seeded prefs: no model downloads
// every <details> open; resolves once each one's own toggle event ran (a page re-lays out on toggle: its capture and earlier listeners
// run first); one the page closed again or removed is not waited for
const openAll = () => new Promise((done) => { const wait = new Set([...document.querySelectorAll('details')].filter((d) => !d.open)); if (!wait.size) return done()
  const chk = () => { for (const d of wait) if (!d.open || !d.isConnected) wait.delete(d); if (!wait.size) done() }
  for (const d of wait) d.addEventListener('toggle', () => { wait.delete(d); chk() }, { once: true })
  wait.forEach((d) => { d.open = true }); setTimeout(chk, 0) })
// the page at rest, never a fixed sleep (a loaded machine runs late): fonts in, finite time-based animations / transitions done, the
// page's own window.uiBusy() false (its pending timers), then 2 frames (250 ms each without rAF); 300 rounds max, then it fails loudly
const settle = async () => { const frame = () => new Promise((r) => { let n = 0; const f = () => n++ || r(); requestAnimationFrame(() => setTimeout(f, 0)); setTimeout(f, 250) })
  await document.fonts.ready
  for (let i = 0; i < 300; i++) { await frame(); await frame()
    const run = document.getAnimations().filter((a) => a.playState === 'running' && a.timeline instanceof DocumentTimeline && a.effect && a.effect.getComputedTiming().endTime !== Infinity)
    if (!run.length && !(typeof window.uiBusy === 'function' && window.uiBusy())) return 0 }
  return 1 }
const scan = () => {
  const res = [], name = (e) => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\s+/).join('.') : '')
  for (const e of document.querySelectorAll('body, body *')) {
    if (e.closest('svg,script,style,noscript,#tip') || !e.getClientRects().length) continue
    const cs = getComputedStyle(e), txt = (e.innerText || '').trim().replace(/\s+/g, ' '), fs = parseFloat(cs.fontSize), lh = parseFloat(cs.lineHeight) || fs * 1.2
    if (!txt) continue
    // owner 2026-11-19: a one-line ellipsis passes when it fits, or when a title on it or its tile holds the full text
    const tip = ((e.closest('[title]') || {}).title || '').replace(/\s+/g, ' ')
    const why = cs.textOverflow === 'ellipsis' ? (e.scrollWidth <= e.clientWidth + 1 || tip.includes(txt) ? '' : 'text-overflow: ellipsis without a title holding the full text') : cs.webkitLineClamp && cs.webkitLineClamp !== 'none' ? `line-clamp ${cs.webkitLineClamp}`
      : cs.clipPath !== 'none' ? `clip-path ${cs.clipPath}` : /hidden|clip/.test(cs.overflowY) && e.scrollHeight > e.clientHeight + 1 ? `scrollHeight ${e.scrollHeight} > clientHeight ${e.clientHeight}`
      : /auto|scroll/.test(cs.overflowX) || cs.display === 'inline' ? '' : e.scrollWidth > e.clientWidth + 1 ? `scrollWidth ${e.scrollWidth} > clientWidth ${e.clientWidth}`
      : e.clientWidth > 0 && e.clientWidth < 4 * fs && txt.length > 6 && e.clientHeight > 3 * lh ? `squeezed: ${e.clientWidth} px wide, ${Math.round(e.clientHeight / lh)} lines` : ''
    if (why) res.push({ el: name(e), why, text: txt.slice(0, 80) })
  }
  return res
}
// a canvas page exposes window.uiBoxes() = {view: [x0, y0, x1, y1], boxes: [{id, key?, own?, b: [x, y, w, h]}]} (page px): each box inside
// view, no two boxes meet (a label never against its own node: own === key); 12 listed per kind, then a count
const layout = () => {
  if (typeof window.uiBoxes !== 'function') return []
  const { view: [a, b, c, d], boxes } = window.uiBoxes(), tol = 0.5, hits = { 'off-screen': [], overlap: [] }
  for (const x of boxes) { const [l, t, w, h] = x.b; if (l < a - tol || t < b - tol || l + w > c + tol || t + h > d + tol) hits['off-screen'].push(x.id) }
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
    const p = boxes[i], q = boxes[j]
    if ((p.own && p.own === q.key) || (q.own && q.own === p.key)) continue
    const [pl, pt, pw, ph] = p.b, [ql, qt, qw, qh] = q.b
    if (pl + tol < ql + qw && ql + tol < pl + pw && pt + tol < qt + qh && qt + tol < pt + ph) hits.overlap.push(`${p.id} x ${q.id}`)
  }
  return Object.entries(hits).flatMap(([why, l]) => l.slice(0, 12).map((t) => ({ el: 'layout', why, text: t.slice(0, 120) }))
    .concat(l.length > 12 ? [{ el: 'layout', why, text: `and ${l.length - 12} more` }] : []))
}
// a box marked data-fit (a card) sized to its content: 24+ px blank between its content's bottom and its own padding is a gap
const fit = () => [...document.querySelectorAll('[data-fit]')].flatMap((e) => {
  if (!e.getClientRects().length) return []
  const cs = getComputedStyle(e), r = document.createRange(); r.selectNodeContents(e)
  const gap = Math.round(e.getBoundingClientRect().bottom - parseFloat(cs.paddingBottom) - parseFloat(cs.borderBottomWidth) - r.getBoundingClientRect().bottom)
  return gap >= 24 ? [{ el: 'fit', why: `blank ${gap} px below the content`, text: (e.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 60) }] : []
})
// a card grid or wrapping row (items [data-fit], details, article, figure, .ci, .st) at desktop width, as loaded: a row ending 24+ px short of its box is an empty column (an auto-fill slot, a lone card)
// a multi-column box (CSS columns) leaves its later columns empty when it holds few cards: the content must reach within 24 px of its right edge
const cols = () => innerWidth < 1280 ? [] : [...document.querySelectorAll('body *')].flatMap((g) => {
  const cs = getComputedStyle(g); if ((cs.columnCount === 'auto' && cs.columnWidth === 'auto') || !g.getClientRects().length || !g.children.length) return []
  const end = g.getBoundingClientRect().right - parseFloat(cs.paddingRight), right = Math.max(...[...g.children].map((c) => c.getBoundingClientRect().right)), short = Math.round(end - right)
  return short >= 24 ? [{ el: 'rows', why: `CSS columns end ${short} px short of their box (empty columns): use a stretching grid`, text: (g.className || g.tagName).toString().slice(0, 80) }] : []
})
// a stray element: absolutely placed outside its parent's box (a class shared by a chart dot and a legend mark), or text cut by a clipping box / the window edge
const stray = () => [...document.querySelectorAll('body *')].flatMap((e) => {
  if (e.closest('svg,#tip,script,style') || !e.getClientRects().length) return []   // a closed fold's body has no box; its summary is checked
  const cs = getComputedStyle(e), r = e.getBoundingClientRect(), out = []
  if (r.right <= 0 || r.bottom <= 0) return []   // parked off-screen on purpose: screen-reader-only text (.sr)
  if (cs.position === 'absolute' && cs.zIndex === 'auto' && e.parentElement) { const p = e.parentElement.getBoundingClientRect(), tol = 6   // a z-index = an overlay (menu, popover)
    if (r.left < p.left - tol || r.right > p.right + tol || r.top < p.top - tol || r.bottom > p.bottom + tol) out.push({ el: 'stray', why: `absolute element ${Math.round(r.left)},${Math.round(r.top)} outside its parent box ${Math.round(p.left)}-${Math.round(p.right)} x ${Math.round(p.top)}-${Math.round(p.bottom)}`, text: `${e.tagName.toLowerCase()}.${String(e.className)} in ${String(e.parentElement.className || e.parentElement.tagName)}`.slice(0, 120) }) }
  if (![...e.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) return out
  if (r.right > innerWidth + 1 && !e.closest('.sc,.tw')) out.push({ el: 'clip', why: `text ends ${Math.round(r.right - innerWidth)} px past the window edge`, text: (e.innerText || '').trim().slice(0, 80) })
  for (let a = e.parentElement; a && a !== document.body; a = a.parentElement) {
    const as = getComputedStyle(a); if (/auto|scroll/.test(as.overflowX + as.overflowY)) break
    if (/hidden|clip/.test(as.overflowX) && r.right > a.getBoundingClientRect().right + 1) { out.push({ el: 'clip', why: `text cut ${Math.round(r.right - a.getBoundingClientRect().right)} px by ${a.tagName.toLowerCase()}.${String(a.className)} (overflow ${as.overflowX})`, text: (e.innerText || '').trim().slice(0, 80) }); break }
  }
  return out
})
const rows = () => innerWidth < 1280 ? [] : [...document.querySelectorAll('body *')].flatMap((g) => {
  const cs = getComputedStyle(g); if (!(/grid/.test(cs.display) || (/flex/.test(cs.display) && cs.flexWrap === 'wrap')) || !g.getClientRects().length || g.closest('details:not([open])') || g.classList.contains('msn')) return []   // packed masonry: own heights by design (the masonry gap check covers it)
  const kids = [...g.children].filter((c) => c.getClientRects().length && !/absolute|fixed/.test(getComputedStyle(c).position))
  if (!kids.length || !kids.some((c) => c.matches('[data-fit],details,article,figure,.ci,.st'))) return []
  if (kids.length < 2) { const r = kids[0].getBoundingClientRect(), short = Math.round(g.getBoundingClientRect().right - parseFloat(cs.paddingRight) - parseFloat(cs.borderRightWidth) - r.right)   // a lone card in a grid row
    return /grid/.test(cs.display) && short >= 24 ? [{ el: 'rows', why: `a lone card ends ${short} px short of its grid (cards stretch: auto-fit)`, text: (g.className || g.tagName).toString().slice(0, 80) }] : [] }
  const end = g.getBoundingClientRect().right - parseFloat(cs.paddingRight) - parseFloat(cs.borderRightWidth), rs = []   // a row: items whose heights overlap (a margin shifts one top)
  const nm = (c) => ((c.querySelector('.k,summary,h3') || {}).textContent || c.id || c.className).trim().replace(/\s+/g, ' ').slice(0, 30)
  for (const c of kids) { const r = c.getBoundingClientRect(), it = { n: nm(c), h: r.height, k: c.classList[0] || c.tagName }, row = rs.find((x) => r.top < x.bottom - 1 && r.bottom > x.top + 1); if (row) { row.right = Math.max(row.right, r.right); row.bottom = Math.max(row.bottom, r.bottom); row.ids.push(c.id || c.className); row.its.push(it) } else rs.push({ top: r.top, bottom: r.bottom, right: r.right, ids: [c.id || c.className], its: [it] }) }
  // an even grid (every card one width) that wrapped may end its last row short: leftover, no empty column; one short row still is
  const ws = kids.map((c) => c.getBoundingClientRect().width), even = /grid/.test(cs.display) && rs.length > 1 && Math.max(...ws) - Math.min(...ws) < 1
  const last = rs.reduce((a, x) => (x.right < a.right ? x : a)), short = even ? 0 : Math.round(end - last.right)
  // vertical: like tiles (one class) side by side end within 48 px of each other; tiles of different classes may differ (a fixed-height trend beside flag cards)
  const tall = rs.flatMap((x) => [...new Set(x.its.map((i) => i.k))].map((k) => x.its.filter((i) => i.k === k)).filter((g) => g.length > 1)).map((g) => ({ g, d: Math.round(Math.max(...g.map((i) => i.h)) - Math.min(...g.map((i) => i.h))) })).filter((y) => y.d > 48)
  return (short >= 24 ? [{ el: 'rows', why: `a card row ends ${short} px short of its box (an empty column)`, text: `${g.className || g.tagName}: ${last.ids.join(', ')}`.slice(0, 120) }] : [])
    .concat(tall.map((y) => ({ el: 'rows', why: `card heights in one row differ by ${y.d} px (max 48): restructure the row`, text: y.g.map((i) => `${i.n} ${Math.round(i.h)} px`).join(' | ').slice(0, 160) })))
})
// an svg drawn over a sibling tile (a stretched flex tile's svg sized from its aspect ratio), any width: svg boxes vs the other tiles of its grid / flex box
const svgs = () => [...document.querySelectorAll('body *')].flatMap((g) => {
  if (!/grid|flex/.test(getComputedStyle(g).display) || !g.getClientRects().length) return []
  const kids = [...g.children].filter((c) => c.getClientRects().length && !/absolute|fixed/.test(getComputedStyle(c).position)), out = []
  for (const c of kids) for (const s of c.querySelectorAll('svg')) {
    if (s.parentElement.closest('svg') || !s.getClientRects().length) continue
    const r = s.getBoundingClientRect().toJSON()   // what shows: cut by each clipping box up to its tile
    for (let e = s.parentElement; e; e = e === c ? null : e.parentElement) if (getComputedStyle(e).overflow !== 'visible') { const q = e.getBoundingClientRect(); r.left = Math.max(r.left, q.left); r.top = Math.max(r.top, q.top); r.right = Math.min(r.right, q.right); r.bottom = Math.min(r.bottom, q.bottom) }
    r.width = r.right - r.left; r.height = r.bottom - r.top; if (r.width <= 0 || r.height <= 0) continue
    for (const o of kids) { if (o === c) continue; const q = o.getBoundingClientRect()
      if (r.left + 1 < q.right && q.left + 1 < r.right && r.top + 1 < q.bottom && q.top + 1 < r.bottom) out.push({ el: 'svg', why: `svg ${Math.round(r.width)}x${Math.round(r.height)} px in one tile draws over a sibling tile (size it from its tile: absolute inset 0)`, text: `${String(c.className || c.tagName)} x ${String(o.className || o.tagName)}`.slice(0, 120) }) }
  }
  return out
})
// links never navigate the page away (owner, 2026-11-17): the kit's own pages (relative, file:) open in the page drawer (data-dw);
// web URLs (MR, task, doc) in a new tab; '#' anchors and app links (vscode:, mailto:) stay as they are
const links = () => [...document.querySelectorAll('a[href]')].flatMap((a) => {
  const h = a.getAttribute('href') || '', web = /^https?:/i.test(h), app = /^[a-z][a-z0-9+.-]*:/i.test(h) && !web && !/^file:/i.test(h)
  if (h.startsWith('#') || app || a.hasAttribute('data-dw') || (web && a.target === '_blank')) return []
  return [{ el: 'link', why: web ? 'a web link opens in this tab: target=_blank' : 'a link to a kit page navigates away: open it in the page drawer (data-dw)', text: `${a.textContent.trim().slice(0, 40)} -> ${h.slice(0, 80)}` }]
})
if (!CHROME) throw new Error('no Chrome or Edge found (set CHROME_PATH)')
const b = await puppeteer.launch({ executablePath: CHROME, headless: true, userDataDir: ud, args: [...QUIET_ARGS, '--disk-cache-size=1'] }), res = []
// one tab for every state, its storage cleared before each load: a new context per state spawned a renderer each (48 for the kit
// map) and under a full test run one never answered (ProtocolError: Network.enable timed out after 180 s)
const page = (await b.pages())[0] || await b.newPage(), href = pathToFileURL(file).href
try {
  for (const width of ws.split(',').map(Number)) for (const theme of ['light', 'dark']) for (const [si, clicks] of JSON.parse(st).entries()) {
    const clipped = [], touch = width < 600   // a phone width: touch emulation (pointer: coarse) and taps
    await page.setViewport({ width, height: touch ? 844 : 900, hasTouch: touch })   // no isMobile: a page without a viewport meta would lay out at 980 px
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])   // its own line: in the comment above it never ran (both shots one theme)
    await page.goto(href, { waitUntil: 'load' }); await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear() } catch { } })   // fresh storage, then the page as a first visit
    await page.goto(href, { waitUntil: 'load' })
    for (const sel of clicks) await (touch ? page.tap(sel) : page.click(sel)).catch((e) => clipped.push({ el: sel, why: `${touch ? 'tap' : 'click'} failed: ${e.message}`, text: '' }))
    const rest = async (when) => { if (await page.evaluate(settle)) clipped.push({ el: 'page', why: `never settled ${when}: an animation or window.uiBusy() still running after 600 frames`, text: '' }) }
    await rest('as loaded or clicked')
    const base = `${out}/${stem}-${width}-${theme}${si ? '-s' + si : ''}`, height = await page.evaluate(() => document.documentElement.scrollHeight)
    await page.screenshot({ path: `${base}.png`, fullPage: true })   // as the owner sees it: the page's own open / closed defaults
    const hs = await page.evaluate(() => document.documentElement.scrollWidth - innerWidth); if (hs > 1) clipped.push({ el: 'page', why: `horizontal page scroll ${hs} px (a wide table scrolls in its own box)`, text: '' })
    clipped.push(...await page.evaluate(layout), ...await page.evaluate(rows), ...await page.evaluate(svgs), ...await page.evaluate(cols), ...await page.evaluate(stray), ...(si ? [] : await page.evaluate(links)))
    await page.evaluate(openAll); await rest('with every details open')
    clipped.push(...await page.evaluate(scan), ...await page.evaluate(fit), ...await page.evaluate(() => typeof window.uiChecks === 'function' ? window.uiChecks() : []))   // a page's own checks: [{el, why, text}]
    await page.screenshot({ path: `${base}-open.png`, fullPage: true })   // every <details> open: what the clip scan read
    res.push({ width, theme, state: clicks.join(' > ') || 'loaded', shot: `${base}.png`, height, clipped })
  }
} finally { await b.close(); rmSync(ud, { recursive: true, force: true, maxRetries: 5 }) }
console.log(JSON.stringify(res))'''

def lane_ids_shown(page, kit=None):
    """K55: bare lane ids in a page's shown text (<product><k> as a word, k >= 2; a base <product> before " · " or after "env " /
    "lane "), lanes from kit.local.json localEnv.envs (lanes.max); each hit with its context. No lanes configured: none."""
    le = local_config(kit or KIT_DIR, 'kit.local.json').get('localEnv') or {}
    envs = le.get('envs') or {}
    alts = [r'(?<![\w·./\\-])(?<!phone )lane-\d{2,}(?= · )|(?<=env )lane-\d{2,}(?![\w·./\\-])'] if envs and le.get('laneIds') == 'nn' else []   # N3 ids, a lane context only (phone lanes may share them)
    for e, v in envs.items():
        q = re.escape(e)
        alts.append(rf'(?<![\w·./\\-]){q}(?= · )|(?<=env ){q}(?![\w·./\\-])|(?<=lane ){q}(?![\w·./\\-])')
        alts += [rf'(?<![\w·./\\-]){q}{k}(?![\w·./\\-])' for k in range(2, int(((v or {}).get('lanes') or {}).get('max') or 1) + 1)]
    if not alts:
        return []
    with open(page, encoding='utf-8', errors='replace') as fh:
        page_html = fh.read()
    text = html.unescape(re.sub(r'<[^>]+>', ' ', re.sub(r'(?is)<(script|style)\b.*?</\1>', ' ', page_html)))
    return [f'{m.group(0)}: ...{text[max(0, m.start() - 30):m.end() + 30].strip()}...' for m in re.finditer('|'.join(alts), text)][:20]

def cmd_ui_check(a):
    """ui-check <page.html> [--widths 1920,1366,900,390] [--click 'sel,sel;sel']: PAGE_JS (light + dark; each --click state after
    the page as loaded); exit 1 on clipped text, a failed click, a layout box (window.uiBoxes) off-screen or overlapping, an svg over a sibling tile or a [data-fit]
    card with 24+ px blank below its content, a card row 24+ px short of its box at 1280+ px or a link that navigates away (kit
    pages: the drawer, data-dw; web URLs: target=_blank), 0 = pass + stamp."""
    flags, rest = parse_opts(a, {'--widths', '--click'})
    widths = str(flags.get('--widths') or '1920,1366,900,390')
    if len(rest) != 1 or not osp.isfile(rest[0]) or not re.fullmatch(r'\d+(,\d+)*', widths):
        print('usage: kitbag.py ui-check <page.html> [--widths 1920,1366,900,390] [--click "<selector>,<selector>;<selector>"]', file=sys.stderr)
        return 2
    if flags.get('--click') and stdout_is_file():   # an unquoted 'a > b' made the shell write stdout to a file named b (a stray 'summary')
        print('kitbag ui-check: stdout goes to a file: an unquoted ">" in --click redirects it; quote the selector or run it from pwsh '
              '(to keep a log on purpose: pipe through tee)', file=sys.stderr)
        return 2
    states = [[]] + [[x.strip() for x in s.split(',') if x.strip()] for s in str(flags.get('--click') or '').split(';') if s.strip()]
    pokey, shots = osp.join(KIT_DIR, 'skills', 'pokey'), osp.join(kit_path('shots', create=True), 'ui-check')
    os.makedirs(shots, exist_ok=True)
    stem = re.sub(r'\.html?$', '', osp.basename(rest[0]), flags=re.I)
    code, out, err = run(['node', '--input-type=module', '-e', PAGE_JS, Path(pokey, 'browser.mjs').as_uri(), osp.abspath(rest[0]), widths,
                          json.dumps(states), shots, stem], cwd=pokey, timeout=kit_param('uiCheck.timeoutSec'))
    try:
        res = json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        why = next((ln.strip() for ln in (err or out).splitlines() if re.match(r'\s*\w*(Error|Exception)\b', ln)), '')   # node prints the stack's file line first
        print(f'kitbag ui-check: the headless render failed (exit {code}): {why}\n{err or out}', file=sys.stderr)
        return 2
    bad = 0
    for r in res:
        print(f"{r['width']} px {r['theme']} {r['state']}: {r['shot']} · {r.get('height', 0)} px tall as loaded · {len(r['clipped'])} clipped")
        for c in r['clipped']:
            print(f"  CLIP {c['el']}: {c['why']} ({c['text']})")
        bad += len(r['clipped'])
    lane_bad = lane_ids_shown(rest[0])
    for ln in lane_bad:
        print(f'  LANE-ID {ln}')
    if bad or lane_bad:
        print(f'kitbag ui-check: {bad + len(lane_bad)} issue(s): content wraps, never truncates; lanes show as <product>·<Bird> '
              '(README "Live supervisor dashboard", "Worktrees and lanes")')
        return 1
    stamp = ui_check_stamp()
    os.makedirs(osp.dirname(stamp), exist_ok=True)
    with open(stamp, 'w', encoding='utf-8') as fh:
        json.dump({'at': kit_stamp(), 'page': osp.abspath(rest[0]), 'widths': widths}, fh)
    print('kitbag ui-check: no clipped text; now read each shot (overlap, gaps, contrast) before the commit')
    return 0

# ---- audit: findings, shared helpers, stamp (scan: kitbag_admin.py)
# user-named subtrees (or samples): never "missing"
USER_MAPS = ('localEnv', 'repos', 'repoAliases', 'targets', 'linkFromByTarget', 'tracker.statuses', 'tracker._examples',
  'gate.startHeapGB', 'lanes', 'app', 'localFiles', 'deploy.minIntervalHours', 'tests', 'qa.targets', 'qa.lanes', 'qa.userRecipes', 'masking.rules', 'runtimes')
AUTOMATIC = {'input', 'args', 'matches', 'error', 'host', 'home', 'pid', 'pwd', 'profile', 'this', 'event', 'sender', 'ofs',
   'psitem', 'iswindows', 'islinux', 'ismacos', 'executioncontext', 'myinvocation', 'psboundparameters', 'lastexitcode'}
AUDIT_VERBS = {'stamp': lambda kit, flags: cmd_stamp(kit)}   # kitbag_admin.py adds setup, config, recover, scan
findings = []

def out(level, code, where, what, fix=''):
    findings.append({'level': level, 'code': code, 'where': where, 'what': what, 'fix': fix})

def stdout_is_file():
    try:
        import stat
        return stat.S_ISREG(os.fstat(sys.stdout.fileno()).st_mode)
    except (OSError, ValueError, AttributeError):
        return False


def run(cmd, cwd=None, timeout=60, stdin=''):
    """(exit code, stdout, stderr); 124 = timeout, 127 = not runnable."""
    try:
        p = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
        return p.returncode, (p.stdout or '').strip(), (p.stderr or '').strip()
    except subprocess.TimeoutExpired:
        return 124, '', f'timed out after {timeout} s'
    except OSError as e:
        return 127, '', str(e)

def git(kit, *a, timeout=60):
    return run(['git', '-C', kit, *a], timeout=timeout)

def load_json(path):
    """(data, error): data None when the file is missing or invalid."""
    if not osp.isfile(path):
        return None, 'missing'
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f), None
    except json.JSONDecodeError as e:
        return None, f'invalid JSON ({e.msg}, line {e.lineno})'
    except (UnicodeDecodeError, OSError) as e:
        return None, f'unreadable ({e})'

def key_paths(d, prefix=''):
    """Dotted key paths of nested objects (lists and user-named maps are leaves)."""
    for k, v in (d or {}).items():
        if k.startswith('_'):
            continue
        p = f'{prefix}{k}'
        yield p
        if isinstance(v, dict) and not any(p == m or p.startswith(m + '.') for m in USER_MAPS):
            yield from key_paths(v, p + '.')

def git_ignored(kit, rels):
    """The rels git ignores (.gitignore, .git/info/exclude, core.excludesFile); empty when kit is no repo's top folder."""
    rc, top, _ = git(kit, 'rev-parse', '--show-toplevel')
    if rc or osp.normcase(osp.realpath(top)) != osp.normcase(osp.realpath(kit)):
        return set()
    rc, o, _ = run(['git', '-C', kit, 'check-ignore', '-z', '--stdin'], stdin='\0'.join(rels))
    return set(o.split('\0')) - {''} if rc in (0, 1) else set()

def tracked(kit):
    rc, o, _ = git(kit, 'ls-files')   # an unmerged file (a rebase with conflicts) has one entry per stage: once each
    return list(dict.fromkeys(x for x in o.splitlines() if x)) if rc == 0 else []

def strip_ps_comments(text):
    text = re.sub(r'<#.*?#>', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return '\n'.join(re.sub(r'(^|\s)#(?![>{]).*$', r'\1', l) if not re.search(r"""['"][^'"]*#""", l) else l for l in text.split('\n'))

MATH_DBL = re.compile(r'/|\d\.\d|\[double\]|\.Total\w*|\w+GB\b|Get-Kit(Param|Setting|BeatMinutes)\b|\(Left\)|\[math\]::(Pow|Sqrt)\b|\[math\]::Round\([^()]*,\s*[1-9]')

def ps_math_int(t):
    """[math]::Min/Max(<int literal>, <a side that may be a double>): [(line, second argument)] (here-strings and comments skipped)."""
    code = re.sub(r"""@'[ \t]*\r?\n.*?\r?\n[ \t]*'@|@"[ \t]*\r?\n.*?\r?\n[ \t]*"@""", lambda m: '\n' * m.group(0).count('\n'), strip_ps_comments(t), flags=re.S)   # here-strings only: 'x@' in a line is none
    out = []
    for m in re.finditer(r'\[math\]::(?:Min|Max)\(\s*-?\d+\s*,', code, re.I):
        i, depth = m.end(), 1
        while i < len(code) and depth:
            depth += {'(': 1, ')': -1}.get(code[i], 0)
            i += 1
        arg = code[m.end():i - 1].strip()
        bare = re.sub(r""""(?:[^"`]|`.)*"|'[^']*'""", "''", arg)
        whole = re.match(r'\[math\]::(?:Ceiling|Floor|Round|Truncate)\(', bare, re.I)   # a whole number: the Int32 overload is exact
        if whole:
            j, d = whole.end(), 1
            while j < len(bare) and d:
                d += {'(': 1, ')': -1}.get(bare[j], 0)
                j += 1
                whole = whole if d != 1 or bare[j - 1] != ',' else None   # Round(x, 1): digits stay
        if MATH_DBL.search(bare) and not re.match(r'\[(?:int|long)\]', bare, re.I) and not (whole and j == len(bare)):
            out.append((code.count('\n', 0, m.start()) + 1, arg))
    return out

def ps_case(t):
    """One variable assigned under two spellings ($L, $l) in one function (or the script body): [(line, b, a, line_a)]."""
    code = re.sub(r"""@'.*?'@|@".*?"@""", lambda m: '\n' * m.group(0).count('\n'), strip_ps_comments(t), flags=re.S)
    scopes, stack, depth, sid, pending = {}, [(0, -1)], 0, 0, None   # stack: (scope id, depth it closes at)
    for ln, line in enumerate(code.split('\n'), 1):
        if re.match(r'\s*function\s+[\w:-]+', line, re.I):
            sid += 1; pending = sid
        cur = pending if pending is not None else stack[-1][0]
        line = re.sub(r"""'[^']*'|"(?:[^"`]|`.)*\"""", '""', line)   # quoted text is data
        for m in re.finditer(r'\$(?:script:|local:)?([A-Za-z_]\w*)\s*(?:=(?![=~])|\+=)|foreach\s*\(\s*\$([A-Za-z_]\w*)\s+in\b', line, re.I):
            n = m.group(1) or m.group(2)
            if n.lower() not in AUTOMATIC:
                scopes.setdefault(cur, {}).setdefault(n.lower(), {}).setdefault(n, ln)
        for ch in line:
            if ch == '{':
                depth += 1
                if pending is not None:
                    stack.append((pending, depth)); pending = None
            elif ch == '}':
                if len(stack) > 1 and stack[-1][1] == depth:
                    stack.pop()
                depth -= 1
    hits = []
    for vars_ in scopes.values():
        for forms in vars_.values():
            if len(forms) > 1:
                (a, la), (b, lb) = sorted(forms.items(), key=lambda x: x[1])[:2]
                hits.append((lb, b, a, la))
    return sorted(hits)

def cmd_stamp(kit):
    p = kit_path('last-kitty-audit', create=True, kit=kit)
    now = kit_stamp()
    with open(p, 'w', encoding='utf-8') as f:
        f.write(now + '\n')
    out('FIX', 'AUDIT-STAMP', p, f'last kit audit = {now} (the SessionStart nudge resets)')

def audit_main(a):
    verb = a[0]
    flags, _ = parse_opts(a[1:], {'--kit', '--json'})
    # scan: this file's kit (the worktree being changed); other verbs: the live clone
    kit = osp.abspath(flags.get('--kit') or (KIT_DIR if verb == 'scan' else main_clone(KIT_DIR)))
    AUDIT_VERBS[verb](kit, flags)
    order = {'FIX': 0, 'ACT': 1, 'ASK': 2, 'WARN': 3, 'INFO': 4}
    for x in sorted(findings, key=lambda x: (order[x['level']], x['code'], x['where'])):
        print(f"{x['level']:4} {x['code']} {x['where']}: {x['what']}" + (f" -> {x['fix']}" if x['fix'] else ''))
    n = {lv: sum(1 for x in findings if x['level'] == lv) for lv in order}
    print(f'kitbag audit {verb} ({kit}): ' + (', '.join(f'{v} {k}' for k, v in n.items() if v) or 'nothing found'))
    if '--json' in flags:
        with open(flags['--json'], 'w', encoding='utf-8') as f:
            json.dump(findings, f, indent=1)
    return 1 if n['ACT'] or n['ASK'] else 0

# ---- registry: _manifest lists crew parts and caps, lint checks files and front matter (JSON Schema subset) against it
TODO = 'TODO(new)'   # stub left by kitbag.py new (kitbag_scaffold.py); lint TODO-STUB refuses it
SCHEMAS = {
 'skill': {'type': 'object', 'required': ['name', 'description'], 'additionalProperties': False,
   'properties': {'name': {'type': 'string', 'pattern': r'^[a-z][a-z0-9-]*$'},
       'description': {'type': 'string', 'pattern': r'^Load when: .+ Not when: .+->', 'maxLength': 450},
       'argument-hint': {'type': 'string'}}},
 'agent': {'type': 'object', 'required': ['name', 'description'], 'additionalProperties': False,
   'properties': {'name': {'type': 'string', 'pattern': r'^[a-z][a-z0-9-]*$'},
       'description': {'type': 'string', 'pattern': r'Spawned by .+Not for'},
       'tools': {'type': 'string', 'minLength': 3}, 'disallowedTools': {'type': 'string', 'minLength': 3}, 'model': {'type': 'string', 'enum': ['sonnet', 'opus', 'haiku', 'inherit']}}},
 'character': {'type': 'object', 'required': ['traits', 'bias', 'catchphrase', 'never'], 'additionalProperties': False,
    'properties': {x: {'type': 'string', 'minLength': 3} for x in ('traits', 'bias', 'catchphrase', 'never')}},
 'manifest-agent': {'type': 'object', 'required': ['job', 'kinds', 'roles', 'skill', 'tools', 'usedIn', 'cant', 'character'], 'additionalProperties': False,
     'properties': {'job': {'type': 'string', 'minLength': 3}, 'kinds': {'type': 'array', 'items': {'type': 'string'}},
         'roles': {'type': 'array', 'items': {'type': 'string'}}, 'skill': {'type': 'string'},
         'tools': {'type': 'string', 'minLength': 3}, 'usedIn': {'type': 'array', 'items': {'type': 'string'}},
         'cant': {'type': 'string', 'minLength': 3}, 'character': {'type': 'object'}}},
}
TYPES = {'object': dict, 'array': list, 'string': str, 'boolean': bool, 'number': (int, float), 'integer': int}

def schema_errors(obj, sch, where='$'):
    """Problems of obj against a JSON Schema subset (the formats the kit uses)."""
    out = []
    t = sch.get('type')
    if t and not isinstance(obj, TYPES[t]):
        return [f'{where}: expected {t}, got {type(obj).__name__}']
    if t == 'object':
        for r in sch.get('required', []):
            if r not in obj:
                out.append(f'{where}: missing field "{r}"')
        props = sch.get('properties', {})
        for key, v in obj.items():
            if key in props:
                out += schema_errors(v, props[key], f'{where}.{key}')
            elif sch.get('additionalProperties') is False:
                out.append(f'{where}: unknown field "{key}"')
    if t == 'array' and 'items' in sch:
        for i, v in enumerate(obj):
            out += schema_errors(v, sch['items'], f'{where}[{i}]')
    if t == 'string':
        if 'enum' in sch and obj not in sch['enum']:
            out.append(f'{where}: "{obj}" not one of {sch["enum"]}')
        if 'pattern' in sch and not re.search(sch['pattern'], obj, re.S):
            out.append(f'{where}: does not match {sch["pattern"]}')
        if len(obj) < sch.get('minLength', 0):
            out.append(f'{where}: shorter than {sch["minLength"]}')
        if 'maxLength' in sch and len(obj) > sch['maxLength']:
            out.append(f'{where}: {len(obj)} chars (max {sch["maxLength"]})')
    return out

PARITY_JSON = 'skills/crafty/parity.json'   # the adapter families (manifest 'adapters') and the harness port table

def manifest(kit=None):
    try:
        man = json.loads(read(osp.join(kit or KIT_DIR, PATHS_JSON)) or '{}').get('_manifest') or {}
        return {**man, 'adapters': (json.loads(read(osp.join(kit or KIT_DIR, PARITY_JSON)) or '{}').get('adapters') or {})} if man else man
    except ValueError:
        return {}

# ---- tools: per-role allowlists (owner 2026-11-24: the coordinator keeps every tool, a crew role only what its list names)
TOOLS_LINE_RX = re.compile(r'^(?:tools|disallowedTools):[^\r\n]*(\r?\n)', re.M)

def tools_live(kit):
    """Grants render only into the installed kit (<workspace>/.claude: the agents Claude Code loads), never a worktree's files."""
    return osp.basename(osp.normpath(kit)) == '.claude'

def role_tools(name, kit=None, local=False):
    """A role's front matter tools: _manifest.agents.<name>.tools, toolSets expanded; local: + kit.local.json tools.roles.<name>
    (the org's MCP servers: their names never enter a tracked file). None = no manifest entry."""
    m = manifest(kit)
    spec = ((m.get('agents') or {}).get(name) or {}).get('tools')
    if not isinstance(spec, str):
        return None
    sets, out = m.get('toolSets') or {}, []
    for t in [x.strip() for x in spec.split(',') if x.strip()]:
        out += [u.strip() for u in (sets[t].split(',') if t in sets else [t]) if u.strip() and u.strip() not in out]
    grants = ((local_config(kit or KIT_DIR, 'kit.local.json').get('tools') or {}).get('roles') or {}).get(name) if local else None
    out += [g for g in (grants if isinstance(grants, list) else []) if isinstance(g, str) and re.fullmatch(r'mcp__[\w*-]+|[A-Z]\w*', g) and g not in out]   # one tool name each: no injected line
    return ', '.join(out)

def set_tools_line(text, tools):
    """The front matter with one `tools:` line (a disallowedTools line goes), the file's line ending kept."""
    head = re.match(r'^---\r?\n.*?\r?\n---', text, re.S)
    if not head or not tools:
        return text
    fm = head.group(0)
    eol = '\r\n' if '\r\n' in fm else '\n'
    body = TOOLS_LINE_RX.sub('', fm)
    at = re.search(r'^model:', body, re.M)
    pos = at.start() if at else body.rfind(eol + '---') + len(eol)
    return body[:pos] + f'tools: {tools}{eol}' + body[pos:] + text[len(fm):]

TOOL_WORDS = ('WebFetch', 'WebSearch', 'Monitor', 'TaskStop', 'ToolSearch', 'NotebookEdit', 'SendMessage', 'AskUserQuestion', 'TodoWrite',
  'CronCreate', 'CronDelete', 'CronList', 'Skill tool', 'Workflow(')

def tools_named(line):
    """The tools a step line calls (TOOLS-SCOPE): a spawn = Agent, `<Name> tool`, a distinctive tool name, an mcp__ name; front matter skipped."""
    if re.match(r'^(name|description|tools|disallowedTools|model):', line):
        return []
    out = ['Agent'] if re.search(r'\bspawns?\b|\bAgent tool\b', line) and not re.search(r'cannot spawn|No Agent tool', line) else []
    out += [m for m in re.findall(r'\b(Read|Write|Edit|Bash|PowerShell|Glob|Grep) tool\b', line)]
    out += [w.split(' ')[0].rstrip('(') for w in TOOL_WORDS if re.search(r'\b' + re.escape(w) + (r'\b' if w[-1].isalnum() else ''), line)]
    return out + re.findall(r'\bmcp__[\w-]+', line)

CHAR_RX = re.compile(r'^\*\*Character:\*\*\s*(.*?)(?=\n\s*\n|\Z)', re.S | re.M)

def character_of(text):
    """The Character block of an agent file as {traits, bias, catchphrase, never} ({} when absent)."""
    m = CHAR_RX.search(text or '')
    if not m:
        return {}
    flat = re.sub(r'\s+', ' ', m.group(1)).strip()
    mm = re.match(r'^traits: (.+?) · bias: (.+?) · catchphrase: "(.+?)" · never: (.+?)\.?$', flat)
    return dict(zip(('traits', 'bias', 'catchphrase', 'never'), mm.groups())) if mm else {'_raw': flat}

def old_name_rx(old):
    # bare, file or joined name (last-<old>, <old>s, <old>-x); a same-stem <name>.stamp is none
    return re.compile(r'(?<![\w.-])((?:\w+-)*)' + re.escape(old) + r'((?:s|-\w+)*)(?![\w-])(?!\.(?:local\.)?stamp\b)')


def yaml_problems(text):
    """[(line, why)]: a plain scalar holding ': ' (or ending in ':') is invalid YAML; PyYAML, when installed, parses it too."""
    out, block = [], None
    for i, ln in enumerate(text.split('\n'), 1):
        s = ln.rstrip(); ind = len(s) - len(s.lstrip(' '))
        if block is not None:
            if not s.strip() or ind > block:
                continue
            block = None
        if not s.strip() or s.lstrip().startswith('#'):
            continue
        m = re.match(r'''^\s*(?:-\s+)?(?:"[^"]*"|'[^']*'|[^\s#'"{\[][^:#]*?)\s*:(?:\s+(.*))?$''', s)
        v = re.sub(r'\s+#.*$', '', (m.group(1) or '') if m else '').strip()
        if re.match(r'^[|>][-+0-9]*$', v):
            block = ind
        elif v and v[0] not in '"\'[{&*!|>' and (': ' in v or v.endswith(':')):
            out.append((i, f'plain scalar with ": " (quote it): {v[:60]}'))
    try:
        import yaml
        yaml.safe_load(text)
    except ImportError:
        pass
    except Exception as e:   # yaml.YAMLError
        mk = getattr(e, 'problem_mark', None)
        out.append(((mk.line + 1) if mk else 0, str(e).split('\n')[0]))
    return out

# ---- parity: every adapter x its family's verbs, every harness x kit feature (AGENTS.md "Parity", skills/crafty/parity.json)
# a registration: Register-KitAdapter <kind> <name> <@{...} | $var[.Clone()]> (ps1) or ADAPTERS['<kind>']['<name>'] = {...} (py)
AD_REG = re.compile(r"""Register-KitAdapter\s+'?([\w-]+)'?\s+'?([\w-]+)'?|ADAPTERS(?:\[['"]([\w-]+)['"]\]|\.setdefault\(['"]([\w-]+)['"],\s*\{\}\))\[['"]([\w-]+)['"]\]\s*=""")
AD_KEY = re.compile(r"""(['"]?)([\w.*-]+)\1\s*(=(?!=)|:)""")   # a key of an adapter's hashtable / dict
AD_DELEGATE = re.compile(r"""\$KitAdapters(?:\.([\w-]+)|\[['"]([\w-]+)['"]\])(?:\.([\w-]+)|\[['"]([\w-]+)['"]\])""")   # '*' = another adapter's verbs
ktext = lambda k, rel: k.texts.get(rel) or read(osp.join(k.dir, rel))   # port copies and settings.json: not in every k.texts
HARNESS = ('codex', 'antigravity')
AD_EXT, AD_COMMENT = ('.ps1', '.py', '.mjs'), r'(?m)^[ \t]*(#|//).*$'   # .mjs: ADAPTERS['<kind>']['<name>'] = {...} (browser.mjs)
kebab = lambda v: re.sub('([A-Z])', r'-\1', v).lower()   # Test-KitCap: cap commentEdit = verb comment-edit
# a verb whose whole body only refuses: { [param(..)] throw 'UNSUPPORTED ..' | '..not supported' } (ps1), lambda ..: sys.exit / raise (py)
AD_STUB = re.compile(r"""(?:\{\s*(?:param\([^)]*\)\s*;?\s*)?throw|lambda[^:\n]*:\s*(?:sys\.exit|raise\s+\w+)\()\s*\(?\s*[f$]?['"][^'"\n]*(?:UNSUPPORTED|not supported)[^\n]*""", re.I)
AD_ROUTERS = {'Invoke-HostVerb': ('git-host', {'ci.': 'ci'})}   # a dispatcher whose family is computed, not literal: (family, {verb prefix: family})

def adapter_calls(k):
    """{family: {verb: 'file:line'}} of every literal verb or cap the kit's code dispatches (owner 2026-11-24: cells from code, not
    only parity.json): Invoke-KitAdapter <fam> <name> <verb>, Test-KitCap <fam> <name> <cap>, any function that forwards $Verb /
    $Cap to them (found, never listed: __TrA, __TrCan), AD_ROUTERS, and Python `<var> = ADAPTERS['<fam>']...` then <var>['<verb>']
    / .get('<verb>') within 15 lines."""
    out, texts = {}, {f: re.sub(AD_COMMENT, '', t) for f, t in k.texts.items() if re.match(r'(skills|workflows)/', f) and f.endswith(AD_EXT)
                      and '.local.' not in f and '/kitbag' not in f}
    def add(fam, v, f, t, i):
        if fam and re.match(r'^[A-Za-z][\w.-]*$', v or ''):
            out.setdefault(fam, {}).setdefault(v, f'{f}:{t.count(chr(10), 0, i) + 1}')
    fwd = {}   # forwarding function -> its family (a literal family, the verb or cap passed through)
    for f, t in texts.items():
        for m in re.finditer(r"""(?:Invoke-KitAdapter|Test-KitCap)\s+'?([\w-]+)'?\s+\S+\s+\$(?:Verb|Cap)\b""", t):
            fn = list(re.finditer(r'(?m)^\s*function\s+([\w-]+)', t[:m.start()]))
            if fn:
                fwd[fn[-1].group(1)] = (m.group(1), {})
    for f, t in texts.items():
        for m in re.finditer(r"""(?:Invoke-KitAdapter|Test-KitCap)\s+'([\w-]+)'\s+\S+\s+'?([A-Za-z][\w.-]*)'?|(?:Invoke-KitAdapter|Test-KitCap)\s+([a-z][\w-]*)\s+\S+\s+'?([A-Za-z][\w.-]*)'?""", t):
            add(m.group(1) or m.group(3), m.group(2) or m.group(4), f, t, m.start())
        for fn, (fam, pre) in {**fwd, **AD_ROUTERS}.items():
            for m in re.finditer(r"""(?<![\w$-])%s\s+'?([A-Za-z][\w.-]*)'?""" % re.escape(fn), t):
                p = next((x for x in pre if m.group(1).startswith(x)), None)
                add(pre[p] if p else fam, m.group(1)[len(p):] if p else m.group(1), f, t, m.start())
        if f.endswith('.py'):
            for m in re.finditer(r"""(?:(\w+)\s*=|for\s+\w+\s*,\s*(\w+)\s+in)\s*(?:\w+\.)?ADAPTERS\[['"]([\w-]+)['"]\]""", t):
                var, win = m.group(1) or m.group(2), t[m.end():m.end() + 15 * 120]
                for c in re.finditer(r"""(?<![\w.])\(?%s(?:\s+or\s+\{\}\))?(?:\[['"]([\w-]+)['"]\]|\.get\(['"]([\w-]+)['"]\))""" % re.escape(var), win):
                    add(m.group(3), c.group(1) or c.group(2), f, t, m.end() + c.start())
    return out

def _str_end(t, x, py):
    """Index of the closing quote of the string opening at t[x]: py / js backslash escapes; ps1 '..' literal, "..." with ` and ""
    escapes and $( ) code inside (nested strings), @' / @" here-strings to their '@ / "@ line."""
    q = t[x]
    if not py and t[x - 1:x] == '@' and t[x + 1:x + 2] in '\r\n':
        e = t.find('\n' + q + '@', x)
        return e + 1 if e >= 0 else len(t)
    x += 1
    while x < len(t):
        c = t[x]
        if (py and c == '\\') or (not py and q == '"' and c == '`'):
            x += 1
        elif c == q and not py and t[x + 1:x + 2] == q:
            x += 1
        elif c == q:
            return x
        elif not py and q == '"' and t[x:x + 2] == '$(':
            x, d = x + 2, 1
            while x < len(t) and d:
                d += {'(': 1, ')': -1}.get(t[x], 0)
                x = (_str_end(t, x, py) if t[x] in '\'"' else x) + 1
            x -= 1
        x += 1
    return x

def _braced(t, i, py=False):
    """t from its first { at or after i to the matching }; braces in strings and trailing comments skipped (a regex '@\\{' in a
    string broke the match, retro tidy-6)."""
    j, d, x = t.find('{', i), 0, t.find('{', i)
    while 0 <= x < len(t):
        c = t[x]
        if c in '\'"':
            x = _str_end(t, x, py)
        elif not py and t[x:x + 2] == '<#':   # a ps1 block comment
            e = t.find('#>', x + 2)
            x = e + 1 if e >= 0 else len(t)
        elif (c == '#' or (py and t[x:x + 2] == '//')) and t[x - 1:x] in ' \t\n':
            x = (t.find('\n', x) + 1 or len(t)) - 1
        else:
            d += {'{': 1, '}': -1}.get(c, 0)
            if not d:
                return t[j:x + 1]
        x += 1
    return t[j:] if j >= 0 else ''

def _var_code(t, name, before, depth=0):
    """$name's hashtable before offset `before`: its @{...}, through .Clone() chains, plus later $name.<key> = sets."""
    defs = list(re.finditer(r'\$' + name + r'\s*=\s*', t[:before]))
    if not defs or depth > 3:
        return ''
    d = defs[-1]
    c = re.match(r'\$(\w+)\.Clone\(\)', t[d.end():])
    base = _var_code(t, c.group(1), d.start(), depth + 1) if c else _braced(t, d.end())
    return base + '\n' + '\n'.join(x.group(0) for x in re.finditer(r'\$' + name + r'\.\w+\s*=\s*[^;\n]+', t[d.end():before]))

def _top_keys(b, py=False):
    """{key: its value is code} at brace depth 1 of an adapter's hashtable / dict (scriptblock bodies, nested tables, strings and
    comments skipped); `$var.<key> = ...` lines after it count too."""
    out, d, i, last = {}, 0, 0, ''
    while i < len(b):
        c = b[i]
        if d == 1 and last in ('{', ';', ',', '\n') and (m := AD_KEY.match(b, i)):
            nx = b[m.end():m.end() + 40].lstrip()
            out[m.group(2)] = nx[:1] == '{' if m.group(3) == '=' else bool(re.match(r'lambda|[A-Za-z_]', nx))
            i, last = m.end(), '='
            continue
        if not py and b[i:i + 2] == '<#':   # a ps1 block comment
            e = b.find('#>', i + 2)
            i = e + 2 if e >= 0 else len(b)
            continue
        if c == '#' and (d == 1 or b[i - 1:i] in ' \t\n'):   # a trailing comment (an apostrophe in it is no string)
            i = b.find('\n', i) if '\n' in b[i:] else len(b)
            continue
        if c in '\'"':   # a string at any depth: a brace in it is no code (retro tidy-6: '@\{')
            i, last = _str_end(b, i, py) + 1, c
            continue
        d += (c == '{') - (c == '}')
        if c not in ' \t\r':
            last = c
        i += 1
    out.update({x: False for x in re.findall(r'\$\w+\.(\w+)\s*=', b)})
    return out

def adapter_code(k, kind):
    """{name: (code, file)} of every registration of `kind` in the kit's tracked skills/**/*.ps1|py (local overlays and
    comment lines excluded)."""
    out = {}
    for f, t in k.texts.items():
        if not (f.startswith('skills/') and f.endswith(AD_EXT)) or '.local.' in f:
            continue
        t = re.sub(AD_COMMENT, '', t)
        for m in AD_REG.finditer(t):
            kn, n = (m.group(1), m.group(2)) if m.group(1) else (m.group(3) or m.group(4), m.group(5))
            if kn != kind:
                continue
            v = re.match(r'\s+\$(\w+)', t[m.end():])
            b = _var_code(t, v.group(1), m.start()) if v else _braced(t, m.end(), not f.endswith('.ps1'))
            out[n] = (out.get(n, ('', f))[0] + b, f)
    return out

def adapter_kinds(k):
    """Every adapter kind the kit's code registers."""
    return {kn for f, t in k.texts.items() if f.startswith('skills/') and f.endswith(AD_EXT) and '.local.' not in f
            for m in AD_REG.finditer(re.sub(AD_COMMENT, '', t)) for kn in [m.group(1) or m.group(3) or m.group(4)]}

def _gap_keys(gaps):
    """'a,b/v1,v2' keys -> {(name, verb): (key, why)}."""
    out = {}
    for key, why in (gaps or {}).items():
        ns, _, vs = key.partition('/')
        out.update({(n.strip(), v.strip()): (key, why) for n in ns.split(',') for v in vs.split(',')})
    return out

def adapter_matrix(k, fam, a, bad=None):
    """{name: {verb: native | config | fallback | gap | MISSING}} of one family ({} when its `parity` says why it is not walked);
    bad() gets each PARITY problem. Each verb, cap and fallback key of every adapter: native, else the family's fallback (same
    outcome), else a declared gap; capKeys: a cap read from its own keys (supportsMarks = $true, a sizes block)."""
    bad = bad or (lambda *x: None)
    if a.get('parity'):
        return {}
    verbs, caps, fb, ck = a.get('verbs', '').split(), a.get('caps', '').split(), a.get('fallback') or {}, a.get('capKeys') or {}
    gaps, used, code, out, delegates = _gap_keys(a.get('gaps')), set(), adapter_code(k, fam), {}, {}
    allv = list(dict.fromkeys(verbs + caps + [x for x in fb if not x.startswith('_')] + [v for _, v in gaps]))
    if not hasattr(k, 'ad_calls'):
        k.ad_calls = adapter_calls(k)
    known = set(allv) | {kebab(x) for x in allv}
    for v, at in (k.ad_calls.get(fam) or {}).items():   # a verb code calls that no list names: a cell on every adapter
        if v not in known:
            bad('PARITY', at.rsplit(':', 1)[0], f'{fam}: verb {v} is called ({at}) but in no family list: add it to adapters.{fam} verbs (required) or caps (optional) in {PARITY_JSON}')
            allv.append(v)
    names = a.get('names', '').split() + a.get('vendors', '').split()
    for n in sorted(set(code) - set(names)):   # registered in code, not declared: walked too, so its missing cells show
        bad('PARITY', code[n][1], f'{fam}/{n}: registered in code, but {PARITY_JSON} adapters.{fam} names / vendors do not list it: add it')
        names.append(n)
    for n in names:
        if n not in code:
            bad('PARITY', PARITY_JSON, f'{fam}/{n}: registered, but no Register-KitAdapter / ADAPTERS entry registers it')
            continue
        b, f = code[n]
        cm = re.search(r"""['"]?caps['"]?\s*=\s*""", b)
        ct = _braced(b, cm.end()) if cm else ''
        cs = dict((x, y == 'true') for x, y in re.findall(r'(\w+)\s*=\s*\$(true|false)', ct)) if re.match(r'\s*@', b[cm.end():] if cm else '') else None
        body = b.replace(ct, '') if ct else b
        tops = _top_keys(body, not f.endswith('.ps1'))
        star = '*' in tops
        dl = AD_DELEGATE.search(body) if star else None
        if dl and (dl.group(1) or dl.group(2)) == fam:
            delegates[n] = dl.group(3) or dl.group(4)
        has = lambda v: v in tops
        def state(v):
            if v in ck:   # bool keys: the last assignment wins (a Clone's override); others: present
                vals = [re.findall(rf'\b{re.escape(x)}\s*=\s*\$(true|false)', b) or ([None] if has(x) else []) for x in ck[v].split()]
                return 'native' if any(x and (x[-1] in (None, 'true')) for x in vals) else None
            if cs is not None and v in cs:
                return 'native' if cs[v] else None
            if ct and cs is None and v in caps:
                return 'config'   # a caps scriptblock: what the org's commands configure
            if has(v) or has(kebab(v)):
                return None if any(AD_STUB.match(body, m.end()) for x in (v, kebab(v))
                                   for m in re.finditer(r"""(['"]?)%s\1\s*[=:]\s*""" % re.escape(x), body)) else 'native'   # throws UNSUPPORTED only: no verb
            return ('config' if 'Invoke-KitCommand' in body else 'native') if star else None
        row = {}
        for v in allv:
            s = state(v)
            if s and (n, v) in gaps and n in delegates:   # a delegate's row is its target's: its own gap entry says why for it
                used.add(gaps[(n, v)][0])
            elif s and (n, v) in gaps:
                bad('PARITY', PARITY_JSON, f'{fam}/{n}/{v}: declared gap "{gaps[(n, v)][0]}", but the adapter has it now: drop it')
            if not s and (n, v) in gaps:
                s = 'gap'; used.add(gaps[(n, v)][0])
            elif not s:
                s = 'fallback' if v in fb else 'MISSING'
            if s == 'MISSING':
                bad('PARITY', f, f'{fam}/{n}/{v}: {"a required verb" if v in verbs else "an optional verb"} with no native code, '
                    f'fallback or declared gap: add the verb, or a fallback / gaps entry in {PARITY_JSON} adapters.{fam} (AGENTS.md "Parity")')
            row[v] = s
        known = set(allv) | {kebab(x) for x in allv} | {x for v in ck.values() for x in v.split()} | {'*', 'caps'}
        for x in sorted({x for x, code in tops.items() if code} - known):
            bad('PARITY', f, f'{fam}/{n}: verb {x} is in no family list: add it to adapters.{fam} verbs (every adapter) or fallback (optional) in {PARITY_JSON}, then check every sibling')
        out[n] = row
    for n, to in delegates.items():   # '*' -> another adapter: its row (jira-server = jira)
        if to in out:
            out[n] = dict(out[to])
    for v in [x for x in fb if not x.startswith('_')]:   # a declaration the code no longer needs is stale
        if out and not any(r.get(v) in ('fallback', 'gap') for r in out.values()):   # a gap's adapter runs the fallback too
            bad('PARITY', PARITY_JSON, f'{fam}: fallback "{v}" is used by no adapter (each is native or config now): drop it')
    for key in sorted({x[0] for x in gaps.values()} - used):
        if not any(gaps[g][0] == key and g[0] in out and out[g[0]].get(g[1]) != 'gap' for g in gaps):
            bad('PARITY', PARITY_JSON, f'{fam}: gaps "{key}" names no adapter or verb of the family: fix or drop it')
    for (n, v), (key, why) in _gap_keys(a.get('accepted')).items():   # a by-design fallback: its reason, and a cell still open
        if out.get(n, {}).get(v) not in ('fallback', 'gap'):
            bad('PARITY', PARITY_JSON, f'{fam}: accepted "{key}": {n}/{v} is {out.get(n, {}).get(v) or "no cell"}, no fallback: drop it')
        elif not why.strip():
            bad('PARITY', PARITY_JSON, f'{fam}: accepted "{key}" has no reason: say why the fallback is the design')
    return out

def _port_hooks(k):
    """{harness: [(event, hook text)]} from the kit's ported hook files (kitbag.py port writes them)."""
    toml = ktext(k, '.codex/config.toml')
    cx = [(m.group(1), toml[m.end():(nx.start() if (nx := re.compile(r'^\[\[hooks\.\w+\]\]$', re.M).search(toml, m.end())) else len(toml))])
          for m in re.finditer(r'^\[\[hooks\.(\w+)\]\]$', toml, re.M)]
    try:
        agy = json.loads(ktext(k, '.agents/hooks.json') or '{}')
    except ValueError:
        agy = {}
    ag = [(ev, json.dumps(h)) for g in agy.values() if isinstance(g, dict) for ev, hs in g.items() if isinstance(hs, list) for h in hs]
    return {'codex': cx, 'antigravity': ag}

def harness_matrix(k, bad=None):
    """[(feature, {claude, codex, antigravity: port | fallback | gap | MISSING, note})]: every Claude Code hook (settings.json),
    agent, workflow and skill, plus the Claude-only features of parity.json harness.features."""
    bad = bad or (lambda *x: None)
    reg = (json.loads(ktext(k, PARITY_JSON) or '{}').get('harness') or {})
    hk, feats, ports, rows = reg.get('hooks') or {}, reg.get('features') or {}, _port_hooks(k), []
    word = lambda v: (v.split(':', 1)[0], v.split(':', 1)[1].strip()) if re.match(r'^(gap|fallback|port):', v or '') else (None, v)
    try:
        st = json.loads(ktext(k, 'settings.json') or '{}').get('hooks') or {}
    except ValueError:
        st = {}
    for ev, groups in st.items():
        for h in [h for g in groups for h in g.get('hooks', [])]:
            av = h.get('args') or []
            i = next((j for j, x in enumerate(av) if re.search(r'\.(ps1|mjs|py)$', x)), None)
            feat = f"hook {ev} " + ' '.join([osp.basename(av[i])] + av[i + 1:] if i is not None else [h.get('command', '')])
            cell, want = {'claude': ('native', '')}, hk.get(feat[5:]) or {}
            for hn in HARNESS:
                w, frag = word(want.get(hn) or feat.split(' ', 2)[2])
                if w in ('gap', 'fallback'):
                    cell[hn] = (w, frag)
                else:
                    hit = re.compile(re.escape(frag) + r"""(?=\s*['"\\]|\s*$)""", re.M)   # the whole command: health is no prefix of health -Flow
                    cell[hn] = ('port', frag) if any(e == ev and hit.search(t) for e, t in ports[hn]) else ('MISSING', frag)
            rows.append((feat, cell))
    for kind, folder, files in (('agent', 'agents', ('.codex/agents/{}.toml', '.agents/agents/{}.md')),
                                ('workflow', 'workflows', ('.codex/workflows/{}.md', '.agents/kit-workflows/{}.py'))):
        for f in sorted(x for x in k.files if re.match(rf'{folder}/[\w-]+\.(md|js)$', x) and '.local.' not in x):
            n = osp.splitext(osp.basename(f))[0]
            cell = {'claude': ('native', '')}
            for hn, pat in zip(HARNESS, files):
                ok = bool(ktext(k, pat.format(n)))
                cell[hn] = (('fallback', 'by-hand procedure, gates in the doc') if kind == 'workflow' and hn == 'codex' else ('port', pat.format(n))) if ok else ('MISSING', pat.format(n))
            rows.append((f'{kind} {n}', cell))
    sk = '.claude/skills' in ktext(k, '.agents/skills.json')
    for s in sorted(k.skills):
        rows.append((f'skill {s}', {'claude': ('native', ''), 'codex': ('port', '.agents/skills link'), 'antigravity': ('port', '.agents/skills.json') if sk else ('MISSING', '.agents/skills.json')}))
    have = {f: c for f, c in rows}
    for feat, want in feats.items():   # a declared entry: a Claude-only feature, or a gap / fallback of an auto row
        if not feat.startswith('_'):
            cell = {hn: (word(want[hn])[0] or 'MISSING', word(want[hn])[1]) for hn in HARNESS if hn in want}
            if feat in have:
                have[feat].update(cell)
            else:
                rows.append((feat, {'claude': ('native', ''), **{hn: ('MISSING', 'no entry') for hn in HARNESS}, **cell}))
    for feat, cell in rows:
        for hn in HARNESS:
            if cell[hn][0] == 'MISSING':
                bad('PARITY', PARITY_JSON, f'{feat}: not in the {hn} port ({cell[hn][1] or "no entry"}): port it (kitbag.py port) or declare '
                    f'harness.{"hooks" if feat.startswith("hook ") else "features"} "{feat[5:] if feat.startswith("hook ") else feat}".{hn} = "gap: <why>" | "fallback: <how>"')
    return rows

def adapter_lint(k, man, bad):
    """PARITY: every adapter family and harness port (AGENTS.md "Parity")."""
    fams = man.get('adapters') or {}
    for fam, a in fams.items():
        if isinstance(a, dict):
            adapter_matrix(k, fam, a, bad)
            for key, why in (a.get('gaps') or {}).items():
                if re.match(r'no such feature', why) and not NOFEATURE.match(why):
                    bad('PARITY', PARITY_JSON, f'{fam}: gaps "{key}" says no such feature without its doc link: "no such feature: https://<the tool\'s doc> <why>"')
    for kind in sorted(adapter_kinds(k) - set(fams)):
        bad('PARITY', PARITY_JSON, f'family {kind}: the code registers it, {PARITY_JSON} adapters has no entry: add it (or "parity": why it is not walked)')
    harness_matrix(k, bad)

NOFEATURE = re.compile(r'^no such feature: https?://\S+')   # a gap the tool itself cannot close: kept, never in parity next

def _org_adapters(cfg, spec):
    """Adapter names kit.local.json picks for a family's config spec ('tracker.type', 'localEnv db.engine', 'repos[].deploys[] (kind)'):
    every string under the spec's last word whose path holds its other words."""
    words, out = re.findall(r'\w+', spec), set()
    def walk(o, path):
        for key, v in (o.items() if isinstance(o, dict) else enumerate(o) if isinstance(o, list) else ()):
            if key == words[-1] and isinstance(v, str) and all(w in path for w in words[:-1]):
                out.add(v.lower())
            walk(v, path + [key])
    walk(cfg, [])
    return out

def parity_next(k, man, cfg):
    """[(rank key, fam, name, verb, state, line)] of the cells to close next (owner 2026-11-24): adapters the org's config picks first,
    then the verbs kit code uses most (no use: last), then the cheapest (most sibling adapters native: a pattern to copy). Skipped: native / config
    cells, `none` adapters (no tool to call), gaps declared `no such feature: <link>` and `accepted` (by-design) fallbacks."""
    fams = {f: a for f, a in (man.get('adapters') or {}).items() if isinstance(a, dict)}
    org = {f: _org_adapters(cfg, a.get('config', '')) for f, a in fams.items()}
    if 'host' in org.get('ci', set()) or not org.get('ci'):   # ci.type host (the default) = the git host's vendor
        org['ci'] = (org.get('ci', set()) - {'host'}) | org.get('git-host', set())
    code = {f: re.sub(AD_COMMENT, '', t) for f, t in k.texts.items() if re.match(r'(skills|workflows)/', f) and f.endswith(AD_EXT + ('.js',)) and '.local.' not in f and '/kitbag' not in f}
    out = []
    for fam, a in fams.items():
        rows, gaps, ok = adapter_matrix(k, fam, a), _gap_keys(a.get('gaps')), _gap_keys(a.get('accepted'))
        near = [t for t in code.values() if re.search(r"""['"]%s['"]""" % re.escape(fam), t)]
        for n, row in rows.items():
            for v, s in row.items():
                why = gaps.get((n, v), ('', a.get('fallback', {}).get(v, '')))[1]
                if s not in ('fallback', 'gap') or n == 'none' or NOFEATURE.match(why) or (n, v) in ok:
                    continue
                if '.' in v:   # a dotted git-host verb is its own name: 'mr.parseRef'
                    uses = sum(len(re.findall(r"""['"]%s['"]""" % re.escape(v), t)) for t in code.values())
                else:   # a quoted verb or -Cap / -Verb argument in code that names the family; a compared value ($d.kind -eq 'create') is no call
                    forms = '|'.join(map(re.escape, {v, kebab(v)}))
                    uses = sum(len(re.findall(r"""['"](?:%s)['"]|-(?:Cap|Verb)\s+(?:%s)\b""" % (forms, forms), t))
                               - len(re.findall(r"""(?:-c?(?:eq|ne|in|notin)|[=!]=)\s*['"](?:%s)['"]""" % forms, t)) for t in near)
                sib = sorted(x for x, r in rows.items() if r.get(v) == 'native' and x != 'none')
                mine = n in org.get(fam, ())
                out.append(((not uses, not mine, -uses, -len(sib), fam, n, v), fam, n, v, s,   # a verb no code calls: last
                            f'{fam}/{n}/{v}: {s} -> native{" · org uses it" if mine else ""} · {uses} code use(s) · native in '
                            f'{len(sib)}/{len(rows)}{" (" + " ".join(sib[:4]) + ")" if sib else ""} · now: {why or "-"}'))
    return sorted(out)

def cmd_parity(a):
    """parity [--json] | parity next [--n 3]: the family x adapter x verb and harness x feature matrices (README "Adapters", "Install");
    next: the cells to close first (kit-admin.md "Parity")."""
    k = load(KIT_DIR)
    probs, man = [], manifest(KIT_DIR)
    if 'next' in a:
        flags, _ = parse_opts(a, ('--n',))
        cells = parity_next(k, man, local_config(KIT_DIR, 'kit.local.json'))
        for c in cells[:int(flags.get('--n') or 3)]:
            print(c[5])
        print(f'parity next: {len(cells)} open cell(s) (fallback or gap; `no such feature: <link>` gaps, accepted fallbacks and none adapters excluded)')
        return 0
    fams = {f: adapter_matrix(k, f, a) for f, a in (man.get('adapters') or {}).items() if isinstance(a, dict)}
    hm = harness_matrix(k)
    adapter_lint(k, man, lambda *x: probs.append(x))
    if '--json' in a:
        print(json.dumps({'adapters': fams, 'harness': [{'feature': f, **{h: {'state': s, 'note': n} for h, (s, n) in c.items()}} for f, c in hm],
                          'problems': [f'{c} {w}: {m}' for c, w, m in probs]}, indent=1))
        return 1 if probs else 0
    for fam, rows in fams.items():
        print(f'{fam}: {len(rows)} adapter(s)')
        for n, row in rows.items():
            odd = [f'{v}={s}' for v, s in row.items() if s != 'native']
            print(f'  {n:<14} {"all native" if not odd else " ".join(odd)}')
    print(f'harness: {"feature":<46} codex            antigravity')
    for feat, c in hm:
        if any(c[h][0] != 'port' for h in HARNESS):
            print(f'  {feat:<54} {c["codex"][0]:<16} {c["antigravity"][0]}')
    print(f'parity: {len(probs)} problem(s)' + ''.join(f'\n  {c} {w}: {m}' for c, w, m in probs))
    return 1 if probs else 0


def registry_lint(k, bad):
    """MANIFEST / SCHEMA / OLD-NAME / AGENT-TYPE / TODO-STUB / NON-CREW / DECISION-WORDING checks (part of lint)."""
    man = manifest(k.dir)
    if not man:
        bad('MANIFEST', PATHS_JSON, 'no _manifest section (the registry of agents, skills, workflows, Router and Events rows, caps)')
        return
    adapter_lint(k, man, bad)
    ag, sk, wf = man.get('agents') or {}, man.get('skills') or [], man.get('workflows') or {}
    local = lambda p: '.local.' in p or any(p == x or p.startswith(x + '/') for x in k.local_only)   # the org overlay registers nothing
    pub = lambda d: {n for n, p in d.items() if not local(p)}
    for what, have, want in (('agent', pub(k.agents), set(ag)), ('skill', {s for s in k.skills if not local(f'skills/{s}/SKILL.md')}, set(sk)), ('workflow', pub(k.workflows), set(wf))):
        for x in sorted(have - want):
            bad('MANIFEST', PATHS_JSON, f'{what} {x} exists but is not registered in _manifest')
        for x in sorted(want - have):
            bad('MANIFEST', PATHS_JSON, f'{what} {x} is registered but has no file')
    rows = [c[0].strip('*') for c in table_rows(k.router or '')]
    if rows != list(man.get('router') or []):
        bad('MANIFEST', 'AGENTS.md', f'Router rows {rows} differ from _manifest.router {man.get("router")}')
    ev = re.findall(r'^\|\s*(E\d+)\s*\|', section(k.texts.get('skills/bossy/SKILL.md', ''), 'Events') or '', re.M)
    if ev != list(man.get('events') or []):
        bad('MANIFEST', 'skills/bossy/SKILL.md', f'Events rows {ev} differ from _manifest.events {man.get("events")}')
    rowtext = {c[0].strip('*'): c for c in table_rows(k.router or '')}
    for w, meta in wf.items():
        r = rowtext.get(meta.get('router', ''))
        if not r or f'/{w}' not in r[2]:
            bad('MANIFEST', f'workflows/{w}.js', f'_manifest.workflows.{w}.router {meta.get("router")} is no Router row targeting /{w}')
    for a, p in k.agents.items():
        text = k.texts.get(p, '')
        fm = frontmatter(text)
        for e in schema_errors(fm, SCHEMAS['agent'], 'front matter'):
            bad('SCHEMA', p, e)
        ch = character_of(text)
        for e in schema_errors(ch, SCHEMAS['character'], 'Character'):
            bad('SCHEMA', p, e + ' (shape: **Character:** traits: .. · bias: .. · catchphrase: ".." · never: ..)')
        m = ag.get(a)
        if m is None:
            continue
        for e in schema_errors(m, SCHEMAS['manifest-agent'], f'_manifest.agents.{a}') + schema_errors(m.get('character') or {}, SCHEMAS['character'], f'_manifest.agents.{a}.character'):
            bad('SCHEMA', PATHS_JSON, e)
        if ch and m.get('character') and ch != m['character']:
            bad('MANIFEST', p, 'the Character block differs from _manifest (kitbag.py port writes it from the manifest)')
        want = {role_tools(a, k.dir), role_tools(a, k.dir, tools_live(k.dir))}
        if fm.get('tools') not in want:
            bad('MANIFEST', p, f'tools "{fm.get("tools")}" differ from _manifest.agents.{a}.tools expanded "{role_tools(a, k.dir)}" '
                '(a crew role carries an allowlist; kitbag.py port writes it)')
        allow = set((role_tools(a, k.dir, True) or '').split(', '))
        for n, line in enumerate(text.splitlines(), 1):
            for t in tools_named(line):
                if t not in allow and not any(t.startswith(g + '__') for g in allow):
                    bad('TOOLS-SCOPE', f'{p}:{n}', f'its steps use {t}, its tools ({m.get("tools")}) omit it: add it to _manifest.agents.{a}.tools or reword the step')
        if m.get('skill') and f'skills/{m["skill"]}/SKILL.md' not in text:
            bad('MANIFEST', p, f'_manifest says it loads {m["skill"]}, its body never names skills/{m["skill"]}/SKILL.md')
    for s in k.skills:
        p = f'skills/{s}/SKILL.md'
        for e in schema_errors(frontmatter(k.texts.get(p, '')), SCHEMAS['skill'], 'front matter'):
            bad('SCHEMA', p, e)
    crew = set(ag)
    for w, p in k.workflows.items():
        src = k.texts.get(p, '')
        for m in re.finditer(r'\bawait\s+agent\(|=>\s*agent\(', src):
            end = src.find('})', src.find('label', m.start()))
            reg = src[m.start():end if end > 0 else m.start() + 4000]
            at = re.search(r"agentType:\s*'([\w-]+)'", reg)
            if not at or at.group(1) not in crew:
                ln = src.count('\n', 0, m.start()) + 1
                bad('AGENT-TYPE', f'{p}:{ln}', f'agent() without a crew agentType ({at.group(1) if at else "none: a general-purpose agent"}); use one of {sorted(crew)}')
    olds = man.get('renamed') or {}
    live = {osp.basename(x) for x in k.files}   # a live joined name (guard-<old>.ps1) is no old one
    # FILE-RENAMES: a kebab-case .ps1 / .mjs's snake_case form (dotted, regex-escaped, or adapters/<stem>) is its old name, no manifest row each
    snake = {b.replace('-', '_'): b for b in live if '-' in b and b.endswith(('.ps1', '.mjs')) and b.replace('-', '_') not in live}
    def snake_rx(o):
        st, ext = (re.escape(x) for x in osp.splitext(o))
        return re.compile(rf'(?<![\w.-]){st}(?:\\?{ext}(?![\w-])|(?<=adapters/{st})(?![\w.-]))')
    pats = [(o, old_name_rx(o)) for o in olds] + [(o, snake_rx(o)) for o in snake]
    olds = {**olds, **snake}
    for f in k.files:
        if '.local.' in f or any(f == x or f.startswith(x + '/') for x in k.local_only):
            continue
        t = k.texts.get(f) or ''
        if f == PATHS_JSON:
            t = re.sub(r'"(renamed|moved)":\s*\{[^}]*\}', '', t)   # the migration notes themselves
        for o, rx in pats:
            m = next((x for x in rx.finditer(t) if x.group(0) not in live), None)
            if m:
                bad('OLD-NAME', f'{f}:{t.count(chr(10), 0, m.start()) + 1}', f'old name "{o}" (now "{olds[o]}"): no aliases, update the reference')
        if TODO in t and f not in ('skills/bossy/kitbag.py', 'skills/bossy/kitbag_scaffold.py'):   # the templates live here
            bad('TODO-STUB', f'{f}:{t.count(chr(10), 0, t.index(TODO)) + 1}', f'{TODO} stub left: fill it in')
        ln = lambda m: f'{f}:{t.count(chr(10), 0, m.start()) + 1}'
        for m in re.finditer(r'business[- ]logic change', t, re.I):   # the rule is what a user sees, not where the code sits
            if 'decide ask' in t[m.start():m.start() + 300] and 'user-visible' not in t[max(0, m.start() - 150):m.start() + 300]:
                bad('DECISION-WORDING', ln(m), 'a decision pause is a user-visible behaviour change (AGENTS.md "Decision pauses"), not a "business-logic change"')
        m = re.search(r'(?<!no )\b(?:Explore|Plan|general-purpose) agents?\b', t) if f.startswith(('agents/', 'workflows/')) or f.endswith('SKILL.md') else None
        if m:
            bad('NON-CREW', ln(m), f'"{m.group(0)}": only crew agents ({", ".join(sorted(crew))}) are spawned')

# Get-KitParam / Add-KitParamObs / kitParam keys registered, no other site default; code literals (PS AST, py ast,
# js regex, TODO-PARAM) ratchet down from _literals
PARAMS_JSON = 'skills/bossy/params.registry.json'
PARAM_HOWS = {'quantile', 'peak', 'ewma', 'aimd', 'config'}
PARAM_SITE = re.compile(r"(Get-KitParam|&\s*\$gp|kitParam\(|kit_param\(|Add-KitParamObs)\s*'([\w.]+)'(?:,?\s+(-?\d+(?:\.\d+)?)\b(?![.\w]))?")
PS_LITERALS = r'''$ErrorActionPreference = 'SilentlyContinue'; $L = 'System.Management.Automation.Language'
$num = { param($a) $v = $null; if ($a -is "$L.ConstantExpressionAst" -and $a.Value -is [ValueType] -and $a.Value -isnot [bool]) { $v = [double]$a.Value } elseif ($a -is "$L.UnaryExpressionAst" -and $a.Child -is "$L.ConstantExpressionAst" -and $a.Child.Value -is [ValueType]) { $v = [double]$a.Child.Value }; $null -ne $v -and [math]::Abs($v) -gt 1 }
$pred = { param($n)
  if ($n -is "$L.CommandAst") { $el = @($n.CommandElements)
    if ($n.GetCommandName() -in 'Get-KitSetting', 'Get-KitValue', 'Opt', 'Start-Sleep') { return [bool]@($el | Select-Object -Skip 1 | Where-Object { & $num $_ }).Count }
    for ($i = 1; $i -lt $el.Count - 1; $i++) { if ($el[$i] -is "$L.CommandParameterAst" -and $el[$i].ParameterName -match '(?i)^(TimeoutSec|Seconds|Minutes|Milliseconds|\w+TimeoutSeconds)$' -and (& $num $el[$i + 1])) { return $true } }
    return $false }
  if ($n -is "$L.MemberExpressionAst" -and $null -ne $n.Arguments -and "$($n.Member)" -match '^(Add|From)(Milliseconds|Seconds|Minutes|Hours|Days)$|^(WaitOne|WaitForExit)$') { return [bool]@($n.Arguments | Where-Object { & $num $_ }).Count }
  if ($n -is "$L.BinaryExpressionAst" -and "$($n.Operator)" -match '^I?(gt|ge|lt|le)$') { foreach ($s in @(@($n.Left, $n.Right), @($n.Right, $n.Left))) { if ($s[0] -is "$L.MemberExpressionAst" -and "$($s[0].Member)" -match '^Total(Milliseconds|Seconds|Minutes|Hours|Days)$' -and (& $num $s[1])) { return $true } } }
  $false }
$out = @(foreach ($f in $env:KIT_LIT_FILES -split '\|') { $tk = $null; $er = $null; $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tk, [ref]$er)
  foreach ($h in @($ast.FindAll($pred, $true))) { @{ file = $f; line = $h.Extent.StartLineNumber } } })
ConvertTo-Json -InputObject $out -Compress'''

def param_spec(s):
    """A registry entry as a dict: the shorthand '<how> k=v ...' or an object (kind config / learn)."""
    if isinstance(s, dict):
        return dict(s, how='config' if s.get('kind') not in (None, 'learn') else s.get('how', 'quantile'))
    w = str(s).split()
    return dict([('how', w[0] if w else '')] + [tuple((x.split('=', 1) + [''])[:2]) for x in w[1:]])

def kit_param(key):
    """A config param: KIT_PARAM_<KEY>, a kit.local.json pin at <key>, else the registry default (no param-state pins or learning)."""
    pin = os.environ.get('KIT_PARAM_' + re.sub(r'\W', '_', key).upper()) or next((v for v in config_values(local_config(KIT_DIR, 'kit.local.json'), key)
                                                                                    if isinstance(v, (int, float, str)) and v != ''), None)
    return float(pin if pin is not None else param_spec(((load_json(osp.join(KIT_DIR, PARAMS_JSON))[0] or {}).get('params') or {}).get(key, ''))['default'])

def params_lint(k, bad):
    """PARAM-REG (registry shape), PARAM-UNREG (a key read or observed in code but not registered), PARAM-DEFAULT (a site literal
    other than the registry default)."""
    reg, err = load_json(osp.join(k.dir, PARAMS_JSON))
    if err:
        bad('PARAM-REG', PARAMS_JSON, err)
        return
    params = reg.get('params') or {}
    for key, s in params.items():
        sp = param_spec(s)
        if sp['how'] not in PARAM_HOWS:
            bad('PARAM-REG', PARAMS_JSON, f'{key}: how "{sp["how"]}" (one of {", ".join(sorted(PARAM_HOWS))})')
        elif sp['how'] == 'config' and not re.match(r'-?\d+(\.\d+)?$', str(sp.get('default', ''))):
            bad('PARAM-REG', PARAMS_JSON, f'{key}: a config key needs a number default=')
    for f in k.files:
        t = (k.texts.get(f) or '') if f.endswith(('.ps1', '.py', '.mjs', '.js')) and not f.startswith('tests/') else ''
        for m in PARAM_SITE.finditer(t):
            key, lit, where = m.group(2), m.group(3), f'{f}:{t.count(chr(10), 0, m.start()) + 1}'
            if key not in params:
                bad('PARAM-UNREG', where, f'{key} is read here but not in {PARAMS_JSON}: register it (how, default, unit)')
            elif lit is not None and m.group(1) != 'Add-KitParamObs' and 'default' in param_spec(params[key]) and float(lit) != float(param_spec(params[key])['default']):
                bad('PARAM-DEFAULT', where, f'{key}: {lit} here, default={param_spec(params[key])["default"]} in the registry: drop the literal')

def literal_sites(k):
    """{file: sorted line numbers} of tunable literals in the core's code files (registered keys read through Get-KitParam are none)."""
    files = [f for f in k.files if f.endswith(('.ps1', '.py', '.mjs', '.js')) and not f.startswith(('tests/', '.githooks/'))]
    hits = defaultdict(set)
    for f in files:
        t = k.texts.get(f) or ''
        for i, l in enumerate(t.split('\n'), 1):
            if 'TODO-PARAM' in l and re.search(r'\d', l):   # marked literal (no number: a mere mention)
                hits[f].add(i)
        if f.endswith('.py'):
            try:
                tree = ast.parse(t)
            except SyntaxError:
                continue
            num = lambda n: isinstance(n, ast.Constant) and isinstance(n.value, (int, float)) and not isinstance(n.value, bool) and abs(n.value) > 1
            for n in ast.walk(tree):
                if isinstance(n, ast.Call):
                    fn = n.func.attr if isinstance(n.func, ast.Attribute) else getattr(n.func, 'id', '')
                    if any(num(kw.value) and re.match(r'(timeout|stale|seconds|minutes|hours|days)$', kw.arg or '') for kw in n.keywords) or (fn in ('sleep', 'timedelta') and any(map(num, n.args))):
                        hits[f].add(n.lineno)
        elif f.endswith(('.js', '.mjs')):
            code = js_code(t)
            for m in re.finditer(r'\b(?:timeout|\w+(?:Ms|Sec|Seconds|Minutes))\s*[:=]\s*\d{2,}|setTimeout\([^;]*?,\s*\d{2,}\s*\)', code):
                hits[f].add(code.count('\n', 0, m.start()) + 1)
    ps = [osp.join(k.dir, f) for f in files if f.endswith('.ps1')]
    pw = shutil.which('pwsh')
    if ps and pw:
        import base64
        r = subprocess.run([pw, '-NoProfile', '-NonInteractive', '-EncodedCommand', base64.b64encode(PS_LITERALS.encode('utf-16-le')).decode()],
          capture_output=True, text=True, encoding='utf-8', timeout=120, env=dict(os.environ, KIT_LIT_FILES='|'.join(ps)))
        try:
            for h in json.loads(r.stdout or '[]'):
                hits[osp.relpath(h['file'], k.dir).replace('\\', '/')].add(int(h['line']))
        except (ValueError, KeyError, TypeError):
            pass
    return {f: sorted(v) for f, v in hits.items() if v}

def literal_warns(k, ratchet=False):
    """WARN PARAM-LITERAL lines: files over their _literals baseline (none: 0); --ratchet writes the lower counts (no _literals key
    yet: records all; {} = zero everywhere, so a file down to 0 literals stays held)."""
    p = osp.join(k.dir, PARAMS_JSON)
    reg, err = load_json(p)
    if err:
        return []
    sites, base = literal_sites(k), reg.get('_literals')
    if ratchet:
        new = {f: len(v) for f, v in sorted(sites.items())} if base is None else {f: min(n, len(sites.get(f, []))) for f, n in base.items() if f in sites}
        if new != base:
            t, lit = read(p), '"_literals": ' + json.dumps(new, separators=(', ', ': '))
            t = re.sub(r'"_literals":\s*\{[^}]*\}', lit, t) if base is not None else re.sub(r'\s*\}\s*$', lambda m: f',\n {lit}\n}}\n', t)
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(t)
            print(f'kitbag lint --ratchet: {PARAMS_JSON} _literals updated ({sum(new.values())} literal(s) in {len(new)} file(s))')
        base = new
    base = base or {}
    return [('PARAM-LITERAL', f, f'{len(v)} tunable literal(s), baseline {base.get(f, 0)}: lines {", ".join(map(str, v[:8]))}{" ..." if len(v) > 8 else ""} '
             f'-> a {PARAMS_JSON} key + Get-KitParam') for f, v in sorted(sites.items()) if len(v) > base.get(f, 0)]

# ---- arch lint: ARCH-* (core stays neutral: defaults, enums, vendor calls, platform calls, lessons, dead keys); vocab in VOCAB_JSON
VOCAB_JSON = 'skills/bossy/lint-vocab.json'
ARCH_COUNTED = {'ARCH-DEAD-KEY', 'ARCH-DEFAULT', 'ARCH-VENDOR-API', 'ARCH-PLATFORM', 'ARCH-LESSON', 'LESSONS-ORG', 'ARCH-SBLOG', 'ARCH-TEMP'}   # counted; ARCH-ENUM stays WARN (vendor dispatch tables name vendors)
CODE_EXT = ('.ps1', '.py', '.js', '.mjs')

def word_rx(words):
    """Whole-word, case-insensitive alternation; a word ending in punctuation (CU-, [Unit Test]) needs no trailing boundary."""
    alt = '|'.join(re.escape(w) + (r'(?![\w-])' if re.match(r'.*\w$', w) else '') for w in sorted(words, key=len, reverse=True))
    return re.compile(r'(?<![\w-])(?:' + alt + ')', re.I) if words else None

def code_line(line, cm):
    """The line without its trailing comment (a comment marker inside quotes is data)."""
    q = None
    for i, ch in enumerate(line):
        if q:
            q = None if ch == q else q
        elif ch in '\'"`':
            q = ch
        elif line.startswith(cm, i) and (cm != '#' or i == 0 or line[i - 1] in ' \t;{(') and not line.startswith('#requires', i):
            return line[:i]
    return line

def arch_lines(f, text):
    """[(line no, code without comment, raw line)] minus lines with `arch-ok: <why>` and lines inside legacy-defaults:start / :end."""
    cm = {'.ps1': '#', '.py': '#'}.get(osp.splitext(f)[1], '//')
    if f.endswith('.ps1'):
        text = re.sub(r'<#.*?#>', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    elif f.endswith('.py'):   # docstrings (a string alone as a statement) are prose, not calls
        import tokenize
        ls, prev = text.split('\n'), tokenize.NEWLINE
        try:
            for t in tokenize.generate_tokens(io.StringIO(text).readline):
                if t.type == tokenize.STRING and prev in (tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.NL):
                    for j in range(t.start[0] - 1, t.end[0]):
                        ls[j] = ''
                if t.type not in (tokenize.COMMENT, tokenize.NL):
                    prev = t.type
        except (tokenize.TokenError, SyntaxError, IndentationError):
            pass
        text = '\n'.join(ls)
    out, skip = [], False
    for n, raw in enumerate(text.split('\n'), 1):
        if 'legacy-defaults:start' in raw:
            skip = True
        elif 'legacy-defaults:end' in raw:
            skip = False
        elif not skip and not re.search(r'arch-ok:\s*\S', raw):
            out.append((n, code_line(raw, cm) if f.endswith(CODE_EXT) else raw, raw))
    return out

def default_expr(s):
    """The default expression at the start of s: up to an unbalanced ) ] }, or ; | at depth 0 (quotes kept)."""
    d, q = 0, None
    for i, ch in enumerate(s):
        if q:
            q = None if ch == q else q
        elif ch in '\'"':
            q = ch
        elif ch in '([{':
            d += 1
        elif ch in ')]}':
            d -= 1
            if d < 0:
                return s[:i]
        elif ch in ';|' and d == 0 and not s.startswith('||', i):
            return s[:i]
    return s

DEFAULT_RX = {'.ps1': (re.compile(r"Get-KitSetting\s+['\"]([\w.]+)['\"]\s+"), re.compile(r'')),   # (config read, default lead-in)
  '.py': (re.compile(r"""\.get\(\s*['"]([\w.]+)['"]\s*"""), re.compile(r',\s*|\)\s*or\s+')),   # lines that name a *CFG only
  '.js': (re.compile(r"\b(?:cfg|conf|config|kitConf|CFG)\w*(?:\?\.|\.)([\w?.]+)\s*"), re.compile(r'(?:\|\||\?\?)\s*'))}

def arch_lint(k):
    """ARCH-* problems [(code, where, msg)]. Exempt: tests/, ports, *.local.*, vendor-named files (basename holds a vendor / stack
    word), `arch-ok: <why>` lines, legacy-defaults blocks; ENUM and VENDOR-API also adapters/ (DEFAULT, PLATFORM: core moved there too)."""
    if getattr(k, 'arch', None) is not None:
        return k.arch
    voc, err = load_json(osp.join(k.dir, VOCAB_JSON))
    probs = k.arch = []
    if err:
        probs.append(('ARCH-VOCAB', VOCAB_JSON, f'{err}: the ARCH-* rules need it'))
        return probs
    fams = voc.get('families') or {}
    rx_of = {n: word_rx(x.get('words') or []) for n, x in fams.items()}
    vendor_words = [w for n in ('vendors', 'stacks') for w in (fams.get(n) or {}).get('words', [])]
    named = lambda f: any(re.sub(r'[\s-]', '', w.lower()) in re.sub(r'[\s_-]', '', osp.basename(f).lower()) for w in vendor_words)
    base = [f for f in k.files if not f.startswith(('tests/',) + GENERATED) and not is_overlay(k, f) and f != VOCAB_JSON]   # org-only files (localOnly, *.local.*) are the org's own
    code = [f for f in base if f.endswith(CODE_EXT)]
    core = [f for f in code if '/adapters/' not in f and not named(f)]
    lines = {f: arch_lines(f, k.texts.get(f) or read(osp.join(k.dir, f))) for f in code}
    selftest = re.compile(r"^\s*@\(\s*'")   # guard self-test rows hold command text as data
    # ARCH-DEFAULT: a config key's default literal names a vendor, stack, status, env or org marker
    drx = [rx_of[n] for n, x in fams.items() if x.get('default') and rx_of[n]]
    for f in [f for f in code if not named(f)]:
        rx, lead = DEFAULT_RX.get('.js' if f.endswith('.mjs') else osp.splitext(f)[1])
        for n, c, _ in lines[f]:
            for m in (rx.finditer(c) if not f.endswith('.py') or re.search(r'\w*CFG\b', c) else ()):
                if m.group(1).isupper() or not (t := lead.match(c, m.end())):   # upper case: an env var, not a config key
                    continue
                expr = default_expr(c[t.end():])
                lits = [a or b for a, b in re.findall(r"'([^']*)'|\"([^\"]*)\"", expr) if not re.match(r'^<[^>]*>$', a or b)]
                hit = sorted({h.group(0) for lit in lits for r in drx for h in r.finditer(lit)}, key=str.lower)
                if hit:
                    probs.append(('ARCH-DEFAULT', f'{f}:{n}', f'{m.group(1)}: default names {", ".join(hit)}: neutral code default '
                                  '(off / none / empty), the value in kit.local.json (kitbag.py migrate legacy row)'))
    # ARCH-ENUM: 3+ values of one vocab family in one file, no `registry:` comment on or above the line
    for f in core:
        raw = (k.texts.get(f) or '').split('\n')
        for fam, x in fams.items():
            if not x.get('enum'):
                continue
            words = {w.lower(): w for w in x.get('words') or []}
            seen = {}
            for n, c, _ in lines[f]:
                if 'registry:' in raw[n - 1] or (n > 1 and 'registry:' in raw[n - 2]):
                    continue
                for a, b in re.findall(r"'([^'\n]{1,30})'|\"([^\"\n]{1,30})\"", c):
                    if (a or b).lower() in words:
                        seen.setdefault(words[(a or b).lower()], n)
            if len(seen) >= 3:
                first = min(seen.values())
                probs.append(('ARCH-ENUM', f'{f}:{first}', f'{len(seen)} {fam} values ({", ".join(f"{w}:{n}" for w, n in sorted(seen.items(), key=lambda t: t[1]))}): '
                              'one registry (adapter kind / config key), or a `registry: <where>` comment on the line'))
    # ARCH-VENDOR-API: vendor CLI / REST calls belong in adapters/ or vendor-named files
    vrx = [re.compile(p, re.I) for p in voc.get('vendorApi') or []]
    for f in core:
        for n, c, _ in lines[f]:
            if not selftest.match(c) and (h := next((m for r in vrx if (m := r.search(c))), None)):
                call = h.group(0).strip(' \t;|({=&\'"')[:40]
                probs.append(('ARCH-VENDOR-API', f'{f}:{n}', f'vendor call "{call}": move it to an adapter verb '
                              '(skills/<skill>/adapters/<vendor>.ps1|py) and call the verb'))
    # ARCH-PLATFORM: a Windows-only call needs a platform check on its line, an enclosing block header or an earlier early-exit
    plat = voc.get('platform') or {}
    prx, grd = [re.compile(p, re.I) for p in plat.get('calls') or []], re.compile(plat.get('guard') or r'(?!)')
    for f in [f for f in code if not re.search(r'(?i)windows|win32|schtasks', osp.basename(f))]:   # arch-ok: platform-named files
        ls = lines[f]
        for i, (n, c, _) in enumerate(ls):
            if selftest.match(c) or not (h := next((m for r in prx if (m := r.search(c))), None)) or grd.search(c):
                continue
            if not arch_guarded(f, ls, i, grd):
                probs.append(('ARCH-PLATFORM', f'{f}:{n}', f'Windows-only "{h.group(0).strip()[:30]}" without a platform check: '
                              'wrap it in if ($KitIsWindows) / os.name == "nt" with an other-OS branch'))
    # ARCH-TEMP: kit scratch lives in <runtime>/tmp (Get-KitTemp / New-KitTempFile, kitPath('tmp'); kitbag sets tempfile.tempdir)
    trx, pyt = [re.compile(p) for p in voc.get('osTemp') or []], re.compile(r'\btempfile\.\w+|\bgettempdir\(|\bfrom\s+tempfile\s+import\b')
    for f in code:
        kb = osp.basename(f).startswith('kitbag') or re.search(r'^\s*(?:from kitbag import|import kitbag)', k.texts.get(f) or read(osp.join(k.dir, f)), re.M)
        for n, c, _ in lines[f]:
            h = None if selftest.match(c) else next((m for r in trx if (m := r.search(c))), None) or (pyt.search(c) if f.endswith('.py') and not kb else None)
            if h:
                probs.append(('ARCH-TEMP', f'{f}:{n}', f'OS temp "{h.group(0)[:30]}": Get-KitTemp / New-KitTempFile (lib.ps1), kitPath(\'tmp\') (node), '
                              'import kitbag (python tempfile then lands in <runtime>/tmp); an external tool\'s own temp: `arch-ok: <why>` on the line'))
    # ARCH-LESSON: tracked rules name a vendor or stack -> a rules/*.local.md; LESSONS-ORG: LESSONS.md holds kit lessons only:
    # a vendor / stack / runner word, an org-shaped name (lessonOrg) or a kit.local.json orgTerm -> LESSONS.local.md
    lrx = word_rx([w for x in fams.values() if x.get('lesson') for w in x.get('words') or []])
    for f in [f for f in base if re.match(r'rules/[^/]+\.md$', f)]:
        for n, c, _ in arch_lines(f, k.texts.get(f) or ''):
            if lrx and (ws := sorted({m.group(0).lower() for m in lrx.finditer(c)})):
                probs.append(('ARCH-LESSON', f'{f}:{n}', f'names {", ".join(ws)}: a vendor / stack lesson goes in a rules/*.local.md'))
    cfg, _ = load_json(osp.join(k.dir, 'skills', 'crafty', 'kit.local.json')) if osp.isfile(osp.join(k.dir, 'skills', 'crafty', 'kit.local.json')) else ({}, None)
    orx = [lrx] + [re.compile(p, re.I) for p in voc.get('lessonOrg') or []] + org_term_rx((cfg or {}).get('orgTerms') or [] if isinstance(cfg, dict) else [])
    for n, c, _ in (arch_lines('LESSONS.md', k.texts.get('LESSONS.md') or '') if 'LESSONS.md' in base else []):
        if hits := [r for r in orx if r and r.search(c)]:
            probs.append(('LESSONS-ORG', f'LESSONS.md:{n}', f'{len(hits)} org / vendor / stack pattern(s): a kit lesson only; this one goes in LESSONS.local.md '
                          '(bossy.ps1 learn routes it there; never quoted here: an org term may be the hit)'))
    # ARCH-SBLOG: pwsh 7 writes a script's whole text to the event log (4104) on every load when it holds a flagged word (any
    # case, comments too) or a $o.$name member; the kit's .ps1 load on every tool call (guard hook)
    sb = voc.get('sbLog') or {}
    ex = tuple(sb.get('exempt') or ['\0'])
    sbf = [f for f in code if f.endswith('.ps1') and f.startswith('skills/') and not f.startswith(ex)]
    cdx = re.compile(sb['cdxml'], re.I) if sb.get('cdxml') else None
    pys = [(f, n, s) for f in code if f.endswith('.py') and f.startswith('skills/') and not f.startswith(ex) for n, s in sblog_inline(k.texts.get(f) or read(osp.join(k.dir, f)))]
    for f, n0, t in [(f, 1, k.texts.get(f) or read(osp.join(k.dir, f))) for f in sbf] + pys:
        where = 'this whole script' if n0 == 1 and f.endswith('.ps1') else 'this inline -Command text'
        for w in sb.get('words') or []:
            if (i := t.lower().find(w.lower())) >= 0:
                probs.append(('ARCH-SBLOG', f'{f}:{n0 + t.count(chr(10), 0, i)}', f'"{w}": pwsh logs {where} on every load: '
                              'a non-flagged equivalent, or the call in skills/crafty/flagged.ps1'))
        if cdx and (m := cdx.search(t)):
            probs.append(('ARCH-SBLOG', f'{f}:{n0 + t.count(chr(10), 0, m.start())}', f'"{m.group(0)}": a cdxml module cmdlet; pwsh logs its generated module '
                          'code in every process that loads it: netstat / .NET sockets, or run it only off the hot path'))
    for f, n, src in sblog_members(k, sbf):
        probs.append(('ARCH-SBLOG', f'{f}:{n}', f'{src}: a dynamic member makes pwsh log this whole script on every load: Get-KitMember / Set-KitMember'))
    # ARCH-DEAD-KEY: a key kit.example.json documents (sample or _doc) that no script reads
    probs += dead_keys(k)
    return probs

PS_MEMBERS = r'''$out = @(foreach ($f in $env:KIT_SB_FILES -split '\|') { $tk = $null; $er = $null; $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tk, [ref]$er)
  foreach ($h in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))) {
    @{ file = $f; line = $h.Extent.StartLineNumber; src = ($h.Extent.Text -split "`n")[0].Substring(0, [Math]::Min(40, ($h.Extent.Text -split "`n")[0].Length)) } } })
ConvertTo-Json -InputObject $out -Compress'''

def sblog_inline(t):
    """[(line, text)] of pwsh script text a .py hands to -Command / -EncodedCommand: a literal or a module constant it names."""
    try:
        tree = ast.parse(t)
    except SyntaxError:
        return []
    consts = {n.targets[0].id: n.value for n in tree.body if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)
              and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)}
    out = {}
    for n in ast.walk(tree):
        for a, b in zip(getattr(n, 'elts', []) if isinstance(n, (ast.List, ast.Tuple)) else [], (getattr(n, 'elts', None) or [None])[1:]):
            if isinstance(a, ast.Constant) and str(a.value).lower() in {'-command', '-encodedcommand'}:
                codec = {id(y) for z in ast.walk(b) if isinstance(z, ast.Call) and getattr(z.func, 'attr', '') in ('encode', 'decode') for y in z.args}   # 'utf-16-le'
                for x in ast.walk(b):
                    c = consts.get(x.id) if isinstance(x, ast.Name) else x if isinstance(x, ast.Constant) and isinstance(x.value, str) and id(x) not in codec else None
                    if c is not None:
                        out[(c.lineno, c.col_offset)] = c.value   # several pieces can share a line (f-string parts, 'a' + 'b')
    return [(p[0], v) for p, v in sorted(out.items())]

def sblog_members(k, files):
    """[(file, line, text)] of member accesses with a computed name ($o.$k, $o.($x), $o."$k", [t]::$m): pwsh's own parser (none without pwsh)."""
    pw = shutil.which('pwsh')
    if not files or not pw:
        return []
    import base64
    r = subprocess.run([pw, '-NoProfile', '-NonInteractive', '-EncodedCommand', base64.b64encode(PS_MEMBERS.encode('utf-16-le')).decode()], capture_output=True,
                       text=True, encoding='utf-8', timeout=120, env=dict(os.environ, KIT_SB_FILES='|'.join(osp.join(k.dir, f) for f in files)))
    try:
        return [(osp.relpath(h['file'], k.dir).replace('\\', '/'), int(h['line']), h['src']) for h in json.loads(r.stdout or '[]')]
    except (ValueError, KeyError, TypeError):
        return []

def arch_guarded(f, ls, i, grd):
    """A platform check on an enclosing block header (braces; py: indentation) or an early exit before line i, within its function."""
    py = f.endswith('.py')
    indent = lambda s: len(s) - len(s.lstrip())
    tot, top, cur = 0, 0, indent(ls[i][1])   # braces: walking up, a line that lifts the open-brace total to a new high encloses line i
    for n, c, _ in reversed(ls[max(0, i - 80):i]):
        if not c.strip():
            continue
        plain = re.sub(r"'[^']*'|\"[^\"]*\"", '', c)
        tot += plain.count('{') - plain.count('}')
        opener = (indent(c) < cur) if py else tot > top
        if opener:
            cur, top = indent(c), max(top, tot)
        if grd.search(c) and (opener or re.search(r'\b(return|exit|continue|throw|raise)\b', c)):
            return True
        if re.match(r'\s*(function\s|def\s|class\s)', c) and (opener or not py):
            return False
    return False

def dead_keys(k):
    """ARCH-DEAD-KEY: dotted keys of the kit.example.json sample and _doc names; read = the full key or its last part quoted or as
    a member (.x) in a code file or .githooks/ (tests and the example itself are no readers)."""
    ex, err = load_json(osp.join(k.dir, PATHS_JSON))
    if err or not isinstance(ex, dict):
        return []
    keys = dict.fromkeys(key_paths(ex))
    for d in (ex.get('_doc') or {}):
        for x in re.split(r'[,\s]+', d):
            if re.match(r'^[A-Za-z][\w.]*$', x):
                keys.setdefault(x)
    readers = '\n'.join(k.texts.get(f) or read(osp.join(k.dir, f)) for f in k.files
                        if (f.endswith(CODE_EXT) or f.startswith('.githooks/')) and not f.startswith(('tests/',) + GENERATED))
    probs = []
    for key in keys:
        leaf = key.rsplit('.', 1)[-1]
        if not re.match(r'^[A-Za-z_]\w*$', leaf):
            continue   # a data name in a map (model id, host), not a config key
        if not re.search(r"""['"`](?:""" + re.escape(key) + '|' + re.escape(leaf) + r""")['"`.]|[.$]""" + re.escape(leaf) + r'\b', readers):
            probs.append(('ARCH-DEAD-KEY', PATHS_JSON, f'"{key}" is documented but no script reads it: drop it (and its README row) or read it'))
    return probs

def _sub_file(kit, rel, fn):   # kitbag_scaffold.py and kitbag_admin.py edit kit files with it, keeping line endings
    p = osp.join(kit, rel)
    with open(p, encoding='utf-8', newline='') as fh:
        raw = fh.read()
    eol = '\r\n' if '\r\n' in raw else '\n'
    t = fn(raw.replace('\r\n', '\n'))
    with open(p, 'w', encoding='utf-8', newline='') as fh:
        fh.write(t.replace('\n', eol))

# ---- prose: check a text against templates.md "Writing standards"
REQ_RX = {'link': r'https?://\S+|\b[\w.-]+[!#]\d+\b|\b(?:MR|PR)\s*!?#?\d+',
  'id': r'\b[A-Z][A-Z0-9]*-\d+\b|#\d+\b|\b[A-Z]\d+\b|\b[0-9a-z]{7,}\b|\b[A-Z]{2,}-[A-Za-z0-9]+',   # any tracker tag + id
  'path': r'[\w./-]+\.(?:md|ps1|py|mjs|js|ts|json|java|xml|ya?ml|cs|go|rs|kt|sql|html?)\b(?::\d+)?|<kit>/\S+',
  'cmd': r'`[^`]*\b(?:pwsh|python|node|git|crafty\.ps1|bossy\.ps1|pokey\.ps1|phoney\.ps1|envy\.ps1|kitbag\.py|devtools\.py|npm|&)\b[^`]*`',
  'evidence': r'\.(?:png|jpe?g|json|log|txt|html?)\b|https?://\S+',
  'expected': r'(?i)\bexpected\b', 'options': r'(?m)^\s*[-*|]?\s*(?:Option\s+)?A(?:[:)]|\s+(?:\||\())', 'recommended': r'(?i)\brecommended\b',
  'verdict': r'\b(?:PASS|FAIL|BLOCKED|PASS_WITH_NOTE|NOT_TESTED)\b', 'today': r'(?m)^[^\w\n]*Today:[^\w\n]*\w',   # owner 2026-11-25: understand first
  'conv': r'^(?:feat|fix|refactor|perf|docs|test|chore|build|ci|style|revert)(?:\([^)]+\))?!?: \S'}

def writing_standards(kit):
    """templates.md "Writing standards" -> ({kind: {format, limits, required}}, [banned regex])."""
    t = read(osp.join(kit, 'skills', 'crafty', 'templates.md'))
    sec = section(t, 'Writing standards') or ''
    kinds = {}
    for row in sec.split('\n'):
        c = [x.strip() for x in row.strip().strip('|').split('|')]
        if len(c) == 5 and c[0] not in ('Kind', '---') and not c[0].startswith('-'):
            kinds[c[0]] = {'purpose': c[1], 'format': c[2], 'limits': c[3], 'required': [] if c[4] in ('—', '-', '') else c[4].split()}
    m = re.search(r'Banned everywhere:(.*?)(?:\n\n|\n\|)', sec, re.S)
    banned = [r'\b' + re.escape(b) + r'\b' for b in re.findall(r'"([^"]+)"', m.group(1))] if m else []
    if m and 'greetings' in m.group(1):
        banned += [r'^\s*(?:hi|hello|hey|dear)\b', r'\bthank(?:s| you)\b']
    return kinds, banned

def prose_parts(text):
    """(prose lines without fenced code, sections {name: [lines]}) of a Markdown text."""
    lines, fence = [], False
    text = re.sub(r'\A---\n.*?\n---\n', '', text.replace('\r\n', '\n'), flags=re.S)   # front matter: one-line fields
    text = re.sub(r'\\?<!-- kit:meta -->.*?<!-- /kit:meta -->', '', text, flags=re.S)   # dec-60: the kit table is no prose (out of every cap)
    for l in text.split('\n'):
        if l.lstrip().startswith('```'):
            fence = not fence
            continue
        if not fence:
            lines.append(l)
    secs, cur = {}, None
    for l in lines:
        h = re.match(r'^##\s+(.+?)\s*$', l)
        if h:
            cur = h.group(1)
            secs[cur] = []
        elif cur:
            secs[cur].append(l)
    return lines, secs

def words(s):   # CJK / kana / hangul: a word per character
    s, cjk = re.sub(r'`[^`]*`|https?://\S+', 'x', s), r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]'
    return len(re.findall(cjk, s)) + len(re.findall(r"[^\W_][\w'’.-]*", re.sub(cjk, ' ', s)))

def commit_rx():   # commitStyle: conventional | free | <regex>
    st = (load_json(osp.join(main_clone(KIT_DIR), 'skills', 'crafty', 'kit.local.json'))[0] or {}).get('commitStyle', 'conventional')
    return REQ_RX['conv'] if st == 'conventional' else r'\S' if st == 'free' else st

def locale_terms():   # locale.proseTerms: {expected, recommended, ...: regex} for non-English texts
    return ((load_json(osp.join(main_clone(KIT_DIR), 'skills', 'crafty', 'kit.local.json'))[0] or {}).get('locale') or {}).get('proseTerms') or {}

def prose_check(kind, text, spec, banned):
    """Findings (strings) for one produced text of one kind."""
    out = []
    lines, secs = prose_parts(text)
    body = [l for l in lines if l.strip()]
    flat = '\n'.join(lines)
    own = {(m.group(1).replace('_', ' '), m.group(3)) for t in spec['limits'].replace(';', ' ').split() if (m := re.match(r'^([A-Z][\w ()/-]*?):(\d+)(\w+)$', t))}   # a section's own cap beats each:
    for tok in spec['limits'].replace(';', ' ').split():
        m = re.match(r'^(?:(each|first|prose|[A-Z][\w ()/-]*?):)?(\d+)(w|t|l|ch|sw|b)$', tok)
        if not m:
            continue
        scope, n, u = (m.group(1) or '').replace('_', ' ') or None, int(m.group(2)), m.group(3)
        targets = {'(all)': body} if not scope else {'(first line)': body[:1]} if scope == 'first' else {k: v for k, v in secs.items() if (k, u) not in own} if scope == 'each' else {'(prose)': [l for l in body if not re.match(r'\s*(?:\|.*\||!\[.*\))\s*$', l)]} if scope == 'prose' else {scope: secs.get(scope, [])}   # prose: no table rows (cells have own caps), no image lines
        for name, ls in targets.items():
            txt = '\n'.join(ls)
            v = {'w': lambda: words(txt), 't': lambda: (len(txt.encode('utf-8')) + 3) // 4, 'l': lambda: len([l for l in ls if l.strip()]),
             'b': lambda: len([l for l in ls if re.match(r'^(?:[-*]|\d+\.)\s', l)])}.get(u, lambda: 0)()
            if v > n:
                out.append(f"{name}: {v} {dict(w='words', t='tokens', l='lines', b='bullets')[u]} (max {n})")
            elif u == 'ch':
                for i, l in enumerate(ls, 1):
                    if len(l) > n and not l.lstrip().startswith('|') and not re.search(r'https?://', l) and not re.fullmatch(r'\s*(?:\*\*[^*]+\*\*\s*)?`[^`]+`\s*', l):   # a lone command cannot wrap
                        out.append(f'{name}: line {i} is {len(l)} chars (max {n}): {l[:60]}...')
                        break
            elif u == 'sw':
                prose = re.sub(r'(?m)^\s*\|.*$', '', txt)
                cells = [re.sub(r'!?\[[^\]]*\]\([^)]*\)|\bfile:|`[^`]*`|<br>', ' ', c) for l in txt.split('\n') if l.lstrip().startswith('|')
                         for c in l.strip().strip('|').split('|')]   # table docs: each cell's sentences; links, images not words
                for s in re.split(r'(?<=[.!?])\s+|\n', prose) + [x for c in cells for x in re.split(r'(?<=[.!?])\s+', c)]:
                    if words(s) > n:
                        out.append(f'{name}: a sentence of {words(s)} words (max {n}): {s.strip()[:60]}...')
                        break
    out += section_gaps(spec, secs)
    for r in spec['required']:
        rx = commit_rx() if r == 'conv' else (locale_terms().get(r) or REQ_RX.get(r))
        if rx and not re.search(rx, text if r != 'conv' else (body[0] if body else ''), re.M):
            out.append(f'required fact missing: {r}')
    for b in banned:
        mm = re.search(b, flat, re.I | re.M)
        if mm:
            out.append(f'filler: "{mm.group(0).strip()}"')
    if kind.startswith('testing-'):   # K56: a tester never reconfigures or restarts a deployed env (it restarts it for every run on it)
        mm = env_change_rx().search(flat)
        if mm:
            out.append(f'env change "{mm.group(0).strip()[:60]}": a tester never toggles env config or restarts a deployed env; a feature whose '
                       'env switch is off there is NOT_TESTED (tool-down) + bossy.ps1 decide ask')
    if re.match(r'(task|comment)-|decisions$', kind):   # tracker texts: a reader has no access to this machine
        mm = LOCAL_PATH_RX.search(re.sub(r'https?://\S+', ' ', flat))
        if mm:
            out.append(f'local path "{mm.group(0).strip()}": link the doc / MR URL instead, or leave it out')
    return out

NA_BARE = re.compile(r'(?i)^\s*(?:[-*]\s*)?(?:none|n/?a|-|—|tbd|todo|nothing)\.?\s*$')


def section_gaps(spec, secs):
    """A doc's `##` sections vs its kind's format (templates.md "Writing standards"): every one present, in order, never empty or a
    bare 'none' (A3: `n/a — <why>` when it does not apply)."""
    want, out = re.findall(r'##\s+([^,#]+?)\s*(?:,|$)', spec['format']), []
    if not want:
        return out
    have = list(secs)
    missing = [w for w in want if w not in have]
    if missing:
        out.append(f'missing sections: {", ".join("## " + w for w in missing)} (format: {spec["format"]})')
    order = [w for w in have if w in want]
    if not missing and order != want:
        out.append(f'sections out of order: {" > ".join(order)} (format: {" > ".join(want)})')
    for w in [w for w in want if w in secs]:
        body = [l for l in secs[w] if l.strip()]
        if not body or (len(body) == 1 and NA_BARE.match(body[0])):
            out.append(f'section ## {w} is {"empty" if not body else repr(body[0].strip())}: write it, or `n/a — <why it does not apply>`')
    return out


def env_change_rx():
    """A deployed-env change in a testing doc: a command of crafty/vocab.json envChangeCommands (the guard's list), or words that tell
    a tester to set / toggle an env variable, option or app setting, or to set an UPPER_CASE switch."""
    cmds = (load_json(osp.join(KIT_DIR, 'skills', 'crafty', 'vocab.json'))[0] or {}).get('envChangeCommands') or []
    cmds = cmds + [c for c in ((local_config(KIT_DIR, 'kit.local.json').get('guard') or {}).get('envChangeCommands') or []) if c]   # the guard's org additions
    words_rx = (r'(?i:\b(?:set|toggle|flip|enable|disable|turn\s+(?:on|off)|change|update|add|remove)\b[^.\n|]{0,60}?\b(?:env(?:ironment)?[ -]'
                r'var(?:iable)?s?|option[ -]settings?|(?:environment|server|container|pod|lambda|beanstalk)[ -](?:config(?:uration)?|propert(?:y|ies)))\b)'
                r'|(?i:\b(?:set|toggle|flip|enable|disable|turn\s+(?:on|off))\s+)`?[A-Z][A-Z0-9]*_[A-Z0-9_]+`?\s*(?:=|(?i:\bto\b|\bon\b))')
    return re.compile('|'.join([words_rx] + [f'(?i:{c})' for c in cmds]))

LOCAL_PATH_RX = re.compile(r'(?<![\w/.-])(?:[A-Za-z]:[\\/]|\\\\\w|~[\\/]|/(?:home|Users)/[\w.-]+/|/(?:tmp|mnt)/[\w.-]+/[\w.-]+|\.{1,2}[\\/]|\.(?:runtime|state|claude|claude-runtime)[\\/])\S*')

def result_notes(obj, at=''):
    """(field path, note) for every note string in a QA run JSON (results / run / bugs; any depth); a list entry by its id."""
    if isinstance(obj, dict):
        for k_, v in obj.items():
            if k_ in ('note', 'notes', 'finding', 'observed', 'what_was_done') and isinstance(v, str):
                yield f'{at}.{k_}'.lstrip('.'), v
            else:
                yield from result_notes(v, f'{at}.{k_}')
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from result_notes(v, f'{at}[{v.get("id") or v.get("code") or i if isinstance(v, dict) else i}]')

def cmd_prose(a):
    """kitbag.py prose --kind <kind> <file | -> [--json] | --kinds"""
    kinds, banned = writing_standards(KIT_DIR)
    flags, files = parse_opts(a, {'--kind'})
    if '--kinds' in flags:
        for name, spec in kinds.items():
            print(f'{name:17} {spec["limits"]:32} {spec["purpose"]}')
        return 0
    kind = flags.get('--kind', '')
    if kind not in kinds or not files:
        print(f'kitbag prose: --kind <{"|".join(kinds)}> <file | -> [--json]', file=sys.stderr)
        return 2
    src = files[0]
    text = sys.stdin.read() if src == '-' else read(src)
    if kind == 'result-note' and src.endswith('.json'):
        found = []
        for at, n in result_notes(json.loads(text)):
            found += [f'{osp.basename(src)} {at} "{n[:50]}": {f}' for f in prose_check(kind, n, kinds[kind], banned)]
    else:
        found = prose_check(kind, text, kinds[kind], banned)
    if '--json' in flags:
        print(json.dumps({'kind': kind, 'file': src, 'findings': found}))
    else:
        for f in found:
            print(f'PROSE {kind} {src}: {f}')
    return 1 if found else 0

# ---- sections: the "Sections:" map in a script's first 40 lines vs its `<comment> ---- <name>: <what>` markers
SEC_MIN, SEC_BIG, SEC_WIDTH = 8000, 600, 130   # bytes (~2,000 tokens) that need a map; lines of a big section (audit WARN); map width
SEC_CM = {'.ps1': '#', '.py': '#', '.js': '//', '.mjs': '//'}
SEC_FN = {'.ps1': r'function\s+([\w-]+)', '.py': r'(?:async\s+)?(?:def|class)\s+(\w+)',
  '.js': r'(?:export\s+)?(?:async\s+)?function\s*\*?\s*(\w+)|(?:export\s+)?const\s+(\w+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|\w+)\s*=>'}   # column 0 only
SEC_INDIRECT = re.compile(r'Assert-Kit\w+|Get-Command|Invoke-KitVerb')   # a handler looked up by name (an adapter's function)

def sec_files(files):
    return [f for f in files if osp.splitext(f)[1] in SEC_CM and not f.startswith(('tests/',) + GENERATED)]

def sec_marks(lines, cm):
    return [(i + 1, m.group(1).strip()) for i, l in enumerate(lines) if (m := re.match(re.escape(cm) + r' ---- ([^:·]+):', l))]

def sec_parse(lines):
    """(first, last index, prefix, [(line, name)]) of the map; a continuation line ends the previous with ' ·' or starts with L<n>."""
    for i, l in enumerate(lines[:40]):
        m = re.match(r'((?:#|//)?\s*)Sections:(.*)$', l)
        if not m:
            continue
        pre, body, j = m.group(1), m.group(2), i
        def strip(s):
            return s[len(pre):] if s.startswith(pre) else s
        while j + 1 < len(lines) and (body.rstrip().endswith('·') or re.match(r'\s*L\d+ \S', strip(lines[j + 1]))):
            j += 1
            body += ' ' + strip(lines[j]).strip()
        tail = (q.group(0) if (q := re.search(r'\s*("""|\'\'\'|#>)\s*$', body)) else '')   # a docstring / comment closer on the map line stays (retro tidy-3)
        ents = [x.strip() for x in re.split(r'·|\s(?=L\d+ )', body[:len(body) - len(tail)]) if x.strip()]
        return i, j, pre, [(int(e.group(1)), e.group(2)) if (e := re.match(r'L(\d+) (.+)$', x)) else (0, x) for x in ents], tail
    return None

def sec_render(pre, ents, tail=''):
    out = [pre + 'Sections:']
    for n, (ln, name) in enumerate(ents):
        item = f'L{ln} {name}' + (' ·' if n + 1 < len(ents) else '')
        if len(out[-1]) + 1 + len(item) > SEC_WIDTH and out[-1] != out[0][:len(pre) + 9]:
            out.append(pre + '  ' + item)
        else:
            out[-1] += ' ' + item
    out[-1] += tail
    return out

def sec_verbs(ext, lines):
    """[(verb, its dispatch code, line)]: arms of the last `switch ($__verb)` (ps1); COMMANDS or `cmd == '<verb>':` arms (py)."""
    arms = []
    if ext == '.ps1':
        top = max([i for i, l in enumerate(lines) if re.match(r'\s*switch \(\$__verb\)', l)], default=-1)
        arms = [(i, m.group(1), m.group(0)[:-len(m.group(0).lstrip())]) for i, l in enumerate(lines)
                if top >= 0 and i > top and (m := re.match(r"\s+'([\w-]+)'\s*\{", l))]
        arms = [(i, v) for i, v, ind in arms if ind == arms[0][2]]
        if arms:   # the last arm ends at the switch's closing brace
            ind = len(lines[arms[0][0]]) - len(lines[arms[0][0]].lstrip())
            arms.append((next((i for i in range(arms[-1][0] + 1, len(lines)) if re.match(r'\s{0,%d}\}' % (ind - 1), lines[i])), len(lines)), ''))
    elif ext == '.py':
        for i, l in enumerate(lines):
            if l.startswith('COMMANDS = {'):
                return [(v, h, i + 1) for v, h in re.findall(r"'([\w-]+)': (\w+)", l)]
        arms = [(i, m.group(1)) for i, l in enumerate(lines) if (m := re.match(r"\s+(?:el)?if cmd == '([\w-]+)':", l))]
    return [(v, '\n'.join(lines[i:arms[n + 1][0] if n + 1 < len(arms) else len(lines)]), i + 1) for n, (i, v) in enumerate(arms) if v]

def sec_check(f, text):
    """([(code, where, problem)], text with a current map or None) of one script: lint SECTION-MAP, SECTION-UNMAPPED."""
    ext = osp.splitext(f)[1]
    cm, nl = SEC_CM.get(ext), '\r\n' if '\r\n' in text else '\n'
    lines = [x.rstrip('\r') for x in text.split('\n')]   # mixed endings: read like lint, written with the main one
    mp = sec_parse(lines) if cm else None
    if not cm or (not mp and len(text.encode('utf-8')) < SEC_MIN):
        return [], None
    marks = sec_marks(lines, cm)
    if not marks:
        return [('SECTION-MAP', f, f'no section markers: a `{cm} ---- <name>: <what>` line opens each part (README "Extending")')], None
    if not mp:
        return [('SECTION-MAP', f, 'no "Sections:" line in the first 40 lines: add one to the header, then kitbag.py sections --fix')], None
    i, j, pre, have, tail = mp
    dup = [(ln, nm) for n, (ln, nm) in enumerate(marks) if nm in [x for _, x in marks[:n]]]
    if dup:
        return [('SECTION-MAP', f'{f}:{ln}', f'section name "{nm}" repeats: rename one marker') for ln, nm in dup], None
    at, named = {nm: ln for ln, nm in have}, {nm for _, nm in marks}
    probs = [('SECTION-UNMAPPED', f'{f}:{ln}', f'section "{nm}" is missing from the Sections: map -> kitbag.py sections --fix')
             for ln, nm in marks if nm not in at]
    probs += [('SECTION-MAP', f, f'L{at[nm]} {nm} is off: its marker is at L{ln} -> kitbag.py sections --fix')
              for ln, nm in marks if nm in at and at[nm] != ln]
    probs += [('SECTION-MAP', f, f'map entry "{(f"L{ln} " if ln else "") + nm}" has no marker -> kitbag.py sections --fix')
              for ln, nm in have if nm not in named]
    rows = n = j - i + 1
    for _ in range(4):   # the map's own length shifts every line below it
        want = sec_render(pre, [(ln + rows - n if ln > j + 1 else ln, nm) for ln, nm in marks], tail)
        if len(want) == rows:
            break
        rows = len(want)
    if want != lines[i:j + 1] and not probs:
        probs.append(('SECTION-MAP', f, 'the map differs from its markers (order, wrapping) -> kitbag.py sections --fix'))
    fns = {}
    for ln, l in enumerate(lines, 1):
        if m := re.match(SEC_FN.get(ext, SEC_FN['.js']), l):
            fns.setdefault(next(g for g in m.groups() if g), ln)
    probs += [('SECTION-UNMAPPED', f'{f}:{ln}', f'{nm} sits before the first section marker: move it into a section or add a marker above it')
              for nm, ln in fns.items() if ln < marks[0][0]]
    for verb, body, ln in sec_verbs(ext, lines):
        if not SEC_INDIRECT.search(body) and not any(re.search(r'(?<![\w-])' + re.escape(fn) + r'(?![\w-])', body) for fn in fns):
            probs.append(('SECTION-UNMAPPED', f'{f}:{ln}', f'verb "{verb}" calls no function of this file: give it a handler in a section'))
    return probs, (nl.join(lines[:i] + want + lines[j + 1:]) if want != lines[i:j + 1] else None)

def sec_sizes(f, text):
    """[(line, name, lines)] of each section over SEC_BIG lines (audit WARN SECTION-BIG)."""
    lines = text.split('\n')
    marks = sec_marks(lines, SEC_CM[osp.splitext(f)[1]]) + [(len(lines) + 1, '')]
    return [(ln, nm, nxt - ln) for (ln, nm), (nxt, _) in zip(marks, marks[1:]) if nxt - ln > SEC_BIG]

def cmd_sections(a):
    """kitbag.py sections [--fix] [<file> ...]: the Sections: map of each file (default: every counted script); --fix rewrites it."""
    flags, rest = parse_opts(a)
    left = 0
    for p in [osp.abspath(x) for x in rest] or [osp.join(KIT_DIR, f) for f in sec_files(counted_files(KIT_DIR))]:
        rel = (osp.relpath(p, KIT_DIR) if osp.splitdrive(p)[0].lower() == osp.splitdrive(KIT_DIR)[0].lower() else p).replace('\\', '/')
        if not sec_files([rel]):
            continue
        if not osp.isfile(p):
            print(f'kitbag sections: no such file {p}', file=sys.stderr)
            left += 1
            continue
        text = read(p, raw=True)
        probs, fixed = sec_check(rel, text)
        if fixed and '--fix' in flags:
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(fixed)
            print(f'fixed {rel}')
            probs = sec_check(rel, fixed)[0]
        for c, w, m in probs:
            print(f'{c:16} {w}: {m}')
        left += len(probs)
    return 1 if left else 0

# ---- budget: start tokens per role vs START_CAP; repo and tests totals as INFO
def cmd_budget(a):
    """kitbag.py budget [show]: start tokens per role (always-loaded + own) vs START_CAP, then INFO lines: repo and tests totals."""
    _, rest = parse_opts(a)
    if rest and rest[0] != 'show':
        print(cmd_budget.__doc__, file=sys.stderr)
        return 2
    k = load(KIT_DIR)
    sizes = {f: size_tokens(KIT_DIR, f) for f in counted_files(KIT_DIR)}
    reads = {r: t for r, t, _ in read_rows(k, sizes)}
    for role, always, own in phase_rows(k):
        print(f'{role:10} start {always + own:6} of {START_CAP} (always-loaded {always} + own {own}: phase lessons, entry docs)')
    for role, always, own in start_rows(k):
        print(f'{role:8} start {always + own:6} of {START_CAP} (always-loaded {always} + own {own}) · with every read {reads.get(role, 0)} of {instr_cap(KIT_DIR)}')
    total, tests = split_total(sizes)
    print(f'INFO repo total {total} tokens · tests {tests} (no cap: agents load per role, then through pointers)')
    return 0

# ---- migrate: one-time cleanup of the retired local-install path (2026-11-14); .githooks/post-merge runs it after a pull
BLOCK_LINE = re.compile(r'^# kitbag (\w+) (\S+)$')   # `# kitbag <marker> <part>` ... `# kitbag <marker> end` blocks in .git/info/exclude

def cmd_migrate(a):
    """kitbag.py migrate: drops the retired install blocks from .git/info/exclude (shared by every worktree), deletes the
    files they listed that git no longer tracks (never a kit.local.json localOnly path), the install-use stamps
    (<state>/extras-used) and this kit's kit.local.json key named after the blocks' marker. Idempotent; silent when done."""
    kit, done = KIT_DIR, []
    rc, ex, _ = git(kit, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude', timeout=20)
    lines = read(ex).split('\n') if rc == 0 and ex and osp.isfile(ex) else []
    keep, listed, markers, inside = [], [], set(), False
    for line in lines:
        m = BLOCK_LINE.match(line.strip())
        if m:
            markers.add(m.group(1))
            inside = m.group(2) != 'end'
            continue
        if inside and line.strip():
            listed.append(line.strip().lstrip('/'))
            continue
        inside = False
        keep.append(line)
    cfg_path = osp.join(kit, 'skills', 'crafty', 'kit.local.json')
    cfg, cfg_err = load_json(cfg_path) if osp.isfile(cfg_path) else ({}, None)
    rc_ls, ls, _ = git(kit, 'ls-files')
    if listed and (rc_ls or not ls.strip() or cfg_err or not isinstance(cfg, dict)):   # never guess what is tracked or local-only
        print('kitbag migrate: git ls-files or kit.local.json unreadable: nothing changed (run it again)', file=sys.stderr)
        return 1
    cfg = cfg if isinstance(cfg, dict) else {}
    local = [str(p).replace('\\', '/').strip('/') for p in (cfg.get('localOnly') or [])]
    now, root = set(ls.split('\n')), osp.abspath(kit)
    for rel in sorted(set(listed)):
        path = osp.abspath(osp.join(kit, rel))
        if rel in now or any(rel == p or rel.startswith(p + '/') or fnmatch.fnmatch(rel, p) for p in local) or \
           osp.commonpath([root, path]) != root or not osp.isfile(path):
            continue
        os.remove(osp.join(kit, rel))
        d = osp.dirname(osp.join(kit, rel))
        while osp.normcase(d) != osp.normcase(kit) and osp.isdir(d) and not os.listdir(d):
            os.rmdir(d)
            d = osp.dirname(d)
        done.append(f'{rel}: removed (no longer part of the kit)')
    stamps = osp.join(kit, MAP.get('stateDir', '.state'), 'extras-used')
    if osp.isdir(stamps):
        shutil.rmtree(stamps, ignore_errors=True)
        done.append(f'{osp.relpath(stamps, kit)}: removed')
    keys = [k for k in (x[:-1] + 'ies' if x.endswith('y') else x + 's' for x in sorted(markers)) if k in cfg]   # the list named after a marker
    if keys:
        text = read(cfg_path)
        indent = len(re.search(r'\n( *)"', text).group(1)) if re.search(r'\n( *)"', text) else 2
        for key in keys:
            cfg.pop(key)
            done.append(f'skills/crafty/kit.local.json: key "{key}" removed')
        with open(cfg_path + '.tmp', 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(json.dumps(cfg, indent=indent, ensure_ascii=False) + '\n')
        os.replace(cfg_path + '.tmp', cfg_path)
    if markers:   # last: a failed step above leaves the blocks for the next run
        with open(ex + '.tmp', 'w', encoding='utf-8', newline='\n') as fh:
            fh.write('\n'.join(keep).rstrip('\n') + '\n')
        os.replace(ex + '.tmp', ex)
        done.insert(0, f'.git/info/exclude: {len(listed)} install line(s) dropped')
    if osp.isfile(cfg_path):
        bad, added = migrate_config(cfg_path)
        if bad:
            print(f'kitbag migrate: {bad}: configVersion unchanged (run it again)', file=sys.stderr)
            return 1
        done += [f'skills/crafty/kit.local.json: "{k}" set to the pre-{CONFIG_VERSION} default' for k in added]
    for x in done:
        print(f'kitbag migrate: {x}')
    return 0

# Changed defaults: a kit.local.json older than a version gets, once, the value that reproduced the old default for each key it
# does not set; a new one (setup -WriteLocal: kit.example.json) starts at CONFIG_VERSION. Only kit-shaped rows ship here; an org's
# own old values (hosts, branch names, stack, tracker patterns) go in the git-ignored LEGACY_LOCAL next to kit.local.json.
CONFIG_VERSION = 3
# legacy-defaults:start
LEGACY_DEFAULTS = {   # version -> {dotted key -> the default before it} (README "Configuration" has today's)
    2: {
        'process.gates': {'promote': 'builtin:testingDocs', 'merge': 'builtin:testingDocs', 'finish': 'builtin:testingDocs', 'mrBody': 'builtin:testingDocs', 'bugFix': 'builtin:reproRow'},
        'mr.footer': '\U0001f916 Generated with [Claude Code](https://claude.com/claude-code)',
        'deploy.ssh.manager': 'systemd',
        'deploy.ssh.sudo': True,
        'api.tokenFields': ['access_token'],
        'ports.targets': 'both',
        'localEnv.defaultService': 'api',
        'localEnv.defaults.db.cascadeGuard': True,
    },
    3: {
        'tests.fallbackRunner': 'spec',
        'build.mavenOffline': True,
    },
}
# legacy-defaults:end
LEGACY_LOCAL = 'migrate.legacy.local.json'   # {"<version>": {"<dotted key>": value}}: merged over LEGACY_DEFAULTS

def legacy_rows(path, since):
    """[(dotted, value)] of every version above `since`: LEGACY_DEFAULTS, then the org's LEGACY_LOCAL beside `path` (error, rows)."""
    rows = {}
    extra, err = load_json(osp.join(osp.dirname(path), LEGACY_LOCAL)) if osp.isfile(osp.join(osp.dirname(path), LEGACY_LOCAL)) else ({}, None)
    if err or not isinstance(extra, dict):
        return f'{LEGACY_LOCAL} unreadable', []
    for ver in sorted({int(v) for v in list(LEGACY_DEFAULTS) + [x for x in extra if str(x).isdigit()]}):
        if since < ver <= CONFIG_VERSION:
            rows.update(LEGACY_DEFAULTS.get(ver) or {})
            rows.update(extra.get(str(ver)) if isinstance(extra.get(str(ver)), dict) else {})
    return None, list(rows.items())

def migrate_config(path):
    """(error, [dotted keys added]): the legacy rows of each version above the file's configVersion; keys it sets win."""
    cfg, err = load_json(path)
    if err or not isinstance(cfg, dict):
        return f'{osp.basename(path)} unreadable', []
    since = int(cfg.get('configVersion') or 1)
    if since >= CONFIG_VERSION:
        return None, []
    err, rows = legacy_rows(path, since)
    if err:
        return err, []
    added = []
    for dotted, value in rows:
        if dotted.split('.')[0] in ('localEnv', 'masking') and 'localEnv' not in cfg:   # no local env: nothing used them
            continue
        cur, parts = cfg, dotted.split('.')
        for part in parts[:-1]:
            if not isinstance(cur.get(part), dict):
                if part in cur:   # a scalar where an object is due: the clone's own choice, left alone
                    cur = None
                    break
                cur[part] = {}
            cur = cur[part]
        if cur is None:
            continue
        if parts[-1] not in cur:
            cur[parts[-1]] = value
            added.append(dotted)
        elif isinstance(value, dict) and isinstance(cur[parts[-1]], dict) and dotted not in USER_MAPS:   # a partial object: its missing fields
            for k, v in value.items():
                if k not in cur[parts[-1]]:
                    cur[parts[-1]][k] = v
                    added.append(f'{dotted}.{k}')
    cfg['configVersion'] = CONFIG_VERSION
    text = read(path)
    indent = len(re.search(r'\n( *)"', text).group(1)) if re.search(r'\n( *)"', text) else 2
    with open(path + '.tmp', 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(json.dumps(cfg, indent=indent, ensure_ascii=False) + '\n')
    os.replace(path + '.tmp', path)
    return None, added

# ---- plugins: skills/bossy/kitbag_<name>.py modules add commands, audit verbs, args and lint hooks
PLUGINS = {}      # command -> handler, from the plugins (skills/bossy/kitbag_<name>.py)
LINT_HOOKS = []   # (kit, problems, flags) -> None: adds problems
WARN_HOOKS = []   # (kit) -> [(code, where, msg)]: lint warnings, not counted

def config_values(cfg, dotted):
    """Every value at a dotted path; `*` walks every key or list item."""
    cur = [cfg]
    for part in dotted.split('.'):
        nxt = []
        for x in cur:
            if part == '*':
                nxt += list(x.values()) if isinstance(x, dict) else x if isinstance(x, list) else []
            elif isinstance(x, dict) and part in x:
                nxt.append(x[part])
        cur = nxt
    return cur

def local_config_path(kit, fname):
    """A local config file (kit.local.json, targets.local.json, swarm.config.json) in skills/*/: this kit's, else the main
    clone's (a worktree has no git-ignored files); None when there is none."""
    for base in (kit, main_clone(kit)):
        for d in sorted(os.listdir(osp.join(base, 'skills'))) if osp.isdir(osp.join(base, 'skills')) else []:
            if osp.isfile(osp.join(base, 'skills', d, fname)):
                return osp.join(base, 'skills', d, fname)
    return None

def local_config(kit, fname):
    p = local_config_path(kit, fname)
    return (load_json(p)[0] or {}) if p else {}

def load_plugins():
    """Load the plugins (kitbag_<name>.py): each sees this module's names, adds COMMANDS, AUDIT_VERBS, ARGS and a lint_hook."""
    here = osp.dirname(osp.abspath(__file__))
    for fname in sorted(os.listdir(here)):
        if not re.match(r'kitbag_[\w-]+\.py$', fname):
            continue
        spec = importlib.util.spec_from_file_location(fname[:-3], osp.join(here, fname))
        mod = importlib.util.module_from_spec(spec)
        shared = {n: v for n, v in globals().items() if not n.startswith('__')}
        mod.__dict__.update(shared)
        try:
            spec.loader.exec_module(mod)
        except Exception as e:   # a broken plugin must not break lint (the commit gate)
            print(f'kitbag: plugin {fname} not loaded: {e}', file=sys.stderr)
            continue
        own = {n: v for n, v in vars(mod).items() if n not in shared or v is not shared[n]}   # what the plugin itself defines
        PLUGINS.update(own.get('COMMANDS', {}))
        AUDIT_VERBS.update(own.get('AUDIT_VERBS', {}))
        for cmd, (switches, valued, positional) in own.get('ARGS', {}).items():
            have = ARGS.get(cmd, (set(), set(), positional))
            ARGS[cmd] = (have[0] | switches, have[1] | valued, have[2])
        if 'lint_hook' in own:
            LINT_HOOKS.append(own['lint_hook'])
        if 'warn_hook' in own:
            WARN_HOOKS.append(own['warn_hook'])

# ---- state lint: every file of skills/bossy/STATE.md "Inventory" (the schema registry)
ISO_TIME = re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)$')
STATE_DOC = 'skills/bossy/STATE.md'

def last_line(path, size=65536):
    with open(path, 'rb') as fh:
        fh.seek(max(0, osp.getsize(path) - size))
        lines = [x for x in fh.read().decode('utf-8', 'replace').splitlines() if x.strip()]
    return lines[-1] if lines else ''

def state_schemas(kit=None):
    """{name: schema} from the STATE.md Inventory rows: | `name` | owner | `schema` | ..."""
    return dict(re.findall(r'(?m)^\| `([\w:-]+)` \|[^|\n]*\| `([^`]+)` \|', section(read(osp.join(kit or KIT_DIR, STATE_DOC)), 'Inventory') or ''))

ART_ROW = re.compile(r'(?m)^\| `([\w-]+)` \| ([^|\n]+) \| (`[^`]+`|—) \| (`[^`]+`|—) \|')

def artefacts(kit=None):
    """[(kind, writer, where glob, shape)] from STATE.md "Artefacts (drift guard)"; '' for —."""
    sec = section(read(osp.join(kit or KIT_DIR, STATE_DOC)), 'Artefacts (drift guard)') or ''
    un = lambda x: '' if x == '—' else x.strip('`').replace('\\|', '|')
    return [(kd, w.strip(), un(g), un(s)) for kd, w, g, s in ART_ROW.findall(sec)]

def artefact_lint(kit, scripts):
    """ARTEFACT: a Writing-standards kind without a row (a new free-text kind), a writer that is no kit script verb and no
    "free: <who> (<plan>)", a shape that is no `md <regex>` / `json <keys>` / `any`."""
    rows, out = artefacts(kit), []
    have = {r[0] for r in rows}
    out += [f'Writing-standards kind {kd} has no "Artefacts" row: name its writer (a renderer from a spec), never free text' for kd in writing_standards(kit)[0] if kd not in have]
    for kd, w, g, s in rows:
        names = re.findall(r'`([\w.]+\.(?:ps1|py|mjs|js))\b', w)
        if not names and not w.startswith('free: '):
            out.append(f'{kd}: writer {w!r}: a backticked kit script verb or "free: <who> (<plan>)"')
        out += [f'{kd}: writer {n} is no kit script' for n in names if n not in scripts]
        try:
            if s and s != 'any' and not (s.startswith('json ') or (s.startswith(('md ', 'todo ')) and re.compile(s.partition(' ')[2]))):
                out.append(f'{kd}: shape {s!r}: md|todo <first-line regex> | json <keys> | any')
        except re.error as e:
            out.append(f'{kd}: shape regex {s.partition(" ")[2]!r}: {e}')
    return out

def shape_ok(shape, f):
    """A file vs an Artefacts shape: md = its first non-empty line matches, json = one object with those keys."""
    if not shape or shape == 'any':
        return True
    if shape.startswith('json '):
        o = state_read(f)
        return isinstance(o, dict) and all(k in o for k in shape[5:].split())
    try:
        with open(f, encoding='utf-8-sig', errors='replace') as fh:
            lines = [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        return False
    kind, _, rx = shape.partition(' ')   # todo: + every checkbox line is a TODO_ITEM
    return bool(lines and re.search(rx, lines[0])) and (kind != 'todo' or all(TODO_ITEM.match(x) for x in lines if x.startswith('- [')))

TODO_ITEM = re.compile(r'^- \[[ x]\] [\w.-]+ · [^·\n]+ · \S[^\n]*$')   # - [ ] <code> · <desc> · <ref>

def todo_cmd(a):
    """state todo add <file> <code> "<desc>" <ref> | done <file> <code> [<ref>] | lint <file>: a kitty to-do / handoff list,
    one item shape (STATE.md Artefacts kitty-todo)."""
    if len(a) < 2 or a[0] not in ('add', 'done', 'lint'):
        print(todo_cmd.__doc__, file=sys.stderr)
        return 2
    verb, f = a[0], a[1]
    lines = read(f).replace('\r\n', '\n').split('\n') if osp.isfile(f) else ['# Kit to-do', '', '']
    if verb == 'lint':
        bad = [x for x in lines if x.startswith('- [') and not TODO_ITEM.match(x)]
        for x in bad:
            print(f'TODO-SHAPE {x[:100]} (want "- [ ] <code> · <desc> · <ref>")')
        return 1 if bad else 0
    code = a[2] if len(a) > 2 else ''
    at = next((i for i, x in enumerate(lines) if re.match(rf'^- \[[ x]\] {re.escape(code)} · ', x)), None)
    if verb == 'add':
        why = ('missing ' + ', '.join(['code', 'desc', 'ref'][len(a) - 2:]) if len(a) < 5 else 'desc holds a ·' if '·' in a[3]
               else f'code {code} is already in {f}' if at is not None else '')
        if why:   # name the slip and show a filled line: agents guessed the shape 3x
            raise SystemExit(f'state todo add: {why}; usage: state todo add <file> <code> "<desc, no ·>" <ref> (task, commit, file:line)\n'
                             '  e.g. kitbag.py state todo add todo.md L1 "lint skips unmerged entries" kitbag.py:812')
        lines.insert(len(lines) - (1 if lines[-1] == '' else 0), f'- [ ] {code} · {a[3]} · {a[4]}')
    elif at is None:
        raise SystemExit(f'state todo done: no item {code} in {f}')
    else:
        x = '- [x]' + lines[at][5:]
        lines[at] = x.rsplit(' · ', 1)[0] + f' · {a[3]}' if len(a) > 3 else x
    with open(f, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n'.join(lines).rstrip('\n') + '\n')
    print(f'{verb} {code}: {f}')
    return 0

def artefact_files(since_min=0):
    """Drift guard on run files: a .md / .json in a shared place no Artefacts / Inventory row lists = BAD; agent scratch of no
    listed shape and loose files in work/ itself = WARN (crafty.ps1 dir gives an agent's place)."""
    rt, now, out = runtime_dir(), time.time(), []
    rows = [(g, s) for _, _, g, s in artefacts() if g]
    for n, spec in state_schemas().items():   # Inventory dirs: their own files
        m = re.match(r'dir(?:=(\S+))?\s', spec)
        if m and n in MAP['runtime'] and MAP['runtime'][n].startswith('work/'):
            rows.append((MAP['runtime'][n] + (m.group(1) or '*.json'), 'any'))
    pats = ('work/*', 'work/docs/*', 'work/briefs/*', 'work/waves/*', 'work/qa-runs/*/*', 'work/agents/*/*')
    for pat in pats:
        for f in Path(rt).glob(pat):
            if not f.is_file() or (since_min and now - f.stat().st_mtime > since_min * 60):
                continue
            rel = f.relative_to(rt).as_posix()
            if pat == 'work/*':
                out.append(('WARN', 'artefacts', rel, 'loose file in work/: an agent\'s files go where crafty.ps1 dir -Agent <id> says'))
                continue
            hits = [(g, s) for g, s in rows if fnmatch.fnmatch(rel, g)]
            top = max((len(g) for g, _ in hits), default=0)   # the most specific place decides (docs/*-ai.md before docs/*)
            if f.suffix not in ('.md', '.json') or any(len(g) == top and shape_ok(s, str(f)) for g, s in hits):
                continue
            # work/docs: kept copies (publish gates them) -> WARN
            out.append(('WARN' if pat in ('work/agents/*/*', 'work/docs/*') else 'BAD', 'artefacts', rel,
                        'unlisted shape: no STATE.md "Artefacts" row names its writer (render it from a spec, or add the row with its renderer)'))
    return out

def state_lint(since_min=0):
    """[(level, name, file, problem)]: BAD = unreadable, wrong schemaVersion or a required key missing; WARN = written before
    STATE.md (no schemaVersion) or a time without an offset. since_min: only files written in the last N minutes."""
    out, now, schemas = [], time.time(), state_schemas()
    own = {osp.normcase(kit_path(n)) for n, s in schemas.items() if not s.startswith('dir') and (n in MAP['runtime'] or n in MAP['durable'])}   # own-row files (runtimes/locks.json) are not their dir's
    for name, spec in schemas.items():
        m = re.match(r'(json|jsonl|text|dir)(?:=(\S+))?\s+v(\d+)(?::\s*(.*))?$', spec)
        base = name.split(':')[0]   # <_paths name>:<part> = another file kind in that folder (qa-runs:results)
        if not m or (base not in MAP['runtime'] and base not in MAP['durable']):
            out.append(('BAD', name, STATE_DOC, f'Inventory {name}: {spec!r} (want "<form> v<n>: <keys> [+ <allowed keys>]" for a _paths name)'))
            continue
        form, pat, ver = m.group(1), m.group(2) or '*.json', int(m.group(3))
        req, _, allow = (m.group(4) or '').partition(' + ')   # allowed: '' = any key
        req, allow = req.split(), set(allow.split()) | set(req.split()) | {'schemaVersion', 'updated', 'holder'}
        p = kit_path(base)
        for f in sorted(str(x) for x in Path(p).glob(pat)) if form == 'dir' else [p]:
            if not osp.isfile(f) or (since_min and now - osp.getmtime(f) > since_min * 60) or form == 'text' or (form == 'dir' and osp.normcase(f) in own):
                continue
            rel = osp.relpath(f, KIT_DIR)
            try:
                o = json.loads(last_line(f)) if form == 'jsonl' else None
            except ValueError:
                o = None
            o = o if form == 'jsonl' else state_read(f)
            if not isinstance(o, dict):
                out.append(('BAD', name, rel, 'unreadable (not one JSON object' + (' on its last line)' if form == 'jsonl' else ')')))
                continue
            extra = sorted(k for k in o if k not in allow) if _ else []
            if extra:   # a writer added keys the schema does not list: drift (supervise WATCH); jsonl: its last line
                out.append(('BAD', name, rel, f'drift: key(s) {", ".join(extra[:6])} not in the schema ({name}: {spec}): add them to STATE.md or fix the writer'))
            miss = [k for k in req if k not in o]
            if miss:
                out.append(('BAD', name, rel, f'missing {", ".join(miss)} ({name}: {spec})'))
            if ver and form != 'jsonl' and o.get('schemaVersion') not in (ver, ver - 1):   # readers accept n-1 (STATE.md)
                out.append(('WARN' if 'schemaVersion' not in o else 'BAD', name, rel, f'schemaVersion {o.get("schemaVersion")}, want {ver}'))
            t = o.get('updated') or o.get('at')
            if isinstance(t, str) and t and not ISO_TIME.match(t):
                out.append(('WARN', name, rel, 'a time without an offset (ISO 8601 with offset: STATE.md)'))
    return out + artefact_files(since_min)

def cmd_state(a):
    """state lint [--since <min>] [--json]: exit 1 on a BAD file (supervise flags them)."""
    flags, rest = parse_opts(a, ('--since',))
    if rest[:1] == ['todo']:
        return todo_cmd(rest[1:])
    if rest[:1] == ['writers']:   # the drift guard's registry: every agent-written kind and its writer
        rows = artefacts()
        for kd, w, g, s in rows:
            print(f'{kd:18} {w}' + (f'  [{g} {s}]' if g else ''))
        print(f'{len(rows)} kinds, {sum(w.startswith("free: ") for _, w, _, _ in rows)} still free text')
        return 0
    if rest[:1] != ['lint']:
        print('usage: kitbag.py state lint [--since <minutes>] [--json] | state writers', file=sys.stderr)
        return 2
    found = state_lint(float(flags.get('--since') or 0))
    if flags.get('--json'):
        print(json.dumps([{'level': l, 'name': n, 'file': f, 'problem': p} for l, n, f, p in found]))
    else:   # BAD one line each; WARN counted per name and problem (legacy files are many)
        for l, n, f, p in found:
            if l == 'BAD':
                print(f'BAD  {f}: {p}')
        for (n, p), c in sorted(collections_counter((n, p) for l, n, f, p in found if l == 'WARN').items()):
            print(f'WARN {n}: {c} file(s): {p}')
        print(f'kitbag state lint: {sum(1 for x in found if x[0] == "BAD")} bad, {sum(1 for x in found if x[0] == "WARN")} warn')
    return 1 if any(x[0] == 'BAD' for x in found) else 0

def collections_counter(items):
    c = defaultdict(int)
    for x in items:
        c[x] += 1
    return c

# ---- main: argument checks, command dispatch
# per command: switches, value flags, kit dir positional? (`lint --help` once became a kit dir)
ARGS = {'lint': ({'--summary', '--warn', '--no-flow', '--ratchet'}, {'--org-terms', '--json'}, True),
  'flow': ({'--readme'}, set(), True), 'audit': (set(), {'--kit', '--json'}, False), 'prose': ({'--json', '--kinds'}, {'--kind'}, False),
  'budget': (set(), set(), False), 'migrate': (set(), set(), False), 'sections': ({'--fix'}, set(), False),
  'state': ({'--json'}, {'--since'}, False), 'ui-check': (set(), {'--widths', '--click'}, False), 'parity': ({'--json'}, {'--n'}, False)}
NAMED_ARGS = ('prose', 'budget', 'sections', 'new', 'rename', 'remove', 'state', 'ui-check', 'naming', 'parity', 'faults')   # positionals: files, verbs or names, never a kit dir
COMMANDS = {'lint': cmd_lint, 'flow': cmd_flow, 'audit': audit_main, 'prose': cmd_prose, 'budget': cmd_budget, 'migrate': cmd_migrate, 'sections': cmd_sections, 'state': cmd_state, 'ui-check': cmd_ui_check, 'parity': cmd_parity}

def parse_opts(a, valued=()):
    """(flags, positionals) of arguments check_args accepted: a switch maps to True, a value flag to its value."""
    flags, rest, i = {}, [], 0
    while i < len(a):
        if a[i] in valued and i + 1 < len(a):
            flags[a[i]] = a[i + 1]
            i += 2
            continue
        if a[i].startswith('-') and a[i] != '-':
            flags[a[i]] = True
        else:
            rest.append(a[i])
        i += 1
    return flags, rest

def is_kit(d):
    return osp.isdir(osp.join(d, 'skills')) and any(osp.isfile(osp.join(d, f)) for f in ('AGENTS.md', 'CLAUDE.md'))

def check_args(cmd, rest):
    """None = go on; else the exit code: --help/-h prints usage (0); an unknown command or flag, a non-kit dir is 2 (a plugin's command without its file: unknown)."""
    if cmd in ('-h', '--help', 'help') or (cmd in ARGS and any(x in ('-h', '--help') for x in rest)):
        print(__doc__)
        return 0
    verb = rest[0] if cmd == 'audit' and rest else ''
    if cmd not in ARGS or (cmd == 'audit' and verb not in AUDIT_VERBS):
        print(__doc__)
        return 2
    if '--kit' in rest and rest.index('--kit') + 1 < len(rest) and not is_kit(rest[rest.index('--kit') + 1]):
        print(f'kitbag {cmd}: --kit {rest[rest.index("--kit") + 1]!r} is not a kit folder', file=sys.stderr)
        return 2
    switches, valued, positional = ARGS[cmd]
    i = 0
    while i < len(rest):
        x = rest[i]
        if x in valued:
            if i + 1 >= len(rest):
                print(f'kitbag {cmd}: {x} needs a value', file=sys.stderr)
                return 2
            i += 2
            continue
        if x.startswith('-') and x != '-' and x not in switches:
            print(f'kitbag {cmd}: unknown option {x} (kitbag.py --help)', file=sys.stderr)
            return 2
        if not x.startswith('-') and not (cmd == 'audit' and i == 0) and cmd not in NAMED_ARGS and (not positional or not is_kit(x)):
            print(f'kitbag {cmd}: {x!r} is not a kit folder (needs skills/ and AGENTS.md or CLAUDE.md)', file=sys.stderr)
            return 2
        i += 1
    return None

if __name__ == '__main__':
    getattr(sys.stdout, 'reconfigure', lambda **_: None)(encoding='utf-8')
    load_plugins()
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    rc = check_args(cmd, rest)
    sys.exit(rc if rc is not None else audited('kitbag.py', sys.argv[1:], lambda: (PLUGINS.get(cmd) or COMMANDS[cmd])(rest)))
