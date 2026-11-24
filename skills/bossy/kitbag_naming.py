"""kitbag_naming.py (plugin): one naming standard for work items, docs, runs, agents and git names (kit.local.json `naming`).

  python -X utf8 skills/bossy/kitbag.py naming check <kind> <name> [<name> ...]   # exit 1 names each one off the standard + its pattern
  python -X utf8 skills/bossy/kitbag.py naming next key <PRODUCT> <AREA>           # the next <PRODUCT>-<AREA>-<nnn> (locked counter)
  python -X utf8 skills/bossy/kitbag.py naming next id <kind>                      # <kind>-<YYYYMMDD>-<nn>: run (buildy, testy, kit ..), dec, fix
  python -X utf8 skills/bossy/kitbag.py naming make <kind> key=<KEY> type=<t> ...  # a name from its parts (title doc branch mr case item)
  python -X utf8 skills/bossy/kitbag.py naming scan [--json]                       # live names (tasks, docs, board, launches) vs the standard
  python -X utf8 skills/bossy/kitbag.py naming rename --plan <plan.json> [--json]  # old codes -> new keys: a dry run table, never applied here
  python -X utf8 skills/bossy/kitbag.py naming seed <PRODUCT-AREA> <n>          # after an applied rename: next key is n+1
Kinds: key `SHOP-CAT-004` · item `SHOP-CAT-004.2 add-price-projection` · title `SHOP-CAT-004 [Feature] Catalogue: <outcome>`
 · doc `SHOP-CAT-004 Spec v3 — <title>` · run `buildy-20261123-01` · agent `devy-01` · area `area-CAT` (`-2`: a second one
   in a run) · lane `lane-01`
 · branch `feat/SHOP-CAT-004-public-catalogue` · mr `feat(web): <summary> [SHOP-CAT-004]` · case `SHOP-CAT-004-TC03` · id `dec-20261123-01`.
PRODUCT / AREA: 2-6 capitals registered in naming.products / naming.areas ({code: name}); an unknown code or a key without
one is refused. A tracker with native ids keeps them as the link; the kit key lives in the title prefix and a field.
DUP-WORDS: a name never repeats what its key or type says (product, a leading area word, a [Type] tag, a repo list); make and
rename strip them.
Exit codes: 0 ok · 1 names off the standard · 2 usage error.
Sections: L24 model · L80 no repeats
"""
import json, os, re, sys, time
import os.path as osp

# ---- model: registries, patterns, counters
TYPES = ('feat', 'fix', 'refactor', 'chore', 'docs', 'test', 'perf', 'spike')
TITLE_TYPES = ('Feature', 'Bug', 'Chore', 'Spike')
DOC_KINDS = ('Spec', 'Brief', 'Testing goals', 'Testing doc', 'Testing doc (AI)', 'QA report', 'Retro', 'Runbook')


def naming_cfg(kit=None):
    c = local_config(kit or KIT_DIR, 'kit.local.json').get('naming') or {}
    codes = lambda k: {str(x).upper(): str(v) for x, v in (c.get(k) or {}).items() if re.match(r'^[A-Za-z]{2,6}$', str(x))}
    return {'products': codes('products'), 'areas': codes('areas'), 'digits': int(c['digits']) if str(c.get('digits') or '').isdigit() else 3}   # a bad value: the default


def patterns(cfg):
    """{kind: regex}; PRODUCT / AREA alternations come from the registries (an empty one matches nothing)."""
    alt = lambda d: '|'.join(sorted(map(re.escape, d), key=len, reverse=True)) or '(?!)'
    key = rf'(?:{alt(cfg["products"])})-(?:{alt(cfg["areas"])})-\d{{{cfg["digits"]},}}'
    ty, slug = '|'.join(TYPES), r'[a-z0-9]+(?:-[a-z0-9]+)*'
    return {'key': rf'^{key}$', 'item': rf'^{key}\.\d+ {slug}$', 'case': rf'^{key}-TC\d{{2,}}$',
            'title': rf'^{key}(?:\.\d+)? \[(?:{"|".join(TITLE_TYPES)})\] [^:]+: \S.*$',
            'doc': rf'^{key}(?:\.\d+)? (?:{"|".join(map(re.escape, DOC_KINDS))}) v\d+ — \S.*$',
            'run': r'^[a-z]+(?:-[a-z]+)*-\d{8}-\d{2,}$', 'id': r'^[a-z]+-\d{8}-\d{2,}$', 'agent': r'^[a-z]+-\d{2,}$',
            'area': rf'^area-(?:{alt(cfg["areas"])})(?:-\d+)?$', 'lane': r'^lane-\d{2,}$',
            'branch': rf'^(?:{ty})/{key}-{slug}$', 'mr': rf'^(?:{ty})(?:\([\w./-]+\))?!?: \S.* \[{key}\]$'}


