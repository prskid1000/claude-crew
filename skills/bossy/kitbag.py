#!/usr/bin/env python3
"""kitbag.py: the kit's own tooling in one file - lint, README graph, audit stamp, prose, budget, goodies (and their commands).

  python -X utf8 kitbag.py lint  [<kit>] [--summary] [--warn] [--no-flow] [--org-terms <kit.local.json | a,b>] [--json <out>]
  python -X utf8 kitbag.py flow --readme [<kit>]       # README graph sections (the interactive page: goody flow-map)
  python -X utf8 kitbag.py port  [--check]             # Codex / Antigravity ports of agents, hooks, workflows (goody ports)
  python -X utf8 kitbag.py audit stamp | scan [--kit <dir>] [--json <file>]   # stamp resets the audit nudge; scan: goody kit-admin
  python -X utf8 kitbag.py cost  [<kit>] [--steps] [--json]   # start tokens per agent, workflow prompts (goody kit-admin)
  python -X utf8 kitbag.py prose --kind <kind> <file | -> [--json] · prose --kinds   # vs templates.md "Writing standards"
  python -X utf8 kitbag.py release [--tag] [--publish]   # next SemVer + notes from Conventional Commits (goody kit-admin)
  python -X utf8 kitbag.py sections [--fix] [<file> ...]   # section maps vs `---- <name>:` markers (lint SECTION-*)
  python -X utf8 kitbag.py budget [show] · budget raise -Reason "<why>"   # the kit total vs its cap; raise: goody kit-admin
  python -X utf8 kitbag.py goody list | add <name> [--auto] | remove <name> | check | sync | test [<name>] | prune [--days N] [--dry-run]

lint problem codes: each message says what is wrong and the fix; skills/bossy/kit-admin.md (goody kit-admin) lists them.
audit output: `<LEVEL> <CODE> <where>: <what> [-> <fix>]`, LEVEL FIX | ACT | ASK | WARN | INFO.
Exit codes: 0 ok · 1 problems found (lint, stale ports, ACT/ASK audit findings, a missing goody in `goody check`) · 2 usage
error or a command that needs a goody not installed (one line: `<feature> is a goody: run kitbag.py goody add <name>`).

Sections: L31 paths · L82 kitlog · L162 load · L539 lint · L908 README graph · L1014 lint command · L1047 audit · L1156 registry ·
  L1385 prose · L1528 sections · L1658 budget · L1676 goodies · L2141 main
"""
import contextlib, datetime, fnmatch, importlib.util, io, json, os, re, shutil, subprocess, sys, tempfile, time, zipfile
import os.path as osp
from collections import defaultdict, deque
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

KIT_DIR = osp.dirname(osp.dirname(osp.dirname(osp.abspath(__file__))))   # 3 levels up: <kit>

# ---- paths: kit.example.json _paths
with open(osp.join(KIT_DIR, 'skills', 'crafty', 'kit.example.json'), encoding='utf-8') as _f:
    MAP = json.load(_f)['_paths']

def runtime_dir(kit=None):
    return os.environ.get('CLAUDE_RUNTIME') or osp.join(kit or KIT_DIR, MAP['runtimeDir'])

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

@contextlib.contextmanager
def locked(path, stale=120):
    """A lock file beside path for one writer at a time (devtools.py imports it); a dead writer's stale lock is taken over."""
    lock = path + '.lock'
    fd, end = None, time.time() + stale + 10
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
        o = {'at': datetime.datetime.now().astimezone().isoformat()}
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
    try:
        rc = cli() or 0
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
        if rc and not isinstance(e.code, int):   # sys.exit('<why>') caught here printed nothing: callers saw a bare exit 1
            err = str(e.code)
            print(err, file=sys.stderr)
    finally:
        kitlog('calls', 'end', {'pid': os.getpid(), 'rc': rc, 'ms': int((time.time() - t0) * 1000), **({'err': err[:300]} if err else {})})
    return rc

# ---- load: kit files, the reach graph
SKIP_DIRS = {'node_modules', '__pycache__', '.git', '.runtime', '.state', '.claude-runtime', 'worktrees', 'memory'}
# outside the graph: generated ports, git / legal files
REPO_ONLY = ('LICENSE', '.gitignore', '.gitattributes', 'GEMINI.md', '.codex', '.agents', '.github')
GENERATED = ('.codex/', '.agents/', 'GEMINI.md')
# caps: content = read by agents / people; plumbing = read only by git, CI, harness
PLUMBING = ('LICENSE', '.gitignore', '.gitattributes', '.githooks/', '.github/', 'settings.json')
CAP_BASE = 200000   # _manifest.caps.totalTokens moves only in `budget raise` steps from here: x1.1, rounded to 1k (lint BUDGET-CAP)
TEST_CAP = 33000    # _manifest.caps.testTokens default: tests/ (lint BUDGET-TESTS)
TRIM_FIRST = 'trim first (dense prose, dedupe; never golf that hurts reading); if impossible: kitbag.py budget raise -Reason "<why trimming cannot make room>"'

def cap_next(c):
    return int(round(c * 1.1 / 1000)) * 1000

def cap_problem(kdir, cap):
    """None, or why `cap` is not a budget-raise step (from CAP_BASE, at most one step above the last commit's cap)."""
    c = CAP_BASE
    while c < cap:
        c = cap_next(c)
    if c != cap:
        return f'totalTokens {cap} is not a raise step ({CAP_BASE} x 1.1, rounded to 1k, per step): change it only with kitbag.py budget raise'
    rc, head, _ = git(kdir, 'show', f'HEAD:{PATHS_JSON}', timeout=30)
    try:
        old = (json.loads(head).get('_manifest', {}).get('caps') or {}).get('totalTokens') if rc == 0 else None
    except ValueError:
        old = None
    if isinstance(old, int) and cap > old and cap != cap_next(old):
        return f'totalTokens {old} -> {cap} skips steps: one kitbag.py budget raise per commit ({old} -> {cap_next(old)})'
    return None

def size_tokens(kdir, f):   # git blob size (LF: a CRLF checkout must not count more)
    t = read(os.path.join(kdir, f))
    if f == 'README.md':   # generated graph blocks excluded, like ports
        t = re.sub(r'<!-- kit-graph:start .*?<!-- kit-graph:end -->', '', t, flags=re.S)
    return len(t.encode('utf-8')) // 4

def counted_files(kdir):
    """Tracked files the budget counts: all but the generated ports (a deletion not staged yet is gone)."""
    rc, o, _ = git(kdir, 'ls-files')
    return [x for x in o.split('\n') if x and not x.startswith(GENERATED) and osp.isfile(osp.join(kdir, x))] if rc == 0 else []

def split_total(sizes):
    """(kit total, tests total) of {file: tokens}: the kit total is what agents load; tests/ never is (own cap testTokens)."""
    tests = sum(n for f, n in sizes.items() if f.startswith('tests/'))
    return sum(sizes.values()) - tests, tests
# token budgets (UTF-8 bytes / 4), README "Extending"
BUDGETS = {'always': 3500, 'skill': 3200, 'agent': 2400, 'rule': 900, 'template': 2600, 'templates': 4000, 'doc': 7000, 'lessons': 30000,
  'workflow': 15000, 'ps1': 58000, 'py': 77000, 'mjs': 8000, 'json': 7000, 'tests': 8000}
