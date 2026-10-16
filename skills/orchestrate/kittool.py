#!/usr/bin/env python3
"""kittool.py: the kit's own tooling in one file - lint, flow graph, ports, audit, cost. Python 3.8+, no dependencies.

  python -X utf8 kittool.py lint  [<kit>] [--summary] [--warn] [--no-flow] [--org-terms <kit.local.json | a,b>] [--json <out>]
  python -X utf8 kittool.py flow  [<kit>] [--out <file.html>] [--readme] [--watch] [--open]
  python -X utf8 kittool.py port  [--check]
  python -X utf8 kittool.py audit setup|config|recover|scan|stamp|due [--kit <dir>] [--fix] [--fill] [--json <file>]
  python -X utf8 kittool.py cost  [<kit>] [--steps] [--json]

Inputs: the kit folder (default: the kit this file lives in), skills/dev-kit/paths.json, kit.local.json (org terms, localOnly).
Outputs: text; --json files; flow writes the live clone's <runtime>/cache/kit-flow.html (from any worktree) and (--readme) the graph sections of README.md.
Exit codes: 0 ok · 1 problems found (lint, stale ports, ACT/ASK audit findings) · 2 usage error.

lint checks (the same graph flow draws; strict: every problem fails, --warn reports only):
  ROUTER-MISSING / ROUTER-TARGET / ROUTER-UNROUTED  AGENTS.md "## Router" (imported by CLAUDE.md); one target per row; every skill, workflow, agent routed
  OVERLAY-ROUTER  a workspace with rules/*.local.md needs a "## Org router rows" section
  SKILL-DESC / SKILL-BLOCK / SKILL-FUZZY  description "Load when: ... Not when: ... -> <sibling>"; the four blocks; no "read when you need it"
  FILES-UNLISTED / FILES-MISSING / FILES-UNBOUND  the Files index lists every file of the folder (and the <kit>/... files it binds) with its step
  WF-WHEN / WF-CLOCK / WF-CRLF  whenToUse = a router row word for word; no Date.now/new Date; LF only
  AGENT-SPAWN / AGENT-SKILL  "Spawned by" and "Not for" in the description; the body names the skill it loads first
  REF-DANGLING    a kit path in Markdown points at nothing
  REACH-NONE / REACH-MENTION  a file not reached from the root through explicit edges (mentions do not count)
  JUNK            runtime output or reserved-name files among the kit files
  RUNTIME-RAW / RUNTIME-MAP / RUNTIME-DURABLE  paths built by hand; a workflow's `const KP` differs from paths.json; durable state in the runtime
  CONFIG-UNDOC    a kit.example.json key missing from README "Configuration"
  FILE-CAP        more than 50 tracked files (ports .codex/ .agents/ GEMINI.md excluded)
  BUDGET          a file or the kit over its token budget (CONTRIBUTING "Hard rules"); the top consumers are listed
  SCRIPT-HEADER   an entry script without a header block naming its usage and "Exit codes"
PROSE           a kit file, lesson or History line breaks its templates.md "Writing standards" limits
DESKTOP-OPEN    a script opens a file, browser or app on the desktop without an explicit --open / -Open flag
  LESSONS-CAP     a LESSONS.md skill section over 40 lines
  README-GRAPH    README.md graph sections out of date (kittool.py flow --readme; the pre-commit hook runs it)
  ORG-TERM        an org term in a published file (only with --org-terms)

audit:
the mechanical half of the kit audit (skills/kit-audit/SKILL.md). The agent reads and judges; this tool lists.

  python -X utf8 kittool.py audit setup   [--kit <dir>] [--fix]    # install state: clone, pre-push gate, excludes, runtime, hooks, ports, CLIs
  python -X utf8 kittool.py audit config  [--kit <dir>] [--fill]   # local config vs example, docs and the keys scripts read
  python -X utf8 kittool.py audit recover [--kit <dir>] [--fix]    # worktrees, kit branches, launches, board, tracked local files, runtime
  python -X utf8 kittool.py audit scan    [--kit <dir>]            # consistency + script pitfall candidates (run it on the audit worktree)
  python -X utf8 kittool.py audit stamp   [--kit <dir>]            # record the audit time (resets the weekly SessionStart nudge)
  python -X utf8 kittool.py audit due     [--kit <dir>]            # when the last audit ran and whether the next one is due
  any: --json <file> (findings as JSON)

--kit default: setup/config/recover/stamp/due = the LIVE clone (the main worktree of this script's kit repo, so running it from an
audit worktree still checks the installed kit); scan = the kit this script lives in (the worktree you are changing).
Output: one line per finding `<LEVEL> <CODE> <where>: <what> [-> <fix>]`. LEVEL: FIX (repaired now) | ACT (repair it) |
ASK (only the lead can supply it: hosts, ids, credentials) | WARN (judge it: candidate, not proof) | INFO.
--fix / --fill repair only what is safe and reversible; everything else is listed. Never prints a config VALUE (key paths only:
local files hold hosts, ids and passwords). Exit 1 when an ACT or ASK finding remains, else 0.
"""
import contextlib, datetime, fnmatch, io, json, os, re, shutil, subprocess, sys, tempfile, time
from collections import defaultdict, deque
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

KIT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # <kit>/skills/orchestrate/kittool.py -> <kit>
HERE = os.path.dirname(os.path.abspath(__file__))

# ================================ 1. paths (paths.json: the one map of runtime + durable state) ================================
with open(os.path.join(KIT_DIR, 'skills', 'dev-kit', 'paths.json'), encoding='utf-8') as _f:
    MAP = json.load(_f)


def runtime_dir(kit=None):
    return os.environ.get('CLAUDE_RUNTIME') or os.path.join(kit or KIT_DIR, MAP['runtimeDir'])


def kit_path(name, create=False, kit=None):
    """Absolute path of a named runtime or durable entry. kit= resolves it for another kit folder (kit-lint on a clone)."""
    if name == 'runtime':
        p, is_dir = runtime_dir(kit), True
    elif name in MAP['runtime']:
        rel = MAP['runtime'][name]
        p, is_dir = os.path.join(runtime_dir(kit), rel.rstrip('/')), rel.endswith('/')
    elif name in MAP['durable']:
        rel = MAP['durable'][name]
        p, is_dir = os.path.join(kit or KIT_DIR, MAP['stateDir'], rel.rstrip('/')), rel.endswith('/')
    else:
        raise KeyError(f'kit_path: unknown name {name!r} (see skills/dev-kit/paths.json)')
    p = os.path.normpath(p)
    if create:
        os.makedirs(p if is_dir else os.path.dirname(p), exist_ok=True)
    return p


@contextlib.contextmanager
def locked(path, stale=120):
    lock = path + '.lock'
    fd = None
    end = time.time() + stale + 10   # a dead writer's lock turns stale (and is taken over) before we give up
    while fd is None:
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lock) > stale:
                    os.remove(lock)
                    continue
            except OSError:
                pass
            if time.time() > end:   # never run the body unlocked (that lost concurrent writes)
                raise TimeoutError(f'could not lock {path} within {stale + 10} s ({lock} is held)')
            time.sleep(0.1)
    try:
        yield
    finally:
        if fd is not None:
            os.close(fd)
            try:
                os.remove(lock)
            except OSError:
                pass


# ================================ 2. graph + checks (lint and flow share it) ================================
SKIP_DIRS = {'node_modules', '__pycache__', '.git', '.runtime', '.state', '.claude-runtime', 'worktrees', 'memory'}
# repo plumbing outside the graph: generated ports (port writes them) and git / legal files (reached by git itself)
REPO_ONLY = ('LICENSE', '.gitignore', '.gitattributes', 'GEMINI.md', '.codex', '.agents')
GENERATED = ('.codex/', '.agents/', 'GEMINI.md')
FILE_CAP = 50
# token budgets (UTF-8 bytes / 4), CONTRIBUTING "Hard rules"
BUDGETS = {'always': 3500, 'skill': 3200, 'agent': 900, 'rule': 900, 'template': 2600, 'templates': 4000, 'doc': 7000, 'lessons': 30000,
           'workflow': 14000, 'ps1': 48000, 'py': 40000, 'mjs': 8000, 'json': 3000, 'tests': 16000, 'total': 360000}
# the one map of runtime + durable paths, and the files allowed to know raw runtime paths (lint RUNTIME-RAW)
PATHS_JSON = 'skills/dev-kit/paths.json'
PATH_HELPERS = {PATHS_JSON, 'skills/dev-kit/lib.ps1', 'skills/dev-kit/devtools.py', 'skills/dev-kit/spec.mjs',
                'skills/qa-kit/browser.mjs', 'skills/orchestrate/kittool.py', 'skills/orchestrate/kit.ps1'}
# durable state that older layouts kept inside the runtime (lint RUNTIME-DURABLE; kit.ps1 setup -Migrate moves it out)
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
        skip = SKIP_DIRS if top else SKIP_DIRS - {'.runtime', '.state', '.claude-runtime', 'worktrees', 'memory'}   # runtime, harness worktrees, auto memory: kit root only
        dirs[:] = [x for x in dirs if x not in skip]
        for f in fs:
            rel = os.path.relpath(os.path.join(d, f), k.dir).replace('\\', '/')
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
                n = n.strip()
                if n.startswith('<kit>/'):   # a kit-level file this skill binds to one of its steps (README, LESSONS.md, tests, hooks)
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
        if f in ('CLAUDE.md', 'AGENTS.md'):
            return 'root'
        if f in ('README.md', 'CONTRIBUTING.md'):
            return 'doc'
        if f.startswith('.githooks/'):
            return 'hook'
        if f.startswith('tests/'):
            return 'script'
        if f.startswith('examples/') or b == 'templates.md':
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
           'reference': 2, 'template': 2, 'lessons': 2, 'history': 2, 'config': 2, 'doc': 2, 'other': 2, 'script': 3}

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
            return ('Run by the harness on ' + ', '.join(hook_targets[f])) if f in hook_targets else 'Run by git (core.hooksPath .githooks, set by kit.ps1 setup)'
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

    why = {}

    def add(src, dst, t=None, reason=None):
        if src != dst and dst in nodes:
            if t:
                edges[(src, dst)] = t
            else:
                edges.setdefault((src, dst), etype(src, dst))
            if reason and (src, dst) not in why:
                why[(src, dst)] = reason[:200]

    for f, n in nodes.items():
        if n['kind'] in ('settings', 'rule', 'rule-scoped') and 'CLAUDE.md' in nodes:
            add('CLAUDE.md', f, 'route', 'the harness loads it with CLAUDE.md' + (' (path-scoped)' if n['kind'] == 'rule-scoped' else ''))
    # the Files index is the explicit path into a skill's files (glob entries cover overlay files like project profiles)
    for s, entries in k.index.items():
        for _, when, hits in entries:
            for h in hits:
                add(f'skills/{s}/SKILL.md', h, 'index', f'Files index: {when}')
    if 'CLAUDE.md' in nodes and 'AGENTS.md' in nodes:
        add('CLAUDE.md', 'AGENTS.md', 'import', 'CLAUDE.md imports AGENTS.md (@AGENTS.md): the Router')
    for cells in table_rows(k.router or ''):   # router rows: the row id + its conditions are the reason
        for s in k.skills:
            if re.search(r'`' + re.escape(s) + r'[`\s]', ' '.join(cells[2:3])):
                add('AGENTS.md' if 'AGENTS.md' in nodes else 'CLAUDE.md', f'skills/{s}/SKILL.md', 'route', f'Router {cells[0]}: {cells[1]}')
        for w, p in k.workflows.items():
            if '/' + w in ' '.join(cells[2:3]):
                add('AGENTS.md' if 'AGENTS.md' in nodes else 'CLAUDE.md', p, 'route', f'Router {cells[0]}: {cells[1]}')
        for a, p in k.agents.items():
            if '`' + a + '`' in ' '.join(cells[2:3]):
                add('AGENTS.md' if 'AGENTS.md' in nodes else 'CLAUDE.md', p, 'route', f'Router {cells[0]}: {cells[1]}')
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
                ln = t.count('\n', 0, m.start()) + 1
                add(src, hit, None, f'{os.path.basename(src)}:{ln}: ' + t.splitlines()[ln - 1].strip()[:160] if t else None)
        for s in k.skills:
            mm = re.search(r'(?<![\w-])' + re.escape(s) + r'(?![\w-])', t)
            if mm:
                add(src, f'skills/{s}/SKILL.md', None, f'{os.path.basename(src)}:{t.count(chr(10), 0, mm.start()) + 1} names {s}')
        for n, f in k.agents.items():
            mm = re.search(r'(?<![\w-])' + re.escape(n) + r'(?![\w-])', t)
            if mm:
                add(src, f, None, f'{os.path.basename(src)}:{t.count(chr(10), 0, mm.start()) + 1} names {n}' + (' (spawns it)' if src.startswith('workflows/') else ''))
        for n, f in k.workflows.items():
            mm = re.search(r'(?<![\w-])/?' + re.escape(n) + r'(?![\w-])', t)
            if mm:
                add(src, f, None, f'{os.path.basename(src)}:{t.count(chr(10), 0, mm.start()) + 1} names /{n}')
    for tgt, evs in hook_targets.items():
        if 'settings.json' in nodes:
            edges[('settings.json', tgt)] = 'hook'
            why[('settings.json', tgt)] = 'hook: ' + ', '.join(evs)

    entries = [f for f in ('CLAUDE.md',) if f in nodes] or [f for f, n in nodes.items() if n['kind'] == 'root']   # ONE root: everything else must be reached from it
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
    return {'nodes': nodes, 'edges': edges, 'why': why}


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
            if (re.match(r'(reference|templates)/', n) or n.endswith('templates.md')) and not re.search(r'\bsteps?\b|\b[A-Z]\d+[a-z]?\b', when, re.I):
                bad('FILES-UNBOUND', p, f'{n}: say at which step (or event row) it is read or filled')
            if os.path.basename(n) == 'LESSONS.md' and not re.search(r'step [A-Z]?0\b|\bstart|\bfirst|before anything', when, re.I):
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
    skip = re.compile(r'[<>*{}$]|\.local\.|^(examples)/|swarm\.(config\.)?json$|^https?:|\.(?:claude-)?runtime|\.state/|^~|^\.\.\./')
    basenames = {os.path.basename(f) for f in k.files}
    kit_dirs = tuple(['skills/', 'rules/', 'agents/', 'workflows/'] + [s + '/' for s in k.skills])

    def overlay(f):
        return '.local.' in f or any(f == p or f.startswith(p + '/') for p in k.local_only)
    for f in k.files:
        if not f.endswith('.md') or f.endswith('LESSONS.md'):
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
        if (n['kind'] in ('history', 'other', 'config') and n['local']) or (os.path.basename(f).startswith('.') and not f.startswith('.githooks/')):
            continue   # harness/git dotfiles (.gitignore, .gitattributes) are not reached through the router
        if n['reach'] == 'none' and n['kind'] != 'history':
            bad('REACH-NONE', f, 'unreached: nothing in the kit leads here')
        elif n['reach'] == 'mention-only' and n['kind'] != 'history':
            bad('REACH-MENTION', f, 'reached only through a mention: list it in a Files index or the router')
    for f, why in k.junk:
        bad('JUNK', f, why)
    # ---- the 50-file cap (generated ports excluded)
    tracked = []
    try:
        r = subprocess.run(['git', '-C', k.dir, 'ls-files'], capture_output=True, text=True, encoding='utf-8', timeout=30)
        tracked = [x for x in r.stdout.splitlines() if x] if r.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired):
        pass
    counted = [x for x in (tracked or k.files) if not x.startswith(GENERATED)]
    if len(counted) > FILE_CAP:
        bad('FILE-CAP', 'kit', f'{len(counted)} tracked files (cap {FILE_CAP}, ports excluded): merge files (CONTRIBUTING "Hard rules")')
    # ---- token budgets per file type and in total
    def tok(f):
        try:
            return os.path.getsize(os.path.join(k.dir, f)) // 4
        except OSError:
            return 0
    def btype(f):
        b = os.path.basename(f)
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
        if f in ('README.md', 'CONTRIBUTING.md'):
            return 'doc'
        if f == 'skills/dev-kit/templates.md':   # every template + the Writing standards table
            return 'templates'
        if f.startswith('workflows/'):
            return 'workflow'
        if f.endswith('.md'):
            return 'template'
        ext = os.path.splitext(f)[1][1:]
        return ext if ext in BUDGETS else None
    sizes = {f: tok(f) for f in counted}
    over = [(f, n, BUDGETS[btype(f)]) for f, n in sizes.items() if btype(f) and n > BUDGETS[btype(f)]]
    always = sum(sizes.get(f, 0) for f in ('CLAUDE.md', 'AGENTS.md') + tuple(f for f in counted if re.match(r'rules/[^/]+\.md$', f) and 'paths' not in frontmatter(k.texts.get(f, ''))))
    if always > BUDGETS['always']:
        over.append(('always-loaded (CLAUDE.md + AGENTS.md + rules)', always, BUDGETS['always']))
    total = sum(sizes.values())
    if total > BUDGETS['total']:
        over.append(('kit total', total, BUDGETS['total']))
    if over:
        top = ', '.join(f'{f} {n}' for f, n in sorted(sizes.items(), key=lambda x: -x[1])[:5])
        for f, n, cap in over:
            bad('BUDGET', f, f'{n} tokens (cap {cap}); top consumers: {top}')
    # ---- script headers: usage + exit codes in the first lines of every entry script
    for f in counted:
        if not f.endswith(('.ps1', '.py', '.mjs')) or f.startswith(GENERATED):
            continue
        head = '\n'.join(k.texts.get(f, '').splitlines()[:40])
        if not re.search(r'Exit codes?:', head, re.I) or not re.search(r'usage|verbs?:|\bpython\b|\bpwsh\b|^\s*[#/]*\s*&\s', head, re.I | re.M):
            bad('SCRIPT-HEADER', f, 'no header block with usage and "Exit codes:" in the first 40 lines (dev-kit/templates.md "Script header")')
    # ---- nothing opens on the owner's desktop (file, browser, app) unless an explicit --open / -Open flag asked for it
    rx_open = {'.py': r'os\.startfile\(|webbrowser\.open|\[\s*[\'"](?:xdg-open|open)[\'"]',
                '.ps1': r'^\s*(?:Invoke-Item|ii)\s|Start-Process\s+(?:-FilePath\s+)?[\'"]?(?:https?://|[^\s\'"]+\.(?:html?|md|pdf|png|jpe?g|txt|csv|log)\b)|\bcmd(?:\.exe)?\s+/c\s+start\b|^\s*(?:start|explorer(?:\.exe)?)\s+\S',
                '.mjs': r'\bexec(?:Sync)?\(\s*[\'"`](?:start|open|xdg-open)\s|\bimport\s.*[\'"]open[\'"]',
                '.js': r'\bexec(?:Sync)?\(\s*[\'"`](?:start|open|xdg-open)\s'}
    for f in counted:
        ext = os.path.splitext(f)[1]
        if ext not in rx_open or f.startswith(GENERATED):
            continue
        ls = k.texts.get(f, '').splitlines()
        for i, line in enumerate(ls):
            if re.match(r'\s*(#|//|@\(\s*'')', line) or not re.search(rx_open[ext], line):   # comments, guard self-test data
                continue
            if not re.search(r'--open|\$Open\b|open_it|opts\.open', '\n'.join(ls[max(0, i - 5):i + 1])):
                bad('DESKTOP-OPEN', f'{f}:{i + 1}', 'opens a file, browser or app on the desktop without an explicit --open / -Open flag (CONTRIBUTING "Script")')
    # ---- writing standards (templates.md): the kit's own files, each lesson and History line
    try:
        wkinds, wbanned = writing_standards(KIT)
    except Exception:   # no templates.md yet: nothing to measure against
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
                    bad('PROSE', f'LESSONS.md:{ln}', f'{cur}: {p_}')    # ---- lessons: 40 lines per skill section
    lt = k.texts.get('LESSONS.md', '')
    for m in re.finditer(r'^## (?!History)(\S+)\n(.*?)(?=^## |\Z)', lt, re.S | re.M):
        n = len([l for l in m.group(2).splitlines() if l.startswith('- ')])
        if n > 40:
            bad('LESSONS-CAP', f'LESSONS.md ## {m.group(1)}', f'{n} lessons (cap 40): orch.ps1 learn -Skill {m.group(1)} -Trim')
    # ---- README graph sections current
    rd = k.texts.get('README.md', '')
    if '<!-- kit-graph:start' in rd and update_readme(rd, readme_sections(k, g)) != rd:
        bad('README-GRAPH', 'README.md', 'graph sections out of date: python -X utf8 skills/orchestrate/kittool.py flow --readme (the pre-commit hook does it)')
    # ---- runtime and durable paths: one map (kitpaths.json), resolved only by the helpers
    try:
        pmap = json.loads(k.texts.get(PATHS_JSON) or read(os.path.join(k.dir, PATHS_JSON)) or '{}')
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
        rt = os.environ.get('CLAUDE_RUNTIME') or os.path.join(k.dir, pmap.get('runtimeDir', '.runtime'))
        for n in LEGACY_DURABLE:
            if os.path.exists(os.path.join(rt, n)):
                bad('RUNTIME-DURABLE', f'<runtime>/{n}', 'durable state inside the disposable runtime (old layout): '
                    'kit.ps1 setup -Migrate moves it out')
    # ---- config keys documented (the kit copy of the configuration reference)
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