def name_problem(kind, name, cfg=None):
    """'' when <name> fits <kind>, else why (an unknown PRODUCT / AREA code named)."""
    cfg = cfg or naming_cfg()
    rx = patterns(cfg).get(kind)
    if rx is None:
        return f'unknown kind {kind!r} ({", ".join(patterns(cfg))})'
    if re.match(rx, name):
        return dup_words(kind, name, cfg)
    m = re.search(r'\b([A-Z]{2,6})-([A-Z]{2,6})-\d+', name)
    need = cfg['areas'] if kind == 'area' else cfg['products'] and cfg['areas']   # an area name needs only the areas
    if kind in ('key', 'item', 'case', 'title', 'doc', 'branch', 'mr', 'area') and not need:
        return 'naming.products / naming.areas are empty: register the codes in kit.local.json first'
    if m and m[1] not in cfg['products']:
        return f'unknown PRODUCT {m[1]} (naming.products: {", ".join(cfg["products"]) or "none"})'
    if m and m[2] not in cfg['areas']:
        return f'unknown AREA {m[2]} (naming.areas: {", ".join(cfg["areas"]) or "none"})'
    if kind == 'area' and (a := re.match(r'^area-([A-Z]+)', name)) and a[1] not in cfg['areas']:
        return f'unknown AREA {a[1]}'
    return f'not {kind} form ({EXAMPLES[kind]})'


EXAMPLES = {'key': 'SHOP-CAT-004', 'item': 'SHOP-CAT-004.2 add-price-projection', 'case': 'SHOP-CAT-004-TC03',
            'title': 'SHOP-CAT-004 [Feature] Catalogue: <outcome>', 'doc': 'SHOP-CAT-004 Spec v3 — <title>',
            'run': 'buildy-20261123-01', 'id': 'dec-20261123-01', 'agent': 'devy-01', 'area': 'area-CAT', 'lane': 'lane-01',
            'branch': 'feat/SHOP-CAT-004-public-catalogue', 'mr': 'feat(web): <summary> [SHOP-CAT-004]'}


def slugify(text, words=6):
    return '-'.join(re.findall(r'[a-z0-9]+', str(text).lower())[:words])


# ---- no repeats: the key carries PRODUCT and AREA, the tag carries the type; a name never says them twice (owner, 2026-11-23)
REPO_LIST = r'\s*\([a-z][\w.-]*(?:\s*,\s*[a-z][\w.-]*)*\)\s*$'   # a trailing "(api, web)": repos belong in the MR, not the name
KIND_WORDS = {'feat': 'feature', 'fix': 'bug', 'feature': 'feat', 'bug': 'fix'}


def carried(key, cfg, ty=''):
    """(words said anywhere: product code + name; leading [(words, needs a ':' after)]: area code + name, the type; a multi-word
    area name said anywhere) for a key. A work type word leads only as a label ("Bug: x"): "Bug report ..." is a noun."""
    m = re.match(r'([A-Z]{2,6})-([A-Z]{2,6})-\d+', str(key or ''))
    if not m:
        return set(), [], []
    words = lambda s: re.findall(r'[a-z0-9]+', str(s).lower())
    ty = str(ty or '').lower()
    an = words(cfg['areas'].get(m[2], ''))
    lab = ty in KIND_WORDS or ty in (t.lower() for t in TITLE_TYPES + TYPES)
    lead = [(an, False), ([m[2].lower()], True)] +[([w], False) for w in an if len(an) > 1 and len(w) > 3] + \
        [(w, lab) for w in ([words(ty), [KIND_WORDS[ty]]] if ty in KIND_WORDS else [words(ty)] if ty else [])]
    return {m[1].lower(), *words(cfg['products'].get(m[1], ''))}, [x for x in lead if x[0]], [an] if len(an) > 1 else []


