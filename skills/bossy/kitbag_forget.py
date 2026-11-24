"""kitbag_forget.py (plugin): forget on cap - an over-cap artefact first loses its least valuable items, anywhere in it.

  python -X utf8 skills/bossy/kitbag.py forget --target <file|lessons|memory|over-cap> [--section <s>] [--to <cap>] [--kind <prose kind>] [--unused-days 60] [--dry-run | --apply] [--json]
  python -X utf8 skills/bossy/kitbag.py forget --confirm <batch> --decision <id>   # features, after the owner's yes (decide ask)
  python -X utf8 skills/bossy/kitbag.py forget --restore <id> · --list · --purge [--dry-run] [--now <iso>]

Items and score (lowest goes first): lessons = lines (hits "(n×)", then last change); docs = ##/### sections (references
`"<heading>"` elsewhere, then git age); code = functions (call sites); config = JSON keys (references); memory index = lines
(note `updated:`); prose (--kind) = lines (duplicate, generated, then written). Never forgotten: hard rules, owner decisions,
safety guards (protected headings / lines, `## Decisions`, feedback / user notes), referenced sections, called code.
--apply cuts content only: lessons, and sections unreferenced and unchanged for --unused-days. Features (functions, verbs,
config keys) are only proposed: --apply writes one batch and prints its decide ask; --confirm applies it after a yes. Memory
indexes and produced texts are only proposed. Each cut goes to <state>/forgotten/<kind>/<date>.md (`--restore <id>` puts it
back); a kind's archive lives 7 days, doubled per restore up to 90, halved after a window with none; --purge deletes the rest.
Exit codes: 0 fits / done · 1 still over cap, or a confirm refused · 2 usage error.
Sections: L29 model · L74 items · L213 plan · L265 archive · L475 hooks
"""
import ast, contextlib, datetime, json, os, re, sys, time
import os.path as osp

MIN_DAYS, MAX_DAYS, UNUSED_DAYS, LESSON_CAP, MEMORY_CAP = 7, 90, 60, 40, 200   # memory: Claude Code loads 200 index lines
PROTECT = re.compile(r'(?i)\b(?:rules?|non-negotiables?|decisions?|safety|guards?|secrets?|security|never|writing|load when|not when|hands off to|files)\b')
OWNER = re.compile(r'(?i)\(owner\b|\bowner,? \d{4}-\d\d-\d\d|\bowner decid')
GEN = re.compile(r'(?i)^\s*(?:<!--|generated (?:by|with)\b|co-authored-by:|\W{0,3}\s*generated with\b)')
HIT = re.compile(r'\((\d+)\s*[x×]\)\s*\.?\s*$')
FENCE = '~~~~~~ forget'
CODE_EXT = ('.py', '.ps1', '.psm1', '.js', '.mjs')

# ---- model: target kind, measure, cap
def _now(flags):
    return datetime.datetime.fromisoformat(flags['--now']).timestamp() if isinstance(flags.get('--now'), str) else time.time()

def _kind(path, flags):
    b = osp.basename(path)
    if flags.get('--kind'):
        return 'prose'
    if b.startswith('LESSONS') and b.endswith('.md'):
        return 'lessons'
    if b == 'MEMORY.md':
        return 'memory'
    return 'doc' if b.endswith('.md') else 'code' if b.endswith(CODE_EXT) else 'config' if b.endswith('.json') else None

def memory_index():
    """The Claude Code memory index (user settings autoMemoryDirectory/MEMORY.md); None when there is none."""
    s = (load_json(osp.join(osp.expanduser('~'), '.claude', 'settings.json'))[0] or {}).get('autoMemoryDirectory')
    p = osp.join(osp.expanduser(s), 'MEMORY.md') if s else None
    return p if p and osp.isfile(p) else None

def _rel(path):
    try:
        r = osp.relpath(osp.abspath(path), KIT_DIR).replace('\\', '/')
    except ValueError:   # another drive
        return None
    return None if r.startswith('..') else r

def _cost(kind, line):
    return words(line) if kind == 'prose' else 1 if kind in ('lessons', 'memory') else len(line.encode('utf-8')) // 4