# ---- README graph sections (Mermaid: GitHub renders it; the pre-commit hook keeps them current)
FLOW_VIEWS = {
    'dev': ['flowchart LR',
            '  T([task / bug]) --> C[dev-agent: code]',
            '  C --> G[testing-goals doc]',
            '  G --> R{bug?}',
            '  R -->|yes| RP[reproduce on the local env]',
            '  R -->|no| L',
            '  RP --> L[local test loop: deploy branch, lease, run every goal]',
            '  L -->|goal fails, < 3 rounds| C',
            '  L -->|3 rounds failed| SR[one stronger fix round]',
            '  SR -->|still failing| B[[held: the coordinator decides]]',
            '  L -.->|coordinator-only env fix| EF[[ENV-FIX: the coordinator fixes, the item waits]]',
            '  EF -.->|done| L',
            '  C -.->|behaviour not asked for / several paths| D[[decision request: the item waits]]',
            '  D -.->|owner answers| C',
            '  L -->|every goal passes| V[review + CI]',
            '  V -->|findings / red| C',
            '  V -->|clean, green| M[merge, producers first]',
            '  M --> H[human testing doc + tracker promoted]',
            '  H --> DB[merged work waits: nobody asks]',
            '  DB -->|a person says deploy env| DP[deploy at once + record]',
            '  DP --> IT[tracker inTest]',
            '  IT --> HT([testers close it, or failedTesting -> back to dev])'],
    'test-only': ['flowchart LR',
                  '  Q([deployed tasks + testing docs]) --> TE[qa-tester per doc: web, API, phone lanes]',
                  '  TE --> AU[note audit]',
                  '  AU --> SR[stronger retry of NOT_TESTED]',
                  '  SR -->|local env, still NOT_TESTED| EF[[ENV-FIX: coordinator fixes, retest; then held]]',
                  '  SR --> VE[qa-verifier re-tests every FAIL]',
                  '  VE --> FI{result rule}',
                  '  FI -->|all pass| CL[closed]',
                  '  FI -->|own check failed / incomplete on a shared env| FT[failedTesting: back to dev, no new task]',
                  '  FI -->|new defect| BG[one Bug task under the ask]',
                  '  FT --> BW[bugfix wave: reproduce locally first]',
                  '  BG --> BW'],
    'local-env': ['flowchart LR',
                  '  BR[branch] -->|localenv deploy| TR[train: merge, gated build, switch-over]',
                  '  TR -->|conflict / build fail| RF[refused / rejected: fix]',
                  '  TR --> LV[live release]',
                  '  LV -->|use: lease| CK[goals: api, browser, phone with the local-env APK]',
                  '  CK -->|errors| DBG[debug: logs, events, DB read-only, debugPort]',
                  '  DBG --> BR',
                  '  CK -->|every goal passes| PR[promote, release]'],
    'deploy': ['flowchart LR',
               '  MW[merged MRs from every session] --> PL[orch deploy plan]',
               '  RQ[deploy request: workflows] --> PL',
               '  CI[last deploy: CI + kit log] --> PL',
               '  PL -->|trigger owner| RD[READY: waits, nobody asks]',
               '  RD -->|a person says deploy env| DO[deploy per org rules]',
               '  PL -->|trigger ask, window open| ASK[ASK the owner once per env]',
               '  PL -->|trigger ask, inside the window| WT[WAIT until the window ends]',
               '  ASK -->|yes| DO',
               '  DO --> RC[deploy record] --> IN[deploy intest]'],
}


def readme_sections(k, g):
    """The README's generated sections: the map (root -> router -> skills / workflows / agents), the flows, one per skill."""
    nodes, edges = g['nodes'], g['edges']
    label = lambda f: nodes[f]['label'] if f in nodes else f
    nid = lambda f: re.sub(r'[^A-Za-z0-9]', '_', f)
    out = {}
    lines = ['flowchart LR', '  CLAUDE_md[CLAUDE.md] -->|import| AGENTS_md[AGENTS.md Router]']
    # the README is published: local-overlay parts (localOnly paths, *.local.*) never appear in it, whichever clone regenerates it
    pub = lambda f: f in nodes and not nodes[f].get('local')
    tops = [f for f, n in sorted(nodes.items()) if n['kind'] in ('skill', 'workflow', 'agent') and pub(f)]
    for f in tops:
        shape = {'skill': '[{}]', 'workflow': '[/{}/]', 'agent': '({})'}[nodes[f]['kind']]
        lines.append(f'  {nid(f)}' + shape.format(label(f)))
    for (a, b), typ in sorted(edges.items()):
        if a in ('AGENTS.md',) and b in tops and typ == 'route':
            lines.append(f'  AGENTS_md --> {nid(b)}')
        elif a in tops and b in tops and typ == 'spawn' and nodes[a]['kind'] == 'workflow':
            lines.append(f'  {nid(a)} -->|spawns| {nid(b)}')
    for a, p in sorted(k.agents.items()):   # an agent's skill = the one its "Load first" line names
        m = re.search(r'Load first:\*\*\s*`[^`]*skills/([\w-]+)/SKILL\.md', k.texts.get(p, ''))
        if m and f'skills/{m.group(1)}/SKILL.md' in nodes:
            lines.append(f'  {nid(p)} -->|loads| {nid(f"skills/{m.group(1)}/SKILL.md")}')
    out['map'] = lines
    for name, body in FLOW_VIEWS.items():
        out[f'flow-{name}'] = body
    for s in k.skills:
        sk = f'skills/{s}/SKILL.md'
        if not pub(sk):
            continue
        lines = ['flowchart LR', f'  {nid(sk)}[{s}]']
        for n, when, hits in k.index.get(s, []):
            for h in [h for h in hits if pub(h) or h not in nodes]:
                step = re.sub(r'[`"|\[\]{}<>]', '', when)[:48]
                lines.append(f'  {nid(sk)} -->|{step}| {nid(h)}[{os.path.basename(h)}]')
        out[f'skill-{s}'] = lines
    return out


def update_readme(text, sections):
    """README text with every generated section replaced; missing sections are appended after the map marker."""
    def block(name):
        return f'<!-- kit-graph:start {name} -->\n```mermaid\n' + '\n'.join(sections[name]) + '\n```\n<!-- kit-graph:end -->'
    text = text.replace('\r\n', '\n')
    # a section no part produces any more (a removed or local-only skill) goes, with the blank line before it
    text = re.sub(r'\n*<!-- kit-graph:start ([\w-]+) -->.*?<!-- kit-graph:end -->',
                  lambda m: m.group(0) if m.group(1) in sections else '', text, flags=re.S)
    for name in sections:
        rx = re.compile(r'<!-- kit-graph:start ' + re.escape(name) + r' -->.*?<!-- kit-graph:end -->', re.S)
        if rx.search(text):
            text = rx.sub(lambda m: block(name), text)
        else:
            text = text.rstrip('\n') + '\n\n' + block(name) + '\n'
    return text


# kit-flow's issue groups for each lint code (the page lists lint problems under these headings)
ISSUE_TYPE = {'REACH-NONE': 'unreached', 'REACH-MENTION': 'accidental', 'SKILL-DESC': 'fuzzy trigger', 'SKILL-FUZZY': 'fuzzy trigger',
              'AGENT-SPAWN': 'fuzzy trigger', 'WF-WHEN': 'fuzzy trigger', 'REF-DANGLING': 'dangling', 'JUNK': 'junk',
              'RUNTIME-RAW': 'junk', 'RUNTIME-MAP': 'dangling', 'RUNTIME-DURABLE': 'junk'}


