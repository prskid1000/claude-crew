#!/usr/bin/env python3
"""kittool.py: the kit's own tooling in one file - lint, flow graph, ports, audit, cost. Python 3.8+, no dependencies.

  python -X utf8 kittool.py lint  [<kit>] [--summary] [--warn] [--no-flow] [--org-terms <kit.local.json | a,b>] [--json <out>]
  python -X utf8 kittool.py flow  [<kit>] [--out <file.html>] [--readme] [--watch [--minutes <n>]] [--open] [--public]
  python -X utf8 kittool.py port  [--check]
  python -X utf8 kittool.py audit setup|config|recover|scan|stamp|due ...   # below
  python -X utf8 kittool.py cost  [<kit>] [--steps] [--routes] [--json]
  python -X utf8 kittool.py new agent|skill|workflow|rule|event|config-key <name> [--crew <agent>] [--skill <skill>] · new adr <title>
  python -X utf8 kittool.py rename agent|skill|workflow|rule|event|config-key <old> <new> · remove <kind> <name>
  python -X utf8 kittool.py prose --kind <kind> <file> [--json] · prose --kinds   # a text vs templates.md "Writing standards"
  python -X utf8 kittool.py release [--tag] [--publish]   # next SemVer + notes from Conventional Commits (no CHANGELOG file)
  python -X utf8 kittool.py budget [show] · budget raise -Reason "<why>"   # the kit total vs its cap; raise = x1.1, only when trimming cannot make room

Inputs: the kit folder (default: the kit this file lives in), skills/dev-kit/kit.example.json (_paths, _manifest), kit.local.json (org terms, localOnly).
Outputs: text; --json files; flow writes the live clone's <runtime>/cache/kit-flow.html (from any worktree) and (--readme) the graph sections of README.md.
Exit codes: 0 ok · 1 problems found (lint, stale ports, ACT/ASK audit findings) · 2 usage error.

lint checks (flow draws them; each fails, --warn only reports):
  ROUTER-MISSING / -TARGET / -UNROUTED  AGENTS.md "## Router": one target per row; every skill, workflow, agent routed
  OVERLAY-ROUTER  rules/*.local.md needs "## Org router rows"
  SKILL-DESC / SKILL-BLOCK / SKILL-FUZZY  "Load when: ... Not when: ... -> <sibling>"; the four blocks; no "read when you need it"
  FILES-UNLISTED / -MISSING / -UNBOUND  the Files index lists every file of the folder (and bound <kit>/... files) with its step
  WF-WHEN / WF-CLOCK / WF-CRLF  whenToUse = a router row word for word; no Date.now/new Date; LF only
  AGENT-SPAWN / AGENT-SKILL  "Spawned by" and "Not for"; the body names the skill it loads first
  REF-DANGLING  a kit path in Markdown points at nothing · REACH-NONE / REACH-MENTION  not reached from the root by edges
  JUNK  runtime output or reserved names · RUNTIME-RAW / -MAP / -DURABLE  hand-built paths; a workflow KP differs from _paths
  CONFIG-UNDOC  a kit.example.json key missing from README "Configuration"
  FILE-CAP / PLUMBING-CAP  over _manifest.caps.content / .plumbing (ports excluded) · BUDGET  a file or the kit over its tokens · BUDGET-CAP  totalTokens not a budget-raise step
  SCRIPT-HEADER  no usage + "Exit codes" header · PROSE  breaks templates.md "Writing standards" · DESKTOP-OPEN  opens without --open
  LESSONS-CAP  a LESSONS.md section over 40 lines · README-GRAPH  graph sections stale · ORG-TERM  an org term (--org-terms)
  MANIFEST / SCHEMA  files vs _manifest and its JSON Schemas · LEASE-HOLDER  a lease / hold written without New-KitLease
  OLD-NAME / AGENT-TYPE / TODO-STUB  a renamed name left; a workflow agent() without a crew agentType; a scaffolding stub left  NON-CREW / DECISION-WORDING  a non-crew agent spawned in an agent, skill or workflow; a decision rule without "user-visible"

audit (the mechanical half of agents/kitty.md steps 1-4, 9; the agent judges):

  setup [--fix]: clone, pre-push gate, excludes, runtime, hooks, ports, CLIs · config [--fill]: local config vs example, docs and
  the keys scripts read · recover [--fix]: worktrees, kit branches, launches, board, tracked local files, runtime · scan:
  consistency + script pitfall candidates (the audit worktree) · stamp: record the audit time (resets the weekly nudge) · due:
  last audit and whether the next is due. Any: --kit <dir>, --json <file> (findings as JSON).

--kit default: the LIVE clone (main worktree of this repo; scan: the kit this script lives in, the worktree you change).
Output: `<LEVEL> <CODE> <where>: <what> [-> <fix>]`; LEVEL FIX (repaired) | ACT (repair it) | ASK (only the lead knows: hosts,
ids, credentials) | WARN (candidate) | INFO. --fix / --fill repair only the safe and reversible; never prints a config VALUE.
Exit 1 when an ACT or ASK remains, else 0.
"""
import contextlib, datetime, fnmatch, hashlib, io, json, os, re, shutil, subprocess, sys, tempfile, time
import os.path as osp
from collections import defaultdict, deque
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

KIT_DIR = osp.dirname(osp.dirname(osp.dirname(osp.abspath(__file__))))   # 3 levels up: <kit>

# ==== 1. paths (kit.example.json _paths)
with open(osp.join(KIT_DIR, 'skills', 'dev-kit', 'kit.example.json'), encoding='utf-8') as _f:
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
        raise KeyError(f'kit_path: unknown name {name!r} (see skills/dev-kit/kit.example.json _paths)')
    p = osp.normpath(p)
    if create:
        os.makedirs(p if is_dir else osp.dirname(p), exist_ok=True)
    return p

@contextlib.contextmanager
def locked(path, stale=120):
    lock = path + '.lock'
    fd = None
    end = time.time() + stale + 10   # a dead writer's stale lock is taken over before we give up
    while fd is None:
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
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
        if fd is not None:
            os.close(fd)
            try:
                os.remove(lock)
            except OSError:
                pass

# ==== 2. graph + checks (lint and flow)
SKIP_DIRS = {'node_modules', '__pycache__', '.git', '.runtime', '.state', '.claude-runtime', 'worktrees', 'memory'}
# outside the graph: generated ports, git / legal files
REPO_ONLY = ('LICENSE', '.gitignore', '.gitattributes', 'GEMINI.md', '.codex', '.agents', '.github')
GENERATED = ('.codex/', '.agents/', 'GEMINI.md')
# caps: content = read by agents / people; plumbing = read only by git, CI, harness
PLUMBING = ('LICENSE', '.gitignore', '.gitattributes', '.githooks/', '.github/', 'settings.json')
CAPS = {'content': 30, 'plumbing': 8, 'totalTokens': 396000}   # only a fallback: kit.example.json _manifest.caps is the source (lint MANIFEST)
CAP_BASE = 360000   # totalTokens moves only in `budget raise` steps from here: x1.1, rounded to 1k (lint BUDGET-CAP)
TRIM_FIRST = 'trim first (dense prose, dedupe; never golf that hurts reading); if impossible: kittool.py budget raise -Reason "<why trimming cannot make room>"'


def cap_next(c):
    return int(round(c * 1.1 / 1000)) * 1000


def cap_problem(kdir, cap):
    """None, or why `cap` is not a budget-raise step (from CAP_BASE, at most one step above the last commit's cap)."""
    c = CAP_BASE
    while c < cap:
        c = cap_next(c)
    if c != cap:
        return f'totalTokens {cap} is not a raise step ({CAP_BASE} x 1.1, rounded to 1k, per step): change it only with kittool.py budget raise'
    try:
        r = subprocess.run(['git', '-C', kdir, 'show', f'HEAD:{PATHS_JSON}'], capture_output=True, text=True, encoding='utf-8', timeout=30)
        old = (json.loads(r.stdout).get('_manifest', {}).get('caps') or {}).get('totalTokens') if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        old = None
    if isinstance(old, int) and cap > old and cap != cap_next(old):
        return f'totalTokens {old} -> {cap} skips steps: one kittool.py budget raise per commit ({old} -> {cap_next(old)})'
    return None


def size_tokens(kdir, f):   # git blob size (LF: a CRLF checkout must not count more)
    t = read(os.path.join(kdir, f))
    if f == 'README.md':   # generated graph blocks excluded, like ports
        t = re.sub(r'<!-- kit-graph:start .*?<!-- kit-graph:end -->', '', t, flags=re.S)
    return len(t.encode('utf-8')) // 4
# token budgets (UTF-8 bytes / 4), README "Extending"
BUDGETS = {'always': 3500, 'skill': 3200, 'agent': 2400, 'rule': 900, 'template': 2600, 'templates': 4000, 'doc': 7000, 'lessons': 30000,
  'workflow': 15000, 'ps1': 58000, 'py': 77000, 'mjs': 8000, 'json': 6600, 'tests': 35750}
# files allowed raw runtime paths (lint RUNTIME-RAW)
PATHS_JSON = 'skills/dev-kit/kit.example.json'   # its _paths section
PATH_HELPERS = {PATHS_JSON, 'skills/dev-kit/lib.ps1', 'skills/dev-kit/devtools.py', 'skills/dev-kit/spec.mjs',
    'skills/qa-kit/browser.mjs', 'skills/orchestrate/kittool.py'}
# durable state old layouts kept in the runtime (RUNTIME-DURABLE; setup -Migrate moves it)
LEGACY_DURABLE = ('learning', 'tracking', 'automerge.json', 'tracker-none')
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

def main_clone(d):
    """Main worktree of the repo holding d (d itself if not a linked worktree or git fails)."""
    try:
        r = subprocess.run(['git', '-C', d, 'rev-parse', '--path-format=absolute', '--git-common-dir'], capture_output=True,
            text=True, encoding='utf-8', timeout=20)
        return osp.dirname(osp.normpath(r.stdout.strip())) if r.returncode == 0 and r.stdout.strip() else d
    except (OSError, subprocess.SubprocessError):
        return d

def load(kit):
    k = Kit()
    k.dir = osp.abspath(kit)
    k.repo = k.dir   # the kit is the repo root (README/docs/examples beside it)
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
    # kit = published files + local overlay (local skills, project profiles); not configs/state
    k.files = sorted(f for f in k.all if not ignored(f) or f in k.local_rules)
    k.fileset = set(k.files)
    try:
        lj = osp.join(k.dir, 'skills', 'dev-kit', 'kit.local.json')
        if not osp.isfile(lj):
            lj = osp.join(main_clone(k.dir), 'skills', 'dev-kit', 'kit.local.json')
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

def graph(k):
    texts, fileset = k.texts, k.fileset
    by_base = defaultdict(list)
    for f in k.files:
        by_base[osp.basename(f).lower()].append(f)

    def is_local(f):
        b = osp.basename(f)
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
        b = osp.basename(f)
        if f in ('CLAUDE.md', 'AGENTS.md'):
            return 'root'
        if f == 'README.md':
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
            return ('Run by the harness on ' + ', '.join(hook_targets[f])) if f in hook_targets else 'Run by git (core.hooksPath .githooks, set by orch.ps1 setup)'
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
        nodes[f] = {'id': f, 'label': osp.basename(f) if f.count('/') else f, 'kind': kd, 'col': COL[kd],
           'group': skill_of(f) or ('agents' if kd == 'agent' else 'workflows' if kd == 'workflow' else 'kit'),
           'local': is_local(f), 'trigger': trigger(f, kd)}
        if kd == 'skill':
            nodes[f]['label'] = skill_of(f)
        if kd in ('agent', 'workflow'):
            nodes[f]['label'] = osp.basename(f).rsplit('.', 1)[0]

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
    # Files index = explicit path into a skill's files (globs cover overlay files)
    for s, entries in k.index.items():
        for _, when, hits in entries:
            for h in hits:
                add(f'skills/{s}/SKILL.md', h, 'index', f'Files index: {when}')
    if 'CLAUDE.md' in nodes and 'AGENTS.md' in nodes:
        add('CLAUDE.md', 'AGENTS.md', 'import', 'CLAUDE.md imports AGENTS.md (@AGENTS.md): the Router')
    for cells in table_rows(k.router or ''):   # row id + conditions = reason
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
        sdir = osp.dirname(src)
        for m in PATH_RE.finditer(t):
            full = m.group(0).replace('\\', '/').strip('`\'"()[],:;')
            base = m.group(1)
            hit = None
            for cand in (osp.normpath(osp.join(sdir, full)).replace('\\', '/'), re.sub(r'^.*?\.claude/', '', full),
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
                add(src, hit, None, f'{osp.basename(src)}:{ln}: ' + t.splitlines()[ln - 1].strip()[:160] if t else None)
        for s in k.skills:
            mm = re.search(r'(?<![\w-])' + re.escape(s) + r'(?![\w-])', t)
            if mm:
                add(src, f'skills/{s}/SKILL.md', None, f'{osp.basename(src)}:{t.count(chr(10), 0, mm.start()) + 1} names {s}')
        for n, f in k.agents.items():
            mm = re.search(r'(?<![\w-])' + re.escape(n) + r'(?![\w-])', t)
            if mm:
                add(src, f, None, f'{osp.basename(src)}:{t.count(chr(10), 0, mm.start()) + 1} names {n}' + (' (spawns it)' if src.startswith('workflows/') else ''))
        for n, f in k.workflows.items():
            mm = re.search(r'(?<![\w-])/?' + re.escape(n) + r'(?![\w-])', t)
            if mm:
                add(src, f, None, f'{osp.basename(src)}:{t.count(chr(10), 0, mm.start()) + 1} names /{n}')
    for tgt, evs in hook_targets.items():
        if 'settings.json' in nodes:
            edges[('settings.json', tgt)] = 'hook'
            why[('settings.json', tgt)] = 'hook: ' + ', '.join(evs)

    entries = [f for f in ('CLAUDE.md',) if f in nodes] or [f for f, n in nodes.items() if n['kind'] == 'root']   # ONE root
    out = defaultdict(list)
    for (a, b), t in edges.items():
        out[a].append((b, t))
    prev: Dict[str, Optional[str]] = {e: None for e in entries}
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
    for a, p in k.agents.items():
        text = k.texts.get(p, '')
        desc = frontmatter(text).get('description', '')
        if 'Spawned by' not in desc:
            bad('AGENT-SPAWN', p, 'description must say "Spawned by <workflow / coordinator> ..."')
        if 'Not for' not in desc:
            bad('AGENT-SPAWN', p, 'description must say "Not for: ..."')
        if not any(f'skills/{s}/SKILL.md' in text for s in k.skills):
            bad('AGENT-SKILL', p, 'body must name the skill (skills/<name>/SKILL.md) it loads first')
    # ---- dangling kit paths (Markdown, workflow prompts)
    ext = r'\.(md|ps1|py|mjs|js|json|html|ini|txt)$'
    skip = re.compile(r'[<>*{}$]|\.local\.|^(examples)/|swarm\.(config\.)?json$|^https?:|\.(?:claude-)?runtime|\.state/|^~|^\.\.\./')
    basenames = {osp.basename(f) for f in k.files}
    kit_dirs = tuple(['skills/', 'rules/', 'agents/', 'workflows/'] + [s + '/' for s in k.skills])

    def overlay(f):
        return '.local.' in f or any(f == p or f.startswith(p + '/') for p in k.local_only)
    for f in k.files:
        if not f.endswith('.md') or f.endswith('LESSONS.md'):
            continue
        fdir, sk = osp.dirname(f), skill_of(f)
        for tok in re.findall(r'`([^`\n]+)`', k.texts.get(f, '')):
            t = (tok.strip().split() or [''])[0].replace('\\', '/')
            t = re.sub(r'^(<workspace>/)?\.claude/|^<kit>/', '', t).rstrip('.,;:)')
            if not re.search(ext, t) or skip.search(t) or re.match(r'^([A-Za-z]:)?/', t):
                continue   # outside the kit on purpose
            if overlay(f) and not t.startswith(kit_dirs):
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
    # ---- reach (same graph as the flow page)
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
    tracked = []
    try:
        r = subprocess.run(['git', '-C', k.dir, 'ls-files'], capture_output=True, text=True, encoding='utf-8', timeout=30)
        tracked = [x for x in r.stdout.splitlines() if x] if r.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired):
        pass
    counted = [x for x in (tracked or k.files) if not x.startswith(GENERATED) and osp.isfile(osp.join(k.dir, x))]   # a deletion not staged yet is gone
    plumbing = [x for x in counted if x.startswith(PLUMBING)]
    content = [x for x in counted if x not in plumbing]
    caps = {x: v for x, v in (manifest(k.dir).get('caps') or {}).items() if not x.startswith('_')}
    if caps and caps != CAPS:
        bad('MANIFEST', PATHS_JSON, f'_manifest.caps {caps} differ from the kittool.py fallback {CAPS}: keep them equal')
    caps = {**CAPS, **caps}
    cap_c, cap_p = caps['content'], caps['plumbing']
    if len(content) > cap_c:
        bad('FILE-CAP', 'kit', f'{len(content)} content files (cap {cap_c}: docs, agents, workflows, skills, scripts, config examples, tests; '
         'ports excluded): merge files (README "Extending")')
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
        if f == 'skills/dev-kit/templates.md':   # every template + Writing standards
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
    total = sum(sizes.values())
    cap_t = caps['totalTokens']
    if total > cap_t:
        over.append(('kit total', total, cap_t))
    if over:
        top = ', '.join(f'{f} {n}' for f, n in sorted(sizes.items(), key=lambda x: -x[1])[:5])
        for f, n, cap in over:
            fix = TRIM_FIRST if f == 'kit total' else 'trim it (dense prose, dedupe) or move text to a file with room'
            bad('BUDGET', f, f'{n} tokens (cap {cap}): {fix}; top consumers: {top}')
    # ---- script headers: usage + exit codes up top
    for f in counted:
        if not f.endswith(('.ps1', '.py', '.mjs')) or f.startswith(GENERATED):
            continue
        head = '\n'.join(k.texts.get(f, '').splitlines()[:40])
        if not re.search(r'Exit codes?:', head, re.I) or not re.search(r'usage|verbs?:|\bpython\b|\bpwsh\b|^\s*[#/]*\s*&\s', head, re.I | re.M):
            bad('SCRIPT-HEADER', f, 'no header block with usage and "Exit codes:" in the first 40 lines (dev-kit/templates.md "Script header")')
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
                bad('DESKTOP-OPEN', f'{f}:{i + 1}', 'opens a file, browser or app on the desktop without an explicit --open / -Open flag (README "Extending")')
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
        rt = os.environ.get('CLAUDE_RUNTIME') or osp.join(k.dir, pmap.get('runtimeDir', '.runtime'))
        for n in LEGACY_DURABLE:
            if osp.exists(osp.join(rt, n)):
                bad('RUNTIME-DURABLE', f'<runtime>/{n}', 'durable state inside the disposable runtime (old layout): '
                 'orch.ps1 setup -Migrate moves it out')
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
    # ---- org terms (published files + README/docs/examples)
    if org_terms:
        scan = [(f, k.texts.get(f) or read(osp.join(k.dir, f))) for f in k.files
          if not ('.local.' in f or any(f == p or f.startswith(p + '/') for p in k.local_only))]
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

