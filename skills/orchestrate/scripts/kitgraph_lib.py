"""Shared kit graph + checks. kit-lint.py (problems, exit code) and kit-flow.py (HTML page) both import this module, so the
page and the lint never disagree. Nothing here writes files.

  load(kit)   -> Kit: files (published + local overlay, git-ignored runtime/caches and the repo's README/docs/examples left out),
                 junk, skills, agents, workflows,
                 texts, router text, org router rows, each skill's Files index
  graph(k)    -> nodes (kind, column, trigger text, reach, chain) + typed edges (route/scoped/hook/spawn/index/loads/calls/mention)
  lint(k, g)  -> [(code, where, message)]: every check kit-lint documents, incl. reach (unreached / mention-only) and junk
"""
import fnmatch, json, os, re
from collections import defaultdict, deque
from typing import Dict, List, Optional, Set, Tuple

SKIP_DIRS = {'node_modules', '__pycache__', '.git', '.claude-runtime', 'worktrees', 'memory'}
# repo plumbing at the kit root (the repo root IS the .claude folder): read for org terms and doc links, not part of the kit graph
REPO_ONLY = ('README.md', 'CONTRIBUTING.md', 'LICENSE', 'docs', 'examples', '.githooks', '.gitignore', '.gitattributes',
             # cross-tool mirrors (Codex/Antigravity): real content, but `@import`ed into CLAUDE.md, not routed to directly
             'AGENTS.md', 'GEMINI.md', '.codex', '.agents')
# the one map of runtime + durable paths, and the files allowed to know raw runtime paths (kit-lint RUNTIME-RAW)
PATHS_JSON = 'skills/dev-kit/scripts/kitpaths.json'
PATH_HELPERS = {PATHS_JSON, 'skills/dev-kit/scripts/kitpaths.ps1', 'skills/dev-kit/scripts/kitpaths.py',
                'skills/dev-kit/scripts/kitpaths.mjs', 'skills/orchestrate/scripts/kitgraph_lib.py',
                'skills/orchestrate/scripts/kit-setup.ps1', 'skills/orchestrate/scripts/kit-lint.py'}
# durable state that older layouts kept inside the runtime (kit-lint RUNTIME-DURABLE; kit-setup.ps1 -Migrate moves it out)
LEGACY_DURABLE = ('learning', 'tracking', 'automerge.json', 'tracker-none')
TEXT_EXT = ('.md', '.ps1', '.psm1', '.py', '.js', '.mjs', '.json', '.html', '.txt', '.sh', '.yml', '.yaml', '.ini')
JUNK_EXT = ('.apk', '.aab', '.log', '.zip', '.tmp')
RESERVED = {'nul', 'con', 'prn', 'aux'}
BLOCKS = ('Load when', 'Not when', 'Hands off to', 'Files')
FUZZY = re.compile(r'(?<!")read (it |this )?(only )?when (you need|needed)|\(read only when', re.I)   # quoted = named, not used
IMPORT_RE = re.compile(r'^@([\w./-]+\.md)\s*$', re.MULTILINE)


def resolve_imports(text, base_dir, _seen=None):
    """Expand Claude Code's own `@<path>.md` import lines (e.g. CLAUDE.md pointing at a
    canonical AGENTS.md shared with Codex/Antigravity) so every text-based check below sees
    the same content Claude Code itself would load, regardless of which file is the real one."""
    seen = _seen if _seen is not None else set()

    def repl(m):
        path = m.group(1)
        if path in seen:
            return ''
        full = os.path.join(base_dir, path)
        if not os.path.isfile(full):
            return m.group(0)
        seen.add(path)
        return resolve_imports(read(full), base_dir, seen)

    return IMPORT_RE.sub(repl, text)


def read(p, raw=False):
    """File text with line endings normalised to LF (a Windows clone with core.autocrlf checks files out as CRLF);
    raw=True keeps them (WF-CRLF)."""
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
    """Everything load() reads (annotated so editors and type checkers know the attributes)."""
    dir: str
    repo: str
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