def _cap(kind, rel, flags, text=''):
    """(cap, unit) or (None, why)."""
    if flags.get('--to'):
        return int(flags['--to']), {'prose': 'w', 'lessons': 'l', 'memory': 'l'}.get(kind, 't')
    if kind == 'lessons':
        return LESSON_CAP, 'l'
    if kind == 'memory':
        return MEMORY_CAP, 'l'
    if kind == 'prose':
        spec = writing_standards(KIT_DIR)[0].get(flags['--kind'])
        m = spec and re.search(r'(?:^|[\s;])(\d+)w(?:$|[\s;])', spec['limits'])
        return (int(m.group(1)), 'w') if m else (None, f'prose kind {flags["--kind"]}: no whole-text word cap')
    b = rel and budget_type(rel)
    return (BUDGETS[b], 't') if b else (None, 'no cap for this file: pass --to <tokens>')

# ---- items: one splitter per kind -> [{start, end, label, cls, protected, key, why, group}]
_TEXTS = {}
def _texts():
    if not _TEXTS:
        for f in counted_files(KIT_DIR):
            if f.endswith(TEXT_EXT):
                _TEXTS[f] = read(osp.join(KIT_DIR, f))
    return _TEXTS

def _blame(path, n, now):
    rc, out, _ = run(['git', '-C', osp.dirname(osp.abspath(path)), 'blame', '--line-porcelain', '--', osp.basename(path)])
    t, cur = [], now
    for l in out.split('\n') if rc == 0 else []:
        if l.startswith('committer-time '):
            cur = float(l.split()[1])
        elif l.startswith('\t'):
            t.append(cur)
    return t if len(t) == n else [now] * n   # unknown age = new: never auto-forgotten

def _lessons(L, times, flags):
    out, cur, proj = [], None, False
    for i, l in enumerate(L):
        if l.startswith('## '):
            cur, proj = l[3:].strip(), False
        elif l.startswith('### '):
            proj = True   # "### Project:" lessons go after the generic ones (the old -Trim order)
        elif cur and l.startswith('- ') and flags.get('--section') in (None, cur):
            m = HIT.search(l)
            hits = 0 if l.startswith('- (fixed in kit)') else int(m.group(1)) if m else 1
            out.append(dict(start=i, end=i + 1, label=l[2:70], cls='content', group=cur, auto=True, key=(proj, hits, times[i]),
                            protected=cur in ('Decisions', 'History') or bool(OWNER.search(l)), why=f'{hits} hit(s)'))
    return out

def _sections(L, times, now, unused):
    heads, fence = [], False
    for i, l in enumerate(L):
        fence = fence != l.lstrip().startswith('```')
        m = not fence and re.match(r'^(#{2,3})\s+(.+?)\s*$', l)
        if m:
            heads.append((i, len(m.group(1)), re.sub(r'[`*_]', '', m.group(2))))
    out = []
    for n, (i, lv, title) in enumerate(heads):
        end = next((j for j, lv2, _ in heads[n + 1:] if lv2 <= lv), len(L))
        body = '\n'.join(L[i:end])
        names = {title, re.sub(r'\s*\(.*?\)\s*$', '', title), title.split(';')[0].strip()}   # "Flows to trace" names "Flows to trace (kitty step 4)"
        refs = sum(t.count(f'"{v}"') for t in _texts().values() for v in names if v)
        age = (now - max(times[i:end])) / 86400
        prot = bool(PROTECT.search(title) or OWNER.search(body) or re.search(r'(?i)\b(?:never|must)\b', body) or any(PROTECT.search(h) for j, _, h in heads if i < j < end))
        if refs == 0:
            out.append(dict(start=i, end=end, label=f'## {title}', cls='content', group='', auto=age >= unused, protected=prot,
                            key=(refs, max(times[i:end])), why=f'0 references, unchanged {int(age)} d'))
    return out

def _brace_end(L, i):
    depth, seen = 0, False
    for j in range(i, len(L)):
        s = re.sub(r"'[^']*'|\"(?:[^\"`\\]|[`\\].)*\"", '', L[j])
        s = re.split(r'(?:^|\s)#|//', s)[0]
        for ch in s:
            depth += (ch == '{') - (ch == '}')
            seen = seen or ch == '{'
        if seen and depth <= 0:
            return j + 1
    return None

def _calls(name, rel):
    rx = re.compile(r'(?<![\w-])' + re.escape(name) + r'(?![\w-])')
    return sum(len(rx.findall(t)) for t in _texts().values())