# ---- README graph sections (Mermaid; pre-commit keeps them current)
FLOW_VIEWS = {
 'dev': ['flowchart LR',
   '  T([task / bug]) --> C[devy: code]',
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
    '  Q([deployed tasks + testing docs]) --> TE[checky per doc: web, API, phone lanes]',
    '  TE --> AU[note audit]',
    '  AU --> SR[stronger retry of NOT_TESTED]',
    '  SR -->|local env, still NOT_TESTED| EF[[ENV-FIX: coordinator fixes, retest; then held]]',
    '  SR --> VE[checky re-tests every FAIL]',
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
 'lifecycle': ['stateDiagram-v2', '  [*] --> open', '  open --> inProgress: devy starts', '  inProgress --> review: MRs open',
    '  review --> inProgress: findings / red CI', '  review --> promoted: every MR merged (track)', '  promoted --> inTest: a person said deploy env',
    '  inTest --> closed: every check passes', '  inTest --> failedTesting: own check failed / incomplete', '  failedTesting --> inProgress: bugfix /buildy',
    '  inTest --> open: new defect = one [Bug] task', '  closed --> [*]'],
 'budget': ['flowchart LR', '  P[plan: agents x budget = run cap] -->|estimate > cap| SP[refused: split into batches]', '  P --> RUN[run]',
   '  RUN -->|spend >= runStopAt x cap| NX[no new item; rest returns as next]', '  NX -->|coordinator relaunches| P',
   '  RUN --> AG[agent] -->|spend >= handoffAt x budget| HB[resume brief + board leave -Handoff]', '  HB -->|fresh agent, same -Agent -Run| AG'],
 'recovery': ['sequenceDiagram', '  participant O as owner', '  participant C as coordinator', '  participant K as kit scripts', '  participant A as fresh agent',
    '  O->>C: restart / new session', '  C->>K: orch.ps1 health (SessionStart)', '  K-->>C: stopped runs, handoffs, dirty worktrees',
    '  C->>K: orch.ps1 recover', '  K-->>C: resume brief + exact resume call per run', '  C->>A: relaunch from the brief (WIP commits kept)',
    '  A->>K: board join -Resume (TAKEOVER, not DUPLICATE)', '  C->>K: supervise -AutoFix every 10 min'],
 'upkeep': ['flowchart LR', '  AG[every agent] -->|orch.ps1 learn| SG[signals]', '  SG -->|run finished / 15 piled up| TI[/tidy: kitty/]',
   '  TI --> LS[LESSONS.md + rule changes]', '  LS -->|step 0 reads its section| AG', '  HB[supervise heartbeat] -->|flags| EV[orchestrate Events]',
   '  EV -->|kit friction| KF[kitty fix -> revy -> push main]', '  WK[weekly nudge] --> AU[kitty audit] --> KF', '  KF -->|git pull when idle| AG'],
 'leases': ['flowchart LR', '  H[holder: workflow step, board beat, pid, owner -Minutes] -->|use / acquire / openTab / gate| R[env service, tab, phone, sandbox, build]',
   '  R --> L{holder live?}', '  L -->|yes: seen = now| R', '  L -->|no| G[grace: idle.graceMinutes, report shows ⏳]', '  G -->|holder back| R',
   '  G -->|grace over| X[stopped / released]', '  R -->|release / unhold| X'],
}

def readme_sections(k, g):
    """The README's generated sections: the map (root -> router -> skills / workflows / agents), the flows, one per skill."""
    nodes, edges = g['nodes'], g['edges']
    label = lambda f: nodes[f]['label'] if f in nodes else f
    nid = lambda f: re.sub(r'[^A-Za-z0-9]', '_', f)
    out = {}
    lines = ['flowchart LR', '  CLAUDE_md[CLAUDE.md] -->|import| AGENTS_md[AGENTS.md Router]']
    # the README is published: local-overlay parts (localOnly, *.local.*) never appear
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
    for a, p in sorted(k.agents.items()):   # the skill on its "Load first" line
        m = re.search(r'Load first:\*\*\s*`[^`]*skills/([\w-]+)/SKILL\.md', k.texts.get(p, ''))
        if m and f'skills/{m.group(1)}/SKILL.md' in nodes:
            lines.append(f'  {nid(p)} -->|loads| {nid(f"skills/{m.group(1)}/SKILL.md")}')
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
    cut = lambda s, n: s if len(s) <= n else s[:n].rsplit(' ', 1)[0] + '…'   # at a word
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
    out['table-caps'] = [' · '.join(f'{n} {v}' for n, v in BUDGETS.items()) + f" · total {CAPS['totalTokens']} · files: {CAPS['content']} content + {CAPS['plumbing']} plumbing"]
    ma, mw = man.get('agents') or {}, man.get('workflows') or {}   # crew hero: who starts whom
    out['crew'] = ['flowchart LR', '  OW([owner]) -->|asks, says deploy env| CO[coordinator: Router + Events]'] + [
     x for w, m in mw.items() for x in [f"  CO -->|{m.get('router', '')}| W_{w}[/{w}/]"] + [f'  W_{w} -->|spawns| A_{c}({c})' for c in m.get('crew', [])]] + [
     f"  CO -->|{', '.join(u for u in m.get('usedIn', []) if u.startswith('R'))}| A_{a}({a})" for a, m in ma.items() if any(u.startswith('R') for u in m.get('usedIn', []))]
    rr = [r for r in table_rows(k.texts.get('AGENTS.md', '')) if len(r) > 2 and re.match(r'R\d+$', r[0])]   # Router: first match wins
    sh = lambda s, n: cut(re.sub(r'\s+([,.])', r'\1', re.sub(r'\s+', ' ', re.sub(r'[`"\[\]{}()<>|#;]', '', re.sub(r'\([^)]*\)', '', s)))).strip(), n)
    out['router'] = ['flowchart TD', '  Q([request]) --> R0'] + [
     x for i, r in enumerate(rr) for x in [f'  {r[0]}{{"{r[0]}: {sh(r[1], 40)}"}} -->|yes| T{i}["{sh(r[2], 32)}"]'] + ([f'  {r[0]} -->|no| {rr[i + 1][0]}'] if i + 1 < len(rr) else [])]
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
                lines.append(f'  {nid(sk)} -->|{step}| {nid(h)}[{osp.basename(h)}]')
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

# ==== 2b. kit-flow model + page
# Nodes: kit parts per file (commands, functions, phases, agent() calls, steps, rows, decisions, control flow, state, config, CLIs).
# Edges: regex refs (reason + file:line, cached per content hash). Issues: dangling refs, unhandled outcomes, unbounded loops.
VER = 9
CODE = ('.ps1', '.psm1', '.py', '.js', '.mjs', '.sh')
STR = re.compile(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"")
FN = {'ps1': re.compile(r'^\s*function\s+([\w-]+)'),
 'js': re.compile(r'^\s*(?:export\s+)?(?:async\s+)?(?:function\s+(\w+)|const\s+(\w+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|\w+)\s*=>)')}
GIT_VERBS = set('add am apply bisect branch checkout cherry-pick clean clone commit config diff fetch for-each-ref init log ls-files '
    'ls-remote merge merge-base mv pull push rebase remote reset restore rev-list rev-parse revert rm show stash status '
    'switch tag update-index worktree'.split())
EXT = [re.compile(r'\bgit(?:\.exe)?\s+(?:-C\s+\S+\s+|-c\s+\S+\s+)*([a-z][a-z-]+)'),
 re.compile(r"""['"]git['"]\s*,\s*(?:['"]-C['"]\s*,\s*[^,\]]+,\s*)?['"]([a-z][a-z-]+)['"]""")]
TOOLS = re.compile(r'\b(glab|gh)\s+(api|mr|pr|ci|run|auth|issue|repo|release)\b|\b(clickup|gws|aws|nr1|adb|emulator|avdmanager)\b'
    r'(?:\s+(?:-s\s+\S+\s+)?([a-z][\w:-]*))?|\b(npm|npx|yarn|pnpm)\s+([a-z][\w-]*)|\b(mvn|mvnw|gradlew?|dotnet|cargo)\b')
CMD = re.compile(r'\b([\w-]+\.(?:ps1|py|mjs))[\'"`]?[ \t]+([a-z_][\w-]*)(?:[ \t]+([a-z][\w-]*))?')
ALIAS_CALL = re.compile(r'(?:\$KitCmd\.(\w+)|\$\{(\w+)\}|&\s*\$(\w+))[\'"`]?[ \t]+([a-z_][\w-]*)(?:[ \t]+([a-z][\w-]*))?')
STATE = re.compile(r"(?:Get-KitPath\s+['\"]?|kit_path\(\s*['\"]|\brp\(\s*['\"]|kitPath\(\s*['\"])([\w-]+)")
JSONF = re.compile(r'(?<![\w/.-])((?:[\w-]+\.)?(?:run|results|launch|contracts|report|tracking|board|seed|decisions?|leases?|state|'
    r'checks|verdicts?|plan|history|outbox|deploys?|signals|learning)\.jsonl?)\b')
WRITE = re.compile(r'Set-Content|Out-File|Add-Content|WriteAll|AppendAll|Export-|New-Item|Move-Item|Copy-Item|Remove-Item|-Create\b|'
    r'write_text|json\.dump|open\([^)]*[\'"][wa]|writeFileSync|appendFileSync|mkdirSync|\b(?:write|append|record|save|update)s?\b', re.I)
# control flow: code on STRIPPED text (comments, strings blanked), docs on steps
CODE_CF = [('parallel', r'\bparallel\(|Promise\.all(?:Settled)?\(|\bpipeline\(|-Parallel\b|Start-ThreadJob|Start-Job\b|ThreadPoolExecutor'),
  ('wait', r'\bStart-Sleep\b|\btime\.sleep\(|\bsetTimeout\(|\bWait-(?:Job|Process|Event)\b|\.wait\(|\bWaitForExit\('),
  ('error', r'\bcatch\b|\btrap\b|\bexcept\b|\.catch\('),
  ('lock', r'\bLocked\b|\blocked\(|O_EXCL|\bMutex\b|\bflock\('),
  ('exit', r'\bexit\s+[0-9]\b|\bsys\.exit\(|\bprocess\.exit\(')]
DOC_CF = [('parallel', r'\bin parallel\b|\bparallel\(|\bpools?\b|\blanes?\b'),
  ('wait', r'\bdecide wait\b|\bwaits? (?:for|until)\b|merge-when-green|memory gate|\bholdMerge\b|\blease\b|seat acquire'),
  ('error', r'roll(?:ed)?[ -]?back|\bbisect\b|\bfallback\b|\brecover\w*\b'),
  ('event', r'\bnotification\b|\bsupervise (?:flag|prints)\b|\bon SessionStart\b'),
  ('human', r"(?:person|owner|tester|human|lead)\s+(?:says|answers|approves|tests|asks|decides)|\bby hand\b|a person's (?:word|yes)")]
CODE_CF = [(k, re.compile(x)) for k, x in CODE_CF]
DOC_CF = [(k, re.compile(x, re.I)) for k, x in DOC_CF]
LOOP_HEAD = {'ps1': re.compile(r'\b(foreach|for|while|until)\s*\(|\bdo\s*\{|\bForEach-Object\b|(?<![\w-])%\s*\{'),
   'js': re.compile(r'\b(for|while)\s*\(|\bdo\s*\{|\.forEach\('),
   'py': re.compile(r'^\s*(for|while)\b(.*):\s*(?:#.*)?$', re.M), 'sh': re.compile(r'\b(for|while|until)\b\s')}
LIMIT = r'(?:max|Max|MAX|cap\b|len\(|limit|Limit|round|Round|tries|Tries|TRIES|attempt|Attempt|timeout|Timeout|deadline|Deadline|budget|Budget|' \
  r'end|End|until|Until|Get-Date|Date\.now|time\.time|monotonic|elapsed|Elapsed|count|Count|length|Length|\$i\b|\bi\b|\bn\b|\d)'
CMP = r'(?:-lt|-le|-gt|-ge|<=?|>=?)'
CRON = re.compile(r"""['"`]([\d*/,-]+ [\d*/,-]+ [\d*/,-]+ [\d*/,-]+ [\d*/,-]+)['"`]""")
DOC_LOOP = re.compile(r'\b(repeat\w*|re-?run\w*|loop(?:s|ing)?)\b|\b(?:at most|max(?:imum)?|up to)\s+\d+\s+(?:rounds?|times|tries|attempts|cycles?)\b', re.I)
DOC_BOUND = re.compile(r'(?:at most|max(?:imum)?|up to|<=|≤)\s*(\d+)\s*(\w+)|(\d+)\s+(rounds?|times|tries|retries|attempts|cycles?)\b|'
     r'every\s+(\d+)\s*(\w+)|\b(weekly|daily|hourly|once|twice)\b', re.I)
OUTCOMES = ('PASS', 'FAIL', 'BLOCKED', 'NONE', 'NOT_TESTED', 'PASS_WITH_NOTE', 'OUT_OF_SCOPE', 'LIVE', 'REFUSED', 'REJECTED', 'ROLLED BACK',
   'SANDBOX', 'ACT', 'WATCH', 'INFO', 'HEAVY', 'LIGHT', 'MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED',
   'closed', 'failedTesting', 'failed testing', 'in test', 'promoted', '[Bug]', 'merged', 'held', 'deferred', 'blocked')
TERMINAL = {'PASS', 'closed', 'merged', 'MERGED', 'promoted', 'in test', 'LIVE', 'INFO', 'OUT_OF_SCOPE', 'NONE', 'PASS_WITH_NOTE'}
OUT_RX = re.compile(r'(?<![\w-])(' + '|'.join(re.escape(o) for o in sorted(OUTCOMES, key=len, reverse=True)) + r')(?![\w-])')
DSUBJ = {'mode', 'trigger', 'status', 'verdict', 'class', 'mclass', 'result', 'outcome', 'kind', 'state', 'level', 'severity', 'defect',
  'cause', 'trtype', '__trtype', 'reports', 'rtype', 'flag', 'decision', 'answer', 'review', 'learn'}
SUBVAR = ('Action', 'Sub', '__v', 'Verb', 'Op')
FLOW = {'calls', 'runs', 'impl', 'next', 'spawns', 'loads', 'routes', 'branch', 'loop', 'writes', 'reads', 'triggers', 'has'}

def short(s, n=44):
    s = re.sub(r'[`*]+', '', re.sub(r'\s+', ' ', s or '')).strip()
    return s if len(s) <= n else s[:n].rsplit(' ', 1)[0] + '…'

def lang(f):
    e = osp.splitext(f)[1]
    return {'.ps1': 'ps1', '.psm1': 'ps1', '.py': 'py', '.js': 'js', '.mjs': 'js', '.sh': 'sh', '.md': 'md', '.json': 'json'}.get(e, '')

class P:
    """One file's parse: parts [id, label, kind, line, desc] and refs (resolved later against every file)."""
    def __init__(s, f):
        s.f, s.parts, s.refs, s.text = f, [], [], {}

    def part(s, pid, label, kind, ln, desc='', end=0):
        s.parts.append([pid, label, kind, ln, short(desc, 260), end])
        return pid

    def ref(s, *r):
        s.refs.append(list(r))

def doc_bound(t):
    m = DOC_BOUND.search(t or '')
    if not m:
        return ''
    if m.group(7):
        return m.group(7).lower()
    if m.group(5):
        return f'every {m.group(5)} {m.group(6)}'
    return f'max {m.group(1) or m.group(3)} {m.group(2) or m.group(4)}'

def strip_code(text, lg, keep_tpl=False, keep_str=False):
    """text with comments and string literals blanked (same length, newlines kept), so keyword checks see only code."""
    out, i, n = list(text), 0, len(text)

    def blank(a, b):
        for j in range(a, min(b, n)):
            if out[j] != '\n':
                out[j] = ' '

    def close(q, a, esc):
        j = a
        while j < n and text[j] != q and not (text[j] == '\n' and lg in ('js', 'py')):
            j += 2 if text[j] == esc else 1
        return j + 1
    while i < n:
        c, two = text[i], text[i:i + 2]
        if lg == 'ps1' and two == '<#':
            j = text.find('#>', i)
            j = n if j < 0 else j + 2
        elif lg == 'ps1' and two in ("@'", '@"') and text[i + 2:i + 3] in ('\n', '\r'):
            j = text.find('\n' + two[1] + '@', i)
            j = n if j < 0 else j + 3
        elif (lg in ('ps1', 'py', 'sh') and c == '#') or (lg == 'js' and two == '//'):
            j = text.find('\n', i)
            j = n if j < 0 else j
        elif lg == 'js' and two == '/*':
            j = text.find('*/', i)
            j = n if j < 0 else j + 2
        elif lg == 'py' and text[i:i + 3] in ('"""', "'''"):
            j = text.find(text[i:i + 3], i + 3)
            j = n if j < 0 else j + 3
        elif lg == 'js' and c == '`':
            j, depth = i + 1, 0
            while j < n and not (text[j] == '`' and depth == 0):
                depth += text[j:j + 2] == '${'
                depth -= depth > 0 and text[j] == '}'
                j += 2 if text[j] == '\\' else 1
            j += 1
            if keep_tpl:
                i = j
                continue
        elif c in ('"', "'"):
            j = close(c, i + 1, '`' if lg == 'ps1' else '\\')
            if lg == 'ps1' and c == "'":
                while j < n and text[j] == "'":   # '' is an escaped quote
                    j = close("'", j + 1, '\0')
        else:
            i += 1
            continue
        if not (keep_str and (text[i] in '"\'`' or text[i:i + 2] in ('@"', "@'"))):
            blank(i, j)
        i = max(j, i + 1)
    return ''.join(out)

def code_control(p, src, raw, live, ln, lg, fname='', lns=None):
    """Control-flow points in one code block: loops with their bound (or none), schedules, parallel, waits, errors, locks, exits."""
    def at(pos):
        k = live.count('\n', 0, pos)
        return lns[min(k, len(lns) - 1)] if lns else ln + k
    for kind, rx in CODE_CF:
        m = rx.search(live)
        if m:
            cid = p.part(f'{src}~{kind}', m.group(0).strip('(. '), kind, at(m.start()), raw[max(0, m.start() - 40):m.end() + 120])
            p.ref('edge', src, cid, 'has', m.group(0).strip('(. '), '')
    loops = []
    rx = LOOP_HEAD.get(lg)
    for m in (rx.finditer(live) if rx else []):
        kw = (m.group(1) if m.groups() and m.group(1) else m.group(0)).strip('(.{ ')
        if kw in ('while', 'until') and re.search(r'\}\s*$', live[max(0, m.start() - 40):m.start()]):
            continue   # do { } while tail: the do loop carries it
        if lg == 'py':
            head = m.group(2)
        elif m.group(0).rstrip().endswith('('):
            j, d = m.end(), 1
            while j < len(live) and d:
                d += {'(': 1, ')': -1}.get(live[j], 0)
                j += 1
            head = live[m.end():j - 1]
        else:
            k = re.search(r'\}\s*(while|until)\s*\(([^\n]*)\)', live[m.end():m.end() + 6000])
            head = k.group(2) if k else ''
        body = live[m.end():m.end() + 2500]
        if kw.lower() in ('foreach', 'foreach-object', '%', 'map', 'filter', 'reduce', 'some', 'every') or \
          (lg == 'py' and kw == 'for') or (kw == 'for' and re.search(r'\b(of|in)\b', head) and ';' not in head):
            bound = 'collection'
        elif kw == 'for' and ';' in head:
            bound = 'counter' if re.search(CMP, head) else ''
        elif re.search(CMP, head):
            bound = 'condition'
        elif re.search(r'^\s*\$?\w+\.(?:Count|length)\s*$|^\s*\w+\s*$', head) and not re.search(r'^\s*\$?(true|True|1)\s*$', head):
            bound = 'drain' if re.search(r'Count|length|queue|stack|todo|work|^\s*\w*q\w*\s*$', head) else ''
        else:
            bound = ''
        if not bound and re.search(r'\b(if|elif|elseif)\b[^\n]*' + LIMIT + r'.{0,700}?\b(break|throw|return|raise|exit)\b', body, re.S):
            bound = 'guarded exit'
        if not bound and re.search(r'Split-Path|\.[Pp]arent\b|dirname|rsplit|(\w+)\s*=\s*\w+\[\s*\$?\1\s*\]|\w+\[\w+\[-1\]\]', body[:600] + head):
            bound = 'walk'
        if not bound and re.search(r'\.pop\(|\.shift\(|Dequeue|\+\+|\+=\s*1\b', raw[m.end():m.end() + 600]):
            bound = 'drain / counter'
        loops.append((kw, bound, at(m.start()), raw[m.start():m.start() + 160]))
    if fname and lg in ('ps1', 'py', 'js') and re.search(r'(?<![\w-])' + re.escape(fname) + r'\s*[\s(]', live.split('\n', 1)[-1]):
        loops.append(('recursion', 'structural', ln, fname))
    for m in CRON.finditer(raw):
        mm = re.match(r'\*/(\d+)', m.group(1))
        cid = p.part(f'{src}~timer', f'cron {m.group(1)}', 'timer', at(m.start()), m.group(1))
        p.ref('edge', cid, src, 'triggers', f'cron {m.group(1)}', '')
        p.ref('edge', cid, cid, 'loop', f'every {mm.group(1)} min' if mm else m.group(1), f'every {mm.group(1)} min' if mm else m.group(1))
    m = re.search(r'-IfDue\b|\beveryDays\b|IntervalHours\b|IdleHours\b', live)
    if m:
        cid = p.part(f'{src}~timer', m.group(0), 'timer', at(m.start()), raw[max(0, m.start() - 40):m.end() + 120])
        p.ref('edge', cid, src, 'triggers', m.group(0), '')
        p.ref('edge', cid, cid, 'loop', 'interval: ' + m.group(0).strip('-'), 'interval')
    if loops:
        free = [x for x in loops if not x[1]]
        lab = ', '.join(sorted({x[0] for x in loops}))
        cid = p.part(f'{src}~retry', f'loop: {lab}' + (' (no bound)' if free else ''), 'retry', (free or loops)[0][2],
           '; '.join(f'{k} [{b or "NO BOUND"}] :{l} {short(t, 60)}' for k, b, l, t in loops[:6]))
        p.ref('edge', src, cid, 'has', lab, '')
        b = '' if free else ', '.join(sorted({x[1] for x in loops}))
        p.ref('edge', cid, cid, 'loop', b or 'no bound', b)
        if free:
            p.ref('nobound', cid, f'{p.f}:{free[0][2]}', short(free[0][3], 80))

def doc_control(p, src, text, ln):
    """Control-flow points a doc step states: loops (repeat / rounds / retry, with their bound), schedules, waits, humans ..."""
    for kind, rx in DOC_CF:
        m = rx.search(text)
        if m:
            cid = p.part(f'{src}~{kind}', short(m.group(0), 28), kind, ln + text.count('\n', 0, m.start()), text[max(0, m.start() - 60):m.end() + 140])
            p.ref('edge', *((cid, src, 'triggers') if kind in ('human', 'event') else (src, cid, 'has')), short(m.group(0), 40), '')
    m = re.search(r'every\s+\d+\s*(?:min\w*|h\w*|days?)\b|\b(?:weekly|daily|hourly)\b|\bcron\b[^.\n]*\d', text, re.I)
    if m:
        b = doc_bound(text[m.start():m.end() + 40]) or short(m.group(0), 30)
        cid = p.part(f'{src}~timer', short(m.group(0), 28), 'timer', ln + text.count('\n', 0, m.start()), text[max(0, m.start() - 60):m.end() + 140])
        p.ref('edge', cid, src, 'triggers', short(m.group(0), 40), '')
        p.ref('edge', src, cid, 'has', 'arms ' + short(m.group(0), 30), '')
        p.ref('edge', cid, cid, 'loop', b, b)
    m = DOC_LOOP.search(text)
    if m:
        b = doc_bound(text[max(0, m.start() - 160):m.end() + 200])
        cid = p.part(f'{src}~retry', short(m.group(0), 20) + (f' ({b})' if b else ' (no bound)'), 'retry', ln + text.count('\n', 0, m.start()),
           text[max(0, m.start() - 60):m.end() + 160])
        p.ref('edge', src, cid, 'has', short(m.group(0), 40), '')
        p.ref('edge', cid, cid, 'loop', b or 'no bound', b)
        if not b and re.search(r'(?i)\b(?:repeat\w*|loop\w*)\b[^.\n]{0,80}\buntil\b', text):
            p.ref('nobound', cid, f'{p.f}:{ln + text.count(chr(10), 0, m.start())}', short(text[max(0, m.start() - 40):m.end() + 60], 80))

def scan(p, src, text, ln, code, aliases, mask=None):
    """Refs in one block of text owned by part src: commands, external CLIs, state, config, names, outcomes."""
    base = osp.basename(p.f)
    spans = [(0, text)] if code else [(m.start(1), m.group(1)) for m in re.finditer(r'`([^`]+)`', text)]
    for off, t in spans:
        def at(m):
            pos = off + m.start()
            line = text[text.rfind('\n', 0, pos) + 1:pos]
            if mask is not None:
                return ln + text.count('\n', 0, pos), bool(code and pos < len(mask) and mask[pos] != text[pos])
            return ln + text.count('\n', 0, pos), bool(code and re.search(r'(^|\s)(#|//|\*)', line))
        for m in CMD.finditer(t):
            p.ref('cmd', src, m.group(1), m.group(2), m.group(3) or '', *at(m))
        for m in ALIAS_CALL.finditer(t):
            key = m.group(1) or m.group(2) or m.group(3)
            b = aliases.get(key) or ('kc:' + key if m.group(1) else None)
            if b:
                p.ref('cmd', src, b, m.group(4), m.group(5) or '', *at(m))
        for rx in EXT:
            for m in rx.finditer(t):
                if m.group(1) in GIT_VERBS and not at(m)[1]:
                    p.ref('edge', src, '@ext/git ' + m.group(1), 'calls', f'{base}:{at(m)[0]}', '')
        for m in TOOLS.finditer(t):
            if at(m)[1]:
                continue   # a CLI named in a message / comment is no call
            tool = m.group(1) or m.group(3) or m.group(5) or m.group(7)
            verb = m.group(2) or (m.group(4) if code else '') or m.group(6) or ''
            p.ref('edge', src, '@ext/' + (tool + ' ' + verb).strip(), 'calls', f'{base}:{at(m)[0]}', '')
        for m in re.finditer(r'[\'"`]([a-zA-Z]\w*(?:\.[\w<>-]+)+)[\'"`]|Get-KitSetting\s+[\'"]?([\w.]+)', t if code else '`' + t + '`'):
            p.ref('cfg', src, m.group(1) or m.group(2), at(m)[0])
    for m in STATE.finditer(text):
        p.ref('state', src, m.group(1), 'w' if WRITE.search(text[m.start():m.start() + 240]) else 'r', ln + text.count('\n', 0, m.start()))
    for m in JSONF.finditer(text):
        seg = text[max(0, m.start() - 80):m.end() + 80]
        p.ref('edge', *((src, '@file/' + m.group(1), 'writes') if WRITE.search(seg) else ('@file/' + m.group(1), src, 'reads')),
         f'{base}:{ln + text.count(chr(10), 0, m.start())}', '')
    toks, n, last = {}, ln, 0
    for m in re.finditer(r'(?<![\w$.-])/?[A-Za-z_][\w-]*', text):
        n += text.count('\n', last, m.start())
        last = m.start()
        toks.setdefault(m.group(0), n)
    p.ref('tok', src, sorted(toks.items()), ln)
    for m in re.finditer(r'(?<![\w/.-])((?:[\w-]+/)*[\w.-]+\.md)\b', text):
        p.ref('mdfile', src, m.group(1), ln + text.count('\n', 0, m.start()))
    if code:
        for m in re.finditer(r'\b(orchestrate|dev-kit|qa-kit|local-env|android-swarm)\s+(?:steps?\s+)?([A-Z]{1,3}\d+[a-z]?|\d+)\b', text):
            p.ref('step', src, m.group(1), m.group(2), ln + text.count('\n', 0, m.start()))

def spans_of(lines, lg):
    out = []
    if lg == 'py':
        for i, l in enumerate(lines):
            m = re.match(r'(\s*)(?:async\s+)?def\s+(\w+)', l)
            if m:
                ind, j = len(m.group(1)), i + 1
                while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > ind):
                    j += 1
                out.append((i, j - 1, m.group(2)))
        return out
    rx = FN.get(lg)
    for i, l in enumerate(lines if rx else []):
        m = rx.match(l)
        if not m:
            continue
        depth, seen, j = 0, False, i
        while j < len(lines):
            s = STR.sub('', lines[j])
            s = s.split('#')[0] if lg == 'ps1' else s
            for ch in s:
                if ch == '{':
                    depth, seen = depth + 1, True
                elif ch == '}':
                    depth -= 1
            if (seen and depth <= 0) or (not seen and j == i and '=>' in l):
                break
            j += 1
        out.append((i, min(j, len(lines) - 1), next(g for g in m.groups() if g)))
    return out

def parse_code(p, f, text):
    lg, base = lang(f), osp.basename(f)
    lines = text.split('\n')
    live = strip_code(text, lg).split('\n')
    tlive = strip_code(text, lg, keep_tpl=True).split('\n') if lg == 'js' else live
    sp = spans_of(lines, lg)
    own = [None] * len(lines)
    for a, b, name in sorted(sp, key=lambda x: x[1] - x[0], reverse=True):
        pid = p.part(f'{f}#{name}', name + ('()' if lg != 'ps1' else ''), 'fn', a + 1, lines[a].strip(), b + 1)
        for i in range(a, b + 1):
            own[i] = pid
    aliases = {}
    for m in re.finditer(r'(?:const\s+(\w+)\s*=|\$(\w+)\s*=)\s*[^\n;]*?[\\/]([\w-]+\.(?:ps1|py|mjs))', text):
        aliases[m.group(1) or m.group(2)] = m.group(3)
    consts = {m.group(1): m.group(2) for m in re.finditer(r'const\s+(\w+)\s*=.*?(\d+)\s*$', text, re.M)}
    # commands: dispatch lines (verb -> function) + its sub-verbs
    impl = {}
    for i, l in enumerate(lines):
        m = re.search(r"^\s*'([\w-]+)'\s*\{\s*Invoke-KitVerb\s+([\w-]+)|__verb -eq '([\w-]+)'\)\s*\{\s*Invoke-KitVerb\s+([\w-]+)|"
           r"\bcmd\s*==\s*'([\w-]+)'\s*:|'([\w-]+)':\s*lambda[^:]*:\s*(\w+)\(", l)
        if m:
            verb = m.group(1) or m.group(3) or m.group(5) or m.group(6)
            fn = m.group(2) or m.group(4) or m.group(7)
            if not fn and i + 1 < len(lines):
                fn = next((x for x in re.findall(r'(\w+)\(', lines[i + 1]) if x not in ('exit', 'print', 'len', 'str', 'int')), None)
            pre = (own[i].split('#')[-1].replace('_main', '').replace('cmd_', '') + ' ') if m.group(6) and own[i] else ''
            cid = p.part(f'{f}#>{pre}{verb}', f'{base} {pre}{verb}', 'cmd', i + 1, l.strip())
            if fn:
                p.ref('impl', cid, fn, i + 1)
                impl[fn] = (cid, f'{base} {pre}{verb}')
        m = re.search(r"\$_\s+-in\s+((?:'[\w-]+'\s*,?\s*)+)\}\s*\{\s*Invoke-KitVerb\s+([\w-]+)|choices=\[([^\]]+)\]", l)
        for v in re.findall(r"'([\w-]+)'", (m.group(1) or m.group(3)) if m else ''):
            cid = p.part(f'{f}#>{v}', f'{base} {v}', 'cmd', i + 1, l.strip())
            if m.group(2):
                p.ref('impl', cid, m.group(2), i + 1)
                impl.setdefault(m.group(2), (f, base))
        m = re.search(r'Invoke-KitVerb\s+([\w-]+)\s+@\(\$args\)', l)   # args passed on: the function's verbs are the script's
        if m:
            impl[m.group(1)] = (f, base)
    for a, b, name in sp:
        if name not in impl:
            continue
        cid, label = impl[name]
        vs = re.search(r"ValidateSet\(([^)]*)\)\]\s*\[string\]\s*\$(?:%s)\b" % '|'.join(SUBVAR), '\n'.join(lines[a:a + 6]))
        for sv in re.findall(r"'([\w-]+)'", vs.group(1) if vs else ''):
            sid = p.part(f'{f}#>{label.split(" ", 1)[-1] if label != base else ""} {sv}'.replace('> ', '>'), f'{label} {sv}', 'cmd', a + 1, lines[a].strip()[:200])
            p.ref('edge', sid, f'{f}#{name}', 'impl', f'{base}:{a + 1}', '')
            if cid != f:
                p.ref('edge', cid, sid, 'next', 'sub-verb', '')
        for i in range(a, b + 1):
            m = re.search(r"\$(?:%s)\s+-(?:c?eq|in)\s+'([\w-]+)'(?:\s*,\s*'([\w-]+)')*|^\s*'([\w-]+)'\s*(?:,\s*'[\w-]+'\s*)*\{" % '|'.join(SUBVAR), lines[i])
            if m and (m.group(1) or (m.group(3) and any(re.search(r'switch\s*\(\s*\$(?:%s)\s*\)' % '|'.join(SUBVAR), lines[j]) for j in range(max(a, i - 400), i)))):
                sv = m.group(1) or m.group(3)
                sid = p.part(f'{f}#>{label.split(" ", 1)[-1] if label != base else ""} {sv}'.replace('> ', '>'), f'{label} {sv}', 'cmd', i + 1, lines[i].strip())
                p.ref('edge', sid, f'{f}#{name}', 'impl', f'{base}:{i + 1}', '')
                if cid != f:
                    p.ref('edge', cid, sid, 'next', 'sub-verb', '')
    # decisions: comparisons, switches (outcome per case), enums
    ekeys = set(re.findall(r"(\w+):\s*\{\s*type:\s*'string',\s*enum:", text))
    for i, l in enumerate(lines):
        src = own[i] or f
        for m in re.finditer(r"([\w$.\]\[]+?)\s*(?:===?|!==?|-c?eq|-ne|==|!=)\s*'([^'\n]{1,24})'", l):
            if live[i][m.start():m.start() + 1] in (' ', ''):
                continue   # inside a comment or a string
            subj, val = m.group(1).lstrip('$').split('.')[-1].strip('[]'), m.group(2)
            if subj in SUBVAR + ('__verb', 'cmd') or not re.match(r'^[\w \[\]-]{1,24}$', val) or not (
              subj in ekeys or re.match(r'^[A-Z][A-Z_ ]+$', val) or subj.lower() in DSUBJ):
                continue
            decision(p, f, src, subj, val, lines, i, base)
        m = re.match(r'\s*switch\s*(?:-\w+\s*)*\(\s*\$([\w.]+)\s*\)', live[i])
        if m and m.group(1).split('.')[-1] not in SUBVAR + ('__verb',):
            ind = None
            for j in range(i + 1, min(len(lines), i + 200)):
                mm = re.match(r"^(\s*)'([^']+)'\s*\{", lines[j])
                if mm and (ind is None or len(mm.group(1)) == ind) and re.match(r'^[\w -]{1,24}$', mm.group(2)):
                    ind = len(mm.group(1))
                    decision(p, f, own[i] or f, m.group(1).split('.')[-1], mm.group(2), lines, j, base)
                elif ind is not None and lines[j].strip() == '}' and len(lines[j]) - len(lines[j].lstrip()) < ind:
                    break
    for m in re.finditer(r"(\w+):\s*\{\s*type:\s*'string',\s*enum:\s*\[([^\]]+)\]", text):
        did = f'{f}#?{m.group(1)}'
        p.part(did, m.group(1) + ' ?', 'decision', text.count('\n', 0, m.start()) + 1, m.group(0))
        p.ref('enum', did, re.findall(r"'([^']+)'", m.group(2)))
    # workflows: phases, slash entry, agent() calls + loops, exit
    if f.startswith('workflows/'):
        name = base.rsplit('.', 1)[0]
        wd = re.search(r"whenToUse:\s*'((?:[^'\\]|\\.)*)'", text)
        slash = p.part(f'{f}#/{name}', '/' + name, 'slash', 1, wd.group(1) if wd else '')
        p.ref('edge', slash, f, 'runs', 'top-level code', '')
        phases = re.findall(r"\{\s*title:\s*'([^']+)',\s*detail:\s*'((?:[^'\\]|\\.)*)'", text)
        prev = slash
        for t, d in phases:
            pid = p.part(f'{f}#phase:{t}', t, 'phase', 1, d)
            p.ref('edge', prev, pid, 'next', 'then', '')
            prev = pid
        ex = p.part(f'{f}#exit', 'return report', 'exit', len(lines), 'the workflow returns its report to the coordinator')
        p.ref('edge', prev, ex, 'next', 'done', '')
        calls, last_phase = [], None
        for m in re.finditer(r"\bphase\('(\w+)'\)|\bawait\s+agent\(", text):
            if m.group(1):
                last_phase = m.group(1)
                continue
            ln = text.count('\n', 0, m.start()) + 1
            end = text.find('})', text.find('label', m.start()))
            reg = text[m.start():end if end > 0 else m.start() + 3000]
            lab = re.search(r"label(?::\s*[`']([\w-]+))?", reg)
            cname = (lab.group(1) if lab and lab.group(1) else f'agent@{ln}').rstrip('-:')
            ph = re.search(r"phase:\s*'(\w+)'", reg)
            cid = p.part(f'{f}#call:{cname}', 'agent ' + cname, 'call', ln, reg[:400])
            p.ref('edge', own[ln - 1] or f, cid, 'calls', f'{base}:{ln}', '')
            phn = ph.group(1) if ph else last_phase
            if phn:
                p.ref('edge', f'{f}#phase:{phn}', cid, 'runs', f'phase {phn}', '')
            at = re.search(r"agentType:\s*'([\w-]+)'", reg)
            if at:
                p.ref('edge', cid, f'agents/{at.group(1)}.md', 'spawns', f'agentType {at.group(1)}', '')
            pf = re.match(r'await\s+agent\(\s*(\w+)\(', reg)
            if pf:
                p.ref('fn', cid, [pf.group(1)], ln)
            scan(p, cid, reg, ln, True, aliases)
            back = '\n'.join(lines[max(0, ln - 7):ln])
            lm = re.search(r'for\s*\(let\s+\w+\s*=\s*0;\s*\w+\s*<\s*([\w.]+)', back)
            if lm:
                b = consts.get(lm.group(1), lm.group(1))
                p.ref('edge', cid, cid, 'loop', f'repeat, max {b}', f'max {b}')
            if re.search(r'retry|retest|strong|resume|again', cname) and calls:
                p.ref('edge', cid, calls[-1], 'loop', cname, '')
            calls.append(cid)
    # per-line refs, then control flow per part
    blocks = defaultdict(list)
    for i, l in enumerate(lines):
        blocks[own[i] or f].append((i + 1, l))
    for src, bl in blocks.items():
        t = '\n'.join(l for _, l in bl)
        scan(p, src, t, bl[0][0], True, aliases, '\n'.join(tlive[n - 1] for n, _ in bl))
        p.ref('fn', src, sorted(set(re.findall(r'([A-Za-z_][\w-]*)\s*\(' if lg != 'ps1' else r'(?<![\w$.-])([A-Za-z_][\w-]*)', t))), bl[0][0])
        if src != f:
            code_control(p, src, t, '\n'.join(live[n - 1] for n, _ in bl), bl[0][0], lg, src.split('#')[-1] if '#' in src else '', [n for n, _ in bl])