def blocks(text):
    """The **Load when** / **Not when** / **Hands off to** / **Files** blocks of a SKILL.md body (first lines only)."""
    out = {}
    for name in BLOCKS:
        m = re.search(r'^\*\*' + re.escape(name) + r':?\*\*(.*?)(?=^\*\*[A-Z][^*]*\*\*|^#|^\||\Z)', text, re.S | re.M)
        if m:
            body = re.sub(r'^\s*:?\s*(\([^)]*\))?\s*:?\s*', '', m.group(1))   # drop "(all must hold):" style lead-ins
            if name == 'Files':
                tm = re.search(r'^\*\*Files:?\*\*[^\n]*\n(?:[ \t]*\n)*((?:\|.*\n?)+)', text, re.M)
                rows_n = sum(len(re.findall(r'`[^`]+`', r[0])) for r in table_rows(tm.group(1) if tm else '') if r and r[0].lower() != 'file')
                body = f'{rows_n} files listed, each with the step that reads or runs it'
            out[name] = re.sub(r'\s+', ' ', body)[:600]
    return out


def agent_blocks(desc):
    out = {}
    for name, pat in (('Spawned by', r'Spawned by(.*?)(?=Not for|Precondition|$)'), ('Precondition', r'Precondition:?(.*?)(?=Not for|$)'),
                      ('Not for', r'Not for:?(.*)$')):
        m = re.search(pat, desc, re.S)
        if m:
            out[name] = m.group(1).strip(' .:;')
    return out


def tables(k):
    """Markdown tables from the always-loaded files, plus Router/Events-headed tables anywhere, each row linked to its targets."""
    names = {**{s: f'skills/{s}/SKILL.md' for s in k.skills}, **{'/' + w: p for w, p in k.workflows.items()}, **dict(k.agents)}
    always = ['CLAUDE.md'] + [f for f in k.files if re.match(r'rules/[^/]+\.md$', f) and 'paths' not in frontmatter(k.texts.get(f, ''))]
    out = []
    for f in k.files:
        if not f.endswith('.md'):
            continue
        heading = ''
        lines = k.texts.get(f, '').splitlines()
        i = 0
        while i < len(lines):
            l = lines[i]
            if l.startswith('#'):
                heading = l.strip('# ').strip()
            if l.startswith('|') and i + 1 < len(lines) and re.match(r'^\|[\s:|-]+\|?$', lines[i + 1]):
                j = i
                while j < len(lines) and lines[j].startswith('|'):
                    j += 1
                if f in always or re.search(r'router|event', heading, re.I):
                    head = [c.strip() for c in l.strip().strip('|').split('|')]
                    rows = table_rows('\n'.join(lines[i:j]))
                    links = [sorted({p for n, p in names.items() if re.search(r'`' + re.escape(n) + r'[`\s]', ' '.join(r))}) for r in rows]
                    out.append({'file': f, 'heading': heading, 'head': head, 'rows': rows, 'links': links})
                i = j
                continue
            i += 1
    return out


def load(kit):
    k = Kit()
    k.dir = os.path.abspath(kit)
    k.repo = k.dir   # the repo root is the kit (.claude folder); README/docs/examples sit next to the kit's own folders
    ign = [l.strip() for l in read(os.path.join(k.dir, '.gitignore')).splitlines() if l.strip() and not l.startswith('#')]

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
        top = os.path.relpath(d, k.dir) == '.'
        skip = SKIP_DIRS if top else SKIP_DIRS - {'.claude-runtime', 'worktrees', 'memory'}   # runtime, harness worktrees, auto memory: kit root only
        dirs[:] = [x for x in dirs if x not in skip]
        for f in fs:
            rel = os.path.relpath(os.path.join(d, f), k.dir).replace('\\', '/')
            if rel.split('/')[0] in REPO_ONLY:
                repo_files.append(rel)
            elif f.lower() in RESERVED:
                junk.append((rel, 'reserved-name file (delete it)'))
            elif f.lower().endswith(JUNK_EXT):
                junk.append((rel, 'runtime output among the kit files (runtime belongs in <kit>/.claude-runtime: Get-KitPath; delete it once unused)'))
            else:
                allf.append(rel)
    k.all = sorted(allf)
    k.repo_files = sorted(repo_files)
    k.junk = junk
    k.local_rules = [f for f in k.all if re.match(r'rules/[^/]+\.local\.md$', f)]
    # kit files = published files + the local overlay that behaves like kit (local skills, project profiles); not configs/state
    k.files = sorted(f for f in k.all if not ignored(f) or f in k.local_rules)
    k.fileset = set(k.files)
    try:
        cfg = json.loads(read(os.path.join(k.dir, 'skills', 'dev-kit', 'kit.local.json')) or '{}')
        k.local_only = [p.replace('\\', '/').rstrip('/') for p in cfg.get('localOnly', [])]
    except ValueError:
        k.local_only = []
    k.skills = sorted({f.split('/')[1] for f in k.files if re.match(r'skills/[^/]+/SKILL\.md$', f)})
    k.agents = {f[7:-3]: f for f in k.files if re.match(r'agents/[^/]+\.md$', f)}
    k.workflows = {f[10:-3]: f for f in k.files if re.match(r'workflows/[^/]+\.js$', f)}
    k.texts = {f: read(os.path.join(k.dir, f)) for f in k.files if f.lower().endswith(TEXT_EXT)}
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
                pat = re.sub(r'<[^>]+>', '*', n.strip())
                hits = [f for f in k.files if f.startswith(base) and fnmatch.fnmatch(f[len(base):], pat)]
                entries.append((n.strip(), cells[1], hits))
        k.index[s] = entries
    return k


