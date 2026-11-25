"""kitbag_naming.py (plugin): one naming standard for work items, docs, runs, agents and git names (kit.local.json `naming`).

  python -X utf8 skills/bossy/kitbag.py naming check <kind> [key=<KEY>] <name> ...   # exit 1 names each one off the standard (a title: DUP-WORDS vs key=)
  python -X utf8 skills/bossy/kitbag.py naming next key <PRODUCT> <AREA>           # the next <PRODUCT>-<AREA>-<nnn> (locked counter)
  python -X utf8 skills/bossy/kitbag.py naming next name <kind> [<topic>] [--dir d]  # <kind>-<topic> <= 12 chars (buildy-ask, tidy); a tie -2 (--dir: vs its files)
  python -X utf8 skills/bossy/kitbag.py naming next id <kind>                      # <kind>-<n> unpadded (dec-12): only where no word names it
  python -X utf8 skills/bossy/kitbag.py naming make <kind> key=<KEY> type=<t> ...  # a name from its parts (title doc branch mr case item)
  python -X utf8 skills/bossy/kitbag.py naming norm <kind> <name> [--topic t] [--live a,b] [--role r]   # shown: <id> · <description>
  python -X utf8 skills/bossy/kitbag.py naming shown --in <rows.json>               # batch [[kind, name, topic, role]] -> JSON [shown]
  python -X utf8 skills/bossy/kitbag.py naming scan [--json]                       # live names (tasks, docs, board, launches) vs the standard
  python -X utf8 skills/bossy/kitbag.py naming rename --plan <plan.json> [--json]  # old codes -> new keys: a dry run table, never applied here
  python -X utf8 skills/bossy/kitbag.py naming seed <PRODUCT-AREA> <n>          # after an applied rename: next key is n+1
  python -X utf8 skills/bossy/kitbag.py naming tags [--have a,b] key=<KEY> kind=bug level=sub ...   # JSON {tags, add, remove}
Kinds: key `SHOP-CAT-004` · item `SHOP-CAT-004.2 add-price-projection` · title `Cart held in the browser` (dec-60: key, area, product in the description's kit table; kind, area, product: tags)
 · tag `website` (lowercase kebab, from the TAG_GROUPS vocabulary) · desc `ask catalogue create-only prompt`
 · doc `SHOP-CAT-004 Spec v3 — <title>` · run `buildy-ask` · agent `devy-ask-prompts` (no topic: `devy-4`) · area `ask-prompts`
   (what it covers; a tie `-2`) · lane `lane-01` · label `fix: rest` (a dashboard / board run label: no role word, no date)
 · branch `feat/SHOP-CAT-004-public-catalogue` · mr `feat(web): <summary> [SHOP-CAT-004]` · case `SHOP-CAT-004-TC03` · id `dec-close-parent`.
WORDS (owner 2026-11-24): a name says what it is; a number only breaks a tie. NO-DATE: the date lives in the record's fields
(at, started). PADDED: no zero-padded counter. SHOWN (owner 2026-11-25): '<role>-<2-3 topic words> · <plain words>'
(kitbag.py name_shown: the one normaliser; SHAPE, TIE-LETTER, NUMBERED, DESC flag the rest; lint NAME-NUMBER: a counter name says why). Old dated / padded ids (`buildy-20261123-01`, `dec-0012`) still resolve, never made.
PRODUCT / AREA: 2-6 capitals registered in naming.products / naming.areas ({code: name}); an unknown code or a key without
one is refused. A tracker with native ids keeps them as the link; the kit key lives in the `kit:` line (an old title prefix still reads).
DUP-WORDS: a name never repeats what its key or tags say (product, a leading area word, a [Type] tag, a repo list); make and
rename strip them. TAGS (owner 2026-11-24): the facts a title no longer says, one vocabulary (TAG_GROUPS, naming.tags);
one kind, one broad area (naming.tags.areaMap) and one product tag first (scan, WATCH TAGS; fix: tracker retag); no wave or kit state tag (env, decision, origin).
Exit codes: 0 ok · 1 names off the standard · 2 usage error.
Sections: L33 model · L112 no repeats · L216 tags
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
            'title': r'^(?!\[|[A-Z]{2,6}-[A-Z]{2,6}-\d)\S.*$', 'tag': r'^[a-z0-9]+(?:-[a-z0-9]+)*$',
            'doc': rf'^{key}(?:\.\d+)? (?:{"|".join(map(re.escape, DOC_KINDS))}) v\d+ — \S.*$',
            'run': r'^[a-z]+(?:-[a-z0-9]+)*$', 'id': r'^[a-z]+(?:-[a-z0-9]+)+$', 'agent': r'^[a-z]+(?:-[a-z0-9]+)+$',
            'area': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$', 'lane': r'^lane-\d{2,}$', 'label': r'^\S.*$', 'desc': r'^[a-z0-9].*$',
            'branch': rf'^(?:{ty})/{key}-{slug}$', 'mr': rf'^(?:{ty})(?:\([\w./-]+\))?!?: \S.* \[{key}\]$'}


def name_problem(kind, name, cfg=None, key=''):
    """'' when <name> fits <kind>, else why (an unknown PRODUCT / AREA code named); a plain title: DUP-WORDS against its <key> (kit table)."""
    cfg = cfg or naming_cfg()
    rx = patterns(cfg).get(kind)
    if rx is None:
        return f'unknown kind {kind!r} ({", ".join(patterns(cfg))})'
    if (dm := DATE_RX.search(name)):
        return f'NO-DATE: {dm[0]!r} is a date; the record\'s fields hold it, its words name it ({EXAMPLES[kind]})'
    if kind in ('run', 'id', 'agent') and (pm := re.search(r'-(0\d+)(?=-|$)', name) or re.match(r'^[a-z]+(?:-[a-z]+)*-(\d{4,})$', name)):
        return f'PADDED: {pm[1]!r} is a padded counter; name it by what it is, a number only to break a tie ({EXAMPLES[kind]}; an old id still resolves)'
    if kind == 'title' and re.match(r'[A-Z]{2,6}-[A-Z]{2,6}-\d', name):
        return "KEY-IN-TITLE: the key lives in the description's kit table (dec-60); fix: crafty.ps1 tracker retag <ids> -DryRun, then apply"
    if kind == 'area' and re.match(r'^area-[A-Z]', name):
        return f'NUMBERED: {name!r} is a code + counter; name the area by what it covers ({EXAMPLES[kind]})'
    if kind in ('run', 'agent', 'area') and len(re.sub(r'-\d+$', '', name)) > 16:   # owner: ~12, 16 at most, a tie suffix aside
        return f'LONG: {name!r}: at most 16 characters (aim for 12), short words ({EXAMPLES[kind]})'
    if kind in ('run', 'agent', 'area', 'id') and (w := '-'.join(name_words(name))) != name:   # the one normaliser's shape (owner 2026-11-25)
        return f'SHAPE: {name!r} is {w!r} in lowercase words split by single hyphens ({EXAMPLES[kind]})'
    if kind in ('run', 'agent', 'area') and re.search(r'-[a-z]$', name):
        return f'TIE-LETTER: {name!r}: a tie is -2, never a letter; better a topic word ({EXAMPLES[kind]})'
    if kind in ('run', 'agent') and (ws := name.split('-')) and (rs := ws[1:] if ws[0] in role_words() else ws) and all(name_code(x, name_vocab()) for x in rs):
        return f'NUMBERED: {name!r} says no topic; <role>-<2-3 topic words>, a number only to break a tie ({EXAMPLES[kind]})'
    if kind == 'desc' and (w := name_describe(name, 10 ** 6)) != name:
        return f'DESC: {name!r} is {w!r}: short lowercase plain words, no task code, wave, version, date or role word (ask catalogue create-only prompt)'
    codes = {c for reg in ('products', 'areas') for c, n in cfg[reg].items() if slugify(n, 6) != c.lower()}   # a name equal to its code is the name
    if kind == 'tag' and re.match(rx, name) and (len(name) > 30 or name.upper() in codes):
        return f'a tag is 1-30 characters and never a PRODUCT / AREA code (the key says it): {name!r}'
    if re.match(rx, name):
        return dup_words(kind, f'{key} {name}' if kind == 'title' and key else name, cfg)
    m = re.search(r'\b([A-Z]{2,6})-([A-Z]{2,6})-\d+', name)
    if kind in ('key', 'item', 'case', 'title', 'doc', 'branch', 'mr') and not (cfg['products'] and cfg['areas']):
        return 'naming.products / naming.areas are empty: register the codes in kit.local.json first'
    if m and m[1] not in cfg['products']:
        return f'unknown PRODUCT {m[1]} (naming.products: {", ".join(cfg["products"]) or "none"})'
    if m and m[2] not in cfg['areas']:
        return f'unknown AREA {m[2]} (naming.areas: {", ".join(cfg["areas"]) or "none"})'
    return f'not {kind} form ({EXAMPLES[kind]})'


EXAMPLES = {'key': 'SHOP-CAT-004', 'item': 'SHOP-CAT-004.2 add-price-projection', 'case': 'SHOP-CAT-004-TC03',
            'title': 'Cart held in the browser', 'tag': 'wave-2', 'doc': 'SHOP-CAT-004 Spec v3 — <title>',
            'run': 'buildy-ask', 'id': 'dec-close-parent', 'agent': 'devy-ask-prompts', 'area': 'ask-prompts', 'lane': 'lane-01', 'label': 'fix: rest', 'desc': 'ask catalogue create-only prompt',
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
            if m and t[m.end():].strip() and not re.match(r'(?i)(?:and|or|plus|&|\+)(?![a-z0-9])', t[m.end():]):   # 'catalogue and cart blocks' keeps its subject
                t, changed = re.sub(r'(?i)^(?:for|of|on|about|by)\s+(?=\S)', '', t[m.end():]), True   # "Spec of the page" -> "the page"
    return t.strip()


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


def readable(t, key, cfg):
    """A title opening with a bare label ('methods: x': its area word was the noun) gets the area noun back: Payment methods: x."""
    a = cfg['areas'].get((str(key).split('-') + ['', ''])[1], '')
    if a and ' ' not in a and re.match(r'[a-z][a-z-]*:', t):   # a multi-word area is a phrase DUP-WORDS bans: only the capital
        ws = a.split()
        ws[-1] = ws[-1][:-1] if ws[-1].endswith('s') and len(ws[-1]) > 3 else ws[-1]
        t = ' '.join(ws) + ' ' + t
    return sentence(t)


def make(kind, p, cfg=None):
    """A name from its parts, free text cleaned of what the key / type say: title (key outcome; type cleaned) · doc (key
    kind ver title) · branch (type key slug tag?) · mr (type scope summary key) · case (key n) · item (key m slug)."""
    cfg = cfg or naming_cfg()
    g = lambda k, d='': str(p.get(k) or d)
    key = g('key')
    cl = lambda t, ty='': clean(t, key, cfg, ty)
    tag = slugify(g('tag'), 3)   # a tracker's native branch tag (CU-<id>): kept so its links and the kit's branch parsers still match
    out = {'title': lambda: readable(clean(g("outcome"), key, cfg, g("type", "Feature"), labels=True), key, cfg),   # dec-60: plain words; key, area, product: the kit table; type: a tag
           'doc': lambda: f'{key} {g("kind", "Spec")} v{g("ver", "1")} — {cl(g("title"), g("kind", "Spec"))}',
           'branch': lambda: f'{g("type", "feat")}/{key}-' + '-'.join(x for x in (tag, slugify(cl(g("slug") or g("title"), g("type", "feat")))) if x),
           'mr': lambda: f'{g("type", "feat")}{"(" + g("scope") + ")" if g("scope") else ""}: {cl(g("summary"), g("type", "feat"))} [{key}]',
           'case': lambda: f'{key}-TC{int(g("n", "1")):02d}', 'item': lambda: f'{key}.{g("m", "1")} {slugify(cl(g("slug")))}'}
    if kind not in out:
        raise SystemExit(f'naming make: kind {kind!r} ({", ".join(out)})')
    return out[kind]()


# ---- tags: what a title no longer says (owner 2026-11-24); tracker labels / tags, MR labels, doc properties carry them
# group: (exclusive: one value at a time, values | a value regex | None: the registries' names / repo names); the comment: who sets it
TAG_GROUPS = {   # this order is the tags' order (owner 2026-11-25: type, broad area, product, then the rest; a person's own tags last)
    'kind': (True, ('feature', 'bug', 'chore', 'spike', 'docs', 'test')),   # tracker create (the old [Type]), a QA bug
    'area': (True, None), 'product': (True, None),                         # tracker create: the key's broad area (naming.tags.areaMap) and PRODUCT name
    'wave': (True, r'wave-\d+'),                                            # RETIRED (owner 2026-11-25: no numbers): any wave= clears; old wave-N tags go
    'phase': (True, ('spec', 'build', 'review', 'qa')),                     # by hand: tracker tags <id> phase=qa
    'repo': (False, None),                                                  # by hand / brief repos: api-code -> api
    'env': (True, r'needs-deploy|on-[a-z0-9]+(?:-[a-z0-9]+)*'),           # RETIRED: the status and deploys.jsonl say it
    'risk': (False, ('migration', 'security', 'breaking', 'feature-flag-off')),   # by hand / brief
    'decision': (True, ('needs-owner', 'blocked')),                         # RETIRED: the Decisions checklist and decisions.jsonl say it
    'origin': (True, ('qa-found', 'tester-report', 'retro')),               # RETIRED: the QA run record says it
    'test': (False, ('ui', 'api', 'mobile')),                               # by hand / testing doc
}
RETIRED = ('wave', 'env', 'decision', 'origin')   # owner 2026-11-25: no numbers; dec-keep-kit: no kit state tags (known, so a retag removes them)
LEVEL_DROP = {'parent': 'area', 'sub': 'product'}   # the group a parent / a subtask never carries
KIND_TAG = {'feat': 'feature', 'fix': 'bug', 'refactor': 'chore', 'perf': 'chore'}


def area_map(cfg):
    """{AREA code: broad tag} (naming.tags.areaMap: wide module names reused across tasks, owner 2026-11-25)."""
    m = (cfg.get('tags') or {}).get('areaMap')
    return {str(k).upper(): slugify(v, 6) for k, v in m.items() if slugify(v, 6)} if isinstance(m, dict) else {}


def area_broad(cfg):
    """The broad area vocabulary: the map's values, plus the name of an area code the map leaves out."""
    return set(area_map(cfg).values()) | {slugify(n, 6) for c, n in cfg['areas'].items() if c not in area_map(cfg)}