# files allowed raw runtime paths (lint RUNTIME-RAW)
PATHS_JSON = 'skills/crafty/kit.example.json'   # its _paths section
PATH_HELPERS = {PATHS_JSON, 'skills/crafty/lib.ps1', 'skills/crafty/devtools.py', 'skills/pokey/browser.mjs', 'skills/bossy/kitbag.py'}
TEXT_EXT = ('.md', '.ps1', '.psm1', '.py', '.js', '.mjs', '.json', '.html', '.txt', '.sh', '.yml', '.yaml', '.ini')
JUNK_EXT = ('.apk', '.aab', '.log', '.zip', '.tmp')
RESERVED = {'nul', 'con', 'prn', 'aux'}
BLOCKS = ('Load when', 'Not when', 'Hands off to', 'Files')
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
    # local-only plugins: not kit files (a path the core tracks stays one: a goody folded into the core before sync swapped it)
    goodies = {f for files in installed_extras(k.dir).values() for f in files} - set(tracked(k.dir))
    for d, dirs, fs in os.walk(k.dir):
        top = osp.relpath(d, k.dir) == '.'
        skip = SKIP_DIRS if top else SKIP_DIRS - {'.runtime', '.state', '.claude-runtime', 'worktrees', 'memory'}   # runtime, harness worktrees, memory: kit root only
        dirs[:] = [x for x in dirs if x not in skip]
        for f in fs:
            rel = osp.relpath(osp.join(d, f), k.dir).replace('\\', '/')
            if rel.split('/')[0] in REPO_ONLY:
                repo_files.append(rel)
            elif rel == '.git' or rel in goodies:   # a worktree's .git file
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
    # kit = published files + local overlay (local skills, project profiles); not configs/state; not shims
    k.files = sorted(f for f in k.all if (not ignored(f) or f in k.local_rules))
    k.fileset = set(k.files)
    try:
        lj = osp.join(k.dir, 'skills', 'crafty', 'kit.local.json')
        if not osp.isfile(lj):
            lj = osp.join(main_clone(k.dir), 'skills', 'crafty', 'kit.local.json')
        cfg = json.loads(read(lj) or '{}')
        k.local_only = [p.replace('\\', '/').rstrip('/') for p in cfg.get('localOnly', [])]
    except ValueError:
        k.local_only = []
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
    for s, entries in k.index.items():   # Files index = explicit path into a skill's files (globs cover overlay files)
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
            if not hit:   # a bare file name: the one file of that name, or the one in the same skill
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
    for f, n in nodes.items():
        n['reach'] = 'entry' if f in entries else 'structural' if f in structural else 'mention-only' if f in anyhow else 'none'
    return {'nodes': nodes, 'edges': edges}

# ---- lint: the checks (problem codes: kit-admin.md, goody kit-admin)
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
    known = known_extras(k.dir)   # None: the goodies branch was never fetched (CI): names are not checked
    rows = table_rows(router)
    if not rows:
        bad('ROUTER-MISSING', 'CLAUDE.md', 'the Router section has no table rows')
    for cells in rows + table_rows(k.org_rows):
        if len(cells) < 3:
            bad('ROUTER-TARGET', 'router', f'row needs # | conditions | target: {" | ".join(cells)[:60]}')
            continue
        found = {t for t in targets if re.search(r'`' + re.escape(t) + r'[`\s]', cells[2])}
        # a skill a goody brings (installed or not: never a kit file) is a target too: "`<skill>` skill (goody `<goody>`)"
        if len(found) + (1 if re.search(r'\bdirect\b|org row|`[\w-]+` skill \(goody `[\w-]+`\)', cells[2], re.I) else 0) != 1:
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
            # absolute path = tool outside the kit: check it on disk
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
        # a line that names its goody (goody `<name>`) may cite that goody's files: they are never kit files
        lines = [x for x in k.texts.get(f, '').split('\n') if not EXTRA_NOTE.search(x)]
        for x in sorted({n for n in EXTRA_NOTE.findall(k.texts.get(f, '')) if known is not None and n not in known}):
            bad('REF-DANGLING', f, f'goody `{x}`: no such goody on origin/goodies (kitbag.py goody list)')
        for tok in re.findall(r'`([^`\n]+)`', '\n'.join(lines)):
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
    # ---- file caps (ports excluded), per group
    counted = counted_files(k.dir) or [x for x in k.files if not x.startswith(GENERATED)]
    plumbing = [x for x in counted if x.startswith(PLUMBING)]
    content = [x for x in counted if x not in plumbing and not x.startswith('tests/')]   # tests: one file per area, bounded by the tests budget
    caps = manifest(k.dir).get('caps') or {}
    if not all(isinstance(caps.get(x), int) for x in ('content', 'plumbing', 'totalTokens', 'testTokens')):
        bad('MANIFEST', PATHS_JSON, '_manifest.caps needs integer content, plumbing, totalTokens and testTokens')
        caps = {'content': 30, 'plumbing': 8, 'totalTokens': CAP_BASE, 'testTokens': TEST_CAP, **caps}
    cap_c, cap_p = caps['content'], caps['plumbing']
    if len(content) > cap_c:
        bad('FILE-CAP', 'kit', f'{len(content)} content files (cap {cap_c}: docs, agents, workflows, skills, scripts, config examples; '
         'ports excluded): merge files (kit-admin.md "Hard rules", goody kit-admin)')
    if len(plumbing) > cap_p:
        bad('PLUMBING-CAP', 'kit', f'{len(plumbing)} plumbing files (cap {cap_p}: LICENSE, .gitignore, .gitattributes, .githooks/*, '
         f'.github/*, settings.json): {", ".join(plumbing)}')
    # ---- token budgets: per file type, total
    cap_bad = cap_problem(k.dir, caps['totalTokens'])
    if cap_bad:
        bad('BUDGET-CAP', PATHS_JSON, cap_bad)
    def btype(f):
        b = osp.basename(f)
        if f in ('CLAUDE.md', 'AGENTS.md'):
            return None   # always-loaded: the 'always' cap
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
        if f.endswith('.md'):
            return 'template'
        ext = osp.splitext(f)[1][1:]
        return ext if ext in BUDGETS else None
    sizes = {f: size_tokens(k.dir, f) for f in counted}
    over = [(f, n, BUDGETS[b]) for f, n in sizes.items() if (b := btype(f)) and n > BUDGETS[b]]
    always = sum(sizes.get(f, 0) for f in ('CLAUDE.md', 'AGENTS.md') + tuple(f for f in counted if re.match(r'rules/[^/]+\.md$', f) and 'paths' not in frontmatter(k.texts.get(f, ''))))
    if always > BUDGETS['always']:
        over.append(('always-loaded (CLAUDE.md + AGENTS.md + rules)', always, BUDGETS['always']))
    total, tests = split_total(sizes)
    cap_t = caps['totalTokens']
    if total > cap_t:
        over.append(('kit total', total, cap_t))
    if tests > caps['testTokens']:
        bad('BUDGET-TESTS', 'tests', f"{tests} tokens (cap {caps['testTokens']}): merge duplicate cases, share setup in tests/harness.ps1")
    if over:
        top = ', '.join(f'{f} {n}' for f, n in sorted(sizes.items(), key=lambda x: -x[1])[:5])
        for f, n, cap in over:
            fix = TRIM_FIRST if f == 'kit total' else 'trim it (dense prose, dedupe) or move text to a file with room'
            bad('BUDGET', f, f'{n} tokens (cap {cap}): {fix}; top consumers: {top}')
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
            bad('SCRIPT-HEADER', f, 'no header block with usage and "Exit codes:" in the first 40 lines (kit-admin.md "Script header", goody kit-admin)')
    # ---- section maps: the "Sections:" line vs the markers; every function and verb in a section
    extra_of = {p: n for n, ps in installed_extras(k.dir).items() for p in ps if p not in counted}   # installed goodies' files too
    # Windows PowerShell 5 misreads UTF-8 without a BOM and pwsh 7 syntax: the line makes it stop with a clear message
    for f in [x for x in list(counted) + sorted(extra_of) if x.endswith('.ps1') and not x.startswith(GENERATED)]:
        if not re.search(r'^#requires\s+-version\s+7', read(osp.join(k.dir, f)), re.I | re.M):
            bad('PS-VERSION', f, 'no "#Requires -Version 7" line (Windows PowerShell 5 cannot run kit scripts)' + (f' (goody {extra_of[f]}: fix it on the goodies branch)' if f in extra_of else ''))
    for f in sec_files(list(counted) + sorted(extra_of)):
        for c, w, m in sec_check(f, read(osp.join(k.dir, f)))[0]:
            bad(c, w, m + (f' (goody {extra_of[f]}: fix it on the goodies branch)' if f in extra_of else ''))
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
                bad('DESKTOP-OPEN', f'{f}:{i + 1}', 'opens a file, browser or app on the desktop without an explicit --open / -Open flag (kit-admin.md "Shapes", goody kit-admin)')
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
            bad('LESSONS-CAP', f'LESSONS.md ## {m.group(1)}', f'{n} lessons (cap 40): bossy.ps1 learn -Skill {m.group(1)} -Trim')
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
    # ---- log lines only through kitlog (Write-KitLog / kitlog): an append to a .log / .jsonl / *-log / signals target
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
    # ---- PS-CASE on the .ps1 files changed vs origin/main (audit scan: every file, as a WARN)
    rc, o, _ = git(k.dir, 'diff', '--name-only', 'origin/main', '--')
    for f in (o.splitlines() if rc == 0 else []):
        if f.endswith('.ps1') and osp.isfile(osp.join(k.dir, f)):
            for lb, b, a, la in ps_case(k.texts.get(f) or read(osp.join(k.dir, f))):
                bad('PS-CASE', f'{f}:{lb}', f'${b} is the same variable as ${a} (line {la}) in this function: rename one')
    # ---- org terms (published files + README/docs/examples)
    if org_terms:
        scan = [(f, k.texts.get(f) or read(osp.join(k.dir, f))) for f in k.files if not is_overlay(k, f)]
        scan += [(f, read(osp.join(k.dir, f))) for f in k.repo_files if f.split('/')[0] != 'LICENSE']
        # whole words; capitalised = case-sensitive; trailing * = prefix
        pats = [(t.strip(), re.compile(r'(?<![\w-])' + re.escape(t.strip().rstrip('*')) + ('' if t.strip().endswith('*') else r'(?![\w-])'),
               0 if t.strip() != t.strip().lower() else re.I))
          for t in org_terms if t.strip()]
        for where, text in scan:
            for t, rx in pats:
                if rx.search(text):
                    bad('ORG-TERM', where, f'contains org term "{t}"')
    return probs