def clean(text, key, cfg, ty=''):
    """<text> without what <key> / <ty> already says: product words anywhere, a leading area or type word, a type tag, a repo list."""
    anywhere, lead, phrases = carried(key, cfg, ty)
    t = re.sub(REPO_LIST, '', str(text or ''))
    t = re.sub(rf'\[(?:{"|".join(TITLE_TYPES)})\]\s*', '', t, flags=re.I)
    t = re.sub(r'\b[A-Z]{2,6}-[A-Z]{2,6}-\d+(?:\.\d+)?\b', '', t)   # the key itself
    for ws in phrases:   # "Create customer via Ask Shop: ..." under area "Ask Shop" -> "Create customer: ..."
        t = re.sub(r'(?i)(?:\s+(?:via|in|on|with|from|through|using))?\s*(?<![a-z0-9])' + r'[\s-]+'.join(map(re.escape, ws)) + r'(?![a-z0-9])', ' ', t)
    for w in anywhere:
        t, n = re.subn(rf'(?i)(?<![a-z0-9]){re.escape(w)}(?![a-z0-9])', '', t)
        t = re.sub(r'(?i)\s+(?:in|on|for|of|to|at)(?=\s*(?:\(was [^)]*\))?$)', '', t.rstrip()) if n else t   # "queue in RM" -> "queue"
    t = re.sub(r'\s+([:;,)])', r'\1', re.sub(r'^[\s:;,—–-]+', '', re.sub(r'\s{2,}', ' ', t))).strip()
    changed = True
    while changed:   # leading carried words, in any order (Catalogue catalogue-blocks, Feature: ...)
        changed = False
        for ws, colon in lead:
            sp = lambda w: re.escape(w[:-1] if w.endswith('s') and len(w) > 3 else w) + 's?'   # Accounts / Account
            m = re.match(r'(?i)' + r'[\s:—–-]+'.join(map(sp, ws)) + (r'\s*:[\s—–-]*' if colon else r'(?![a-z0-9])[\s:;,—–-]*'), t)
            if m and t[m.end():].strip():
                t, changed = re.sub(r'(?i)^(?:for|of|on|about|by)\s+(?=\S)', '', t[m.end():]), True   # "Spec of the page" -> "the page"
    return t.strip()


def dup_words(kind, name, cfg):
    """'' or 'DUP-WORDS ...': the free text of a standard <name> repeats its product, area, type or repos."""
    km = re.search(r'[A-Z]{2,6}-[A-Z]{2,6}-\d+', name)
    if not km or kind not in ('title', 'doc', 'branch', 'mr', 'item'):
        return ''
    key = km[0]
    if kind == 'title':
        free, ty = name.split('] ', 1)[1], re.search(r'\[(\w+)\]', name)[1]
        head, _, free = free.partition(': ')
        if (a := cfg['areas'].get(key.split('-')[1], '')) and head.strip().lower() != a.lower():
            return f'DUP-WORDS: "{head}" before ":" is the area name {a!r} only (the key carries the product)'
    elif kind == 'doc':
        ty, free = '', name.split(' — ', 1)[1]
        ty = next((k for k in DOC_KINDS if name[len(key):].strip().startswith(k)), '')
    elif kind == 'branch':
        ty, free = name.split('/', 1)[0], name.split(key, 1)[1].replace('-', ' ')
    elif kind == 'mr':
        ty, free = re.match(r'\w+', name)[0], re.sub(rf'\s*\[{key}\]$', '', name.split(': ', 1)[1])
    else:
        ty, free = '', name.split(' ', 1)[1].replace('-', ' ')
    c = clean(free, key, cfg, ty)
    if re.sub(r'\W+', ' ', c).strip().lower() != re.sub(r'\W+', ' ', free).strip().lower():
        gone = [w for w in re.findall(r'[\w-]+', free) if w.lower() not in re.findall(r'[\w-]+', c.lower())]
        return f'DUP-WORDS: repeats {" ".join(gone) or "a repo list"} (the key / type already say it): {c!r}'
    return ''