def area_narrow(cfg):
    """Area names the map replaces (catalogue under website): an old narrow tag the retag swaps for the broad one."""
    return {slugify(cfg['areas'][c], 6) for c in area_map(cfg) if c in cfg['areas']} - area_broad(cfg)


def tag_groups(cfg):
    """{group: (exclusive, values)}; naming.tags.<group>: a list replaces its values, false turns it off (repo: {repo: tag} map)."""
    over = cfg.get('tags') or {}
    return {g: (one, tuple(map(str, over[g])) if isinstance(over.get(g), list) else vals) for g, (one, vals) in TAG_GROUPS.items() if over.get(g) is not False}


def tag_value(group, value, cfg):
    """A part as its tag: product / area code -> its name, feat -> feature, 2 -> wave-2, api-code -> api."""
    v = str(value or '').strip()
    if group == 'area':   # owner 2026-11-25: a broad module tag reused across tasks (naming.tags.areaMap), else the area's name
        v = area_map(cfg).get(v.upper(), cfg['areas'].get(v.upper(), v))
    elif group == 'product':
        v = cfg['products'].get(v.upper(), v)
    elif group == 'kind':
        v = KIND_TAG.get(v.lower(), v)
    elif group == 'wave' and (m := re.search(r'(\d+)\s*$', v)):
        v = f'wave-{m[1]}'
    elif group == 'repo':
        rm = (cfg.get('tags') or {}).get('repo')
        v = rm.get(v, v) if isinstance(rm, dict) and v in rm else re.split(r'[-_.]', v.replace('\\', '/').rsplit('/', 1)[-1])[0]
    return slugify(v, 6)