# ---- README graph: Mermaid and tables; pre-commit keeps them current
def readme_sections(k, g):
    """The README's generated sections: the map (root -> router -> skills / workflows / agents), tables, one per skill."""
    nodes, edges = g['nodes'], g['edges']
    label = lambda f: skill_of(f) if nodes[f]['kind'] == 'skill' else osp.basename(f).rsplit('.', 1)[0]
    nid = lambda f: re.sub(r'[^A-Za-z0-9]', '_', f)
    cut = lambda s, n: s if len(s) <= n else s[:n].rsplit(' ', 1)[0] + '…'   # at a word
    # Mermaid text: always quoted (unquoted ( ) ; : parse as shape tokens); entity-escape what ends or opens a token
    mq = lambda s: '"' + re.sub(r'["#<>`|]', lambda m: {'"': '#quot;', '#': '#35;', '<': '#lt;', '>': '#gt;', '`': '#96;', '|': '#124;'}[m.group(0)], re.sub(r'\s+', ' ', str(s)).strip()) + '"'
    out = {}
    lines = ['flowchart LR', f'  CLAUDE_md[{mq("CLAUDE.md")}] -->|{mq("import")}| AGENTS_md[{mq("AGENTS.md Router")}]']
    # the README is published: local-overlay parts (localOnly, *.local.*) never appear
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
    out['table-adapters'] = ['| Kind | Selected by | Interface (verbs) | Built in | Code |', '|---|---|---|---|---|'] + [
     f"| {n} | `{a.get('config', '')}` | {a.get('verbs', '')} | {', '.join(a.get('names', '').split())} | `{a.get('file', '')}` |" for n, a in (man.get('adapters') or {}).items() if isinstance(a, dict)]
    bd = ((json.loads(read(osp.join(k.dir, PATHS_JSON)) or '{}').get('budget') or {}).get('defaults') or {})   # the budget rule's per-tool defaults
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
    out['table-caps'] = [' · '.join(f'{n} {v}' for n, v in BUDGETS.items()) + f" · total {caps.get('totalTokens')} · all tests {caps.get('testTokens')} · files: {caps.get('content')} content + {caps.get('plumbing')} plumbing"]
    ma, mw = man.get('agents') or {}, man.get('workflows') or {}   # crew hero: who starts whom
    out['crew'] = ['flowchart LR', f'  OW([{mq("owner")}]) -->|{mq("asks, says deploy env")}| CO[{mq("coordinator: Router + Events")}]'] + [
     x for w, m in mw.items() for x in [f"  CO -->|{mq(m.get('router', ''))}| W_{w}[/{mq(w)}/]"] + [f'  W_{w} -->|{mq("spawns")}| A_{c}({mq(c)})' for c in m.get('crew', [])]] + [
     f"  CO -->|{mq(', '.join(u for u in m.get('usedIn', []) if u.startswith('R')))}| A_{a}({mq(a)})" for a, m in ma.items() if any(u.startswith('R') for u in m.get('usedIn', []))]
    rr = [r for r in table_rows(k.texts.get('AGENTS.md', '')) if len(r) > 2 and re.match(r'R\d+$', r[0])]   # Router: first match wins
    sh = lambda s, n: cut(re.sub(r'\s+([,.])', r'\1', re.sub(r'\s+', ' ', re.sub(r'[`"\[\]{}()<>|#;]', '', re.sub(r'\([^)]*\)', '', s)))).strip(), n)
    out['router'] = ['flowchart TD', f'  Q([{mq("request")}]) --> R0'] + [
     x for i, r in enumerate(rr) for x in [f'  {r[0]}{{{mq(r[0] + ": " + sh(r[1], 40))}}} -->|{mq("yes")}| T{i}[{mq(sh(r[2], 32))}]'] + ([f'  {r[0]} -->|{mq("no")}| {rr[i + 1][0]}'] if i + 1 < len(rr) else [])]
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
    # drop sections no part produces any more, with the blank line before
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
    """flow --readme [<kit>]; any other flow call draws the page, which the flow-map goody provides."""
    if '--readme' not in a:
        return need_extra('the kit-flow page (kitbag.py flow)', 'flow-map')
    flags, rest = parse_opts(a)
    write_readme(osp.abspath(rest[0] if rest else KIT_DIR))
    return 0

# ---- lint command: print, --json, exit code
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
    for hook in LINT_HOOKS:   # installed goodies (flow-map: FLOW-* issues)
        hook(k, problems, flags)
    if '--json' in flags:
        with open(flags['--json'], 'w', encoding='utf-8') as fh:
            json.dump([{'code': c, 'where': w, 'problem': m} for c, w, m in problems], fh, indent=1)
    if '--summary' in flags:
        if problems:
            c, w, m = problems[0]
            print(f'kitbag lint: {len(problems)} problem(s), e.g. {c} {w}: {m} (list: python {osp.abspath(__file__)} lint)')
    else:
        for c, w, m in problems:
            print(f'{c:15} {w}: {m}')
        print(f'kitbag lint: {len(problems)} problem(s) in {kit} ({len(k.files)} files, {len(k.skills)} skills, '
         f'{len(k.workflows)} workflows, {len(k.agents)} agents)')
    return 1 if problems and '--warn' not in flags else 0

# ---- audit: findings, shared helpers, stamp (scan: consistency and pitfall candidates, goody kit-admin)
# user-named subtrees (or samples): never "missing"
USER_MAPS = ('localEnv', 'repos', 'repoAliases', 'targets', 'linkFromByTarget', 'tracker.statuses', 'tracker._examples',
  'gate.startHeapGB', 'lanes', 'app', 'localFiles', 'deploy.minIntervalHours', 'tests', 'qa.targets')
AUTOMATIC = {'input', 'args', 'matches', 'error', 'host', 'home', 'pid', 'pwd', 'profile', 'this', 'event', 'sender', 'ofs',
   'psitem', 'iswindows', 'islinux', 'ismacos', 'executioncontext', 'myinvocation', 'psboundparameters', 'lastexitcode'}
AUDIT_VERBS = {'stamp': lambda kit, flags: cmd_stamp(kit)}   # goody kit-admin adds setup, config, recover, scan
findings = []

def out(level, code, where, what, fix=''):
    findings.append({'level': level, 'code': code, 'where': where, 'what': what, 'fix': fix})

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

def tracked(kit):
    rc, o, _ = git(kit, 'ls-files')
    return o.splitlines() if rc == 0 else []