def _code(L, rel, times):
    spans = []
    if rel.endswith('.py'):
        for n in ast.parse('\n'.join(L)).body:
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                spans.append((n.name, min([n.lineno] + [d.lineno for d in n.decorator_list]) - 1, n.end_lineno))
    else:
        rx = re.compile(r'^\s*(?:export\s+)?(?:async\s+)?function\s+([\w-]+)')
        for i, l in enumerate(L):
            m = rx.match(l)
            e = m and _brace_end(L, i)
            if e:
                spans.append((m.group(1), i, e))
    return [dict(start=s, end=e, label=f'{name}()', cls='feature', group='', auto=False, protected=False, key=(0, max(times[s:e])),
                 why='0 call sites') for name, s, e in spans if _calls(name, rel) <= 1]

def _top_keys(raw):
    """(key, offset, value end) of each top-level key, parsed (a nested key of the same name is never taken)."""
    dec, ws, i, out = json.JSONDecoder(), re.compile(r'\s*'), raw.index('{') + 1, []
    while True:
        i = ws.match(raw, i).end()
        if raw[i] == '}':
            return out
        key, j = dec.raw_decode(raw, i)
        j = re.compile(r'\s*:\s*').match(raw, j).end()
        end = dec.raw_decode(raw, j)[1]
        out.append((key, i, end))
        i = re.compile(r'\s*,?').match(raw, end).end()

def _config(raw, L, rel):
    out = []
    others = {f: t for f, t in _texts().items() if f != rel}
    for key, at, end in _top_keys(raw):
        ls = raw.rfind('\n', 0, at) + 1
        if key.startswith('_') or raw[ls:at].strip() or any(key in t for t in others.values()):
            continue
        tail = re.match(r'[ \t]*,[ \t]*\r?\n', raw[end:])
        if tail:   # the last key (no comma after it) stays: its removal would leave a dangling comma above
            s, e = raw.count('\n', 0, at), raw.count('\n', 0, end) + 1
            out.append(dict(start=s, end=e, label=f'"{key}"', cls='feature', group='', auto=False, protected=False, key=(0, s), why='0 references'))
    return out

def _memory(L, path):
    out = []
    for i, l in enumerate(L):
        m = re.match(r'^- \[(.+?)\]\(([^)]+)\)', l)
        if not m:
            continue
        note = osp.join(osp.dirname(path), m.group(2))
        head = (re.match(r'^---\s*\n(.*?)\n---', read(note), re.S) if osp.isfile(note) else None) or None
        fm = dict(re.findall(r'(?m)^\s*(updated|type):\s*(\S+)', head.group(1))) if head else {}   # flat or nested (metadata:)
        when = str(fm.get('updated', ''))
        t = datetime.datetime.fromisoformat(when).timestamp() if re.match(r'\d{4}-\d\d-\d\d$', when) else osp.getmtime(note) if osp.isfile(note) else 0
        out.append(dict(start=i, end=i + 1, label=m.group(1), cls='content', group='', auto=False, key=(t,),
                        protected=str(fm.get('type', '')) in ('feedback', 'user'), why=f'updated {when or "?"}'))
    return out

def _prose(L):
    seen, out = set(), []
    for i, l in enumerate(L):
        k = re.sub(r'\W+', ' ', l).strip().lower()
        if not k:
            continue
        rank = 0 if k in seen else 1 if GEN.search(l) else 2
        seen.add(k)
        out.append(dict(start=i, end=i + 1, label=l.strip()[:60], cls='content', group='', auto=False, key=(rank, -i),
                        protected=bool(OWNER.search(l) or re.search(r'(?i)\b(?:never|must)\b', l)),
                        why=('duplicate', 'generated', 'written')[rank]))
    return out