def skill_of(f):
    return f.split('/')[1] if f.startswith('skills/') and f.count('/') >= 2 else None


def graph(k):
    texts, fileset = k.texts, k.fileset
    by_base = defaultdict(list)
    for f in k.files:
        by_base[os.path.basename(f).lower()].append(f)

    def is_local(f):
        b = os.path.basename(f)
        return '.local.' in b or any(f == p or f.startswith(p + '/') for p in k.local_only)

    hook_targets = {}
    try:
        sj = json.loads(texts.get('settings.json', '{}') or '{}')
        for event, blocks in (sj.get('hooks') or {}).items():
            for b in blocks:
                for h in b.get('hooks', []):
                    blob = ' '.join([h.get('command', '')] + list(h.get('args', [])))
                    m = re.search(r'\.claude[\\/]([\w./\\-]+\.(?:ps1|py|js|sh))', blob)
                    if m and m.group(1).replace('\\', '/') in fileset:
                        hook_targets.setdefault(m.group(1).replace('\\', '/'), []).append(event + (f" ({b['matcher']})" if b.get('matcher') else ''))
    except ValueError:
        pass

    def kind(f):
        b = os.path.basename(f)
        if f == 'CLAUDE.md':
            return 'root'
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
        if f in hook_targets:
            return 'hook'
        if b == 'LESSONS.md':
            return 'lessons'
        if b == 'HISTORY.md':
            return 'history'
        if '/reference/' in f:
            return 'reference'
        if '/templates/' in f:
            return 'template'
        if '.example.' in b or b.endswith('.local.json'):
            return 'config'
        if f.endswith(('.ps1', '.psm1', '.py', '.js', '.mjs', '.sh')):
            return 'script'
        return 'other'

    COL = {'root': 0, 'rule': 0, 'rule-scoped': 0, 'settings': 0, 'skill': 1, 'workflow': 1, 'agent': 1, 'hook': 1,
           'reference': 2, 'template': 2, 'lessons': 2, 'history': 2, 'config': 2, 'other': 2, 'script': 3}

    def trigger(f, kd):
        t = texts.get(f, '')
        fm = frontmatter(t)
        if kd in ('skill', 'agent'):
            return fm.get('description', '')
        if kd == 'rule-scoped':
            fmm = re.match(r'^---\s*\n(.*?)\n---', t, re.S)
            paths = re.findall(r'^\s*-\s*"?([^"\n]+)"?', fmm.group(1), re.M) if fmm else []
            return 'Loaded when a file matching ' + ', '.join(paths) + ' is opened'
        if kd == 'rule':
            return 'Always loaded into every session'
        if kd == 'root':
            return 'Always loaded: the project CLAUDE.md (holds the Router)'
        if kd == 'workflow':
            d = re.search(r"description:\s*'((?:[^'\\]|\\.)*)'", t)
            w = re.search(r"whenToUse:\s*'((?:[^'\\]|\\.)*)'", t)
            return ((d.group(1) if d else '') + ('\nWhen: ' + w.group(1) if w else '\nWhen: (no whenToUse)')).strip()
        if kd == 'hook':
            return 'Run by the harness on ' + ', '.join(hook_targets[f])
        if kd == 'settings':
            return 'Harness settings: permissions and hooks'
        sk = skill_of(f)
        for n, when, hits in k.index.get(sk, []):
            if f in hits:
                return f'{n}: {when}'
        first = next((l.strip('# ').strip() for l in t.splitlines() if l.strip() and not l.startswith(
            ('---', '#!', '<#', '"""', 'import', '$', 'param', 'export const meta'))), '')
        return first[:220]

    nodes = {}
    for f in k.files:
        kd = kind(f)
        nodes[f] = {'id': f, 'label': os.path.basename(f) if f.count('/') else f, 'kind': kd, 'col': COL[kd],
                    'group': skill_of(f) or ('agents' if kd == 'agent' else 'workflows' if kd == 'workflow' else 'kit'),
                    'local': is_local(f), 'trigger': trigger(f, kd)}
        if kd == 'skill':
            nodes[f]['label'] = skill_of(f)
        if kd in ('agent', 'workflow'):
            nodes[f]['label'] = os.path.basename(f).rsplit('.', 1)[0]

    PATH_RE = re.compile(r'[\w./\\<>*{}$-]*?([\w.-]+\.(?:md|ps1|psm1|py|js|mjs|json|html|txt|sh|ini))\b')
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

    def add(src, dst, t=None):
        if src != dst and dst in nodes:
            if t:
                edges[(src, dst)] = t
            else:
                edges.setdefault((src, dst), etype(src, dst))

    # the Files index is the explicit path into a skill's files (glob entries cover overlay files like project profiles)
    for s, entries in k.index.items():
        for _, _, hits in entries:
            for h in hits:
                add(f'skills/{s}/SKILL.md', h, 'index')
    for src, t in texts.items():
        sdir = os.path.dirname(src)
        for m in PATH_RE.finditer(t):
            full = m.group(0).replace('\\', '/').strip('`\'"()[],:;')
            base = m.group(1)
            hit = None
            for cand in (os.path.normpath(os.path.join(sdir, full)).replace('\\', '/'), re.sub(r'^.*?\.claude/', '', full),
                         ('skills/' + full.split('skills/', 1)[1]) if 'skills/' in full else None):
                if cand and cand in fileset:
                    hit = cand
                    break
            if not hit:
                hits = by_base.get(base.lower(), [])
                same = [h for h in hits if skill_of(h) and skill_of(h) == skill_of(src)]
                hit = (same or hits or [None])[0] if (len(hits) == 1 or same) else None
            if hit:
                add(src, hit)
        for s in k.skills:
            if re.search(r'(?<![\w-])' + re.escape(s) + r'(?![\w-])', t):
                add(src, f'skills/{s}/SKILL.md')
        for n, f in k.agents.items():
            if re.search(r'(?<![\w-])' + re.escape(n) + r'(?![\w-])', t):
                add(src, f)
        for n, f in k.workflows.items():
            if re.search(r'(?<![\w-])/?' + re.escape(n) + r'(?![\w-])', t):
                add(src, f)
    for tgt in hook_targets:
        if 'settings.json' in nodes:
            edges[('settings.json', tgt)] = 'hook'

    entries = [f for f, n in nodes.items() if n['kind'] in ('root', 'rule', 'rule-scoped', 'settings', 'skill', 'agent', 'workflow')]
    out = defaultdict(list)
    for (a, b), t in edges.items():
        out[a].append((b, t))
    prev = {e: None for e in entries}
    q = deque(entries)
    while q:
        cur = q.popleft()
        for nxt, t in out[cur]:
            if t != 'mention' and nxt not in prev:
                prev[nxt] = cur
                q.append(nxt)
    any_reach = set(prev)
    q = deque(any_reach)
    while q:
        cur = q.popleft()
        for nxt, _ in out[cur]:
            if nxt not in any_reach:
                any_reach.add(nxt)
                q.append(nxt)
    for f, n in nodes.items():
        chain, c = [], f
        while c is not None and c in prev:
            chain.append(c)
            c = prev[c]
        n['chain'] = list(reversed(chain)) if f in prev else []
        n['reach'] = 'entry' if f in entries else 'structural' if f in prev else 'mention-only' if f in any_reach else 'none'
    return {'nodes': nodes, 'edges': edges}


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
            # an absolute path names a tool outside the kit (e.g. a local overlay's script): check it on disk instead
            absolute = re.match(r'^(?:[A-Za-z]:[\\/]|/|~[\\/])', n)
            if absolute and os.path.exists(os.path.expanduser(n)):
                continue
            if not hits and '*' not in n and '<' not in n:
                bad('FILES-MISSING', p, f'Files index lists {n}, which does not exist' + (' (absolute path, not found on this machine)' if absolute else ''))
            if re.match(r'(reference|templates)/', n) and not re.search(r'\bsteps?\b|\b[A-Z]\d+[a-z]?\b', when, re.I):
                bad('FILES-UNBOUND', p, f'{n}: say at which step (or event row) it is read or filled')
            if n == 'HISTORY.md' and 'never' not in when.lower():
                bad('FILES-UNBOUND', p, 'HISTORY.md must be marked "never read for work"')
            if n == 'LESSONS.md' and not re.search(r'step [A-Z]?0\b|\bstart|\bfirst|before anything', when, re.I):
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
        if '\r' in read(os.path.join(k.dir, p), raw=True):
            bad('WF-CRLF', p, 'CR line endings (workflow scripts must be LF)')
    # ---- agents
    for a, p in k.agents.items():
        text = k.texts.get(p, '')
        desc = frontmatter(text).get('description', '')
        if 'Spawned by' not in desc:
            bad('AGENT-SPAWN', p, 'description must say "Spawned by <workflow / coordinator> ..."')
        if 'Not for' not in desc:
            bad('AGENT-SPAWN', p, 'description must say "Not for: ..."')
        if not any(f'skills/{s}/SKILL.md' in text for s in k.skills):
            bad('AGENT-SKILL', p, 'body must name the skill (skills/<name>/SKILL.md) it loads first')
    # ---- dangling kit paths in Markdown (and kit paths in workflow prompts)
    ext = r'\.(md|ps1|py|mjs|js|json|html|ini|txt)$'
    skip = re.compile(r'[<>*{}$]|\.local\.|^(examples)/|swarm\.(config\.)?json$|^https?:|\.claude-runtime|^~|^\.\.\./')
    basenames = {os.path.basename(f) for f in k.files}
    kit_dirs = tuple(['skills/', 'rules/', 'agents/', 'workflows/'] + [s + '/' for s in k.skills])

    def overlay(f):
        return '.local.' in f or any(f == p or f.startswith(p + '/') for p in k.local_only)
    for f in k.files:
        if not f.endswith('.md') or f.endswith(('LESSONS.md', 'HISTORY.md')):
            continue
        fdir, sk = os.path.dirname(f), skill_of(f)
        for tok in re.findall(r'`([^`\n]+)`', k.texts.get(f, '')):
            t = (tok.strip().split() or [''])[0].replace('\\', '/')
            t = re.sub(r'^(<workspace>/)?\.claude/|^<kit>/', '', t).rstrip('.,;:)')
            if not re.search(ext, t) or skip.search(t) or re.match(r'^([A-Za-z]:)?/', t):
                continue   # absolute paths point outside the kit on purpose (personal or org tools)
            if overlay(f) and not t.startswith(kit_dirs):
                continue   # org overlay files may name project files and org tools; only their kit paths are checked
            if t.split('/')[0] in REPO_ONLY:   # the repo's docs/examples ship in every clone (the repo root is the kit)
                if t not in k.repo_files:
                    bad('REF-DANGLING', f, f'{t}: no such file in the kit repo')
                continue
            if os.path.basename(t).startswith('.'):
                continue
            if '/' not in t:
                if t.endswith(('.ps1', '.py', '.mjs')) and t not in basenames:
                    bad('REF-DANGLING', f, f'{t}: no such kit script')
                continue
            cands = [t, os.path.normpath(os.path.join(fdir, t)).replace('\\', '/'), 'skills/' + t]
            if sk:   # relative to the skill folder, ../other-skill/... included
                cands.append(os.path.normpath(f'skills/{sk}/{t}').replace('\\', '/'))
            cands += [f'skills/{s}/{t}' for s in k.skills]   # a skill-relative path written in another skill's or an agent's text
            if not any(c in k.fileset or c in k.all for c in cands):
                bad('REF-DANGLING', f, f'{t}: no such kit file')
    # ---- reach (the same graph the kit-flow page draws)
    for f, n in sorted(g['nodes'].items()):
        if (n['kind'] in ('history', 'other', 'config') and n['local']) or os.path.basename(f).startswith('.'):
            continue   # harness/git dotfiles (.gitignore, .gitattributes) are not reached through the router
        if n['reach'] == 'none' and n['kind'] != 'history':
            bad('REACH-NONE', f, 'unreached: nothing in the kit leads here')
        elif n['reach'] == 'mention-only' and n['kind'] != 'history':
            bad('REACH-MENTION', f, 'reached only through a mention: list it in a Files index or the router')
    for f, why in k.junk:
        bad('JUNK', f, why)
    # ---- runtime and durable paths: one map (kitpaths.json), resolved only by the helpers
    try:
        pmap = json.loads(k.texts.get(PATHS_JSON) or read(os.path.join(k.dir, PATHS_JSON)) or '{}')
    except ValueError:
        pmap = {}
        bad('RUNTIME-MAP', PATHS_JSON, 'invalid JSON')
    raw = [(re.compile(r'\.claude-runtime[\\/]+[\w<$]'), 'a hard-coded .claude-runtime/<sub> path'),
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
    if pmap:
        for w, p in k.workflows.items():
            m = re.search(r'^const KP = (\{.*\})\s*$', k.texts.get(p, ''), re.M)
            if not m:
                if re.search(r'\$\{RT\}|\brp\(', k.texts.get(p, '')):
                    bad('RUNTIME-MAP', p, 'uses runtime paths without a `const KP = {...}` map (copy the names from kitpaths.json)')
                continue
            try:
                kp = json.loads(m.group(1))
            except ValueError:
                bad('RUNTIME-MAP', p, 'const KP must be JSON (double quotes) so kit-lint can compare it with kitpaths.json')
                continue
            for sect in ('runtime', 'durable'):
                for n, v in (kp.get(sect) or {}).items():
                    if (pmap.get(sect) or {}).get(n) != v:
                        bad('RUNTIME-MAP', p, f'KP.{sect}["{n}"] = "{v}" but kitpaths.json says "{(pmap.get(sect) or {}).get(n)}"')
        rt = os.environ.get('CLAUDE_RUNTIME') or os.path.join(k.dir, pmap.get('runtimeDir', '.claude-runtime'))
        for n in LEGACY_DURABLE:
            if os.path.exists(os.path.join(rt, n)):
                bad('RUNTIME-DURABLE', f'<runtime>/{n}', 'durable state inside the disposable runtime (old layout): '
                    'kit-setup.ps1 -Migrate <runtime folder> moves it out (in place: leftovers are parked in cache/old-layout)')
    # ---- config keys documented (the kit copy of the configuration reference)
    conf = k.texts.get('skills/dev-kit/reference/configuration.md', '')
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
                    bad('CONFIG-UNDOC', f, f'key "{key}" is not documented in skills/dev-kit/reference/configuration.md')
    # ---- org terms (published files only, plus the repo's README/docs/examples)
    if org_terms:
        scan = [(f, k.texts.get(f) or read(os.path.join(k.dir, f))) for f in k.files
                if not ('.local.' in f or any(f == p or f.startswith(p + '/') for p in k.local_only))]
        scan += [(f, read(os.path.join(k.dir, f))) for f in k.repo_files if f.split('/')[0] != 'LICENSE']
        # whole words; a term with a capital letter matches case-sensitively (e.g. a folder name vs the English word)
        # a term ending in * is a prefix (task-id stems, codes that continue with more characters)
        pats = [(t.strip(), re.compile(r'(?<![\w-])' + re.escape(t.strip().rstrip('*')) + ('' if t.strip().endswith('*') else r'(?![\w-])'),
                                      0 if t.strip() != t.strip().lower() else re.I))
                for t in org_terms if t.strip()]
        for where, text in scan:
            for t, rx in pats:
                if rx.search(text):
                    bad('ORG-TERM', where, f'contains org term "{t}"')
    return probs


# kit-flow's issue groups for each lint code (the page lists lint problems under these headings)
ISSUE_TYPE = {'REACH-NONE': 'unreached', 'REACH-MENTION': 'accidental', 'SKILL-DESC': 'fuzzy trigger', 'SKILL-FUZZY': 'fuzzy trigger',
              'AGENT-SPAWN': 'fuzzy trigger', 'WF-WHEN': 'fuzzy trigger', 'REF-DANGLING': 'dangling', 'JUNK': 'junk',
              'RUNTIME-RAW': 'junk', 'RUNTIME-MAP': 'dangling', 'RUNTIME-DURABLE': 'junk'}