def tag_known(group, t, cfg, vals):
    """t is a value of group: in its list, its regex, a registry name (product / area); repo: any slug."""
    if vals is None and group == 'area':
        return t in area_broad(cfg)
    if vals is None:
        return group == 'repo' or t in {slugify(x, 6) for x in cfg[group + 's'].values()}
    return bool(re.fullmatch(vals, t)) if isinstance(vals, str) else t in vals


def tag_group(t, cfg, groups):
    """The group of a live tag ('' = a person's own tag, kept); an old '<group>: ...' label (Wave: x wave 2) counts as its group."""
    lt = str(t).strip().lower()
    return next((g for g, (_, vals) in groups.items() if g != 'repo' and (tag_known(g, lt, cfg, vals) or re.match(rf'{g}\s*:', lt) or (g == 'wave' and re.match(r'wave-.*\d$', lt))
                 or (g == 'area' and lt in area_narrow(cfg)))), '')   # a narrow area name (catalogue): the broad tag replaces it   # Jira kept 'wave-x-wave-2'


def tags(parts, have=(), cfg=None):
    """{tags, add, remove}: the live tags <have> with parts {group: value | 'a,b' | '-' (clear)}; key=<KEY> gives product + area,
    type= is kind. An exclusive group keeps one value; a value off the vocabulary raises ValueError; others' tags stay."""
    cfg = cfg or naming_cfg()
    groups, p, bad = tag_groups(cfg), dict(parts), []
    if (km := re.match(r'([A-Z]{2,6})-([A-Z]{2,6})-\d+', str(p.pop('key', '') or ''))):
        p.setdefault('product', km[1]); p.setdefault('area', km[2])
    if 'type' in p:
        p.setdefault('kind', p.pop('type'))
    for g in RETIRED:   # retired groups: never set
        p.pop(g, None)
    lvl = str(p.pop('level', '') or '')   # owner 2026-11-25: a parent: kind + product · a subtask: kind + area (its parent says the product) · alone: all three
    if lvl in LEVEL_DROP:
        p[LEVEL_DROP[lvl]] = '-'
    have = [str(h).strip() for h in have if str(h).strip()]
    keep = [h for h in have if tag_group(h, cfg, groups) not in RETIRED]   # old wave-N / 'Wave: x' tags go on any update
    for g, raw in p.items():
        if g not in TAG_GROUPS:
            bad.append(f'unknown tag group {g!r} ({", ".join(TAG_GROUPS)})')
        if g not in groups:   # unknown, or off in naming.tags
            continue
        one, vals = groups[g]
        xs = [x.strip() for x in str(raw).split(',') if x.strip() and x.strip() != '-']
        new = [tag_value(g, x, cfg) for x in xs if not x.startswith('-')]
        drop = {tag_value(g, x[1:], cfg) for x in xs if x.startswith('-')}   # -urgent: that value only
        bad += [f'{g} tag {t!r}: {w or "not in the vocabulary"}' for t in new if (w := name_problem('tag', t, cfg) if g != 'repo' else '') or not tag_known(g, t, cfg, vals)]   # a repo word may equal an AREA code
        bad += [f'{g}: one value at a time ({", ".join(new)})'] if one and len(new) > 1 else []
        bad += [f'{g}=: an empty value (clear the group with {g}=-)'] if not str(raw).strip() else []
        keep = [h for h in keep if h.lower() not in drop]
        if (one and new) or not xs:   # one value at a time; '-' clears the group
            keep = [h for h in keep if tag_group(h, cfg, groups) != g or h.lower() in new]
        keep += [t for t in new if t not in [k.lower() for k in keep]]
    if bad:
        raise ValueError('; '.join(bad))
    keep.sort(key=lambda t: list(TAG_GROUPS).index(g) if (g := tag_group(t, cfg, groups)) else len(TAG_GROUPS))   # kind, area, product, the rest; a person's own last
    low = lambda xs: {x.lower() for x in xs}   # trackers lower-case tags (ClickUp)
    return {'tags': keep, 'add': [t for t in keep if t.lower() not in low(have)], 'remove': [h for h in have if h.lower() not in low(keep)]}