def decision(p, f, src, subj, val, lines, i, base):
    did = f'{f}#?{subj}'
    if not any(x[0] == did for x in p.parts):
        p.part(did, subj + ' ?', 'decision', i + 1, lines[i].strip())
        p.ref('edge', src, did, 'calls', f'{base}:{i + 1} decides on {subj}', '')
    near = '\n'.join(lines[i:i + 8])
    lab = re.search(r"label:\s*[`']([\w-]+)", near)
    if lab:
        p.ref('edge', did, f'{f}#call:{lab.group(1).rstrip("-:")}', 'branch', f'= {val}', '')
        return
    p.ref('branch', did, val, near[:500], i + 1)

def parse_md(p, f, text):
    sec, cur, prev_step, buf, intable, tdec, fence = f, f, None, defaultdict(list), False, None, False
    cbuf, lines = defaultdict(list), text.split('\n')
    aliases = {m.group(1): m.group(2) for m in re.finditer(r"\$(\w+)\s*=\s*'[^'\n]*?([\w-]+\.(?:ps1|py|mjs))'", text)}
    for i, l in enumerate(lines):
        ln = i + 1
        if l.startswith('```'):
            fence = False if fence else ('skip' if 'mermaid' in l else True)
            continue
        im = re.match(r'^@([\w./-]+\.md)\s*$', l)
        if im:
            p.ref('edge', f, im.group(1), 'loads', 'import', '')
        if fence == 'skip':
            continue
        h = re.match(r'^(#{1,3})\s+(.+)', l) if not fence else None
        if h:
            p.ref('edge', sec, f'{f}#§{short(h.group(2), 40)}', 'next', 'then' if sec != f else 'first', '')
            sec = cur = p.part(f'{f}#§{short(h.group(2), 40)}', short(h.group(2), 40), 'section', ln, h.group(2))
            prev_step, intable = None, False
            continue
        st = re.match(r'^\s{0,2}(?:[-*]\s+)?\**([A-Z]{1,3}\d+[a-z]?)\.\**\s+(.*)|^(\d+)\.\s+(.*)', l)
        row = re.match(r'^\|\s*\**([A-Z]{1,3}\d+[a-z]?)\**\s*\|(.*)', l)
        if l.startswith('|') and not intable and i + 1 < len(lines) and re.match(r'^\|[\s:|-]+\|?$', lines[i + 1]):
            intable, tdec = True, None
            continue
        if not l.startswith('|'):
            intable = False
        if row:
            cells = [c.strip() for c in row.group(2).strip().strip('|').split('|')]
            if not tdec:
                tdec = p.part(f'{sec}?', short(sec.split('#§')[-1], 30) + ' ?', 'decision', ln, 'first matching row wins')
                p.ref('edge', sec, tdec, 'next', 'which row?', '')
            cur = p.part(f'{f}#{row.group(1)}', f'{row.group(1)} {short(cells[0], 34)}', 'row', ln, ' | '.join(cells))
            p.ref('edge', tdec, cur, 'branch', short(cells[0], 60), '')
            buf[cur].append((ln, ' '.join(cells[1:]) + ' ' + cells[0]))
            continue
        fs = re.search(r'#\s+(\d+[a-z]?)\.\s+(\S.*)$', l) if fence else None
        if fs:
            st = re.match(r'(?P<a>)?(?P<b>)?(\d+[a-z]?)\.\s+(.*)', fs.group(1) + '. ' + fs.group(2))
        if st and (not fence or fs):
            sid = st.group(1) or (short(sec.split('#§')[-1], 18) + '/' + st.group(3))
            cur = p.part(f'{f}#{sid}', f'{st.group(1) or st.group(3)}. {short(st.group(2) or st.group(4), 34)}', 'step', ln, st.group(2) or st.group(4))
            if prev_step:
                p.ref('edge', prev_step, cur, 'next', 'then', '')
            else:
                p.ref('edge', sec, cur, 'next', 'first', '')
            prev_step = cur
        elif not l.strip() and not fence:
            cur = sec
        (cbuf if fence else buf)[cur].append((ln, l))
    for src, bl in cbuf.items():
        scan(p, src, '\n'.join(l for _, l in bl), bl[0][0], True, aliases)
    for src, bl in buf.items():
        t = '\n'.join(l for _, l in bl)
        scan(p, src, t, bl[0][0], False, {})
        doc_control(p, src, t, bl[0][0]) if src != f else None
        for m in re.finditer(r'\b([\w-]+)(?: SKILL\.md)?\s+(?:steps?\s+(\d+|[A-Z]{1,3}\d+[a-z]?)|([A-Z]{1,3}\d+[a-z]?))\b', t):
            p.ref('step', src, m.group(1), m.group(2) or m.group(3), bl[0][0])
        for m in re.finditer(r'(?<![\w#-])([A-Z]{1,3}\d{1,2}[a-z]?)(?![\w-])', t):
            p.ref('step', src, '', m.group(1), bl[0][0])
        arrows = [a for a in re.split(r'\s[·;]\s|\.\s(?=[A-Z])|\n', t) if re.search(r'->|→', a)]
        for a in arrows:
            left, right = re.split(r'\s*(?:->|→)\s*', a, maxsplit=1)
            p.ref('arrow', src, short(left.split(':')[-1], 50), right[:300], bl[0][0], len(arrows))

def parse_json(p, f, text):
    try:
        d = json.loads(text)
    except ValueError:
        return
    if '.example.' in f and isinstance(d.get('_paths'), dict):
        for sect in ('runtime', 'durable'):
            for k, v in (d['_paths'].get(sect) or {}).items():
                p.part(f'@state/{k}', k, 'state', 1, f'{sect}: {v}')
    if osp.basename(f) == 'settings.json':
        for ev, bl in (d.get('hooks') or {}).items():
            for b in bl:
                eid = p.part(f'{f}#{ev}{" " + b["matcher"] if b.get("matcher") else ""}', ev + (f' ({b["matcher"]})' if b.get('matcher') else ''),
                   'event', 1, 'Claude Code runs these hooks on ' + ev)
                for h in b.get('hooks', []):
                    scan(p, eid, ' '.join([h.get('command', '')] + list(h.get('args', []))).replace('/', ' / '), 1, True, {})
                    scan(p, eid, ' '.join([h.get('command', '')] + [osp.basename(x) for x in h.get('args', [])]), 1, True, {})
    elif '.example.' in f:
        def walk(o, pre, depth):
            for k, v in o.items():
                if k.startswith('_') or k.startswith('<'):
                    continue
                key = pre + k
                p.part(f'@config/{key}', key, 'config', 1, json.dumps(v)[:200] if not isinstance(v, dict) else (v.get('_readme') or ''))
                if isinstance(v, dict) and depth < 2:
                    walk(v, key + '.', depth + 1)
        walk(d, '', 0)

def parse(f, text):
    p = P(f)
    lg = lang(f)
    if f.startswith('.githooks/'):
        ev = {'pre-commit': 'git commit', 'pre-push': 'git push', 'post-merge': 'git pull / merge'}.get(osp.basename(f), 'git hook')
        eid = p.part(f'{f}#{ev}', ev, 'event', 1, f'git runs {f} (core.hooksPath)')
        scan(p, eid, text, 1, True, {})
    elif lg in ('ps1', 'py', 'js', 'sh'):
        parse_code(p, f, text)
    elif lg == 'md':
        parse_md(p, f, text)
    elif lg == 'json':
        parse_json(p, f, text)
    return {'parts': p.parts, 'refs': p.refs}

def model(k, problems, cache_path=None):
    """The page data: files, nodes, edges (with back-edge / loop flags), cycles, issues."""
    cache = {}
    if cache_path and osp.isfile(cache_path):
        try:
            with open(cache_path, encoding='utf-8') as fh:
                cache = json.load(fh)
        except (OSError, ValueError):
            cache = {}
    if cache.get('v') != VER:
        cache = {'v': VER, 'files': {}}
    parsed = {}
    for f in k.files:
        t = k.texts.get(f, '')
        if f.endswith('.md'):   # raw file (k.texts expands @imports)
            try:
                with open(osp.join(k.dir, f), encoding='utf-8', errors='replace') as fh:
                    t = fh.read().replace('\r\n', '\n')
            except OSError:
                pass
        h = hashlib.sha1(t.encode('utf-8', 'replace')).hexdigest()
        c = cache['files'].get(f)
        if not c or c['h'] != h:
            c = cache['files'][f] = {'h': h, 'p': parse(f, t)}
        parsed[f] = c['p']
    cache['files'] = {f: v for f, v in cache['files'].items() if f in parsed}
    if cache_path:
        try:
            os.makedirs(osp.dirname(cache_path), exist_ok=True)
            with open(cache_path, 'w', encoding='utf-8') as fh:
                json.dump(cache, fh)
        except OSError:
            pass
    return link(k, parsed, problems)

def fkind(f):
    b = osp.basename(f)
    return ('skill' if b == 'SKILL.md' else 'agent' if f.startswith('agents/') else 'workflow' if f.startswith('workflows/') else
      'script' if f.endswith(CODE) or f.startswith('.githooks/') else 'doc')

def link(k, parsed, problems):
    N, E, issues, grp = {}, {}, [], {}

    def node(i, label, kind, f, ln=0, d='', end=0):
        if i not in N:
            N[i] = [i, label, kind, f, ln, d, end]
        return i

    for f in k.files:
        lab = f.split('/')[1] if fkind(f) == 'skill' else osp.basename(f)
        node(f, lab, 'file', f, 1, '')
        for pid, label, kind, ln, d, *end in parsed[f]['parts']:
            node(pid, label, kind, f, ln, d, (end or [0])[0])
    node('@session', 'every session', 'event', '(events)', 0, 'the harness loads CLAUDE.md (+ imports) and the always-on rules')
    PSEUDO = {'ext': '(external CLIs)', 'file': '(shared files)', 'outcome': '(outcomes)', 'state': '(state)', 'config': '(config)'}

    def ensure(i):
        if i in N:
            return True
        m = re.match(r'@(\w+)/(.+)$', i)
        if m and m.group(1) in ('ext', 'file', 'outcome'):
            node(i, m.group(2), {'file': 'state'}.get(m.group(1), m.group(1)), PSEUDO[m.group(1)], 0, '')
            return True
        return False

    def edge(a, b, kind, label='', bound=''):
        if a and b and ensure(a) and ensure(b) and (a != b or kind == 'loop'):
            key = (a, b, kind)
            if key not in E:
                E[key] = [a, b, kind, (label or '')[:140], bound or '']

    fns = defaultdict(list)
    cmds = defaultdict(dict)
    steps = defaultdict(dict)
    for i, n in N.items():
        if n[2] == 'fn':
            fns[n[1].rstrip('()')].append(i)
        elif n[2] == 'cmd':
            parts = n[1].split(' ', 1)
            cmds[parts[0]][parts[1] if len(parts) > 1 else ''] = i
        elif n[2] in ('step', 'row'):
            steps[n[3]].setdefault(i.split('#', 1)[1].split('/')[-1], i)
    kc = {m.group(1): m.group(2) for m in re.finditer(r'^\s*(\w+)\s*=\s*Join-Path \$KitConf\.Kit \'[^\']*?([\w-]+\.\w+)\'', k.texts.get('skills/dev-kit/lib.ps1', ''), re.M)}
    skills = {s: f'skills/{s}/SKILL.md' for s in k.skills}
    agents = dict(k.agents)
    wfs = {'/' + w: f'{p}#/{w}' for w, p in k.workflows.items()}
    cfg = {n[1] for n in N.values() if n[2] == 'config'}
    states = {n[1] for n in N.values() if n[2] == 'state' and n[0].startswith('@state/')} | {'runtime'}

    def resolve_fn(name, f):
        c = fns.get(name, [])
        same = [x for x in c if x.startswith(f + '#')]
        lib = [x for x in c if x.startswith('skills/dev-kit/lib.ps1#')] if f.endswith('.ps1') else []
        c = [x for x in c if lang(x.split('#')[0]) == lang(f) or (lang(f) == 'md' and lang(x.split('#')[0]) == 'ps1')]
        return (same or lib or (c if len(c) == 1 else []) or [None])[0]

    def resolve_cmd(base, verb, sub):
        base = kc.get(base[3:], base) if base.startswith('kc:') else base
        if base not in cmds:
            return None, None
        if verb in ('-File', 'File'):
            return None, None
        c = cmds[base]
        hit = c.get(f'{verb} {sub}'.strip()) or c.get(verb)
        return hit, (None if hit or not c or verb in ('-', '') else f'{base} {verb}')

    for f in k.files:
        if f == 'CLAUDE.md' or re.match(r'rules/[^/]+\.md$', f) and 'paths:' not in k.texts.get(f, '')[:300]:
            E[('@session', f, 'triggers')] = ['@session', f, 'triggers', 'always loaded', '']
    unres = defaultdict(set)
    for f in k.files:
        for r in parsed[f]['refs']:
            kind, src = r[0], r[1]
            if kind == 'edge':
                edge(r[1], r[2], r[3], r[4], r[5])
            elif kind == 'impl':
                edge(src, resolve_fn(r[2], f), 'impl', f'{osp.basename(f)}:{r[3]}')
            elif kind == 'cmd':
                hit, miss = resolve_cmd(r[2], r[3], r[4])
                if hit and r[6] and hit.split('#')[0] == f:
                    continue   # own usage comment, not a call
                if hit:
                    edge(src, hit, 'calls' if N.get(src, [0, 0, ''])[2] == 'fn' else 'runs', f'{osp.basename(f)}:{r[5]}')
                elif miss and not r[6] and re.match(r'^[a-z][a-z-]+$', r[3]) and r[3] not in ('and', 'or', 'the', 'to', 'in', 'is', 'with', 'from', 'for', 'then', 'only'):
                    unres[miss].add(f'{f}:{r[5]}')
            elif kind == 'fn':
                for name in r[2]:
                    t = resolve_fn(name, f)
                    if t and t != src and not t.startswith(src + '~'):
                        edge(src, t, 'calls', f'{osp.basename(f)}:{r[3]}')
            elif kind == 'tok':
                for tok, r3 in r[2]:
                    if tok in skills and not f.startswith(f'skills/{tok}/'):
                        edge(src, skills[tok], 'loads', f'{osp.basename(f)}:{r3} names {tok}')
                    elif tok in agents and agents[tok] != f:
                        edge(src, agents[tok], 'spawns' if 'spawn' in (N[src][5] or '').lower() or f.startswith('workflows/') else 'loads',
                         f'{osp.basename(f)}:{r3} names {tok}')
                    elif tok in wfs and not f.startswith('workflows/'):
                        edge(src, wfs[tok], 'loads' if f.startswith('agents/') else 'runs', f'{osp.basename(f)}:{r3} launches {tok}')
                    elif f.endswith('.md') and re.match(r'^[A-Z][\w]*-[A-Z]\w+$', tok) and tok in fns:
                        edge(src, resolve_fn(tok, f), 'runs', f'{osp.basename(f)}:{r3} names {tok}')
            elif kind == 'state':
                if r[2] in states:
                    if r[2] == 'runtime':
                        continue
                    edge(*((src, '@state/' + r[2], 'writes') if r[3] == 'w' else ('@state/' + r[2], src, 'reads')), f'{osp.basename(f)}:{r[4]}')
                else:
                    unres[f'state {r[2]}'].add(f'{f}:{r[4]}')
            elif kind == 'cfg':
                key = r[2]
                while key and key not in cfg:
                    key = key.rsplit('.', 1)[0] if '.' in key else ''
                if key and not re.search(r'\.(ps1|py|m?js|json|md|html|txt|sh|exe)$', r[2]):
                    edge('@config/' + key, src, 'reads', f'{osp.basename(f)}:{r[3]} reads {r[2]}')
            elif kind == 'step':
                sk, sid = r[2], r[3]
                tf = skills.get(sk) or (f if not sk else None)
                if tf and sid in steps.get(tf, {}):
                    t = steps[tf][sid]
                    if t != src:
                        edge(src, t, 'loads' if tf != f else 'next', f'{osp.basename(f)}:{r[4]} {sk + " " if sk else ""}{sid}')
                elif sk in skills:
                    unres[f'{sk} step {sid}'].add(f'{f}:{r[4]}')
            elif kind == 'branch':
                tgt = branch_target(r[3], f, cmds, kc, N)
                edge(src, tgt or '@outcome/' + r[2], 'branch', f'= {r[2]}')
            elif kind == 'arrow':
                tgt = branch_target(r[3], f, cmds, kc, N, steps.get(f, {}), skills, wfs)
                if tgt:
                    s2 = src
                    if r[5] >= 2:
                        s2 = node(src + '?', short(N[src][1], 24) + ' ?', 'decision', f, N[src][4], N[src][5])
                        edge(src, s2, 'next', 'decides')
                    edge(s2, tgt, 'branch', r[2])
            elif kind == 'enum':
                pass
            elif kind == 'mdfile':
                hit = [x for x in k.files if x == r[2] or x.endswith('/' + r[2])]
                if len(hit) == 1 and hit[0] != f:
                    edge(src, hit[0], 'reads', f'{osp.basename(f)}:{r[3]} names {r[2]}')
    # handled = any branch, case, map key or row in the kit names it (code: outside comments)
    alltext = '\n'.join(strip_code(k.texts.get(f, ''), lang(f), keep_str=True) if lang(f) in ('ps1', 'py', 'js') else k.texts.get(f, '')
         for f in k.files)

    def handled(v):
        q = re.escape(v)
        return bool(re.search(r"(?:===?|!==?|==|!=|-c?eq|-c?ne|-c?in|-notin|\bin\b|includes\(|\bcase|has\()\s*[\[(]?\s*['\"]" + q + r"['\"]|"
             r"['\"]" + q + r"['\"]\s*(?::|=>|\)\s*\{|\s*\{)|^\|\s*`?" + q + r"`?\s*\||(?<![\w-])" + q + r"(?![\w-])[^\n]{0,40}?(?:->|→)", alltext, re.M))
    for f in k.files:
        for r in parsed[f]['refs']:
            if r[0] == 'enum':
                br = {e[3][2:] for e in E.values() if e[0] == r[1] and e[2] == 'branch'}
                for v in r[2]:
                    if v not in br:
                        edge(r[1], '@outcome/' + v, 'branch', f'= {v} (schema)')
                    if v not in br and v not in TERMINAL and not handled(v):
                        issues.append({'code': 'UNHANDLED', 'node': r[1], 'text': f'{N[r[1]][1]} outcome {v}: nothing branches on it ({f}:{N[r[1]][4]})'})
            elif r[0] == 'nobound':
                issues.append({'code': 'NO-BOUND', 'node': r[1], 'text': f'{r[2]}: loop with no bound ({r[3]})'})
    for miss, where in sorted(unres.items()):
        issues.append({'code': 'UNRESOLVED', 'node': sorted(where)[0].rsplit(':', 1)[0], 'text': f'{miss}: no such command/step ({", ".join(sorted(where)[:3])})'})
    for i, n in N.items():
        if n[2] == 'decision' and (n[3].endswith('.md') or n[3].startswith('workflows/')):
            outs = [e for e in E.values() if e[0] == i and e[2] == 'branch']
            vals = {e[1][9:] for e in outs}
            if outs and all(e[1].startswith('@outcome/') for e in outs) and not any(v in TERMINAL or handled(v) for v in vals):
                issues.append({'code': 'DEAD-END', 'node': i, 'text': f'{n[1]}: outcomes {", ".join(sorted(vals))} lead nowhere ({n[3]}:{n[4]})'})
    for i, n in list(N.items()):
        if not i.startswith('@outcome/'):
            continue
        rx = re.compile(r'(?<![\w-])' + re.escape(n[1]) + r'(?![\w-])')
        for j, r in N.items():
            if r[2] == 'row' and r[3].endswith('.md') and rx.search((r[5] or '').split(' | ')[0]):
                edge(i, j, 'triggers', 'handled by ' + r[1])
    named = named_cycles(N, E, issues)
    for it in issues:   # a deliberate one carries a `flow: <reason>` marker at its source line (or the line above): listed, not counted
        it['flow'] = True
        m = re.search(r'([\w./-]+\.(?:ps1|py|js|mjs|md)):(\d+)', it['text'])
        if m and m.group(1) in k.texts:
            ls = k.texts[m.group(1)].split('\n')
            near = ' '.join(ls[max(0, int(m.group(2)) - 2):int(m.group(2))])
            mk = re.search(r'flow:\s*([^\n]+?)\s*(?:#>|-->|\*/)?\s*$', near)
            if mk:
                it['deliberate'] = mk.group(1)
    for c, w, m in problems:
        issues.append({'code': c, 'node': w if w in N else None, 'text': f'{w}: {m}'})
    return pack(k, N, E, issues, named)

# the crew's named cycles: each hop (<= 4 edges) must exist; a missing hop is a GAP, never drawn
NAMED = [('heartbeat', [('timer', r'(?i)^cron |every \d+ ?min'), ('cmd', r'orch\.ps1 supervise$'), ('outcome|decision', r'^ACT\b'),
      ('row', r'^E\d+'), ('timer', r'(?i)^cron |every \d+ ?min')]),
  ('learn -> retro -> lessons', [('cmd', r'orch\.ps1 learn$'), ('state', r'^signals$'), ('slash', r'^/tidy$'),
          ('file', r'^LESSONS\.md$'), ('step', r'^0\. .*learn'), ('cmd', r'orch\.ps1 learn$')]),
  ('failedTesting -> dev -> deploy -> QA', [('outcome', r'^failedTesting$'), ('slash', r'^/buildy$'), ('cmd', r'orch\.ps1 deploy request$'),
            ('row', r'^E5\b'), ('slash', r'^/testy$'), ('outcome', r'^failedTesting$')])]

def named_cycles(N, E, issues):
    out = defaultdict(list)
    for a, b, kind, _, _ in E.values():
        if kind in FLOW:
            out[a].append(b)
    found = []
    for name, hops in NAMED:
        sets = [[i for i, n in N.items() if re.fullmatch(k, n[2]) and re.search(rx, n[1])] for k, rx in hops]
        nodes, gaps = [], []
        for (ka, ra), (kb, rb), A, B in zip(hops, hops[1:], sets, sets[1:]):
            path = hop(out, A, set(B)) if A and B else None
            if path:
                nodes += path
            else:
                gaps.append(f'{ra} -> {rb}' + ('' if A and B else ' (no such node)'))
        for g in gaps:
            issues.append({'code': 'GAP', 'node': (sets[0] or [None])[0], 'text': f'cycle "{name}": no edge {g} (the source never states it)'})
        found.append({'label': name + (f' ({len(gaps)} gap{"s" if len(gaps) > 1 else ""})' if gaps else ''), 'ids': list(dict.fromkeys(nodes)),
           'bound': '', 'kind': 'named', 'gaps': gaps})
    return found

def hop(out, A, B, depth=8):
    prev = {a: None for a in A}
    fr = list(A)
    for _ in range(depth):
        nx = []
        for u in fr:
            for v in out[u]:
                if v not in prev:
                    prev[v] = u
                    if v in B:
                        path = [v]
                        while prev[path[-1]] is not None:
                            path.append(prev[path[-1]])
                        return path[::-1]
                    nx.append(v)
        fr = nx
    return None

def branch_target(text, f, cmds, kc, N, steps=None, skills=None, wfs=None):
    for m in re.finditer(r"label:\s*[`']([\w-]+)", text):
        t = f'{f}#call:{m.group(1).rstrip("-:")}'
        if t in N:
            return t
    for m in CMD.finditer(text):
        c = cmds.get(m.group(1), {})
        t = c.get(f'{m.group(2)} {m.group(3) or ""}'.strip()) or c.get(m.group(2))
        if t:
            return t
    for m in ALIAS_CALL.finditer(text):
        base = kc.get(m.group(1) or '', '') or {'ORCH': 'orch.ps1', 'DEV': 'dev.ps1', 'DT': 'devtools.py'}.get(m.group(2) or m.group(3) or '', '')
        c = cmds.get(base, {})
        t = c.get(f'{m.group(4)} {m.group(5) or ""}'.strip()) or c.get(m.group(4))
        if t:
            return t
    for m in re.finditer(r'(?<![\w#-])([A-Z]{1,3}\d{1,2}[a-z]?)(?![\w-])', text):
        if steps and m.group(1) in steps:
            return steps[m.group(1)]
    for w, t in (wfs or {}).items():
        if re.search(r'(?<![\w-])' + re.escape(w) + r'(?![\w-])', text):
            return t
    for s, t in (skills or {}).items():
        if re.search(r'(?<![\w/-])' + re.escape(s) + r'(?![\w-])', text):
            return t
    m = OUT_RX.search(text[:80])
    return '@outcome/' + m.group(1) if m else None