def make(kind, p, cfg=None):
    """A name from its parts, free text cleaned of what the key / type say: title (key type outcome; area from the key) · doc (key
    kind ver title) · branch (type key slug tag?) · mr (type scope summary key) · case (key n) · item (key m slug)."""
    cfg = cfg or naming_cfg()
    g = lambda k, d='': str(p.get(k) or d)
    key = g('key')
    ac = (key.split('-') + ['', ''])[1] or g('area').upper()
    area = cfg['areas'].get(ac, g('area'))
    cl = lambda t, ty='': clean(t, key, cfg, ty)
    tag = slugify(g('tag'), 3)   # a tracker's native branch tag (CU-<id>): kept so its links and the kit's branch parsers still match
    out = {'title': lambda: f'{key} [{g("type", "Feature")}] {area}: {cl(g("outcome"), g("type", "Feature"))}',
           'doc': lambda: f'{key} {g("kind", "Spec")} v{g("ver", "1")} — {cl(g("title"), g("kind", "Spec"))}',
           'branch': lambda: f'{g("type", "feat")}/{key}-' + '-'.join(x for x in (tag, slugify(cl(g("slug") or g("title"), g("type", "feat")))) if x),
           'mr': lambda: f'{g("type", "feat")}{"(" + g("scope") + ")" if g("scope") else ""}: {cl(g("summary"), g("type", "feat"))} [{key}]',
           'case': lambda: f'{key}-TC{int(g("n", "1")):02d}', 'item': lambda: f'{key}.{g("m", "1")} {slugify(cl(g("slug")))}'}
    if kind not in out:
        raise SystemExit(f'naming make: kind {kind!r} ({", ".join(out)})')
    return out[kind]()


def _counter(group):
    """The next number of a counter group under its lock (.state naming.json: {group: last})."""
    f = kit_path('naming', create=True)
    with locked(f):
        x = state_read(f) or {}
        x[group] = int(x.get(group) or 0) + 1
        state_write(f, x)
        return x[group]


def next_key(product, area, cfg=None):
    cfg = cfg or naming_cfg()
    product, area = product.upper(), area.upper()
    for code, reg, what in ((product, cfg['products'], 'PRODUCT'), (area, cfg['areas'], 'AREA')):
        if code not in reg:
            raise SystemExit(f'naming next key: unknown {what} {code} (naming.{what.lower()}s in kit.local.json: {", ".join(reg) or "none"})')
    return f'{product}-{area}-{_counter(f"key:{product}-{area}"):0{cfg["digits"]}d}'


def next_id(kind):
    if not re.match(r'^[a-z]+(?:-[a-z]+)*$', kind):
        raise SystemExit(f'naming next id: kind {kind!r}: lowercase words joined by -')
    day, live = time.strftime('%Y%m%d', time.gmtime()), board_live('run')
    for _ in range(100):   # a reset counter never hands out a run id live on the board
        rid = f'{kind}-{day}-{_counter(f"id:{kind}:{day}"):02d}'
        if rid not in live:
            return rid
    raise SystemExit(f'naming next id: 100 {kind} ids of {day} live on the board')


def board_live(field):
    """{field value} of the board rows not left (board join, kitbag.py naming next id)."""
    d, out = kit_path('board'), set()
    for f in (osp.join(d, n) for n in os.listdir(d) if n.endswith('.json')) if os.path.isdir(d) else []:
        row, err = load_json(f)
        if not err and isinstance(row, dict) and row.get('status') != 'left' and row.get(field):
            out.add(str(row[field]))
    return out


# ---- commands
def live_names(kit=None):
    """[(kind, name, where)] the kit holds now: tracked task names and keys, published doc titles, board agents and runs."""
    out = []
    tr = (read_tracking() or {}).get('tasks') or {}
    for tid, t in tr.items():
        if isinstance(t, dict) and t.get('name'):
            out.append(('title', str(t['name']), f'tracking {tid}'))
    pub = kit_path('published')
    for fn in sorted(os.listdir(pub)) if osp.isdir(pub) else []:
        r = state_read(osp.join(pub, fn)) or {}
        if r.get('title') and r.get('key'):
            out.append(('doc', str(r['title']), f'published {r["key"]}'))
    return out