def tag_gaps(have, cfg=None, level=''):
    """[problem]: a kit task carries exactly one kind, one broad area and one product tag (owner 2026-11-25); no narrow area or wave tag."""
    cfg = cfg or naming_cfg()
    groups = tag_groups(cfg)
    by = [tag_group(t, cfg, groups) for t in have]
    by = [g if g != 'area' or str(t).strip().lower() in area_broad(cfg) else 'narrow' for t, g in zip(have, by)]
    need = [g for g in ('kind', 'area', 'product') if g != LEVEL_DROP.get(level)]   # level '' (unknown): area or product may be inherited
    out = [f'{n} {g} tags' if n else f'no {g} tag' for g in need if g in groups and (n := by.count(g)) != 1 and (level or g == 'kind' or n > 1 or not by.count('area' if g == 'product' else 'product'))]
    out += [f'{g} tag on a {"parent" if level == "parent" else "subtask"}' for g in by if level in LEVEL_DROP and g == LEVEL_DROP[level]]
    out += [f'narrow area tag {t!r} (a broad one replaces it)' for t, g in zip(have, by) if g == 'narrow']
    return out + [f'{g} tag {t!r} (retired)' for t, g in zip(have, by) if g in RETIRED]


META_RX = re.compile(r'\\?<!-- kit:meta -->(.*?)\\?<!-- /kit:meta -->', re.S)   # ClickUp reads markers back as \<!--