def pack(k, N, E, issues, named=()):
    ids = list(N)
    ix = {i: n for n, i in enumerate(ids)}
    files = sorted({n[3] for n in N.values()})
    fx = {f: n for n, f in enumerate(files)}
    edges = [[ix[a], ix[b], kind, lab, bnd, 0] for a, b, kind, lab, bnd in E.values()]
    out = defaultdict(list)
    for n, e in enumerate(edges):
        if e[2] in FLOW:
            out[e[0]].append((e[1], n))
    # back edges: iterative DFS from entry points, then the rest
    kinds = [N[i][2] for i in ids]
    order = sorted(range(len(ids)), key=lambda n: (kinds[n] not in ('event', 'slash', 'human', 'timer', 'row', 'cmd'), n))
    state = [0] * len(ids)
    for r in order:
        if state[r]:
            continue
        stack = [(r, iter(out[r]))]
        state[r] = 1
        while stack:
            u, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                state[u] = 2
                stack.pop()
                continue
            v, en = nxt
            if state[v] == 1:
                edges[en][5] = 1
            elif not state[v]:
                state[v] = 1
                stack.append((v, iter(out[v])))
    cycles = []
    for n, e in enumerate(edges):   # named loops: loop edge + shortest way back
        if e[2] != 'loop' and not (e[5] and e[2] in ('branch', 'next')):
            continue
        if e[0] == e[1] and N[ids[e[0]]][2] in ('retry', 'timer') and (not e[4] or (N[ids[e[0]]][2] == 'retry' and not N[ids[e[0]]][3].endswith('.md'))):
            continue   # bounded code loops: nodes, not chips
        path = [e[0]] if e[0] == e[1] else (shortest(out, e[1], e[0]) or [e[1], e[0]])
        if path:
            lab = f"{N[ids[e[0]]][1]} ↻{' ' + e[4] if e[4] else ''}"
            cycles.append({'label': short(lab, 50), 'nodes': path, 'bound': e[4], 'kind': N[ids[e[0]]][2]})
    proc = defaultdict(list)   # process cycles, not helper calls
    for n, e in enumerate(edges):
        if e[2] in FLOW - {'calls', 'loads', 'has'}:
            proc[e[0]].append((e[1], n))
    for comp in tarjan(len(ids), proc):
        if len(comp) >= 2:
            names = sorted(comp, key=lambda n: -len(out[n]))[:3]
            cycles.append({'label': short(' → '.join(N[ids[n]][1] for n in names), 50) + f' ({len(comp)})', 'nodes': comp, 'bound': '', 'kind': 'scc'})
    for c in named:
        cycles.append({'label': c['label'], 'nodes': [ix[i] for i in c['ids']], 'bound': '', 'kind': 'named', 'gaps': c['gaps']})
    seen, uniq = set(), []
    rank = {'named': -1, 'call': 0, 'phase': 0, 'step': 1, 'cmd': 1, 'row': 1, 'decision': 1, 'scc': 2}
    for c in sorted(cycles, key=lambda c: (rank.get(c['kind'], 3), len(c['nodes']))):
        key = tuple(sorted(c['nodes']))
        if key not in seen:
            seen.add(key)
            uniq.append(c)
    nodes = [[N[i][1], N[i][2], fx[N[i][3]], N[i][4], N[i][5], i, N[i][6] if len(N[i]) > 6 else 0] for i in ids]
    fk = [{'id': f, 'kind': fkind(f) if not f.startswith('(') else 'pseudo'} for f in files]
    for it in issues:
        it['node'] = ix.get(it['node']) if it.get('node') in ix else (ix.get(it['node'].split(':')[0]) if it.get('node') else None)
    deliberate = [it for it in issues if it.get('deliberate')]
    counted = [it for it in issues if not it.get('deliberate')]
    counts = {'nodes': len(nodes), 'edges': len(edges), 'files': len([f for f in files if not f.startswith('(')]), 'issues': len(counted),
      'deliberate': len(deliberate), 'cycles': len(uniq)}
    dirty = bool(subprocess.run(['git', '-C', k.dir, 'status', '--porcelain'], capture_output=True, text=True).stdout.strip()) if osp.isdir(k.dir) else False
    return {'kit': k.dir, 'generated': time.strftime('%Y-%m-%d %H:%M:%S'), 'files': fk, 'nodes': nodes, 'edges': edges,
      'cycles': uniq[:80], 'issues': counted, 'deliberate': deliberate, 'dirty': dirty, 'counts': counts}

def shortest(out, a, b, cap=4000):
    prev, q = {a: None}, deque([a])
    while q and len(prev) < cap:
        u = q.popleft()
        if u == b:
            path = []
            while u is not None:
                path.append(u)
                u = prev[u]
            return path[::-1]
        for v, _ in out[u]:
            if v not in prev:
                prev[v] = u
                q.append(v)
    return None

def tarjan(n, out):
    index, low, on, st, comps, c = [None] * n, [0] * n, [False] * n, [], [], [0]
    for r in range(n):
        if index[r] is not None:
            continue
        work = [(r, iter(out[r]))]
        index[r] = low[r] = c[0]
        c[0] += 1
        st.append(r)
        on[r] = True
        while work:
            u, it = work[-1]
            nxt = next(it, None)
            if nxt is not None:
                v = nxt[0]
                if index[v] is None:
                    index[v] = low[v] = c[0]
                    c[0] += 1
                    st.append(v)
                    on[v] = True
                    work.append((v, iter(out[v])))
                elif on[v]:
                    low[u] = min(low[u], index[v])
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[u])
            if low[u] == index[u]:
                comp = []
                while True:
                    w = st.pop()
                    on[w] = False
                    comp.append(w)
                    if w == u:
                        break
                if len(comp) > 1:
                    comps.append(comp)
    return comps

def html(data, src_name=''):
    data = dict(data, src=src_name)
    return PAGE.replace('__DATA__', json.dumps(data, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/'))

def write(out, data, texts):
    """The page plus its sidecar (<page>-src.js: every file's text, loaded only when a node's code is first shown)."""
    side = out[:-5] + '-src.js' if out.endswith('.html') else out + '-src.js'
    with open(side, 'w', encoding='utf-8') as fh:
        fh.write('window.KF_SRC=' + json.dumps(texts, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/') + ';')
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write(html(data, osp.basename(side)))

PAGE = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kit flow</title>
<style>:root{--bg:#f8fafc;--fg:#0f172a;--mut:#64748b;--ln:#e2e8f0;--pn:#ffffff;--pn2:#f1f5f9;--hi:#d97706;--bad:#dc2626;--sel:#2563eb22;
--kw:#7c3aed;--st:#047857;--cm:#94a3b8;--nu:#c2410c;--va:#0369a1;--mono:ui-monospace,SFMono-Regular,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#0b1120;--fg:#e2e8f0;--mut:#94a3b8;--ln:#1e293b;--pn:#0f172a;--pn2:#111c33;--hi:#fbbf24;--bad:#f87171;--sel:#60a5fa22;
--kw:#c4b5fd;--st:#6ee7b7;--cm:#64748b;--nu:#fdba74;--va:#7dd3fc}}
*{box-sizing:border-box}html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--fg);font:12px system-ui,sans-serif}
#app{display:flex;height:100%}#main{position:relative;flex:1;min-width:0}#c{position:absolute;inset:0;width:100%;height:100%;touch-action:none}
#top{position:absolute;top:8px;left:8px;right:8px;display:flex;gap:6px;align-items:center;flex-wrap:wrap;pointer-events:none}#top>*{pointer-events:auto}
.b{background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:4px 9px;cursor:pointer;user-select:none;white-space:nowrap;color:var(--fg);font:inherit}
.b.on{background:var(--fg);color:var(--bg)}.seg{display:inline-flex}.seg .b{border-radius:0;margin-left:-1px}.seg .b:first-child{border-radius:8px 0 0 8px}.seg .b:last-child{border-radius:0 8px 8px 0}
input.b{cursor:text;width:180px}.dd{position:relative}.dd>.menu{display:none;position:absolute;top:30px;left:0;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:6px;min-width:220px;z-index:5;box-shadow:0 8px 24px #0003}
.dd.open>.menu{display:block}.menu label{display:flex;gap:6px;align-items:center;padding:3px 4px;border-radius:5px;cursor:pointer}.menu label:hover{background:var(--pn2)}.menu small{margin-left:auto;color:var(--mut)}
#legb{position:absolute;left:10px;bottom:10px;width:34px;height:34px;border-radius:50%;display:grid;place-items:center}
#leg{display:none;position:absolute;left:10px;bottom:52px;background:var(--pn);border:1px solid var(--ln);border-radius:10px;padding:10px;box-shadow:0 8px 24px #0003;max-width:min(640px,calc(100% - 20px))}
#leg.open{display:block}#leg .g{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px 14px}#leg .it{display:flex;gap:6px;align-items:center;white-space:nowrap;overflow:hidden}
#leg h4{margin:8px 0 4px;font-size:11px;color:var(--mut);font-weight:600}
#side{width:0;transition:width .18s ease;background:var(--pn);border-left:1px solid var(--ln);display:flex;flex-direction:column;position:relative;overflow:hidden}
#side.drag{transition:none}#grip{position:absolute;left:0;top:0;bottom:0;width:6px;cursor:col-resize;z-index:2}#grip:hover{background:var(--sel)}
#rail{width:44px;background:var(--pn2);border-left:1px solid var(--ln);display:flex;flex-direction:column;align-items:center;padding-top:8px;gap:4px}
.ri{position:relative;width:34px;height:34px;border-radius:8px;display:grid;place-items:center;cursor:pointer;color:var(--mut)}.ri:hover,.ri.on{background:var(--pn);color:var(--fg)}
.ri.on::before{content:'';position:absolute;left:-5px;top:7px;bottom:7px;width:3px;border-radius:2px;background:var(--fg)}
.badge{position:absolute;right:-2px;top:-2px;min-width:16px;height:16px;border-radius:8px;background:var(--bad);color:#fff;font-size:10px;display:grid;place-items:center;padding:0 3px}
#sh{padding:10px 12px 8px 14px;border-bottom:1px solid var(--ln);font-weight:600;display:flex;align-items:center;gap:8px;min-height:40px}
#sb{flex:1;overflow:auto;padding:0 0 12px 6px}.sticky{position:sticky;top:0;background:var(--pn);padding:8px 8px 6px 6px;z-index:1;display:flex;gap:6px;flex-wrap:wrap}
.li{display:flex;gap:8px;align-items:flex-start;padding:5px 8px;border-radius:6px;cursor:pointer}.li:hover{background:var(--pn2)}.li.on{background:var(--sel)}
.li .t{flex:1;min-width:0}.li .f{display:block;font:11px var(--mono);color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.li.bad .t{color:var(--bad)}
.num{font:600 10px var(--mono);color:var(--mut);min-width:20px;text-align:right;padding-top:2px}.grp{font-size:11px;color:var(--mut);font-weight:600;padding:8px 8px 2px}
.empty{color:var(--mut);padding:16px 10px;line-height:1.5}.ico{flex:none}
pre{margin:0;font:12px/1.55 var(--mono);tab-size:2}.cl{display:flex}.cl .n{color:var(--mut);min-width:44px;text-align:right;padding-right:10px;user-select:none}.cl .x{white-space:pre;flex:1}
.cl.me{background:var(--sel)}.kw{color:var(--kw)}.st{color:var(--st)}.cm{color:var(--cm);font-style:italic}.nu{color:var(--nu)}.va{color:var(--va)}
#meta{padding:8px 14px;border-bottom:1px solid var(--ln);color:var(--mut);line-height:1.5}#meta .f{font:11px var(--mono)}#meta a,.lnk{color:var(--va);cursor:pointer;margin-right:12px;text-decoration:none}
#tip{position:fixed;max-width:380px;background:var(--pn);border:1px solid var(--ln);border-radius:6px;padding:6px 8px;pointer-events:none;display:none;white-space:pre-wrap;box-shadow:0 4px 14px #0002;z-index:9}
select.b{max-width:100%}</style></head><body>
<div id="app"><div id="main"><canvas id="c"></canvas>
<div id="top"><b class="b" id="ttl" title="How to read: icons = kinds (key, bottom-left); zoom in for more detail; click a node = its neighbours + its code; click a highlighted neighbour to extend; dashed arc = loop / back edge; double-click = collapse a file; drag = pin">kit flow</b>
<input class="b" id="q" placeholder="search…"><span class="seg" id="lv"></span><span class="dd" id="ddS"><span class="b">Show ▾</span><div class="menu"></div></span><span class="dd" id="ddE"><span class="b">Edges ▾</span><div class="menu"></div></span><span class="b" id="fit">fit</span></div>
<span class="b" id="legb" title="key"></span><div id="leg"></div></div>
<div id="side"><div id="grip" title="drag to resize · double-click to reset"></div><div id="sh"></div><div id="meta" style="display:none"></div><div id="sb"></div></div>
<div id="rail"></div></div><div id="tip"></div>
<script>
const D = __DATA__, $ = s => document.querySelector(s), cv = $('#c'), X = cv.getContext('2d'), tip = $('#tip');
const LS = {get(k, d) { try { const v = localStorage.getItem('kf.' + k); return v == null ? d : JSON.parse(v) } catch (e) { return d } }, set(k, v) { try { localStorage.setItem('kf.' + k, JSON.stringify(v)) } catch (e) {} }};
// icons (24x24 stroke paths) and six colour families
const IC = {bolt: 'M13 2L4 14h7l-1 8 9-12h-7z', person: 'M12 4a4 4 0 1 0 0 8a4 4 0 1 0 0-8M4 21c1-5 15-5 16 0', clock: 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 7v5l3 2',
 table: 'M3 5h18v14H3zM3 10h18M9 5v14', slash: 'M15 4l-6 16', puzzle: 'M4 7h4a2 2 0 1 1 4 0h4v4a2 2 0 1 1 0 4v4h-4a2 2 0 1 0-4 0H4v-4a2 2 0 1 0 0-4z',
 robot: 'M6 8h12v11H6zM12 4v4M9.5 13h.01M14.5 13h.01M9 16h6M4 12v3M20 12v3', flow: 'M4 5h5v5H4zM15 14h5v5h-5zM9 7.5h3a3 3 0 0 1 3 3v3.5',
 term: 'M4 4h16v16H4zM8 9l3 3-3 3M13 15h3', fn: 'M15 4c-3 0-3 2-4 8s-1 8-4 8M8 10h7', globe: 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18',
 git: 'M6 3v12M18 6a3 3 0 1 0 0 .01M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6M18 9c0 5-5 6-9 8', doc: 'M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6',
 list: 'M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01', diamond: 'M12 3l9 9-9 9-9-9zM9 12h6', hour: 'M6 3h12M6 21h12M7 3c0 6 10 6 10 9s-10 3-10 9M17 3c0 6-10 6-10 9s10 3 10 9',
 loop: 'M4 12a8 8 0 0 1 14-5.3M20 4v4h-4M20 12a8 8 0 0 1-14 5.3M4 20v-4h4', par: 'M7 4v16M12 4v16M17 4v16', lock: 'M6 11h12v10H6zM8 11V7a4 4 0 0 1 8 0v4',
 warn: 'M12 3l10 18H2zM12 10v5M12 18h.01', door: 'M13 3H5v18h8M9 12h12M18 9l3 3-3 3', flag: 'M5 21V4h12l-2 4 2 4H5', db: 'M4 6c0-3 16-3 16 0v12c0 3-16 3-16 0zM4 6c0 3 16 3 16 0M4 12c0 3 16 3 16 0',
 gear: 'M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2', code: 'M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16',
 route: 'M6 19a2 2 0 1 0 0-4a2 2 0 1 0 0 4M18 9a2 2 0 1 0 0-4a2 2 0 1 0 0 4M6 15V9a4 4 0 0 1 4-4h6M18 9v6a4 4 0 0 1-4 4H8', key: 'M8 15a4 4 0 1 0 0-8a4 4 0 1 0 0 8M12 11h9M18 11v3M15 11v2'};
const P2 = Object.fromEntries(Object.entries(IC).map(([k, d]) => [k, new Path2D(d)]));
const FAM = {trig: ['Triggers', '#8b5cf6'], crew: ['Crew', '#0d9488'], code: ['Commands & code', '#3b82f6'], docs: ['Docs', '#16a34a'], ctrl: ['Control flow', '#d97706'], data: ['Data', '#ea580c']};
const KD = {event: ['trig', 'bolt', 'event / hook'], human: ['trig', 'person', 'human'], timer: ['trig', 'clock', 'timer / schedule'], row: ['trig', 'table', 'table row'],
 slash: ['crew', 'slash', 'slash command'], 'file-skill': ['crew', 'puzzle', 'skill'], 'file-agent': ['crew', 'robot', 'agent'], 'file-workflow': ['crew', 'flow', 'workflow'],
 call: ['crew', 'robot', 'agent() call'], phase: ['crew', 'flow', 'phase'], cmd: ['code', 'term', 'command'], 'file-script': ['code', 'term', 'script'], fn: ['code', 'fn', 'function'],
 ext: ['code', 'globe', 'external CLI'], 'file-doc': ['docs', 'doc', 'doc file'], section: ['docs', 'doc', 'section'], step: ['docs', 'list', 'step'],
 decision: ['ctrl', 'diamond', 'decision'], wait: ['ctrl', 'hour', 'wait / gate'], retry: ['ctrl', 'loop', 'loop / retry'], parallel: ['ctrl', 'par', 'parallel'], lock: ['ctrl', 'lock', 'lock'],
 error: ['ctrl', 'warn', 'error path'], exit: ['ctrl', 'door', 'exit'], outcome: ['ctrl', 'flag', 'outcome'], state: ['data', 'db', 'state'], config: ['data', 'gear', 'config key'], 'file-pseudo': ['data', 'db', 'group']};
const EK = {calls: ['#94a3b8', 'solid'], runs: ['#3b82f6', 'solid'], impl: ['#0ea5e9', 'solid'], next: ['#16a34a', 'solid'], spawns: ['#0d9488', 'solid'], loads: ['#a3a3a3', 'dot'],
 routes: ['#8b5cf6', 'solid'], branch: ['#d97706', 'solid'], loop: ['#db2777', 'dash'], writes: ['#ea580c', 'solid'], reads: ['#ea580c', 'dot'], triggers: ['#8b5cf6', 'dash'], has: ['#94a3b8', 'dot']};
const N = D.nodes.map((a, i) => ({i, l: a[0], k: a[1], g: a[2], ln: a[3], d: a[4], id: a[5], end: a[6] || 0, out: [], in: [], x: 0, y: 0, vx: 0, vy: 0, fx: null}));
const E = D.edges.map((a, i) => ({i, s: a[0], t: a[1], k: a[2], l: a[3], b: a[4], back: a[5]}));
E.forEach(e => { N[e.s].out.push(e); N[e.t].in.push(e) });
const G = D.files.map((f, i) => ({i, id: f.id, kind: f.kind, m: N.filter(n => n.g === i)}));
G.forEach(g => g.fn = g.m.find(n => n.k === 'file'));
N.forEach(n => { n.kk = n.k === 'file' ? 'file-' + (G[n.g].kind || 'doc') : n.k; if (!KD[n.kk]) n.kk = 'file-doc'; n.fam = KD[n.kk][0]; n.col = FAM[n.fam][1];
 n.r = n.k === 'file' ? 11 : 5 + Math.min(7, Math.sqrt(n.out.length + n.in.length)) });
// progressive levels: 0 = the crew (crew files, events, router rows), 1 = parts of files and commands, 2 = internals
const LV0 = n => (n.k === 'file' && n.fam === 'crew') || n.k === 'event' || /^AGENTS\.md#§Router\?$/.test(n.id);
const lvOf = n => LV0(n) ? 0 : n.k === 'decision' ? (/\.md#|^workflows\//.test(n.id) ? 1 : 2) : (n.k === 'file' || /slash|phase|call|step|section|cmd|timer|human|row/.test(n.k)) ? 1 : 2;
N.forEach(n => n.lv = lvOf(n));
const bad = new Map(); D.issues.forEach(it => it.node != null && bad.set(it.node, (bad.get(it.node) || []).concat(it)));
const famOn = Object.fromEntries(Object.keys(FAM).map(k => [k, true])), ekOn = Object.fromEntries(Object.keys(EK).map(k => [k, k !== 'has']));
const coll = new Set();
let LVL = 0, VN = [], VE = [], focus = null, fE = null, sel = null, force = new Set(), trace = null, tIdx = -1, hover = null, fitSc = 1;
// layout seed: files on a spiral by size, parts inside
let ang = 0, rad = 0;
[...G].sort((a, b) => b.m.length - a.m.length).forEach(g => { const R = 10 * Math.sqrt(g.m.length) + 30; rad += R * .55; ang += 2.4; const gx = Math.cos(ang) * rad, gy = Math.sin(ang) * rad;
 g.m.forEach(n => { const a = Math.random() * 6.28, d = Math.random() * R * .6; n.x = gx + Math.cos(a) * d; n.y = gy + Math.sin(a) * d }) });
function vis(n) { if (!famOn[n.fam]) return false; if (force.has(n)) return true; if (coll.has(n.g)) return n.k === 'file'; return n.lv <= LVL }
function rep(n) { if (vis(n)) return n; if (n.par && vis(n.par)) return n.par; const f = G[n.g].fn; return f && f !== n && vis(f) ? f : null }
N.forEach(n => { const b = n.in.find(e => e.k === 'branch' && N[e.s].k === 'decision'); if (n.k === 'row' && b) n.par = N[b.s] });
function rebuild() {
 VN = N.filter(vis); const seen = new Map(); VE = [];
 for (const e of E) { if (!ekOn[e.k]) continue; const a = rep(N[e.s]), b = rep(N[e.t]); if (!a || !b || (a === b && e.s !== e.t)) continue;
  const key = a.i + ',' + b.i + ',' + e.k; if (seen.has(key)) { seen.get(key).n++; continue } const v = {a, b, e, n: 1}; seen.set(key, v); VE.push(v) }
 $('#lv').querySelectorAll('.b').forEach((b, i) => b.classList.toggle('on', i === LVL)); heat(.15)
}
// force simulation: grid-binned repulsion + collision, springs, cohesion to the file's centroid (file hub sits on it), file-vs-file repulsion
let alpha = 1, raf = 0;
const heat = a => { alpha = Math.max(alpha, a); if (!raf) raf = requestAnimationFrame(frame) };
function tick() {
 for (const g of G) { g.cx = g.cy = g.c = 0 }
 for (const n of N) { if (n.k === 'file' && G[n.g].m.length > 1) continue; const g = G[n.g]; g.cx += n.x; g.cy += n.y; g.c++ }
 for (const g of G) if (g.c) { g.cx /= g.c; g.cy /= g.c; g.R = 9 * Math.sqrt(g.c) + 18; g.sx = g.sy = 0 }
 const C = 46, grid = new Map(), key = (a, b) => a * 73856093 ^ b * 19349663;
 for (const n of N) { const k = key(Math.floor(n.x / C), Math.floor(n.y / C)); (grid.get(k) || grid.set(k, []).get(k)).push(n) }
 for (const n of N) { const gx = Math.floor(n.x / C), gy = Math.floor(n.y / C);
  for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) for (const m of grid.get(key(gx + i, gy + j)) || []) {
   if (m.i <= n.i) continue; const dx = n.x - m.x, dy = n.y - m.y, d2 = dx * dx + dy * dy || .01, d = Math.sqrt(d2);
   let f = (n.g === m.g ? 30 : 120) / d2 * alpha; const mn = n.r + m.r + 4; if (d < mn) f += (mn - d) / d * .4;
   n.vx += dx * f; n.vy += dy * f; m.vx -= dx * f; m.vy -= dy * f } }
 for (const e of E) { const a = N[e.s], b = N[e.t]; if (a === b) continue; const same = a.g === b.g, L = same ? 22 : 180, s = (same ? .1 : .0015) * alpha;
  const dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy) || 1, f = (d - L) / d * s; a.vx += dx * f; a.vy += dy * f; b.vx -= dx * f; b.vy -= dy * f }
 const GL = G.filter(g => g.c);
 for (let i = 0; i < GL.length; i++) for (let j = i + 1; j < GL.length; j++) { const p = GL[i], q = GL[j], dx = p.cx - q.cx, dy = p.cy - q.cy, d = Math.hypot(dx, dy) || 1, m = p.R + q.R + 40;
  if (d < m) { const f = (m - d) / d * (.03 + .25 * alpha); p.sx += dx * f; p.sy += dy * f; q.sx -= dx * f; q.sy -= dy * f } }
 for (const g of GL) { g.sx -= g.cx * (.003 + .004 * alpha); g.sy -= g.cy * (.003 + .004 * alpha) }
 for (const n of N) { const g = G[n.g];
  if (n.k === 'file' && g.m.length > 1) { n.x = g.cx; n.y = g.cy; n.vx = n.vy = 0; continue }
  n.vx += (g.cx - n.x) * (.01 + .04 * alpha) + g.sx; n.vy += (g.cy - n.y) * (.01 + .04 * alpha) + g.sy;
  if (n.fx != null) { n.x = n.fx; n.y = n.fy; n.vx = n.vy = 0; continue } n.vx *= .55; n.vy *= .55; n.x += n.vx; n.y += n.vy }
 alpha *= .99
}
// view + semantic zoom (zoom level picks the detail level)
let tx = 0, ty = 0, sc = .3, W = 0, H = 0, dpr = 1;
const size = () => { const r = $('#main').getBoundingClientRect(), ow = W; W = r.width; H = r.height; dpr = devicePixelRatio || 1; cv.width = W * dpr; cv.height = H * dpr; if (ow) tx += (W - ow) / 2; draw() };
const s2w = (x, y) => [(x - tx) / sc, (y - ty) / sc];
function zoomLevel() { const z = sc / fitSc, L = z < 1.8 ? 0 : z < 4 ? 1 : 2; if (L !== LVL) { LVL = L; rebuild() } }
function hull(P) {
 P = P.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]); if (P.length < 3) return P;
 const cr = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]), lo = [], up = [];
 for (const p of P) { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p) }
 for (const p of P.reverse()) { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p) }
 return lo.slice(0, -1).concat(up.slice(0, -1))
}
function icon(name, x, y, s, col, lw) { X.save(); X.translate(x - s / 2, y - s / 2); X.scale(s / 24, s / 24); X.strokeStyle = col; X.lineWidth = lw * 24 / s; X.lineCap = X.lineJoin = 'round'; X.stroke(P2[name]); X.restore() }
function draw() {
 raf = 0; const cs = getComputedStyle(document.documentElement), bg = cs.getPropertyValue('--bg'), fg = cs.getPropertyValue('--fg'), hi = cs.getPropertyValue('--hi'), pn = cs.getPropertyValue('--pn');
 X.setTransform(dpr, 0, 0, dpr, 0, 0); X.fillStyle = bg; X.fillRect(0, 0, W, H); X.setTransform(dpr * sc, 0, 0, dpr * sc, dpr * tx, dpr * ty);
 const lw = 1 / sc, F = n => !focus || focus.has(n), x0 = -tx / sc, y0 = -ty / sc, x1 = x0 + W / sc, y1 = y0 + H / sc, on = n => n.x > x0 - 50 && n.x < x1 + 50 && n.y > y0 - 50 && n.y < y1 + 50;
 if (LVL > 0) for (const g of G) { if (!g.fn || coll.has(g.i)) continue; const m = g.m.filter(n => n.k !== 'file' && vis(n)); if (m.length < 2) continue;
  const h = hull(m.map(n => [n.x, n.y])); X.globalAlpha = focus && !m.some(F) ? .03 : .07; X.fillStyle = X.strokeStyle = g.fn.col; X.lineWidth = 34; X.lineJoin = 'round';
  X.beginPath(); h.forEach((p, i) => i ? X.lineTo(p[0], p[1]) : X.moveTo(p[0], p[1])); X.closePath(); X.fill(); X.stroke() }
 const lab = [];
 for (const v of VE) { const {a, b, e} = v; if (!on(a) && !on(b)) continue; const hl = fE ? fE.has(v) : false, dim = focus && !hl;
  const loopy = e.back || e.k === 'loop'; X.globalAlpha = hl ? .95 : dim ? .04 : LVL === 0 ? .45 : LVL === 1 ? .25 : .14;
  X.strokeStyle = X.fillStyle = hl ? hi : EK[e.k][0]; X.lineWidth = (hl ? 2 : loopy ? 1.4 : 1) * lw * (LVL === 0 ? 1.4 : 1);
  X.setLineDash(loopy || EK[e.k][1] === 'dash' ? [6 * lw, 4 * lw] : EK[e.k][1] === 'dot' ? [1.5 * lw, 3 * lw] : []); X.beginPath();
  let mx, my, ang;
  if (a === b) { X.arc(a.x + a.r, a.y - a.r, a.r + 4, 0, 6.283); mx = a.x + a.r; my = a.y - 2 * a.r - 6; ang = 0 }
  else { const dx = b.x - a.x, dy = b.y - a.y, c = loopy ? .35 : .1, cx = (a.x + b.x) / 2 - dy * c, cy = (a.y + b.y) / 2 + dx * c;
   X.moveTo(a.x, a.y); X.quadraticCurveTo(cx, cy, b.x, b.y); mx = (a.x + 2 * cx + b.x) / 4; my = (a.y + 2 * cy + b.y) / 4; ang = Math.atan2(b.y - cy, b.x - cx) }
  X.stroke(); X.setLineDash([]);
  if (a !== b && (hl || sc > .8 || LVL === 0)) { const d = b.r + 2, s = 6 * lw, hx = b.x - Math.cos(ang) * d, hy = b.y - Math.sin(ang) * d;
   X.beginPath(); X.moveTo(hx, hy); X.lineTo(hx - Math.cos(ang - .45) * s, hy - Math.sin(ang - .45) * s); X.lineTo(hx - Math.cos(ang + .45) * s, hy - Math.sin(ang + .45) * s); X.fill() }
  if (loopy && (hl || (e.k === 'loop' && LVL === 0 && !focus))) lab.push([mx, my, '↻' + (e.b ? ' ' + e.b : ''), '#db2777']);
  if (hl && fE.size < 120) lab.push([mx, my + 12 * lw, e.k + (e.l ? ' · ' + e.l : '') + (v.n > 1 ? ` (×${v.n})` : ''), fg]) }
 const big = sc * 8 > 3;
 for (const n of VN) { if (!on(n)) continue; const r = LVL === 0 ? (n.k === 'file' ? 16 : 11) : n.r; X.globalAlpha = F(n) ? 1 : .12;
  X.beginPath(); X.arc(n.x, n.y, r, 0, 6.283); X.fillStyle = pn; X.fill(); X.globalAlpha *= .22; X.fillStyle = n.col; X.fill(); X.globalAlpha = F(n) ? 1 : .12;
  const ring = bad.has(n.i) && (sel === n || (focus && focus.has(n))) ? '#dc2626' : n === sel ? hi : n.col; X.strokeStyle = ring; X.lineWidth = (n === sel || ring === '#dc2626' ? 2.5 : 1.2) * lw; X.stroke();
  if (r * sc > 5) icon(KD[n.kk][1], n.x, n.y, r * 1.15, n.col, Math.max(1.2 * lw, r * .12));
  if (n.fx != null) { X.fillStyle = fg; X.beginPath(); X.arc(n.x + r * .8, n.y - r * .8, 2.2 * lw, 0, 6.283); X.fill() } }
 X.textAlign = 'center';
 for (const n of VN) { if (!on(n)) continue; const r = LVL === 0 ? (n.k === 'file' ? 16 : 11) : n.r, show = n === sel || n === hover || (focus ? focus.has(n) && (focus.size < 150 || r * sc > 6) : (n.lv === LVL || n.k === 'file') && r * sc > 4.5 && big);
  if (!show) continue; X.globalAlpha = F(n) ? 1 : .2; X.font = `${n.k === 'file' ? 600 : 400} ${(n.k === 'file' ? 12 : 11) * lw}px system-ui`;
  X.lineWidth = 3 * lw; X.strokeStyle = bg; const t = n.l.slice(0, 40); X.strokeText(t, n.x, n.y + r + 12 * lw); X.fillStyle = fg; X.fillText(t, n.x, n.y + r + 12 * lw) }
 for (const [x, y, t, c] of lab) { X.globalAlpha = 1; X.font = `${10.5 * lw}px system-ui`; X.lineWidth = 3 * lw; X.strokeStyle = bg; X.strokeText(t.slice(0, 64), x, y); X.fillStyle = c; X.fillText(t.slice(0, 64), x, y) }
 if (trace) { X.font = `600 ${10 * lw}px system-ui`; const done = new Set();
  trace.forEach((s, i) => { const n = rep(s.n); if (!n || done.has(n)) return; done.add(n); const t = String(i + 1), w = (t.length * 6 + 8) * lw, bx = n.x + n.r * .7, by = n.y - n.r - 9 * lw;
   X.globalAlpha = 1; X.fillStyle = i === tIdx ? hi : n.col; X.beginPath(); X.roundRect ? X.roundRect(bx - w / 2, by - 7 * lw, w, 14 * lw, 7 * lw) : X.rect(bx - w / 2, by - 7 * lw, w, 14 * lw); X.fill();
   X.fillStyle = '#fff'; X.fillText(t, bx, by + 3.5 * lw) }) }
 X.globalAlpha = 1
}
function frame() { raf = 0; for (let i = 0; i < 2 && alpha > .02; i++) tick(); draw(); if (alpha > .02 || drag) raf = requestAnimationFrame(frame) }
function fitTo(ns) { ns = ns && ns.length ? ns : VN; if (!ns.length) return; const xs = ns.map(n => n.x), ys = ns.map(n => n.y), a = Math.min(...xs), b = Math.max(...xs), c = Math.min(...ys), d = Math.max(...ys);
 sc = Math.min((W - 60) / (b - a + 120), (H - 90) / (d - c + 120), 2.5); tx = W / 2 - (a + b) / 2 * sc; ty = 30 + (H - 30) / 2 - (c + d) / 2 * sc; draw() }