def strip_ps_comments(text):
    text = re.sub(r'<#.*?#>', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return '\n'.join(re.sub(r'(^|\s)#(?![>{]).*$', r'\1', l) if not re.search(r"""['"][^'"]*#""", l) else l for l in text.split('\n'))

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
    now = datetime.datetime.now().isoformat(timespec='seconds')
    with open(p, 'w', encoding='utf-8') as f:
        f.write(now + '\n')
    out('FIX', 'AUDIT-STAMP', p, f'last kit audit = {now} (the SessionStart nudge resets)')

def audit_main(a):
    verb = a[0]
    flags, _ = parse_opts(a[1:], {'--kit', '--json'})
    # scan: the kit this file lives in (the worktree being changed); the other verbs: the live clone
    kit = osp.abspath(flags.get('--kit') or (KIT_DIR if verb == 'scan' else main_clone(KIT_DIR)))
    stamp_fn(AUDIT_VERBS[verb])
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

# ---- registry: _manifest registers every crew part and cap, lint checks the files against it; front matter
# validates against a small JSON Schema subset
TODO = 'TODO(new)'   # a stub kitbag.py new (goody kit-admin) leaves; lint TODO-STUB refuses it
SCHEMAS = {
 'skill': {'type': 'object', 'required': ['name', 'description'], 'additionalProperties': False,
   'properties': {'name': {'type': 'string', 'pattern': r'^[a-z][a-z0-9-]*$'},
       'description': {'type': 'string', 'pattern': r'^Load when: .+ Not when: .+->', 'maxLength': 450},
       'argument-hint': {'type': 'string'}}},
 'agent': {'type': 'object', 'required': ['name', 'description'], 'additionalProperties': False,
   'properties': {'name': {'type': 'string', 'pattern': r'^[a-z][a-z0-9-]*$'},
       'description': {'type': 'string', 'pattern': r'Spawned by .+Not for'},
       'tools': {'type': 'string', 'minLength': 3}, 'model': {'type': 'string', 'enum': ['sonnet', 'opus', 'haiku', 'inherit']}}},
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

def manifest(kit=None):
    try:
        return json.loads(read(osp.join(kit or KIT_DIR, PATHS_JSON)) or '{}').get('_manifest') or {}
    except ValueError:
        return {}

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
    # bare, file or joined name (last-<old>, <old>s, <old>-x); <name>.stamp sharing the stem is no reference
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

def adapter_blocks(text, kind):
    """{name: code} of each `adapter:<kind>/<name>` block (to the next adapter / adapter-end marker)."""
    out = {}
    for m in re.finditer(r'adapter:' + re.escape(kind) + r'/([\w-]+)', text):
        nx = re.compile(r'adapter(?:-end)?:[\w-]+').search(text, m.end())
        out[m.group(1)] = out.get(m.group(1), '') + text[m.end():nx.start() if nx else len(text)]
    return out


def adapter_lint(k, man, bad):
    """ADAPTER: each core name has every verb of its kind ('*' = all); a configured name that is no core adapter is a goody
    (`goody check` reports it)."""
    for kind, a in (man.get('adapters') or {}).items():
        if not isinstance(a, dict):
            continue
        names, blocks, f = a['names'].split(), adapter_blocks(k.texts.get(a['file'], ''), kind), a['file']
        if a.get('table'):   # a data table (one entry per name) instead of adapter blocks
            m = re.search(r'(?ms)^(?:\$script:)?' + re.escape(a['table']) + r' = @?\{\s*\n(.*?)^\}', k.texts.get(f, ''))
            rows = {}
            body = (m.group(1) if m else '').split('\n')
            ind = min((len(x) - len(x.lstrip(' ')) for x in body if x.strip()), default=1)
            for ln in body:   # a row starts at the table's first indent, continuation lines are deeper
                r = re.match(r"^ {%d}'?([\w-]+)'?\s*[:=]\s*@?\{" % ind, ln)
                if r:
                    cur_n = r.group(1); rows[cur_n] = ''
                if rows:
                    rows[cur_n] += ln + '\n'
            blocks = rows
            if set(rows) - set(names):
                bad('ADAPTER', f, f'{kind}: {a["table"]} entries {sorted(set(rows) - set(names))} not in _manifest.adapters.{kind}.names')
        for n in names:
            b = blocks.get(n)
            miss = [] if b is None or "'*'" in b else [v for v in a['verbs'].split() if not re.search(rf"""['"]{re.escape(v)}['"]|\b{re.escape(v)}\s*=(?!=)""", b)]
            if b is None or miss:
                bad('ADAPTER', f, f'{kind}/{n}: {miss or "no block"} (a core adapter needs every verb)')


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
        tools = fm.get('tools') or 'all'
        if tools != m.get('tools'):
            bad('MANIFEST', p, f'tools "{tools}" differ from _manifest.agents.{a}.tools "{m.get("tools")}"')
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
    pats = [(o, old_name_rx(o)) for o in olds]
    for f in k.files:
        if '.local.' in f or any(f == x or f.startswith(x + '/') for x in k.local_only):
            continue
        t = k.texts.get(f) or ''
        if f == PATHS_JSON:
            t = re.sub(r'"(renamed|moved)":\s*\{[^}]*\}', '', t)   # the migration notes themselves
        for o, rx in pats:
            m = rx.search(t)
            if m:
                bad('OLD-NAME', f'{f}:{t.count(chr(10), 0, m.start()) + 1}', f'old name "{o}" (now "{olds[o]}"): no aliases, update the reference')
        if TODO in t and f != 'skills/bossy/kitbag.py':   # the templates live here
            bad('TODO-STUB', f'{f}:{t.count(chr(10), 0, t.index(TODO)) + 1}', f'{TODO} stub left: fill it in')
        ln = lambda m: f'{f}:{t.count(chr(10), 0, m.start()) + 1}'
        for m in re.finditer(r'business[- ]logic change', t, re.I):   # the rule is what a user sees, not where the code sits
            if 'decide ask' in t[m.start():m.start() + 300] and 'user-visible' not in t[max(0, m.start() - 150):m.start() + 300]:
                bad('DECISION-WORDING', ln(m), 'a decision pause is a user-visible behaviour change (AGENTS.md "Decision pauses"), not a "business-logic change"')
        m = re.search(r'(?<!no )\b(?:Explore|Plan|general-purpose) agents?\b', t) if f.startswith(('agents/', 'workflows/')) or f.endswith('SKILL.md') else None
        if m:
            bad('NON-CREW', ln(m), f'"{m.group(0)}": only crew agents ({", ".join(sorted(crew))}) are spawned')

def _sub_file(kit, rel, fn):   # goody kit-admin (scaffold, admin) edits kit files with it, keeping each file's line endings
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
  'expected': r'(?i)\bexpected\b', 'options': r'(?m)^\s*[-*]?\s*(?:Option\s+)?A[:)]', 'recommended': r'(?i)\brecommended\b',
  'verdict': r'\b(?:PASS|FAIL|BLOCKED|PASS_WITH_NOTE|NOT_TESTED)\b',
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

def locale_terms():   # locale.proseTerms: {expected, recommended, ...: regex} for texts not in English
    return ((load_json(osp.join(main_clone(KIT_DIR), 'skills', 'crafty', 'kit.local.json'))[0] or {}).get('locale') or {}).get('proseTerms') or {}

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
        rx = commit_rx() if r == 'conv' else (locale_terms().get(r) or REQ_RX.get(r))
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
            if k_ in ('note', 'notes', 'finding', 'observed', 'what_was_done') and isinstance(v, str):
                yield v
            else:
                yield from result_notes(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from result_notes(v)

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
        for n in result_notes(json.loads(text)):
            found += [f'note "{n[:50]}": {f}' for f in prose_check(kind, n, kinds[kind], banned)]
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
SEC_EXTRA = re.compile(r'Assert-KitExtra|Get-Command|extra_missing|need_extra')   # a verb an installed goody handles

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
        ents = [x.strip() for x in re.split(r'·|\s(?=L\d+ )', body) if x.strip()]
        return i, j, pre, [(int(e.group(1)), e.group(2)) if (e := re.match(r'L(\d+) (.+)$', x)) else (0, x) for x in ents]
    return None

def sec_render(pre, ents):
    out = [pre + 'Sections:']
    for n, (ln, name) in enumerate(ents):
        item = f'L{ln} {name}' + (' ·' if n + 1 < len(ents) else '')
        if len(out[-1]) + 1 + len(item) > SEC_WIDTH and out[-1] != out[0][:len(pre) + 9]:
            out.append(pre + '  ' + item)
        else:
            out[-1] += ' ' + item
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
    lines = [x.rstrip('\r') for x in text.split('\n')]   # mixed endings: read like lint, written back with the file's main one
    mp = sec_parse(lines) if cm else None
    if not cm or (not mp and len(text.encode('utf-8')) < SEC_MIN):
        return [], None
    marks = sec_marks(lines, cm)
    if not marks:
        return [('SECTION-MAP', f, f'no section markers: a `{cm} ---- <name>: <what>` line opens each part (README "Extending")')], None
    if not mp:
        return [('SECTION-MAP', f, 'no "Sections:" line in the first 40 lines: add one to the header, then kitbag.py sections --fix')], None
    i, j, pre, have = mp
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
        want = sec_render(pre, [(ln + rows - n if ln > j + 1 else ln, nm) for ln, nm in marks])
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
        if not SEC_EXTRA.search(body) and not any(re.search(r'(?<![\w-])' + re.escape(fn) + r'(?![\w-])', body) for fn in fns):
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

# ---- budget: the kit total vs its cap
def cmd_budget(a):
    """kitbag.py budget [show]: the kit total (agent-loaded files) vs _manifest.caps.totalTokens, tests/ vs caps.testTokens.
    budget raise -Reason "<why trimming cannot make room>" (x1.1 per step, only while over the cap) is in the kit-admin goody."""
    kit = KIT_DIR
    flags, rest = parse_opts(a, {'-Reason', '-reason', '--reason'})
    total, tests = split_total({f: size_tokens(kit, f) for f in counted_files(kit)})
    caps = manifest(kit).get('caps') or {}
    cap, cap_t = caps.get('totalTokens', CAP_BASE), caps.get('testTokens', TEST_CAP)
    if not rest or rest[0] == 'show':
        print(f'kit total {total} of cap {cap} ({total * 100 // cap}%) · tests {tests} of cap {cap_t}; next raise step {cap_next(cap)}')
        return 0
    if rest[0] == 'raise':
        raise_cap = PLUGINS.get('budget raise')
        return (stamp_fn(raise_cap) or raise_cap(kit, total, cap, flags)) if raise_cap else need_extra('kitbag.py budget raise', 'kit-admin')
    print(cmd_budget.__doc__, file=sys.stderr)
    return 2

# ---- goodies: optional parts on the origin's `goodies` branch, installed local-only (README "Goodies")
# goodies/<name>/GOODY.md says what it is and "Needed when: `<config key>` = `<value>`"; goodies/<name>/files/<kit path> are its files.
EXTRAS_REF = 'refs/remotes/origin/goodies'
EXCLUDE_MARK = '# kitbag goody '
OS_NAME = {'win32': 'windows', 'darwin': 'macos'}.get(sys.platform, 'linux')   # `<os>` OS in a Needed when line
EXTRA_NOTE = re.compile(r'\bgoody `([\w-]+)`')   # core text citing a goody's part names it: lint skips that line's paths
EXTRA_OF = {'flow': 'flow-map', 'port': 'ports', 'new': 'kit-admin', 'rename': 'kit-admin', 'remove': 'kit-admin', 'cost': 'kit-admin',
  'release': 'kit-admin', 'audit scan': 'kit-admin', 'audit setup': 'kit-admin', 'audit config': 'kit-admin', 'audit recover': 'kit-admin'}
PLUGINS = {}      # command -> handler, from installed kitbag goodies (skills/bossy/kitbag_<name>.py)
LINT_HOOKS = []   # (kit, problems, flags) -> None: adds problems
# goodies merged into another (old -> new) or folded into the core / retired (None): sync swaps the installed and listed old ones
MERGED_EXTRAS = {'annotate': 'android-swarm', 'emulator-windows': 'android-swarm', 'app-kinds': 'android-swarm', 'deployed-checks': 'deploys',
  'deploy-merge': 'deploys', 'container-tests': 'runtimes', 'qa-html-report': 'report-gdocs', 'board-disputes': 'duel', 'scaffold': 'kit-admin',
  'tracker-gitlab': 'gitlab', 'supervise-resources': None, 'posix': None, 'migration-classify': None}

def known_extras(kit):
    """Names of the goodies on the fetched goodies branch; None when it was never fetched."""
    rc, o, _ = git(kit, 'ls-tree', '-d', '--name-only', EXTRAS_REF, 'goodies/')
    return {x.split('/')[-1] for x in o.split('\n') if x} if rc == 0 else None

def need_extra(feature, name):
    print(f'{feature} is a goody: run kitbag.py goody add {name}', file=sys.stderr)
    return 2

def exclude_path(kit):
    rc, p, _ = git(kit, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude', timeout=20)
    return p if rc == 0 and p else None

def exclude_blocks(kit):
    """{name: [kit paths]} of every `# kitbag goody <name>` ... `# kitbag goody end` block in .git/info/exclude (shared by
    every worktree of the clone); a block also ends at a blank line or the next block."""
    p = exclude_path(kit)
    blocks, name = {}, None
    for line in (read(p) if p else '').split('\n'):
        if line.startswith(EXCLUDE_MARK):
            name = line[len(EXCLUDE_MARK):].strip()
            name = None if name == 'end' else name
            if name:
                blocks[name] = []
        elif name and line.strip():
            blocks[name].append(line.strip().lstrip('/'))
        else:
            name = None
    return blocks

def installed_extras(kit):
    """{name: [kit paths]} of the goodies whose files are in this kit."""
    return {n: paths for n, paths in exclude_blocks(kit).items() if paths and all(osp.isfile(osp.join(kit, x)) for x in paths)}

def set_exclude(kit, name, paths):
    """Replace the goody's block in .git/info/exclude (paths None: drop it); every other line stays."""
    p = exclude_path(kit)
    lines, inside = [], False
    for line in read(p).split('\n') if p and osp.isfile(p) else []:
        if inside and (line.startswith(EXCLUDE_MARK) or not line.strip()):
            inside = False
            if line == f'{EXCLUDE_MARK}end':
                continue
        if line == f'{EXCLUDE_MARK}{name}':
            inside = True
        if not inside:
            lines.append(line)
    text = '\n'.join(lines).rstrip('\n') + '\n'
    if paths:
        text += f'{EXCLUDE_MARK}{name}\n' + ''.join(f'/{x}\n' for x in paths) + f'{EXCLUDE_MARK}end\n'
    os.makedirs(osp.dirname(p), exist_ok=True)
    with open(p + '.tmp', 'w', encoding='utf-8', newline='\n') as fh:   # replaced whole: a concurrent reader never sees half a file
        fh.write(text)
    os.replace(p + '.tmp', p)

def worktrees(kit):
    return [x[len('worktree '):] for x in git(kit, 'worktree', 'list', '--porcelain')[1].split('\n') if x.startswith('worktree ')]

def extra_files(kit, name):
    """[(path on the goodies branch, kit path)] of one goody."""
    prefix = f'goodies/{name}/files/'
    rc, o, _ = git(kit, 'ls-tree', '-r', '--name-only', EXTRAS_REF, '--', prefix)
    return [(x, x[len(prefix):]) for x in o.split('\n') if x.startswith(prefix) and '__pycache__/' not in x] if rc == 0 else []

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

def listed_goodies(cfg):
    return cfg.get('goodies') or []

def set_listed(kit, name, on):
    """kit.local.json `goodies`: names sync always installs (a fresh clone gets them back); goody add lists, remove unlists.
    Only this kit's own file: an add in a worktree never edits the live clone's config."""
    p = osp.join(kit, 'skills', 'crafty', 'kit.local.json')
    if not osp.isfile(p):
        return
    with locked(p):
        cfg = load_json(p)[0]
        names = list(listed_goodies(cfg)) if isinstance(cfg, dict) else None
        if names is None or (name in names) == on:
            return
        cfg['goodies'] = sorted(set(names) | {name}) if on else [x for x in names if x != name]
        indent = len(re.search(r'\n( *)"', read(p)).group(1)) if re.search(r'\n( *)"', read(p)) else 2
        with open(p + '.tmp', 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(json.dumps(cfg, indent=indent, ensure_ascii=False) + '\n')
        os.replace(p + '.tmp', p)

def extras_needed(kit, every=False):
    """[(name, feature)]: goodies this install asks for that are not installed: kit.local.json `goodies`, and GOODY.md "Needed when[ (<file>, ...)]:" lines:
    `<key>` = `<value>` [| `<value>`] (the file's config, default kit.local.json; value `*` = the key is set; `~` instead of `=`:
    the value contains it), `<path>` exists (a kit file, the kit's own need), `<glob>` in a repo (a repos[].checkout tracks
    such a file), `<os>` OS (windows, linux, macos) or origin ~ `<text>` (the kit's or a repo's origin URL); prose-only lines never install. every: installed ones too."""
    have = set() if every else set(installed_extras(kit))
    rc, o, _ = git(kit, 'grep', '-n', '--full-name', '-e', '^Needed when', EXTRAS_REF, '--', 'goodies/')
    need, configs = [], {'kit.local.json': local_config(kit, 'kit.local.json')}
    listed = listed_goodies(configs['kit.local.json'])
    need += [(x, 'kit.local.json goodies') for x in listed if isinstance(x, str) and x not in have and extra_files(kit, x)]
    for line in o.split('\n') if rc == 0 else []:
        m = re.match(r'^[^:]+:goodies/([\w-]+)/GOODY\.md:\d+:Needed when(?: \(([\w.-]+\.json)[^)]*\))?:(.*)$', line)
        if not m or m.group(1) in have:
            continue
        name, fname, rule = m.group(1), m.group(2) or 'kit.local.json', m.group(3)
        cfg = configs.setdefault(fname, local_config(kit, fname))
        for key, op, wants in re.findall(r'`([\w.*-]+)`\s*(=|is|~)\s*((?:`[^`]+`\s*\|?\s*)+)', rule):
            wants = re.findall(r'`([^`]+)`', wants)
            values = [str(v).lower() for v in config_values(cfg, key) if v not in (None, '', [], {})]
            match = (lambda w: any(w.lower() in v for v in values)) if op == '~' else (lambda w: w.lower() in values)   # ~ = contains
            hit = next((w for w in wants if (w == '*' and values) or match(w)), None)
            if hit:
                need.append((name, f'{key} "{hit}"'))
        need += [(name, f'{p} exists') for p in re.findall(r'`([^`\s]+)`\s+exists', rule)   # a worktree: the main clone answers
                 if any(osp.exists(osp.join(base, p)) for base in (kit, main_clone(kit)))]
        need += [(name, f'{p} in a repo') for p in re.findall(r'`([^`\s]+)`\s+in a repo', rule) if repo_tracks(configs['kit.local.json'], p)]
        need += [(name, f'{x} OS') for x in re.findall(r'`(\w+)`\s+OS\b', rule) if x == OS_NAME]
        need += [(name, f'origin ~ {x}') for x in re.findall(r'(?<![`\w])origin\s*~\s*`([^`]+)`', rule) if any(x.lower() in u for u in origins(kit, configs['kit.local.json']))]
    hx = host_extra(kit, configs['kit.local.json'])   # an unrecognised self-hosted origin still needs the gitlab adapter
    need += [(hx, "the repos' git host")] if hx and hx not in have and extra_files(kit, hx) else []
    return sorted(set(need))

ORIGINS = []   # the kit's and the configured repos' origin URLs, lowercase: read once per run

HOST_RE = re.compile(r'^(?:\w+://)?(?:[^@/]+@)?(?:ssh\.)?([^/:]+)')   # lib.ps1 reads the origin host the same way

def origins(kit, cfg):
    """The origin hosts of the kit and the configured repos (the host only: a path that names another host never matches)."""
    if not ORIGINS:
        dirs = [kit] + [c for c in config_values(cfg, 'repos.*.checkout') if isinstance(c, str) and osp.isdir(c)]
        urls = [git(d, 'remote', 'get-url', 'origin', timeout=20)[1].lower() for d in dirs]
        ORIGINS.extend(m.group(1) if m else '' for m in (HOST_RE.match(u) for u in urls))   # one per dir, the kit first
    return ORIGINS

HOST_EXTRA = (('github', 'github'), ('bitbucket', 'bitbucket'), ('dev.azure.com', 'azure-devops'), ('visualstudio.com', 'azure-devops'),
  ('gitea', 'gitea'), ('forgejo', 'gitea'), ('codeberg', 'gitea'))   # lib.ps1 Get-HostKind; any other host = gitlab

def host_extra(kit, cfg):
    """The git-host goody of the product repos when config leaves the type to the host (lib.ps1: unknown host = gitlab); None without repos."""
    if cfg.get('gitHostType') or not config_values(cfg, 'repos.*.checkout'):
        return None
    host = str(cfg.get('gitHost') or next(iter(origins(kit, cfg)[1:]), '')).lower()
    return next((x for h, x in HOST_EXTRA if h in host), 'gitlab') if host else None

REPO_FILES = {}   # checkout -> its tracked paths: one git ls-files per repo and run, however many globs ask

def repo_tracks(cfg, pattern):
    """A configured repo (kit.local.json repos[].checkout) tracks a file named like the glob, at any depth."""
    for c in config_values(cfg, 'repos.*.checkout'):
        if isinstance(c, str) and c not in REPO_FILES:
            REPO_FILES[c] = git(c, 'ls-files', timeout=30)[1].split('\n') if osp.isdir(c) else []
        if isinstance(c, str) and any(fnmatch.fnmatch(f, pattern) or fnmatch.fnmatch(f, '*/' + pattern) for f in REPO_FILES[c]):
            return True
    return False

def stale_extras(kit, installed):
    """Installed goodies whose files differ from the fetched goodies branch (git blob ids: bytes as stored)."""
    stale = []
    for name, paths in installed.items():
        rc, o, _ = git(kit, 'ls-tree', '-r', EXTRAS_REF, '--', f'goodies/{name}/files/')
        want = {x.split('\t')[1][len(f'goodies/{name}/files/'):]: x.split()[2] for x in o.split('\n') if '\t' in x and '__pycache__/' not in x} if rc == 0 else {}
        have = dict(zip(paths, git(kit, 'hash-object', '--no-filters', '--', *paths)[1].split('\n')))
        if want and want != have:
            stale.append(name)
    return stale

def add_extra(kit, name, installed, verb='installed'):
    """Write one goody's files from the fetched branch and register them local-only; 0 ok, 1 refused, 2 no such goody."""
    files = extra_files(kit, name)
    if not files:
        print(f'kitbag goody add: no goody "{name}" on origin/goodies (kitbag.py goody list)', file=sys.stderr)
        return 2
    # its own files (installed, or listed in its .git/info/exclude block even when a later version changed the list) are updated;
    # anything else is never overwritten
    mine, tracked_files = set(installed.get(name, [])) | set(exclude_blocks(kit).get(name, [])), set(tracked(kit))
    clash = sorted(rel for _, rel in files if rel in tracked_files or (osp.exists(osp.join(kit, rel)) and rel not in mine))
    if clash:
        print(f'kitbag goody add {name}: refused - it would overwrite {clash}', file=sys.stderr)
        return 1
    for rel in mine - {rel for _, rel in files}:   # a file the new version dropped
        if osp.isfile(osp.join(kit, rel)) and rel not in tracked_files:
            os.remove(osp.join(kit, rel))
    for src, rel in files:
        blob = subprocess.run(['git', '-C', kit, 'show', f'{EXTRAS_REF}:{src}'], capture_output=True, timeout=60).stdout   # bytes as stored
        os.makedirs(osp.dirname(osp.join(kit, rel)), exist_ok=True)
        with open(osp.join(kit, rel) + '.tmp', 'wb') as fh:   # replaced whole: a script loading it never reads half a file
            fh.write(blob)
        os.replace(osp.join(kit, rel) + '.tmp', osp.join(kit, rel))
    set_exclude(kit, name, [rel for _, rel in files])
    print(f'goody {name}: {verb} {len(files)} file(s), local-only (never pushed): {", ".join(rel for _, rel in files)}')
    return 0

def extra_sync(kit):
    """Install every goody this install needs (extras_needed); refresh installed ones the branch changed, only while the kit
    is not behind origin/main (a newer goody may need newer core: the pull comes first). Silent when nothing to do."""
    fetched = not git(kit, 'rev-parse', '-q', '--verify', EXTRAS_REF)[0]
    current = git(kit, 'merge-base', '--is-ancestor', 'origin/main', 'HEAD')[0] == 0
    if not fetched:
        print('kitbag goody sync: the goodies branch was never fetched (offline?): nothing installed', file=sys.stderr)
        return 1
    if current:
        migrate_extras(kit)
    rc, installed = 0, installed_extras(kit)
    for name in sorted({n for n, _ in extras_needed(kit)}):
        rc = max(rc, add_extra(kit, name, installed))
    if current:
        for name in stale_extras(kit, installed):
            rc = max(rc, add_extra(kit, name, installed, 'updated'))
    return rc

def migrate_extras(kit):
    """MERGED_EXTRAS gone from the goodies branch: the old files go, a listed old name is listed as the new one (sync installs it)."""
    known, blocks = known_extras(kit) or set(), exclude_blocks(kit)
    listed = listed_goodies(local_config(kit, 'kit.local.json'))
    for old, new in MERGED_EXTRAS.items():
        if old in known or (old not in blocks and old not in listed):
            continue
        if old in blocks:
            drop_extra(kit, old, blocks[old], f'merged into {new}' if new else 'now in the core')
        set_listed(kit, old, False)
        if new and (old in listed or old in blocks):   # installed by hand (unlisted) too: its new home stays installed
            set_listed(kit, new, True)

def drop_extra(kit, name, paths, why=''):
    """Delete a goody's untracked files here (and the folders it brought); its exclude block goes once no worktree has them
    untracked (a worktree behind a core fold still needs the block: an unignored file there would block its pull)."""
    tracked_files = set(tracked(kit))   # another block's files (the goody it merged into) are never this one's to delete
    mine = [x for x in paths if x not in {p for n, b in exclude_blocks(kit).items() if n != name for p in b}]
    here = [x for x in mine if x not in tracked_files and osp.isfile(osp.join(kit, x))]
    for rel in here:
        os.remove(osp.join(kit, rel))
        d = osp.dirname(osp.join(kit, rel))
        while d != kit and osp.isdir(d) and not os.listdir(d):
            os.rmdir(d)
            d = osp.dirname(d)
    loose = lambda w, x: osp.isfile(osp.join(w, x)) and git(w, 'ls-files', '--error-unmatch', '--', x)[0] != 0
    elsewhere = [w for w in worktrees(kit) if any(loose(w, x) for x in mine)]
    if not elsewhere:
        set_exclude(kit, name, None)
    elif not here and why:   # a migration another worktree still has to run: nothing to say here
        return here
    print(f'goody {name}: removed {len(here)} file(s)' + (f' ({why})' if why else '') + (f'; still installed in {", ".join(elsewhere)}' if elsewhere else ''))
    return here

PRUNE_DAYS = 30   # TODO-PARAM (fixed default): goodies.pruneDays; tidy prep passes the learned value as --days

def use_stamp(rel):
    """<state>/extras-used/<kit path, / as __>: touched once a day by the code that loads the file (lib.ps1 Add-KitExtraUse)."""
    return osp.join(kit_path('extras-used', kit=KIT_DIR), rel.replace('/', '__'))

def stamp_fn(fn):
    """The usage stamp of the file that defines fn (a plugin's command, verb or adapter), when it lies in the kit."""
    f = osp.abspath(getattr(getattr(fn, '__code__', None), 'co_filename', '') or '')
    if f.lower().startswith(KIT_DIR.lower() + os.sep) and osp.basename(f) not in ('kitbag.py', 'devtools.py'):
        stamp_use([osp.relpath(f, KIT_DIR).replace(os.sep, '/')])

def stamp_use(paths):
    """Touch the usage stamps of goody files a command just used, at most once a day; never fails."""
    with contextlib.suppress(OSError):
        os.makedirs(kit_path('extras-used', kit=KIT_DIR), exist_ok=True)
        day = datetime.datetime.combine(datetime.date.today(), datetime.time()).timestamp()
        for rel in paths:
            if not osp.isfile(use_stamp(rel)) or osp.getmtime(use_stamp(rel)) < day:
                open(use_stamp(rel), 'w', encoding='utf-8').close()

def extra_prune(kit, days, dry):
    """Drop installed goodies unused for more than <days> (newest stamp of their files, else when installed) that no Needed when
    line asks for and kit.local.json `goodies` does not list; one line each."""
    try:
        days = float(days)
    except ValueError:
        print(f'kitbag goody prune: --days {days!r} is not a number', file=sys.stderr)
        return 2
    if git(kit, 'rev-parse', '-q', '--verify', EXTRAS_REF)[0]:   # no Needed when lines to read: every goody would look unneeded
        print('kitbag goody prune: the goodies branch was never fetched (kitbag.py goody list): nothing pruned', file=sys.stderr)
        return 1
    want = {n for n, _ in extras_needed(kit, every=True)}
    listed = set(listed_goodies(local_config(kit, 'kit.local.json')))
    now, gone = time.time(), 0
    for name, paths in sorted(installed_extras(kit).items()):
        if name in want or name in listed:
            continue
        seen = [osp.getmtime(use_stamp(p)) for p in paths if osp.isfile(use_stamp(p))] or [osp.getmtime(osp.join(kit, p)) for p in paths]
        idle = (now - max(seen)) / 86400
        if idle > days:
            gone += 1
            print(f'goody {name}: unused {idle:.0f} d, no config needs it' + (' (dry run: kept)' if dry else ''))
            if not dry:
                drop_extra(kit, name, paths, 'pruned')
    if not gone:
        print(f'kitbag goody prune: nothing unused > {days:g} d')
    return 0

# a goody's tests.ps1 that dot-sources harness.ps1 beside itself gets the kit's harness; its test kits get the goody's files
HARNESS_SHIM = """. '<kit>/tests/harness.ps1'
$script:NewCoreTestKit = ${function:New-TestKit}
function New-TestKit([string]$name) { $k = & $script:NewCoreTestKit $name; if (Test-Path '<files>') { Copy-Item '<files>/*' $k -Recurse -Force }; $k }
"""

def extra_test(kit, names):
    """Run each installed goody's tests.ps1 (it stays on the goodies branch) against this kit, in parallel, and check its
    scripts' section maps (lint SECTION-*); harness output."""
    if not shutil.which('pwsh'):
        print('FAIL goody test: pwsh 7 is not on PATH\n1 failure(s)')
        return 1
    runs = []
    for name in names:
        zipped = subprocess.run(['git', '-C', kit, 'archive', '--format=zip', EXTRAS_REF, f'goodies/{name}'], capture_output=True, timeout=60).stdout
        tmp = tempfile.mkdtemp(prefix=f'extra-{name}-')
        with contextlib.suppress(zipfile.BadZipFile):   # no such goody: an empty archive
            zipfile.ZipFile(io.BytesIO(zipped)).extractall(tmp)
        here, p = osp.join(tmp, 'goodies', name), None
        files = osp.join(here, 'files')   # its scripts' section maps, as lint checks them once installed
        sec = ''.join(f'FAIL {c} {w}: {m}\n' for r, _, fs in os.walk(files) for x in fs
                      for rel in sec_files([osp.relpath(osp.join(r, x), files).replace('\\', '/')]) for c, w, m in sec_check(rel, read(osp.join(r, x)))[0])
        if osp.isfile(osp.join(here, 'tests.ps1')):
            if osp.isfile(osp.join(kit, 'tests', 'harness.ps1')) and not osp.exists(osp.join(here, 'harness.ps1')):
                with open(osp.join(here, 'harness.ps1'), 'w', encoding='utf-8') as fh:   # a test written to sit next to the harness
                    fh.write(HARNESS_SHIM.replace('<kit>', kit.replace("'", "''")).replace('<files>', files.replace("'", "''")))
            cmd = ['pwsh', '-NoProfile', '-File', osp.join(here, 'tests.ps1'), '-Kit', kit]
            d = osp.dirname(sys.executable)   # no python shim (chcp: shared console code page)
            env = dict(os.environ, PATH=d + os.pathsep + os.environ.get('PATH', '')) if d else None
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', env=env)
        runs.append((name, tmp, sec, p))
    fails = 0
    for name, tmp, sec, p in runs:
        try:
            o = sec + (p.communicate(timeout=300)[0] if p else '')
        except subprocess.TimeoutExpired:
            p.kill()
            o = sec + 'FAIL timed out after 300 s\n'
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        failed = len(re.findall(r'(?m)^FAIL ', o)) or (1 if p and p.returncode else 0)
        fails += failed
        if p or sec:   # a goody without tests.ps1 shows only map problems
            print(f'== goody {name}\n{o.rstrip()}\n-- goody {name}: {len(re.findall(r"(?m)^PASS ", o))} pass, {failed} fail')   # its own count: never read as the next one's
    print(f'{fails} failure(s)')
    return 1 if fails else 0

def extra_write(kit, verb, names, auto=False):
    """goody sync | add <name> [--auto: unlisted] | remove <name>, under the caller's lock."""
    if verb == 'sync':
        return extra_sync(kit)
    installed = installed_extras(kit)
    name = names[0]
    if name in MERGED_EXTRAS and name not in (known_extras(kit) or set()):
        print(f'kitbag goody {verb}: {name} is ' + (f'part of {MERGED_EXTRAS[name]} now: kitbag.py goody {verb} {MERGED_EXTRAS[name]}' if MERGED_EXTRAS[name] else 'in the core now'), file=sys.stderr)
        return 2
    if verb == 'add':
        rc = add_extra(kit, name, installed)
        if rc == 0 and not auto:   # on demand (lib.ps1 Install-KitExtra): unlisted, so goody prune can drop it once unused
            set_listed(kit, name, True)
        return rc
    tracked_files = set(tracked(kit))
    paths = [x for x in exclude_blocks(kit).get(name) or [rel for _, rel in extra_files(kit, name)] if x not in tracked_files]
    set_listed(kit, name, False)
    if not any(osp.isfile(osp.join(kit, x)) for x in paths):
        print(f'kitbag goody remove: {name} is not installed in {kit}', file=sys.stderr)
        return 1
    drop_extra(kit, name, paths)
    return 0


def cmd_extra(a):
    """kitbag.py goody list | add <name> [--auto] | remove <name> | check | sync | test [<name>] | prune [--days N] [--dry-run]
    (--auto: installed on demand, unlisted; prune: unused > N days, default 30, and no Needed when matches)"""
    kit = KIT_DIR
    flags, rest = parse_opts(a, {'--days'})
    verb, names = (rest[0] if rest else 'list'), rest[1:]
    want = {'add': 1, 'remove': 1, 'test': len(names[:1])}.get(verb, 0)
    if verb == 'prune' and not names:
        with locked(exclude_path(kit) or osp.join(kit, '.git', 'info', 'exclude'), stale=600):
            return extra_prune(kit, flags.get('--days', PRUNE_DAYS), '--dry-run' in flags)
    if verb not in ('list', 'add', 'remove', 'check', 'sync', 'test') or len(names) != want or ('--auto' in flags and verb != 'add'):
        print(cmd_extra.__doc__, file=sys.stderr)
        return 2
    installed = installed_extras(kit)
    # offline: the last fetched branch answers; check and test fetch only when it never did (check runs at SessionStart)
    if verb in ('list', 'add', 'sync') or (git(kit, 'rev-parse', '-q', '--verify', EXTRAS_REF)[0] and (verb != 'test' or installed)):
        git(kit, 'fetch', '-q', 'origin', f'+refs/heads/goodies:{EXTRAS_REF}', timeout=60)
    if verb in ('sync', 'add', 'remove'):   # one writer at a time: the post-merge hook's background sync races a manual one
        with locked(exclude_path(kit) or osp.join(kit, '.git', 'info', 'exclude'), stale=600):   # a sync may take minutes
            return extra_write(kit, verb, names, '--auto' in flags)
    if verb == 'test':
        if names and names[0] not in (known_extras(kit) or set()):
            print(f'kitbag goody test: no goody "{names[0]}" on origin/goodies (kitbag.py goody list)', file=sys.stderr)
            return 2
        return extra_test(kit, names or sorted(installed))
    if verb == 'check':
        need = extras_needed(kit)
        for name, feature in need:
            print(f'{feature} is a goody: run kitbag.py goody add {name}')
        return 1 if need else 0
    if verb == 'list':
        rc, o, err = git(kit, 'ls-tree', '-d', '--name-only', EXTRAS_REF, 'goodies/')
        if rc:
            print(f'kitbag goody: no goodies branch on origin ({err})', file=sys.stderr)
            return 1
        for path in o.split('\n'):
            name = path.split('/')[-1]
            text = git(kit, 'show', f'{EXTRAS_REF}:{path}/GOODY.md')[1]
            what = next((x.strip() for x in text.split('\n') if x.strip() and not x.startswith('#')), '')
            print(f"{'*' if name in installed else ' '} {name:20} {what[:100]}")
        return 0

def load_plugins():
    """Load installed kitbag goodies: each sees this module's names, adds COMMANDS, AUDIT_VERBS, ARGS and a lint_hook."""
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
        except Exception as e:   # a broken goody must not take lint (the commit gate) down with it
            print(f'kitbag: goody {fname} not loaded: {e}', file=sys.stderr)
            continue
        own = {n: v for n, v in vars(mod).items() if n not in shared or v is not shared[n]}   # what the plugin itself defines
        PLUGINS.update(own.get('COMMANDS', {}))
        AUDIT_VERBS.update(own.get('AUDIT_VERBS', {}))
        for cmd, (switches, valued, positional) in own.get('ARGS', {}).items():
            have = ARGS.get(cmd, (set(), set(), positional))
            ARGS[cmd] = (have[0] | switches, have[1] | valued, have[2])
        if 'lint_hook' in own:
            LINT_HOOKS.append(own['lint_hook'])

# ---- main: argument checks, command dispatch
# per command: switches, value flags, positional kit dir allowed? (`lint --help` once became a kit dir)
ARGS = {'lint': ({'--summary', '--warn', '--no-flow'}, {'--org-terms', '--json'}, True),
  'flow': ({'--readme'}, set(), True), 'audit': (set(), {'--kit', '--json'}, False), 'prose': ({'--json', '--kinds'}, {'--kind'}, False),
  'budget': (set(), {'-Reason', '-reason', '--reason'}, False), 'goody': ({'--auto', '--dry-run'}, {'--days'}, False), 'sections': ({'--fix'}, set(), False)}
NAMED_ARGS = ('prose', 'budget', 'goody', 'sections', 'new', 'rename', 'remove')   # positionals are files, verbs or names, not a kit dir
COMMANDS = {'lint': cmd_lint, 'flow': cmd_flow, 'audit': audit_main, 'prose': cmd_prose, 'budget': cmd_budget, 'goody': cmd_extra, 'sections': cmd_sections}

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
    """None = go on; else the exit code: --help/-h prints usage (0); an unknown command or flag, a non-kit dir or a missing goody is 2."""
    if cmd in ('-h', '--help', 'help') or (cmd in ARGS and any(x in ('-h', '--help') for x in rest)):
        print(__doc__)
        return 0
    verb = rest[0] if cmd == 'audit' and rest else ''
    if (cmd == 'audit' and f'audit {verb}' in EXTRA_OF and verb not in AUDIT_VERBS) or \
       (cmd in EXTRA_OF and cmd not in PLUGINS and not (cmd == 'flow' and '--readme' in rest)):
        name = EXTRA_OF[f'audit {verb}' if verb else cmd]
        if os.environ.get('KIT_EXTRA_AUTO') != '0' and os.environ.get('KIT_EXTRA_RETRY') != name and cmd_extra(['add', name, '--auto']) == 0:
            print(f'goody {name}: installed on demand', file=sys.stderr)   # the same command again, the goody loaded
            return subprocess.run([sys.executable, '-X', 'utf8', osp.abspath(__file__)] + sys.argv[1:], env=dict(os.environ, KIT_EXTRA_RETRY=name)).returncode
        return need_extra(f'kitbag.py {cmd} {verb}'.strip(), name)
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
    if rc is None and cmd in PLUGINS:
        stamp_fn(PLUGINS[cmd])
    sys.exit(rc if rc is not None else audited('kitbag.py', sys.argv[1:], lambda: (PLUGINS.get(cmd) or COMMANDS[cmd])(rest)))