def meta_read(desc):
    """dec-60: a description's kit table as {key (row Code), area, product, parent, run, ...} (the last table wins; task-items.ps1
    Get-KitTaskMeta / Set-KitTaskMeta; Markdown and Jira wiki rows)."""
    ms = META_RX.findall(str(desc or '').replace('\r\n', '\n'))
    rows = [m for ln in re.sub(r'\\(?=[\W_])', '', ms[-1]).split('\n') if (m := re.match(r'^\s*\|\|?\s*([^|]+?)\s*\|\|?\s*([^|]*?)\s*\|\|?\s*$', ln))] if ms else []
    return {('key' if (n := re.sub(r'\W+', '', m[1].lower())) == 'code' else n): m[2].strip() for m in rows if not re.match(r'^(?:Kit|:?-+:?)$', m[1]) and m[2].strip()}


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
    out += [('run', n, 'board') for n in sorted(board_live('run'))] + [('agent', n, 'board') for n in sorted(board_live('agent')) if n != 'coordinator']
    dd = kit_path('decisions')
    out += [('id', fn[:-5], 'decisions') for fn in sorted(os.listdir(dd)) if fn.endswith('.json')
            and (state_read(osp.join(dd, fn)) or {}).get('status') == 'pending'] if osp.isdir(dd) else []
    return out