def plan_rows(plan, cfg):
    """A rename plan: {product, area (default), products?, areas? (codes proposed for kit.local.json naming), start? {"SHOP-CAT": 3},
    items: [{code, id, title, area?, type?, outcome?}]} -> rows old code -> new key / title (dry). A title already keyed keeps its key
    (a re-run over renamed tasks); its words repeated from the key are a problem."""
    rows, seq = [], {}
    cfg = {**cfg, **{k: {**cfg[k], **{str(c).upper(): v for c, v in (plan.get(k) or {}).items()}} for k in ('products', 'areas')}}
    for it in plan.get('items') or []:
        old, code = str(it.get('title') or ''), str(it.get('code') or '')
        km = re.match(r'([A-Z]{2,6})-([A-Z]{2,6})-(\d+)\s+(?:\[(\w+)\]\s*)?', old)
        prod = str(it.get('product') or (km and km[1]) or plan.get('product') or '').upper()
        area = str(it.get('area') or (km and km[2]) or plan.get('area') or '').upper()
        bad = [f'unknown PRODUCT {prod}'] if prod not in cfg['products'] else []
        bad += [f'unknown AREA {area}'] if area not in cfg['areas'] else []
        if km:   # already renamed: same key, the outcome after "<area>: "
            key, rest = km[0].split()[0], old[km.end():]
            rest = rest.split(': ', 1)[1] if ': ' in rest else rest
            bad += [f'old title {w}' for w in [name_problem('title', old, cfg)] if w.startswith('DUP-WORDS')]
        else:
            base = int(plan.get('start', {}).get(f'{prod}-{area}', 0)) if isinstance(plan.get('start'), dict) else 0
            seq[(prod, area)] = seq.get((prod, area), base) + 1
            key, rest = f'{prod}-{area}-{seq[(prod, area)]:0{cfg["digits"]}d}', old.split(f' {code} ', 1)[-1] if code else old
        rest = re.sub(r'\s*\(was [^)]*\)\s*$', '', rest)
        outcome = it.get('outcome') or re.sub(r'^\s*v\d+\s+', '', re.sub(REPO_LIST, '', rest)).strip()
        ty = it.get('type') or (km and km[4]) or (re.match(rf'\s*\[({"|".join(TITLE_TYPES)})\]', old) or [None, 'Feature'])[1]
        title = make('title', {'key': key, 'type': ty, 'outcome': outcome}, cfg)
        title += f' (was {code})' if code and code != key else ''
        rows.append({'old': code, 'id': it.get('id', ''), 'oldTitle': old, 'key': key, 'title': title, 'problems': bad})
    return rows


def cmd_naming(rest):
    a = [x for x in rest if not x.startswith('--')]
    js = '--json' in rest
    cfg = naming_cfg()
    if not a or a[0] in ('help', '-h') or '--help' in rest:
        print(__doc__)
        return 0 if (not a or a[0] in ('help', '-h') or '--help' in rest) else 2
    verb = a[0]
    if verb == 'check' and len(a) >= 3:
        bad = [(n, w) for n in a[2:] if (w := name_problem(a[1], n, cfg))]
        print('\n'.join(f'NAME {a[1]} {n!r}: {w}' for n, w in bad) or f'naming: {len(a) - 2} {a[1]} name(s) fit the standard')
        return 1 if bad else 0
    if verb == 'next' and len(a) >= 3 and a[1] in ('key', 'id'):
        print(next_key(a[2], a[3] if len(a) > 3 else '', cfg) if a[1] == 'key' else next_id(a[2]))
        return 0
    if verb == 'make' and len(a) >= 2:
        try:
            n = make(a[1], dict(x.split('=', 1) for x in a[2:] if '=' in x), cfg)
        except ValueError as e:   # a non-number n / m
            print(f'naming make {a[1]}: {e}', file=sys.stderr)
            return 2
        if a[1] in patterns(cfg) and (w := name_problem(a[1], n, cfg)):   # a made name obeys its own check
            print(f'NAME {a[1]} {n!r}: {w}', file=sys.stderr)
            return 1
        print(n)
        return 0
    if verb == 'seed' and len(a) == 3 and a[2].isdigit():   # after an applied rename: the counter starts past the migrated keys
        f = kit_path('naming', create=True)
        with locked(f):
            x = state_read(f) or {}
            x[f'key:{a[1].upper()}'] = max(int(x.get(f'key:{a[1].upper()}') or 0), int(a[2]))
            state_write(f, x)
        print(f'naming {a[1].upper()}: next key after {a[2]}')
        return 0
    if verb == 'scan':
        bad = [(k, n, w, why) for k, n, w in live_names() if (why := name_problem(k, n, cfg))]
        if js:
            print(json.dumps([{'kind': k, 'name': n, 'where': w, 'why': y} for k, n, w, y in bad], ensure_ascii=False, indent=1))
        else:
            print('\n'.join(f'WARN NAME {w}: {k} {n!r}: {y}' for k, n, w, y in bad[:60]) + (f'\n... {len(bad) - 60} more (--json)' if len(bad) > 60 else '')
                  if bad else 'naming scan: every live name fits the standard')
        return 1 if bad else 0
    if verb == 'rename' and '--plan' in rest:
        p = rest[rest.index('--plan') + 1] if rest.index('--plan') + 1 < len(rest) else ''
        plan = load_json(p)[0] if p and osp.isfile(p) else None
        if not isinstance(plan, dict):
            print(f'naming rename --plan <plan.json>: {p or "no file"} is no JSON object', file=sys.stderr)
            return 2
        rows = plan_rows(plan, cfg)
        if js:
            print(json.dumps(rows, ensure_ascii=False, indent=1))
        else:
            print('| Old code | Tracker id | Old title | New key | New title | Problems |\n|---|---|---|---|---|---|')
            for r in rows:
                print('| ' + ' | '.join(str(r[k]).replace('|', '\\|') for k in ('old', 'id', 'oldTitle', 'key', 'title')) + f' | {"; ".join(r["problems"]) or "—"} |')
            top = {}
            for r in rows:
                g, n = r['key'].rsplit('-', 1)
                top[g] = max(top.get(g, 0), int(n))
            print('DRY RUN: nothing renamed; the old code stays searchable (a tracker field / the title suffix) when applied. After applying: '
                  + '; '.join(f'kitbag.py naming seed {g} {n}' for g, n in top.items()))
        return 1 if any(r['problems'] for r in rows) else 0
    print(__doc__, file=sys.stderr)
    return 2