# ================================ 3. flow: the HTML page and the README graph sections ================================
def live_root(kit):
    """The main worktree of kit's repo (the live clone): a worktree's commit or lint refreshes the page the owner opens."""
    try:
        r = subprocess.run(['git', '-C', kit, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                           capture_output=True, text=True, encoding='utf-8', timeout=15)
        main = os.path.dirname(os.path.normpath(r.stdout.strip())) if r.returncode == 0 and r.stdout.strip() else ''
        if main and os.path.isfile(os.path.join(main, PATHS_JSON)):
            return main
    except (OSError, subprocess.TimeoutExpired):
        pass
    return kit


def default_out(kit):
    return kit_path('kit-flow', kit=live_root(kit))


def flow_args(a):
    out = a[a.index('--out') + 1] if '--out' in a else None
    rest = [x for i, x in enumerate(a) if not x.startswith('--') and (i == 0 or a[i - 1] != '--out')]
    kit = os.path.abspath(rest[0] if rest else KIT_DIR)
    return kit, os.path.abspath(out or default_out(kit)), '--watch' in a, '--open' in a, '--readme' in a


GIT_HOOK_EVENT = {'pre-commit': 'git commit', 'pre-push': 'git push', 'post-merge': 'git pull / merge'}


def flow_triggers(k, nodes):
    """Trigger nodes (Router / org rows, Events rows, harness hooks, git hooks, every session) and their edges to files."""
    names = {**{s: f'skills/{s}/SKILL.md' for s in k.skills}, **dict(k.agents)}
    base = defaultdict(list)
    for f in nodes:
        base[os.path.basename(f)].append(f)

    def links(text):
        hit = {p for n, p in names.items() if re.search(r'`' + re.escape(n) + r'[`\s]', text)}
        hit |= {p for w, p in k.workflows.items() if re.search(r'(?<![\w-])/' + re.escape(w) + r'(?![\w-])', text)}
        hit |= {base[b][0] for b in re.findall(r'[\w.-]+\.(?:ps1|py|mjs|js|md|json)\b', text) if len(base.get(b, [])) == 1}
        for gl in re.findall(r'`([^`\s]*\*[^`\s]*)`', text):
            hit |= {f for f in nodes if fnmatch.fnmatch(f, gl)}
        return hit

    def short(s, n=34):
        s = re.sub(r'[`*]', '', s).strip()
        return s if len(s) <= n else s[:n].rsplit(' ', 1)[0] + ' ...'

    trig, edges = {}, []

    def add(tid, tkind, label, desc, targets, why):
        trig.setdefault(tid, {'id': tid, 'label': label, 'kind': 'trigger', 'tkind': tkind, 'trigger': desc, 'reach': 'entry'})
        edges.extend({'s': tid, 't': t, 'type': 'trigger', 'why': why} for t in sorted(targets) if t in nodes)

    for t in tables(k):
        ev = bool(re.search(r'event', t['heading'], re.I))
        if t['head'][:1] != ['#'] or not (ev or re.search(r'router', t['heading'], re.I)):
            continue
        for r in t['rows']:
            if len(r) < 3 or not re.match(r'^[A-Z]+\d+$', r[0]) or 'trigger:' + r[0] in trig:
                continue
            desc = re.sub(r'[`*]', '', f'{r[1]} -> {r[2]}')
            add('trigger:' + r[0], 'event' if ev else 'request', f'{r[0]} {short(r[1])}', desc, links(' '.join(r[2:])), f'{r[0]}: {desc}'[:200])
    try:
        hooks = (json.loads(k.texts.get('settings.json', '{}') or '{}').get('hooks') or {})
    except ValueError:
        hooks = {}
    for event, bl in hooks.items():
        for b in bl:
            ev = event + (f" ({b['matcher']})" if b.get('matcher') else '')
            for h in b.get('hooks', []):
                m = re.search(r'\.claude[\\/]([\w./\\-]+\.(?:ps1|py|js|sh))\s*(.*)', ' '.join([h.get('command', '')] + list(h.get('args', []))))
                if m:
                    f = m.group(1).replace('\\', '/')
                    add('trigger:' + ev, 'hook', ev, f'Claude Code runs hooks on {ev}', {f}, f'{ev}: {os.path.basename(f)} {m.group(2)}'.strip())
    for f in nodes:
        if f.startswith('.githooks/'):
            ev = GIT_HOOK_EVENT.get(os.path.basename(f), 'git ' + os.path.basename(f))
            add('trigger:' + ev, 'git', ev, f'git runs {f} (core.hooksPath)', {f}, f'{ev} runs {f}')
    add('trigger:session', 'session', 'every session', 'The harness loads CLAUDE.md (and its imports, rules)', {'CLAUDE.md'},
        'every session loads CLAUDE.md')
    return list(trig.values()), edges


def page_data(k, g, problems):
    """Page model: trigger + file nodes, trigger -> file and file -> file edges with reasons, kit-lint's problems as issues."""
    nodes = {f: dict(n) for f, n in g['nodes'].items()}
    for f, n in nodes.items():
        text = k.texts.get(f, '')
        if n['kind'] == 'skill':
            n['blocks'] = blocks(text)
        elif n['kind'] == 'agent':
            n['blocks'] = agent_blocks(frontmatter(text).get('description', ''))
        elif n['kind'] == 'workflow':
            m = re.search(r"whenToUse:\s*'((?:[^'\\]|\\.)*)'", text)
            n['blocks'] = {'When to use': m.group(1)} if m else {}
    issues = [{'type': ISSUE_TYPE.get(c, 'lint ' + c.lower()), 'code': c, 'id': w if w in nodes else None,
               'text': (m if w in nodes else f'{w}: {m}')} for c, w, m in problems]
    edges = g['edges']
    trig, tedges = flow_triggers(k, nodes)
    return {'kit': k.dir, 'generated': time.strftime('%Y-%m-%d %H:%M:%S'), 'nodes': trig + list(nodes.values()),
            'edges': tedges + [{'s': a, 't': b, 'type': t, 'why': g.get('why', {}).get((a, b), t)} for (a, b), t in sorted(edges.items())],
            'issues': issues,
            'counts': {'files': len(nodes), 'edges': len(edges), 'triggers': len(trig),
                       'structural': sum(1 for n in nodes.values() if n['reach'] in ('entry', 'structural')), 'issues': len(issues)}}


def build(kit):
    k = load(kit)
    g = graph(k)
    return page_data(k, g, lint(k, g))


def render(kit, out, quiet=False, data=None):
    data = data or build(kit)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    blob = json.dumps(data, ensure_ascii=False).replace('</', '<\\/')
    page = TEMPLATE_HTML.replace('__DATA__', blob)
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write(page)
    c = data['counts']
    if not quiet:
        print(f"kit-flow: {out}  ({c['files']} files, {c['edges']} edges, {c['structural']} reached structurally, {c['issues']} issues)")
    return data


def signature(kit):
    sig = []
    for d, dirs, fs in os.walk(kit):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in fs:
            try:
                st = os.stat(os.path.join(d, f))
                sig.append((d, f, st.st_mtime_ns, st.st_size))
            except OSError:
                pass
    return hash(tuple(sorted(sig)))


def cmd_flow(a):
    kit, out, watch, open_it, readme = flow_args(a)
    if not os.path.isdir(kit):
        sys.exit(f'kittool flow: no such folder {kit}')
    if readme:
        k = load(kit)
        g = graph(k)
        p = os.path.join(kit, 'README.md')
        old = read(p)
        new = update_readme(old, readme_sections(k, g))
        if new != old.replace('\r\n', '\n'):
            with open(p, 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(new)
            print(f'kittool flow: README.md graph sections updated')
    render(kit, out)
    if open_it:
        if sys.platform.startswith('win'):
            os.startfile(out)  # type: ignore[attr-defined]  # noqa
        else:
            subprocess.run(['open' if sys.platform == 'darwin' else 'xdg-open', out], check=False)
    if watch:
        print('kittool flow: watching for changes (Ctrl+C to stop)')
        last = signature(kit)
        while True:
            time.sleep(2)
            cur = signature(kit)
            if cur != last:
                last = cur
                try:
                    render(kit, out)
                except Exception as e:  # keep watching through a half-written file
                    print('kittool flow: render failed, will retry:', e)
    return 0


TEMPLATE_HTML = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kit flow</title>
<style>:root{--bg:#f8fafc;--fg:#0f172a;--mut:#64748b;--ln:#94a3b8;--pn:#ffffffe6;--hi:#d97706;--bad:#dc2626}
@media (prefers-color-scheme:dark){:root{--bg:#0b1120;--fg:#e2e8f0;--mut:#94a3b8;--ln:#64748b;--pn:#111827e6;--hi:#fbbf24;--bad:#f87171}}
html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--fg);font:12px system-ui,sans-serif}
#s{position:fixed;inset:0;width:100%;height:100%;cursor:grab;touch-action:none}
.bar{position:fixed;left:8px;right:8px;display:flex;gap:5px;flex-wrap:wrap;align-items:center;pointer-events:none}.bar>*{pointer-events:auto}
#top{top:8px}#leg{bottom:8px}
.p{background:var(--pn);border:1px solid var(--ln);border-radius:12px;padding:2px 8px;cursor:pointer;user-select:none;display:inline-flex;gap:4px;align-items:center}
.p.off{opacity:.35}.p.bad{border-color:var(--bad);color:var(--bad)}b.p{cursor:default}
#q{background:var(--pn);color:var(--fg);border:1px solid var(--ln);border-radius:12px;padding:3px 8px;width:200px}
#tip{position:fixed;max-width:440px;background:var(--pn);border:1px solid var(--ln);border-radius:6px;padding:6px 8px;pointer-events:none;display:none;white-space:pre-wrap}
.n text{fill:var(--fg);font-size:11px;pointer-events:none}.n{cursor:pointer}.n.bad>:first-child{stroke:var(--bad);stroke-width:2.5}
.n.m>:first-child,.n.sel>:first-child{stroke:var(--hi);stroke-width:3}
.e{fill:none;stroke:var(--ln);stroke-width:1.3;opacity:.5}.e.t{opacity:.8}.e.h{stroke:var(--hi);opacity:1;stroke-width:2}
.dim{opacity:.07!important}.l{font-size:10px;fill:var(--fg);paint-order:stroke;stroke:var(--bg);stroke-width:3px;pointer-events:none}</style></head><body>
<svg id="s"><defs><marker id="a" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L8 4L0 8z" style="fill:var(--ln)"/></marker>
<marker id="ah" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L8 4L0 8z" style="fill:var(--hi)"/></marker></defs><g id="w"></g></svg>
<div class="bar" id="top"><b class="p">kit flow</b><span class="p" id="iss"></span><input id="q" placeholder="search (Enter selects)"><span class="p" id="fit">fit</span></div>
<div class="bar" id="leg"></div><div id="tip"></div>
<script>
const D = __DATA__, NS = 'http://www.w3.org/2000/svg', $ = s => document.querySelector(s);
const mk = (t, a, p) => { const e = document.createElementNS(NS, t); for (const k in a) e.setAttribute(k, a[k]); if (p) p.appendChild(e); return e };
// style per node kind: color, shape, legend name
const ST = {request: ['#2563eb', 'pill', 'request (Router row)'], event: ['#d97706', 'hex', 'coordinator event'], hook: ['#7c3aed', 'tag', 'harness hook'],
  git: ['#db2777', 'tag', 'git hook'], session: ['#0891b2', 'tag', 'session start'], rule: ['#64748b', 'dash', 'root / rule / settings'],
  skill: ['#16a34a', 'rect', 'skill'], workflow: ['#ea580c', 'para', 'workflow'], agent: ['#0d9488', 'oct', 'agent'], script: ['#475569', 'sharp', 'script / file hook'],
  doc: ['#a8a29e', 'note', 'template / reference / doc']};
const sk = n => n.kind === 'trigger' ? n.tkind : ({root: 'rule', 'rule-scoped': 'rule', settings: 'rule', hook: 'script'})[n.kind] || (ST[n.kind] ? n.kind : 'doc');
function shape(s, w, h, p) {
  const c = 8, P = {hex: [[c, 0], [w - c, 0], [w, h / 2], [w - c, h], [c, h], [0, h / 2]], tag: [[0, 0], [w - c, 0], [w, h / 2], [w - c, h], [0, h]],
    para: [[c, 0], [w, 0], [w - c, h], [0, h]], oct: [[5, 0], [w - 5, 0], [w, 5], [w, h - 5], [w - 5, h], [5, h], [0, h - 5], [0, 5]], note: [[0, 0], [w - 7, 0], [w, 7], [w, h], [0, h]]}[s];
  return P ? mk('polygon', {points: P.map(q => q.join(',')).join(' ')}, p) : mk('rect', {width: w, height: h, rx: s === 'pill' ? h / 2 : s === 'sharp' ? 0 : 4, 'stroke-dasharray': s === 'dash' ? '4 2' : ''}, p)
}
const N = D.nodes, by = {}, out = {}, inn = {};
N.forEach(n => { by[n.id] = n; out[n.id] = []; inn[n.id] = [] });
const E = D.edges.filter(e => by[e.s] && by[e.t]);
E.forEach(e => { out[e.s].push(e); inn[e.t].push(e) });
const isT = n => n.kind === 'trigger', bad = new Set(D.issues.map(i => i.id).filter(Boolean));
// layers: kind bands left to right (triggers -> rules -> workflows -> agents -> skills -> docs -> scripts); the DAG for ordering
// keeps only band-increasing, non-mention edges (no cycles, mentions never shape the layout)
const BAND = {rule: 1, workflow: 2, agent: 3, skill: 4, doc: 5, script: 6}, band = n => isT(n) ? 0 : BAND[sk(n)];
const dag = new Set(E.filter(e => e.type !== 'mention' && band(by[e.t]) > band(by[e.s])));
const cols = [];
N.forEach(n => (cols[band(n)] = cols[band(n)] || []).push(n));
for (let i = cols.length - 1; i >= 0; i--) if (!cols[i]) cols.splice(i, 1); else cols[i].sort((a, b) => sk(a).localeCompare(sk(b)) || a.label.localeCompare(b.label));
// barycenter ordering: sweep down (by predecessors) and up (by successors)
const pos = {}, idx = () => cols.forEach(c => c.forEach((n, i) => pos[n.id] = i - (c.length - 1) / 2));
idx();
for (let it = 0; it < 8; it++) {
  const down = it % 2 === 0;
  for (const c of down ? cols.slice(1) : cols.slice(0, -1).reverse()) {
    const bc = {};
    for (const n of c) { const nb = (down ? inn[n.id].map(e => dag.has(e) && e.s) : out[n.id].map(e => dag.has(e) && e.t)).filter(Boolean); bc[n.id] = nb.length ? nb.reduce((s, x) => s + pos[x], 0) / nb.length : pos[n.id] }
    c.sort((a, b) => bc[a.id] - bc[b.id]); idx()
  }
}
const H = 22, DY = 28, GX = 160, tw = s => s.length > 36 ? s.slice(0, 35) + '…' : s;
let X = 0, maxR = Math.max(...cols.map(c => c.length));
for (const c of cols) {
  const w = Math.max(60, ...c.map(n => Math.min(250, 18 + 6.2 * tw(n.label).length)));
  c.forEach((n, i) => { n.w = w; n.x = X; n.y = (i + (maxR - c.length) / 2) * DY });
  X += w + GX
}
const TW = X - GX, TH = maxR * DY, W = $('#w'), EG = mk('g', {}, W), LG = mk('g', {}, W), NG = mk('g', {}, W), tip = $('#tip');
const showTip = (ev, s) => { tip.textContent = s; tip.style.display = 'block'; tip.style.left = Math.min(ev.clientX + 14, innerWidth - 450) + 'px'; tip.style.top = (ev.clientY + 14) + 'px' };
const hide = () => tip.style.display = 'none';
for (const e of E) {
  const a = by[e.s], b = by[e.t], x1 = a.x + a.w, y1 = a.y + H / 2, x2 = b.x, y2 = b.y + H / 2, d = Math.max(50, Math.abs(x2 - x1) / 2);
  e.p = [x1, y1, x1 + d, y1, x2 - d, y2, x2, y2];
  e.el = mk('path', {d: `M${x1},${y1}C${x1 + d},${y1} ${x2 - d},${y2} ${x2},${y2}`, class: 'e' + (e.type === 'trigger' ? ' t' : ''), 'marker-end': 'url(#a)'}, EG);
  e.el.onmousemove = ev => showTip(ev, `${a.label} → ${b.label}  [${e.type}]\n${e.why || ''}`); e.el.onmouseleave = hide
}
for (const n of N) {
  const [col, s] = ST[sk(n)], g = mk('g', {class: 'n', transform: `translate(${n.x},${n.y})`}, NG);
  g.dataset.id = n.id;
  const sh = shape(s, n.w, H, g); sh.setAttribute('style', `fill:${col}33;stroke:${col};stroke-width:1.4`);
  mk('text', {x: n.w / 2, y: H / 2 + 4, 'text-anchor': 'middle'}, g).textContent = tw(n.label);
  if (bad.has(n.id)) g.classList.add('bad');
  const bl = Object.entries(n.blocks || {}).map(([k, v]) => `${k}: ${v.slice(0, 160)}`).join('\n');
  g.onmousemove = ev => showTip(ev, `${n.id}  [${n.kind === 'trigger' ? n.tkind : n.kind}]\n${(n.trigger || '').slice(0, 320)}${bl ? '\n' + bl : ''}`); g.onmouseleave = hide;
  n.el = g
}
// edge-type toggles (file -> file calls / loads / mentions hidden by default) + node legend
const on = new Set(['trigger', 'route', 'import', 'hook', 'spawn', 'scoped', 'index']), cnt = {};
E.forEach(e => cnt[e.type] = (cnt[e.type] || 0) + 1);
const leg = $('#leg');
for (const t of Object.keys(cnt).sort((a, b) => (a !== 'trigger') - (b !== 'trigger') || cnt[b] - cnt[a])) {
  const b = document.createElement('span'); b.className = 'p' + (on.has(t) ? '' : ' off'); b.textContent = `${t === 'trigger' ? 'trigger → file' : t} ${cnt[t]}`;
  b.title = 'show / hide these edges'; b.onclick = () => { on.has(t) ? on.delete(t) : on.add(t); b.classList.toggle('off'); update() }; $('#top').appendChild(b)
}
for (const k in ST) if (N.some(n => sk(n) === k)) {
  const b = document.createElement('span'); b.className = 'p'; const sv = mk('svg', {width: 26, height: 14}, b), sh = shape(ST[k][1], 24, 12, sv);
  sh.setAttribute('style', `fill:${ST[k][0]}33;stroke:${ST[k][0]};stroke-width:1.2`); sh.setAttribute('transform', 'translate(1,1)'); b.append(ST[k][2]); leg.appendChild(b)
}
const iss = $('#iss');
iss.textContent = `${D.counts.issues} issue${D.counts.issues === 1 ? '' : 's'}`; iss.title = D.issues.map(i => `${i.code} ${i.text}`).join('\n') || 'kittool lint: 0 problems';
if (D.counts.issues) iss.classList.add('bad');
let sel = null, issMode = false;
iss.onclick = () => { issMode = !issMode && D.counts.issues > 0; sel = null; update() };
function update() {
  const vis = e => on.has(e.type), q = $('#q').value.trim().toLowerCase(), path = new Set();
  let keep = null;
  if (sel) {
    keep = new Set([sel]);
    for (const [adj, k] of [[inn, 's'], [out, 't']]) {
      const todo = [sel], seen = new Set(todo);
      while (todo.length) for (const e of adj[todo.pop()]) if (vis(e)) { path.add(e); keep.add(e[k]); if (!seen.has(e[k])) { seen.add(e[k]); todo.push(e[k]) } }
    }
  } else if (issMode) keep = bad;
  const match = q ? new Set(N.filter(n => (n.id + ' ' + n.label + ' ' + (n.trigger || '')).toLowerCase().includes(q)).map(n => n.id)) : null;
  if (!keep && match) keep = match;
  for (const n of N) { n.el.classList.toggle('dim', !!keep && !keep.has(n.id)); n.el.classList.toggle('m', !!match && match.has(n.id)); n.el.classList.toggle('sel', n.id === sel) }
  LG.innerHTML = '';
  for (const e of E) {
    const direct = sel && (e.s === sel || e.t === sel), shown = vis(e) || direct, h = sel ? path.has(e) || direct : false;
    e.el.style.display = shown ? '' : 'none';
    e.el.classList.toggle('h', h); e.el.setAttribute('marker-end', h ? 'url(#ah)' : 'url(#a)');
    e.el.classList.toggle('dim', !!keep && !h && !(keep.has(e.s) && keep.has(e.t) && !sel));
    if (direct && vis(e)) { const p = e.p, x = (p[0] + 3 * p[2] + 3 * p[4] + p[6]) / 8, y = (p[1] + 3 * p[3] + 3 * p[5] + p[7]) / 8;
      mk('text', {x, y: y - 3, class: 'l', 'text-anchor': 'middle'}, LG).textContent = tw(e.why || e.type) }
  }
}
// pan / zoom
const S = $('#s');
let tx = 0, ty = 0, sc = 1, drag = null;
const ap = () => W.setAttribute('transform', `translate(${tx},${ty}) scale(${sc})`);
const fit = () => { sc = Math.min(innerWidth / (TW + 60), (innerHeight - 90) / (TH + 40), 1.5); tx = (innerWidth - TW * sc) / 2; ty = 50 + (innerHeight - 90 - TH * sc) / 2; ap() };
S.addEventListener('wheel', ev => { ev.preventDefault(); const f = Math.exp(-ev.deltaY * .0015); tx = ev.clientX - (ev.clientX - tx) * f; ty = ev.clientY - (ev.clientY - ty) * f; sc *= f; ap() }, {passive: false});
S.addEventListener('pointerdown', ev => drag = {x: ev.clientX, y: ev.clientY, tx, ty, moved: false});
addEventListener('pointermove', ev => { if (!drag) return; const dx = ev.clientX - drag.x, dy = ev.clientY - drag.y; if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true; if (drag.moved) { tx = drag.tx + dx; ty = drag.ty + dy; ap() } });
addEventListener('pointerup', ev => {
  if (drag && !drag.moved) { const g = ev.target.closest && ev.target.closest('.n'); sel = g && g.dataset.id !== sel ? g.dataset.id : null; issMode = false; update() }
  drag = null
});
$('#fit').onclick = fit; addEventListener('resize', fit);
$('#q').oninput = () => { sel = null; update() };
$('#q').onkeydown = ev => {
  if (ev.key !== 'Enter') return;
  const q = ev.target.value.trim().toLowerCase(), n = N.find(n => (n.id + ' ' + n.label + ' ' + (n.trigger || '')).toLowerCase().includes(q));
  if (n) { sel = n.id; tx = innerWidth / 2 - (n.x + n.w / 2) * sc; ty = innerHeight / 2 - (n.y + H / 2) * sc; ap(); update() }
};
addEventListener('keydown', ev => { if (ev.key === 'Escape') { sel = null; issMode = false; $('#q').value = ''; update() } });
fit(); update();
</script></body></html>
'''


# ================================ 4. lint ================================
def cmd_lint(args):
    def opt(name, has_value=False):
        if name not in args:
            return None
        i = args.index(name)
        args.pop(i)
        if not has_value:
            return True
        if i >= len(args) or args[i].startswith('--'):
            sys.exit(f'kittool lint: {name} needs a value (see the usage at the top of kittool.py)')
        return args.pop(i)
    SUMMARY, WARN, NOFLOW = opt('--summary'), opt('--warn'), opt('--no-flow')
    ORG, JSON_OUT = opt('--org-terms', True), opt('--json', True)
    KIT = os.path.abspath(args[0] if args else KIT_DIR)

    terms = None
    if ORG:
        if os.path.isfile(ORG):
            try:
                terms = json.load(open(ORG, encoding='utf-8')).get('orgTerms') or []
            except ValueError:
                sys.exit(f'kittool lint: {ORG} is not valid JSON')
        else:
            terms = [t for t in ORG.split(',') if t.strip()]

    k = load(KIT)
    g = graph(k)
    problems = lint(k, g, terms)

    if not NOFLOW:   # keep the flow page current whenever the lint runs
        try:
            render(KIT, default_out(KIT), quiet=bool(SUMMARY), data=page_data(k, g, problems))

        except Exception as e:  # the page is a convenience; never fail the lint for it
            print(f'kittool lint: flow page not regenerated: {e}', file=sys.stderr)

    if JSON_OUT:
        json.dump([{'code': c, 'where': w, 'problem': m} for c, w, m in problems], open(JSON_OUT, 'w', encoding='utf-8'), indent=1)
    if SUMMARY:
        if problems:
            c, w, m = problems[0]
            print(f'kittool lint: {len(problems)} problem(s), e.g. {c} {w}: {m} (list: python {os.path.abspath(__file__)} lint)')
    else:
        for c, w, m in problems:
            print(f'{c:15} {w}: {m}')
        print(f'kittool lint: {len(problems)} problem(s) in {KIT} ({len(k.files)} files, {len(k.skills)} skills, '
              f'{len(k.workflows)} workflows, {len(k.agents)} agents)')
    return 1 if problems and not WARN else 0


# ================================ 5. port: Codex / Antigravity agents, hooks, workflow procedures ================================
# the kit = the folder this script lives in, 3 levels up (<kit>/skills/orchestrate/scripts): normally <workspace>/.claude, but a
# second clone or a worktree of the kit (any folder name) must port its own files, not the workspace's .claude
KIT = Path(__file__).resolve().parents[2]          # the kit repo (canonical + pushable): <kit>/skills/orchestrate/kittool.py
WORKSPACE = KIT.parent                             # where the CLIs look for .codex/.agents (deployed copies)
CLAUDE_AGENTS = KIT / "agents"
CLAUDE_WORKFLOWS = KIT / "workflows"
CLAUDE_SETTINGS = KIT / "settings.json"

# Canonical copies live inside the kit repo so `git push` carries them. Codex/Antigravity don't
# walk into .claude for .codex//.agents -- confirmed live: `agy`/`codex` resolve them from the
# session's cwd (workspaceDirs=[<workspace>] in agy's own log), i.e. WORKSPACE, not KIT. So
# port_agents()/port_hooks()/port_workflows() write under KIT, then deploy() mirrors the result
# out to WORKSPACE/.codex and WORKSPACE/.agents (untracked there, same as this kit being cloned
# into WORKSPACE/.claude in the first place -- the deployed copy is not itself version control).
CODEX_AGENTS = KIT / ".codex" / "agents"
GRAVITY_AGENTS = KIT / ".agents" / "agents"
CODEX_CONFIG = KIT / ".codex" / "config.toml"
GRAVITY_HOOKS = KIT / ".agents" / "hooks.json"
CODEX_WORKFLOWS = KIT / ".codex" / "workflows"
GRAVITY_WORKFLOWS = KIT / ".agents" / "workflows"

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n(.*)$", re.DOTALL)
META_RE = re.compile(r"export const meta\s*=\s*\{(.*?)\n\}", re.DOTALL)
STRING_FIELD_RE = re.compile(r"(\w+):\s*'((?:[^'\\]|\\.)*)'")
PHASES_RE = re.compile(r"phases:\s*\[(.*?)\n\s*\],", re.DOTALL)
PHASE_ENTRY_RE = re.compile(r"\{\s*title:\s*'([^']*)'\s*,\s*detail:\s*'((?:[^'\\]|\\.)*)'\s*\}")


def parse_frontmatter(text):
    m = FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError("no frontmatter")
    raw, body = m.group(1), m.group(2).lstrip("\n")
    fields = {}
    key, buf = None, []
    for line in raw.split("\n"):
        kv = re.match(r"^(\w+):\s*(.*)$", line)
        if kv:
            if key:
                fields[key] = "\n".join(buf).strip()
            key, buf = kv.group(1), [kv.group(2)]
        elif key:
            buf.append(line)
    if key:
        fields[key] = "\n".join(buf).strip()
    for k, v in list(fields.items()):
        if v.startswith('"') and v.endswith('"'):
            fields[k] = v[1:-1]
    return fields, body


def toml_escape(s):
    return s.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')


def write_codex(name, fields, body):
    # Verified against learn.chatgpt.com/docs/agent-configuration/subagents (2026-10-13):
    # required fields are name/description/developer_instructions; no "tools" array exists.
    # A Claude agent whose frontmatter restricts tools to read-only ones (Read/Grep/Glob/Bash
    # with no Edit/Write) is the closest match to sandbox_mode = "read-only".
    sandbox_line = ""
    if fields.get("tools") and "Edit" not in fields["tools"] and "Write" not in fields["tools"]:
        sandbox_line = 'sandbox_mode = "read-only"\n'
    content = (
        f'name = "{name}"\n'
        f'description = "{fields["description"]}"\n'
        f"{sandbox_line}"
        f'developer_instructions = """\n{toml_escape(body)}\n"""\n'
    )
    (CODEX_AGENTS / f"{name}.toml").write_text(content, encoding="utf-8")


def write_gravity(name, fields, body):
    # Verified against antigravity.google/docs/subagents (2026-10-13). "tools" takes
    # Antigravity's own tool names (view_file, run_command, ...), not Claude's (Read,
    # Bash, ...); the docs warn a mismapped name can hang the subagent, so we deliberately
    # don't guess a translation here -- leave tools unset (default: all) and say so in the body
    # when the Claude definition restricted tools, so a human maps it once by hand.
    frontmatter = [
        f"name: {name}",
        f'description: "{fields["description"]}"',
        "subagent: true",
        "mainAgent: false",
        "model: inherit",
        "commandExecutionPolicy: auto",
    ]
    note = ""
    if fields.get("tools"):
        note = (
            f"\n> Ported note: the Claude Code definition restricts tools to `{fields['tools']}`. "
            "Antigravity's `tools:` field uses its own tool names (view_file, run_command, ...); "
            "map this by hand if you need the same restriction here.\n"
        )
    content = "---\n" + "\n".join(frontmatter) + "\n---\n" + note + "\n" + body.strip() + "\n"
    (GRAVITY_AGENTS / f"{name}.md").write_text(content, encoding="utf-8")


def port_agents():
    CODEX_AGENTS.mkdir(parents=True, exist_ok=True)
    GRAVITY_AGENTS.mkdir(parents=True, exist_ok=True)
    count = 0
    for src in sorted(CLAUDE_AGENTS.glob("*.md")):
        fields, body = parse_frontmatter(src.read_text(encoding="utf-8"))
        name = fields.get("name", src.stem)
        write_codex(name, fields, body)
        write_gravity(name, fields, body)
        count += 1
    print(f"ported {count} agent(s) -> .codex/agents/*.toml, .agents/agents/*.md")


def port_hooks():
    """Guard + SessionStart hook logic already lives in .claude/skills/dev-kit/dev.ps1 guard,
    .../orchestrate/kit.ps1 health and orch.ps1 cleanup. We don't copy the logic; we
    point each tool's own hook config at the SAME scripts, so there is one implementation and
    three thin wire-ups. NOT ported: the `SendMessage` guard (orchestrate/kit.ps1 guard-sendmessage)
    -- `SendMessage` is a Claude Code tool name with no Codex/Antigravity equivalent to matcher
    against, so there is nothing to wire it to; this stays Claude-only."""
    # Matches settings.json's SessionStart list, minus the `kit.ps1 health -Flow -Fetch` variant
    # (cosmetic: regenerates the flow page + an async git fetch; skipped as non-essential).
    session_start_cmds = [
        ("kit.ps1 health", 15),
        ("orch.ps1 cleanup -IfDue -Quiet", 600),
    ]
    CODEX_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    pretool = (
        "[[hooks.PreToolUse]]\n"
        'matcher = "^(Bash|apply_patch)$"\n\n'
        "[[hooks.PreToolUse.hooks]]\n"
        'type = "command"\n'
        "command = '''pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .claude/skills/dev-kit/dev.ps1 guard'''\n"
        'statusMessage = "Guard check (git stash / --no-verify / force-push / heavy build gate)"\n'
        "timeout = 10\n"
    )
    session_start = ""
    for script, timeout in session_start_cmds:
        name, _, args = script.partition(" ")
        cmd = f"pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .claude/skills/orchestrate/{name}"
        if args:
            cmd += f" {args}"
        session_start += (
            "\n[[hooks.SessionStart]]\n"
            'matcher = "*"\n\n'
            "[[hooks.SessionStart.hooks]]\n"
            'type = "command"\n'
            f"command = '''{cmd}'''\n"
            f"timeout = {timeout}\n"
        )
    CODEX_CONFIG.write_text(
        "# Generated by kittool.py port - do not hand-edit the [hooks] section below.\n"
        "# Schema verified against learn.chatgpt.com/docs/hooks (2026-10-13).\n"
        "# Logic lives in .claude/skills/dev-kit/dev.ps1 and orchestrate/*.ps1 (shared with Claude Code).\n"
        "# Not ported: the SendMessage guard -- no Codex tool named SendMessage to matcher against.\n\n"
        + pretool + session_start,
        encoding="utf-8",
    )

    GRAVITY_HOOKS.parent.mkdir(parents=True, exist_ok=True)
    GRAVITY_HOOKS.write_text(
        json.dumps(
            {
                "guard": {
                    "enabled": True,
                    "PreToolUse": [
                        {
                            "matcher": "run_command",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass "
                                    "-File .claude/skills/dev-kit/dev.ps1 guard",
                                    "timeout": 10,
                                }
                            ],
                        }
                    ],
                },
                "kit-health": {
                    "enabled": True,
                    # SessionStart's shape is NOT the PreToolUse {"matcher":..., "hooks":[...]} wrapper --
                    # verified against antigravity.google/docs/hooks (2026-10-13): "the structure is
                    # simpler (a list of handlers directly under the event key)" and matcher is ignored.
                    "SessionStart": [
                        {
                            "type": "command",
                            "command": (
                                "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass "
                                f"-File .claude/skills/orchestrate/{script.partition(' ')[0]}"
                                + (f" {script.partition(' ')[2]}" if script.partition(' ')[2] else "")
                            ),
                            "timeout": timeout,
                        }
                        for script, timeout in session_start_cmds
                    ],
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print("hook wiring written -> .claude/.codex/config.toml, .claude/.agents/hooks.json")


def parse_workflow_meta(text):
    m = META_RE.search(text)
    if not m:
        return None
    block = m.group(1)
    fields = dict(STRING_FIELD_RE.findall(block))
    pm = PHASES_RE.search(block)
    phases = PHASE_ENTRY_RE.findall(pm.group(1)) if pm else []
    fields["phases"] = phases
    return fields


def workflow_procedure_doc(fields, tool_label, agent_note):
    lines = [
        f"# {fields['name']} (ported procedure, not a native {tool_label} workflow)",
        "",
        f"> {fields['description']}",
        "",
        f"**When to run it:** {fields.get('whenToUse', '(see .claude/workflows source)')}",
        "",
        f"{tool_label} has no pipeline/phase scripting engine equivalent to Claude Code's "
        "Workflow tool, so this is a manual run procedure, not an automated script. Drive it "
        f"yourself as the coordinator: {agent_note}",
        "",
        "## Phases",
        "",
    ]
    for i, (title, detail) in enumerate(fields.get("phases", []), 1):
        lines.append(f"{i}. **{title}** -- {detail}")
    lines.append("")
    lines.append(
        "Full argument shape and step-by-step mechanics: the canonical source is "
        f"`.claude/workflows/{fields['name']}.js` (read its header comment and the `orchestrate` "
        "skill before running this by hand)."
    )
    return "\n".join(lines) + "\n"


def port_workflows():
    CODEX_WORKFLOWS.mkdir(parents=True, exist_ok=True)
    GRAVITY_WORKFLOWS.mkdir(parents=True, exist_ok=True)
    count = 0
    for src in sorted(CLAUDE_WORKFLOWS.glob("*.js")):
        fields = parse_workflow_meta(src.read_text(encoding="utf-8"))
        if not fields or "name" not in fields:
            continue
        (CODEX_WORKFLOWS / f"{fields['name']}.md").write_text(
            workflow_procedure_doc(
                fields, "Codex",
                "spawn each phase's agents from `.codex/agents/*.toml` yourself with "
                "`spawn_agent` (one call per agent in that phase, up to the session's "
                "concurrency limit), `wait_agent` for them to finish, then move to the next "
                "phase, in the order below. Verified against the installed CLI "
                "(`codex features list`: hooks/multi_agent stable) on 2026-10-13 -- "
                "`spawn_agents_on_csv` does not exist; don't use it.",
            ),
            encoding="utf-8",
        )
        (GRAVITY_WORKFLOWS / f"{fields['name']}.md").write_text(
            workflow_procedure_doc(
                fields, "Antigravity",
                "delegate each phase to the matching subagent in `.agents/agents/*.md` "
                "yourself, in the phase order below.",
            ),
            encoding="utf-8",
        )
        count += 1
    print(f"ported {count} workflow procedure doc(s) -> .codex/workflows/*.md, .agents/workflows/*.md")


def port_deploy():
    """Mirror the canonical .claude/.codex and .claude/.agents out to the workspace root,
    where the real Codex/Antigravity CLIs actually look (confirmed live: `codex`/`agy` resolve
    .codex//.agents from the session cwd, not from inside .claude). The workspace root usually
    isn't a git repo itself, so this copy is a deploy target, not a second source of truth --
    same relationship as the kit repo itself being cloned into <workspace>/.claude."""
    if KIT.name != '.claude':   # a second clone / worktree of the kit: its parent is no workspace, write nothing there
        print(f"not deployed: {KIT} is not a workspace's .claude folder (the ports inside the kit are updated)")
        return
    deployed = []
    for src_dir, dst_dir in ((KIT / ".codex", WORKSPACE / ".codex"), (KIT / ".agents", WORKSPACE / ".agents")):
        if dst_dir.exists():
            shutil.rmtree(dst_dir)
        shutil.copytree(src_dir, dst_dir)
        deployed.append(dst_dir)
    # AGENTS.md/GEMINI.md: Codex/Antigravity search upward from the session cwd (usually
    # WORKSPACE), never down into .claude, so the canonical file in .claude needs a copy here too.
    for name in ("AGENTS.md", "GEMINI.md"):
        dst = WORKSPACE / name
        shutil.copyfile(KIT / name, dst)
        deployed.append(dst)
    print(f"deployed -> {', '.join(str(p) for p in deployed)}")


def deployed_stale():
    """The workspace copies port_deploy writes (<workspace>/.codex, .agents, AGENTS.md, GEMINI.md) that differ from the kit;
    [] when the kit is no installed <workspace>/.claude (a worktree or second clone deploys nothing)."""
    if KIT.name != '.claude':
        return []
    bad = []
    for name in ('.codex', '.agents'):
        src, dst = KIT / name, WORKSPACE / name
        a = {p.relative_to(src).as_posix(): p.read_bytes() for p in src.rglob('*') if p.is_file()} if src.exists() else {}
        b = {p.relative_to(dst).as_posix(): p.read_bytes() for p in dst.rglob('*') if p.is_file()} if dst.exists() else {}
        if a != b:
            bad.append(name + '/')
    for name in ('AGENTS.md', 'GEMINI.md'):
        if not (WORKSPACE / name).exists() or (WORKSPACE / name).read_bytes() != (KIT / name).read_bytes():
            bad.append(name)
    return bad


def check_stale():
    """--check: exit 1 if .codex/.agents would change, without writing. Wired into
    kit.ps1 health (SessionStart) so drift between .claude/agents and the ported
    copies surfaces the same way any other kit-health nudge does. Generates every port into a
    temp copy and compares contents (only checking that the files exist missed every edit)."""
    import contextlib, io, tempfile
    g = globals()
    outs = ("CODEX_AGENTS", "GRAVITY_AGENTS", "CODEX_CONFIG", "GRAVITY_HOOKS", "CODEX_WORKFLOWS", "GRAVITY_WORKFLOWS")
    real = {k: g[k] for k in outs}
    stale = []
    with tempfile.TemporaryDirectory() as tmp:
        for k in outs:
            g[k] = Path(tmp) / real[k].relative_to(KIT)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                port_agents()
                port_hooks()
                port_workflows()
        finally:
            g.update(real)
        for f in sorted(Path(tmp).rglob("*")):
            if f.is_file():
                rel = f.relative_to(tmp)
                have = KIT / rel
                if not have.exists() or have.read_text(encoding="utf-8") != f.read_text(encoding="utf-8"):
                    stale.append(str(rel).replace("\\", "/"))
    if stale:
        print(f"kittool port: stale or missing ports for {sorted(set(stale))}; run "
              f"'python -X utf8 skills/orchestrate/kittool.py port'")
        return 1
    return 0


GEMINI_MD = "@AGENTS.md\n"


def cmd_port(a):
    if '--check' in a:
        rc = check_stale()
        gm = KIT / 'GEMINI.md'
        if not gm.exists() or gm.read_text(encoding='utf-8') != GEMINI_MD:
            print("kittool port: GEMINI.md stale or missing; run 'python -X utf8 skills/orchestrate/kittool.py port'")
            rc = 1
        stale_ws = deployed_stale()
        if stale_ws:
            print(f"kittool port: workspace copies differ from the kit: {stale_ws}; run 'python -X utf8 skills/orchestrate/kittool.py port'")
            rc = 1
        return rc
    port_agents()
    port_hooks()
    port_workflows()
    (KIT / 'GEMINI.md').write_text(GEMINI_MD, encoding='utf-8')
    port_deploy()
    return 0


# ================================ 6. audit: the mechanical half of the kit audit ================================
OWN = KIT_DIR

# (example: kit.example.json, or its localFiles entry), local file, what it holds
PAIRS = [('skills/dev-kit/kit.example.json', 'skills/dev-kit/kit.local.json', 'org settings (tracker, repos, reports, ...)'),
         ('localFiles:skills/qa-kit/targets.local.json', 'skills/qa-kit/targets.local.json', 'QA targets and test logins (secrets)'),
         ('localFiles:skills/android-swarm/swarm.config.json', 'skills/android-swarm/swarm.config.json', 'Android emulator lanes')]


def example_of(ex_rel):
    ex, err = load_json(os.path.join(OWN, 'skills/dev-kit/kit.example.json'))
    if not ex_rel.startswith('localFiles:'):
        return {k: v for k, v in (ex or {}).items() if k != 'localFiles'}, err
    return ((ex or {}).get('localFiles') or {}).get(ex_rel[len('localFiles:'):]), err
# keys whose example value IS the documented default: --fill may write them (behaviour does not change, the file gets explicit)
SAFE_DEFAULTS = {'kitAudit.everyDays', 'cleanup.maxBrowserProfiles', 'supervise.ramActPct', 'supervise.minDiskFreeGB',
                 'build.mavenOffline', 'gate.heapMinGB'}
# subtrees whose keys are user-chosen names (or samples): never "missing" against the example
USER_MAPS = ('localEnv', 'repos', 'repoAliases', 'targets', 'linkFromByTarget', 'tracker.statuses', 'tracker._examples', 'gate.startHeapGB', 'lanes', 'app', 'localFiles', 'deploy.minIntervalHours', 'tests')
PLACEHOLDER = re.compile(r'<[^>]+>|/path/to|example\.(com|app)|your[- ]', re.I)
AUTOMATIC = {'input', 'args', 'matches', 'error', 'host', 'home', 'pid', 'pwd', 'profile', 'this', 'event', 'sender', 'ofs',
             'psitem', 'iswindows', 'islinux', 'ismacos', 'executioncontext', 'myinvocation', 'psboundparameters', 'lastexitcode'}
LIBS = ('lib.ps1',)

findings = []


def out(level, code, where, what, fix=''):
    findings.append({'level': level, 'code': code, 'where': where, 'what': what, 'fix': fix})


def run(cmd, cwd=None, timeout=60, stdin=''):
    try:
        p = subprocess.run(cmd, cwd=cwd, input=stdin, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
        return p.returncode, (p.stdout or '').strip(), (p.stderr or '').strip()
    except subprocess.TimeoutExpired:
        return 124, '', f'timed out after {timeout} s'
    except OSError as e:
        return 127, '', str(e)


def git(kit, *a, timeout=60):
    return run(['git', '-C', kit, *a], timeout=timeout)


def pwsh(script, *a, timeout=120, stdin=''):
    exe = shutil.which('pwsh')
    if not exe:
        return 127, '', 'pwsh 7 not on PATH'
    return run([exe, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, *a], timeout=timeout, stdin=stdin)


def py():
    return sys.executable or shutil.which('python3') or shutil.which('python')


def load_json(path):
    """(data, error): data None when the file is missing or invalid."""
    if not os.path.isfile(path):
        return None, 'missing'
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f), None
    except ValueError as e:
        return None, f'invalid JSON ({e.msg}, line {e.lineno})'


def live_kit():
    """The installed clone: the main worktree of this script's repo (an audit worktree checks the live kit, not itself)."""
    rc, common, _ = git(OWN, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if rc == 0 and common:
        main = os.path.dirname(os.path.normpath(common))
        if os.path.isfile(os.path.join(main, 'skills', 'dev-kit', 'paths.json')):
            return main
    return OWN


def get(d, dotted):
    cur = d
    for part in dotted.split('.'):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def key_paths(d, prefix=''):
    """Dotted key paths of nested objects (lists and user-named maps are leaves)."""
    for k, v in (d or {}).items():
        if k.startswith('_'):
            continue
        p = f'{prefix}{k}'
        yield p
        if isinstance(v, dict) and not any(p == m or p.startswith(m + '.') for m in USER_MAPS):
            yield from key_paths(v, p + '.')


def tracked(kit):
    rc, o, _ = git(kit, 'ls-files')
    return o.splitlines() if rc == 0 else []


def aread(kit, rel):
    try:
        with open(os.path.join(kit, rel), encoding='utf-8', errors='replace') as f:
            return f.read().replace('\r\n', '\n')
    except OSError:
        return ''


def strip_ps_comments(text):
    text = re.sub(r'<#.*?#>', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return '\n'.join(re.sub(r'(^|\s)#(?![>{]).*$', r'\1', l) if not re.search(r"""['"][^'"]*#""", l) else l for l in text.split('\n'))


def config_doc_keys(kit):
    doc = section(aread(kit, 'README.md'), 'Configuration') or ''
    keys = set(re.findall(r'`([A-Za-z][\w]*(?:\.[\w]+)*)', doc))
    for row in doc.split('\n'):   # a row's sub-keys named in its Meaning cell: `tracker` ... `statuses` -> tracker.statuses
        cells = row.split('|')
        if len(cells) > 3:
            heads = re.findall(r'`([A-Za-z][\w.]*)', cells[1])
            for w in re.findall(r'`([A-Za-z]\w*)', '|'.join(cells[2:])):
                keys.update(f'{h}.{w}' for h in heads)
    return doc, keys


def script_config_keys(kit, files):
    """Top-level kit.local.json keys the scripts read (Get-KitSetting / Get-KitValue / CFG.get / $cfg.<key>)."""
    keys = {}
    pats = [re.compile(r"Get-Kit(?:Setting|Value)\s+'([\w.]+)'"), re.compile(r"""CFG\.get\(\s*['"](\w+)"""),
            re.compile(r"""CFG\[['"](\w+)"""), re.compile(r'\$cfg\.(\w+)')]
    for f in files:
        if not f.endswith(('.ps1', '.py')) or f.endswith('kittool.py'):
            continue
        text = aread(kit, f)
        loads = re.search(r"""Join-Path[^\n]*kit\.local\.json['"]""", text)
        use = pats if loads else pats[:3]   # $cfg.<key> means kit.local.json only where the file loads it
        for ln, line in enumerate(text.split('\n'), 1):
            for rx in use:
                for m in rx.finditer(line):
                    keys.setdefault(m.group(1), f'{f}:{ln}')
    return keys


# ------------------------------------------------------------------ setup
def cmd_setup(kit, fix):
    if not os.path.isdir(os.path.join(kit, '.git')) and not os.path.isfile(os.path.join(kit, '.git')):
        out('ACT', 'SETUP-CLONE', kit, 'not a git clone of the kit repo', 'README "Install": git clone <kit repo> <workspace>/.claude')
        return
    setup_ps = os.path.join(kit, 'skills', 'orchestrate', 'kit.ps1')
    need_setup = []
    rc, hp, _ = git(kit, 'config', 'core.hooksPath')
    if hp != '.githooks':
        need_setup.append('core.hooksPath is not .githooks (pre-push gate off)')
    cfg, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.local.json'))
    rc, ex, _ = git(kit, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude')
    excl = open(ex, encoding='utf-8', errors='replace').read() if rc == 0 and os.path.isfile(ex) else ''
    miss = [p for p in ((cfg or {}).get('localOnly') or []) if f"/{p.replace(chr(92), '/').strip('/')}" not in excl]
    if miss:
        need_setup.append(f'{len(miss)} localOnly path(s) not in .git/info/exclude')
    for n in ('work', 'cache', 'logs'):
        if not os.path.isdir(kit_path(n, kit=kit)):
            need_setup.append(f'runtime folder {n}/ missing')
    if need_setup:
        if fix:
            rc, o, e = pwsh(setup_ps, 'setup', timeout=120)
            out('FIX' if rc == 0 else 'ACT', 'SETUP-INSTALL', 'kit.ps1 setup', '; '.join(need_setup) + ('' if rc == 0 else f' (kit.ps1 setup failed: {e[:200]})'))
        else:
            out('ACT', 'SETUP-INSTALL', kit, '; '.join(need_setup), f'pwsh -File {setup_ps} setup')
    for ex_rel, loc_rel, what in PAIRS:
        if not os.path.isfile(os.path.join(kit, loc_rel)):
            lvl = 'ASK' if loc_rel.endswith('kit.local.json') else 'INFO'
            out(lvl, 'SETUP-CONFIG', loc_rel, f'missing ({what})', 'kit.ps1 setup -WriteLocal, then fill it (the config step lists the keys)')
    # hooks: every script exists; the synchronous SessionStart ones run clean, fast, and print valid JSON or nothing
    sj, err = load_json(os.path.join(kit, 'settings.json'))
    if err:
        out('ACT', 'SETUP-HOOKS', 'settings.json', err)
        sj = {}
    for event, blocks in ((sj or {}).get('hooks') or {}).items():
        for b in blocks:
            for h in b.get('hooks', []):
                blob = ' '.join([h.get('command', '')] + list(h.get('args', [])))
                m = re.search(r'\.claude[\\/]([\w./\\-]+\.ps1)', blob)
                if not m:
                    continue
                rel = m.group(1).replace('\\', '/')
                path = os.path.join(kit, rel)
                if not os.path.isfile(path):
                    out('ACT', 'SETUP-HOOKS', f'settings.json {event}', f'{rel} does not exist')
                    continue
                if event != 'SessionStart' or h.get('async'):
                    continue
                hargs = list(h.get('args', []))
                extra = hargs[hargs.index('-File') + 2:] if '-File' in hargs else []   # the verb and its flags after the script path
                t0 = time.time()
                rc, o, e = pwsh(path, *extra, timeout=int(h.get('timeout', 10)) + 5, stdin='{"source":"startup"}')
                dt = time.time() - t0
                if rc != 0:
                    out('ACT', 'SETUP-HOOK-FAIL', rel, f'SessionStart hook exit {rc}: {(e or o)[:200]}')
                elif o:
                    try:
                        json.loads(o.splitlines()[-1])
                    except ValueError:
                        out('ACT', 'SETUP-HOOK-FAIL', rel, 'SessionStart hook output is not one JSON line (the harness ignores it)')
                if dt > 2.5:
                    out('WARN', 'SETUP-HOOK-SLOW', rel, f'SessionStart hook took {dt:.1f} s (keep synchronous hooks < 2 s; slow work goes async)')
    sl = os.path.join(kit, 'settings.local.json')
    if os.path.isfile(sl) and load_json(sl)[1]:
        out('ACT', 'SETUP-CONFIG', 'settings.local.json', load_json(sl)[1])
    # Codex / Antigravity ports and their deployed copies at the workspace root
    pk = os.path.join(kit, 'skills', 'orchestrate', 'kittool.py')
    if os.path.isfile(pk):
        rc, o, e = run([py(), '-X', 'utf8', pk, 'port', '--check'], timeout=60)
        if rc:
            out('ACT', 'SETUP-PORTS', 'kittool.py port --check', (o or e)[:300], f'python -X utf8 {pk} port (in the clone that changed, then commit)')
    ws = os.path.dirname(kit)
    for n in ('AGENTS.md', 'GEMINI.md'):
        src, dst = os.path.join(kit, n), os.path.join(ws, n)
        if os.path.isfile(src) and (not os.path.isfile(dst) or aread(kit, n) != aread(ws, n)):
            out('WARN', 'SETUP-PORTS', f'<workspace>/{n}', 'missing or differs from the kit copy (Codex/Antigravity read this one)', f'python -X utf8 {pk} port')
    # CLIs: present and logged in (check only; never log in from here)
    for exe in ('git', 'pwsh', 'node'):
        if not shutil.which(exe):
            out('ACT', 'SETUP-CLI', exe, 'not on PATH (the kit needs it)')
    tt = (os.environ.get('KIT_TRACKER_TYPE') or get(cfg, 'tracker.type') or 'none').lower()
    need = {'clickup': ['clickup'], 'github': ['gh'], 'gitlab': ['glab'], 'jira': [], 'none': []}.get(tt, [])
    host_cli = 'gh' if 'github' in str(get(cfg, 'gitHost') or '') else 'glab'
    for exe in sorted(set(need + [host_cli])):
        if not shutil.which(exe):
            out('ASK', 'SETUP-CLI', exe, f'not on PATH (tracker.type {tt} / git host need it): install it and log in by hand')
            continue
        auth = {'gh': ['gh', 'auth', 'status'], 'glab': ['glab', 'auth', 'status']}.get(exe)
        if auth:
            rc, o, e = run([shutil.which(exe)] + auth[1:], timeout=30)
            if rc:
                out('ASK', 'SETUP-AUTH', exe, 'not logged in (auth status failed): the owner logs in by hand, never headlessly')
    if tt == 'jira':
        for v in ('JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN'):
            if not os.environ.get(v):
                out('ASK', 'SETUP-AUTH', v, 'environment variable not set (tracker.type jira)')
    rt = (os.environ.get('KIT_REPORT_TYPE') or get(cfg, 'reports.type') or ('gdocs' if shutil.which('gws') else 'markdown')).lower()
    if rt == 'gdocs' and not shutil.which('gws'):
        out('ASK', 'SETUP-CLI', 'gws', 'reports.type gdocs needs the gws CLI on PATH, logged in')


# ------------------------------------------------------------------ config
def cmd_config(kit, fill):
    doc, documented = config_doc_keys(OWN)
    for ex_rel, loc_rel, what in PAIRS:
        ex, _ = example_of(ex_rel)
        loc, err = load_json(os.path.join(kit, loc_rel))
        if err == 'missing':
            if loc_rel.endswith('kit.local.json'):
                out('ASK', 'CONFIG-FILE', loc_rel, f'missing ({what})', 'kit.ps1 setup -WriteLocal; the lead fills org values')
            continue
        if err:
            out('ACT', 'CONFIG-FILE', loc_rel, err)
            continue
        if not isinstance(loc, dict) or not isinstance(ex, dict):
            out('ACT', 'CONFIG-FILE', loc_rel, 'top level must be a JSON object')
            continue
        changed = False
        for p in key_paths(ex):
            if any(p.startswith(m + '.') for m in USER_MAPS):
                continue
            ev, lv = get(ex, p), get(loc, p)
            if lv is None:
                if loc_rel.endswith('kit.local.json') and p in SAFE_DEFAULTS and fill:
                    parent = loc
                    for part in p.split('.')[:-1]:
                        parent = parent.setdefault(part, {})
                    if isinstance(parent, dict):
                        parent[p.split('.')[-1]] = ev
                        changed = True
                        out('FIX', 'CONFIG-DEFAULT', f'{loc_rel} {p}', 'filled with the documented default')
                continue
            if ev is not None and not PLACEHOLDER.search(json.dumps(ev)) and type(ev) is not type(lv) and not (
                    isinstance(ev, (int, float)) and isinstance(lv, (int, float)) and not isinstance(lv, bool)):
                out('ACT', 'CONFIG-TYPE', f'{loc_rel} {p}', f'is {type(lv).__name__}, expected {type(ev).__name__} (as in {os.path.basename(ex_rel)})')
        for p in key_paths(loc):
            top = p.split('.')[0]
            if get(ex, p) is None and p not in documented and f'`{p}' not in doc and not any(p.startswith(m + '.') for m in USER_MAPS) \
                    and top not in ('default', 'browser', 'keepFreeGB'):
                out('WARN', 'CONFIG-UNKNOWN', f'{loc_rel} {p}', 'key not in the example nor README "Configuration": a typo, or an undocumented key a script reads?')
        if changed:
            bak = os.path.join(kit, loc_rel) + time.strftime('.bak-%Y%m%d-%H%M%S')
            shutil.copyfile(os.path.join(kit, loc_rel), bak)
            with open(os.path.join(kit, loc_rel), 'w', encoding='utf-8') as f:
                json.dump(loc, f, indent=2, ensure_ascii=False)
                f.write('\n')
            out('INFO', 'CONFIG-DEFAULT', loc_rel, f'written (backup {os.path.basename(bak)}: delete it once checked)')
        if loc_rel.endswith('kit.local.json'):
            config_rules(kit, loc)
        elif loc_rel.endswith('targets.local.json'):
            targets_rules(loc)
        else:
            swarm_rules(loc)
    # keys the scripts read but nobody documented (both ways)
    reads = script_config_keys(OWN, tracked(OWN))
    for key, where in sorted(reads.items()):
        top = key.split('.')[0]
        if top not in documented and f'`{top}' not in doc:
            out('ACT', 'CONFIG-UNDOC', where, f'script reads kit.local.json "{key}", not documented in README "Configuration" (nor kit.example.json)')


def config_rules(kit, c):
    """Values a feature in use needs and no default can supply: ASK the lead (key paths only, never values)."""
    tt = (os.environ.get('KIT_TRACKER_TYPE') or get(c, 'tracker.type') or 'clickup').lower()
    if tt not in ('clickup', 'github', 'gitlab', 'jira', 'none'):
        out('ACT', 'CONFIG-VALUE', 'kit.local.json tracker.type', 'not one of clickup / github / gitlab / jira / none')
    if tt in ('github', 'gitlab') and not get(c, 'tracker.repo'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json tracker.repo', f'tracker.type {tt} needs owner/name or group/project')
    rt = (os.environ.get('KIT_REPORT_TYPE') or get(c, 'reports.type') or ('gdocs' if shutil.which('gws') else 'markdown')).lower()
    if rt == 'gdocs' and not c.get('driveParent'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json driveParent', 'reports.type gdocs needs the Drive folder id for guides and evidence')
    if not c.get('orgTerms'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json orgTerms', 'empty: the pre-push org-term gate checks nothing; the lead lists org, product, host and tenant names')
    for p in c.get('localOnly') or []:
        if not os.path.exists(os.path.join(kit, p)):
            out('WARN', 'CONFIG-VALUE', f'kit.local.json localOnly {p}', 'path does not exist in the clone (stale entry?)')
    for k in ('reposRoot',):
        if c.get(k) and not os.path.isdir(os.path.expanduser(str(c[k]))):
            out('ACT', 'CONFIG-VALUE', f'kit.local.json {k}', 'folder does not exist on this machine')
    for i, root in enumerate(c.get('worktreeRoots') or []):
        if root and not os.path.isdir(os.path.dirname(os.path.abspath(os.path.expanduser(str(root))))):
            out('ACT', 'CONFIG-VALUE', f'kit.local.json worktreeRoots[{i}]', 'its parent folder does not exist on this machine')
    for i, r in enumerate(c.get('repos') or []):
        w = f'kit.local.json repos[{i}]'
        if not isinstance(r, dict):
            out('ACT', 'CONFIG-TYPE', w, 'must be an object')
            continue
        for k in ('name', 'checkout', 'target'):
            if not r.get(k):
                out('ASK' if k != 'name' else 'ACT', 'CONFIG-NEED', f'{w}.{k}', 'missing')
        if r.get('checkout') and not os.path.isdir(os.path.expanduser(str(r['checkout']).replace('<workspace>', os.path.dirname(kit)))):
            out('ACT', 'CONFIG-VALUE', f'{w}.checkout', 'folder does not exist on this machine')
        for k in ('linkFrom',):
            if r.get(k) and not os.path.isdir(os.path.expanduser(str(r[k]))):
                out('ACT', 'CONFIG-VALUE', f'{w}.{k}', 'folder does not exist (wt.ps1 new fails)')
        for t, d in (r.get('linkFromByTarget') or {}).items():
            if d and not os.path.isdir(os.path.expanduser(str(d))):
                out('ACT', 'CONFIG-VALUE', f'{w}.linkFromByTarget.{t}', 'folder does not exist (wt.ps1 new fails)')
        for j, d in enumerate(r.get('deploys') or []):
            dw = f'{w}.deploys[{j}]'
            if not isinstance(d, dict) or not d.get('target'):
                out('ACT', 'CONFIG-NEED', dw, 'needs a target')
                continue
            kinds = [k for k in ('branch', 'awsStack', 'ssh', 'manual', 'laneApk') if d.get(k)]
            if not kinds:
                out('ASK', 'CONFIG-NEED', dw, 'no way to check it: branch + job, awsStack + region, ssh {...}, manual or laneApk')
            if d.get('branch') and not d.get('job'):
                out('ASK', 'CONFIG-NEED', f'{dw}.job', 'branch deploys need the CI job name')
            if d.get('awsStack') and not d.get('region'):
                out('ASK', 'CONFIG-NEED', f'{dw}.region', 'awsStack deploys need the region')
            s = d.get('ssh')
            if isinstance(s, dict):
                for k in ('host', 'key', 'repoDir', 'appDir'):
                    if not s.get(k):
                        out('ASK', 'CONFIG-NEED', f'{dw}.ssh.{k}', 'missing')
                if s.get('key') and not os.path.isfile(os.path.expanduser(str(s['key']))):
                    out('ACT', 'CONFIG-VALUE', f'{dw}.ssh.key', 'key file not found on this machine')
    le = c.get('localEnv') or {}
    ports = {}
    for env, e in (le.get('envs') or {}).items():
        for s in (e or {}).get('services') or []:
            if s.get('port') and not s.get('external'):   # external infra (a DB server) may be shared by several envs
                ports.setdefault(s['port'], []).append(f'{env}/{s.get("name")}')
            if s.get('repo') and not any(s['repo'] in [r.get('name')] + list(r.get('aliases') or []) for r in c.get('repos') or [] if isinstance(r, dict)):
                out('ACT', 'CONFIG-VALUE', f'kit.local.json localEnv.envs.{env} service {s.get("name")}', 'repo is not a repos[] name or alias')
    for p, who in ports.items():
        if len(who) > 1:
            out('ACT', 'CONFIG-VALUE', f'kit.local.json localEnv port {p}', f'used by {len(who)} services (ports must be unique across envs)')


def targets_rules(t):
    tg = t.get('targets') or {}
    if not tg:
        out('ASK', 'CONFIG-NEED', 'targets.local.json targets', 'no test environment defined')
    if t.get('default') and t['default'] not in tg:
        out('ACT', 'CONFIG-VALUE', 'targets.local.json default', 'names no entry of targets')
    for n, v in tg.items():
        if not (v or {}).get('web') and not (v or {}).get('api'):
            out('ASK', 'CONFIG-NEED', f'targets.local.json targets.{n}', 'needs web and/or api base URL')
        if not (v or {}).get('users'):
            out('ASK', 'CONFIG-NEED', f'targets.local.json targets.{n}.users', 'no test login (the lead supplies it; it stays in this file only)')
        a = ((v or {}).get('auth') or {}).get('type')
        if a and a not in ('login', 'token', 'basic', 'none'):
            out('ACT', 'CONFIG-VALUE', f'targets.local.json targets.{n}.auth.type', 'not one of login / token / basic / none')


def swarm_rules(s):
    if not s.get('lanes'):
        out('ASK', 'CONFIG-NEED', 'swarm.config.json lanes', 'no emulator lane defined')
    for k in ('package', 'appDir'):
        if not get(s, f'app.{k}'):
            out('ASK', 'CONFIG-NEED', f'swarm.config.json app.{k}', 'missing')
    if get(s, 'app.appDir') and not os.path.isdir(os.path.expanduser(str(get(s, 'app.appDir')))):
        out('ACT', 'CONFIG-VALUE', 'swarm.config.json app.appDir', 'folder does not exist on this machine')


# ------------------------------------------------------------------ recover
def cmd_recover(kit, fix):
    rc, _, _ = git(kit, 'fetch', '--quiet', '--prune', timeout=120)
    if rc:
        out('WARN', 'RECOVER-GIT', kit, 'git fetch failed: ahead/behind and merged checks use the last fetched state')
    rc, st, _ = git(kit, 'status', '--porcelain=v1', '--branch')
    lines = st.splitlines()
    head = lines[0] if lines else ''
    dirty = [l[3:] for l in lines[1:]]
    if dirty:
        out('ACT', 'RECOVER-DIRTY', kit, f'{len(dirty)} uncommitted change(s) in the live clone: {", ".join(dirty[:6])}',
            'kit change -> commit + push it from a worktree; org-only path -> kit.local.json localOnly; leftover -> ask the lead')
    for m in re.finditer(r'(behind|ahead) (\d+)', head):
        out('WARN', 'RECOVER-UPSTREAM', kit, f'{m.group(2)} commit(s) {m.group(1)} upstream ({head[3:]})',
            'behind: git pull --rebase once no agents run; ahead: push')
    # worktrees of the kit repo
    rc, wl, _ = git(kit, 'worktree', 'list', '--porcelain')
    wts, cur = [], {}
    for l in wl.splitlines() + ['']:
        if not l.strip():
            if cur:
                wts.append(cur)
            cur = {}
        else:
            k, _, v = l.partition(' ')
            cur[k] = v or True
    prunable = [w for w in wts if 'prunable' in w]
    if prunable:
        if fix:
            git(kit, 'worktree', 'prune')
            out('FIX', 'RECOVER-WORKTREE', kit, f'pruned {len(prunable)} kit worktree record(s) whose folder is gone')
        else:
            out('ACT', 'RECOVER-WORKTREE', kit, f'{len(prunable)} kit worktree record(s) point at missing folders', f'git -C {kit} worktree prune')
    main = os.path.normcase(os.path.abspath(kit))
    in_wt = set()
    for w in wts:
        path = w.get('worktree', '')
        br = str(w.get('branch', '')).replace('refs/heads/', '')
        if not path or os.path.normcase(os.path.abspath(path)) == main or 'prunable' in w:
            continue
        in_wt.add(br)
        _, wd, _ = git(path, 'status', '--porcelain')
        rc_m, _, _ = git(kit, 'merge-base', '--is-ancestor', br or 'HEAD', 'origin/main')
        _, ahead, _ = git(kit, 'rev-list', '--count', f'origin/main..{br}') if br else (0, '?', '')
        _, remote, _ = git(kit, 'ls-remote', '--heads', 'origin', br, timeout=60) if br else (0, '', '')
        idle_h = (time.time() - max((os.path.getmtime(os.path.join(path, f)) for f in os.listdir(path)), default=0)) / 3600 if os.path.isdir(path) else 99
        if rc_m == 0 and not wd.strip():
            if fix and idle_h > 2:
                rc, _, e = git(kit, 'worktree', 'remove', path)
                out('FIX' if rc == 0 else 'ACT', 'RECOVER-WORKTREE', path, f'kit worktree of finished branch {br} removed' + ('' if rc == 0 else f' failed: {e[:120]}'))
            elif idle_h > 2:
                out('ACT', 'RECOVER-WORKTREE', path, f'kit branch {br} has nothing beyond origin/main (merged or never used) and the worktree is clean (idle {idle_h:.0f} h)', f'git -C {kit} worktree remove {path}')
            else:
                out('INFO', 'RECOVER-WORKTREE', path, f'kit branch {br} has nothing new for origin/main, but the worktree was touched {idle_h * 60:.0f} min ago (in use?): leave it')
        else:
            out('WARN', 'RECOVER-HALF', path, f'kit branch {br or "(detached)"}: {ahead} commit(s) not on origin/main, '
                f'{len(wd.splitlines())} uncommitted, {"pushed" if remote else "NOT pushed"}, idle {idle_h:.0f} h',
                'in use by another agent? ask the lead; finished -> push the branch and merge it; abandoned -> list it for the lead')
    # local kit branches without a worktree
    rc, bl, _ = git(kit, 'for-each-ref', '--format=%(refname:short)', 'refs/heads')
    _, curb, _ = git(kit, 'rev-parse', '--abbrev-ref', 'HEAD')
    for br in bl.splitlines():
        if br in ('main', 'master', curb) or br in in_wt:
            continue
        rc_m, _, _ = git(kit, 'merge-base', '--is-ancestor', br, 'origin/main')
        if rc_m == 0:
            if fix:
                rc, _, _ = git(kit, 'branch', '-d', br)
                out('FIX' if rc == 0 else 'ACT', 'RECOVER-BRANCH', br, 'merged kit branch deleted' if rc == 0 else 'merged, but git branch -d refused')
            else:
                out('ACT', 'RECOVER-BRANCH', br, 'local kit branch already merged into origin/main', f'git -C {kit} branch -d {br}')
        else:
            _, n, _ = git(kit, 'rev-list', '--count', f'origin/main..{br}')
            out('WARN', 'RECOVER-HALF', br, f'local kit branch with {n} commit(s) not on origin/main and no worktree', 'merge it, or list it for the lead (never delete unmerged work)')
    # tracked files that must stay local
    rc, ig, _ = git(kit, 'ls-files', '-ci', '--exclude-standard')
    cfg, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.local.json'))
    lo = [p.replace('\\', '/').strip('/') for p in ((cfg or {}).get('localOnly') or [])]
    bad = sorted(set([f for f in ig.splitlines() if f] + [f for f in tracked(kit) if '.local.' in os.path.basename(f) or any(f == p or f.startswith(p + '/') for p in lo)]))
    for f in bad:
        out('ACT', 'RECOVER-TRACKED-LOCAL', f, 'tracked although git-ignored / local-only (it is published on push)',
            f'git -C {kit} rm --cached -- {f} in a kit commit (the lead confirms; the file stays on disk)')
    # launch records, board entries, product worktrees, runtime size
    ld = kit_path('launches', kit=kit)
    for f in sorted(os.listdir(ld)) if os.path.isdir(ld) else []:
        r, err = load_json(os.path.join(ld, f))
        if err or not isinstance(r, dict):
            out('ACT', 'RECOVER-LAUNCH', f, f'unreadable launch record ({err})', 'delete it')
        elif not r.get('completed'):
            age = (time.time() - os.path.getmtime(os.path.join(ld, f))) / 3600
            out('WARN', 'RECOVER-LAUNCH', r.get('runId', f), f'workflow launch with no completion, {age:.0f} h old ({os.path.basename(str(r.get("script", "")))})',
                'still running in a live session? leave it; dead -> resume (orchestrate E3) or orch.ps1 launch -Done -RunId <id>')
    bd = kit_path('board', kit=kit)
    for f in sorted(os.listdir(bd)) if os.path.isdir(bd) else []:
        p = os.path.join(bd, f)
        e, err = load_json(p)
        if err or not isinstance(e, dict):
            continue
        try:
            beat = datetime.datetime.fromisoformat(re.sub(r'(\.\d{6})\d+', r'\1', str(e.get('beat'))))
            age_h = (datetime.datetime.now(beat.tzinfo) - beat).total_seconds() / 3600
        except ValueError:
            age_h = 99
        if e.get('status') != 'left' and age_h > 20 / 60:
            if fix and age_h > 12:
                e['status'] = 'left'
                e['leftBy'] = 'kit-audit (no heartbeat > 12 h)'
                with open(p, 'w', encoding='utf-8') as fh:
                    json.dump(e, fh, indent=2)
                out('FIX', 'RECOVER-BOARD', f, f'stale board entry {e.get("agent")} ({e.get("run")}) marked left ({age_h:.0f} h without a heartbeat)')
            else:
                out('WARN', 'RECOVER-BOARD', f, f'board entry {e.get("agent")} ({e.get("run")}) has no heartbeat for {age_h:.1f} h',
                    'orch.ps1 supervise -AutoFix closes finished workflow agents; > 12 h: kittool.py audit recover --fix marks it left')
    for root in (cfg or {}).get('worktreeRoots') or []:
        root = os.path.expanduser(str(root))
        for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            gp = os.path.join(root, d, '.git')
            if os.path.isfile(gp):
                gd = open(gp, encoding='utf-8', errors='replace').read().replace('gitdir:', '').strip()
                if not os.path.isdir(gd):
                    out('ACT', 'RECOVER-ORPHAN', os.path.join(root, d), 'worktree folder whose repo record is gone (git cannot see or clean it)',
                        'check it holds nothing unpushed, then the lead deletes the folder; run git worktree prune in its repo')
    cl = os.path.join(kit, 'skills', 'orchestrate', 'orch.ps1')
    rc, o, e = pwsh(cl, 'cleanup', *(['-Quiet'] if fix else ['-DryRun']), timeout=300)   # the verb: without it orch.ps1 printed usage (exit 2)
    if rc == 124:
        out('WARN', 'RECOVER-CLEANUP', 'orch.ps1 cleanup', 'did not finish within 5 min (git host lookups for many branches?): run it by hand with -DryRun')
    elif rc != 0:
        out('ACT', 'RECOVER-CLEANUP', 'orch.ps1 cleanup', f'exit {rc}: {(e or o)[:200]}')
    elif o and not fix:
        out('INFO', 'RECOVER-CLEANUP', 'orch.ps1 cleanup -DryRun', f'{len(o.splitlines())} line(s) of clutter it would remove (--fix runs it; safe: it skips anything in use)')
    elif fix:
        out('FIX', 'RECOVER-CLEANUP', 'orch.ps1 cleanup', 'ran (log: <runtime>/logs/cleanup.log)')
    rt = kit_path('runtime', kit=kit)
    size = 0
    for d, _, fs in os.walk(rt):
        for f in fs:
            try:
                size += os.path.getsize(os.path.join(d, f))
            except OSError:
                pass
    if size > 5 * 1024 ** 3:
        out('WARN', 'RECOVER-RUNTIME', rt, f'runtime holds {size / 1024 ** 3:.1f} GB', 'find the folder that grows; add a prune rule to orch.ps1 cleanup')


# ------------------------------------------------------------------ scan
def cmd_scan(kit):
    files = tracked(kit) or []
    lint = os.path.join(kit, 'skills', 'orchestrate', 'kittool.py')
    tmp = os.path.join(kit_path('cache', create=True, kit=kit), 'kit-audit-lint.json')
    run([py(), '-X', 'utf8', lint, kit, '--warn', '--no-flow', '--json', tmp], timeout=120)
    lj, _ = load_json(tmp)
    for p in lj or []:
        out('ACT', f'LINT-{p["code"]}', p['where'], p['problem'])
    live = live_kit()
    kl = os.path.join(live, 'skills', 'dev-kit', 'kit.local.json')
    if os.path.isfile(kl):
        rc, o, _ = run([py(), '-X', 'utf8', lint, kit, '--no-flow', '--org-terms', kl], timeout=120)
        for l in o.splitlines():
            if l.startswith('ORG-TERM'):
                out('ACT', 'GENERIC-ORG-TERM', l.split()[1].rstrip(':'), l.split(':', 1)[1].strip())
    pk = os.path.join(kit, 'skills', 'orchestrate', 'kittool.py')
    rc, o, e = run([py(), '-X', 'utf8', pk, 'port', '--check'], timeout=60)
    if rc:
        out('ACT', 'PORT-DRIFT', 'kittool.py port --check', (o or e)[:300], f'python -X utf8 {pk} port')
    agents = {os.path.basename(f)[:-3] for f in files if re.match(r'agents/[^/]+\.md$', f)}
    for f in files:
        t = aread(kit, f)
        pass   # LESSONS.md section caps: kittool.py lint LESSONS-CAP
        if f.startswith('workflows/') and f.endswith('.js'):
            for m in re.finditer(r"agentType:\s*'([\w-]+)'", t):
                if m.group(1) not in agents:
                    out('ACT', 'WF-AGENT', f, f'spawns agentType {m.group(1)}, which has no agents/{m.group(1)}.md')
        if re.match(r'agents/[^/]+\.md$', f):
            tools = re.search(r'^tools:\s*(.+)$', t, re.M)
            sk = re.search(r'skills/([\w-]+)/SKILL\.md', t)
            if tools and sk:
                st = aread(kit, f'skills/{sk.group(1)}/SKILL.md')
                tl = tools.group(1)
                if re.search(r'\.ps1\b', st) and not re.search(r'\b(Bash|PowerShell)\b', tl):
                    out('ACT', 'AGENT-TOOLS', f, f'its skill {sk.group(1)} runs scripts, but tools ({tl}) has neither Bash nor PowerShell')
                if re.search(r'\b(Edit|Write)\b', st) and 'never edits' not in t.lower() and not re.search(r'\b(Edit|Write)\b', tl) and 'read-only' not in t.lower():
                    out('WARN', 'AGENT-TOOLS', f, f'its skill mentions editing files, tools ({tl}) cannot edit')
    # config: example keys documented (nested), documented keys read by some script
    doc, documented = config_doc_keys(kit)
    ex, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.example.json'))
    for p in key_paths(ex or {}):
        if '.' in p and not any(p.startswith(m + '.') for m in USER_MAPS) and p not in documented and f'`{p}' not in doc:
            out('ACT', 'CONFIG-UNDOC', f'kit.example.json {p}', 'not documented in README "Configuration"')
    code = '\n'.join(aread(kit, f) for f in files if f.endswith(('.ps1', '.py', '.mjs', '.js')))
    table = doc.split('### Tracker')[0]
    for key in sorted({m for m in re.findall(r'^\| `([A-Za-z][\w.]*)`', table, re.M)}):
        leaf = key.split('.')[-1]
        if not re.search(r'[\'".]' + re.escape(leaf) + r'\b', code):
            out('WARN', 'CONFIG-UNUSED', f'README Configuration {key}', 'documented, but no script seems to read it (dead key, or read under another name?)')
    reads = script_config_keys(kit, files)
    for key, where in sorted(reads.items()):
        top = key.split('.')[0]
        if top not in documented and f'`{top}' not in doc:
            out('ACT', 'CONFIG-UNDOC', where, f'script reads kit.local.json "{key}", not documented in README "Configuration"')
        elif ex is not None and top not in ex:
            out('WARN', 'CONFIG-EXAMPLE', where, f'"{top}" is documented but missing from kit.example.json')
    # generic: absolute machine paths
    for f in files:
        if f.startswith(('examples/', '.codex/', '.agents/')) or not f.endswith(('.ps1', '.py', '.js', '.mjs', '.md', '.json')):
            continue
        for ln, line in enumerate(aread(kit, f).split('\n'), 1):
            if re.search(r'(?<![\w/])[A-Za-z]:[\\/](?:Users|Codebase|src|work|Projects)\b|/home/\w+/|/Users/\w+/', line) and not re.search(r'e\.g\.|example|<|//|^\s*#|Windows:', line):
                out('WARN', 'GENERIC-PATH', f'{f}:{ln}', 'absolute machine path: config key or derived path instead?')
    # script pitfall candidates (each is a lead to read, not a verdict)
    for f in files:
        t = aread(kit, f)
        if f.endswith('.ps1'):
            ps_pitfalls(kit, f, t)
        elif f.endswith('.py'):
            for ln, line in enumerate(t.split('\n'), 1):
                if re.match(r'\s*except\s*:', line):
                    out('WARN', 'PY-BARE-EXCEPT', f'{f}:{ln}', 'bare except: hides real errors (KeyboardInterrupt too)')
                if re.search(r'(?<![\w.])open\(', line) and 'encoding' not in line and not re.search(r"""['"][rwax+]*b[rwax+]*['"]""", line):
                    out('WARN', 'PY-ENCODING', f'{f}:{ln}', 'open() without encoding= reads cp1252 on Windows')
    doc_flags(kit, files)


def ps_pitfalls(kit, f, t):
    code = strip_ps_comments(t)
    lines = code.split('\n')
    # one variable, two spellings, both ASSIGNED (e.g. a list $L and a loop $l): the second silently overwrites the first
    assigned = {}
    for ln, line in enumerate(lines, 1):
        for m in re.finditer(r'\$(?:script:|local:)?([A-Za-z_]\w*)\s*(?:=(?![=~])|\+=)|foreach\s*\(\s*\$([A-Za-z_]\w*)\s+in\b', line, re.I):
            n = m.group(1) or m.group(2)
            if n.lower() not in AUTOMATIC:
                assigned.setdefault(n.lower(), {}).setdefault(n, ln)
    for low, forms in assigned.items():
        if len(forms) > 1:
            (a, la), (b, lb) = sorted(forms.items(), key=lambda x: x[1])[:2]
            out('WARN', 'PS-CASE', f'{f}:{lb}', f'${b} (line {lb}) is the same variable as ${a} (line {la}): PowerShell names are case-insensitive')
    pm = re.search(r'(?is)^\s*param\s*\((.*?)\)\s*$', code, re.M)
    for ln, line in enumerate(lines, 1):
        m = re.search(r'\$(\w+)\s*=(?![=~])', line)
        if m and m.group(1).lower() in AUTOMATIC - {'lastexitcode'} and not re.search(r'\[(ref)\]', line):
            out('WARN', 'PS-AUTOVAR', f'{f}:{ln}', f'assigns automatic variable ${m.group(1)} (silently overwritten / ignored)')
        if re.search(r'\.Substring\(\s*[^,()]+,\s*\d+\s*\)', line) and not re.search(r'Min\(|\.Length\s*-g[te]|-g[te]\s*\d|ToString\(|GetBytes|Guid', line):
            out('WARN', 'PS-SUBSTRING', f'{f}:{ln}', '.Substring(i, n) with a fixed n and no length guard on the line: throws on short strings')
        if os.path.basename(f) in LIBS and re.match(r'\s*exit\b', line):
            out('WARN', 'PS-LIB-EXIT', f'{f}:{ln}', 'exit in a dot-sourced library ends the CALLER')
    if pm:
        for m in re.finditer(r'\[string\[\]\]\s*\$(\w+)', pm.group(1)):
            v = m.group(1)
            if not re.search(r'Split-KitList[^\n]*\$' + v + r'\b|\$' + v + r'\b[^\n]*-split', code, re.I):
                out('WARN', 'PS-FILE-ARRAY', f, f'[string[]]${v}: `pwsh -File` passes "a,b" as ONE string; use Split-KitList')
        for m in re.finditer(r'\$(input|args|host|error|matches|pid|home)\b', pm.group(1), re.I):
            out('ACT', 'PS-AUTOVAR', f, f'parameter ${m.group(1)} shadows an automatic variable')


def doc_flags(kit, files):
    """`<script>.ps1 -Flag` in Markdown where the script has no such parameter (docs that contradict scripts)."""
    params = {}
    for f in files:
        if f.endswith('.ps1'):
            code = strip_ps_comments(aread(kit, f))
            # every param block in the file (an area script has one per verb function): a flag is fine when some verb takes it
            for m in re.finditer(r'(?is)\bparam\s*\((.*?)\)\s*\n', code):
                ps = {x.lower() for x in re.findall(r'\$(\w+)', m.group(1))} | {x.lower() for x in re.findall(r"Alias\('([^']+)'", m.group(1))}
                params.setdefault(os.path.basename(f), set()).update(ps)
    for f in files:
        if not f.endswith('.md') or f.startswith(('.codex/', '.agents/')) or f.endswith(('LESSONS.md',)):
            continue
        for ln, line in enumerate(aread(kit, f).split('\n'), 1):
            for span in re.findall(r'`([^`]+)`', line):
                for m in re.finditer(r'([\w-]+\.ps1)((?:\s+[^\s|;]+)*)', span):
                    s = m.group(1)
                    if s not in params:
                        continue
                    for flag in re.findall(r'(?<![\w-])-([A-Za-z]\w+)', m.group(2)):
                        fl = flag.lower()
                        if fl in ('file', 'noprofile', 'command', 'whatif', 'verbose', 'erroraction') or any(p.startswith(fl) for p in params[s]):
                            continue
                        out('WARN', 'DOC-FLAG', f'{f}:{ln}', f'`{s} -{flag}`: {s} has no such parameter')


# ------------------------------------------------------------------ stamp / due
def last_audit(kit):
    p = kit_path('last-kit-audit', kit=kit)
    try:
        return datetime.datetime.fromisoformat(open(p, encoding='utf-8').read().strip()[:19])
    except (OSError, ValueError):
        return None


def cmd_stamp(kit):
    p = kit_path('last-kit-audit', create=True, kit=kit)
    now = datetime.datetime.now().isoformat(timespec='seconds')
    with open(p, 'w', encoding='utf-8') as f:
        f.write(now + '\n')
    out('FIX', 'AUDIT-STAMP', p, f'last kit audit = {now} (the SessionStart nudge resets)')


def cmd_due(kit):
    cfg, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.local.json'))
    every = get(cfg, 'kitAudit.everyDays')
    every = 7 if every is None else every
    last = last_audit(kit)
    if not every:
        out('INFO', 'AUDIT-DUE', kit, 'weekly audit nudge off (kitAudit.everyDays 0)')
    elif not last or (datetime.datetime.now() - last).days >= every:
        out('INFO', 'AUDIT-DUE', kit, f'due (last {last.date() if last else "never"}, every {every} days)')
    else:
        out('INFO', 'AUDIT-DUE', kit, f'not due (last {last.date()}, next {(last + datetime.timedelta(days=every)).date()})')


def audit_main(a):
    if not a or a[0] not in ('setup', 'config', 'recover', 'scan', 'stamp', 'due'):
        sys.exit(__doc__)
    cmd = a.pop(0)

    def opt(n, val=False):
        if n not in a:
            return None
        i = a.index(n)
        a.pop(i)
        return a.pop(i) if val else True
    kit, js, fix, fill = opt('--kit', True), opt('--json', True), opt('--fix'), opt('--fill')
    kit = os.path.abspath(kit) if kit else (OWN if cmd == 'scan' else live_kit())
    {'setup': lambda: cmd_setup(kit, fix), 'config': lambda: cmd_config(kit, fill), 'recover': lambda: cmd_recover(kit, fix),
     'scan': lambda: cmd_scan(kit), 'stamp': lambda: cmd_stamp(kit), 'due': lambda: cmd_due(kit)}[cmd]()
    order = {'FIX': 0, 'ACT': 1, 'ASK': 2, 'WARN': 3, 'INFO': 4}
    for x in sorted(findings, key=lambda x: (order[x['level']], x['code'], x['where'])):
        print(f"{x['level']:4} {x['code']} {x['where']}: {x['what']}" + (f" -> {x['fix']}" if x['fix'] else ''))
    n = {lv: sum(1 for x in findings if x['level'] == lv) for lv in order}
    print(f'kit-audit {cmd} ({kit}): ' + ', '.join(f'{v} {k}' for k, v in n.items() if v) if findings else f'kit-audit {cmd} ({kit}): nothing found')
    if js:
        with open(js, 'w', encoding='utf-8') as f:
            json.dump(findings, f, indent=1)
    sys.exit(1 if n['ACT'] or n['ASK'] else 0)


# ================================ 7. cost: tokens each agent type reads + the prompts the workflows build ================================
COST_MJS = r'''// Renders every prompt a kit workflow builds, by running the workflow with mock agents and sample args.
// Used by kit-cost.ps1 (token budget per agent type); also a cheap behaviour check: the label/model/agentType of every
// step is printed, so a prompt refactor can be diffed against the previous version.
//   node kit-cost.mjs <kitDir> [--prompts] [--clean] [--set <wf>.<arg>=<json>]...  -> JSON { calls: [{ wf, label, agentType, model, effort, bytes }], logs }
//   --clean: reviews find nothing and every QA check passes (exercises learn: 'auto'); --set dev-wave.review='"auto"' overrides a sample arg
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const kit = (process.argv[2] || '.claude').replace(/[\\/]+$/, '')
const MR = (repo, n) => ({ url: `https://git.example.com/acme/${repo}/-/merge_requests/${n}`, repo, merged: false })
const CLEAN = process.argv.includes('--clean')
const report = (id) => ({ mrs: [MR('api', id === 'X2' ? 2 : 1)], worktrees: [`${id.toLowerCase()}-api`], done: ['A1'], deferred: [], needsLiveCheck: ['open the form and save'], seed: [], foreignHooks: [], summary: 'implemented, checks green', needsDecision: [], localTest: { status: 'PASS', env: 'shop r1', rounds: 1, failing: [], goalsDoc: 'goals.md' }, testerGuide: 'doc',
  changedLines: id === 'X2' ? 12 : 30, changedFiles: id === 'X2' ? ['src/auth/LoginService.java'] : ['web/src/order-form.ts'] })

function mock(label, opts) {
  const [kind, rest = ''] = label.split(':'); const id = rest.split('@')[0]
  switch (kind) {
    case 'build': case 'fix': case 'ship': return report(id)
    case 'review': return { findings: id === 'X2' && !CLEAN ? [{ mr: MR('api', 2).url, file: 'src/Order.java', line: 10, severity: 'blocking', problem: 'null check missing', fix: 'add it' }] : [] }
    case 'ci': return { done: true, mrs: [{ mr: MR('api', 1).url, status: 'success' }] }
    case 'learn': return { signals: 1, lessonsChanged: [] }
    case 'test': case 'retest': return { code: id, checks: [
      { id: 'T1', subtask_id: 't1', screen: 'Orders', result: 'PASS', what_was_done: 'saved', observed: 'saved', evidence: [`${id}-T1_01_saved.jpeg`] },
      ...(CLEAN ? [] : [{ id: 'T2', subtask_id: 't1', screen: 'Orders', result: 'PASS_WITH_NOTE', what_was_done: 'opened', observed: 'label differs', evidence: [] },
      { id: 'T3', subtask_id: 't1', screen: 'Orders', result: 'FAIL', what_was_done: 'cancelled', observed: 'PUT /api/orders -> 500', evidence: [] }])],
      findings: CLEAN ? [] : ['seed data was old'], setup_changes: [], data_created: [] }
    case 'audit': return { reclassify: [{ id: 'T2', defect: false, reason: 'cosmetic' }], newDefects: [] }
    case 'verify': return { verdicts: [{ id: 'T3', confirmed: true, observed: '500 again', evidence: [] }] }
    case 'close': case 'hold': case 'add-followups': return { ok: true, output: 'published' }
    case 'prepare': return { runDir: SAMPLE['test-and-close'].runDir, items: 2, left: [{ id: 't3', reason: 'not live' }], summary: 'sample' }
    case 'load-run': return { json: JSON.stringify(SAMPLE['test-and-close']) }
    case 'analyse': return { proposals: [{ file: `${kit}/skills/dev-kit/LESSONS.md`, change: 'add-lesson', text: 'x', evidence: '2 signals', occurrences: 2, confidence: 'high' }] }
    case 'apply': return { applied: ['x'], proposedForApproval: [], rejected: [], report: 'r.md' }
    default: return 'ok'
  }
}

const SAMPLE = {
  'dev-wave': { brief: '/ws/.claude/<runtime>/work/briefs/wave-brief.md', kitDir: kit, mandate: ['Fix the order form bugs from the QA run and ship them.'],
    agents: [{ id: 'X1', items: 'A1, A2', area: 'order form' }, { id: 'X2', items: 'A3', area: 'order list', complex: true }] },
  'test-and-close': { runDir: '/ws/.claude/<runtime>/work/qa-runs/2026-01-01-sample', kitDir: kit, title: 'Sample epic', target: 'my-staging', tester: 'QA',
    mandate: ['Test the deployed epic tasks and close them.'], context: 'Use tenant acme.', tracker: { list: 'L1', parent: 'P1' },
    lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556', user: 'qa-user-1' }],
    items: [{ code: 'W1', title: 'Order form', guideFile: '/ws/guides/W1.md', lane: 'web', subtasks: [{ id: 't1', name: 'Order form', mrs: 'api!1' }] },
      { code: 'P1', title: 'Order app', guideFile: '/ws/guides/P1.md', lane: 'app', subtasks: [{ id: 't2', name: 'Order app', mrs: 'app!3' }] }] },
  'kit-retro': { kitDir: kit },
  'test-and-close#select': { select: { statuses: ['promoted', 'inTest'] }, target: 'local', kitDir: kit, mandate: ['Test everything promoted or in test on local.'] },
}

for (let i = 0; i < process.argv.length; i++) if (process.argv[i] === '--set') {
  const [, wf, key, val] = process.argv[++i].match(/^([\w-]+)\.(\w+)=(.*)$/)
  SAMPLE[wf][key] = JSON.parse(val)
}
const calls = [], logs = []
for (const wf of Object.keys(SAMPLE)) {
  const src = readFileSync(join(kit, 'workflows', `${wf.split('#')[0]}.js`), 'utf8').replace(/^export const meta/m, 'const meta')
  const body = new Function('args', 'agent', 'pipeline', 'parallel', 'log', 'phase', `return (async () => {\n${src}\n})()`)
  const agent = async (prompt, opts = {}) => {
    calls.push({ wf, label: opts.label || '?', agentType: opts.agentType || '', model: opts.model || '', effort: opts.effort || '', bytes: Buffer.byteLength(prompt, 'utf8'), prompt })
    return mock(opts.label || '', opts)
  }
  const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => { let r = it; for (const [i, s] of stages.entries()) r = i === 0 ? await s(it) : await s(r, it); return r }))
  const parallel = async (fns) => Promise.all(fns.map((f) => f()))
  await body(JSON.parse(JSON.stringify(SAMPLE[wf])), agent, pipeline, parallel, (m) => logs.push(`${wf}: ${m}`), () => {})
}
const keep = process.argv.includes('--prompts')
console.log(JSON.stringify({ calls: calls.map(({ prompt, ...c }) => (keep ? { ...c, prompt } : c)), logs }))
'''


def cmd_cost(a):
    """Tokens (UTF-8 bytes / 4) each agent type reads at start - the always-loaded files, its agent definition, its skill and its
    LESSONS.md section - plus the prompt each workflow step builds (the workflows run under node with mock agents)."""
    kit = os.path.abspath(next((x for x in a if not x.startswith('--')), KIT_DIR))
    tok = lambda s: (len(s.encode('utf-8')) + 3) // 4
    ftok = lambda rel: tok(read(os.path.join(kit, rel)))
    rules = [f'rules/{f}' for f in sorted(os.listdir(os.path.join(kit, 'rules'))) if f.endswith('.md') and not f.endswith('.local.md')] if os.path.isdir(os.path.join(kit, 'rules')) else []
    always = ftok('CLAUDE.md') + ftok('AGENTS.md') + sum(ftok(r) for r in rules if 'paths' not in frontmatter(read(os.path.join(kit, r))))
    skills = sorted(d for d in os.listdir(os.path.join(kit, 'skills')) if os.path.isfile(os.path.join(kit, 'skills', d, 'SKILL.md')))
    always += sum(tok(frontmatter(read(os.path.join(kit, 'skills', s, 'SKILL.md'))).get('description', '')) for s in skills)
    lessons = read(os.path.join(kit, 'LESSONS.md'))
    lsec = lambda s: tok((re.search(r'^## ' + re.escape(s) + r'\n(.*?)(?=^## |\Z)', lessons, re.S | re.M) or [''])[0] if lessons else '')
    reads = {'dev-agent': 'dev-kit', 'mr-reviewer': 'dev-kit', 'qa-tester': 'qa-kit', 'qa-verifier': 'qa-kit', 'kit-auditor': 'kit-audit'}
    calls = []
    node = shutil.which('node')
    if node:
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, 'cost.mjs')
            with open(src, 'w', encoding='utf-8') as fh:
                fh.write(COST_MJS)
            r = subprocess.run([node, src, kit], capture_output=True, text=True, encoding='utf-8', timeout=120)
            try:
                calls = json.loads(r.stdout).get('calls', [])
            except ValueError:
                print(f'kittool cost: the workflow render failed: {(r.stderr or r.stdout)[:300]}', file=sys.stderr)
    for c in calls:
        c['tokens'] = (c['bytes'] + 3) // 4
    if '--steps' in a:
        for c in calls:
            print(f"{c['wf']:15} {c['label']:18} {c['agentType']:12} {c['model']:7} {c['effort']:6} {c['tokens']:6}")
        return 0
    rows = [{'agent': f'{ag} (start)', 'always': always, 'files': ftok(f'agents/{ag}.md') + ftok(f'skills/{sk}/SKILL.md') + lsec(sk)} for ag, sk in reads.items()]
    for wf in sorted({c['wf'] for c in calls}):
        cs = [c for c in calls if c['wf'] == wf]
        rows.append({'agent': f'run: {wf} ({len(cs)} steps)', 'always': always * len(cs), 'files': sum(c['tokens'] for c in cs)})
    for r_ in rows:
        r_['total'] = r_['always'] + r_['files']
    if '--json' in a:
        print(json.dumps(rows, indent=1))
        return 0
    print('| Agent / run | always-loaded | start files / prompts | total |\n|---|---:|---:|---:|')
    for r_ in rows:
        print(f"| {r_['agent']} | {r_['always']} | {r_['files']} | {r_['total']} |")
    return 0


# ================================ prose: measure a produced text against templates.md "Writing standards"
REQ_RX = {'link': r'https?://\S+|\b[\w.-]+[!#]\d+\b|\b(?:MR|PR)\s*!?#?\d+',
          'id': r'\b[A-Z][A-Z0-9]*-\d+\b|#\d+\b|\b[A-Z]\d+\b|\b[0-9a-z]{7,}\b|\bCU-\w+',
          'path': r'[\w./-]+\.(?:md|ps1|py|mjs|js|ts|json|java|xml|ya?ml|cs|go|rs|kt|sql|html?)\b(?::\d+)?|<kit>/\S+',
          'cmd': r'`[^`]*\b(?:pwsh|python|node|git|dev\.ps1|orch\.ps1|qa\.ps1|kit\.ps1|swarm\.ps1|localenv\.ps1|kittool\.py|devtools\.py|npm|&)\b[^`]*`',
          'evidence': r'\.(?:png|jpe?g|json|log|txt|html?)\b|https?://\S+',
          'expected': r'(?i)\bexpected\b', 'options': r'(?m)^\s*[-*]?\s*(?:Option\s+)?A[:)]', 'recommended': r'(?i)\brecommended\b',
          'verdict': r'\b(?:PASS|FAIL|BLOCKED|PASS_WITH_NOTE|NOT_TESTED)\b',
          'conv': r'^(?:feat|fix|refactor|perf|docs|test|chore|build|ci|style|revert)(?:\([^)]+\))?!?: \S'}


def writing_standards(kit):
    """templates.md "Writing standards" -> ({kind: {format, limits, required}}, [banned regex])."""
    t = read(os.path.join(kit, 'skills', 'dev-kit', 'templates.md'))
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
    text = re.sub(r'\A---\n.*?\n---\n', '', text.replace('\r\n', '\n'), flags=re.S)   # front matter: one-line fields by design
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


def words(s):
    return len(re.findall(r"[A-Za-z0-9][\w'’.-]*", re.sub(r'`[^`]*`|https?://\S+', 'x', s)))


def prose_check(kind, text, spec, banned):
    """Findings (strings) for one produced text of one kind."""
    out = []
    lines, secs = prose_parts(text)
    body = [l for l in lines if l.strip()]
    flat = '\n'.join(lines)
    for tok in spec['limits'].replace(';', ' ').split():
        m = re.match(r'^(?:(each|first|[A-Z][\w ()/-]*?):)?(\d+)(w|t|l|ch|sw|b)$', tok)
        if not m:
            continue
        scope, n, u = (m.group(1) or '').replace('_', ' ') or None, int(m.group(2)), m.group(3)
        targets = {'(all)': body} if not scope else {'(first line)': body[:1]} if scope == 'first' else secs if scope == 'each' else {scope: secs.get(scope, [])}
        for name, ls in targets.items():
            txt = '\n'.join(ls)
            if u == 'w' and words(txt) > n:
                out.append(f'{name}: {words(txt)} words (max {n})')
            elif u == 't' and (len(txt.encode("utf-8")) + 3) // 4 > n:
                out.append(f'{name}: {(len(txt.encode("utf-8")) + 3) // 4} tokens (max {n})')
            elif u == 'l' and len([l for l in ls if l.strip()]) > n:
                out.append(f'{name}: {len([l for l in ls if l.strip()])} lines (max {n})')
            elif u == 'b':
                nb = len([l for l in ls if re.match(r'^(?:[-*]|\d+\.)\s', l)])
                if nb > n:
                    out.append(f'{name}: {nb} bullets (max {n})')
            elif u == 'ch':
                for i, l in enumerate(ls, 1):
                    if len(l) > n and not l.lstrip().startswith('|') and not re.search(r'https?://', l) and not re.fullmatch(r'\s*(?:\*\*[^*]+\*\*\s*)?`[^`]+`\s*', l):   # a lone command cannot wrap
                        out.append(f'{name}: line {i} is {len(l)} chars (max {n}): {l[:60]}...')
                        break
            elif u == 'sw':
                prose = re.sub(r'(?m)^\s*\|.*$', '', txt)
                for s in re.split(r'(?<=[.!?])\s+|\n', prose):
                    if words(s) > n:
                        out.append(f'{name}: a sentence of {words(s)} words (max {n}): {s.strip()[:60]}...')
                        break
    want = re.findall(r'##\s+([^,#]+?)\s*(?:,|$)', spec['format'])
    if want:
        have = list(secs)
        missing = [w for w in want if w not in have]
        if missing:
            out.append(f'missing sections: {", ".join("## " + w for w in missing)} (format: {spec["format"]})')
        order = [w for w in have if w in want]
        if not missing and order != want:
            out.append(f'sections out of order: {" > ".join(order)} (format: {" > ".join(want)})')
    for r in spec['required']:
        rx = REQ_RX.get(r)
        if rx and not re.search(rx, text if r != 'conv' else (body[0] if body else ''), re.M):
            out.append(f'required fact missing: {r}')
    for b in banned:
        mm = re.search(b, flat, re.I | re.M)
        if mm:
            out.append(f'filler: "{mm.group(0).strip()}"')
    return out


def result_notes(obj):
    """Every note string in a results.json (any depth)."""
    if isinstance(obj, dict):
        for k_, v in obj.items():
            if k_ in ('note', 'notes', 'finding') and isinstance(v, str):
                yield v
            else:
                yield from result_notes(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from result_notes(v)


def cmd_prose(a):
    """kittool.py prose --kind <kind> <file | -> [--json] | --kinds"""
    kit = KIT_DIR
    kinds, banned = writing_standards(kit)
    if '--kinds' in a:
        for k_, s in kinds.items():
            print(f'{k_:17} {s["limits"]:32} {s["purpose"]}')
        return 0
    kind = a[a.index('--kind') + 1] if '--kind' in a and a.index('--kind') + 1 < len(a) else ''
    files = [x for i, x in enumerate(a) if not x.startswith('--') and (i == 0 or a[i - 1] != '--kind')]
    if kind not in kinds or not files:
        print(f'kittool prose: --kind <{"|".join(kinds)}> <file | -> [--json]', file=sys.stderr)
        return 2
    src = files[0]
    text = sys.stdin.read() if src == '-' else read(src)
    if kind == 'result-note' and src.endswith('.json'):
        found = []
        for n in result_notes(json.loads(text)):
            found += [f'note "{n[:50]}": {f}' for f in prose_check(kind, n, kinds[kind], banned)]
    else:
        found = prose_check(kind, text, kinds[kind], banned)
    if '--json' in a:
        print(json.dumps({'kind': kind, 'file': src, 'findings': found}))
    else:
        for f in found:
            print(f'PROSE {kind} {src}: {f}')
    return 1 if found else 0

# ================================ main ================================
if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    if cmd == 'lint':
        sys.exit(cmd_lint(rest))
    if cmd == 'flow':
        sys.exit(cmd_flow(rest))
    if cmd == 'port':
        sys.exit(cmd_port(rest))
    if cmd == 'audit':
        sys.exit(audit_main(rest))
    if cmd == 'cost':
        sys.exit(cmd_cost(rest))
    if cmd == 'prose':
        sys.exit(cmd_prose(rest))
    print(__doc__)
    sys.exit(2)