def tag_scan(cfg):
    """[(kind 'tags', task name, where, why)]: a task whose tags the kit recorded (task index: the kit tagged it) 

    kind / product tag or keep an area / wave tag; fix: crafty.ps1 tracker retag <ids> [-DryRun] (supervise WATCH TAGS)."""
    out, tr, d = [], (read_tracking() or {}).get('tasks') or {}, kit_path('tasks')
    for fn in sorted(os.listdir(d)) if osp.isdir(d) else []:
        x = state_read(osp.join(d, fn)) if fn.endswith('.json') else None
        tid = str((x or {}).get('task') or '')
        if tid and isinstance(x.get('tags'), list) and (gaps := tag_gaps([str(t) for t in x['tags']], cfg)):
            out.append(('tags', str((tr.get(tid) or {}).get('name') or tid), f'tracking {tid}', '; '.join(gaps)))
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
        outcome = re.sub(r'\s*\[flaky\]$', '', outcome)   # dec-keep-kit: a state marker; the QA body says which defect is flaky
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
        bad += [f'new title {w}' for w in [name_problem('title', title, cfg, key)] if w]
        meta = {'key': key, 'area': tag_value('area', key.split('-')[1], cfg), 'product': tag_value('product', key.split('-')[0], cfg)}   # task-items.ps1 New-KitKeyMeta
        wave = next((m[1] for h in live if (m := re.match(r'(?i)wave\b.*?(\d+)\s*$', str(h)))), '') or it.get('wave') or ''   # a live label, else the kit's order record
        try:
            tg = tags({'key': key, 'kind': ty, **({'level': it['level']} if it.get('level') else {})}, live, cfg)
        except ValueError as e:
            tg, bad = {'tags': live, 'add': [], 'remove': []}, bad + [str(e)]
        rows.append({'old': code, 'id': it.get('id', ''), 'oldTitle': old, 'key': key, 'title': title, 'meta': meta, 'problems': bad, 'gaps': tag_gaps(live, cfg, it.get('level') or ''), **tg})
    return rows