const center = n => { tx = W / 2 - n.x * sc; ty = H / 2 - n.y * sc; draw() };
function setLevel(L) { const cx = (W / 2 - tx) / sc, cy = (H / 2 - ty) / sc; sc = fitSc * [1, 2.4, 5][L]; tx = W / 2 - cx * sc; ty = H / 2 - cy * sc; LVL = L; rebuild() }
// focus: click = a node's direct neighbours (both ways); click a highlighted neighbour (or shift) = extend from it
function neigh(n, extend) {
 if (!extend || !focus) { focus = new Set([n]); fE = new Set() }
 if (!fE) fE = new Set()
 focus.add(n); for (const v of VE) if (v.a === n || v.b === n) { fE.add(v); focus.add(v.a); focus.add(v.b) } draw()
}
function select(n, extend) { sel = n; if (n) { neigh(n, extend); openSide('code') } else { focus = fE = null; draw() } }
function show(nodes, edgesToo) { force = new Set(nodes); rebuild(); focus = new Set(nodes.map(rep).filter(Boolean)); fE = new Set(VE.filter(v => focus.has(v.a) && focus.has(v.b))); draw() }
// trace: ordered walk from an entry; decisions follow the chosen outcome; loops shown once (cost: internals count double)
const PRI = {routes: 0, runs: 1, impl: 1, spawns: 2, branch: 3, triggers: 4, has: 5, calls: 6, writes: 7, loads: 8, next: 9, loop: 10}, COST = {calls: 2, has: 2, loads: 2, writes: 2}, choice = {};
function walk(start) {
 const steps = [], seen = new Set();
 (function go(n, dep, via) {
  if (steps.length > 300) return; seen.add(n); steps.push({n, dep, via}); if (dep >= 7) return;
  let outs = n.out.filter(e => PRI[e.k] != null && !(n.k === 'fn' && (e.k === 'has' || (e.k === 'calls' && N[e.t].k === 'fn')))).sort((a, b) => PRI[a.k] - PRI[b.k] || N[a.t].ln - N[b.t].ln);
  const br = outs.filter(e => e.k === 'branch'); if (n.k === 'decision' && br.length) outs = outs.filter(e => e.k !== 'branch').concat([br[Math.min(choice[n.i] || 0, br.length - 1)]]);
  for (const e of outs) { const t = N[e.t]; if (seen.has(t)) { if (e.back || e.k === 'loop') steps.push({n: t, dep: dep + 1, via: e, loop: 1}); continue } go(t, dep + (COST[e.k] || 1), e) }
 })(start, 0, null);
 return steps
}
function runTrace(start) { trace = walk(start); tIdx = 0; show(trace.map(s => s.n)); const ids = new Set(trace.map(s => s.via).filter(Boolean)); fE = new Set(VE.filter(v => [...ids].some(e => rep(N[e.s]) === v.a && rep(N[e.t]) === v.b)));
 fitTo([...focus]); tab('trace') }
