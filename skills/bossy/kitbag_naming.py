"""kitbag_naming.py (plugin): one naming standard for work items, docs, runs, agents and git names (kit.local.json `naming`).

  python -X utf8 skills/bossy/kitbag.py naming check <kind> <name> [<name> ...]   # exit 1 names each one off the standard + its pattern
  python -X utf8 skills/bossy/kitbag.py naming next key <PRODUCT> <AREA>           # the next <PRODUCT>-<AREA>-<nnn> (locked counter)
  python -X utf8 skills/bossy/kitbag.py naming next id <kind>                      # <kind>-<nnnn>: run (buildy, testy, kitty-fix ..), dec; one locked counter per kind
  python -X utf8 skills/bossy/kitbag.py naming make <kind> key=<KEY> type=<t> ...  # a name from its parts (title doc branch mr case item)
  python -X utf8 skills/bossy/kitbag.py naming scan [--json]                       # live names (tasks, docs, board, launches) vs the standard
  python -X utf8 skills/bossy/kitbag.py naming rename --plan <plan.json> [--json]  # old codes -> new keys: a dry run table, never applied here
  python -X utf8 skills/bossy/kitbag.py naming seed <PRODUCT-AREA> <n>          # after an applied rename: next key is n+1
  python -X utf8 skills/bossy/kitbag.py naming tags [--have a,b] key=<KEY> kind=bug wave=2 env=- ...   # JSON {tags, add, remove}
Kinds: key `SHOP-CAT-004` · item `SHOP-CAT-004.2 add-price-projection` · title `SHOP-CAT-004 <outcome>` (kind, product, area: tags)
 · tag `wave-2` (lowercase kebab, from the TAG_GROUPS vocabulary)
 · doc `SHOP-CAT-004 Spec v3 — <title>` · run `buildy-0042` · agent `devy-01` · area `area-CAT` (`-2`: a second one
   in a run) · lane `lane-01` · label `fix: rest` (a dashboard / board run label: no role word, no date)
 · branch `feat/SHOP-CAT-004-public-catalogue` · mr `feat(web): <summary> [SHOP-CAT-004]` · case `SHOP-CAT-004-TC03` · id `dec-0398`.
NO-DATE: no name holds a date (owner 2026-11-24): the date lives in the record's fields (at, started); an old dated
run / id (`buildy-20261123-01`) is read as an alias until the next minor version, never made.
PRODUCT / AREA: 2-6 capitals registered in naming.products / naming.areas ({code: name}); an unknown code or a key without
one is refused. A tracker with native ids keeps them as the link; the kit key lives in the title prefix and a field.
DUP-WORDS: a name never repeats what its key or tags say (product, a leading area word, a [Type] tag, a repo list); make and
rename strip them. TAGS (owner 2026-11-24): the facts a title no longer says, one vocabulary (TAG_GROUPS, naming.tags).
Exit codes: 0 ok · 1 names off the standard · 2 usage error.
Sections: L28 model · L94 no repeats · L194 tags
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
    return {'products': codes('products'), 'areas': codes('areas'), 'digits': int(c['digits']) if str(c.get('digits') or '').isdigit() else 3,   # a bad value: the default
            'tags': c['tags'] if isinstance(c.get('tags'), dict) else {},
            'strip': [str(x) for x in c.get('titleStrip') or [] if str(x).strip()] if isinstance(c.get('titleStrip'), list) else []}   # org regexes: old codes out of titles


def patterns(cfg):
    """{kind: regex}; PRODUCT / AREA alternations come from the registries (an empty one matches nothing)."""
    alt = lambda d: '|'.join(sorted(map(re.escape, d), key=len, reverse=True)) or '(?!)'
    key = rf'(?:{alt(cfg["products"])})-(?:{alt(cfg["areas"])})-\d{{{cfg["digits"]},}}'
    ty, slug = '|'.join(TYPES), r'[a-z0-9]+(?:-[a-z0-9]+)*'
    return {'key': rf'^{key}$', 'item': rf'^{key}\.\d+ {slug}$', 'case': rf'^{key}-TC\d{{2,}}$',
            'title': rf'^{key}(?:\.\d+)? \S.*$', 'tag': r'^[a-z0-9]+(?:-[a-z0-9]+)*$',
            'doc': rf'^{key}(?:\.\d+)? (?:{"|".join(map(re.escape, DOC_KINDS))}) v\d+ — \S.*$',
            'run': r'^[a-z]+(?:-[a-z]+)*-\d{4,}$', 'id': r'^[a-z]+-\d{4,}$', 'agent': r'^[a-z]+-\d{2,}$',
            'area': rf'^area-(?:{alt(cfg["areas"])})(?:-\d+)?$', 'lane': r'^lane-\d{2,}$', 'label': r'^\S.*$',
            'branch': rf'^(?:{ty})/{key}-{slug}$', 'mr': rf'^(?:{ty})(?:\([\w./-]+\))?!?: \S.* \[{key}\]$'}


def name_problem(kind, name, cfg=None):
    """'' when <name> fits <kind>, else why (an unknown PRODUCT / AREA code named)."""
    cfg = cfg or naming_cfg()
    rx = patterns(cfg).get(kind)
    if rx is None:
        return f'unknown kind {kind!r} ({", ".join(patterns(cfg))})'
    if (dm := DATE_RX.search(name)):
        return f'NO-DATE: {dm[0]!r} is a date; the record\'s fields hold it, a counter makes it unique ({EXAMPLES[kind]})'
    codes = {c for reg in ('products', 'areas') for c, n in cfg[reg].items() if slugify(n, 6) != c.lower()}   # a name equal to its code is the name
    if kind == 'tag' and re.match(rx, name) and (len(name) > 30 or name.upper() in codes):
        return f'a tag is 1-30 characters and never a PRODUCT / AREA code (the key says it): {name!r}'
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
            'title': 'SHOP-CAT-004 <outcome>', 'tag': 'wave-2', 'doc': 'SHOP-CAT-004 Spec v3 — <title>',
            'run': 'buildy-0042', 'id': 'dec-0398', 'agent': 'devy-01', 'area': 'area-CAT', 'lane': 'lane-01', 'label': 'fix: rest',
            'branch': 'feat/SHOP-CAT-004-public-catalogue', 'mr': 'feat(web): <summary> [SHOP-CAT-004]'}


DATE_RX = re.compile(r'(?<!\d)(?:19|20)\d\d(?:-?)(?:0[1-9]|1[0-2])(?:-?)(?:0[1-9]|[12]\d|3[01])(?!\d)')   # 20261124, 2026-11-24


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


def clean(text, key, cfg, ty='', labels=False):
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
            colon = colon or (labels and ws != [str(ty).lower()])   # a title: an area word goes only as a label ('Catalogue: x'), 'Payment methods' stays
            sp = lambda w: re.escape(w[:-1] if w.endswith('s') and len(w) > 3 else w) + 's?'   # Accounts / Account
            m = re.match(r'(?i)' + r'[\s:—–-]+'.join(map(sp, ws)) + (r'\s*:[\s—–-]*' if colon else r'(?![a-z0-9])[\s:;,—–-]*'), t)
            if m and t[m.end():].strip():
                t, changed = re.sub(r'(?i)^(?:for|of|on|about|by)\s+(?=\S)', '', t[m.end():]), True   # "Spec of the page" -> "the page"
    return t.strip()


def role_words():
    """The crew and workflow names (_manifest agents + workflows)."""
    m = (load_json(osp.join(KIT_DIR, 'skills', 'crafty', 'kit.example.json'))[0] or {}).get('_manifest') or {}
    return {str(x).lower() for k in ('agents', 'workflows') for x in (m.get(k) or {})}


def dup_words(kind, name, cfg):
    """'' or 'DUP-WORDS ...': the free text of a standard <name> repeats its product, area, type or repos."""
    if kind == 'label':   # a dashboard / board label: its kind chip and agent rows show the role (owner 2026-11-24)
        lead = (re.findall(r'[a-z]+', name.lower()) or [''])[0]
        return f'DUP-WORDS: label leads with the role {lead!r} (its kind chip shows it): {name!r}' if lead in role_words() else ''
    km = re.search(r'[A-Z]{2,6}-[A-Z]{2,6}-\d+', name)
    if not km or kind not in ('title', 'doc', 'branch', 'mr', 'item'):
        return ''
    key = km[0]
    if kind == 'title':   # <KEY> <outcome>: a [Type] or a leading area word is a tag now (owner 2026-11-24)
        ty, free = '', re.sub(rf'^{re.escape(key)}(?:\.\d+)?\s+', '', name)
    elif kind == 'doc':
        ty, free = '', name.split(' — ', 1)[1]
        ty = next((k for k in DOC_KINDS if name[len(key):].strip().startswith(k)), '')
    elif kind == 'branch':
        ty, free = name.split('/', 1)[0], name.split(key, 1)[1].replace('-', ' ')
    elif kind == 'mr':
        ty, free = re.match(r'\w+', name)[0], re.sub(rf'\s*\[{key}\]$', '', name.split(': ', 1)[1])
    else:
        ty, free = '', name.split(' ', 1)[1].replace('-', ' ')
    c = clean(free, key, cfg, ty, labels=kind == 'title')
    if re.sub(r'\W+', ' ', c).strip().lower() != re.sub(r'\W+', ' ', free).strip().lower():
        gone = [w for w in re.findall(r'[\w-]+', free) if w.lower() not in re.findall(r'[\w-]+', c.lower())]
        return f'DUP-WORDS: repeats {" ".join(gone) or "a repo list"} (the key / type already say it): {c!r}'
    return ''


def sentence(t):
    """A title reads as a sentence on its own: a lowercase first word gets a capital (menu: list -> Menu: list; iPhone, npm-x stay)."""
    return t[:1].upper() + t[1:] if re.match(r'[a-z]+(?![a-zA-Z0-9-])', t) else t


def make(kind, p, cfg=None):
    """A name from its parts, free text cleaned of what the key / type say: title (key outcome; type cleaned) · doc (key
    kind ver title) · branch (type key slug tag?) · mr (type scope summary key) · case (key n) · item (key m slug)."""
    cfg = cfg or naming_cfg()
    g = lambda k, d='': str(p.get(k) or d)
    key = g('key')
    cl = lambda t, ty='': clean(t, key, cfg, ty)
    tag = slugify(g('tag'), 3)   # a tracker's native branch tag (CU-<id>): kept so its links and the kit's branch parsers still match
    out = {'title': lambda: f'{key} {sentence(clean(g("outcome"), key, cfg, g("type", "Feature"), labels=True))}',   # type, product, area: tags (naming tags)
           'doc': lambda: f'{key} {g("kind", "Spec")} v{g("ver", "1")} — {cl(g("title"), g("kind", "Spec"))}',
           'branch': lambda: f'{g("type", "feat")}/{key}-' + '-'.join(x for x in (tag, slugify(cl(g("slug") or g("title"), g("type", "feat")))) if x),
           'mr': lambda: f'{g("type", "feat")}{"(" + g("scope") + ")" if g("scope") else ""}: {cl(g("summary"), g("type", "feat"))} [{key}]',
           'case': lambda: f'{key}-TC{int(g("n", "1")):02d}', 'item': lambda: f'{key}.{g("m", "1")} {slugify(cl(g("slug")))}'}
    if kind not in out:
        raise SystemExit(f'naming make: kind {kind!r} ({", ".join(out)})')
    return out[kind]()


# ---- tags: what a title no longer says (owner 2026-11-24); tracker labels / tags, MR labels, doc properties carry them
# group: (exclusive: one value at a time, values | a value regex | None: the registries' names / repo names); the comment: who sets it
TAG_GROUPS = {
    'kind': (True, ('feature', 'bug', 'chore', 'spike', 'docs', 'test')),   # tracker create (the old [Type]), a QA bug
    'product': (True, None), 'area': (True, None),                         # tracker create: the key's PRODUCT / AREA names
    'wave': (True, r'wave-\d+'),                                            # tracker order (brief waves)
    'phase': (True, ('spec', 'build', 'review', 'qa')),                     # by hand: tracker tags <id> phase=qa
    'repo': (False, None),                                                  # by hand / brief repos: api-code -> api
    'env': (True, r'needs-deploy|on-[a-z0-9]+(?:-[a-z0-9]+)*'),           # promoted: needs-deploy · in test: on-<env> · closed: cleared
    'risk': (False, ('migration', 'security', 'breaking', 'feature-flag-off')),   # by hand / brief
    'decision': (True, ('needs-owner', 'blocked')),                         # blocked status / decide ask; work or an answer clears it
    'origin': (True, ('qa-found', 'tester-report', 'retro')),               # a QA run's bug: qa-found; others by hand
    'test': (False, ('ui', 'api', 'mobile')),                               # by hand / testing doc
}
KIND_TAG = {'feat': 'feature', 'fix': 'bug', 'refactor': 'chore', 'perf': 'chore'}


def tag_groups(cfg):
    """{group: (exclusive, values)}; naming.tags.<group>: a list replaces its values, false turns it off (repo: {repo: tag} map)."""
    over = cfg.get('tags') or {}
    return {g: (one, tuple(map(str, over[g])) if isinstance(over.get(g), list) else vals) for g, (one, vals) in TAG_GROUPS.items() if over.get(g) is not False}


def tag_value(group, value, cfg):
    """A part as its tag: product / area code -> its name, feat -> feature, 2 -> wave-2, staging -> on-staging, api-code -> api."""
    v = str(value or '').strip()
    if group in ('product', 'area'):
        v = cfg[group + 's'].get(v.upper(), v)
    elif group == 'kind':
        v = KIND_TAG.get(v.lower(), v)
    elif group == 'wave' and (m := re.search(r'(\d+)\s*$', v)):
        v = f'wave-{m[1]}'
    elif group == 'repo':
        rm = (cfg.get('tags') or {}).get('repo')
        v = rm.get(v, v) if isinstance(rm, dict) and v in rm else re.split(r'[-_.]', v.replace('\\', '/').rsplit('/', 1)[-1])[0]
    elif group == 'env' and v and v != 'needs-deploy' and not v.startswith('on-'):
        v = f'on-{v}'
    return slugify(v, 6)


def tag_known(group, t, cfg, vals):
    """t is a value of group: in its list, its regex, a registry name (product / area); repo: any slug."""
    if vals is None:
        return group == 'repo' or t in {slugify(x, 6) for x in cfg[group + 's'].values()}
    return bool(re.fullmatch(vals, t)) if isinstance(vals, str) else t in vals


def tag_group(t, cfg, groups):
    """The group of a live tag ('' = a person's own tag, kept); an old '<group>: ...' label (Wave: x wave 2) counts as its group."""
    lt = str(t).strip().lower()
    return next((g for g, (_, vals) in groups.items() if g != 'repo' and (tag_known(g, lt, cfg, vals) or re.match(rf'{g}\s*:', lt) or (g == 'wave' and re.match(r'wave-.*\d$', lt)))), '')   # Jira kept 'wave-x-wave-2'


def tags(parts, have=(), cfg=None):
    """{tags, add, remove}: the live tags <have> with parts {group: value | 'a,b' | '-' (clear)}; key=<KEY> gives product + area,
    type= is kind. An exclusive group keeps one value; a value off the vocabulary raises ValueError; others' tags stay."""
    cfg = cfg or naming_cfg()
    groups, p, bad = tag_groups(cfg), dict(parts), []
    if (km := re.match(r'([A-Z]{2,6})-([A-Z]{2,6})-\d+', str(p.pop('key', '') or ''))):
        p.setdefault('product', km[1]); p.setdefault('area', km[2])
    if 'type' in p:
        p.setdefault('kind', p.pop('type'))
    have = [str(h).strip() for h in have if str(h).strip()]
    keep = list(have)
    for g, raw in p.items():
        if g not in TAG_GROUPS:
            bad.append(f'unknown tag group {g!r} ({", ".join(TAG_GROUPS)})')
        if g not in groups:   # unknown, or off in naming.tags
            continue
        one, vals = groups[g]
        xs = [x.strip() for x in str(raw).split(',') if x.strip() and x.strip() != '-']
        new = [tag_value(g, x, cfg) for x in xs if not x.startswith('-')]
        drop = {tag_value(g, x[1:], cfg) for x in xs if x.startswith('-')}   # -needs-owner: that value only
        bad += [f'{g} tag {t!r}: {w or "not in the vocabulary"}' for t in new if (w := name_problem('tag', t, cfg) if g != 'repo' else '') or not tag_known(g, t, cfg, vals)]   # a repo word may equal an AREA code
        bad += [f'{g}: one value at a time ({", ".join(new)})'] if one and len(new) > 1 else []
        bad += [f'{g}=: an empty value (clear the group with {g}=-)'] if not str(raw).strip() else []
        keep = [h for h in keep if h.lower() not in drop]
        if (one and new) or not xs:   # one value at a time; '-' clears the group
            keep = [h for h in keep if tag_group(h, cfg, groups) != g or h.lower() in new]
        keep += [t for t in new if t not in [k.lower() for k in keep]]
    if bad:
        raise ValueError('; '.join(bad))
    keep.sort(key=lambda t: list(TAG_GROUPS).index(g) if (g := tag_group(t, cfg, groups)) else -1)   # others' first, then kind, product, area, wave ...
    low = lambda xs: {x.lower() for x in xs}   # trackers lower-case tags (ClickUp)
    return {'tags': keep, 'add': [t for t in keep if t.lower() not in low(have)], 'remove': [h for h in have if h.lower() not in low(keep)]}


def next_key(product, area, cfg=None):
    cfg = cfg or naming_cfg()
    product, area = product.upper(), area.upper()
    for code, reg, what in ((product, cfg['products'], 'PRODUCT'), (area, cfg['areas'], 'AREA')):
        if code not in reg:
            raise SystemExit(f'naming next key: unknown {what} {code} (naming.{what.lower()}s in kit.local.json: {", ".join(reg) or "none"})')
    return f'{product}-{area}-{_counter(f"key:{product}-{area}"):0{cfg["digits"]}d}'


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
        if km:   # already keyed: same key; an old "<Area>: " head goes (the area tag says it)
            key, rest = km[0].split()[0], old[km.end():]
            head, sep, tail = rest.partition(': ')
            rest = tail if sep and head.strip().lower() == cfg['areas'].get(area, '').lower() else rest
        else:
            base = int(plan.get('start', {}).get(f'{prod}-{area}', 0)) if isinstance(plan.get('start'), dict) else 0
            seq[(prod, area)] = seq.get((prod, area), base) + 1
            key, rest = f'{prod}-{area}-{seq[(prod, area)]:0{cfg["digits"]}d}', old.split(f' {code} ', 1)[-1] if code else old
        was = re.search(r'\s*(\(was [^)]*\))\s*$', rest)   # an earlier rename's old code stays searchable
        rest = rest[:was.start()] if was else rest
        outcome = it.get('outcome') or re.sub(r'^\s*v\d+\s+', '', re.sub(REPO_LIST, '', rest)).strip()
        live = it.get('tags') or []   # a keyed title without [Type]: its live kind tag (a re-run never flips a bug)
        lk = next((str(h).capitalize() for h in live if str(h).lower() in ('bug', 'chore', 'spike', 'feature', 'docs', 'test')), '')
        ty = it.get('type') or (km and km[4]) or (re.match(rf'\s*\[({"|".join(TITLE_TYPES)})\]', old) or [None, lk or 'Feature'])[1]
        tail = f' (was {code})' if code and code != key else f' {was[1]}' if was else ''
        for rx in cfg.get('strip') or []:   # naming.titleStrip (kit.local.json): retag keeps the old title in the description
            try:
                outcome, tail = re.sub(rx, ' ', outcome).strip(), re.sub(rx, ' ', tail).rstrip()
            except re.error as e:
                bad.append(f'naming.titleStrip {rx!r}: {e}')
        title = make('title', {'key': key, 'type': ty, 'outcome': re.sub(r'\s{2,}', ' ', outcome)}, cfg) + (' ' + tail.strip() if tail.strip() else '')
        bad += [f'new title {w}' for w in [name_problem('title', title, cfg)] if w]
        wave = next((m[1] for h in live if (m := re.match(r'(?i)wave\b.*?(\d+)\s*$', str(h)))), '') or it.get('wave') or ''   # a live label, else the kit's order record
        try:
            tg = tags({'key': key, 'kind': ty, **({'wave': wave} if wave else {})}, live, cfg)
        except ValueError as e:
            tg, bad = {'tags': live, 'add': [], 'remove': []}, bad + [str(e)]
        rows.append({'old': code, 'id': it.get('id', ''), 'oldTitle': old, 'key': key, 'title': title, 'problems': bad, **tg})
    return rows


def cmd_naming(rest):
    a = [x for i, x in enumerate(rest) if not x.startswith('--') and not (i and rest[i - 1] in ('--have', '--plan'))]   # a flag's value is no part
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
    if verb == 'tags':   # JSON for the adapters (task-items.ps1 Set-KitTaskTags, devtools.py doc / MR labels)
        hv = rest[rest.index('--have') + 1] if '--have' in rest and rest.index('--have') + 1 < len(rest) else ''
        try:
            print(json.dumps(tags(dict(x.split('=', 1) for x in a[1:] if '=' in x), [h for h in hv.split(',') if h.strip()], cfg), ensure_ascii=False))
        except ValueError as e:
            print(f'naming tags: {e}', file=sys.stderr)
            return 1
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
            print('| Old code | Tracker id | Old title | New key | New title | Tags | Tags removed | Problems |\n|---|---|---|---|---|---|---|---|')
            for r in rows:
                print('| ' + ' | '.join(str(r[k]).replace('|', '\\|') for k in ('old', 'id', 'oldTitle', 'key', 'title')) + ' | '
                      + ' | '.join(', '.join(r[k]) or '—' for k in ('tags', 'remove')) + f' | {"; ".join(r["problems"]) or "—"} |')
            top = {}
            for r in rows:
                g, n = r['key'].rsplit('-', 1)
                top[g] = max(top.get(g, 0), int(n))
            print('DRY RUN: nothing renamed; the old code stays searchable (a tracker field / the title suffix) when applied. After applying: '
                  + '; '.join(f'kitbag.py naming seed {g} {n}' for g, n in top.items()))
        return 1 if any(r['problems'] for r in rows) else 0
    print(__doc__, file=sys.stderr)
    return 2


FILE_RX = {'.py': r'^[a-z][a-z0-9_]*\.py$', '.ps1': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.(?:tests|local))?\.ps1$',
           '.mjs': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.local)?\.mjs$', '.js': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.local)?\.js$'}   # adapters/*.local.ps1: org overlays
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
    """NAME-BACKUP: a backup beside the live config other than `<file>.bak-<nnnn>` (NO-DATE, New-KitId bak -Number; the old dated
    `.bak-<yyyyMMdd-HHmmss>` passes one version)."""
    out = []
    for base in {k.dir, main_clone(k.dir)}:
        for d in sorted(os.listdir(osp.join(base, 'skills'))) if osp.isdir(osp.join(base, 'skills')) else []:
            sd = osp.join(base, 'skills', d)
            out += [('NAME-BACKUP', f'skills/{d}/{n}', 'one backup form, <file>.bak-<nnnn> (New-KitId bak -Number); or move it to .state/backups/')
                    for n in sorted(os.listdir(sd)) if BAK_RX.search(n) and not re.search(r'\.bak-(?:\d{4}|\d{8}-\d{6})$', n) and osp.isfile(osp.join(sd, n))]
    return out


COMMANDS = {'naming': cmd_naming}
ARGS = {'naming': ({'--json', '--help'}, {'--plan', '--have'}, False)}