def cmd_naming(rest):
    a = [x for i, x in enumerate(rest) if not x.startswith('--') and not (i and rest[i - 1] in VALUED)]   # a flag's value is no part
    js = '--json' in rest
    opt = lambda f: rest[rest.index(f) + 1] if f in rest and rest.index(f) + 1 < len(rest) else ''
    cfg = naming_cfg()
    if not a or a[0] in ('help', '-h') or '--help' in rest:
        print(__doc__)
        return 0 if (not a or a[0] in ('help', '-h') or '--help' in rest) else 2
    verb = a[0]
    if verb == 'check' and len(a) >= 3:
        ky, ns = next((x[4:] for x in a[2:] if x.startswith('key=')), ''), [x for x in a[2:] if not x.startswith('key=')]   # check title key=<KEY> <title>: DUP-WORDS
        bad = [(n, w) for n in ns if (w := name_problem(a[1], n, cfg, ky))]
        print('\n'.join(f'NAME {a[1]} {n!r}: {w}' for n, w in bad) or f'naming: {len(ns)} {a[1]} name(s) fit the standard')
        return 1 if bad else 0
    if verb == 'norm' and len(a) >= 3:   # the shown form: <id> · <description>; --live: the other live names (a tie suffix stays on a clash)
        print(name_shown(a[1], a[2], opt('--topic'), [x for x in opt('--live').split(',') if x], opt('--role')))
        return 0
    if verb == 'shown' and opt('--in'):   # batch for the dashboard / board show: [[kind, name, topic, role], ...] -> [shown, ...]
        rows = [r for r in (load_json(opt('--in'))[0] or []) if isinstance(r, list) and len(r) >= 2]
        live = {}
        for r in rows:
            live.setdefault(r[0], set()).add(str(r[1]))
        print(json.dumps([name_shown(r[0], str(r[1]), str((r + ['', ''])[2] or ''), live.get(r[0], ()), str((r + ['', '', ''])[3] or '')) for r in rows], ensure_ascii=False))
        return 0
    if verb == 'next' and len(a) >= 3 and a[1] in ('key', 'id', 'name'):
        print(next_key(a[2], a[3] if len(a) > 3 else '', cfg) if a[1] == 'key' else next_id(a[2]) if a[1] == 'id' else next_name(a[2], ' '.join(a[3:]), opt('--dir'), int(opt('--cap') or 12)))   # NAME-NUMBER: the CLI of the maker
        return 0
    if verb == 'make' and len(a) >= 2:
        try:
            n = make(a[1], dict(x.split('=', 1) for x in a[2:] if '=' in x), cfg)
        except ValueError as e:   # a non-number n / m
            print(f'naming make {a[1]}: {e}', file=sys.stderr)
            return 2
        kw = name_problem('key', dict(x.split('=', 1) for x in a[2:] if '=' in x).get('key', ''), cfg) if a[1] == 'title' else ''   # a plain title: its key still checked
        if a[1] in patterns(cfg) and (w := name_problem(a[1], n, cfg) or kw):   # a made name obeys its own check
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
        bad = [(k, n, w, why) for k, n, w in live_names() if (why := name_problem(k, n, cfg))] + tag_scan(cfg)
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
            print('| Old code | Tracker id | Old title | New key | New title | Tag gaps now | Tags | Tags removed | Problems |\n|---|---|---|---|---|---|---|---|---|')
            for r in rows:
                print('| ' + ' | '.join(str(r[k]).replace('|', '\\|') for k in ('old', 'id', 'oldTitle', 'key', 'title')) + ' | '
                      + ' | '.join(', '.join(r[k]) or '—' for k in ('gaps', 'tags', 'remove')) + f' | {"; ".join(r["problems"]) or "—"} |')
            top = {}
            for r in rows:
                g, n = r['key'].rsplit('-', 1)
                top[g] = max(top.get(g, 0), int(n))
            print('DRY RUN: nothing renamed; the old code stays searchable (the title suffix, the Old title line) when applied. After applying: '
                  + '; '.join(f'kitbag.py naming seed {g} {n}' for g, n in top.items()))
        return 1 if any(r['problems'] for r in rows) else 0
    print(__doc__, file=sys.stderr)
    return 2