FILE_RX = {'.py': r'^[a-z][a-z0-9_]*\.py$', '.ps1': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.tests)?\.ps1$', '.mjs': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*\.mjs$',
           '.js': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*\.js$'}
BAK_RX = re.compile(r'\.(?:bak|bad|orig|old|stale)(?:[-.]|$)', re.I)
HOOK_CFG = ('settings.json', '.agents/hooks.json', '.codex/config.toml')


def hook_entry_names(kd, files):
    """Script basenames the hook configs call, and the scripts those name: a rename would cut running sessions off their guard."""
    rx = re.compile(r'[\w.-]+\.(?:ps1|mjs|js|py)')
    names, todo = set(), [c for c in HOOK_CFG if c in files]
    by_name = {osp.basename(f): f for f in files}
    while todo:
        p = osp.join(kd, todo.pop())
        try:
            txt = open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for n in set(rx.findall(txt)) - names:
            if '_' in n and n in by_name:
                names.add(n)
                todo.append(by_name[n])
    return names


def lint_hook(k, problems, flags):
    """NAME-CONFIG: a naming registry entry that is no 2-6 letter code (the live names: `naming scan`, WARN-level).
    NAME-FILE: a script name off its language's rule (py snake_case; ps1 / mjs / js kebab-case), except hook entry points (hook_entry_names)."""
    c = local_config(k.dir, 'kit.local.json').get('naming') or {}
    for reg in ('products', 'areas'):
        for code in (c.get(reg) or {}):
            if not re.match(r'^[A-Z]{2,6}$', str(code)):
                problems.append(('NAME-CONFIG', 'kit.local.json', f'naming.{reg} code {code!r}: 2-6 capital letters'))
    kf = getattr(k, 'files', None) or []   # a plugin caller may pass only dir
    ex = hook_entry_names(k.dir, set(kf))
    problems += [('NAME-FILE', f, f'{osp.basename(f)}: {"snake_case" if f.endswith(".py") else "kebab-case"} for {osp.splitext(f)[1]} files')
                 for f in kf if re.match(r'(?:skills|workflows|tests)/', f) and osp.splitext(f)[1] in FILE_RX
                 and not re.match(FILE_RX[osp.splitext(f)[1]], osp.basename(f)) and osp.basename(f) not in ex]


def warn_hook(k):
    """NAME-BACKUP: a backup beside the live config other than `<file>.bak-<yyyyMMdd-HHmmss>` (Get-KitStamp file)."""
    out = []
    for base in {k.dir, main_clone(k.dir)}:
        for d in sorted(os.listdir(osp.join(base, 'skills'))) if osp.isdir(osp.join(base, 'skills')) else []:
            sd = osp.join(base, 'skills', d)
            out += [('NAME-BACKUP', f'skills/{d}/{n}', 'one backup form, <file>.bak-<yyyyMMdd-HHmmss> (Get-KitStamp file); or move it to .state/backups/')
                    for n in sorted(os.listdir(sd)) if BAK_RX.search(n) and not re.search(r'\.bak-\d{8}-\d{6}$', n) and osp.isfile(osp.join(sd, n))]
    return out


COMMANDS = {'naming': cmd_naming}
ARGS = {'naming': ({'--json', '--help'}, {'--plan'}, False)}