# ---- plan: what to cut so the target fits
def plan(path, flags, now=None):
    """{'path','rel','kind','unit','cap','size','items','cut'} or {'error'}; groups (lesson sections) are planned one by one."""
    now = now or _now(flags)
    kind = _kind(path, flags)
    if not kind or not osp.isfile(path):
        return {'error': f'{path}: not a file this command can score (lessons, md, code, json, MEMORY.md, or --kind <prose kind>)'}
    rel = _rel(path)
    cap, unit = _cap(kind, rel, flags)
    if cap is None:
        return {'error': unit}
    raw = open(path, encoding='utf-8', newline='').read()
    L = raw.replace('\r\n', '\n').split('\n')
    times = _blame(path, len(L) - (L[-1] == ''), now) + [now] if kind in ('lessons', 'doc', 'code') else [now] * len(L)
    unused = int(flags.get('--unused-days') or UNUSED_DAYS)
    try:
        items = (_lessons(L, times, flags) if kind == 'lessons' else _sections(L, times, now, unused) if kind == 'doc'
                 else _code(L, rel or path, times) if kind == 'code' else _config(raw, L, rel) if kind == 'config'
                 else _memory(L, path) if kind == 'memory' else _prose(L))
    except (ValueError, SyntaxError, IndexError) as e:   # invalid JSON / code: nothing to score
        return {'error': f'{path}: cannot parse ({e})'}
    for x in items:
        x['cost'] = sum(_cost(kind, l + '\n') for l in L[x['start']:x['end']])
        x['text'] = '\n'.join(L[x['start']:x['end']])
    if kind == 'lessons':
        groups = {}
        for x in items:
            groups.setdefault(x['group'], []).append(x)
        size, cut = {g: len(v) for g, v in groups.items()}, []
        for g, v in groups.items():
            cut += _choose(v, size[g] - cap)
        return dict(path=path, rel=rel, kind=kind, unit=unit, cap=cap, size=max(size.values(), default=0), items=items, cut=cut, lines=L, raw=raw)
    size = (words('\n'.join(L)) if unit == 'w' else len(L) - (L[-1] == '') if unit == 'l'
            else size_tokens(KIT_DIR, rel) if rel else len('\n'.join(L).encode('utf-8')) // 4)   # README: graph blocks out, as lint
    return dict(path=path, rel=rel, kind=kind, unit=unit, cap=cap, size=size, items=items, cut=_choose(items, size - cap), lines=L, raw=raw)

def _choose(items, over):
    """Lowest key first, no overlapping spans, until `over` is freed; protected items never."""
    picked, freed = [], 0
    for x in sorted([x for x in items if not x['protected']], key=lambda x: x['key']):
        if freed >= over:
            break
        if any(x['start'] < p['end'] and p['start'] < x['end'] for p in picked):
            continue
        picked.append(x)
        freed += x['cost']
    return picked

def _applyable(p, x):
    """content inside the kit; memory indexes and produced texts (prose) are proposed only."""
    return x['cls'] == 'content' and x['auto'] and p['rel'] is not None and p['kind'] not in ('memory', 'prose')

# ---- archive: write, list, restore, retention, purge
def _adir(kind=''):
    d = kit_path('forgotten', create=True, kit=main_clone(KIT_DIR))   # the live clone's: a kit worktree's cut outlives the worktree
    return osp.join(d, kind) if kind else d

def _cut(p, xs, now):
    """Remove xs from the file (its line endings kept), archive each; -> ids."""
    eol = '\r\n' if '\r\n' in p['raw'] else '\n'
    L, ids, day = list(p['lines']), [], datetime.date.fromtimestamp(now).isoformat()
    os.makedirs(_adir(p['kind']), exist_ok=True)
    with open(osp.join(_adir(p['kind']), day + '.md'), 'a', encoding='utf-8') as fh:
        gone = {j for x in xs for j in range(x['start'], x['end'])}
        for x in sorted(xs, key=lambda x: -x['start']):   # anchor: the nearest line above that stays (a restore of one cut alone finds it)
            j = next((j for j in range(x['start'] - 1, -1, -1) if L[j].strip() and j not in gone), -1)
            at = j - len([g for g in gone if g < j]) if j >= 0 else -1   # the anchor's line once every cut is out
            xid = next_id(p['kind'])   # NO-DATE: <kind>-<nnnn>; the day file holds the time
            fh.write(f"## {xid}\n- file: {p['rel'] or p['path']}\n- at: {at}\n- after: {L[j] if j >= 0 else ''}\n- why: {x['why']}\n{FENCE}\n{x['text']}\n{FENCE}\n\n")
            del L[x['start']:x['end']]
            ids.append(xid)
    if p['raw'].endswith('\n') and (not L or L[-1] != ''):   # a cut of the last span keeps the final newline
        L.append('')
    with open(p['path'], 'w', encoding='utf-8', newline='') as fh:
        fh.write(eol.join(L))
    return ids

ENTRY = re.compile(r'^## (\S+)\n- file: ([^\n]*)\n- at: (-?\d+)\n- after: ([^\n]*)\n- why: ([^\n]*)\n' + FENCE + r'\n(.*?)\n' + FENCE + r'\n\n?', re.M | re.S)

def _entries():
    for kind in sorted(os.listdir(_adir())):
        d = _adir(kind)
        for f in sorted(os.listdir(d)) if kind != 'pending' and osp.isdir(d) else []:
            t = read(osp.join(d, f)).replace('\r\n', '\n')
            for m in ENTRY.finditer(t):
                yield kind, osp.join(d, f), m

def restore(xid, now):
    for kind, f, m in _entries():
        if m.group(1) != xid:
            continue
        path = m.group(2) if osp.isabs(m.group(2)) else osp.join(KIT_DIR, m.group(2))
        raw = open(path, encoding='utf-8', newline='').read() if osp.isfile(path) else ''
        eol = '\r\n' if '\r\n' in raw else '\n'
        L = raw.replace('\r\n', '\n').split('\n')
        was, after = int(m.group(3)), m.group(4)
        hits = [i for i, l in enumerate(L) if after and l == after]   # a repeated anchor (```, |---|): the one nearest its old line
        at = 0 if was < 0 else min(hits, key=lambda i: abs(i - was)) + 1 if hits else min(was + 1, len(L))
        L[at:at] = m.group(6).split('\n')
        with open(path, 'w', encoding='utf-8', newline='') as fh:
            fh.write(eol.join(L))
        rest = read(f).replace('\r\n', '\n').replace(m.group(0), '')
        if rest.strip():
            with open(f, 'w', encoding='utf-8') as fh:
                fh.write(rest)
        else:
            os.remove(f)
        k = _retention()
        r = k.setdefault(kind, {'days': MIN_DAYS, 'restores': 0})
        r.update(days=min(MAX_DAYS, max(MIN_DAYS, int(r.get('days', MIN_DAYS))) * 2), restores=int(r.get('restores', 0)) + 1, since=now)
        _retention(k)
        print(f'restored {xid} -> {m.group(2)}:{at + 1}; {kind} archive now kept {r["days"]} d')
        return 0
    print(f'forget --restore: no archived item {xid} (forget --list)', file=sys.stderr)
    return 1

def _retention(kinds=None):
    p = osp.join(_adir(), 'retention.json')   # {kinds: {<kind>: {days, restores, since}}}
    if kinds is None:
        return (state_read(p) or {}).get('kinds') or {}
    state_write(p, {'kinds': kinds})

def purge(now, dry):
    """Delete archive files older than their kind's days; a kind with no restore for a whole window halves its days."""
    kinds, gone = _retention(), []
    for kind in sorted(os.listdir(_adir())):
        if kind == 'pending' or not osp.isdir(_adir(kind)):
            continue
        r = kinds.setdefault(kind, {'days': MIN_DAYS, 'restores': 0, 'since': now})
        for f in sorted(os.listdir(_adir(kind))):
            m = re.match(r'(\d{4}-\d\d-\d\d)\.md$', f)
            if m and (now - datetime.datetime.fromisoformat(m.group(1)).timestamp()) / 86400 > r['days']:
                gone.append(f'{kind}/{f}')
                if not dry:
                    os.remove(osp.join(_adir(kind), f))
        if r['days'] > MIN_DAYS and (now - float(r.get('since') or now)) / 86400 >= r['days']:
            r.update(days=max(MIN_DAYS, r['days'] // 2), since=now)
    if not dry:
        _retention(kinds)
        if gone:
            kitlog('calls', 'forget-purge', {'deleted': gone})
    for g in gone:
        print(f'{"would delete" if dry else "deleted"} {g}')
    print(f'purge: {len(gone)} archive file(s); retention ' + (', '.join(f'{k} {v["days"]} d' for k, v in sorted(kinds.items())) or f'default {MIN_DAYS} d'))
    return 0

# ---- command
def _show(p, out):
    for x in p['cut']:
        mode = 'APPLY' if _applyable(p, x) else 'CONFIRM' if x['cls'] == 'feature' else 'PROPOSE'
        out.append(f"FORGET {mode} {p['rel'] or p['path']}:{x['start'] + 1} {x['label']} ({x['why']}, -{x['cost']}{p['unit']})")

def _batch(p, xs, now):
    path = osp.abspath(p['path'])
    b = next_id('fb')   # NO-DATE: fb-<nnnn>; the batch file keeps path and items
    state_write(osp.join(_adir('pending'), b + '.json'), {'batch': b, 'path': path, 'kind': p['kind'],
                'items': [{'text': x['text'], 'why': x['why'], 'label': x['label']} for x in xs]})
    names = ', '.join(x['label'] for x in xs)[:200]
    who = kit_who().get('agent') or 'kitty'
    print(f'BATCH {b}: {len(xs)} feature(s) wait for the owner. Ask once: & <kit>/skills/bossy/bossy.ps1 decide ask -Agent {who} -Item forget-{b} '
          f'-Context "{p["rel"] or p["path"]} is over its cap; no call site uses them" -Question "Forget {len(xs)} unused feature(s): {names}?" '
          '-Options "yes: forget them — archived and restorable, the file gets room","no: keep them — the file stays over its cap" -Recommend yes')
    print(f'then: python -X utf8 <kit>/skills/bossy/kitbag.py forget --confirm {b} --decision <id>')

def confirm(b, did, now):
    pf = osp.join(_adir('pending'), b + '.json')
    batch = state_read(pf)
    if not batch or not did:
        print(f'forget --confirm: no pending batch {b} or no --decision', file=sys.stderr)
        return 2
    ans, rec = None, None
    logs = dict.fromkeys([log_file('decisions-log'), kit_path('decisions-log', kit=main_clone(KIT_DIR))])   # a kit worktree: the live clone's decisions
    for lf in [x for x in logs if osp.isfile(x)]:
        for l in open(lf, encoding='utf-8').read().splitlines():
            with contextlib.suppress(ValueError):
                o = json.loads(l)
                if o.get('id') == did and o.get('event') == 'answered':
                    rec, ans = o, str(o.get('answer', ''))
    if ans is None:
        print(f'forget --confirm: decision {did} has no answer yet (decide wait); nothing removed')
        return 1
    names = ','.join(re.sub(r'[^\w,-]', '', it['label']) for it in batch['items'])   # forget-<batch> or forget-<the features it names>
    if rec.get('item') not in (f'forget-{b}', f'forget-{names}') or str(rec.get('by') or 'owner').lower() != 'owner':   # this batch's ask, the owner's word
        print(f'forget --confirm: {did} is not the owner\'s answer to forget-{b} (item {rec.get("item")}, by {rec.get("by")}); nothing removed')
        return 1
    if not re.match(r'(?i)\s*(?:yes|y|approved?|confirm(?:ed)?)\b(?!\s+nothing)', ans):
        os.remove(pf)
        print(f'kept: the owner answered "{ans}"; batch {b} dropped')
        return 0
    raw = open(batch['path'], encoding='utf-8', newline='').read()
    L = raw.replace('\r\n', '\n').split('\n')
    xs = []
    for it in batch['items']:
        n = len(it['text'].split('\n'))
        at = [i for i in range(len(L)) if '\n'.join(L[i:i + n]) == it['text']]
        if len(at) != 1:
            print(f'forget --confirm: {it["label"]} changed since the ask ({len(at)} matches); ask again', file=sys.stderr)
            return 1
        xs.append(dict(start=at[0], end=at[0] + n, text=it['text'], why=it['why'] + ', owner yes ' + did))
    ids = _cut(dict(path=batch['path'], rel=_rel(batch['path']), kind=batch['kind'], lines=L, raw=raw), xs, now)
    os.remove(pf)
    print(f'forgot {len(ids)} feature(s): {", ".join(ids)} (forget --restore <id>)')
    return 0

def cmd_forget(a):
    flags, rest = parse_opts(a, {'--target', '--section', '--to', '--kind', '--restore', '--confirm', '--decision', '--now', '--unused-days'})
    now = _now(flags)
    if flags.get('--restore'):
        return restore(flags['--restore'], now)
    if flags.get('--confirm'):
        return confirm(flags['--confirm'], flags.get('--decision'), now)
    if '--purge' in flags:
        return purge(now, '--dry-run' in flags)
    if '--list' in flags:
        for kind, f, m in _entries():
            print(f'{m.group(1)}  {m.group(2)}  {m.group(5)}  ({osp.basename(f)})')
        return 0
    t = flags.get('--target')
    if not isinstance(t, str):
        print(__doc__, file=sys.stderr)
        return 2
    paths = (over_cap() if t == 'over-cap' else [osp.join(KIT_DIR, 'LESSONS.md')] if t == 'lessons'
             else [memory_index()] if t == 'memory' else [osp.abspath(t) if osp.isabs(t) or osp.isfile(t) else osp.join(KIT_DIR, t)])
    apply, rc, out, summary = '--apply' in flags and '--dry-run' not in flags, 0, [], []
    for path in [x for x in paths if x]:
        p = plan(path, flags, now)
        if 'error' in p:
            print(f'forget: {p["error"]}', file=sys.stderr)
            return 2
        _show(p, out)
        left = p['size'] - sum(x['cost'] for x in p['cut']) if p['kind'] != 'lessons' else p['size'] - len(p['cut'])
        if apply:
            done = [x for x in p['cut'] if _applyable(p, x)]
            ids = _cut(p, done, now) if done else []
            feats = [x for x in p['cut'] if x['cls'] == 'feature']
            if feats:
                _batch(p, feats, now)
            out.append(f"FORGOT {p['rel'] or p['path']}: {len(ids)} item(s) archived{': ' + ', '.join(ids) if ids else ''}")
            p['removed'] = [x['text'] for x in done]
        rc = max(rc, 1 if p['size'] > p['cap'] and (left > p['cap'] or not apply or any(not _applyable(p, x) for x in p['cut'])) else 0)
        summary.append(dict(file=p['rel'] or p['path'], kind=p['kind'], size=p['size'], cap=p['cap'], unit=p['unit'],
                            cut=[dict(line=x['start'] + 1, label=x['label'], why=x['why'], mode='apply' if _applyable(p, x) else x['cls'])
                                 for x in p['cut']], removed=p.get('removed', [])))
        out.append(f"{p['rel'] or p['path']}: {p['size']}/{p['cap']}{p['unit']}, {len(p['cut'])} candidate(s) -> {max(left, 0)}{p['unit']}")
    if '--json' in flags:
        print(json.dumps(summary, ensure_ascii=False))
    else:
        print('\n'.join(out) or 'forget: nothing over its cap')
    return rc

def over_cap():
    """Every kit file over its BUDGETS cap, LESSONS files with a section over 40, the memory index over its lines."""
    out = [osp.join(KIT_DIR, f) for f in counted_files(KIT_DIR) if (b := budget_type(f)) and size_tokens(KIT_DIR, f) > BUDGETS[b] and b != 'lessons']
    for f in ('LESSONS.md', 'LESSONS.local.md'):
        t = read(osp.join(KIT_DIR, f)) if osp.isfile(osp.join(KIT_DIR, f)) else ''
        if any(len([l for l in m.group(1).splitlines() if l.startswith('- ')]) > LESSON_CAP for m in re.finditer(r'^## \S+\n(.*?)(?=^## |\Z)', t, re.S | re.M)):
            out.append(osp.join(KIT_DIR, f))
    mi = memory_index()
    if mi and len(read(mi).splitlines()) > MEMORY_CAP:
        out.append(mi)
    return out

# ---- hooks: lint BUDGET / LESSONS-CAP and prose print the forget candidates
def lint_hook(k, problems, flags):
    for n, (code, where, msg) in enumerate(list(problems)):
        if code not in ('BUDGET', 'LESSONS-CAP'):
            continue
        try:
            f = 'LESSONS.md' if code == 'LESSONS-CAP' else where
            sec = {'--section': where.split('## ', 1)[1]} if code == 'LESSONS-CAP' else {}
            p = plan(osp.join(k.dir, f), sec) if osp.isfile(osp.join(k.dir, f)) else None
            if p and p.get('cut'):
                problems[n] = (code, where, msg + f' · forget first: {"; ".join(x["label"][:40] for x in p["cut"][:3])} (kitbag.py forget --target {f})')
        except Exception:   # a hint: never fail the lint
            pass

def cmd_prose_forget(a):
    rc = cmd_prose(a)
    flags, files = parse_opts(a, {'--kind'})
    if rc == 1 and '--json' not in flags and files and files[0] != '-' and isinstance(flags.get('--kind'), str):
        p = plan(files[0], {'--kind': flags['--kind']})
        if 'error' not in p and p['size'] > p['cap']:
            out = []
            _show(p, out)
            print('\n'.join(out))
    return rc

COMMANDS = {'forget': cmd_forget, 'prose': cmd_prose_forget}
ARGS = {'forget': ({'--apply', '--dry-run', '--json', '--list', '--purge'}, {'--target', '--section', '--to', '--kind', '--restore', '--confirm', '--decision', '--now', '--unused-days'}, False)}