FILE_RX = {'.py': r'^[a-z][a-z0-9_]*\.py$', '.ps1': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.(?:tests|local))?\.ps1$',
           '.mjs': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.local)?\.mjs$', '.js': r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.local)?\.js$'}   # adapters/*.local.ps1: org overlays
BAK_RX = re.compile(r'\.(?:bak|bad|orig|old|stale)(?:[-.]|$)', re.I)
PAD_RX = re.compile(r"""-(?:\{[^{}]*:0\d+d\}|\{\d+:(?:0{2,}|D\d)\}|\$\(Get-Date -Format '[yMdHms]{6,}'\))""")   # padded or dated after a dash
NUM_RX = re.compile(r'\bNew-KitId\s+[-$(\w]|\bnext_id\(')   # NAME-NUMBER: a made counter name
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
    NAME-FILE: a script name off its language's rule (py snake_case; ps1 / mjs / js kebab-case), except hook entry points (hook_entry_names).
    NAME-PADDED: kit code making a name with a padded counter or a date (PAD_RX).
    NAME-NUMBER: kit code making a counter name (New-KitId / next_id) with no `NAME-NUMBER: <why>` on the line (owner 2026-11-25)."""
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
    for f in (f for f in kf if re.match(r'(?:skills|workflows)/(?!pokey/)', f) and osp.splitext(f)[1] in FILE_RX):   # pokey: evidence names keep <CODE>-<check>_<nn>
        try:
            lines = open(osp.join(k.dir, f), encoding='utf-8', errors='replace').read().splitlines()
        except OSError:
            continue
        problems += [('NAME-PADDED', f'{f}:{i}', 'a padded counter or a date in a made name (owner 2026-11-24): <kind>-<words> (kitbag.py naming next name), '
                      '<kind>-<n> only to break a tie (next id)') for i, s in enumerate(lines, 1) if PAD_RX.search(s)]
        problems += [('NAME-NUMBER', f'{f}:{i}', 'a counter as a name (owner 2026-11-25): New-KitName <kind> <topic> / next_name; a number only where '
                      'nothing names it: say why on the line (# NAME-NUMBER: <why>)') for i, s in enumerate(lines, 1)
                     if NUM_RX.search(s) and 'NAME-NUMBER:' not in s and not re.match(r'\s*(?:#|def |function |//|\*)', s)]


def warn_hook(k):
    """NAME-BACKUP: a backup beside the live config other than `<file>.bak` (latest) / `<file>.bak.prev` (Get-KitBakName, owner
    2026-11-24: no counter, no date; the old `.bak-<nnnn>` / `.bak-<yyyyMMdd-HHmmss>` pass)."""
    out = []
    for base in {k.dir, main_clone(k.dir)}:
        for d in sorted(os.listdir(osp.join(base, 'skills'))) if osp.isdir(osp.join(base, 'skills')) else []:
            sd = osp.join(base, 'skills', d)
            out += [('NAME-BACKUP', f'skills/{d}/{n}', 'one backup form, <file>.bak + <file>.bak.prev (Get-KitBakName); or move it to .state/backups/')
                    for n in sorted(os.listdir(sd)) if BAK_RX.search(n) and not re.search(r'\.bak(?:\.prev|-\d{4,}|-\d{8}-\d{6})?$', n) and osp.isfile(osp.join(sd, n))]
    return out


COMMANDS = {'naming': cmd_naming}
VALUED = {'--plan', '--have', '--dir', '--cap', '--topic', '--live', '--role', '--in'}
ARGS = {'naming': ({'--json', '--help'}, VALUED, False)}