function stepTo(i) { if (!trace) return; tIdx = Math.max(0, Math.min(trace.length - 1, i)); sel = trace[tIdx].n; center(rep(sel) || sel); if (curTab === 'trace') tab('trace'); else draw() }
// sidebar: rail tabs (Code, Trace, Loops, Issues), resizable, remembered
const side = $('#side'), sb = $('#sb'), esc = s => String(s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'})[c]);
const svgI = (name, col, s = 16) => `<svg class="ico" width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="${col || 'currentColor'}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="${IC[name]}"/></svg>`;
const TABS = {code: ['code', 'Code'], trace: ['route', 'Trace'], loops: ['loop', 'Loops'], issues: ['warn', 'Issues']};
let curTab = LS.get('tab', 'code'), sideW = LS.get('w', 420), sideOpen = false;
if (!D.issues.length) { delete TABS.issues; if (curTab === 'issues') curTab = 'code' }
for (const t in TABS) { const d = document.createElement('div'); d.className = 'ri'; d.dataset.t = t; d.title = TABS[t][1] + (t === 'issues' ? (D.dirty ? ' (uncommitted work: commit is blocked until 0)' : '') : ''); d.innerHTML = svgI(TABS[t][0], null, 20) + (t === 'issues' && D.issues.length ? `<span class="badge">${D.issues.length}</span>` : t === 'loops' ? `<span class="badge" style="background:#db2777">${D.cycles.length}</span>` : '');
 d.onclick = () => sideOpen && curTab === t ? closeSide() : openSide(t); $('#rail').append(d) }
function openSide(t) { curTab = t; LS.set('tab', t); if (!sideOpen) { sideOpen = true; side.style.width = sideW + 'px'; LS.set('open', true) } tab(t); setTimeout(size, 200) }
function closeSide() { sideOpen = false; side.style.width = '0'; LS.set('open', false); document.querySelectorAll('.ri').forEach(r => r.classList.remove('on')); setTimeout(size, 200) }
const fl = n => D.files[n.g].id + (n.ln ? ':' + n.ln : '');
const row = (n, title, extra, cls, fn) => { const d = document.createElement('div'); d.className = 'li ' + (cls || ''); d.innerHTML = (extra || '') + (n ? svgI(KD[n.kk][1], n.col) : '') + `<span class="t">${title}<span class="f">${n ? esc(fl(n)) : ''}</span></span>`; d.onclick = fn; return d };
function filterBox(ph, onq) { const s = document.createElement('div'); s.className = 'sticky'; const i = document.createElement('input'); i.className = 'b'; i.placeholder = ph; i.style.width = '100%'; i.oninput = () => onq(i.value.toLowerCase()); s.append(i); sb.append(s); return s }
function tab(t) {
 document.querySelectorAll('.ri').forEach(r => r.classList.toggle('on', r.dataset.t === t)); $('#sh').innerHTML = svgI(TABS[t][0], null, 16) + TABS[t][1]; sb.innerHTML = ''; $('#meta').style.display = 'none';
 if (t === 'code') return code(sel);
 if (t === 'trace') {
  const st = document.createElement('div'); st.className = 'sticky'; const se = document.createElement('select'); se.className = 'b'; se.style.flex = '1'; se.add(new Option('trace from… (agent, trigger, row, command)', ''));
  const ent = N.filter(n => /slash|event|human|timer|row/.test(n.k) || (n.k === 'file' && n.fam === 'crew'));
  ent.sort((a, b) => a.kk.localeCompare(b.kk) || a.l.localeCompare(b.l)).forEach(n => se.add(new Option(`${KD[n.kk][2]}: ${n.l}`.slice(0, 80), n.i)));
  se.value = trace ? trace[0].n.i : ''; se.onchange = () => se.value && runTrace(N[+se.value]); st.append(se);
  for (const [lab, d] of [['‹ prev', -1], ['next ›', 1]]) { const b = document.createElement('span'); b.className = 'b'; b.textContent = lab; b.onclick = () => stepTo(tIdx + d); st.append(b) }
  const b2 = document.createElement('span'); b2.className = 'b'; b2.textContent = 'from selected'; b2.onclick = () => sel && runTrace(sel); st.append(b2); sb.append(st);
  if (!trace) { sb.insertAdjacentHTML('beforeend', '<div class="empty">Pick an entry above (an agent, a trigger, a router row …) or select a node and press "from selected". The path is numbered on the graph; prev / next walk it; a decision step lets you switch the outcome.</div>'); return }
  trace.forEach((s, i) => { const n = s.n, d = row(n, `${s.loop ? '↻ back to ' : ''}${esc(n.l)}${s.via && !s.loop ? ` <small style="color:var(--mut)">${esc(s.via.k)}</small>` : ''}`,
   `<span class="num" style="padding-left:${Math.min(s.dep, 8) * 6}px">${i + 1}</span>`, (i === tIdx ? 'on ' : '') + (bad.has(n.i) ? 'bad' : ''), () => { stepTo(i); openSide('code') });
   const br = n.out.filter(e => e.k === 'branch');
   if (n.k === 'decision' && br.length > 1 && !s.loop) { const x = document.createElement('select'); x.className = 'b'; br.forEach((e, j) => x.add(new Option(`${e.l} → ${N[e.t].l}`.slice(0, 60), j)));
    x.value = choice[n.i] || 0; x.onclick = ev => ev.stopPropagation(); x.onchange = () => { choice[n.i] = +x.value; runTrace(trace[0].n) }; d.querySelector('.t').append(x) }
   sb.append(d) }); return
 }
 const list = document.createElement('div');
 const fill = q => { list.innerHTML = '';
  if (t === 'loops') { if (!D.cycles.length) list.innerHTML = '<div class="empty">No loops or cycles found.</div>';
   D.cycles.filter(c => !q || c.label.toLowerCase().includes(q)).forEach(c => { const n = N[c.nodes[0]];
    list.append(row(n, esc(c.label) + ` <small style="color:var(--mut)">${c.kind} · ${c.nodes.length} nodes${c.gaps && c.gaps.length ? ' · gaps: ' + esc(c.gaps.join('; ')) : ''}</small>`, '', c.gaps && c.gaps.length ? 'bad' : '',
     () => { trace = null; sel = n; show(c.nodes.map(i => N[i])); fitTo([...focus]) })) })
   if ((D.deliberate || []).length) { list.insertAdjacentHTML('beforeend', `<div class="grp">deliberate (marked flow:) · ${D.deliberate.length}</div>`);
    D.deliberate.filter(it => !q || (it.code + ' ' + it.text + ' ' + it.deliberate).toLowerCase().includes(q)).forEach(it => list.insertAdjacentHTML('beforeend',
     `<div class="empty" style="text-align:left">${esc(it.code)} ${esc(it.text)} <small style="color:var(--mut)">— ${esc(it.deliberate)}</small></div>`)) } }
  else { if (!D.issues.length) list.innerHTML = '<div class="empty">No unknown behaviour: every reference resolves, every outcome is handled, every loop has a bound.</div>';
   const by = {}; D.issues.filter(it => !q || (it.code + ' ' + it.text).toLowerCase().includes(q)).forEach(it => (by[it.code] = by[it.code] || []).push(it));
   for (const c in by) { list.insertAdjacentHTML('beforeend', `<div class="grp">${esc(c)} · ${by[c].length}</div>`);
    by[c].forEach(it => { const n = it.node != null ? N[it.node] : null; list.append(row(n, esc(it.text), '', 'bad', () => { if (n) { trace = null; show([n]); sel = n; neigh(n, true); center(n); openSide('code') } })) }) } } };
 filterBox(t === 'loops' ? 'filter loops…' : 'filter issues…', fill); sb.append(list); fill('')
}
// code view: the node's span from the sidecar source (loaded on first use), highlighted, its own line marked
const HL = {ps1: [/#.*$/, /\b(function|param|if|elseif|else|foreach|for|while|do|until|switch|return|break|continue|throw|try|catch|finally|exit|in)\b/, /\$[\w:]+/],
 py: [/#.*$/, /\b(def|class|if|elif|else|for|while|return|break|continue|raise|try|except|finally|with|as|import|from|in|not|and|or|lambda|yield|None|True|False)\b/, /\bself\b/],
 js: [/\/\/.*$/, /\b(const|let|var|function|async|await|if|else|for|while|do|return|break|continue|throw|try|catch|new|of|in|export|import|from|true|false|null)\b/, /\$\{[^}]*\}/],
 md: [/<!--.*-->/, /^#{1,6} .*|\*\*[^*]+\*\*/, /`[^`]+`/], json: [/$^/, /\b(true|false|null)\b/, /"[\w.-]+"(?=\s*:)/]};
function hl(line, lg) { const h = HL[lg] || HL.md, rx = new RegExp(`(${h[0].source})|('(?:[^'\\\\]|\\\\.)*'|"(?:[^"\\\\]|\\\\.)*")|(${h[1].source})|(${h[2].source})|(\\b\\d+(?:\\.\\d+)?\\b)`, 'g');
 let out = '', last = 0; line.replace(rx, (m, c, s, k, v, nu, off) => { out += esc(line.slice(last, off)) + `<span class="${c ? 'cm' : s ? 'st' : k ? 'kw' : v ? 'va' : 'nu'}">${esc(m)}</span>`; last = off + m.length; return m });
 return out + esc(line.slice(last)) }
let srcWanted = null, more = 0;
function code(n) {
 if (!n) { sb.innerHTML = '<div class="empty">Click a node on the graph: its source span shows here, with its line marked.</div>'; return }
 const f = D.files[n.g].id, real = !f.startsWith('('), abs = (D.kit + '/' + f).replace(/\\/g, '/'), ln = n.ln || 1;
 $('#sh').innerHTML = svgI(KD[n.kk][1], n.col, 18) + `<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(n.l)}</span><small style="color:var(--mut);font-weight:400">${esc(KD[n.kk][2])}</small>`;
 const m = $('#meta'); m.style.display = 'block'; const iss = bad.get(n.i) || [];
 m.innerHTML = `<div class="f">${esc(f)}${n.ln ? ':' + n.ln : ''}</div>${n.d ? `<div>${esc(n.d)}</div>` : ''}${iss.map(it => `<div style="color:var(--bad)">⚠ ${esc(it.code)}: ${esc(it.text)}</div>`).join('')}
  <div>${n.out.length} out · ${n.in.length} in${real ? ` · ${D.kit ? `<a href="vscode://file/${encodeURI(abs)}:${ln}">open in editor</a>` : ''}${D.repoUrl ? `<a target="_blank" rel="noopener" href="${D.repoUrl}/${encodeURI(f)}#L${ln}">view on GitHub</a>` : ''}<span class="lnk" id="cp">copy path:line</span>` : ''}</div>`;
 if (real) $('#cp').onclick = () => { const t = `${f}:${ln}`; (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).catch(() => { const a = document.createElement('textarea'); a.value = t; document.body.append(a); a.select(); document.execCommand('copy'); a.remove() }); $('#cp').textContent = 'copied' };
 if (!real) { sb.innerHTML = '<div class="empty">A shared node (state, config, outcome or external CLI): no single source span. Its edges on the graph show who reads, writes or calls it.</div>'; return }
 if (!window.KF_SRC) { sb.innerHTML = '<div class="empty">loading source…</div>'; if (!srcWanted && D.src) { srcWanted = document.createElement('script'); srcWanted.src = D.src; srcWanted.onload = () => curTab === 'code' && code(sel); srcWanted.onerror = () => sb.innerHTML = '<div class="empty">Source sidecar not found next to this page.</div>'; document.head.append(srcWanted) } return }
 const lines = (window.KF_SRC[f] || '').split('\n'), lg = {ps1: 'ps1', psm1: 'ps1', py: 'py', js: 'js', mjs: 'js', md: 'md', json: 'json', sh: 'py'}[f.split('.').pop()] || 'md';
 let end = n.end; if (!end) { const nx = G[n.g].m.filter(o => o.ln > ln && o.k !== 'file').map(o => o.ln); end = nx.length ? Math.min(...nx) - 1 : lines.length }
 if (n.k === 'file') end = lines.length; const a = Math.max(1, ln - (n.k === 'file' ? 0 : 2)), cap = a + 80 + more;
 sb.innerHTML = ''; const pre = document.createElement('pre'); pre.style.padding = '8px 0';
 pre.innerHTML = lines.slice(a - 1, Math.min(end, cap)).map((l, i) => `<div class="cl${a + i === ln ? ' me' : ''}"><span class="n">${a + i}</span><span class="x">${hl(l, lg)}</span></div>`).join('');
 sb.append(pre); if (end > cap) { const b = document.createElement('div'); b.className = 'empty'; b.innerHTML = `<span class="lnk">show more (${end - cap} lines)</span>`; b.onclick = () => { more += 80; code(n) }; sb.append(b) }
 const me = pre.querySelector('.me'); if (me) me.scrollIntoView({block: 'center'})
}
// resize the sidebar: drag its left edge (280 px .. 70 %), double-click resets
$('#grip').onpointerdown = e => { e.preventDefault(); side.classList.add('drag'); const mv = ev => { sideW = Math.max(280, Math.min(innerWidth * .7, innerWidth - 44 - ev.clientX)); side.style.width = sideW + 'px'; size(); if (sel) center(rep(sel) || sel) };
 const up = () => { side.classList.remove('drag'); LS.set('w', sideW); removeEventListener('pointermove', mv); removeEventListener('pointerup', up) }; addEventListener('pointermove', mv); addEventListener('pointerup', up) };
$('#grip').ondblclick = () => { sideW = 420; side.style.width = sideW + 'px'; LS.set('w', sideW); setTimeout(size, 200) };
// top bar: level, Show (families), Edges (kinds), search, legend key
['Overview', 'Detail', 'Everything'].forEach((t, i) => { const b = document.createElement('span'); b.className = 'b'; b.textContent = t; b.onclick = () => setLevel(i); $('#lv').append(b) });
function menu(id, items, state, label) { const dd = $(id), m = dd.querySelector('.menu'); dd.firstElementChild.onclick = e => { e.stopPropagation(); document.querySelectorAll('.dd').forEach(x => x !== dd && x.classList.remove('open')); dd.classList.toggle('open') };
 m.onclick = e => e.stopPropagation();
 for (const [k, html, c] of items) { const l = document.createElement('label'); l.innerHTML = `<input type="checkbox" ${state[k] ? 'checked' : ''}>${html}<small>${c}</small>`; l.firstChild.onchange = ev => { state[k] = ev.target.checked; rebuild() }; m.append(l) } }
menu('#ddS', Object.keys(FAM).map(f => [f, `${svgI(Object.values(KD).find(k => k[0] === f)[1], FAM[f][1])} ${FAM[f][0]}`, N.filter(n => n.fam === f).length]), famOn);
menu('#ddE', Object.keys(EK).filter(k => E.some(e => e.k === k)).map(k => [k, `<svg width="26" height="8"><line x1="1" y1="4" x2="25" y2="4" stroke="${EK[k][0]}" stroke-width="2" ${EK[k][1] === 'dash' ? 'stroke-dasharray="6 4"' : EK[k][1] === 'dot' ? 'stroke-dasharray="1.5 3"' : ''}/></svg> ${k}`, E.filter(e => e.k === k).length]), ekOn);
const leg = $('#leg'), cnt = k => N.filter(n => n.kk === k).length;
leg.innerHTML = '<h4 style="margin-top:0">Nodes</h4><div class="g">' + Object.keys(KD).filter(cnt).map(k => `<span class="it">${svgI(KD[k][1], FAM[KD[k][0]][1])}${esc(KD[k][2])} <small style="color:var(--mut)">${cnt(k)}</small></span>`).join('') +
 '</div><h4>Edges</h4><div class="g">' + Object.keys(EK).filter(k => E.some(e => e.k === k)).map(k => `<span class="it"><svg width="22" height="8"><line x1="1" y1="4" x2="21" y2="4" stroke="${EK[k][0]}" stroke-width="2" ${EK[k][1] === 'dash' ? 'stroke-dasharray="5 3"' : EK[k][1] === 'dot' ? 'stroke-dasharray="1.5 3"' : ''}/></svg>${k}</span>`).join('') +
 '</div><h4>Families</h4><div class="g">' + Object.values(FAM).map(f => `<span class="it"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="${f[1]}"/></svg>${f[0]}</span>`).join('') + '</div>';
$('#legb').innerHTML = svgI('key', null, 18); $('#legb').onclick = e => { e.stopPropagation(); leg.classList.toggle('open') }; $('#legb').onmouseenter = () => leg.classList.add('open'); leg.onclick = e => e.stopPropagation();
addEventListener('click', () => { leg.classList.remove('open'); document.querySelectorAll('.dd').forEach(x => x.classList.remove('open')) });
$('#q').oninput = () => { const q = $('#q').value.trim().toLowerCase(); trace = null; if (!q) { force = new Set(); focus = fE = null; return rebuild() } show(N.filter(n => (n.l + ' ' + n.id).toLowerCase().includes(q)).slice(0, 300)) };
$('#q').onkeydown = e => { if (e.key === 'Enter' && focus && focus.size) { const n = [...focus][0]; select(n); center(n) } };
$('#fit').onclick = () => { fitTo(); fitSc = sc; LVL = 0; rebuild() };
// pointer: pan, drag a node (pins it; right-click unpins), click = neighbours (+code), click a highlighted node or shift = extend, double-click = collapse its file
let drag = null;
const hit = (sx, sy) => { const [x, y] = s2w(sx, sy); let best = null, bd = 1e9; for (const n of VN) { const r = LVL === 0 ? (n.k === 'file' ? 16 : 11) : n.r, d = Math.hypot(n.x - x, n.y - y); if (d < r + 4 / sc && d < bd) { bd = d; best = n } } return best };
const pt = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top] };
cv.addEventListener('pointerdown', e => { const [x, y] = pt(e), n = hit(x, y); drag = {n, x, y, tx, ty, moved: false}; cv.setPointerCapture(e.pointerId) });
cv.addEventListener('pointermove', e => { const [x, y] = pt(e);
 if (!drag) { const n = hit(x, y); if (n !== hover) { hover = n; draw() }
  if (n) { tip.style.display = 'block'; tip.style.left = Math.min(e.clientX + 14, innerWidth - 390) + 'px'; tip.style.top = e.clientY + 14 + 'px'; tip.textContent = `${n.l}\n${KD[n.kk][2]} · ${fl(n)}${bad.has(n.i) ? '\n⚠ ' + bad.get(n.i)[0].code : ''}` } else tip.style.display = 'none'; return }
 const dx = x - drag.x, dy = y - drag.y; if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true; if (!drag.moved) return;
 if (drag.n) { const [wx, wy] = s2w(x, y); drag.n.fx = wx; drag.n.fy = wy; heat(.2) } else { tx = drag.tx + dx; ty = drag.ty + dy; draw() } });
cv.addEventListener('pointerup', e => { if (drag && !drag.moved) { const n = drag.n; if (!n) { sel = null; focus = fE = null; trace = null; force = new Set(); rebuild() } else select(n, e.shiftKey || (focus && focus.has(n) && n !== sel)) } drag = null });
cv.addEventListener('dblclick', e => { const n = hit(...pt(e)); if (!n || !G[n.g].fn) return; coll.has(n.g) ? coll.delete(n.g) : coll.add(n.g); rebuild() });
cv.addEventListener('contextmenu', e => { const n = hit(...pt(e)); if (n) { e.preventDefault(); n.fx = n.fy = null; heat(.2) } });
cv.addEventListener('wheel', e => { e.preventDefault(); const [x, y] = pt(e), f = Math.exp(-e.deltaY * .0015); tx = x - (x - tx) * f; ty = y - (y - ty) * f; sc *= f; zoomLevel(); draw() }, {passive: false});
addEventListener('keydown', e => { if (e.key === 'Escape') { leg.classList.remove('open'); sel = null; trace = null; focus = fE = null; force = new Set(); $('#q').value = ''; rebuild() }
 if (trace && (e.key === 'ArrowRight' || e.key === 'ArrowLeft') && document.activeElement.tagName !== 'INPUT') stepTo(tIdx + (e.key === 'ArrowRight' ? 1 : -1)) });
new ResizeObserver(size).observe($('#main'));
rebuild(); for (let i = 0; i < 420; i++) tick(); size(); fitTo(); fitSc = sc; draw(); if (LS.get('open', false)) openSide(curTab);
window.KF = {N, G, D, select, runTrace, stepTo, setLevel, openSide, closeSide, show, fitTo, center, get sc() { return sc }};
</script></body></html>
'''

# ==== 3. flow: the HTML page and the README graph sections
def live_root(kit):
    """The main worktree of kit's repo (the live clone): a worktree's commit or lint refreshes the page the owner opens."""
    try:
        r = subprocess.run(['git', '-C', kit, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
            capture_output=True, text=True, encoding='utf-8', timeout=15)
        main = osp.dirname(osp.normpath(r.stdout.strip())) if r.returncode == 0 and r.stdout.strip() else ''
        if main and osp.isfile(osp.join(main, PATHS_JSON)):
            return main
    except (OSError, subprocess.TimeoutExpired):
        pass
    return kit

def default_out(kit):
    return kit_path('kit-flow', kit=live_root(kit))

def flow_args(a):
    out = a[a.index('--out') + 1] if '--out' in a else None
    rest = [x for i, x in enumerate(a) if not x.startswith('--') and (i == 0 or a[i - 1] not in ('--out', '--minutes'))]
    kit = osp.abspath(rest[0] if rest else KIT_DIR)
    return kit, osp.abspath(out or default_out(kit)), '--watch' in a, '--open' in a, '--readme' in a, '--public' in a

def page_data(k, g, problems, kit=None):
    """Page model (section 2b): the parts inside every file, the edges between them, loops, issues."""
    live = live_root(kit or k.dir)
    data = model(k, problems, kit_path('kit-flow-cache', kit=live))
    data['kit'], data['_texts'] = live.replace('\\', '/'), {f: k.texts.get(f, '') for f in k.files}
    return data

def public_only(k):
    """--public (the published page): drop every local-only file (kit.local.json localOnly, *.local.*, rules/*.local.md)."""
    keep = [f for f in k.files if '.local.' not in osp.basename(f) and not any(f == x or f.startswith(x.rstrip('/') + '/') for x in k.local_only)]
    k.files, k.fileset = keep, set(keep)
    k.texts = {f: t for f, t in k.texts.items() if f in k.fileset}
    k.skills = [x for x in k.skills if f'skills/{x}/SKILL.md' in k.fileset]
    k.agents = {n: f for n, f in k.agents.items() if f in k.fileset}
    k.workflows = {n: f for n, f in k.workflows.items() if f in k.fileset}
    return k

def build(kit, public=False):
    k = load(kit)
    if public:
        k = public_only(k)
    g = graph(k)
    data = page_data(k, g, lint(k, g))
    if public:   # no local paths; code links go to the CI repo host
        repo, sha = os.environ.get('GITHUB_REPOSITORY'), os.environ.get('GITHUB_SHA')
        data['kit'], data['repoUrl'] = '', (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/blob/{sha}" if repo and sha else '')
    return data

def render(kit, out, quiet=False, data=None, public=False):
    data = data or build(kit, public)
    os.makedirs(osp.dirname(out), exist_ok=True)
    write(out, data, data.pop('_texts', {}))
    c = data['counts']
    if not quiet:
        print(f"kit-flow: {out}  ({c['files']} files, {c['nodes']} nodes, {c['edges']} edges, {c['cycles']} loops, {c['issues']} issues)")
    return data

def signature(kit):
    sig = []
    for d, dirs, fs in os.walk(kit):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in fs:
            try:
                st = os.stat(osp.join(d, f))
                sig.append((d, f, st.st_mtime_ns, st.st_size))
            except OSError:
                pass
    return hash(tuple(sorted(sig)))

def cmd_flow(a):
    kit, out, watch, open_it, readme, public = flow_args(a)
    if not osp.isdir(kit):
        sys.exit(f'kittool flow: no such folder {kit}')
    if readme:
        k = load(kit)
        g = graph(k)
        p = osp.join(kit, 'README.md')
        old = read(p)
        new = update_readme(old, readme_sections(k, g))
        if new != old.replace('\r\n', '\n'):
            with open(p, 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(new)
            print(f'kittool flow: README.md graph sections updated')
    render(kit, out, public=public)
    if open_it:
        if sys.platform.startswith('win'):
            os.startfile(out)  # type: ignore[attr-defined]  # noqa
        else:
            subprocess.run(['open' if sys.platform == 'darwin' else 'xdg-open', out], check=False)
    if watch:
        mins = float(a[a.index('--minutes') + 1]) if '--minutes' in a else 0
        end = time.time() + mins * 60 if mins else None
        print(f'kittool flow: watching for changes ({f"{mins:g} min" if mins else "until Ctrl+C"})')
        last = signature(kit)
        while end is None or time.time() < end:   # flow: unbounded on purpose without --minutes - watch mode until Ctrl+C
            time.sleep(2)
            cur = signature(kit)
            if cur != last:
                last = cur
                try:
                    render(kit, out, public=public)
                except Exception as e:  # keep watching through a half-written file
                    print('kittool flow: render failed, will retry:', e)
    return 0

# ==== 4. lint
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
    KIT = osp.abspath(args[0] if args else KIT_DIR)

    terms = None
    if ORG:
        if osp.isfile(ORG):
            try:
                with open(str(ORG), encoding='utf-8') as fh:
                    terms = json.load(fh).get('orgTerms') or []
            except ValueError:
                sys.exit(f'kittool lint: {ORG} is not valid JSON')
        else:
            terms = [t for t in str(ORG).split(',') if t.strip()]

    k = load(KIT)
    g = graph(k)
    problems = lint(k, g, terms)
    data = None
    try:   # the flow graph's own issues gate the commit too (a `flow: <reason>` marker at the source line makes one deliberate)
        if WARN and NOFLOW:
            raise StopIteration   # report-only, no page (SessionStart, pre-push, audit scan): skip the model, stay fast
        data = page_data(k, g, problems)
        problems += [('FLOW-' + it['code'], 'flow', it['text']) for it in data['issues'] if it.get('flow')]
    except StopIteration:
        pass
    except Exception as e:  # noqa - a model crash is itself a problem
        problems.append(('FLOW-MODEL', 'kittool.py', f'the flow model failed: {e}'))
    if not NOFLOW and data:   # keep the flow page current
        try:
            render(KIT, default_out(KIT), quiet=bool(SUMMARY), data=data)
        except Exception as e:  # a convenience: never fail the lint
            print(f'kittool lint: flow page not regenerated: {e}', file=sys.stderr)

    if JSON_OUT:
        with open(str(JSON_OUT), 'w', encoding='utf-8') as fh:
            json.dump([{'code': c, 'where': w, 'problem': m} for c, w, m in problems], fh, indent=1)
    if SUMMARY:
        if problems:
            c, w, m = problems[0]
            print(f'kittool lint: {len(problems)} problem(s), e.g. {c} {w}: {m} (list: python {osp.abspath(__file__)} lint)')
    else:
        for c, w, m in problems:
            print(f'{c:15} {w}: {m}')
        print(f'kittool lint: {len(problems)} problem(s) in {KIT} ({len(k.files)} files, {len(k.skills)} skills, '
         f'{len(k.workflows)} workflows, {len(k.agents)} agents)')
    return 1 if problems and not WARN else 0

# ==== 5. port: Codex / Antigravity agents, hooks, workflows
# KIT = this file's kit: a second clone / worktree ports its own files
KIT = Path(__file__).resolve().parents[2]          # canonical, pushable
WORKSPACE = KIT.parent                             # where the CLIs look (deployed copies)
CLAUDE_AGENTS = KIT / "agents"
CLAUDE_WORKFLOWS = KIT / "workflows"
CLAUDE_SETTINGS = KIT / "settings.json"

# ports are written under KIT (pushed), deploy() copies them to WORKSPACE: agy / codex read only the session cwd
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
    # learn.chatgpt.com/docs/agent-configuration/subagents (2026-10-13): no tools array; read-only tools -> "read-only"
    sandbox_line = ""
    if fields.get("tools") and "Edit" not in fields["tools"] and "Write" not in fields["tools"]:
        sandbox_line = 'sandbox_mode = "read-only"\n'
    content = (
     f'name = "{name}"\n'
     f'description = {json.dumps(fields["description"], ensure_ascii=False)}\n'
     f"{sandbox_line}"
     f'developer_instructions = """\n{toml_escape(body)}\n"""\n'
    )
    (CODEX_AGENTS / f"{name}.toml").write_text(content, encoding="utf-8", newline="\n")

def write_gravity(name, fields, body):
    # antigravity.google/docs/subagents (2026-10-13): own tool names, a mismapped one hangs: leave unset, note it
    frontmatter = [
     f"name: {name}",
     f'description: {json.dumps(fields["description"], ensure_ascii=False)}',
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
    (GRAVITY_AGENTS / f"{name}.md").write_text(content, encoding="utf-8", newline="\n")

def prune(folder, suffix, keep):
    """Drop a port the kit no longer generates (a removed or renamed agent / workflow): no stale alias survives."""
    for p in folder.glob('*' + suffix) if folder.exists() else []:
        if p.stem not in keep:
            p.unlink()

def port_agents():
    CODEX_AGENTS.mkdir(parents=True, exist_ok=True)
    GRAVITY_AGENTS.mkdir(parents=True, exist_ok=True)
    count, made = 0, set()
    for src in sorted(CLAUDE_AGENTS.glob("*.md")):
        fields, body = parse_frontmatter(src.read_text(encoding="utf-8"))
        name = fields.get("name", src.stem)
        write_codex(name, fields, body)
        write_gravity(name, fields, body)
        made.add(name)
        count += 1
    prune(CODEX_AGENTS, '.toml', made)
    prune(GRAVITY_AGENTS, '.md', made)
    print(f"ported {count} agent(s) -> .codex/agents/*.toml, .agents/agents/*.md")

def port_hooks():
    """Point each tool's hook config at the same scripts (dev.ps1 guard, orch.ps1 health / cleanup): one implementation.
    Not ported: the SendMessage guard (no Codex/Antigravity tool to match it)."""
    # SessionStart of settings.json minus the cosmetic `orch.ps1 health -Flow -Fetch`
    session_start_cmds = [
     ("orch.ps1 health", 15),
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
     encoding="utf-8", newline="\n",
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
                    # handlers directly under the event, no matcher wrapper (antigravity.google/docs/hooks)
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
     encoding="utf-8", newline="\n",
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
    count, made = 0, set()
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
         encoding="utf-8", newline="\n",
        )
        (GRAVITY_WORKFLOWS / f"{fields['name']}.md").write_text(
         workflow_procedure_doc(
          fields, "Antigravity",
          "delegate each phase to the matching subagent in `.agents/agents/*.md` "
          "yourself, in the phase order below.",
         ),
         encoding="utf-8", newline="\n",
        )
        made.add(fields['name'])
        count += 1
    prune(CODEX_WORKFLOWS, '.md', made)
    prune(GRAVITY_WORKFLOWS, '.md', made)
    print(f"ported {count} workflow procedure doc(s) -> .codex/workflows/*.md, .agents/workflows/*.md")

def port_deploy():
    """Copy .claude/.codex and .claude/.agents to the workspace root, where codex / agy look (session cwd, not .claude):
    a deploy target, not a second source of truth."""
    if KIT.name != '.claude':   # second clone / worktree: no workspace above
        print(f"not deployed: {KIT} is not a workspace's .claude folder (the ports inside the kit are updated)")
        return
    deployed = []
    for src_dir, dst_dir in ((KIT / ".codex", WORKSPACE / ".codex"), (KIT / ".agents", WORKSPACE / ".agents")):
        for p in stale_generated(src_dir, dst_dir):
            p.unlink()   # a port no longer generated; user files stay
        for p in src_dir.rglob('*'):
            if p.is_file():
                t = dst_dir / p.relative_to(src_dir)
                t.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, t)
        deployed.append(dst_dir)
    # AGENTS.md/GEMINI.md: the CLIs search up from the cwd, never into .claude
    for name in ("AGENTS.md", "GEMINI.md"):
        dst = WORKSPACE / name
        shutil.copyfile(KIT / name, dst)
        deployed.append(dst)
    print(f"deployed -> {', '.join(str(p) for p in deployed)}")

def stale_generated(src, dst):
    """Workspace files in agents/ or workflows/ of dst with no kit counterpart: ports of a removed agent / workflow."""
    if not dst.exists():
        return []
    have = {p.relative_to(src).as_posix() for p in src.rglob('*') if p.is_file()} if src.exists() else set()
    return [p for p in dst.rglob('*') if p.is_file() and p.relative_to(dst).parts[0] in ('agents', 'workflows')
      and p.suffix in ('.toml', '.md') and p.relative_to(dst).as_posix() not in have]

def deployed_stale():
    """port_deploy's workspace copies (.codex, .agents, AGENTS.md, GEMINI.md) that differ from the kit; [] when the kit is
    not an installed <workspace>/.claude (a worktree or second clone deploys nothing)."""
    if KIT.name != '.claude':
        return []
    bad = []
    for name in ('.codex', '.agents'):
        src, dst = KIT / name, WORKSPACE / name
        a = {p.relative_to(src).as_posix(): p.read_bytes() for p in src.rglob('*') if p.is_file()} if src.exists() else {}
        b = {r: (dst / r).read_bytes() for r in a if (dst / r).is_file()}   # only kit-deployed files
        if a != b or stale_generated(src, dst):
            bad.append(name + '/')
    for name in ('AGENTS.md', 'GEMINI.md'):
        if not (WORKSPACE / name).exists() or (WORKSPACE / name).read_bytes() != (KIT / name).read_bytes():
            bad.append(name)
    return bad

def check_stale():
    """--check: exit 1 if .codex/.agents would change, without writing (orch.ps1 health, SessionStart). Generates every port
    into a temp copy and compares contents (existence alone missed every edit)."""
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
        made = set()
        for f in sorted(Path(tmp).rglob("*")):
            if f.is_file():
                rel = f.relative_to(tmp)
                made.add(rel.as_posix())
                have = KIT / rel
                if not have.exists() or have.read_text(encoding="utf-8") != f.read_text(encoding="utf-8"):
                    stale.append(str(rel).replace("\\", "/"))
        for d in (CODEX_AGENTS, GRAVITY_AGENTS, CODEX_WORKFLOWS, GRAVITY_WORKFLOWS):   # a port of a removed part
            for p in d.glob('*') if d.exists() else []:
                if p.is_file() and p.relative_to(KIT).as_posix() not in made:
                    stale.append(p.relative_to(KIT).as_posix() + ' (no source)')
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
    write_characters(str(KIT))
    port_agents()
    port_hooks()
    port_workflows()
    (KIT / 'GEMINI.md').write_text(GEMINI_MD, encoding='utf-8', newline='\n')
    port_deploy()
    return 0

# ==== 6. audit (mechanical half)
OWN = KIT_DIR

# (example file or localFiles entry, local file, what it holds)
PAIRS = [('skills/dev-kit/kit.example.json', 'skills/dev-kit/kit.local.json', 'org settings (tracker, repos, reports, ...)'),
  ('localFiles:skills/qa-kit/targets.local.json', 'skills/qa-kit/targets.local.json', 'QA targets and test logins (secrets)'),
  ('localFiles:skills/android-swarm/swarm.config.json', 'skills/android-swarm/swarm.config.json', 'Android emulator lanes')]

def example_of(ex_rel):
    ex, err = load_json(osp.join(OWN, 'skills/dev-kit/kit.example.json'))
    if not ex_rel.startswith('localFiles:'):
        return {k: v for k, v in (ex or {}).items() if k != 'localFiles'}, err
    return ((ex or {}).get('localFiles') or {}).get(ex_rel[len('localFiles:'):]), err
# example value IS the default: --fill may write it
SAFE_DEFAULTS = {'kitAudit.everyDays', 'cleanup.maxBrowserProfiles', 'supervise.ramActPct', 'supervise.minDiskFreeGB',
    'build.mavenOffline', 'gate.heapMinGB'}
# user-named subtrees (or samples): never "missing"
USER_MAPS = ('localEnv', 'repos', 'repoAliases', 'targets', 'linkFromByTarget', 'tracker.statuses', 'tracker._examples', 'gate.startHeapGB', 'lanes', 'app', 'localFiles', 'deploy.minIntervalHours', 'tests', 'qa.targets')   # qa.targets: group names are the org's
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
    if not osp.isfile(path):
        return None, 'missing'
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f), None
    except json.JSONDecodeError as e:
        return None, f'invalid JSON ({e.msg}, line {e.lineno})'
    except (UnicodeDecodeError, OSError) as e:
        return None, f'unreadable ({e})'

def live_kit():
    """The installed clone: the main worktree of this script's repo (an audit worktree checks the live kit, not itself)."""
    rc, common, _ = git(OWN, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if rc == 0 and common:
        main = osp.dirname(osp.normpath(common))
        if osp.isfile(osp.join(main, PATHS_JSON)):
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
        with open(osp.join(kit, rel), encoding='utf-8', errors='replace') as f:
            return f.read().replace('\r\n', '\n')
    except OSError:
        return ''

def strip_ps_comments(text):
    text = re.sub(r'<#.*?#>', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return '\n'.join(re.sub(r'(^|\s)#(?![>{]).*$', r'\1', l) if not re.search(r"""['"][^'"]*#""", l) else l for l in text.split('\n'))

def config_doc_keys(kit):
    doc = section(aread(kit, 'README.md'), 'Configuration') or ''
    keys = set(re.findall(r'`([A-Za-z][\w]*(?:\.[\w]+)*)', doc))
    for row in doc.split('\n'):   # sub-keys named in a row's Meaning cell -> tracker.statuses
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
        use = pats if loads else pats[:3]   # $cfg.<key> = kit.local.json only where loaded
        for ln, line in enumerate(text.split('\n'), 1):
            for rx in use:
                for m in rx.finditer(line):
                    keys.setdefault(m.group(1), f'{f}:{ln}')
    return keys

# ---- setup
def cmd_setup(kit, fix):
    if not osp.isdir(osp.join(kit, '.git')) and not osp.isfile(osp.join(kit, '.git')):
        out('ACT', 'SETUP-CLONE', kit, 'not a git clone of the kit repo', 'README "Install": git clone <kit repo> <workspace>/.claude')
        return
    setup_ps = osp.join(kit, 'skills', 'orchestrate', 'orch.ps1')
    need_setup = []
    rc, hp, _ = git(kit, 'config', 'core.hooksPath')
    if hp != '.githooks':
        need_setup.append('core.hooksPath is not .githooks (pre-push gate off)')
    cfg, _ = load_json(osp.join(kit, 'skills/dev-kit/kit.local.json'))
    rc, ex, _ = git(kit, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude')
    excl = open(ex, encoding='utf-8', errors='replace').read() if rc == 0 and osp.isfile(ex) else ''
    miss = [p for p in ((cfg or {}).get('localOnly') or []) if f"/{p.replace(chr(92), '/').strip('/')}" not in excl]
    if miss:
        need_setup.append(f'{len(miss)} localOnly path(s) not in .git/info/exclude')
    for n in ('work', 'cache', 'logs'):
        if not osp.isdir(kit_path(n, kit=kit)):
            need_setup.append(f'runtime folder {n}/ missing')
    if need_setup:
        if fix:
            rc, o, e = pwsh(setup_ps, 'setup', timeout=120)
            out('FIX' if rc == 0 else 'ACT', 'SETUP-INSTALL', 'orch.ps1 setup', '; '.join(need_setup) + ('' if rc == 0 else f' (orch.ps1 setup failed: {e[:200]})'))
        else:
            out('ACT', 'SETUP-INSTALL', kit, '; '.join(need_setup), f'pwsh -File {setup_ps} setup')
    for ex_rel, loc_rel, what in PAIRS:
        if not osp.isfile(osp.join(kit, loc_rel)):
            lvl = 'ASK' if loc_rel.endswith('kit.local.json') else 'INFO'
            out(lvl, 'SETUP-CONFIG', loc_rel, f'missing ({what})', 'orch.ps1 setup -WriteLocal, then fill it (the config step lists the keys)')
    # hooks: scripts exist; sync SessionStart ones run clean, fast, valid JSON or nothing
    sj, err = load_json(osp.join(kit, 'settings.json'))
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
                path = osp.join(kit, rel)
                if not osp.isfile(path):
                    out('ACT', 'SETUP-HOOKS', f'settings.json {event}', f'{rel} does not exist')
                    continue
                if event != 'SessionStart' or h.get('async'):
                    continue
                hargs = list(h.get('args', []))
                extra = hargs[hargs.index('-File') + 2:] if '-File' in hargs else []   # verb + flags after the script path
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
    sl = osp.join(kit, 'settings.local.json')
    if osp.isfile(sl) and load_json(sl)[1]:
        out('ACT', 'SETUP-CONFIG', 'settings.local.json', load_json(sl)[1])
    # Codex / Antigravity ports + deployed copies
    pk = osp.join(kit, 'skills', 'orchestrate', 'kittool.py')
    if osp.isfile(pk):
        rc, o, e = run([py(), '-X', 'utf8', pk, 'port', '--check'], timeout=60)
        if rc:
            out('ACT', 'SETUP-PORTS', 'kittool.py port --check', (o or e)[:300], f'python -X utf8 {pk} port (in the clone that changed, then commit)')
    ws = osp.dirname(kit)
    for n in ('AGENTS.md', 'GEMINI.md'):
        src, dst = osp.join(kit, n), osp.join(ws, n)
        if osp.isfile(src) and (not osp.isfile(dst) or aread(kit, n) != aread(ws, n)):
            out('WARN', 'SETUP-PORTS', f'<workspace>/{n}', 'missing or differs from the kit copy (Codex/Antigravity read this one)', f'python -X utf8 {pk} port')
    # CLIs: present and logged in (never log in)
    for exe in ('git', 'pwsh', 'node'):
        if not shutil.which(exe):
            out('ACT', 'SETUP-CLI', exe, 'not on PATH (the kit needs it)')
    tt = (os.environ.get('KIT_TRACKER_TYPE') or get(cfg, 'tracker.type') or 'none').lower()
    need = {'clickup': ['clickup'], 'github': ['gh'], 'gitlab': ['glab'], 'jira': [], 'none': []}.get(tt, [])
    host_cli = {'github': 'gh', 'gitlab': 'glab'}.get(get(cfg, 'gitHostType') or ('github' if 'github' in str(get(cfg, 'gitHost') or '') else 'gitlab'))   # GitHub Enterprise: gitHostType
    for exe in sorted(set(need + [host_cli] if host_cli else need)):
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

# ---- config
def cmd_config(kit, fill):
    doc, documented = config_doc_keys(OWN)
    for ex_rel, loc_rel, what in PAIRS:
        ex, _ = example_of(ex_rel)
        loc, err = load_json(osp.join(kit, loc_rel))
        if err == 'missing':
            if loc_rel.endswith('kit.local.json'):
                out('ASK', 'CONFIG-FILE', loc_rel, f'missing ({what})', 'orch.ps1 setup -WriteLocal; the lead fills org values')
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
                out('ACT', 'CONFIG-TYPE', f'{loc_rel} {p}', f'is {type(lv).__name__}, expected {type(ev).__name__} (as in {osp.basename(ex_rel)})')
        for p in key_paths(loc):
            top = p.split('.')[0]
            if get(ex, p) is None and p not in documented and f'`{p}' not in doc and not any(p.startswith(m + '.') for m in USER_MAPS) \
              and top not in ('default', 'browser', 'keepFreeGB'):
                out('WARN', 'CONFIG-UNKNOWN', f'{loc_rel} {p}', 'key not in the example nor README "Configuration": a typo, or an undocumented key a script reads?')
        if changed:
            bak = osp.join(kit_path('cache', create=True, kit=kit), osp.basename(loc_rel) + time.strftime('.bak-%Y%m%d-%H%M%S'))
            shutil.copyfile(osp.join(kit, loc_rel), bak)
            with open(osp.join(kit, loc_rel), 'w', encoding='utf-8') as f:
                json.dump(loc, f, indent=2, ensure_ascii=False)
                f.write('\n')
            out('INFO', 'CONFIG-DEFAULT', loc_rel, f'written (backup {bak}: disposable runtime cache)')
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
    tt = (os.environ.get('KIT_TRACKER_TYPE') or get(c, 'tracker.type') or 'none').lower()
    tn = ((manifest(kit).get('adapters') or {}).get('tracker') or {}).get('names', 'none').split()
    if tt not in tn:
        out('ACT', 'CONFIG-VALUE', 'kit.local.json tracker.type', 'not one of ' + ' / '.join(tn))
    if tt in ('github', 'gitlab') and not get(c, 'tracker.repo'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json tracker.repo', f'tracker.type {tt} needs owner/name or group/project')
    rt = (os.environ.get('KIT_REPORT_TYPE') or get(c, 'reports.type') or ('gdocs' if shutil.which('gws') else 'markdown')).lower()
    if rt == 'gdocs' and not c.get('driveParent'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json driveParent', 'reports.type gdocs needs the Drive folder id for guides and evidence')
    if not c.get('orgTerms'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json orgTerms', 'empty: the pre-push org-term gate checks nothing; the lead lists org, product, host and tenant names')
    for p in c.get('localOnly') or []:
        if not osp.exists(osp.join(kit, p)):
            out('WARN', 'CONFIG-VALUE', f'kit.local.json localOnly {p}', 'path does not exist in the clone (stale entry?)')
    for k in ('reposRoot',):
        if c.get(k) and not osp.isdir(osp.expanduser(str(c[k]))):
            out('ACT', 'CONFIG-VALUE', f'kit.local.json {k}', 'folder does not exist on this machine')
    for i, root in enumerate(c.get('worktreeRoots') or []):
        if root and not osp.isdir(osp.dirname(osp.abspath(osp.expanduser(str(root))))):
            out('ACT', 'CONFIG-VALUE', f'kit.local.json worktreeRoots[{i}]', 'its parent folder does not exist on this machine')
    for i, r in enumerate(c.get('repos') or []):
        w = f'kit.local.json repos[{i}]'
        if not isinstance(r, dict):
            out('ACT', 'CONFIG-TYPE', w, 'must be an object')
            continue
        for k in ('name', 'checkout', 'target'):
            if not r.get(k):
                out('ASK' if k != 'name' else 'ACT', 'CONFIG-NEED', f'{w}.{k}', 'missing')
        if r.get('checkout') and not osp.isdir(osp.expanduser(str(r['checkout']).replace('<workspace>', osp.dirname(kit)))):
            out('ACT', 'CONFIG-VALUE', f'{w}.checkout', 'folder does not exist on this machine')
        for k in ('linkFrom',):
            if r.get(k) and not osp.isdir(osp.expanduser(str(r[k]))):
                out('ACT', 'CONFIG-VALUE', f'{w}.{k}', 'folder does not exist (wt.ps1 new fails)')
        for t, d in (r.get('linkFromByTarget') or {}).items():
            if d and not osp.isdir(osp.expanduser(str(d))):
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
                if s.get('key') and not osp.isfile(osp.expanduser(str(s['key']))):
                    out('ACT', 'CONFIG-VALUE', f'{dw}.ssh.key', 'key file not found on this machine')
    le = c.get('localEnv') or {}
    ports = {}
    for env, e in (le.get('envs') or {}).items():
        for s in (e or {}).get('services') or []:
            if s.get('port') and not s.get('external'):   # external infra may be shared
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
    if get(s, 'app.appDir') and not osp.isdir(osp.expanduser(str(get(s, 'app.appDir')))):
        out('ACT', 'CONFIG-VALUE', 'swarm.config.json app.appDir', 'folder does not exist on this machine')

# ---- recover
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
    main = osp.normcase(osp.abspath(kit))
    in_wt = set()
    for w in wts:
        path = w.get('worktree', '')
        br = str(w.get('branch', '')).replace('refs/heads/', '')
        if not path or osp.normcase(osp.abspath(path)) == main or 'prunable' in w:
            continue
        in_wt.add(br)
        _, wd, _ = git(path, 'status', '--porcelain')
        rc_m, _, _ = git(kit, 'merge-base', '--is-ancestor', br or 'HEAD', 'origin/main')
        _, ahead, _ = git(kit, 'rev-list', '--count', f'origin/main..{br}') if br else (0, '?', '')
        _, remote, _ = git(kit, 'ls-remote', '--heads', 'origin', br, timeout=60) if br else (0, '', '')
        idle_h = (time.time() - max((osp.getmtime(osp.join(path, f)) for f in os.listdir(path)), default=0)) / 3600 if osp.isdir(path) else 99
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
    cfg, _ = load_json(osp.join(kit, 'skills/dev-kit/kit.local.json'))
    lo = [p.replace('\\', '/').strip('/') for p in ((cfg or {}).get('localOnly') or [])]
    bad = sorted(set([f for f in ig.splitlines() if f] + [f for f in tracked(kit) if '.local.' in osp.basename(f) or any(f == p or f.startswith(p + '/') for p in lo)]))
    for f in bad:
        out('ACT', 'RECOVER-TRACKED-LOCAL', f, 'tracked although git-ignored / local-only (it is published on push)',
         f'git -C {kit} rm --cached -- {f} in a kit commit (the lead confirms; the file stays on disk)')
    # launch records, board entries, product worktrees, runtime size
    ld = kit_path('launches', kit=kit)
    for f in sorted(os.listdir(ld)) if osp.isdir(ld) else []:
        r, err = load_json(osp.join(ld, f))
        if err or not isinstance(r, dict):
            out('ACT', 'RECOVER-LAUNCH', f, f'unreadable launch record ({err})', 'delete it')
        elif not r.get('completed'):
            age = (time.time() - osp.getmtime(osp.join(ld, f))) / 3600
            out('WARN', 'RECOVER-LAUNCH', r.get('runId', f), f'workflow launch with no completion, {age:.0f} h old ({osp.basename(str(r.get("script", "")))})',
             'still running in a live session? leave it; dead -> resume (orchestrate E3) or orch.ps1 launch -Done -RunId <id>')
    bd = kit_path('board', kit=kit)
    for f in sorted(os.listdir(bd)) if osp.isdir(bd) else []:
        p = osp.join(bd, f)
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
                e['leftBy'] = 'kittool audit recover (no heartbeat > 12 h)'
                with open(p, 'w', encoding='utf-8') as fh:
                    json.dump(e, fh, indent=2)
                out('FIX', 'RECOVER-BOARD', f, f'stale board entry {e.get("agent")} ({e.get("run")}) marked left ({age_h:.0f} h without a heartbeat)')
            else:
                out('WARN', 'RECOVER-BOARD', f, f'board entry {e.get("agent")} ({e.get("run")}) has no heartbeat for {age_h:.1f} h',
                 'orch.ps1 supervise -AutoFix closes finished workflow agents; > 12 h: kittool.py audit recover --fix marks it left')
    for root in (cfg or {}).get('worktreeRoots') or []:
        root = osp.expanduser(str(root))
        for d in sorted(os.listdir(root)) if osp.isdir(root) else []:
            gp = osp.join(root, d, '.git')
            if osp.isfile(gp):
                gd = open(gp, encoding='utf-8', errors='replace').read().replace('gitdir:', '').strip()
                if not osp.isdir(gd):
                    out('ACT', 'RECOVER-ORPHAN', osp.join(root, d), 'worktree folder whose repo record is gone (git cannot see or clean it)',
                     'check it holds nothing unpushed, then the lead deletes the folder; run git worktree prune in its repo')
    cl = osp.join(kit, 'skills', 'orchestrate', 'orch.ps1')
    rc, o, e = pwsh(cl, 'cleanup', *(['-Quiet'] if fix else ['-DryRun']), timeout=300)   # without the verb: usage, exit 2
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
                size += osp.getsize(osp.join(d, f))
            except OSError:
                pass
    if size > 5 * 1024 ** 3:
        out('WARN', 'RECOVER-RUNTIME', rt, f'runtime holds {size / 1024 ** 3:.1f} GB', 'find the folder that grows; add a prune rule to orch.ps1 cleanup')

# ---- scan
def cmd_scan(kit):
    files = tracked(kit) or []
    lint = osp.join(kit, 'skills', 'orchestrate', 'kittool.py')
    tmp = osp.join(kit_path('cache', create=True, kit=kit), 'kitty-audit-lint.json')
    if osp.exists(tmp):
        os.remove(tmp)
    rc, _, e = run([py(), '-X', 'utf8', lint, 'lint', kit, '--warn', '--no-flow', '--json', tmp], timeout=120)
    if rc not in (0, 1):
        out('ACT', 'LINT-RUN', 'kittool.py lint', f'exit {rc}: {(e or "")[:200]}')
    lj, _ = load_json(tmp)
    for p in lj or []:
        out('ACT', f'LINT-{p["code"]}', p['where'], p['problem'])
    live = live_kit()
    kl = osp.join(live, 'skills', 'dev-kit', 'kit.local.json')
    if osp.isfile(kl):
        rc, o, _ = run([py(), '-X', 'utf8', lint, 'lint', kit, '--no-flow', '--org-terms', kl], timeout=120)
        for l in o.splitlines():
            if l.startswith('ORG-TERM'):
                out('ACT', 'GENERIC-ORG-TERM', l.split()[1].rstrip(':'), l.split(':', 1)[1].strip())
    pk = osp.join(kit, 'skills', 'orchestrate', 'kittool.py')
    rc, o, e = run([py(), '-X', 'utf8', pk, 'port', '--check'], timeout=60)
    if rc:
        out('ACT', 'PORT-DRIFT', 'kittool.py port --check', (o or e)[:300], f'python -X utf8 {pk} port')
    agents = {osp.basename(f)[:-3] for f in files if re.match(r'agents/[^/]+\.md$', f)}
    for f in files:
        t = aread(kit, f)
        pass   # LESSONS-CAP in lint
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
    # config: example keys documented, documented keys read
    doc, documented = config_doc_keys(kit)
    ex, _ = load_json(osp.join(kit, 'skills/dev-kit/kit.example.json'))
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
    # script pitfall leads (to read, not verdicts)
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
    # one variable, two spellings, both ASSIGNED ($L, $l): the second overwrites
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
        if osp.basename(f) in LIBS and re.match(r'\s*exit\b', line):
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
            # any verb param block taking the flag counts
            for m in re.finditer(r'(?is)\bparam\s*\((.*?)\)\s*\n', code):
                ps = {x.lower() for x in re.findall(r'\$(\w+)', m.group(1))} | {x.lower() for x in re.findall(r"Alias\('([^']+)'", m.group(1))}
                params.setdefault(osp.basename(f), set()).update(ps)
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

# ---- stamp / due
def last_audit(kit):
    p = kit_path('last-kitty-audit', kit=kit)
    try:
        return datetime.datetime.fromisoformat(open(p, encoding='utf-8').read().strip()[:19])
    except (OSError, ValueError):
        return None

def cmd_stamp(kit):
    p = kit_path('last-kitty-audit', create=True, kit=kit)
    now = datetime.datetime.now().isoformat(timespec='seconds')
    with open(p, 'w', encoding='utf-8') as f:
        f.write(now + '\n')
    out('FIX', 'AUDIT-STAMP', p, f'last kit audit = {now} (the SessionStart nudge resets)')

def cmd_due(kit):
    cfg, _ = load_json(osp.join(kit, 'skills/dev-kit/kit.local.json'))
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
    kit = osp.abspath(str(kit)) if kit else (OWN if cmd == 'scan' else live_kit())
    {'setup': lambda: cmd_setup(kit, fix), 'config': lambda: cmd_config(kit, fill), 'recover': lambda: cmd_recover(kit, fix),
    'scan': lambda: cmd_scan(kit), 'stamp': lambda: cmd_stamp(kit), 'due': lambda: cmd_due(kit)}[cmd]()
    order = {'FIX': 0, 'ACT': 1, 'ASK': 2, 'WARN': 3, 'INFO': 4}
    for x in sorted(findings, key=lambda x: (order[x['level']], x['code'], x['where'])):
        print(f"{x['level']:4} {x['code']} {x['where']}: {x['what']}" + (f" -> {x['fix']}" if x['fix'] else ''))
    n = {lv: sum(1 for x in findings if x['level'] == lv) for lv in order}
    print(f'kittool audit {cmd} ({kit}): ' + ', '.join(f'{v} {k}' for k, v in n.items() if v) if findings else f'kittool audit {cmd} ({kit}): nothing found')
    if js:
        with open(js, 'w', encoding='utf-8') as f:
            json.dump(findings, f, indent=1)
    sys.exit(1 if n['ACT'] or n['ASK'] else 0)

# ==== 7. cost: tokens per agent type + workflow prompts
COST_MJS = r'''// Renders every prompt a kit workflow builds, by running the workflow with mock agents and sample args.
// Used by kittool.py cost (token budget per agent type); also a cheap behaviour check: the label/model/agentType of every
// step is printed, so a prompt refactor can be diffed against the previous version.
//   node kit-cost.mjs <kitDir> [--prompts] [--clean] [--set <wf>.<arg>=<json>]...  -> JSON { calls: [{ wf, label, agentType, model, effort, bytes }], logs }
//   --clean: reviews find nothing and every QA check passes (exercises learn: 'auto'); --set buildy.review='"auto"' overrides a sample arg
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
  case 'prepare': return { runDir: SAMPLE['testy'].runDir, items: 2, left: [{ id: 't3', reason: 'not live' }], summary: 'sample' }
  case 'load-run': return { json: JSON.stringify(SAMPLE['testy']) }
  case 'analyse': return { proposals: [{ file: `${kit}/skills/dev-kit/LESSONS.md`, change: 'add-lesson', text: 'x', evidence: '2 signals', occurrences: 2, confidence: 'high' }] }
  case 'apply': return { applied: ['x'], proposedForApproval: [], rejected: [], report: 'r.md' }
  default: return 'ok'
 }
}

const SAMPLE = {
 'buildy': { brief: '/ws/.claude/<runtime>/work/briefs/wave-brief.md', kitDir: kit, mandate: ['Fix the order form bugs from the QA run and ship them.'],
  agents: [{ id: 'X1', items: 'A1, A2', area: 'order form' }, { id: 'X2', items: 'A3', area: 'order list', complex: true }] },
 'testy': { runDir: '/ws/.claude/<runtime>/work/qa-runs/2026-01-01-sample', kitDir: kit, title: 'Sample epic', target: 'my-staging', tester: 'QA',
  mandate: ['Test the deployed epic tasks and close them.'], context: 'Use tenant acme.', tracker: { list: 'L1', parent: 'P1' },
  lanes: [{ n: 1, name: 'Falcon', serial: 'emulator-5556', user: 'qa-user-1' }],
  items: [{ code: 'W1', title: 'Order form', guideFile: '/ws/guides/W1.md', lane: 'web', subtasks: [{ id: 't1', name: 'Order form', mrs: 'api!1' }] },
   { code: 'P1', title: 'Order app', guideFile: '/ws/guides/P1.md', lane: 'app', subtasks: [{ id: 't2', name: 'Order app', mrs: 'app!3' }] }] },
 'tidy': { kitDir: kit },
 'testy#select': { select: { statuses: ['promoted', 'inTest'] }, target: 'local', kitDir: kit, mandate: ['Test everything promoted or in test on local.'] },
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
    """Start tokens (UTF-8 bytes / 4) per agent type (always-loaded files, agent definition, skill, LESSONS.md section) plus
    each workflow step's prompt (workflows run under node with mock agents)."""
    kit = osp.abspath(next((x for x in a if not x.startswith('--')), KIT_DIR))
    tok = lambda s: (len(s.encode('utf-8')) + 3) // 4
    ftok = lambda rel: tok(read(osp.join(kit, rel)))
    rules = [f'rules/{f}' for f in sorted(os.listdir(osp.join(kit, 'rules'))) if f.endswith('.md') and not f.endswith('.local.md')] if osp.isdir(osp.join(kit, 'rules')) else []
    always = ftok('CLAUDE.md') + ftok('AGENTS.md') + sum(ftok(r) for r in rules if 'paths' not in frontmatter(read(osp.join(kit, r))))
    skills = sorted(d for d in os.listdir(osp.join(kit, 'skills')) if osp.isfile(osp.join(kit, 'skills', d, 'SKILL.md')))
    always += sum(tok(frontmatter(read(osp.join(kit, 'skills', s, 'SKILL.md'))).get('description', '')) for s in skills)
    lessons = read(osp.join(kit, 'LESSONS.md'))
    lsec = lambda s: tok((re.search(r'^## ' + re.escape(s) + r'\n(.*?)(?=^## |\Z)', lessons, re.S | re.M) or [''])[0] if lessons else '')
    # agent -> (skills it loads at start, its LESSONS.md sections)
    reads = {'devy': (['dev-kit'], ['dev-kit']), 'revy': (['dev-kit'], ['revy', 'dev-kit']), 'revy (module)': ([], ['revy']),
      'checky': (['qa-kit'], ['qa-kit']), 'kitty': ([], ['kitty'])}
    calls = []
    node = shutil.which('node')
    if node:
        with tempfile.TemporaryDirectory() as tmp:
            src = osp.join(tmp, 'cost.mjs')
            with open(src, 'w', encoding='utf-8') as fh:
                fh.write(COST_MJS)
            try:
                r = subprocess.run([node, src, kit], capture_output=True, text=True, encoding='utf-8', timeout=120)
            except subprocess.TimeoutExpired:
                r = None
                print('kittool cost: the workflow render timed out after 120 s', file=sys.stderr)
            if r is not None:
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
    rows = [{'agent': f'{ag} (start)', 'always': always, 'files': ftok(f'agents/{ag.split()[0]}.md') + sum(ftok(f'skills/{s}/SKILL.md') for s in sks) + sum(lsec(x) for x in ls)}
      for ag, (sks, ls) in reads.items()]
    for wf in sorted({c['wf'] for c in calls}):
        cs = [c for c in calls if c['wf'] == wf]
        rows.append({'agent': f'run: {wf} ({len(cs)} steps)', 'always': always * len(cs), 'files': sum(c['tokens'] for c in cs)})
    for r_ in rows:
        r_['total'] = r_['always'] + r_['files']
    if '--routes' in a:   # per Router row: always-loaded + Load first skill + the target's start files (a workflow: its whole run)
        start = {r_['agent'][:-8]: r_['files'] for r_ in rows if r_['agent'].endswith(' (start)')}
        runs = {r_['agent'].split()[1]: r_['total'] for r_ in rows if r_['agent'].startswith('run: ')}
        rows = []
        for c in table_rows(section(read(osp.join(kit, 'AGENTS.md')), 'Router') or ''):
            tgt, lf = c[2], c[3] if len(c) > 3 else ''
            wf = next((w for w in runs if f'/{w}' in tgt), '')
            ag = next((x for x in start if re.search(rf'`{x.split()[0]}` agent', tgt) and ('(module)' in x) == ('module' in tgt)), '')
            sk = [s for s in skills if f'`{s}`' in tgt + lf or (f'{s} steps' in tgt)]
            n = (runs[wf] if wf else always) + (start[ag] if ag else 0) + sum(ftok(f'skills/{s}/SKILL.md') for s in sk)
            rows.append({'route': c[0].strip('*'), 'target': '/' + wf if wf else ag or ', '.join(sk) or 'direct', 'total': n})
        if '--json' in a:
            print(json.dumps(rows, indent=1))
            return 0
        print('| Route | loads | tokens |\n|---|---|---:|')
        for r_ in rows:
            print(f"| {r_['route']} | {r_['target']} | {r_['total']} |")
        return 0
    if '--json' in a:
        print(json.dumps(rows, indent=1))
        return 0
    print('| Agent / run | always-loaded | start files / prompts | total |\n|---|---:|---:|---:|')
    for r_ in rows:
        print(f"| {r_['agent']} | {r_['always']} | {r_['files']} | {r_['total']} |")
    return 0

# ==== 8. registry: manifest, schemas, new / rename / remove, release
# _manifest registers every crew part and cap; lint checks files against it; new / rename / remove change part + entry
# together (no half-added part lints clean). Front matter validates against a small JSON Schema subset.
TODO = 'TODO(new)'
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

def character_block(ch, width=128):
    """The Character paragraph port writes into agents/<name>.md from the manifest (one fixed shape for every agent)."""
    words = f'**Character:** traits: {ch["traits"]} · bias: {ch["bias"]} · catchphrase: "{ch["catchphrase"]}" · never: {ch["never"]}.'.split(' ')
    lines, cur = [], ''
    for w in words:
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = f'{cur} {w}' if cur else w
    return '\n'.join(lines + [cur])

def old_name_rx(old):
    # bare, file or joined name (last-<old>, <old>s, <old>-x); <name>.stamp sharing the stem is no reference
    return re.compile(r'(?<![\w/.-])((?:\w+-)*)' + re.escape(old) + r'((?:s|-\w+)*)(?![\w-])(?!\.(?:local\.)?stamp\b)')


def adapter_blocks(text, kind):
    """{name: code} of each `adapter:<kind>/<name>` block (to the next adapter / adapter-end marker)."""
    out = {}
    for m in re.finditer(r'adapter:' + re.escape(kind) + r'/([\w-]+)', text):
        nx = re.compile(r'adapter(?:-end)?:[\w-]+').search(text, m.end())
        out[m.group(1)] = out.get(m.group(1), '') + text[m.end():nx.start() if nx else len(text)]
    return out


def adapter_lint(k, man, bad):
    """ADAPTER: each registered name has every verb of its kind ('*' = all); configured names are registered."""
    try:
        loc = json.loads(read(os.path.join(k.dir, 'skills/dev-kit/kit.local.json')) or '{}')
    except ValueError:
        loc = {}
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
                bad('ADAPTER', f, f'{kind}/{n}: {miss or "no block"} (kittool.py new adapter {kind} {n})')
        cur = [loc] if a.get('config') else []
        for p in (a.get('config') or '').replace('[]', '.[]').split('.'):
            cur = [y for x in cur for y in (x if isinstance(x, list) else [x]) if isinstance(y, dict)] if p == '[]' else [x[p] for x in cur if isinstance(x, dict) and x.get(p) is not None]
        for v in cur:
            if isinstance(v, str) and v not in names + a.get('values', '').split():
                bad('ADAPTER', 'skills/dev-kit/kit.local.json', f'{a["config"]} "{v}": no such {kind} adapter ({" ".join(names)})')


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
            bad('MANIFEST', PATHS_JSON, f'{what} {x} exists but is not registered in _manifest (kittool.py new {what} {x} registers a new one)')
        for x in sorted(want - have):
            bad('MANIFEST', PATHS_JSON, f'{what} {x} is registered but has no file (kittool.py remove {what} {x})')
    rows = [c[0].strip('*') for c in table_rows(k.router or '')]
    if rows != list(man.get('router') or []):
        bad('MANIFEST', 'AGENTS.md', f'Router rows {rows} differ from _manifest.router {man.get("router")}')
    ev = re.findall(r'^\|\s*(E\d+)\s*\|', section(k.texts.get('skills/orchestrate/SKILL.md', ''), 'Events') or '', re.M)
    if ev != list(man.get('events') or []):
        bad('MANIFEST', 'skills/orchestrate/SKILL.md', f'Events rows {ev} differ from _manifest.events {man.get("events")}')
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
            bad('MANIFEST', p, 'the Character block differs from _manifest (kittool.py port writes it from the manifest)')
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
            t = re.sub(r'"renamed":\s*\{[^}]*\}', '', t)   # the migration note itself
        for o, rx in pats:
            m = rx.search(t)
            if m:
                bad('OLD-NAME', f'{f}:{t.count(chr(10), 0, m.start()) + 1}', f'old name "{o}" (now "{olds[o]}"): no aliases, update the reference')
        if TODO in t and f != 'skills/orchestrate/kittool.py':   # the templates live here
            bad('TODO-STUB', f'{f}:{t.count(chr(10), 0, t.index(TODO)) + 1}', f'{TODO} left by kittool.py new: fill it in')
        ln = lambda m: f'{f}:{t.count(chr(10), 0, m.start()) + 1}'
        for m in re.finditer(r'business[- ]logic change', t, re.I):   # the rule is what a user sees, not where the code sits
            if 'decide ask' in t[m.start():m.start() + 300] and 'user-visible' not in t[max(0, m.start() - 150):m.start() + 300]:
                bad('DECISION-WORDING', ln(m), 'a decision pause is a user-visible behaviour change (AGENTS.md "Decision pauses"), not a "business-logic change"')
        m = re.search(r'(?<!no )\b(?:Explore|Plan|general-purpose) agents?\b', t) if f.startswith(('agents/', 'workflows/')) or f.endswith('SKILL.md') else None
        if m:
            bad('NON-CREW', ln(m), f'"{m.group(0)}": only crew agents ({", ".join(sorted(crew))}) are spawned')

def write_characters(kit=None):
    """port: every agent's Character block from the manifest (one shape, one source)."""
    kd = kit or KIT_DIR
    n = 0
    for a, m in (manifest(kd).get('agents') or {}).items():
        p = osp.join(kd, 'agents', f'{a}.md')
        ch = m.get('character') or {}
        if not osp.isfile(p) or schema_errors(ch, SCHEMAS['character']) or TODO in json.dumps(ch):
            continue
        with open(p, encoding='utf-8', newline='') as fh:
            raw = fh.read()
        eol = '\r\n' if '\r\n' in raw else '\n'
        t = raw.replace('\r\n', '\n')
        blk = character_block(ch)
        t2 = CHAR_RX.sub(lambda _: blk, t, count=1) if CHAR_RX.search(t) else t
        if t2 != t:
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(t2.replace('\n', eol))
            n += 1
    if n:
        print(f'Character blocks written from the manifest: {n}')

# ---- scaffolding: a template per part kind; registers it, leaves TODO(new) stubs lint refuses
def _git(kit, *a):
    return subprocess.run(['git', '-C', kit, *a], capture_output=True, text=True, encoding='utf-8', errors='replace')

def _edit_manifest(kit, change):
    p = osp.join(kit, PATHS_JSON)
    raw = read(p)
    old = json.loads(raw).get('_manifest') or {}
    new = json.loads(json.dumps(old))
    change(new)
    at = raw.index('"_manifest": {')
    for key in [x for x in new if new[x] != old.get(x)]:   # changed keys only, one line each: the hand layout stays
        m = re.compile(r'\n(\s*)"' + re.escape(key) + r'": ').search(raw, at)
        if m:
            end = json.JSONDecoder().raw_decode(raw, m.end())[1]
            raw = raw[:m.end()] + json.dumps(new[key], ensure_ascii=False) + raw[end:]
        else:
            m = re.compile(r'\n(\s*)"renamed": ').search(raw, at)
            raw = raw[:m.start()] + f'\n{m.group(1)}"{key}": {json.dumps(new[key], ensure_ascii=False)},' + raw[m.start():]
    with open(p, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(raw)

def _write_new(kit, rel, text):
    p = osp.join(kit, rel)
    if osp.exists(p):
        sys.exit(f'kittool new: {rel} already exists')
    os.makedirs(osp.dirname(p), exist_ok=True)
    with open(p, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)
    print(f'wrote {rel}')

def _sub_file(kit, rel, fn):
    p = osp.join(kit, rel)
    with open(p, encoding='utf-8', newline='') as fh:
        raw = fh.read()
    eol = '\r\n' if '\r\n' in raw else '\n'
    t = fn(raw.replace('\r\n', '\n'))
    with open(p, 'w', encoding='utf-8', newline='') as fh:
        fh.write(t.replace('\n', eol))

def _router_stub(kit, target, cond):
    """A Router row stub before the last row (the catch-all 'direct' row keeps its place); returns its id."""
    rid = {}

    def fn(t):
        sec = section(t, 'Router') or ''
        rows = [l for l in sec.split('\n') if re.match(r'^\|\s*R\d+\s*\|', l)]
        n = max(int(re.match(r'^\|\s*R(\d+)', l).group(1)) for l in rows) + 1
        rid['id'] = f'R{n}'
        new = f'| R{n} | {cond} | {target} | — |'
        return t.replace(rows[-1], new + '\n' + rows[-1], 1)
    _sub_file(kit, 'AGENTS.md', fn)
    _edit_manifest(kit, lambda m: m.setdefault('router', []).insert(len(m.get('router', [])) - 1, rid['id']))
    return rid['id']

TEST_MARK = '# ---- scaffolded parts (kittool.py new appends a test stub per part here; replace each with a real check)'

def _test_stub(kit, what):
    def fn(t):
        line = f"  Expect '{what}: {TODO} a real check' ($false)   # {TODO}\n"
        if TEST_MARK in t:
            return t.replace(TEST_MARK + '\n', TEST_MARK + '\n' + line, 1)
        return t.rstrip('\n') + '\n' + TEST_MARK + '\n' + line
    _sub_file(kit, 'tests/kit-tests.ps1', fn)

def cmd_new(a):
    """kittool.py new agent|skill|workflow|rule|event|config-key <name> [--crew <agent>] [--skill <skill>] | new adapter <kind> <name> | new adr <title>"""
    kit = KIT_DIR
    if len(a) < 2:
        print(cmd_new.__doc__, file=sys.stderr)
        return 2
    kind, name = a[0], a[1]
    if kind == 'adr':   # a decision record: one LESSONS.md "## Decisions" line, the title is free text
        title = ' '.join(a[1:]).strip()
        line = f'- {datetime.date.today():%Y-%m-%d} {title}: context {TODO} · decision {TODO} · consequences {TODO}'

        def fn(t):
            if not re.search(r'^## Decisions\s*$', t, re.M):
                return t.rstrip('\n') + '\n\n## Decisions\n' + line + '\n'
            return re.sub(r'(^## Decisions\s*\n(?:(?!## ).*\n)*)', lambda m: m.group(1).rstrip('\n') + '\n' + line + '\n', t, count=1, flags=re.M)
        _sub_file(kit, 'LESSONS.md', fn)
        print(f'LESSONS.md Decisions: {title}: fill every {TODO}')
        return 0
    opt = lambda n, d='': a[a.index(n) + 1] if n in a and a.index(n) + 1 < len(a) else d
    if not re.match(r'^[a-z][a-z0-9-]*(\.[a-zA-Z0-9]+)*$', name):
        sys.exit(f'kittool new: "{name}" is not a kebab-case name')
    if kind == 'agent':
        skill = opt('--skill', 'dev-kit')
        _write_new(kit, f'agents/{name}.md', f'''---
name: {name}
description: "{TODO}: what it does. Spawned by {TODO}: which workflow or the coordinator. Precondition: {TODO}. Loads {skill} first. Not for: {TODO}."
model: sonnet
---

`<kit>` = the workspace's `.claude` folder (the directory the session started in holds it).

**Character:** traits: {TODO} · bias: {TODO} · catchphrase: "{TODO}" · never: {TODO}.

**Kind** (the prompt names it): {TODO}.

**Load first:** `<kit>/skills/{skill}/SKILL.md` and follow its steps (step 0 prints your lessons).

Non-negotiables:
- Board first (`orch.ps1 board join -Type {name} ...`; it lists every live agent on this machine); a file, task, env or seat someone
  else holds -> `board msg` the holder; a disagreement -> `orch.ps1 board dispute`; `leave` at the end.
- {TODO}: the limits of this job.
- A prompt that starts with `STEP:` is one mechanical workflow step: do exactly that; skip Load first, the board and the report shape.

Finish with the report your task asks for (dev-kit templates.md "Final reports").

**Self-improvement:**
`& <kit>/skills/orchestrate/orch.ps1 learn -Skill {name} -Kind <kind> -Text "<what happened + what fixed it>" [-Ref <id>]`
''')
        ch = {'traits': TODO, 'bias': TODO, 'catchphrase': TODO, 'never': TODO}
        _edit_manifest(kit, lambda m: m.setdefault('agents', {}).__setitem__(name, {'job': TODO, 'kinds': [], 'roles': [], 'skill': skill, 'tools': 'all', 'usedIn': [], 'cant': TODO, 'character': ch}))
        rid = _router_stub(kit, f'`{name}` agent', f'{TODO}: the conditions that route to {name}')
        _test_stub(kit, f'agent {name}')
    elif kind == 'skill':
        _write_new(kit, f'skills/{name}/SKILL.md', f'''---
name: {name}
description: "Load when: {TODO}. Not when: {TODO} -> <sibling skill>."
---

**Load when** (all must hold): {TODO}.
**Not when:** {TODO} -> `<sibling>`.
**Hands off to:** {TODO}.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `orch.ps1 learn -Read -Skill {name}` |

## Steps
0. `orch.ps1 learn -Read -Skill {name}`.
1. **{TODO}:** action -> result.

**Rules**
- {TODO}

**Learn:** `orch.ps1 learn -Skill {name} -Kind <kind> -Text "<what + fix>"`.
''')
        _edit_manifest(kit, lambda m: m.setdefault('skills', []).append(name) or m['skills'].sort())
        rid = _router_stub(kit, f'`{name}`', f'{TODO}: the conditions that load {name}')
        _test_stub(kit, f'skill {name}')
    elif kind == 'workflow':
        crew = opt('--crew', 'devy')
        cond = f'{TODO}: the conditions that launch /{name}'
        _write_new(kit, f'workflows/{name}.js', f'''export const meta = {{
  name: '{name}',
  description: '{TODO}: what the run does',
  whenToUse: '{cond}',
  phases: [
    {{ title: 'Run', detail: '{TODO}: what the phase does' }},
  ],
}}

/*
args = {{ kitDir: '<abs path of .claude>', mandate: ['<the owner words, verbatim>'] }}   // every arg with its default ({TODO})
Returns {{ ok, summary }}.
*/
const A = args || {{}}
const KIT = (A.kitDir || '.claude').replace(/[\\\\/]+$/, '')
const PATHS = '\\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const OK_SCHEMA = {{ type: 'object', properties: {{ ok: {{ type: 'boolean' }}, summary: {{ type: 'string' }} }}, required: ['ok', 'summary'] }}
phase('Run')
const r = await agent(`{TODO}: the prompt (kit: ${{KIT}}).${{PATHS}}`, {{ label: 'run', phase: 'Run', schema: OK_SCHEMA, agentType: '{crew}' }})
return r || {{ ok: false, summary: 'the agent returned nothing' }}
''')
        rid = _router_stub(kit, f'`/{name}`', cond)
        _edit_manifest(kit, lambda m: m.setdefault('workflows', {}).__setitem__(name, {'covers': TODO, 'crew': [crew], 'router': rid}))
        _test_stub(kit, f'workflow {name}')
    elif kind == 'rule':
        _write_new(kit, f'rules/{name}.md', f'---\npaths: ["{TODO}: the files this rule is for"]\n---\n# {name}\n- {TODO}: one short hard rule per line\n')
        _test_stub(kit, f'rule {name}')
    elif kind == 'event':
        ids = {}

        def fn(t):
            rows = re.findall(r'^\|\s*E(\d+)\s*\|.*$', section(t, 'Events') or '', re.M)
            n = max(int(x) for x in rows) + 1
            ids['id'] = f'E{n}'
            last = [l for l in t.split('\n') if re.match(r'^\|\s*E\d+\s*\|', l)][-1]
            return t.replace(last, last + f'\n| E{n} | {TODO}: {name} | {TODO}: the action |', 1)
        _sub_file(kit, 'skills/orchestrate/SKILL.md', fn)
        _edit_manifest(kit, lambda m: m.setdefault('events', []).append(ids['id']))
        _test_stub(kit, f'event {ids["id"]} {name}')
    elif kind == 'config-key':
        def addkey(d):
            cur = d
            parts = name.split('.')
            for x in parts[:-1]:
                cur = cur.setdefault(x, {})
            cur[parts[-1]] = f'{TODO}: the default'
        p = osp.join(kit, PATHS_JSON)
        d = json.loads(read(p))
        addkey(d)
        man, pth = d.pop('_manifest', None), d.pop('_paths', None)
        d['_manifest'], d['_paths'] = man, pth
        with open(p, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')

        def fn(t):
            sec = section(t, 'Configuration') or ''
            last = [l for l in sec.split('\n') if l.startswith('| `')][-1]
            return t.replace(last, last + f'\n| `{name}` | {TODO} | {TODO}: what it changes (today\'s behaviour is the default) |', 1)
        _sub_file(kit, 'README.md', fn)
        _test_stub(kit, f'config key {name}')
    elif kind == 'adapter':   # new adapter <kind> <name>: every verb stubbed, before adapter-end:<kind>
        ak, name, man = name, (a[2] if len(a) > 2 else ''), manifest(kit).get('adapters') or {}
        ad = man.get(ak)
        if not ad or not re.match(r'^[a-z][a-z0-9-]*$', name):
            sys.exit(f'kittool new adapter <kind> <name>: kinds {sorted(x for x in man if x[0] != "_")}')
        py, end = ad['file'].endswith('.py'), f'# adapter-end:{ak}'
        body = '\n'.join((f"  '{v}': lambda a: _todo('{v}')," if py else f"  '{v}' = {{ param($a) throw '{TODO}: {v}' }}") for v in ad['verbs'].split())
        blk = f"# adapter:{ak}/{name}: {TODO} what it talks to\n" + (f"ADAPTERS.setdefault('{ak}', {{}})['{name}'] = {{" if py else f"Register-KitAdapter '{ak}' '{name}' @{{") + f"\n{body}\n}}\n"
        _sub_file(kit, ad['file'], lambda t: t.replace(end, blk + end, 1) if end in t else t.rstrip('\n') + '\n' + blk)
        _edit_manifest(kit, lambda m: m['adapters'][ak].__setitem__('names', f"{m['adapters'][ak]['names']} {name}"))
        _test_stub(kit, f'adapter {ak}/{name} against a recorded API fixture')
    else:
        print(cmd_new.__doc__, file=sys.stderr)
        return 2
    _regen(kit)
    print(f'{kind} {name}: fill every {TODO}, then kittool.py port, lint (0 problems), tests/kit-tests.ps1')
    return 0

def _regen(kit):
    """After new / rename / remove: the ports and README's generated sections follow the registry at once."""
    with contextlib.redirect_stdout(io.StringIO()):
        cmd_port([])
    k2 = load(kit)
    p = osp.join(kit, 'README.md')
    old = read(p)
    new = update_readme(old, readme_sections(k2, graph(k2)))
    if new != old:
        with open(p, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(new)

def _references(kit, word, skip=()):
    rx = old_name_rx(word)
    hits = []
    for f in _git(kit, 'ls-files').stdout.splitlines():
        if f.startswith(GENERATED) or f in skip or not (f.lower().endswith(TEXT_EXT) or '.' not in osp.basename(f)):
            continue
        t = read(osp.join(kit, f))
        if f == PATHS_JSON:
            t = re.sub(r'"renamed":\s*\{[^}]*\}', '', t)
        for m in rx.finditer(t):
            hits.append(f'{f}:{t.count(chr(10), 0, m.start()) + 1}')
    return hits

PART_PATH = {'agent': 'agents/{}.md', 'skill': 'skills/{}', 'workflow': 'workflows/{}.js', 'rule': 'rules/{}.md'}

def _rename_id(kit, kind, old, new):
    """rename event E<n> E<m> | config-key a.b.old a.b.new (same parent): the row / key, the registry and every reference."""
    if kind == 'event':
        if not (re.fullmatch(r'E\d+', old) and re.fullmatch(r'E\d+', new)):
            sys.exit('kittool rename event: ids look like E5')
        man = manifest(kit) or {}
        if old not in man.get('events', []) or new in man.get('events', []):
            sys.exit(f'kittool rename event: {old} must be registered and {new} free')
        _edit_manifest(kit, lambda m: m.__setitem__('events', [new if x == old else x for x in m.get('events', [])]))
    else:
        po, pn = old.split('.'), new.split('.')
        if po[:-1] != pn[:-1]:
            sys.exit('kittool rename config-key: same parent only (a.b.old -> a.b.new)')

        def leaf(path):   # parse + rename in memory; both files parse before either is written
            d = json.loads(read(path))
            cur = d
            for x in po[:-1]:
                cur = cur.get(x) if isinstance(cur, dict) else None
            if not isinstance(cur, dict) or po[-1] not in cur or pn[-1] in cur:
                return None
            items = [(pn[-1] if x == po[-1] else x, v) for x, v in cur.items()]   # same place in the file
            cur.clear()
            cur.update(items)
            return d
        ex, loc = osp.join(kit, PATHS_JSON), osp.join(kit, PATHS_JSON.replace('example', 'local'))
        done = [(p, leaf(p)) for p in (ex, loc) if osp.exists(p)]
        if not done or done[0][1] is None:
            sys.exit(f'kittool rename config-key: {old} must exist in {PATHS_JSON} and {new} must not')
        for p, d in done:
            if d is not None:
                with open(p, 'w', encoding='utf-8', newline='\n') as fh:
                    fh.write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
                if p == loc:
                    print(f'migrated {osp.basename(loc)}: {old} -> {new}')
        for ln in _git(kit, 'grep', '-n', '-w', po[-1], '--', '*.ps1', '*.py', '*.js', '*.mjs').stdout.splitlines()[:20]:
            if old not in ln:
                print(f'WARN nested read? {ln[:160]} (renamed only dotted {old}: check by hand)')
    rx = re.compile(r'(?<![\w.-])' + re.escape(old) + r'(?![\w-]|\.\w)')
    for f in _git(kit, 'ls-files').stdout.splitlines():
        p = osp.join(kit, f)
        if f.startswith(GENERATED) or f == PATHS_JSON or not f.lower().endswith(TEXT_EXT) or not osp.isfile(p):
            continue
        with open(p, encoding='utf-8', errors='replace', newline='') as fh:
            raw = fh.read()
        t2 = rx.sub(new, raw)
        if t2 != raw:
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(t2)
            print(f'updated {f}')
    _regen(kit)
    print(f'renamed {kind} {old} -> {new}')
    return 0

def cmd_rename(a):
    """kittool.py rename agent|skill|workflow|rule|event|config-key <old> <new>: moves the part, rewrites every reference, updates
    the manifest (a part's old -> new joins _manifest.renamed; a config key also moves in kit.local.json), regenerates the ports."""
    kit = KIT_DIR
    if len(a) >= 3 and a[0] in ('event', 'config-key'):
        return _rename_id(kit, *a[:3])
    if len(a) < 3 or a[0] not in PART_PATH:
        print(cmd_rename.__doc__, file=sys.stderr)
        return 2
    kind, old, new = a[0], a[1], a[2]
    src, dst = PART_PATH[kind].format(old), PART_PATH[kind].format(new)
    if not osp.exists(osp.join(kit, src)) or osp.exists(osp.join(kit, dst)):
        sys.exit(f'kittool rename: {src} must exist and {dst} must not')
    r = _git(kit, 'mv', src, dst)
    if r.returncode:   # a part not committed yet (just made by new): a plain move
        try:
            shutil.move(osp.join(kit, src), osp.join(kit, dst))
        except OSError as x:
            sys.exit(f'kittool rename: {src} -> {dst} failed: {r.stderr.strip()} / {x}')
    rx = old_name_rx(old)
    for f in _git(kit, 'ls-files').stdout.splitlines():
        if f.startswith(GENERATED) or not (f.lower().endswith(TEXT_EXT) or '.' not in osp.basename(f)) or not osp.isfile(osp.join(kit, f)):
            continue
        if f == PATHS_JSON:
            continue   # manifest edited below (renamed map keeps the old name)
        p = osp.join(kit, f)
        with open(p, encoding='utf-8', errors='replace', newline='') as fh:
            raw = fh.read()
        t2 = rx.sub(lambda mt: mt.group(1) + new + mt.group(2), raw)   # keep joined prefix / suffix (last-<old>, <old>s)
        if t2 != raw:
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(t2)
            print(f'updated {f}')

    def m(man):
        sect = {'agent': 'agents', 'workflow': 'workflows'}.get(kind)
        if sect and old in (man.get(sect) or {}):
            man[sect] = {(new if x == old else x): v for x, v in man[sect].items()}
        if kind == 'skill':
            man['skills'] = sorted(new if x == old else x for x in man.get('skills', []))
        for w in (man.get('workflows') or {}).values():
            w['crew'] = [new if x == old else x for x in w.get('crew', [])]
        for ag in (man.get('agents') or {}).values():
            if ag.get('skill') == old:
                ag['skill'] = new
            ag['usedIn'] = [(f'/{new}' if x == f'/{old}' else x) for x in ag.get('usedIn', [])]
        ren = man.setdefault('renamed', {})
        for x, y in list(ren.items()):
            if y == old:
                ren[x] = new
        ren[old] = new
    _edit_manifest(kit, m)
    if kind == 'agent':
        _sub_file(kit, dst, lambda t: re.sub(r'^name: .*$', f'name: {new}', t, count=1, flags=re.M))
    _regen(kit)
    left = _references(kit, old)
    print(f'renamed {kind} {old} -> {new}' + (f'; references left: {", ".join(left[:10])}' if left else '; no reference left'))
    return 1 if left else 0

def cmd_remove(a):
    """kittool.py remove agent|skill|workflow|rule|event|config-key <name>: deletes the part, its registry entry and its Router /
    Events row; lists every reference left (exit 1 until none)."""
    kit = KIT_DIR
    if len(a) < 2:
        print(cmd_remove.__doc__, file=sys.stderr)
        return 2
    kind, name = a[0], a[1]
    if kind in PART_PATH:
        r = _git(kit, 'rm', '-rqf', PART_PATH[kind].format(name))
        if r.returncode:   # not committed yet: delete it from disk
            p = osp.join(kit, PART_PATH[kind].format(name))
            if not osp.exists(p):
                sys.exit(f'kittool remove: {r.stderr.strip()}')
            shutil.rmtree(p) if osp.isdir(p) else os.remove(p)
        target = {'agent': f'`{name}`', 'skill': f'`{name}`', 'workflow': f'`/{name}`', 'rule': None}[kind]
        gone = []
        if target:
            def fn(t):
                for l in t.split('\n'):
                    if re.match(r'^\|\s*R\d+\s*\|', l) and target in l.split('|')[3]:
                        gone.append(l.split('|')[1].strip())
                        t = t.replace(l + '\n', '', 1)
                return t
            _sub_file(kit, 'AGENTS.md', fn)

        def m(man):
            man.get('agents', {}).pop(name, None) if kind == 'agent' else None
            man.get('workflows', {}).pop(name, None) if kind == 'workflow' else None
            if kind == 'skill':
                man['skills'] = [x for x in man.get('skills', []) if x != name]
            man['router'] = [x for x in man.get('router', []) if x not in gone]
        _edit_manifest(kit, m)
    elif kind == 'event':
        _sub_file(kit, 'skills/orchestrate/SKILL.md', lambda t: re.sub(r'^\|\s*' + re.escape(name) + r'\s*\|.*\n', '', t, count=1, flags=re.M))
        _edit_manifest(kit, lambda man: man.__setitem__('events', [x for x in man.get('events', []) if x != name]))
    elif kind == 'config-key':
        p = osp.join(kit, PATHS_JSON)
        d = json.loads(read(p))
        cur = d
        for x in name.split('.')[:-1]:
            cur = cur.get(x, {})
        cur.pop(name.split('.')[-1], None)
        with open(p, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
        _sub_file(kit, 'README.md', lambda t: re.sub(r'^\| `' + re.escape(name) + r'` \|.*\n', '', t, count=1, flags=re.M))
    else:
        print(cmd_remove.__doc__, file=sys.stderr)
        return 2
    _regen(kit)
    left = _references(kit, name.split('.')[-1] if kind == 'config-key' else name)
    print(f'removed {kind} {name}' + (f'; references left (fix them): {", ".join(left[:12])}' if left else '; no reference left'))
    return 1 if left else 0

# ---- release: SemVer tags from Conventional Commits; notes = change log
def cmd_release(a):
    """Next vX.Y.Z + notes (breaking + Migration lines, features, fixes, retired lessons) from Conventional Commits since the last
    tag; prints only. --tag: annotated tag with the notes; --publish: also a GitHub release (gh, never logs in)."""
    kit = KIT_DIR
    last = _git(kit, 'describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*').stdout.strip()
    rng = f'{last}..HEAD' if last else 'HEAD'
    log = _git(kit, 'log', rng, '--no-merges', '--format=%h%x1f%s%x1f%b%x1e').stdout
    major, minor, patch = (int(x) for x in re.findall(r'\d+', last)[:3]) if last else (0, 0, 0)
    groups = {'Breaking (migration notes)': [], 'Features': [], 'Fixes': [], 'Other': []}
    bump = 0
    for c in [x for x in log.split('\x1e') if x.strip()]:
        h, s, b = (c.strip('\n').split('\x1f') + ['', ''])[:3]
        m = re.match(r'^(\w+)(?:\([^)]*\))?(!)?:\s*(.+)$', s)
        if m and (m.group(2) or 'BREAKING CHANGE' in b):
            bump = 3
            mig = [l.strip() for l in b.split('\n') if re.match(r'\s*(Migration|BREAKING CHANGE):', l)]
            groups['Breaking (migration notes)'].append(f'- {s} ({h})' + ''.join(f'\n  {x}' for x in mig))
        else:
            g = 'Features' if m and m.group(1) == 'feat' else 'Fixes' if m and m.group(1) in ('fix', 'perf') else 'Other'
            bump = max(bump, 2 if g == 'Features' else 1)
            groups[g].append(f'- {s if g == "Other" else m.group(3)} ({h})')
    if not bump:
        print(f'kittool release: nothing since {last or "the first commit"}')
        return 0
    ver = f'v{major + 1}.0.0' if bump == 3 else f'v{major}.{minor + 1}.0' if bump == 2 else f'v{major}.{minor}.{patch + 1}'
    retired = [l[1:] for l in _git(kit, 'log', rng, '-p', '--unified=0', '--format=', '--', 'LESSONS.md').stdout.split('\n') if l.startswith('-- ')]
    notes = [f'# {ver} ({datetime.date.today().isoformat()})', '']
    for g, items in groups.items():
        if items:
            notes += [f'## {g}', *items, '']
    if retired:
        notes += ['## Retired lessons (orch.ps1 learn -History)', *[f'- {x[2:]}' for x in retired[:200]], '']
    text = '\n'.join(notes)
    print(text)
    if '--tag' in a or '--publish' in a:
        nf = osp.join(kit_path('cache', create=True, kit=kit), f'release-{ver}.md')
        with open(nf, 'w', encoding='utf-8') as fh:
            fh.write(text)
        r = _git(kit, 'tag', '-a', ver, '-F', nf)
        print(f'tag {ver}: ' + ('created (push it: git push origin ' + ver + ')' if not r.returncode else r.stderr.strip()))
        if '--publish' in a and not r.returncode:
            gh = shutil.which('gh')
            if not gh:
                print('kittool release: gh not on PATH: the GitHub release was not published')
                return 1
            p = subprocess.run([gh, 'release', 'create', ver, '-F', nf, '--title', ver], cwd=kit, capture_output=True, text=True, encoding='utf-8')
            print((p.stdout or p.stderr).strip())
            return p.returncode
    return 0

# ==== prose: check a text against templates.md "Writing standards"
REQ_RX = {'link': r'https?://\S+|\b[\w.-]+[!#]\d+\b|\b(?:MR|PR)\s*!?#?\d+',
  'id': r'\b[A-Z][A-Z0-9]*-\d+\b|#\d+\b|\b[A-Z]\d+\b|\b[0-9a-z]{7,}\b|\bCU-\w+',
  'path': r'[\w./-]+\.(?:md|ps1|py|mjs|js|ts|json|java|xml|ya?ml|cs|go|rs|kt|sql|html?)\b(?::\d+)?|<kit>/\S+',
  'cmd': r'`[^`]*\b(?:pwsh|python|node|git|dev\.ps1|orch\.ps1|qa\.ps1|swarm\.ps1|localenv\.ps1|kittool\.py|devtools\.py|npm|&)\b[^`]*`',
  'evidence': r'\.(?:png|jpe?g|json|log|txt|html?)\b|https?://\S+',
  'expected': r'(?i)\bexpected\b', 'options': r'(?m)^\s*[-*]?\s*(?:Option\s+)?A[:)]', 'recommended': r'(?i)\brecommended\b',
  'verdict': r'\b(?:PASS|FAIL|BLOCKED|PASS_WITH_NOTE|NOT_TESTED)\b',
  'conv': r'^(?:feat|fix|refactor|perf|docs|test|chore|build|ci|style|revert)(?:\([^)]+\))?!?: \S'}

def writing_standards(kit):
    """templates.md "Writing standards" -> ({kind: {format, limits, required}}, [banned regex])."""
    t = read(osp.join(kit, 'skills', 'dev-kit', 'templates.md'))
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
    st = (load_json(osp.join(main_clone(KIT_DIR), 'skills', 'dev-kit', 'kit.local.json'))[0] or {}).get('commitStyle', 'conventional')
    return REQ_RX['conv'] if st == 'conventional' else r'\S' if st == 'free' else st

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
        rx = commit_rx() if r == 'conv' else REQ_RX.get(r)
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

def cmd_budget(a):
    """kittool.py budget [show] | budget raise -Reason "<why trimming cannot make room>": the kit total vs _manifest.caps.totalTokens;
 raise (only while the total is over the cap) multiplies the cap by 1.1, rounded to 1k, in kit.example.json and the CAPS fallback,
 and prints the commit message carrying the reason (stored nowhere else)."""
    kit = KIT_DIR
    r = subprocess.run(['git', '-C', kit, 'ls-files'], capture_output=True, text=True, encoding='utf-8', timeout=30)
    files = [x for x in r.stdout.splitlines() if x and not x.startswith(GENERATED) and os.path.isfile(os.path.join(kit, x))]
    total, cap = sum(size_tokens(kit, f) for f in files), {**CAPS, **(manifest(kit).get('caps') or {})}['totalTokens']
    if not a or a[0] == 'show':
        print(f'kit total {total} of cap {cap} ({total * 100 // cap}%); next raise step {cap_next(cap)}')
        return 0
    low = [x.lower() for x in a]
    why = a[low.index('-reason') + 1].strip() if '-reason' in low and low.index('-reason') + 1 < len(a) else ''
    if a[0] != 'raise' or not why:
        print(cmd_budget.__doc__, file=sys.stderr)
        return 2
    if total <= cap:
        print(f'budget raise: refused - the kit total {total} fits the cap {cap}: nothing to raise', file=sys.stderr)
        return 1
    bad = cap_problem(kit, cap_next(cap))
    if bad:
        print(f'budget raise: refused - {bad}', file=sys.stderr)
        return 1
    new = cap_next(cap)
    _sub_file(kit, PATHS_JSON, lambda t: re.sub(r'("totalTokens":\s*)\d+', lambda m: m.group(1) + str(new), t, count=1))
    _sub_file(kit, 'skills/orchestrate/kittool.py', lambda t: re.sub(r"^(CAPS = \{.*'totalTokens': )\d+", lambda m: m.group(1) + str(new), t, count=1, flags=re.M))
    print(f'cap {cap} -> {new} (kit total {total}); commit message: chore(kit): raise the token cap to {new} - {why}')
    if total > new:
        print(f'still over: {total} > {new}: trim more (one raise per commit)')
    return 0


# ==== main
# per subcommand: switches, value flags, positional kit dir allowed? (`lint --help` once became a kit dir)
ARGS = {'lint': ({'--summary', '--warn', '--no-flow'}, {'--org-terms', '--json'}, True),
  'flow': ({'--readme', '--watch', '--open', '--public'}, {'--out', '--minutes'}, True),
  'port': ({'--check'}, set(), False),
  'audit': ({'--fix', '--fill'}, {'--kit', '--json'}, False),
  'cost': ({'--steps', '--routes', '--json'}, set(), True),
  'prose': ({'--json', '--kinds'}, {'--kind'}, False),
  'new': (set(), {'--crew', '--skill'}, False), 'rename': (set(), set(), False), 'remove': (set(), set(), False),
  'release': ({'--tag', '--publish'}, set(), False), 'budget': (set(), {'-Reason', '-reason', '--reason'}, False)}
AUDIT_VERBS = {'setup', 'config', 'recover', 'scan', 'stamp', 'due'}

def is_kit(d):
    return osp.isdir(osp.join(d, 'skills')) and any(osp.isfile(osp.join(d, f)) for f in ('AGENTS.md', 'CLAUDE.md'))

def check_args(cmd, rest):
    """None = go on; else the exit code: --help/-h prints usage (0); an unknown command, flag or a non-kit dir is a usage error (2)."""
    if cmd in ('-h', '--help', 'help') or (cmd in ARGS and any(x in ('-h', '--help') for x in rest)):
        print(__doc__)
        return 0
    if cmd not in ARGS or (cmd == 'audit' and (not rest or rest[0] not in AUDIT_VERBS)):
        print(__doc__)
        return 2
    if '--kit' in rest and rest.index('--kit') + 1 < len(rest) and not is_kit(rest[rest.index('--kit') + 1]):
        print(f'kittool {cmd}: --kit {rest[rest.index("--kit") + 1]!r} is not a kit folder', file=sys.stderr)
        return 2
    switches, valued, positional = ARGS[cmd]
    i = 0
    while i < len(rest):
        x = rest[i]
        if x in valued:
            if i + 1 >= len(rest):
                print(f'kittool {cmd}: {x} needs a value', file=sys.stderr)
                return 2
            i += 2
            continue
        if x.startswith('-') and x != '-' and x not in switches:
            print(f'kittool {cmd}: unknown option {x} (kittool.py --help)', file=sys.stderr)
            return 2
        if not x.startswith('-'):
            if cmd == 'audit' and i == 0 and x in AUDIT_VERBS:
                pass
            elif cmd in ('prose', 'new', 'rename', 'remove', 'budget'):
                pass   # file to check / part kind + names
            elif not positional or not is_kit(x):
                print(f'kittool {cmd}: {x!r} is not a kit folder (needs skills/ and AGENTS.md or CLAUDE.md)', file=sys.stderr)
                return 2
        i += 1
    return None

if __name__ == '__main__':
    getattr(sys.stdout, 'reconfigure', lambda **_: None)(encoding='utf-8')
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    rc = check_args(cmd, rest)
    if rc is not None:
        sys.exit(rc)
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
    if cmd == 'new':
        sys.exit(cmd_new(rest))
    if cmd == 'rename':
        sys.exit(cmd_rename(rest))
    if cmd == 'remove':
        sys.exit(cmd_remove(rest))
    if cmd == 'release':
        sys.exit(cmd_release(rest))
    if cmd == 'budget':
        sys.exit(cmd_budget(rest))
    print(__doc__)
    sys.exit(2)
