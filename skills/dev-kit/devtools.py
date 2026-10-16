"""devtools.py: tracker / git-host / docs helpers for agents (dev-kit steps 6-7). Host and project come from the worktree's
`origin` remote, the MR target from its dev.ps1 wt record.

 python devtools.py task <taskId>   summary: name | status | url | parent
 python devtools.py subtasks <parentId> [status ...]   id | status | name
 python devtools.py newtask <listId|-> <parentId|-> <assignee|-> "<name>" <desc.md>
 python devtools.py status <taskId> "<status>"   logical (review, promoted, inTest, closed) or the tracker's own name
 python devtools.py comment <taskId> <file.md | "text"> [kind]   kind: comment-status (default), comment-deploy, decision-request ...
 python devtools.py finish <taskId> <guideUrl|guide.md> <solution.md> [review]   guide link on top, one solution comment (+ guide link), status
 python devtools.py mr <worktree> "<title>" <body.md> [target]   open a merge/pull request from the current branch
 python devtools.py merge <worktree> <iid>   merge now (per repos[].mergeMethod; green / no CI) or arm merge-when-green; waits <= 90 s;
  last line (read back): MERGED / SCHEDULED / WAIT (also: producer unmerged) / CONFLICT / PIPELINE_FAILED / NOT_MERGED
 python devtools.py doc "<title>" <file.html|.md> [parent] [--type <t>]   publish a document (reports.type); prints its URL/path
 python devtools.py evidence "<name>" [--parent <id>] [--folder <id>] <file> ...   host evidence files (gdocs: Drive) -> JSON
 python devtools.py keepboth <file> [...]   append-only rebase conflicts: keep OURS then THEIRS
 python devtools.py lbcheck <master.xml> [since]   Liquibase sanity check (run by dev.ps1 check -Step migrations)
 python devtools.py selftest   offline self-test
 python devtools.py migrations classify|plan|rules|selftest ...   local env migration audit (localenv.ps1)
 python devtools.py findings schema   the 23 keys with their formats, an example, the project profile shape
 python devtools.py findings validate <module>.json [...]   check a module audit's findings against the schema
 python devtools.py findings summary <module>.json [--sources ".."] [--out <dir>]   <module>-summary.md + .html
Exit codes: 0 ok · 1 problem (merge refused, conflict, check issues) · 2 usage error.

Config (..\\kit.local.json): "tracker" (dev.ps1 tracker, default none), "reports" + "driveParent" (doc / evidence:
kit.example.json reports._readme), "gitHost" / "githubHost" (self-hosted; default gitlab.com / github.com).
Windows: run from PowerShell (python hangs in git-bash); Linux/macOS: python3. CLIs are resolved with shutil.which.
"""
import argparse, hashlib, html, json, os, re, shutil, subprocess, sys, tempfile, time
from collections import Counter
import xml.etree.ElementTree as ET

KIT = os.path.dirname(os.path.abspath(__file__))  # dev-kit skill folder
KIT_DIR = os.path.dirname(os.path.dirname(KIT))   # the kit (.claude)
def _cfg_file():
    own = os.path.join(KIT, 'kit.local.json')
    if os.path.exists(own):
        return own
    try:   # linked kit worktree: the main clone's
        cd = subprocess.run(['git', '-C', KIT, 'rev-parse', '--path-format=absolute', '--git-common-dir'], capture_output=True,
             text=True, encoding='utf-8', timeout=10).stdout.strip()
        alt = os.path.join(os.path.dirname(cd), 'skills', 'dev-kit', 'kit.local.json') if cd else ''
        return alt if alt and os.path.exists(alt) else own
    except Exception:
        return own


try:
    CFG = json.load(open(_cfg_file(), encoding='utf-8'))
except Exception:
    CFG = {}
GWS = shutil.which('gws')
RCFG = CFG.get('reports') or {}
REPORT_TYPE = (os.environ.get('KIT_REPORT_TYPE') or RCFG.get('type') or ('gdocs' if GWS else 'markdown')).lower()
ADAPTERS = {}   # kind -> name -> {verb: fn(a)}


def _todo(verb):
    raise SystemExit(f'adapter verb {verb} is a stub (kittool.py new adapter): implement it first')


import contextlib
with open(os.path.join(KIT, 'kit.example.json'), encoding='utf-8') as _f:
    MAP = json.load(_f)['_paths']


def runtime_dir(kit=None):
    return os.environ.get('CLAUDE_RUNTIME') or os.path.join(kit or KIT_DIR, MAP['runtimeDir'])


def kit_path(name, create=False, kit=None):
    """Absolute path of a named runtime / durable entry; kit= another kit folder."""
    if name == 'runtime':
        p, is_dir = runtime_dir(kit), True
    elif name in MAP['runtime'] or name in MAP['durable']:
        rt = name in MAP['runtime']
        rel = MAP['runtime' if rt else 'durable'][name]
        p, is_dir = os.path.join(runtime_dir(kit) if rt else os.path.join(kit or KIT_DIR, MAP['stateDir']), rel.rstrip('/')), rel.endswith('/')
    else:
        raise KeyError(f'kit_path: unknown name {name!r} (see skills/dev-kit/kit.example.json _paths)')
    p = os.path.normpath(p)
    if create:
        os.makedirs(p if is_dir else os.path.dirname(p), exist_ok=True)
    return p


@contextlib.contextmanager
def locked(path, stale=120):
    lock = path + '.lock'
    fd = None
    end = time.time() + stale + 10   # a dead writer's stale lock is taken over first
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
            if time.time() > end:   # never run unlocked
                raise TimeoutError(f'could not lock {path} within {stale + 10} s ({lock} is held)')
            time.sleep(0.1)
    try:
        yield
    finally:
        if fd is not None:
            os.close(fd)
            with contextlib.suppress(OSError):
                os.remove(lock)


# reads retry transient errors (2 s, 6 s) in one deadline; writes never (a lost reply would duplicate)
TRANSIENT = re.compile(r'(?i)timed? ?out|connection (reset|refused|closed|aborted)|could not resolve|no such host|unreachable|dial tcp|\bEOF\b|TLS handshake|temporar|\b(429|500|502|503|504)\b|bad gateway|service unavailable|too many requests')
STOP_AT = [0.0]   # auto_merge's deadline


def _is_write(cmd):
    s = [str(c) for c in cmd[1:]]
    m = next((s[i + 1] for i, c in enumerate(s[:-1]) if c in ('-X', '--method')), 'GET')
    return m.upper() != 'GET' or any(w in s[:4] for w in ('create', 'merge', 'update', 'comment', 'note', 'edit', 'close', 'upload', 'delete'))


def _run(cmd, cwd=None, check=False, write=None):
    if not cmd[0]:
        raise SystemExit(f'CLI not found on PATH for: {cmd[1:3]}')
    sec = min(120, int(os.environ.get('KIT_NET_TIMEOUT_SEC') or (CFG.get('net') or {}).get('timeoutSec') or 120))   # the whole deadline
    write = _is_write(cmd) if write is None else write
    tries, delay, hangs = 1 if write else max(1, int(os.environ.get('KIT_NET_TRIES') or 3)), 2, 0
    end = min(time.time() + sec, STOP_AT[0] or float('inf'))
    for i in range(1, tries + 1):
        left = max(10 if STOP_AT[0] else 1, int((end - time.time()) / (2 if i == 1 and tries > 1 else 1)))   # half kept for the retry
        try:
            p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding='utf-8', timeout=left)
            out, rc, hung = ((p.stdout or '') + (p.stderr or '')).strip(), p.returncode, False
        except subprocess.TimeoutExpired:
            out, rc, hung, hangs = f'error: timed out after {left} s', -1, True, hangs + 1
        if not rc or i >= tries or hangs > 1 or not (hung or TRANSIENT.search(out)) or end - time.time() < delay + 5:
            break
        time.sleep(delay)
        delay *= 3
    if check and hung:
        raise SystemExit(f'timed out after {sec} s: {" ".join(str(c) for c in cmd[-4:])[:120]}')
    if check and rc:
        raise SystemExit(f'failed (exit {rc}): {" ".join(str(c) for c in cmd[-4:])[:120]}\n{out[-600:]}')
    return out


def _json(out):
    """The first JSON value (CLIs may print notices around it)."""
    starts = [i for i in (out.find('{'), out.find('[')) if i >= 0]
    try:
        return json.JSONDecoder().raw_decode(out[min(starts):])[0] if starts else json.loads(out)
    except Exception:
        return {'raw': out}


def _text(arg):
    return open(arg, encoding='utf-8').read() if os.path.isfile(arg) else arg


def _body(arg):
    """A file's text, or multi-line text; a missing file is an error, never the body."""
    if os.path.isfile(arg) or '\n' in arg:
        return _text(arg)
    raise SystemExit(f'file not found: {arg} - write it first (nothing was created)')


# --- Tracker (dev.ps1 tracker)
DEV = os.path.join(KIT, 'dev.ps1')   # tracker adapter
PWSH = shutil.which('pwsh') or shutil.which('powershell')
TRACKER_TYPE = (os.environ.get('KIT_TRACKER_TYPE') or (CFG.get('tracker') or {}).get('type') or 'none').lower()


def _tracker(*args):
    """dev.ps1 tracker <verb>; long texts go via a temp file."""
    tmp = []
    try:
        argv = []
        for x in args:
            x = str(x)
            if (len(x) > 200 or '\n' in x) and (not argv or argv[-1] != '-Name'):   # a name stays an argument
                fd, p = tempfile.mkstemp(suffix='.md')
                with os.fdopen(fd, 'w', encoding='utf-8', newline='') as fh:
                    fh.write(x)
                tmp.append(p)
                x = p
            argv.append(x)
        w = bool(argv) and argv[0] in ('status', 'comment', 'describe', 'create', 'rename', 'attach')
        return _run([PWSH, '-NoProfile', '-NonInteractive', '-File', DEV, 'tracker', *argv], check=w, write=w)
    finally:
        for p in tmp:
            with contextlib.suppress(OSError):
                os.remove(p)


def task(tid):
    """{id, name, status, url, parent, assignees[], subtasks[{id,name,status,url}], list, description}"""
    return _json(_tracker('view', tid))


def task_url(tid):
    return _tracker('url', tid).strip()


def subtasks(parent, statuses=None):
    want = {s.lower() for s in statuses or ()}
    rows = [(str(s['id']), s.get('status') or '', s.get('name') or '') for s in task(parent).get('subtasks') or []]
    return [r for r in rows if not want or r[1].lower() in want]


def prose(kind, text):
    """Print kittool.py prose findings for a text about to be published; never truncates."""
    tool = os.path.join(KIT_DIR, 'skills', 'orchestrate', 'kittool.py')
    if not os.path.isfile(tool):
        return []
    try:
        r = subprocess.run([sys.executable, '-X', 'utf8', tool, 'prose', '--kind', kind, '-', '--json'], input=text, capture_output=True,
            text=True, encoding='utf-8', timeout=30)
        found = json.loads(r.stdout).get('findings', [])
    except (ValueError, OSError, subprocess.SubprocessError):
        return []
    for f in found:
        print(f'[prose] {kind}: {f} (templates.md "Writing standards": rewrite, nothing was cut)', file=sys.stderr)
    return found


def new_task(list_id, parent, assignee, name, desc_md, priority='2'):
    prose('task-name', name)
    prose('task-description', desc_md)
    args = ['create', '-Name', name, '-Description', desc_md, '-Priority', priority]
    for flag, v in (('-List', list_id), ('-Parent', parent), ('-Assignee', assignee)):
        if v and v != '-':
            args += [flag, v]
    return _json(_tracker(*args)).get('id')


def set_status(tid, status):
    """status: logical (tracker.statuses) or the tracker's own name."""
    return _tracker('status', tid, status)


def comment(tid, text, kind='comment-status'):
    prose(kind, text)
    return _tracker('comment', tid, text)


def finish(tid, guide_url, solution_md, status='review'):
    if os.path.isfile(guide_url):   # publish it: never link a local path
        guide_url = make_doc(os.path.splitext(os.path.basename(guide_url))[0], guide_url)
    t = task(tid)
    md = t.get('description') or ''
    # failed lookup: describing would wipe the description
    if t.get('id') and t.get('name') and guide_url not in md:
        _tracker('describe', tid, f'Testing doc: {guide_url}\n\n{md}')
    if guide_url not in solution_md:
        solution_md = f'{solution_md.rstrip()}\n\n**Testing doc**: {guide_url}'
    comment(tid, solution_md, 'comment-solution')
    set_status(tid, status)


# --- Git host: lib.ps1 section 5 adapters via dev.ps1 host
GITLAB_HOST = CFG.get('gitHost') or 'gitlab.com'
GITHUB_HOST = CFG.get('githubHost') or 'github.com'
if CFG.get('gitHost') and not os.environ.get('GITLAB_HOST'):   # else glab api outside a checkout hits gitlab.com
    os.environ['GITLAB_HOST'] = CFG['gitHost']


def host_kind(host):
    """Adapter name of a host (as lib.ps1 Get-HostKind)."""
    # gitHost unset: gitHostType names any origin host
    if CFG.get('gitHostType') and (host == GITLAB_HOST or (not CFG.get('gitHost') and host != GITHUB_HOST)):
        return CFG['gitHostType']
    if host == GITHUB_HOST:
        return 'github'
    return next((k for k, rx in (('github', 'github'), ('bitbucket', 'bitbucket'), ('azure', r'dev\.azure\.com|visualstudio\.com'),
                  ('gitea', 'gitea|forgejo|codeberg')) if re.search(rx, host)), 'gitlab')


def remote(worktree):
    """(adapter, project path) of the worktree's origin (Azure: org/project/repo)."""
    url = _run(['git', '-C', worktree, 'remote', 'get-url', 'origin']).strip()
    m = re.match(r'^(?:\w+://)?(?:[^@/\s]+@)?(?:ssh\.)?([^/:\s]+)(?::\d+)?[:/](?:v3/)?(.+?)(?:\.git)?/?$', url)
    if not m:
        raise SystemExit(f'unsupported remote: {url}')
    return host_kind(m.group(1)), m.group(2).replace('/_git/', '/')


def _host(verb, **a):
    """One git-host / ci verb via dev.ps1 host; JSON from the last line (ci.log: text); unknown = {'raw': output}."""
    fd, p = tempfile.mkstemp(suffix='.json')
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(a, fh)
    try:
        out = _run([PWSH, '-NoProfile', '-NonInteractive', '-File', DEV, 'host', verb, '@' + p], write=verb in ('mr.create', 'mr.merge', 'mr.unauto'))
    finally:
        os.remove(p)
    if verb == 'ci.log':
        return out
    try:
        v = json.loads((out.strip().splitlines() or ['null'])[-1])
    except ValueError:
        v = None
    return {'raw': out} if v is None else v


def _mr_api(host, proj, iid):
    return lambda verb, **a: _host(verb, **{'type': host, 'repo': proj, 'n': str(iid), **a})


def target_of(worktree):
    """MR target: the worktree's record (dev.ps1 wt new), else kit.local.json repos[].target, else origin/HEAD.
    A fallback is printed (stderr) with its source; None when all three are missing."""
    gd = _run(['git', '-C', worktree, 'rev-parse', '--git-dir'])
    gd = gd if os.path.isabs(gd) else os.path.join(worktree, gd)
    f = os.path.join(gd, 'claude-target')
    if os.path.exists(f):
        with open(f, encoding='utf-8-sig') as fh:
            return fh.read().strip() or None
    # repos[]: checkout = this main checkout, or name/alias = remote repo name
    common = _run(['git', '-C', worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir'])
    main = os.path.normcase(os.path.dirname(os.path.normpath(common))) if os.path.isdir(common) else ''
    try:
        name = remote(worktree)[1].rsplit('/', 1)[-1].lower()
    except SystemExit:
        name = ''
    for r in CFG.get('repos') or []:
        if not isinstance(r, dict) or not r.get('target'):
            continue
        co = r.get('checkout') or ''
        same = bool(co and main and os.path.normcase(os.path.abspath(co)) == main)
        names = [str(n).lower() for n in [r.get('name') or ''] + list(r.get('aliases') or []) if n]
        if same or (name and name in names):
            print(f"[mr] target {r['target']} (no dev.ps1 wt record; kit.local.json repos[].target of {r.get('name') or co})", file=sys.stderr)
            return r['target']
    head = _run(['git', '-C', worktree, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD'])
    if head.startswith('origin/') and '\n' not in head:
        print(f'[mr] target {head[7:]} (no dev.ps1 wt record, no kit.local.json repos[].target; origin/HEAD)', file=sys.stderr)
        return head[7:]
    return None


MR_SECTIONS = ('## Summary', '## Changes', '## How tested', '## Risks', '## Links')  # templates.md "MR body"
FOOTER = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'


def _verified_gaps(body_md):
    """True when '## How tested' has no 'Not run:' / 'Pure logic:' line."""
    m = re.search(r'^## How tested[^\n]*\n(.*?)(?=^## |\Z)', body_md, re.M | re.S)
    sec = m.group(1) if m else ''
    return bool(m) and not re.search(r'(?im)^\s*[-*]?\s*(\*\*)?(not run|pure logic)(\*\*)?\s*:', sec)


UI_FILES = re.compile(r'\.(html?|s?css|less|sass|tsx|jsx|vue|svelte)$|(^|/)res/layout[^/]*/[^/]+\.xml$', re.I)


def _ui_line_missing(worktree, tgt, body_md):
    """Changed UI files vs origin/<target> when the body has no 'UI:' line, else []."""
    if re.search(r'(?im)^\s*[-*]?\s*(\*\*)?UI(\*\*)?\s*:', body_md) or not tgt:
        return []
    out = _run(['git', '-C', worktree, 'diff', '--name-only', f'origin/{tgt}...HEAD'])
    return [f for f in out.splitlines() if UI_FILES.search(f.strip())]


TASK_LINK = {'clickup': 'clickup.com', 'github': '/issues/', 'gitlab': '/issues/', 'jira': '/browse/', 'jira-server': '/browse/',
             'linear': 'linear.app', 'azure': '_workitems', 'youtrack': '/issue/'}


def mr_create(worktree, title, body_md, tgt=None):
    missing = [h for h in MR_SECTIONS if h not in body_md]
    if missing:
        print(f'[mr] body is missing {missing} - templates.md "MR body"', file=sys.stderr)
    prose('mr-title', title)
    prose('mr-body', body_md)
    if _verified_gaps(body_md):
        print('[mr] "## How tested" has neither a "Not run: <gate and why>" nor a "Pure logic: <spec file or node output>" line'
             ' - say what was not run (or "Not run: nothing") - see templates.md "MR body"', file=sys.stderr)
    link = TASK_LINK.get(TRACKER_TYPE)
    if link and link not in body_md:
        print(f'[mr] body has no tracker ({TRACKER_TYPE}) task link', file=sys.stderr)
    if FOOTER not in body_md:
        body_md = body_md.rstrip() + '\n\n' + FOOTER + '\n'
    host, proj = remote(worktree)
    src = _run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'])
    tgt = tgt or target_of(worktree)
    if not tgt:
        raise SystemExit('no target: no dev.ps1 wt record, no kit.local.json repos[].target for this repo and no origin/HEAD'
                  ' - pass it as the 4th argument (git remote set-head origin --auto fixes origin/HEAD)')
    ui = _ui_line_missing(worktree, tgt, body_md)
    if ui:
        print(f'[mr] the diff touches templates/styles ({", ".join(ui[:3])}{" ..." if len(ui) > 3 else ""}) but "## How tested" has no'
         ' "UI: <committed spec or screenshot link>" line (or "UI: not a UI change") - templates.md "MR body"', file=sys.stderr)
    m = _host('mr.create', type=host, repo=proj, source=src, target=tgt, title=title, body=body_md)
    url = m.get('web_url') if isinstance(m, dict) else None
    if not url:   # a retry after a timeout: the first call's MR
        ex = _host('mr.list', type=host, repo=proj, state='opened', source_branch=src)
        url = next((x['web_url'] for x in ex if isinstance(x, dict) and x.get('web_url')), None) if isinstance(ex, list) else None
        if url:
            print(f'[mr] an open MR from {src} already exists (a previous call opened it): {url} - update its description if needed', file=sys.stderr)
    if not url:
        raise SystemExit(f'MR not created: {str(m)[:500]}')
    return url


def _remember_automerge(ref):
    """GitLab drops merge-when-green on a new push (e.g. a rebase): record the intent in the durable tracking file ("automerge");
    orch.ps1 track run re-arms it every supervise round until the MR merges."""
    path = kit_path('tracking')
    try:
        with locked(path):
            data = json.load(open(path, encoding='utf-8-sig')) if os.path.exists(path) else {}
            data = data if isinstance(data, dict) else {}
            data.setdefault('tasks', {})
            am = data['automerge'] if isinstance(data.get('automerge'), dict) else {}
            am[ref] = time.strftime('%Y-%m-%dT%H:%M:%S')
            data['automerge'] = am
            with open(path + '.tmp', 'w', encoding='utf-8') as f:
                json.dump(data, f, indent=1)
            os.replace(path + '.tmp', path)
    except Exception as e:   # a lost intent is never re-armed
        print(f'[merge] could not record the merge-when-green intent for {ref} in {path}: {e}', file=sys.stderr)


MERGE_WORDS = ('MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED')
RESOLVE = 'dev.ps1 wt sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again'


def merge_word(res):
    """auto_merge's last-line status word (NOT_MERGED when none)."""
    last = (str(res or '').strip().splitlines() or [''])[-1].strip()
    return last if last in MERGE_WORDS else 'NOT_MERGED'


def _progress(msg):
    print(f'[merge] {msg}', flush=True)


def _final(H, iid, put, st, proj):
    """Re-read the MR after the merge call -> result text + status word."""
    m = {}
    for i in range(4):
        m = H('mr.get')
        m = m if isinstance(m, dict) else {}
        if m.get('state') == 'merged' or m.get('merge_when_pipeline_succeeds') or i == 3:
            break
        _progress(f're-reading !{iid} ({m.get("detailed_merge_status") or m.get("state")})')
        time.sleep(3)
    put = put if isinstance(put, dict) else {}
    hp = (m.get('head_pipeline') or {}).get('status')
    if m.get('state') == 'merged':
        return f'merged !{iid}\nMERGED'
    if m.get('merge_when_pipeline_succeeds') or put.get('merge_when_pipeline_succeeds') or put.get('auto_merge') == 'kit':   # kit: emulated (orch.ps1 track run)
        _remember_automerge(f'{proj}!{iid}')
        return f'scheduled: !{iid} merges automatically when the pipeline ({st}) succeeds\nSCHEDULED'
    if m.get('has_conflicts') or m.get('detailed_merge_status') == 'conflict':
        return f'conflict on !{iid}: {RESOLVE}\nCONFLICT'
    if hp in ('failed', 'canceled'):
        return f'pipeline {hp} on !{iid}: fix it, do not merge\nPIPELINE_FAILED'
    if hp in ('running', 'pending') or (not hp and st in ('running', 'pending')):   # the host merges only with required checks
        return f'!{iid}: checks still running, no merge scheduled (no required checks?): run merge again in a few minutes\nWAIT'
    return f'not merged: !{iid} is {m.get("state")} ({m.get("detailed_merge_status")}); merge reply: {str(put)[:300]}\nNOT_MERGED'


def _norm_ref(ref):
    """'web!12', quoted ref, MR/PR URL or alias -> (repo, iid) as orch.ps1 track stores them."""
    r = str(ref or '').strip().strip('\'"')
    group = CFG.get('gitlabGroup') or ''
    m = re.search(r'://[^/]+/(?P<p>[\w./-]+?)/(?:-/merge_requests|pulls?|pull-requests|pullrequest)/(?P<i>\d+)', r)
    if m:
        p = m.group('p').replace('/_git/', '/')
        if group and p.lower().startswith(group.lower() + '/'):
            p = p[len(group) + 1:]
        r = f"{p}!{m.group('i')}"
    m = re.match(r'^(?P<repo>[\w./-]+)!(?P<iid>\d+)$', r)
    if not m:
        return None
    repo = m.group('repo')
    repo = str((CFG.get('repoAliases') or {}).get(repo) or repo)
    return repo, m.group('iid')


def _same_repo(repo, proj):
    """Does a ref's repo ('web', 'group/web') name the origin path ('group/sub/web')?"""
    a, b = repo.lower().strip('/'), proj.lower().strip('/')
    return a == b or b.endswith('/' + a)


def _host_mr_state(host, proj, repo, iid):
    """State of <repo>!<iid> ('' = unknown), path resolved like orch.ps1 track."""
    if '/' in repo:
        path = repo
    else:
        group = CFG.get('gitlabGroup') if host == 'gitlab' else ''
        path = f"{group or proj.rsplit('/', 1)[0]}/{repo}"
    m = _host('mr.get', type=host, repo=path, n=str(iid))
    return str(m.get('state') or '') if isinstance(m, dict) else ''



def unmerged_producers(proj, iid, state_of, tracking=None):
    """Unmerged producers of this MR (<proj>!<iid>): tracking-file mergeAfter pairs ('<consumer>!<iid>><producer>!<iid>', orch.ps1
    track add -MergeAfter). state_of(repo, iid) -> 'merged'/'opened'/'closed'/''. Returns [(producer ref, state, task id)]."""
    path = tracking or kit_path('tracking')
    try:
        with open(path, encoding='utf-8-sig') as fh:
            data = json.load(fh) if os.path.exists(path) else {}
    except FileNotFoundError:
        data = {}
    except Exception as e:   # order unknown -> WAIT, never "no producers"
        return [(f'(tracking file unreadable: {e})', 'unknown', '-')]
    out = []
    for tid, t in ((data or {}).get('tasks') or {}).items():
        if not isinstance(t, dict):
            continue
        for pair in t.get('mergeAfter') or []:
            dep, sep, on = str(pair).partition('>')
            d, o = _norm_ref(dep), _norm_ref(on)
            if not sep or not d or not o or str(d[1]) != str(iid):
                continue
            if not _same_repo(d[0], proj):
                print(f'[merge] mergeAfter {pair} (task {tid}) names repo {d[0]}, this remote is {proj}: not applied'
                       ' - add kit.local.json repoAliases if they are the same repo', file=sys.stderr)
                continue
            st = state_of(o[0], o[1])
            if st != 'merged':
                out.append((f'{o[0]}!{o[1]}', st or 'unknown', tid))
    return out


def held(proj):
    """holdMerge: true (all) or repo names / aliases / paths no script merges."""
    h = CFG.get('holdMerge')
    if h is True:
        return True
    names = [str((CFG.get('repoAliases') or {}).get(x) or x) for x in (h if isinstance(h, list) else [])]
    return any(_same_repo(n, proj) for n in names)


def auto_merge(worktree, iid, max_wait=90):
    STOP_AT[0] = time.time() + max_wait   # 10 s floor per call
    try:
        return _auto_merge(worktree, iid, max_wait)
    finally:
        STOP_AT[0] = 0.0


def _auto_merge(worktree, iid, max_wait):
    """Merge when green (GitLab merge-when-pipeline-succeeds, GitHub auto-merge), or at once when green already or without CI.
    Waits <= max_wait s with flushed progress (fits a tool timeout). Last line = one merge_word, read back from the host:
    MERGED / SCHEDULED / WAIT (run again later) / CONFLICT / PIPELINE_FAILED / NOT_MERGED. Unmerged producer (track -MergeAfter): WAIT."""
    iid = str(iid).strip().rsplit('!', 1)[-1].lstrip('#')   # '!203' / 'web!203' / '#12' -> the number
    host, proj = remote(worktree)
    if held(proj):
        return f'{proj}!{iid} is held for approval (kit.local.json holdMerge): a person merges it\nNOT_MERGED'
    waiting = unmerged_producers(proj, iid, lambda r, i: _host_mr_state(host, proj, r, i))
    if waiting:
        lines =[f'waiting for producer {ref} ({st}; task {tid}): {proj}!{iid} merges only after it' for ref, st, tid in waiting]
        if any(st == 'closed' for _, st, _ in waiting):
            return '\n'.join(lines) + '\nproducer MR closed: fix the merge order (orch.ps1 track mergeAfter) with the coordinator\nNOT_MERGED'
        return '\n'.join(lines) + '\nnot merged now: orch.ps1 track run (supervise) merges it once the producer merged\nWAIT'
    H = _mr_api(host, proj, iid)
    m = H('mr.get')
    m = m if isinstance(m, dict) else {}
    if m.get('state') == 'merged':
        return f'already merged !{iid}\nMERGED'
    if not m.get('state'):
        return f'!{iid}: the git host did not answer (auth status? network?): run merge again\nWAIT'
    if m.get('state') != 'opened':
        return f'!{iid} is {m.get("state")}, not open\nNOT_MERGED'
    if m.get('has_conflicts') or m.get('detailed_merge_status') == 'conflict':
        return f'CONFLICT: {RESOLVE}\nCONFLICT'
    st = (m.get('head_pipeline') or {}).get('status')
    if st in ('failed', 'canceled'):
        return f'PIPELINE {st}: fix it, do not merge\nPIPELINE_FAILED'
    # no CI config -> merge now (merge-when-green would wait forever); CI + no pipeline 5 min after the MR update -> NOT_MERGED
    no_ci = False
    if st is None:
        if H('ci.config', ref=m.get('target_branch') or '') is False:
            no_ci = True
            _progress(f'repo has no CI (no CI config on {m.get("target_branch")}): merging !{iid} now')
        else:
            from datetime import datetime, timezone
            sha = m.get('sha') or ''

            def _no_ci():   # HEAD pipelines only
                runs = H('ci.runs', repo=str(m.get('source_project_id') or proj), ref=m.get('source_branch') or '', sha=sha, per_page=5)
                if not isinstance(runs, list):   # unknown, never 'no CI'
                    return False, False
                head = [p for p in runs if isinstance(p, dict) and (not sha or p.get('sha') == sha)]
                return not head, bool(head)

            when = m.get('updated_at') or m.get('created_at') or ''
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(when.replace('Z', '+00:00'))).total_seconds() if when else 0
            none_yet, has = _no_ci()
            waited = 0
            while none_yet and age + waited <= 300 and waited + 15 <= max_wait:   # progress: a tool timeout kills a silent sleep
                _progress(f'no pipeline on !{iid} yet; checking again in 15 s ({int(300 - age - waited)} s until it counts as no CI)')
                time.sleep(15)
                waited += 15
                none_yet, has = _no_ci()
            if has:
                st = 'running'
            if none_yet and age + waited > 300:   # never merge without CI
                return (f'no pipeline for the head of !{iid} although the repo has CI (skipped by rules or never started): '
                  f'run it, then merge again (or the coordinator merges by hand)\nNOT_MERGED')
            if not has:
                return f'WAIT: no pipeline on !{iid} yet (a pipeline is still expected); run merge again in {int(max(30, 310 - age - waited)) if none_yet else 60} s\nWAIT'
    if st in ('manual', 'skipped'):   # merge-when-green never fires
        return f'pipeline {st} on !{iid}: start its manual jobs (or ask the coordinator), then run merge again\nNOT_MERGED'
    if st == 'scheduled':
        return f'pipeline scheduled (delayed job) on !{iid}: run merge again once it runs\nWAIT'
    put = H('mr.merge', sha=m.get('sha') or '', auto=st != 'success' and not no_ci)   # sha: a later push refuses it
    return _final(H, iid, put, st, proj)


def merge_when_green(worktree, iid, timeout_min=90):
    """Poll; merge (per repos[].mergeMethod) when green, never on failure / conflict. Prefer auto_merge."""
    host, proj = remote(worktree)
    if held(proj):
        return f'{proj}!{iid} is held for approval (kit.local.json holdMerge)\nNOT_MERGED'
    waiting = unmerged_producers(proj, iid, lambda r, i: _host_mr_state(host, proj, r, i))
    if waiting:
        return '; '.join(f'waiting for producer {ref} ({st}; task {tid})' for ref, st, tid in waiting) + ': not merged\nWAIT'
    end = time.time() + timeout_min * 60
    H = _mr_api(host, proj, iid)
    while time.time() < end:
        m = H('mr.get')
        m = m if isinstance(m, dict) else {}
        st = (m.get('head_pipeline') or {}).get('status')
        if m.get('state') == 'merged':
            return 'already merged\nMERGED'
        if m.get('has_conflicts') or m.get('detailed_merge_status') == 'conflict':
            return 'CONFLICT: dev.ps1 wt sync, resolve (devtools.py keepboth for append-only files), re-check, push --force-with-lease to YOUR branch\nCONFLICT'
        if st in ('failed', 'canceled'):
            return f'PIPELINE {st}: fix it, do not merge\nPIPELINE_FAILED'
        if m.get('state') == 'opened' and st is None:   # no MR CI: auto_merge() decides
            res = auto_merge(worktree, iid)
            if merge_word(res) != 'WAIT':
                return res
        if st == 'success':
            return _final(H, iid, H('mr.merge', sha=m.get('sha') or ''), st, proj)
        time.sleep(60)
    return 'TIMEOUT waiting for pipeline\nWAIT'


# --- Documents: make_doc / make_evidence -> ADAPTERS['report'][reports.type]
def gws(*args, params=None, body=None, upload=None):
    if not GWS:
        raise SystemExit('reports.type is gdocs but the gws CLI is not on PATH (or set "reports": {"type": "markdown"})')
    cmd = [GWS, *args] + (['--params', json.dumps(params)] if params is not None else []) + (['--json', json.dumps(body)] if body is not None else [])
    # gws uploads only cwd files
    return _json(_run(cmd + ['--upload', os.path.basename(upload)] if upload else cmd, cwd=upload and os.path.dirname(os.path.abspath(upload))))
def _http(method, url, body=None, headers=None):
    import urllib.request as u, urllib.error
    q = u.Request(url, body and json.dumps(body).encode(), {'Content-Type': 'application/json', **(headers or {})}, method=method)
    try:
        with u.urlopen(q, timeout=int((CFG.get('net') or {}).get('timeoutSec') or 60)) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise SystemExit(f'{method} {url}: HTTP {e.code} {e.read()[:300]}')




_q = lambda s: subprocess.list2cmdline([str(s)]) if os.name == 'nt' else __import__('shlex').quote(str(s))


def keep_doc(title, path, keep=None):
    """Copy into keep (default <runtime>/work/docs); already there: in place."""
    if keep and os.path.abspath(keep) == os.path.dirname(os.path.abspath(path)):
        return path
    slug = re.sub(r'[^A-Za-z0-9]+', '-', title).strip('-')[:80] or 'doc'
    dst = os.path.join(keep or kit_path('docs', create=True), slug + os.path.splitext(path)[1])
    if os.path.abspath(dst) != os.path.abspath(path):
        shutil.copyfile(path, dst)
    return dst


def md_to_html(md, title=''):
    """Dependency-free Markdown -> HTML for `doc` (gws uploads Markdown as plain text): headings, tables, lists, emphasis, code,
    links, rules."""
    import html as _h

    def inline(t):
        t = html.escape(t, quote=False)
        t = re.sub(r'`([^`]+)`', r'<code>\1</code>', t)
        t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
        t = re.sub(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])', r'<i>\1</i>', t)
        return re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', r'<a href="\2">\1</a>', t)

    out, lines, i, lst = [], md.splitlines(), 0, None
    def close():
        nonlocal lst
        if lst:
            out.append(f'</{lst}>')
            lst = None
    while i < len(lines):
        l = lines[i]
        if l.strip().startswith('```'):
            close(); j = i + 1
            while j < len(lines) and not lines[j].strip().startswith('```'):
                j += 1
            out.append('<pre><code>' + html.escape('\n'.join(lines[i + 1:j])) + '</code></pre>'); i = j + 1; continue
        if l.startswith('|') and i + 1 < len(lines) and re.match(r'^\|[\s:|-]+\|?\s*$', lines[i + 1]):
            close(); cells = lambda r: [c.strip() for c in r.strip().strip('|').split('|')]
            rows = ['<tr>' + ''.join(f'<th>{inline(c)}</th>' for c in cells(l)) + '</tr>']
            i += 2
            while i < len(lines) and lines[i].startswith('|'):
                rows.append('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in cells(lines[i])) + '</tr>'); i += 1
            out.append('<table border="1" cellpadding="4" style="border-collapse:collapse">' + ''.join(rows) + '</table>'); continue
        m = re.match(r'^(#{1,6})\s+(.*)$', l)
        if m:
            close(); n = len(m.group(1)); out.append(f'<h{n}>{inline(m.group(2))}</h{n}>'); i += 1; continue
        m = re.match(r'^\s*([-*+]|\d+[.)])\s+(.*)$', l)
        if m:
            kind = 'ol' if m.group(1)[0].isdigit() else 'ul'
            if lst != kind:
                close(); out.append(f'<{kind}>'); lst = kind
            out.append(f'<li>{inline(m.group(2))}</li>'); i += 1; continue
        close()
        if re.match(r'^\s*([-*_])(\s*\1){2,}\s*$', l):
            out.append('<hr>')
        elif l.strip():
            out.append(f'<p>{inline(l)}</p>')
        i += 1
    close()
    return f'<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title></head><body>' + '\n'.join(out) + '</body></html>'


def _html_of(a):
    """a's file as HTML (Markdown -> <name>.doc.html)."""
    p = a['path']
    if not p.lower().endswith(('.md', '.markdown')):
        return p
    conv = os.path.splitext(p)[0] + '.doc.html'
    with open(p, encoding='utf-8') as fh, open(conv, 'w', encoding='utf-8') as out:
        out.write(md_to_html(fh.read(), a['title']))
    return conv


def make_doc(title, path, parent=None):
    """Publish via reports.type -> URL or kept path; parent: a remote id or a folder to keep it in."""
    ad = ADAPTERS['report'].get(REPORT_TYPE) or sys.exit(f'reports.type "{REPORT_TYPE}" is no report adapter ({" ".join(ADAPTERS["report"])})')
    keep = parent if parent and os.path.isdir(parent) else None
    return ad['publish']({'title': title, 'path': path, 'parent': None if keep else parent, 'keep': keep})


def make_evidence(name, files, folder=None, parent=None):
    """Host evidence files -> {folderId, folderLink, label, files}; {} = they stay in the run folder."""
    fn = (ADAPTERS['report'].get(REPORT_TYPE) or {}).get('evidence')
    return fn({'name': name, 'files': files, 'folder': folder, 'parent': parent}) if fn else {}


def _gshare(fid, what, warn=False):
    s = str(RCFG.get('share') or 'anyone')   # anyone | domain:<domain> | none
    p = s != 'none' and gws('drive', 'permissions', 'create', params={'fileId': fid, 'supportsAllDrives': True},
                body={'type': 'domain', 'role': 'reader', 'domain': s[7:]} if s[:7] == 'domain:' else {'type': 'anyone', 'role': 'reader'})
    if p is not False and not (isinstance(p, dict) and p.get('id')):
        m = f'{what} was uploaded but not shared ({s}): {str(p)[:300]} - share it by hand or fix gws auth'
        if not warn:
            raise SystemExit(m)
        print('warning: ' + m, file=sys.stderr)


def _gcreate(name, mime, parent, upload=None):
    b = {'name': name, **({'mimeType': mime} if mime else {}), **({'parents': [parent]} if parent else {})}
    return gws('drive', 'files', 'create', params={'supportsAllDrives': True, 'fields': 'id,webViewLink'}, body=b, upload=upload)


R = ADAPTERS.setdefault('report', {})
# adapter:report/gdocs: a Google Doc via gws; evidence = a Drive folder
def _gdocs(a):
    r = _gcreate(a['title'], 'application/vnd.google-apps.document', a.get('parent') or CFG.get('driveParent'), _html_of(a))
    if 'id' not in r:
        raise SystemExit(f'gws upload failed: {r}')
    url = f"https://docs.google.com/document/d/{r['id']}/edit"
    _gshare(r['id'], url)
    return url


def _gdocs_evidence(a):
    fid, link, out = a.get('folder'), None, {}
    if not fid:
        f = _gcreate(a['name'], 'application/vnd.google-apps.folder', a.get('parent') or CFG.get('driveParent'))
        fid, link = f.get('id') or sys.exit(f'gws: evidence folder not created: {str(f)[:300]}'), f.get('webViewLink')
        _gshare(fid, link, warn=True)
    for p in a['files']:   # a failed upload is left out (the caller warns)
        r = _gcreate(os.path.basename(p), None, fid, p)
        if r.get('id'):
            out[os.path.basename(p)] = {'id': r['id'], 'link': r.get('webViewLink'), 'src': 'https://drive.google.com/uc?export=view&id=' + r['id']}
    return {'folderId': fid, 'folderLink': link, 'label': 'Drive folder', 'files': out}


R['gdocs'] = {'publish': _gdocs, 'evidence': _gdocs_evidence}
# adapter:report/markdown: the file, kept
R['markdown'] = {'publish': lambda a: keep_doc(a['title'], a['path'], a['keep'])}
# adapter:report/html: Markdown -> HTML (md_to_html), kept
R['html'] = {'publish': lambda a: keep_doc(a['title'], _html_of(a), a['keep'])}
# adapter:report/pdf: the HTML printed by a headless browser (or reports.pdfCommand), kept
def _browser():
    b = next(filter(None, map(shutil.which, ('chrome', 'google-chrome', 'chromium', 'chromium-browser', 'msedge', r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'))), None)
    return b and [b]


def _pdf(a):
    src, out, cmd, b = os.path.abspath(_html_of(a)), os.path.abspath(os.path.splitext(a['path'])[0] + '.pdf'), RCFG.get('pdfCommand'), _browser()
    if os.path.exists(out):
        os.remove(out)
    r = subprocess.run(cmd.replace('{in}', _q(src)).replace('{out}', _q(out)) if cmd else (b or sys.exit('pdf: no Chrome / Chromium / Edge: install one or set reports.pdfCommand'))
             + ['--headless', '--disable-gpu', '--no-pdf-header-footer', '--print-to-pdf=' + out, __import__('pathlib').Path(src).as_uri()],
             shell=bool(cmd), capture_output=True, text=True, errors='replace', timeout=180)
    return keep_doc(a['title'], out, a['keep']) if os.path.isfile(out) else sys.exit(f'reports.type pdf: {out} not written: {(r.stdout + r.stderr)[-300:]}')


R['pdf'] = {'publish': _pdf}
# adapter:report/confluence: a page via REST: env CONFLUENCE_URL (wiki base), CONFLUENCE_TOKEN (bearer; + CONFLUENCE_EMAIL: basic),
#   reports.space, reports.parent (page id); readers = the space / parent page permissions
def _confluence(a):
    base, tok, em = (os.environ.get('CONFLUENCE_' + k, '') for k in ('URL', 'TOKEN', 'EMAIL'))
    if not (base and tok and RCFG.get('space')):
        raise SystemExit('confluence needs env CONFLUENCE_URL, CONFLUENCE_TOKEN and reports.space')
    with open(_html_of(a), encoding='utf-8') as fh:   # storage format = XHTML: the body, void tags closed
        x = re.sub(r'<(br|hr|img|meta|input|col)\b([^>]*?)/?>', r'<\1\2/>', re.sub(r'(?is)^.*?<body[^>]*>|</body>.*$', '', fh.read()))
    par, base = a['parent'] or RCFG.get('parent'), base.rstrip('/')
    auth = 'Basic ' + __import__('base64').b64encode(f'{em}:{tok}'.encode()).decode() if em else 'Bearer ' + tok
    lk = _http('POST', base + '/rest/api/content', {'type': 'page', 'title': a['title'], 'space': {'key': RCFG['space']}, **({'ancestors': [{'id': str(par)}]} if par else {}),
         'body': {'storage': {'value': x, 'representation': 'storage'}}}, {'Authorization': auth}).get('_links') or {}
    return lk.get('base', base) + lk['webui'] if lk.get('webui') else sys.exit(f'confluence: no page link in the reply: {lk}')


R['confluence'] = {'publish': _confluence}
# adapter:report/notion: a child page of reports.parent via REST (env NOTION_TOKEN): heading / paragraph / bulleted / code
#   blocks, 100 per call; readers = the parent page's sharing
def _notion(a):
    tok, par = os.environ.get('NOTION_TOKEN'), a['parent'] or RCFG.get('parent')
    if not (tok and par):
        raise SystemExit('notion needs env NOTION_TOKEN and reports.parent (a page shared with the integration)')
    with open(a['path'], encoding='utf-8') as fh:
        t = fh.read()
    if not a['path'].lower().endswith(('.md', '.markdown')):   # HTML: its text lines
        t = html.unescape(re.sub(r'<[^>]+>', '\n', re.sub(r'(?is)<(head|style|script)\b.*?</\1>', '', t)))
    rt = lambda s: [{'type': 'text', 'text': {'content': s[i:i + 2000]}} for i in range(0, len(s), 2000)]
    bl, code = [], None
    for l in t.splitlines() + ['```']:   # the extra fence closes an open code block
        if l.strip().startswith('```'):
            if code:
                bl.append({'type': 'code', 'code': {'language': 'plain text', 'rich_text': rt('\n'.join(code))}})
            code = [] if code is None else None
        elif code is not None:
            code.append(l)
        elif l.strip() and not re.match(r'^\s*(\|[\s:|-]+\|?|([-*_])(\s*\2){2,})\s*$', l):   # table rules and <hr> dropped
            h, b = re.match(r'(#{1,6})\s+(.*)', l), re.match(r'\s*(?:[-*+]|\d+[.)])\s+(.*)', l)
            k, s = (f'heading_{min(3, len(h[1]))}', h[2]) if h else ('bulleted_list_item', b[1]) if b else ('paragraph', l)
            bl.append({'type': k, k: {'rich_text': rt(s)}})
    hd, api = {'Authorization': 'Bearer ' + tok, 'Notion-Version': '2022-06-28'}, 'https://api.notion.com/v1/'
    r = _http('POST', api + 'pages', {'parent': {'page_id': par}, 'properties': {'title': {'title': [{'text': {'content': a['title']}}]}}, 'children': bl[:100]}, hd)
    if not r.get('id'):
        raise SystemExit(f'notion: no page in the reply: {str(r)[:300]}')
    for i in range(100, len(bl), 100):
        _http('PATCH', f"{api}blocks/{r['id']}/children", {'children': bl[i:i + 100]}, hd)
    return r.get('url') or 'https://www.notion.so/' + r['id'].replace('-', '')


R['notion'] = {'publish': _notion}


# adapter:report/command: reports.command with {title} {path} {parent}; last output word = the URL
def _command(a):
    c = RCFG.get('command') or sys.exit('reports.type command needs reports.command')
    for k, v in (('title', a['title']), ('path', a['path']), ('parent', a['parent'] or a['keep'] or '')):
        c = c.replace('{' + k + '}', _q(v))
    r = subprocess.run(c, shell=True, capture_output=True, text=True, errors='replace', timeout=300)
    u = (r.stdout.split() or [''])[-1]
    return u if u and not r.returncode else sys.exit(f'reports.command failed (exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}')


R['command'] = {'publish': _command}
# adapter-end:report


def _report_selftest(expect):
    """Each report backend on recorded replies (Drive via gws, Confluence / Notion via _http); no network."""
    g, calls, env0, tmp = globals(), [], dict(os.environ), tempfile.mkdtemp()
    saved, md, png = {k: g[k] for k in ('gws', '_http', '_browser', 'REPORT_TYPE', 'GWS', 'kit_path', 'RCFG')}, os.path.join(tmp, 'r.md'), os.path.join(tmp, 's.png')
    PAGE = {'object': 'page', 'id': '59833787-2cf9-4fdf-8782-e53db20768a5', 'url': 'https://www.notion.so/T-598337872cf94fdf8782e53db20768a5'}
    with open(md, 'w', encoding='utf-8') as fh:
        fh.write('# T\n\n---\n' + ''.join(f'- b{i}\n' for i in range(151)) + '```\nx\n```\n')
    open(png, 'wb').close()
    FILE = {'kind': 'drive#file', 'id': '1AbC', 'webViewLink': 'https://docs.google.com/document/d/1AbC/edit?usp=drivesdk'}
    def use(t, rcfg, reply=lambda a: {'kind': 'drive#permission', 'id': 'anyoneWithLink'} if 'permissions' in a else FILE):
        calls.clear(); g.update(REPORT_TYPE=t, RCFG=rcfg)
        g['_http'] = g['gws'] = lambda *a, **k: calls.append((a, k)) or reply(a)
        return lambda: [k['body'] for a, k in calls if 'permissions' in a]
    try:
        g['GWS'], g['kit_path'] = 'gws', lambda n, create=False: tmp
        perms = use('gdocs', {}); u = make_doc('T', md); anyone = perms()
        perms = use('gdocs', {'share': 'domain:ex.com'}); make_doc('T', md); dom = perms()
        perms = use('gdocs', {'share': 'none'}); make_doc('T', md)
        expect('gdocs: Markdown as HTML; share anyone (default) / domain:<d> / none', u == 'https://docs.google.com/document/d/1AbC/edit'
           and calls[0][1]['upload'].endswith('r.doc.html') and anyone == [{'type': 'anyone', 'role': 'reader'}] and dom[0]['domain'] == 'ex.com' and not perms())
        use('gdocs', {}, lambda a: FILE if 'files' in a else {'error': 'insufficient permissions'})
        try:
            make_doc('t', md); expect('gdocs: an unshared doc is refused', False)
        except SystemExit as e:
            expect('gdocs: an unshared doc is refused', 'not shared' in str(e))
        use('gdocs', {}); ev = make_evidence('ev', [png])
        expect('gdocs evidence: a Drive folder, an image src per file', calls[0][1]['body']['mimeType'].endswith('folder') and ev['files']['s.png']['src'].endswith('id=1AbC'))
        use('markdown', {})
        expect('markdown: kept in place, else in docs; no evidence host', make_doc('T', md, tmp) == md and make_doc('My T', md) == os.path.join(tmp, 'My-T.md') and not make_evidence('e', [png]))
        use('html', {})
        expect('html: Markdown -> HTML, kept', '<h1>T</h1>' in open(make_doc('T', md, tmp), encoding='utf-8').read())
        os.environ.update(CONFLUENCE_URL='https://ex.atlassian.net/wiki/', CONFLUENCE_TOKEN='tk', NOTION_TOKEN='secret_x')
        use('confluence', {'space': 'QA', 'parent': '42'}, lambda a: {'id': '65601', 'type': 'page', '_links': {'webui': '/spaces/QA/pages/65601/T', 'base': 'https://ex.atlassian.net/wiki'}})
        u = make_doc('T', md); _, url, b, hd = calls[0][0]
        expect('confluence: a storage page under reports.parent, bearer auth', u == 'https://ex.atlassian.net/wiki/spaces/QA/pages/65601/T' and url.endswith('/wiki/rest/api/content')
           and b['ancestors'] == [{'id': '42'}] and '<hr/>' in b['body']['storage']['value'] and hd['Authorization'] == 'Bearer tk')
        use('notion', {'parent': 'p1'}, lambda a: PAGE if a[0] == 'POST' else {'object': 'list', 'results': []})
        u = make_doc('T', md); c1, c2 = (c[0][2]['children'] for c in calls)
        expect('notion: blocks 100 per call', u == PAGE['url'] and (len(c1), len(c2), c1[0]['type'], c2[-1]['type']) == (100, 53, 'heading_1', 'code'))
        with open(os.path.join(tmp, 'b.py'), 'w') as fh:   # the fake browser writes --print-to-pdf=<out>
            fh.write("import sys\nopen([x[15:] for x in sys.argv if x[:15] == '--print-to-pdf='][0], 'wb').write(b'%PDF')")
        g['_browser'] = lambda: [sys.executable, os.path.join(tmp, 'b.py')]; use('pdf', {}); p = make_doc('T', md, tmp)
        expect('pdf: the headless browser prints the HTML, kept', p == os.path.join(tmp, 'r.pdf') and open(p, 'rb').read() == b'%PDF')
        use('command', {'command': _q(sys.executable) + ' -c "import sys; print(\'https://w.ex/\' + sys.argv[1])" {title}'})
        expect('command: {title} filled, the last output = the URL', make_doc('T1', md) == 'https://w.ex/T1')
    finally:
        g.update(saved); os.environ.clear(); os.environ.update(env0); shutil.rmtree(tmp, ignore_errors=True)


# --- keepboth (rebase), lbcheck, self-test
def keepboth(paths):
    """Resolve conflict blocks as OURS then THEIRS; append-only files only (changelog includes, route/nav lists, i18n keys,
    DI registrations, barrel exports, requirements.txt), never real code."""
    left = 0

    pat = re.compile(r'<<<<<<< [^\r\n]*\r?\n(.*?)(?:\|\|\|\|\|\|\| [^\r\n]*\r?\n.*?)?=======\r?\n(.*?)>>>>>>> [^\r\n]*(?:\r?\n|\Z)', re.S)   # last block may end the file
    for path in paths:
        text = open(path, encoding='utf-8', newline='').read()
        n = len(pat.findall(text))
        text = pat.sub(lambda m: m.group(1) + m.group(2), text)
        open(path, 'w', encoding='utf-8', newline='').write(text)
        print(path, 'resolved', n, 'block(s)')
        if re.search(r'^(<<<<<<<|>>>>>>>) ', text, re.M):   # a block the pattern missed
            print(path, 'STILL HAS CONFLICT MARKERS: resolve by hand', file=sys.stderr)
            left += 1
    return 1 if left else 0


def lbcheck(argv):
    """Liquibase sanity check (dev.ps1 check): replays master.xml's includes; flags create / add of an existing table / column
without <preConditions>, schema changeSets without <rollback> (beyond auto-rollback types), not-reversible ones with an empty one.
Reports files named >= since (yyyyMMddHHmmss) or listed in env LBCHECK_CHANGED ('|'); prints issues + 'ISSUES <n>', exit 1 if n."""
    sys.stdout.reconfigure(encoding='utf-8')
    master, since = os.path.abspath(argv[0]), argv[1] if len(argv) > 1 else '0'
    m = re.search(r'^(.*?)[\\/]config[\\/]liquibase[\\/]', master) or re.search(r'^(.*[\\/]resources)[\\/]', master)
    roots = [m.group(1) if m else os.path.dirname(master), os.path.dirname(master)]
    changed = {f for f in os.environ.get('LBCHECK_CHANGED', '').split('|') if f}
    schema = {'createTable', 'addColumn', 'dropColumn', 'dropTable', 'renameColumn', 'modifyDataType', 'addForeignKeyConstraint', 'createIndex',
         'addUniqueConstraint', 'sql', 'update', 'insert', 'delete'}
    auto = {'createTable', 'addColumn', 'renameColumn', 'createIndex', 'addForeignKeyConstraint', 'addUniqueConstraint'}
    cols, issues = {}, []   # table -> its columns, replayed

    def resolve(f, base):
        ps = [os.path.join(base, f)] + [os.path.join(r, f.lstrip('/')) for r in roots]
        return next((p for p in ps if os.path.exists(p)), ps[1])

    def walk(path, fname):
        try:
            raw = open(path, encoding='utf-8', errors='replace').read()
            root = ET.fromstring(raw.lstrip('\ufeff').encode('utf-8'))
        except Exception as e: return issues.append(f'PARSE ERROR {fname}: {e}')
        ts = re.match(r'(\d{14})', os.path.basename(fname))
        report = (bool(ts) and ts.group(1) >= since) or os.path.basename(fname) in changed or (not ts and since == '0')   # a changed old one counts
        for mm in re.finditer(r'<changeSet\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</changeSet>', raw, re.S) if report else ():   # ET drops comments
            rb = re.search(r'<rollback\s*/>|<rollback\b[^>]*>(.*?)</rollback>', mm.group(2), re.S)
            if re.search(r'not\s+reversible|irreversible|non-reversible|cannot\s+be\s+(rolled|reverted)|no\s+rollback', mm.group(2), re.I) and not (rb and (rb.group(1) or '').strip()):
                issues.append(f'{fname} {mm.group(1)}: marked not reversible but its <rollback> is missing or empty (a revert would fail): write a real reverse statement')
        for node in root:
            t = local(node.tag)
            if t == 'changeSet':
                kids = [k for k in node if local(k.tag) not in NON_CHANGE]
                guarded, cid = any(local(k.tag) == 'preConditions' for k in node), node.get('id')
                for ch in map(xml_change, kids):
                    tb, have = ch['table'], cols.setdefault(ch['table'], set()) if ch['type'] in ('createTable', 'addColumn') else cols.get(ch['table'], set())
                    hit = ([tb] if tb in cols and ch['type'] == 'createTable' and have else []) + ([f'{tb}.{c}' for c in ch['columns'] if c in have] if ch['type'] == 'addColumn' else [])
                    if hit and report and not guarded: issues.append(f'{fname} {cid}: {ch["type"]} {", ".join(hit)} already exists')
                    if ch['type'] == 'dropTable': cols.pop(tb, None)
                    elif ch['type'] == 'renameColumn' and ch['attrs'].get('oldColumnName', '').lower() in have:
                        have.discard(ch['attrs']['oldColumnName'].lower()); have.add(ch['attrs'].get('newColumnName', '').lower())
                    else:
                        (have.difference_update if ch['type'] == 'dropColumn' else have.update if ch['type'] in ('createTable', 'addColumn') else len)(ch['columns'])
                kinds = {local(k.tag) for k in kids} & schema
                if report and kinds and not any(local(k.tag) == 'rollback' for k in node) and not kinds <= auto:
                    issues.append(f'{fname} {cid}: {", ".join(sorted(kinds))} without a <rollback>')
            elif t == 'include' and (node.get('file') or '').lower().endswith('.xml'):   # .sql / .yaml includes are valid Liquibase
                walk(resolve(node.get('file'), os.path.dirname(path)), node.get('file'))
            elif t == 'includeAll':
                d = resolve(node.get('path') or '', os.path.dirname(path))
                for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
                    if f.endswith('.xml'): walk(os.path.join(d, f), f)

    walk(master, 'master.xml')
    print('\n'.join(issues + [f'ISSUES {len(issues)}']))
    return 1 if issues else 0

def selftest():
    """Offline checks (missing body file refused; mergeAfter finds producers, warns on an unmatched repo name; merge_word).
    Exit 0 = all pass."""
    import contextlib as _c, io
    fails = 0

    def expect(what, cond):
        nonlocal fails
        print(('PASS ' if cond else 'FAIL ') + what)
        fails += 0 if cond else 1

    def refused(what, fn, text):
        try:
            fn(); expect(what, False)
        except SystemExit as e:
            expect(what, text in str(e))
    refused('a missing body file is refused', lambda: _body('no-such-body.md'), 'file not found')
    expect('multi-line body text passes', _body('a\nb') == 'a\nb')

    fd, path = tempfile.mkstemp(suffix='.json')
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump({'tasks': {'T1': {'mergeAfter': ['web!5>api!3', 'other!5>api!4']}}}, f)
    err = io.StringIO()
    with _c.redirect_stderr(err):
        out = unmerged_producers('group/web', '5', lambda r, i: 'opened', tracking=path)
    os.remove(path)
    expect('the open producer is found', out == [('api!3', 'opened', 'T1')])
    expect('a pair naming another repo is reported', 'names repo other' in err.getvalue())
    expect('merge_word reads the last line', merge_word('x\nWAIT') == 'WAIT' and merge_word('x') == 'NOT_MERGED')
    # merge gate over the adapter verbs (_host faked)
    g = globals()
    saved = {k: g[k] for k in ('_host', 'remote', 'unmerged_producers', '_progress', 'kit_path')}
    old = '2020-01-01T00:00:00Z'
    calls = []

    def fake(runs=(), cfg=True, hp=None, put=None):
        st = {'merged': False}

        def h(verb, **a):
            calls.append((verb, a))
            if verb == 'mr.merge':
                st['merged'] = put is None and not a.get('auto')
                return put or {}
            if verb == 'mr.get':
                return {'state': 'merged'} if st['merged'] else {'state': 'opened', 'sha': 'abc', 'source_branch': 'f/x', 'target_branch': 'main', 'updated_at': old, 'head_pipeline': hp}
            return {'ci.runs': list(runs) if isinstance(runs, tuple) else runs, 'ci.config': cfg}.get(verb, {})
        return h
    merged = lambda: [a for v, a in calls if v == 'mr.merge']
    try:
        g['remote'] = lambda wt: ('gitlab', 'g/r'); g['unmerged_producers'] = lambda *a, **k: []; g['_progress'] = lambda m: None
        g['kit_path'] = lambda n, **k: os.path.join(tempfile.mkdtemp(), 'tracking.json')
        g['_host'] = fake()
        expect('CI, no head pipeline after 5 min: NOT_MERGED, no merge', merge_word(auto_merge('.', '7', max_wait=0)) == 'NOT_MERGED' and not merged())
        calls.clear(); g['_host'] = fake(runs={'raw': 'error: 500'})
        expect('a failed pipeline query is WAIT, no merge call', merge_word(auto_merge('.', '7', max_wait=0)) == 'WAIT' and not merged())
        calls.clear(); g['_host'] = fake(cfg=False)
        expect('no CI config: merged at once, not merge-when-green', merge_word(auto_merge('.', '7')) == 'MERGED' and merged() and not merged()[0]['auto'])
        calls.clear(); g['_host'] = fake(hp={'status': 'running'}, put={'state': 'opened'})
        expect('running checks, nothing scheduled: WAIT', merge_word(auto_merge('.', '7')) == 'WAIT' and merged()[0]['auto'])
        calls.clear(); g['_host'] = fake(hp={'status': 'running'}, put={'auto_merge': 'kit'})
        expect('kit-emulated merge-when-green: SCHEDULED', merge_word(auto_merge('.', '7')) == 'SCHEDULED')
    finally:
        g.update(saved)
    expect('lbcheck has its XML parser (ET imported)', 'ET' in g)
    # holdMerge, unreadable tracking, lost intent
    saved = {k: g[k] for k in ('_run', 'remote', 'unmerged_producers', 'kit_path')}
    cfg0, puts = dict(CFG), []
    try:
        g['remote'] = lambda wt: ('gitlab', 'g/web'); g['_run'] = lambda *a, **k: puts.append('called') or '{}'
        CFG['holdMerge'] = ['web']; puts.clear()
        expect('holdMerge: a held repo is NOT_MERGED, no host call', merge_word(auto_merge('.', '7')) == 'NOT_MERGED' and not puts)
        CFG.pop('holdMerge', None)
        fd, bad = tempfile.mkstemp(suffix='.json'); os.write(fd, b'{broken'); os.close(fd)
        w = saved['unmerged_producers']('g/web', '7', lambda r, i: 'merged', tracking=bad); os.remove(bad)
        expect('an unreadable tracking file is a wait', len(w) == 1 and 'unreadable' in w[0][0])
        g['unmerged_producers'] = lambda *a, **k: []
        g['kit_path'] = lambda n: os.path.join(tempfile.gettempdir(), 'no-such-dir-kit', 'x', 'tracking.json')
        err = io.StringIO()
        with _c.redirect_stderr(err):
            _remember_automerge('web!7')
        expect('a lost merge-when-green intent is reported', 'could not record' in err.getvalue())
    finally:
        g.update(saved); CFG.clear(); CFG.update(cfg0)
    fd, cp = tempfile.mkstemp(suffix='.json'); os.write(fd, b'{"dialect": "PostgreSQL"}'); os.close(fd)
    expect('dialect alias', load_cfg(cp)['dialect'] == 'postgres'); os.remove(cp)
    cfg0 = dict(CFG); CFG.clear(); CFG['gitHostType'] = 'github'
    expect('gitHostType, no gitHost: any origin', host_kind('git.corp.example') == 'github'); CFG.update(cfg0)
    _report_selftest(expect)
    print(f'{fails} failure(s)')
    return 1 if fails else 0



# ===== migrations: local env migration audit (run by localenv.ps1). LIGHT changeSets revert when their layer leaves; HEAVY need a snapshot.
#   python devtools.py migrations classify --repo <checkout> --base <ref> --head <sha> [--config <json>] [--under a,b] [--save <dir>]
#   | plan --leaving <manifest,..> [--staying <manifest,..>] [--repo <worktree>] [--out <dir>] | rules|detect [--repo <dir>] | selftest
# Exit: 0 ok · 1 error · 2 usage. classify -> { class: light|heavy|none, changesets [ file, path, id, author, hash, status, class, rule,
#   why, guarded, creates, refs, x (tool vars) ], reasons, tools }. plan -> { revert (newest first), kept, blocked, commands, hook (count
#   left to db.rollback) }; --out: revert.json, files/, localenv-revert.xml. Rules: DEFAULT_RULES ("rules" replaces, "extraRules" first;
#   first match decides); SQL lists per "dialect". Parsers: Liquibase, MIG_TOOLS, config "parsers" [ { match, parser | cmd } ].
KNOWN = {'createTable', 'dropTable', 'addColumn', 'dropColumn', 'renameColumn', 'renameTable', 'modifyDataType', 'createIndex',
  'dropIndex', 'addForeignKeyConstraint', 'dropForeignKeyConstraint', 'addUniqueConstraint', 'dropUniqueConstraint',
  'addPrimaryKey', 'dropPrimaryKey', 'addNotNullConstraint', 'dropNotNullConstraint', 'addDefaultValue', 'dropDefaultValue',
  'createView', 'dropView', 'renameView', 'createSequence', 'dropSequence', 'alterSequence', 'renameSequence',
  'addAutoIncrement', 'setTableRemarks', 'setColumnRemarks', 'insert', 'update', 'delete', 'loadData', 'loadUpdateData',
  'sql', 'sqlFile', 'tagDatabase', 'customChange', 'executeCommand', 'createProcedure', 'dropProcedure', 'output', 'stop',
  'mergeColumns', 'addLookupTable', 'dropAllForeignKeyConstraints', 'empty'}
# change types Liquibase auto-reverses (no <rollback> needed)
AUTO = {'createTable', 'addColumn', 'renameColumn', 'renameTable', 'renameView', 'createIndex', 'addForeignKeyConstraint',
  'addUniqueConstraint', 'addPrimaryKey', 'addNotNullConstraint', 'dropNotNullConstraint', 'addDefaultValue', 'createView',
  'createSequence', 'tagDatabase', 'empty', 'setTableRemarks', 'setColumnRemarks'}
NON_CHANGE = {'preConditions', 'rollback', 'comment', 'validCheckSum', 'property'}

DEFAULTS = {
 'pattern': r'(?i)(^|/)(db/)?(changelog|migrations?|migrate|liquibase|flyway|alembic)(/|\.)(?!(?:.*\.)?(?:md|txt|rst)$)',   # not docs
 'logicalRoot': r'^(?:.*/)?src/main/resources/',   # classpath path (DATABASECHANGELOG.FILENAME)
 'smallDataRows': 20,
 'referenceTables': r'(?i)(^|_)(ref|lookup|types?|status(es)?|configs?|settings?|authorit(y|ies)|permissions?|roles?|menus?|features?|translations?)$',
 'dialect': '',   # a DIALECTS key (localenv: db.engine); '' = every set (strictest)
 'heavySql': [r'\bDROP\s+(TABLE|COLUMN|DATABASE|SCHEMA)\b', r'\bTRUNCATE\b', r'\bCREATE\s+(OR\s+REPLACE\s+)?(PROCEDURE|FUNCTION|TRIGGER)\b',
    r'\bRENAME\s+TABLE\b', r'\bALTER\s+TABLE\b.*\bDROP\s+(?!(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK|PRIMARY\s+KEY|DEFAULT)\b)[`"]?\w',
    r'\bWHERE\s+(1\s*=\s*1|TRUE|1)\s*$'],
 'lightSql': [r'^SET\s', r'^ALTER\s+TABLE\s+\S+\s+(ADD|RENAME|DROP\s+(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK))\b',
    r'^CREATE\s+(UNIQUE\s+)?INDEX\b', r'^CREATE\s+TABLE\b', r'^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b', r'^(BEGIN|COMMIT|END|START\s+TRANSACTION)$',
    r'^DROP\s+(INDEX|VIEW)\b', r'^INSERT\s+INTO\b', r'^UPDATE\b.+\bWHERE\b', r'^DELETE\s+FROM\b.+\bWHERE\b'],
}
# dialect: (heavySql, lightSql) added to the common lists
DIALECTS = {
 'mysql': ([r'\bMODIFY\b', r'\bCHANGE\s+(COLUMN\s+)?\w', r'\bDELIMITER\b', r'\bCREATE\s+(DEFINER|EVENT)\b', r'\bON\s+DUPLICATE\s+KEY\s+UPDATE\b',
      r'\bREPLACE\s+INTO\b'], [r'^INSERT\s+IGNORE\s+INTO\b', r'^CREATE\s+FULLTEXT\s+INDEX\b']),
 'postgres': ([r'\bALTER\s+COLUMN\s+\S+\s+(SET\s+DATA\s+)?TYPE\b', r'\bON\s+CONFLICT\b.*\bDO\s+UPDATE\b', r'\bDO\s+\$', r'\bCREATE\s+(OR\s+REPLACE\s+)?RULE\b'],
       [r'^CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY\b', r'^CREATE\s+(TYPE|SEQUENCE|EXTENSION\s+IF\s+NOT\s+EXISTS)\b', r'^COMMENT\s+ON\b']),
 'sqlserver': ([r'\bsp_rename\b', r'\bALTER\s+COLUMN\b', r'^MERGE\b', r'^EXEC(UTE)?\b'], [r'^CREATE\s+(UNIQUE\s+)?(NON)?CLUSTERED\s+INDEX\b']),
 'sqlite': ([r'^PRAGMA\b', r'\bINSERT\s+INTO\s+\S+\s+SELECT\b'], []),
 'oracle': ([r'\bMODIFY\b', r'^MERGE\s+INTO\b', r'^(BEGIN|DECLARE)\s+\S', r'\bEXECUTE\s+IMMEDIATE\b'], [r'^CREATE\s+SEQUENCE\b', r'^COMMENT\s+ON\b']),
}
DIALECTS['mariadb'] = DIALECTS['mysql']
DIALECT_ALIAS = {'postgresql': 'postgres', 'pg': 'postgres', 'mssql': 'sqlserver', 'mongo': 'mongodb'}
# first match decides each item (changeSet, then each change); a HEAVY item makes the changeSet HEAVY
DEFAULT_RULES = [
 {'id': 'runs-always', 'scope': 'changeset', 'attr': {'runAlways': '(?i)^true$'}, 'class': 'heavy', 'why': 'runAlways: runs on every start, no exact rollback'},
 {'id': 'runs-on-change', 'scope': 'changeset', 'attr': {'runOnChange': '(?i)^true$'}, 'class': 'heavy', 'why': 'runOnChange: re-runs when edited, no exact rollback'},
 {'id': 'edits-applied', 'scope': 'changeset', 'status': '^modified$', 'class': 'heavy', 'why': 'edits a changeSet the target already has (checksum change)'},
 {'id': 'removes-applied', 'scope': 'changeset', 'status': '^removed$', 'class': 'heavy', 'why': 'removes a changeSet the target already has'},
 {'id': 'moved-file', 'scope': 'changeset', 'status': '^renamed$', 'class': 'heavy', 'why': 'moved changelog file: its changeSets get a new identity and run again'},
 {'id': 'empty-rollback', 'scope': 'changeset', 'rollback': 'empty', 'onlyTag': False, 'class': 'heavy', 'why': 'empty <rollback>: a revert would undo nothing'},
 {'id': 'no-rollback', 'scope': 'changeset', 'rollback': 'missing', 'autoRollback': False, 'class': 'heavy', 'why': 'no <rollback>, and {types} has no automatic rollback'},
 {'id': 'tag', 'change': '^tagDatabase$', 'class': 'light'},
 {'id': 'drop-own', 'change': '^(dropTable|dropColumn)$', 'createdHere': True, 'class': 'light'},
 {'id': 'drop-data', 'change': '^(dropTable|dropColumn)$', 'class': 'heavy', 'why': 'drops {target}, which may hold data'},
 {'id': 'retype', 'change': '^modifyDataType$', 'createdHere': False, 'class': 'heavy', 'why': 'changes the type of existing column {target} (may truncate data)'},
 {'id': 'unbounded', 'change': '^(update|delete)$', 'where': False, 'class': 'heavy', 'why': 'unbounded {type} on {table} (no WHERE)'},
 {'id': 'delete-reference', 'change': '^delete$', 'table': '@referenceTables', 'class': 'light'},
 {'id': 'delete-rows', 'change': '^delete$', 'class': 'heavy', 'why': 'deletes rows of {table}: a rollback cannot restore them exactly'},
 {'id': 'bulk-file', 'change': '^(loadData|loadUpdateData|sqlFile)$', 'class': 'heavy', 'why': '{type} reads an external file that is not audited'},
 {'id': 'big-insert', 'change': '^insert$', 'rowsOver': '@smallDataRows', 'class': 'heavy', 'why': '{rows} rows into {table} (over smallDataRows)'},
 {'id': 'raw-sql', 'change': '^sql$', 'sqlUnsafe': True, 'class': 'heavy', 'why': 'raw SQL outside the light list: {stmt}'},
 {'id': 'custom', 'change': '^(customChange|executeCommand|createProcedure|dropProcedure|output|stop|mergeColumns|addLookupTable|dropAllForeignKeyConstraints)$', 'class': 'heavy', 'why': '{type}: custom or procedural change'},
 {'id': 'unknown', 'known': False, 'class': 'heavy', 'why': 'unknown change type {type}'},
]
FILE_RULES = {'unparsed': 'cannot be audited: {why}', 'raw-sql-file': 'raw SQL file outside a formatted changelog: no changeSet ids or rollback'}


def load_cfg(path):
    cfg = dict(DEFAULTS)
    if path:
        with open(path, encoding='utf-8-sig') as f: user = json.load(f) or {}
        cfg.update({k: v for k, v in user.items() if v is not None})
    rules = cfg.get('rules') or DEFAULT_RULES
    cfg['rules'] = list(cfg.get('extraRules') or []) + list(rules)
    dia = (cfg.get('dialect') or '').lower()
    cfg['dialect'] = DIALECT_ALIAS.get(dia, dia)   # db.engine spellings
    for d, (hv, lt) in DIALECTS.items():
        if (cfg['dialect'] or d) == d:
            cfg['heavySql'], cfg['lightSql'] = list(cfg['heavySql']) + hv, list(cfg['lightSql']) + lt
    return cfg


def git(repo, *a, ok=False):
    p = subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, encoding='utf-8', errors='replace')
    if p.returncode and not ok: raise SystemExit(f'git {" ".join(a)}: {p.stderr.strip()}')
    return p.stdout if p.returncode == 0 else None


def norm(s):
    return re.sub(r'\s+', ' ', s or '').strip()


def h(s):
    return hashlib.sha1(norm(s).encode('utf-8')).hexdigest()[:16]


def local(tag):
    return tag.split('}', 1)[-1]


def split_names(v):
    return [x.strip().strip('`"').lower() for x in (v or '').split(',') if x.strip()]


# --- normalized changes
def change_from(t, attrs, cols, where, text):
    """t: change type; attrs: dict; cols: column names; where: WHERE text or None; text: SQL body."""
    tbl = (attrs.get('tableName') or attrs.get('baseTableName') or attrs.get('viewName') or '').strip('`"').lower()
    c = {'type': t, 'table': tbl, 'columns': cols, 'where': bool(norm(where)) and not re.fullmatch(r'(?i)\(?\s*(1\s*=\s*1|true|1)\s*\)?', norm(where)), 'rows': 1 if t == 'insert' else 0, 'sql': text or '',
     'creates': [], 'refs': [], 'attrs': {k: v for k, v in attrs.items() if isinstance(v, str)}}
    if t == 'createTable': c['creates'] = [tbl] + [f'{tbl}.{x}' for x in cols]
    elif t == 'addColumn': c['creates'] = [f'{tbl}.{x}' for x in cols]; c['refs'] = [tbl]
    elif t == 'createView': c['creates'] = [tbl]
    elif t == 'renameColumn':
        c['creates'] = [f'{tbl}.{attrs.get("newColumnName", "").lower()}']; c['refs'] = [tbl, f'{tbl}.{attrs.get("oldColumnName", "").lower()}']
    elif t == 'renameTable': c['creates'] = [attrs.get('newTableName', '').lower()]; c['refs'] = [attrs.get('oldTableName', '').lower()]
    elif t == 'addForeignKeyConstraint':
        rt = attrs.get('referencedTableName', '').lower()
        c['refs'] = [tbl, rt] + [f'{tbl}.{x}' for x in split_names(attrs.get('baseColumnNames'))] + [f'{rt}.{x}' for x in split_names(attrs.get('referencedColumnNames'))]
    elif t == 'sql':
        body = text or ''
        for m in re.finditer(r'(?is)\bCREATE\s+TABLE\s+(?!IF\s+NOT\s+EXISTS\b)[`"]?(\w+)', body):
            c['creates'].append(m.group(1).lower())
        for m in re.finditer(r'(?is)\bALTER\s+TABLE\s+[`"]?(\w+)[`"]?\s+ADD\s+(?:COLUMN\s+)?[`"]?(\w+)', body):
            if m.group(2).upper() not in ('INDEX', 'KEY', 'CONSTRAINT', 'UNIQUE', 'FOREIGN', 'PRIMARY', 'FULLTEXT', 'CHECK'):
                c['creates'].append(f'{m.group(1).lower()}.{m.group(2).lower()}')
        c['refs'] = sorted({m.group(1).lower() for m in re.finditer(r'(?i)\b(?:TABLE|INTO|UPDATE|FROM|JOIN|REFERENCES|ON)\s+[`"]?(\w+)', body)})
    else:
        c['refs'] = [x for x in [tbl] + [f'{tbl}.{x}' for x in cols] if x]
    return c


def xml_change(el):
    t = local(el.tag)
    a = dict(el.attrib)
    cols = [c.get('name', '').lower() for c in el.iter() if local(c.tag) == 'column' and c.get('name')]
    cols += [x for k in ('columnName', 'columnNames') for x in split_names(a.get(k))]
    where = ''.join(w.text or '' for w in el if local(w.tag) == 'where')
    text = (el.text or '') if t in ('sql', 'createProcedure') else ''
    return change_from(t, a, cols, where, text)


def yaml_change(d):
    (t, body), = d.items() if isinstance(d, dict) and len(d) == 1 else (('?', {}),)
    body = body if isinstance(body, dict) else {}
    cols = []
    for c in body.get('columns') or []:
        col = c.get('column') if isinstance(c, dict) else None
        if isinstance(col, dict) and col.get('name'): cols.append(str(col['name']).lower())
    cols += [x for k in ('columnName', 'columnNames') for x in split_names(str(body.get(k) or ''))]
    return change_from(t, {k: str(v) for k, v in body.items() if not isinstance(v, (list, dict))}, cols, str(body.get('where') or ''), str(body.get('sql') or ''))


# --- parsers: text -> [ changeset ]
def cs_record(id_, author, attrs, changes, rb_state, rb_changes, on_fail, raw):
    return {'id': str(id_), 'author': str(author), 'attrs': {k: str(v) for k, v in attrs.items()}, 'changes': changes,
      'rollback': rb_state, 'rollbackChanges': rb_changes, 'onFail': on_fail or '', 'hash': h(raw)}


def parse_xml(text):
    root = ET.fromstring(text.lstrip('﻿').encode('utf-8'))
    if local(root.tag) != 'databaseChangeLog': raise ValueError('not a Liquibase XML changelog')
    out = []
    raws = re.findall(r'<changeSet\b.*?</changeSet>', re.sub(r'<!--.*?-->', '', text, flags=re.S), re.S)
    for i, cs in enumerate(el for el in root if local(el.tag) == 'changeSet'):
        changes, rb, rbc, on_fail = [], 'missing', [], ''
        for ch in cs:
            t = local(ch.tag)
            if t == 'rollback':
                kids = list(ch)
                rb = 'present' if kids or norm(ch.text) else 'empty'
                rbc = [local(k.tag) for k in kids]
            elif t == 'preConditions': on_fail = ch.get('onFail', 'HALT')
            elif t not in NON_CHANGE: changes.append(xml_change(ch))
        out.append(cs_record(cs.get('id'), cs.get('author'), cs.attrib, changes, rb, rbc, on_fail, raws[i] if i < len(raws) else ET.tostring(cs, encoding='unicode')))
    return out


def parse_struct(doc):
    out = []
    for item in (doc or {}).get('databaseChangeLog') or []:
        cs = item.get('changeSet') if isinstance(item, dict) else None
        if not isinstance(cs, dict): continue
        changes = [yaml_change(c) for c in cs.get('changes') or []]
        rbv = cs.get('rollback', None)
        rb = 'missing' if 'rollback' not in cs else ('present' if rbv not in (None, '', [], {}) else 'empty')
        pre = cs.get('preConditions') or []
        on_fail = next((str(p.get('onFail')) for p in pre if isinstance(p, dict) and p.get('onFail')), '') if isinstance(pre, list) else ''
        attrs = {k: v for k, v in cs.items() if not isinstance(v, (list, dict)) and k not in ('id', 'author')}
        out.append(cs_record(cs.get('id'), cs.get('author'), attrs, changes, rb, [], on_fail, json.dumps(cs, sort_keys=True, default=str)))
    return out


def parse_yaml(text):
    import yaml   # PyYAML; absent -> YAML is HEAVY
    return parse_struct(yaml.safe_load(text))


def parse_formatted_sql(text):
    out = []
    blocks = re.split(r'(?m)^--\s*changeset\s+', text)
    for b in blocks[1:]:
        head, _, body = b.partition('\n')
        m = re.match(r'(?:"([^"]+)"|([^:\s]+)):(\S+)(.*)', head.strip())
        if not m: continue
        author, id_, rest = m.group(1) or m.group(2), m.group(3), m.group(4)
        attrs = dict(re.findall(r'(\w+):(\S+)', rest))
        rb_lines = [l.split('rollback', 1)[1].strip() for l in body.splitlines() if re.match(r'\s*--\s*rollback\b', l)]
        rb = 'missing' if not rb_lines else ('empty' if all(not x or re.match(r'(?i)not\s+required|empty', x) for x in rb_lines) else 'present')
        on_fail = (re.search(r'(?im)^--\s*preconditions\s+.*onFail:(\w+)', body) or [None, ''])[1]
        sql = '\n'.join(l for l in body.splitlines() if not re.match(r'\s*--', l))
        out.append(cs_record(id_, author, attrs, [change_from('sql', {}, [], '', sql)], rb, ['sql'] if rb == 'present' else [], on_fail, b))
    return out


# --- other tools: one file (prisma: folder) = one changeSet, id = its version, rollback = its down part (a down file: regex
# + replacement on the path, or the in-file split). Commands run in the folder of the nearest marker: {id} {v} {prev} {app}
# {file} {down} {dir}; ordered: a revert also undoes every newer migration of its folder (2: any other, a revision chain).
SQLF = r'[^/]*\.sql$'
MIG_TOOLS = {
 'flyway': {'file': r'(^|/)(?:(?P<r>R)|V(?P<v>\d[\w.]*?))__(?P<n>[^/]*)\.sql$', 'down': (r'(^|/)V([^/]*)$', r'\1U\2'), 'marker': ('flyway.conf', 'flyway.toml'),
      'apply': 'flyway migrate', 'revert': 'flyway undo', 'dry': 'flyway migrate -dryRunOutput=flyway-dry-run.sql', 'ordered': 1},
 'prisma': {'file': r'(^|/)migrations/(?P<v>\d+_[^/]+)/migration\.sql$', 'down': (r'migration\.sql$', 'down.sql'), 'marker': ('package.json',),
      'apply': 'npx prisma migrate deploy', 'revert': 'npx prisma db execute --file "{down}" && npx prisma migrate resolve --rolled-back {id}', 'dry': 'npx prisma migrate status'},
 'sqitch': {'file': r'(^|/)deploy/(?P<v>[^/]+)\.sql$', 'down': (r'(^|/)deploy/', r'\1revert/'), 'marker': ('sqitch.plan',),
      'apply': 'sqitch deploy', 'revert': 'sqitch revert -y --to {id}^', 'dry': 'sqitch status', 'ordered': 1},
 'goose': {'file': r'(^|/)(?P<v>\d+)_' + SQLF, 'split': (r'(?im)^--\s*\+goose\s+up\b', r'(?im)^--\s*\+goose\s+down\b'),
      'apply': 'goose -dir "{dir}" up', 'revert': 'goose -dir "{dir}" down-to {prev}', 'dry': 'goose -dir "{dir}" status', 'first': '0', 'ordered': 1},
 'sql': {'file': r'(^|/)(?P<v>\d+)[_.-]' + SQLF, 'down': (r'\.up\.sql$', '.down.sql'), 'revert': '{exec}'},
 'alembic': {'file': r'(^|/)versions/(?P<v>\w+?)(_\w*)?\.py$', 'split': (r'(?m)^def\s+upgrade\b', r'(?m)^def\s+downgrade\b'), 'marker': ('alembic.ini',),
       'id': r'(?m)^revision\s*(?::[^=\n]*)?=\s*[\'"](\w+)', 'prev': r'(?m)^down_revision\s*(?::[^=\n]*)?=\s*[\'"](\w+)', 'first': 'base',
       'apply': 'alembic upgrade head', 'revert': 'alembic downgrade {prev}', 'dry': 'alembic upgrade head --sql', 'ordered': 2},
 'django': {'file': r'(^|/)(?P<app>\w+)/migrations/(?P<v>\d{4}_\w+)\.py$', 'auto': '', 'marker': ('manage.py',), 'first': 'zero',
      'apply': 'python manage.py migrate', 'revert': 'python manage.py migrate {app} {prev}', 'dry': 'python manage.py sqlmigrate {app} {id}', 'ordered': 1},
 'efcore': {'file': r'(^|/)(?P<v>\d{14}_\w+)\.cs$', 'split': (r'\bvoid\s+Up\s*\(', r'\bvoid\s+Down\s*\('), 'marker': ('.csproj',), 'first': '0',
      'apply': 'dotnet ef database update', 'revert': 'dotnet ef database update {prev}', 'dry': 'dotnet ef migrations script --idempotent', 'ordered': 1},
 'rails': {'file': r'(^|/)db/migrate/(?P<v>\d{14})_\w+\.rb$', 'split': (r'\bdef\s+(up|change)\b', r'\bdef\s+down\b'), 'auto': r'\bdef\s+change\b', 'marker': ('Gemfile',),
      'apply': 'bin/rails db:migrate', 'revert': 'bin/rails db:migrate:down VERSION={v}', 'dry': 'bin/rails db:migrate:status'},
 'knex': {'file': r'(^|/)migrations/(?P<v>\d{14})_[^/]+\.[cm]?[jt]s$', 'split': (r'\bup\b\s*[(=:]|function\s+up\b', r'\bdown\b\s*[(=:]|function\s+down\b'),
     'marker': ('knexfile.js', 'knexfile.ts', 'package.json'), 'apply': 'npx knex migrate:latest', 'revert': 'npx knex migrate:down {file}', 'dry': 'npx knex migrate:list'},
}
# down files (read with their up) and tool plumbing: never a changeSet of their own
NOT_MIG = re.compile(r'\.down\.sql$|(^|/)U\d[^/]*__[^/]*\.sql$|(^|/)revert/[^/]+\.sql$|/down\.sql$|(^|/)(__init__|env)\.py$|\.Designer\.cs$|ModelSnapshot\.cs$|'
                     r'migration_lock\.toml$|(^|/)sqitch\.(plan|conf)$|\.(md|txt|mako)$')
MIG_EXT = r'(?i)\.(sql|xml|ya?ml|json|py|rb|php|exs?|[cm]?[jt]s|go|cs|java|kt)$'
# code calls -> change types; '' = a table block (its column calls belong to it)
OPS = {'createtable': 'createTable', 'createmodel': 'createTable', 'addcolumn': 'addColumn', 'addfield': 'addColumn', 'addreference': 'addColumn',
 'dropcolumn': 'dropColumn', 'removecolumn': 'dropColumn', 'removefield': 'dropColumn', 'droptable': 'dropTable', 'deletemodel': 'dropTable',
 'droptableifexists': 'dropTable', 'altercolumn': 'modifyDataType', 'alterfield': 'modifyDataType', 'changecolumn': 'modifyDataType', 'alter': 'modifyDataType',
 'renamecolumn': 'renameColumn', 'renamefield': 'renameColumn', 'renametable': 'renameTable', 'renamemodel': 'renameTable', 'createindex': 'createIndex',
 'addindex': 'createIndex', 'index': 'createIndex', 'dropindex': 'dropIndex', 'removeindex': 'dropIndex', 'createforeignkey': 'addForeignKeyConstraint',
 'addforeignkey': 'addForeignKeyConstraint', 'dropforeignkey': 'dropForeignKeyConstraint', 'removeforeignkey': 'dropForeignKeyConstraint',
 'createuniqueconstraint': 'addUniqueConstraint', 'addconstraint': 'addUniqueConstraint', 'unique': 'addUniqueConstraint', 'dropconstraint': 'dropUniqueConstraint',
 'execute': 'sql', 'sql': 'sql', 'raw': 'sql', 'runsql': 'sql', 'bulkinsert': 'insert', 'insertdata': 'insert', 'insert': 'insert', 'updatedata': 'update',
 'update': 'update', 'deletedata': 'delete', 'del': 'delete', 'runpython': 'customChange', 'altertable': '', 'table': '', 'changetable': ''}
COL_TYPES = set('string text integer int bigint biginteger smallint float decimal double boolean bool date datetime timestamp timestamps time uuid json jsonb '
                'binary enu enum increments bigincrements references belongs_to'.split())
CALL = re.compile(r'(?:\b(\w+)\.)?\b([A-Za-z_]\w*)\s*(?:<[^<>()]*>)?(\(|[ \t]+:(?=\w))')


def mig_tool(path, text, cfg):
    """-> (name, preset, path match) of the tool owning path, else (None, None, None)"""
    for n, t in MIG_TOOLS.items():
        m = re.search(t['file'], path)
        if m and cfg.get('tool') in (None, '', 'auto', n) and not NOT_MIG.search(path) and (not t.get('split') or re.search(t['split'][0], text or '')):
            return n, t, m
    return None, None, None


def split_ud(text, t):
    sp = t.get('split')
    if not sp: return text, None
    d = re.search(sp[1], text)
    return (text[:d.start()], text[d.end():]) if d else (text, None)


def code_changes(up):
    out, cur = [], ''
    for m in CALL.finditer(up):
        pre, k = (m.group(1) or '').lower(), m.group(2).replace('_', '').lower()
        col = pre in ('t', 'table', 'tbl') and k in COL_TYPES
        if k not in OPS and not col: continue
        if m.group(3) == '(':
            d, j = 1, m.end()
            while j < len(up) and d: d += {'(': 1, ')': -1}.get(up[j], 0); j += 1
            a = up[m.end():j]
        else:
            a = up[m.end():].split('\n', 1)[0]
        kw = dict(re.findall(r'(\w+)\s*[=:]\s*[\'"`](\w+)', a))
        lits = [x or y for x, y in re.findall(r'[\'"`](\w+)[\'"`]|(?<![\w:]):(\w+)', a)]
        tbl = next((kw[x] for x in ('table', 'table_name', 'model_name', 'tableName') if x in kw), '')
        if col: out.append(change_from('addColumn', {'tableName': cur}, lits[:1], '', '')); continue
        typ = OPS[k]
        tbl = tbl or (lits[0] if lits else cur)
        if not typ: cur = tbl; continue
        if typ == 'createTable': cur = tbl
        cols = [kw['name'].lower()] if 'name' in kw and tbl != kw['name'] else [x.lower() for x in lits[1:2]]
        s = re.search(r'(?s)("""|\'\'\'|"|\'|`)(.*?)(?<!\\)\1', a) if typ == 'sql' else None
        h = re.match(r'(?s)\s*<<[~-]?([A-Z]+)\n(.*?)\n\s*\1', up[m.end():]) if typ == 'sql' else None
        out.append(change_from(typ, {'tableName': tbl} if typ != 'sql' else {}, cols, 'x' if re.search(r'(?i)\bwhere\b|keyColumn|filter\(', a) else '',
                   (h.group(2) if h else s.group(2) if s else a)))
    return out


def parse_tool(path, text, cfg, read):
    """a migration of a MIG_TOOLS tool -> [ its one changeSet ]"""
    n, t, m = mig_tool(path, text, cfg)
    up, down = split_ud(text, t)
    if t.get('down'):
        dp = re.sub(*t['down'], path)
        down = read(dp) if dp != path else None
    sql = path.endswith('.sql')
    ch = [change_from('sql', {}, [], '', up)] if sql else code_changes(up)
    live = lambda s: s is not None and bool(re.sub(r'(?m)^\s*(--|#|//).*$|\bpass\b|[\s{}();]|\bend\b|\breturn\b', '', s))
    rb = 'missing' if down is None else ('present' if (live(down) if sql else code_changes(down) or re.search(r'\bexecute|\.sql\(|raw\(', down)) else 'empty')
    if 'auto' in t and (not t['auto'] or re.search(t['auto'], text)):
        rb = 'present' if len(re.findall(r'reverse_\w+\s*=', text)) >= len(re.findall(r'\bRun(SQL|Python)\(', text)) > 0 else 'missing'
    idm = re.search(t['id'], text) if t.get('id') else None
    v = idm.group(1) if idm else m.group('v') or m.group('n')
    attrs = {'runOnChange': 'true'} if m.groupdict().get('r') == 'R' else {}
    x = {'tool': n, 'v': m.group('v') or m.group('n'), 'app': m.groupdict().get('app') or '', 'file': os.path.basename(path), 'prev': ''}
    if t.get('prev'): p = re.search(t['prev'], text); x['prev'] = p.group(1) if p else t.get('first', '')
    cs = cs_record(v, '', attrs, ch, rb, [], '', text + (down or ''))
    cs['x'] = x
    return [cs]


def parse(path, text, cfg, read=None):
    """-> (changesets or None, why-not, parser); read(path) -> text of another file (a down file)"""
    for p in cfg.get('parsers') or []:
        if re.search(p.get('match', '$^'), path):
            if p.get('cmd'):
                r = subprocess.run(f'{p["cmd"]} "{path}"', shell=True, capture_output=True, text=True, input=text)
                if r.returncode: return None, f'parser command failed: {r.stderr.strip()[:200]}', 'cmd'
                return json.loads(r.stdout).get('changesets', []), '', 'cmd'
            if p.get('parser') == 'heavy': return None, f'parser "heavy" set for {path}', 'heavy'
            return run_parser(p.get('parser'), path, text)
    ext = os.path.splitext(path)[1].lower()
    if ext == '.xml': return run_parser('liquibase-xml', path, text)
    if ext in ('.yaml', '.yml'): return run_parser('liquibase-yaml', path, text)
    if ext == '.json': return run_parser('liquibase-json', path, text)
    if ext == '.sql' and re.match(r'\s*--\s*liquibase\s+formatted\s+sql', text, re.I): return run_parser('liquibase-sql', path, text)
    if mig_tool(path, text, cfg)[0]:
        try:
            return parse_tool(path, text, cfg, read or (lambda p: None)), '', 'tool'
        except Exception as ex:  # noqa: BLE001 - HEAVY
            return None, f'parse failed: {str(ex)[:160]}', 'unparsed'
    if ext == '.sql': return None, FILE_RULES['raw-sql-file'], 'raw-sql-file'
    return None, f'no parser for {ext or "this file"}', 'unparsed'


def run_parser(name, path, text):
    try:
        fn = {'liquibase-xml': parse_xml, 'liquibase-yaml': parse_yaml, 'liquibase-json': lambda t: parse_struct(json.loads(t)),
         'liquibase-sql': parse_formatted_sql}[name]
        return fn(text), '', name
    except KeyError: return None, f'unknown parser {name}', 'unparsed'
    except Exception as ex:  # noqa: BLE001 - any parse failure makes the file HEAVY
        return None, f'{name} parse failed: {str(ex)[:160]}', 'unparsed'


# --- rules
def setting(v, cfg):
    return cfg.get(v[1:]) if isinstance(v, str) and v.startswith('@') else v


def sql_unsafe(body, cfg):
    s = re.sub(r'/\*.*?\*/', ' ', body or '', flags=re.S)
    s = '\n'.join(l for l in s.splitlines() if not l.strip().startswith('--'))
    for stmt in (norm(x) for x in s.split(';')):
        if not stmt: continue
        if any(re.search(p, stmt, re.I) for p in cfg['heavySql']) or not any(re.search(p, stmt, re.I | re.S) for p in cfg['lightSql']): return stmt[:90]
        if re.match(r'(?i)INSERT\b', stmt) and len(re.findall(r'\)\s*,\s*\(', stmt)) + 1 > int(cfg['smallDataRows']):
            return f'{stmt[:60]}... (over smallDataRows rows)'
        m = re.match(r'(?i)DELETE\s+FROM\s+[`"]?(?:\w+\.)?(\w+)', stmt)
        if m and not re.search(cfg['referenceTables'], m.group(1)): return stmt[:90]
    return None


def match(rule, item, ctx, cfg):
    """item: the changeset (scope changeset) or one change; ctx: { cs, created, rows }"""
    cs = ctx['cs']
    for k, want in rule.items():
        want = setting(want, cfg)
        if k in ('id', 'class', 'why', 'scope'): continue
        if k == 'status' and not re.search(want, cs['status']): return False
        if k == 'attr' and not all(re.search(p, cs['attrs'].get(a, '')) for a, p in want.items()): return False
        if k == 'rollback' and cs['rollback'] != want: return False
        if k == 'onlyTag' and (all(c['type'] == 'tagDatabase' for c in cs['changes'])) != want: return False
        if k == 'autoRollback' and (all(c['type'] in AUTO for c in cs['changes'])) != want: return False
        if k == 'onFail' and not re.search(want, cs['onFail']): return False
        if k == 'change' and not re.search(want, item.get('type', '')): return False
        if k == 'known' and (item.get('type') in KNOWN) != want: return False
        if k == 'createdHere':
            t = item.get('table', '')
            targets = [t] if item.get('type') in ('dropTable', 'createTable') or not item.get('columns') else [f'{t}.{c}' for c in item['columns']]
            if all(x in ctx['created'] or x.split('.')[0] in ctx['created'] for x in targets) != want: return False
        if k == 'where' and item.get('where') != want: return False
        if k == 'table' and not re.search(want, item.get('table', '')): return False
        if k == 'rowsOver' and ctx['rows'].get(item.get('table'), 0) <= int(want): return False
        if k == 'sqlUnsafe':
            ctx['stmt'] = sql_unsafe(item.get('sql'), cfg)
            if bool(ctx['stmt']) != want: return False
    return True


def judge(cs, created, cfg):
    """-> (class, rule id, why) of one changeset"""
    rows = {}
    for c in cs['changes']:
        if c['type'] == 'insert': rows[c['table']] = rows.get(c['table'], 0) + 1
    ctx = {'cs': cs, 'created': created, 'rows': rows, 'stmt': ''}
    items = [('changeset', cs)] + [('change', c) for c in cs['changes']]
    for scope, item in items:
        for r in cfg['rules']:
            rs = r.get('scope') or 'change'
            if rs != scope or not match(r, item, ctx, cfg): continue
            if r.get('class', 'heavy') == 'heavy':
                t = item.get('table', '') if scope == 'change' else ''
                tgt = ', '.join(f'{t}.{c}' for c in item.get('columns') or []) if scope == 'change' and item.get('columns') and item.get('type') != 'dropTable' else t
                why = r.get('why', r['id']).format(type=item.get('type', ''), table=t, target=tgt or t, rows=rows.get(t, 0), stmt=ctx.get('stmt') or '',
                        types=', '.join(sorted({c['type'] for c in cs['changes'] if c['type'] not in AUTO})) or 'it')
                return 'heavy', r['id'], why
            break   # light rule decides; next item
    return 'light', '', ''


# --- classify
def logical(path, cfg):
    return re.sub(cfg['logicalRoot'], '', path)


def vkey(v):
    return [(0, int(p), '') if p.isdigit() else (1, 0, p) for p in re.split(r'(\d+)', str(v)) if p]


def tool_ctx(x, path, repo, head, tree):
    """x += cwd (nearest marker folder, else the repo top), dir, down (relative to cwd), prev (the version before, by order)"""
    if not tree:
        for f in (git(repo, 'ls-tree', '-r', '--name-only', head, ok=True) or '').splitlines(): tree.setdefault(os.path.dirname(f), []).append(f)
    t = MIG_TOOLS[x['tool']]
    d = os.path.dirname(path)
    folder = os.path.dirname(d) if x['tool'] == 'prisma' else d
    cwd = d
    while cwd and not any(os.path.basename(f) == mk or (mk[0] == '.' and f.endswith(mk)) for f in tree.get(cwd, []) for mk in t.get('marker', ())):
        cwd = os.path.dirname(cwd)
    rel = lambda p: os.path.relpath(p or '.', cwd or '.').replace('\\', '/')
    x.update(cwd=cwd, dir=rel(d))
    if t.get('down'): x['down'] = rel(re.sub(*t['down'], path))
    if not x['prev']:
        sib = sorted({mm.group('v') for f in (tree.get(folder, []) if x['tool'] != 'prisma' else [g for k, fs in tree.items() if os.path.dirname(k) == folder for g in fs])
               for mm in [re.search(t['file'], f)] if mm and not NOT_MIG.search(f) and (mm.groupdict().get('app') or '') == x['app']}, key=vkey)
        before = [s for s in sib if vkey(s) < vkey(x['v'])]
        x['prev'] = before[-1] if before else t.get('first', '0')


def fill_cmd(cmd, id_, x, exec_=''):
    cmd = (cmd or '').replace('{exec}', (exec_ or '').replace('{file}', '"{down}"'))
    for k in ('v', 'prev', 'app', 'file', 'down', 'dir'): cmd = cmd.replace('{' + k + '}', str(x.get(k, '')))
    return cmd.replace('{id}', str(id_))


def classify(a, cfg):
    repo = a.repo
    mb = (git(repo, 'merge-base', a.base, a.head, ok=True) or '').strip() or a.base
    under = [u.strip().strip('/').replace('\\', '/') for u in (a.under or '').split(',') if u.strip()]
    tok = (git(repo, 'diff', '--name-status', '-z', '-M', mb, a.head) or '').split('\0')
    rows, i = [], 0
    while i < len(tok) and tok[i]:
        n = 3 if tok[i][0] in 'RC' else 2   # R<score>\0old\0new, else <st>\0path
        rows.append(tok[i:i + n]); i += n
    out, reasons, files, created, tree = [], [], [], set(), {}
    parsed = []
    for r in rows:
        st, path, old = r[0][0], r[-1], r[1] if len(r) > 2 else r[1]
        if not (re.search(cfg['pattern'], path) or any(re.search(t['file'], path) for t in MIG_TOOLS.values())) or NOT_MIG.search(path) or (
          under and not any(path == u or path.startswith(u + '/') for u in under)):
            continue
        head_text = git(repo, 'show', f'{a.head}:{path}', ok=True) if st != 'D' else None
        base_text = git(repo, 'show', f'{mb}:{old}', ok=True) if st in 'MRD' else None
        if not re.search(cfg['pattern'], path) and not mig_tool(path, head_text or base_text or '', cfg)[0]:
            continue   # a tool's file name only, not its content
        files.append({'path': path, 'logical': logical(path, cfg), 'status': st})
        parsed.append((st, path, old, head_text, base_text))
    for st, path, old, head_text, base_text in parsed:
        lp = logical(path, cfg)
        if (st != 'D' and head_text is None) or (st in 'MRD' and base_text is None):
            out.append({'file': lp, 'path': path, 'id': '*', 'author': '', 'hash': '', 'status': 'unparsed', 'class': 'heavy', 'rule': 'unparsed',
               'why': FILE_RULES['unparsed'].format(why='git show could not read it'), 'guarded': False, 'creates': [], 'refs': [], 'changes': []})
            continue
        new_cs, why_h, _ = parse(path, head_text, cfg, lambda p: git(repo, 'show', f'{a.head}:{p}', ok=True)) if head_text is not None else ([], '', '')
        old_cs, why_b, _ = parse(old, base_text, cfg, lambda p: git(repo, 'show', f'{mb}:{p}', ok=True)) if base_text is not None else ([], '', '')
        if new_cs is None or old_cs is None:
            why = why_h or why_b
            rule = 'raw-sql-file' if why == FILE_RULES['raw-sql-file'] else 'unparsed'
            out.append({'file': lp, 'path': path, 'id': '*', 'author': '', 'hash': '', 'status': 'unparsed', 'class': 'heavy', 'rule': rule,
               'why': FILE_RULES['unparsed'].format(why=why) if rule == 'unparsed' else why, 'guarded': False, 'creates': [], 'refs': [], 'changes': []})
            continue
        if not new_cs and not old_cs:
            continue   # a master file that only includes others
        base_keys = {(c['id'], c['author']): c['hash'] for c in old_cs}
        for c in new_cs:
            k = (c['id'], c['author'])
            c['status'] = 'renamed' if st == 'R' and k in base_keys else ('added' if k not in base_keys else ('modified' if base_keys[k] != c['hash'] else 'same'))
        for c in old_cs:
            if (c['id'], c['author']) not in {(x['id'], x['author']) for x in new_cs}: c['status'] = 'removed'; new_cs.append(c)
        for c in new_cs:
            if c['status'] == 'same': continue
            c.update({'file': lp, 'path': path})
            if c.get('x'): tool_ctx(c['x'], path, repo, a.head, tree)
            out.append(c)
    for c in out:   # file order: only EARLIER changeSets' objects count as "created here"
        if c['id'] == '*': continue
        c['class'], c['rule'], c['why'] = judge(c, created, cfg)
        if c['status'] == 'added':
            for ch in c['changes']: created.update(ch['creates'])
        c['guarded'] = bool(re.search(r'(?i)MARK_RAN|CONTINUE', c['onFail']))
        c['creates'] = sorted({x for ch in c['changes'] for x in ch['creates']})
        c['refs'] = sorted({x for ch in c['changes'] for x in ch['refs']} - set(c['creates']))
    for c in out:
        if c['class'] == 'heavy': reasons.append(f"{c['file']}::{c['id']} {c['rule']}: {c['why']}")
    res = {'repo': repo, 'base': a.base, 'mergeBase': mb, 'head': a.head, 'class': 'none' if not out else ('heavy' if reasons else 'light'),
     'reasons': reasons, 'files': files, 'tools': {c['x']['tool']: {'cwd': c['x']['cwd'], **{k: fill_cmd(MIG_TOOLS[c['x']['tool']].get(k), c['id'], c['x'])
      for k in ('apply', 'dry')}} for c in out if c.get('x')},
     'changesets': [{k: c.get(k) for k in ('file', 'path', 'id', 'author', 'hash', 'status', 'class', 'rule', 'why', 'guarded', 'creates', 'refs', 'x')} | {'types': [ch['type'] for ch in c.get('changes', [])]} for c in out]}
    if a.save:
        os.makedirs(os.path.join(a.save, 'files'), exist_ok=True)
        for f in files:
            t = git(repo, 'show', f'{a.head}:{f["path"]}', ok=True)
            if t is not None:
                dst = os.path.join(a.save, 'files', *f['logical'].split('/'))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, 'w', encoding='utf-8', newline='') as fh: fh.write(t)
        res['saved'] = os.path.abspath(a.save)
        with open(os.path.join(a.save, 'manifest.json'), 'w', encoding='utf-8') as fh: json.dump(res, fh, indent=1)
    return res


# --- plan
def key(c):
    return f"{c['file']}::{c['id']}::{c['author']}"


def cut_file(text, path, ids):
    """the changelog text with only the changeSets whose (id, author) is in ids"""
    ext = os.path.splitext(path)[1].lower()
    if ext == '.xml':
        def keep(m):
            mi, ma = re.search(r'\bid\s*=\s*"([^"]*)"', m.group(0)), re.search(r'\bauthor\s*=\s*"([^"]*)"', m.group(0))
            return m.group(0) if mi and ma and (mi.group(1), ma.group(1)) in ids else ''
        return re.sub(r'<changeSet\b.*?</changeSet>', keep, text, flags=re.S)
    if ext == '.sql':
        parts = re.split(r'(?m)^(?=--\s*changeset\s+)', text)
        kept = [parts[0]]
        for p in parts[1:]:
            m = re.match(r'--\s*changeset\s+(?:"([^"]+)"|([^:\s]+)):(\S+)', p)
            if m and ((m.group(3), m.group(1) or m.group(2)) in ids): kept.append(p)
        return ''.join(kept)
    doc = json.loads(text) if ext == '.json' else __import__('yaml').safe_load(text)
    doc['databaseChangeLog'] = [x for x in doc.get('databaseChangeLog') or [] if not (isinstance(x, dict) and 'changeSet' in x) or (str(x['changeSet'].get('id')), str(x['changeSet'].get('author'))) in ids]
    return json.dumps(doc, indent=1) if ext == '.json' else __import__('yaml').safe_dump(doc, sort_keys=False)


def plan(a, cfg):
    load = lambda paths: [json.load(open(p, encoding='utf-8-sig')) | {'_path': p} for p in (paths or '').split(',') if p.strip()]
    leaving, staying = load(a.leaving), load(a.staying)
    stay = {(key(c), c['hash']) for m in staying for c in m.get('changesets', [])}
    in_tree = {}
    if a.repo:
        for m in leaving:
            for f in {c['path'] for c in m.get('changesets', [])}:
                p = os.path.join(a.repo, *f.split('/'))
                if f not in in_tree:
                    try:
                        rd = lambda q: open(os.path.join(a.repo, *q.split('/')), encoding='utf-8').read() if os.path.exists(os.path.join(a.repo, *q.split('/'))) else None
                        cs, _, _ = parse(f, rd(f), cfg, rd) if os.path.exists(p) else ([], '', '')
                    except OSError: cs = []
                    in_tree[f] = {(c['id'], c['author']): c['hash'] for c in cs or []}
    revert, kept = [], []
    for m in reversed(leaving):   # newest layer first, its changeSets newest first
        for c in reversed(m.get('changesets', [])):
            if c['id'] == '*' or c['status'] == 'removed': continue
            if (key(c), c['hash']) in stay or in_tree.get(c['path'], {}).get((c['id'], c['author'])) == c['hash']:
                kept.append({'key': key(c), 'why': 'still in the release (target or another layer)'})
            else:
                revert.append(c | {'layer': m.get('layer') or os.path.dirname(m['_path'])})
    # a staying changeSet using what a revert drops (and nothing recreates) blocks it
    gone = {x for c in revert for x in c.get('creates', [])} - {x for m in staying for c in m.get('changesets', []) for x in c.get('creates', [])}
    blocked = []
    for m in staying:
        for c in m.get('changesets', []):
            hit = sorted(set(c.get('refs', [])) & gone)
            sx = c.get('x') or {}   # an ordered tool reverts by version: a newer staying migration of the folder goes too
            hit += [f"{sx['tool']} order: newer than {r['id']}" for r in revert if MIG_TOOLS.get(sx.get('tool'), {}).get('ordered') and (r.get('x') or {}).get('tool') == sx['tool']
                and (r['x']['cwd'], r['x']['dir']) == (sx['cwd'], sx['dir']) and (vkey(sx['v']) > vkey(r['x']['v']) or MIG_TOOLS[sx['tool']]['ordered'] == 2)][:1]
            if hit: blocked.append({'key': key(c), 'layer': m.get('layer') or os.path.dirname(m['_path']), 'uses': hit})
    for c in revert:
        x = c.get('x')
        c['cmd'] = fill_cmd(MIG_TOOLS[x['tool']].get('revert'), c['id'], x, cfg.get('exec')) if x else ''
        if x and x['tool'] == 'sql' and not (cfg.get('exec') and x.get('down')):
            c['cmd'] = ''   # no down script or no migrations.exec: db.rollback decides
    res = {'revert': [{k: c.get(k) for k in ('file', 'path', 'id', 'author', 'hash', 'guarded', 'layer', 'x', 'cmd')} for c in revert], 'kept': kept, 'blocked': blocked, 'count': len(revert),
       'commands': [{'cwd': c['x']['cwd'], 'cmd': c['cmd']} for c in revert if c['cmd']], 'hook': sum(1 for c in revert if not c['cmd'])}
    if a.out and revert:
        fd = os.path.join(a.out, 'files')
        os.makedirs(fd, exist_ok=True)
        by_file = {}
        for c in (c for c in revert if not c.get('x')): by_file.setdefault((c['file'], c['path']), set()).add((c['id'], c['author']))
        src_dirs = {c['file']: m.get('saved') for m in leaving for c in m.get('changesets', [])}
        for (lf, path), ids in by_file.items():
            src = os.path.join(src_dirs.get(lf) or '', 'files', *lf.split('/'))
            text = open(src, encoding='utf-8').read() if os.path.exists(src) else ''
            dst = os.path.join(fd, *lf.split('/'))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, 'w', encoding='utf-8', newline='') as fh: fh.write(cut_file(text, path, ids))
        inc = ''.join(f'  <include file="{lf}" relativeToChangelogFile="false"/>\n' for lf, _ in by_file)
        with open(os.path.join(fd, 'localenv-revert.xml'), 'w', encoding='utf-8') as fh:
            fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog" '
                   'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog '
                   'http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">\n' + inc + '</databaseChangeLog>\n')
        res['searchPath'] = os.path.abspath(fd); res['changelog'] = 'localenv-revert.xml'
        with open(os.path.join(a.out, 'revert.json'), 'w', encoding='utf-8') as fh: json.dump(res, fh, indent=1)
        res['manifest'] = os.path.abspath(os.path.join(a.out, 'revert.json'))
    return res


def mig_main(argv):
    ap = argparse.ArgumentParser(prog='devtools.py migrations')
    ap.add_argument('cmd', choices=['classify', 'plan', 'rules', 'detect'])
    for o in ('--repo', '--base', '--head', '--config', '--under', '--save', '--leaving', '--staying', '--out'): ap.add_argument(o)
    a = ap.parse_args(argv)
    cfg = load_cfg(a.config)
    if a.cmd == 'rules': res = {'rules': cfg['rules'], **{k: cfg[k] for k in DEFAULTS}}
    elif a.cmd == 'detect':   # tracked migrations per tool, Liquibase aside (dev.ps1 check -Step migrations)
        res, unknown = {}, []
        fs = (git(a.repo, 'ls-files') or '').splitlines()
        lb_master = any(re.search(r'(?i)master\.(xml|ya?ml|json|sql)$', f) for f in fs)
        for f in fs:
            lb, n = re.search(r'(?i)liquibase|changelog', f), None
            if any(re.search(t['file'], f) for t in MIG_TOOLS.values()) and not lb:
                p = os.path.join(a.repo, *f.split('/'))
                n = mig_tool(f, open(p, encoding='utf-8', errors='replace').read() if os.path.isfile(p) else '', cfg)[0]
                if n: res[n] = res.get(n, 0) + 1
            # no tool parses it: UNRUN
            if not n and re.search(cfg['pattern'], f) and not NOT_MIG.search(f) and not (lb and lb_master) and re.search(MIG_EXT, f):
                unknown.append(f)
        if unknown: res['unknown tool'] = ', '.join(unknown[:5])
    elif a.cmd == 'classify': res = classify(a, cfg)
    else:
        res = plan(a, cfg)
    print(json.dumps(res, indent=1))



# --- selftest (git, temp repos): python -X utf8 devtools.py migrations selftest; exit 0 = all pass
SELFTEST = r'''import json, os, shutil, subprocess, sys, tempfile, unittest

SCRIPT = os.path.abspath(__file__)
CL = 'api/src/main/resources/config/liquibase/changelog'
HEAD = ('<?xml version="1.0" encoding="utf-8"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog">\n')
TAIL = '</databaseChangeLog>\n'


def xml(*changesets):
 return HEAD + ''.join(changesets) + TAIL


def cs(id_, body, rollback=None, attrs='', pre=''):
 rb = '' if rollback is None else (f'<rollback>{rollback}</rollback>' if rollback else '<rollback/>')
 return f'  <changeSet id="{id_}" author="dev"{attrs}>{pre}{body}{rb}</changeSet>\n'


TAG = lambda t: cs(f'{t}-0', f'<tagDatabase tag="{t}"/>')
ADD = lambda c: f'<addColumn tableName="orders"><column name="{c}" type="INT"/></addColumn>'
DROP = lambda c: f'<dropColumn tableName="orders" columnName="{c}"/>'
SEL, MK, DT = '<sql>SELECT 1</sql>', '<sql>CREATE TABLE orders (id BIGINT)</sql>', '<dropTable tableName="orders"/>'


def run(*a):
 p = subprocess.run([sys.executable, '-X', 'utf8', SCRIPT, 'migrations', *a], capture_output=True, text=True, encoding='utf-8')
 if p.returncode:
  raise AssertionError(p.stderr)
 return json.loads(p.stdout)


class Repo:
 def __init__(self):
  self.d = tempfile.mkdtemp(prefix='mig-test-')
  self.g('init', '-q', '-b', 'main'); self.g('config', 'user.email', 't@t'); self.g('config', 'user.name', 't')
  self.write(f'{CL}/20260101000000_base.xml', xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/><column name="qty" type="INT"/></createTable>')))
  self.write('api/src/main/java/App.java', 'class App {}')
  self.commit('base')

 def g(self, *a):
  return subprocess.run(['git', '-C', self.d, *a], capture_output=True, text=True, check=True).stdout.strip()

 def write(self, rel, text):
  p = os.path.join(self.d, *rel.split('/'))
  os.makedirs(os.path.dirname(p), exist_ok=True)
  open(p, 'w', encoding='utf-8', newline='\n').write(text)

 def commit(self, msg):
  self.g('add', '-A'); self.g('commit', '-q', '-m', msg); return self.g('rev-parse', 'HEAD')

 def branch(self, name, files, base='main'):
  self.g('checkout', '-q', '-b', name, base)
  for rel, text in files.items():
   if text is None:
    os.remove(os.path.join(self.d, *rel.split('/')))
   else:
    self.write(rel, text)
  sha = self.commit(name); self.g('checkout', '-q', 'main'); return sha

 def classify(self, sha, save=None, cfg=None):
  a = ['classify', '--repo', self.d, '--base', 'main', '--head', sha]
  if save:
   a += ['--save', save]
  if cfg:
   p = os.path.join(self.d, '..', os.path.basename(self.d) + '-cfg.json'); open(p, 'w', encoding='utf-8').write(json.dumps(cfg)); a += ['--config', p]
  return run(*a)


LIGHT_FILE = xml(TAG('20260201000000'),
        cs('20260201000000-1', '<addColumn tableName="orders"><column name="note" type="VARCHAR(80)"/></addColumn>',
     DROP('note'), pre='<preConditions onFail="MARK_RAN"><not><columnExists tableName="orders" columnName="note"/></not></preConditions>'),
        cs('20260201000000-2', '<createTable tableName="order_status"><column name="id" type="INT"/><column name="code" type="VARCHAR(20)"/></createTable>'),
        cs('20260201000000-3', '<insert tableName="order_status"><column name="id" valueNumeric="1"/><column name="code" value="NEW"/></insert>',
     '<delete tableName="order_status"><where>id = 1</where></delete>'),
        cs('20260201000000-4', '<update tableName="orders"><column name="qty" valueNumeric="0"/><where>qty IS NULL AND id IN (SELECT id FROM orders WHERE 1=0)</where></update>',
     '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>'),
        cs('20260201000000-5', '<sql>ALTER TABLE orders ADD INDEX ix_orders_qty (qty)</sql>', '<sql>ALTER TABLE orders DROP INDEX ix_orders_qty</sql>'))


class Classify(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.r = Repo()

 @classmethod
 def tearDownClass(cls):
  shutil.rmtree(cls.r.d, ignore_errors=True)

 def test_light(self):
  sha = self.r.branch('light', {f'{CL}/20260201000000_light.xml': LIGHT_FILE})
  res = self.r.classify(sha)
  self.assertEqual(res['class'], 'light', res['reasons'])
  self.assertEqual([c['id'] for c in res['changesets']], [f'20260201000000-{i}' for i in range(6)])
  self.assertEqual(res['changesets'][0]['file'], 'config/liquibase/changelog/20260201000000_light.xml')
  self.assertTrue(res['changesets'][1]['guarded'])
  self.assertIn('order_status', res['changesets'][2]['creates'])

 def test_no_migrations(self):
  sha = self.r.branch('code-only', {'api/src/main/java/App.java': 'class App { int x; }'})
  self.assertEqual(self.r.classify(sha)['class'], 'none')

 def heavy(self, name, body, rule, rollback='', **kw):
  sha = self.r.branch(name, {f'{CL}/20260301000000_{name}.xml': xml(TAG('20260301000000'), cs('20260301000000-1', body, rollback, **kw))})
  res = self.r.classify(sha)
  self.assertEqual(res['class'], 'heavy', f'{name}: {res}')
  self.assertEqual(res['changesets'][1]['rule'], rule, res['reasons'])
  return res

 def test_heavy_rules(self):
  self.heavy('dropcol', DROP('qty'), 'drop-data', ADD('qty'))
  self.heavy('droptable', DT, 'drop-data', MK)
  self.heavy('unbounded', '<update tableName="orders"><column name="qty" valueNumeric="0"/></update>', 'unbounded', '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>')
  self.heavy('delrows', '<delete tableName="orders"><where>qty = 0</where></delete>', 'delete-rows', SEL)
  self.heavy('emptyrb', ADD('x'), 'empty-rollback', '')
  self.heavy('norb', '<sql>ALTER TABLE orders ADD COLUMN y INT</sql>', 'no-rollback', None)
  self.heavy('always', '<sql>ALTER TABLE orders ADD COLUMN z INT</sql>', 'runs-always', '<sql>ALTER TABLE orders DROP INDEX z</sql>', attrs=' runAlways="true"')
  self.heavy('rawsql', '<sql>ALTER TABLE orders MODIFY qty BIGINT</sql>', 'raw-sql', '<sql>ALTER TABLE orders MODIFY qty INT</sql>')
  self.heavy('retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="SMALLINT"/>', 'retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="INT"/>')
  self.heavy('loaddata', '<loadData tableName="orders" file="x.csv"/>', 'bulk-file', SEL)

 def test_order_and_sql_gaps_are_heavy(self):
  # drop an existing column, add it back later: the first changeSet still drops data
  sha = self.r.branch('dropreadd', {f'{CL}/20260402000000_x.xml': xml(
   cs('20260402000000-1', DROP('qty'), ADD('qty')),
   cs('20260402000000-2', ADD('qty')))})
  res = self.r.classify(sha)
  self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'drop-data'), res['reasons'])
  # CREATE TABLE IF NOT EXISTS then a drop of it: the table may have existed
  sha = self.r.branch('ifnot', {f'{CL}/20260403000000_x.xml': xml(
   cs('20260403000000-1', '<sql>CREATE TABLE IF NOT EXISTS orders (id BIGINT)</sql>', SEL),
   cs('20260403000000-2', DT, MK))})
  self.assertEqual(self.r.classify(sha)['changesets'][1]['rule'], 'drop-data')
  for name, body in (('altdrop', 'ALTER TABLE orders ADD note INT, DROP qty'), ('upsert', 'INSERT INTO orders (id) VALUES (1) ON DUPLICATE KEY UPDATE qty = 0'),
             ('trivwhere', 'UPDATE orders SET qty = 0 WHERE 1=1')):
   self.heavy(name, f'<sql>{body}</sql>', 'raw-sql', SEL)
  self.heavy('trivxml', '<update tableName="orders"><column name="qty" valueNumeric="0"/><where>1=1</where></update>', 'unbounded', SEL)

 def test_non_ascii_path_is_read(self):
  sha = self.r.branch('uml', {f'{CL}/20260404000000_bestellung_\u00e4.xml': xml(cs('20260404000000-1', DT, MK))})
  self.assertEqual(self.r.classify(sha)['class'], 'heavy')

 def test_drop_own_is_light(self):
  sha = self.r.branch('dropown', {f'{CL}/20260401000000_own.xml': xml(
   cs('20260401000000-1', ADD('tmp')),
   cs('20260401000000-2', DROP('tmp'), ADD('tmp')))})
  self.assertEqual(self.r.classify(sha)['class'], 'light')

 def test_edit_applied_and_raw_file(self):
  base = f'{CL}/20260101000000_base.xml'
  sha = self.r.branch('edit', {base: xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/></createTable>'))})
  res = self.r.classify(sha)
  self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'edits-applied'))
  sha = self.r.branch('rawfile', {'api/src/main/resources/db/migrations/fix.sql': 'UPDATE orders SET qty = 1;'})
  res = self.r.classify(sha)
  self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'raw-sql-file'))

 def test_mixed_is_heavy_and_names_the_changeset(self):
  sha = self.r.branch('mixed', {f'{CL}/20260501000000_mixed.xml': xml(
   TAG('20260501000000'), cs('20260501000000-1', ADD('ok')),
   cs('20260501000000-2', '<delete tableName="orders"/>', SEL))})
  res = self.r.classify(sha)
  self.assertEqual(res['class'], 'heavy')
  self.assertEqual([c['class'] for c in res['changesets']], ['light', 'light', 'heavy'])
  self.assertEqual(res['reasons'], ['config/liquibase/changelog/20260501000000_mixed.xml::20260501000000-2 unbounded: unbounded delete on orders (no WHERE)'])

 def test_formatted_sql_and_yaml(self):
  sql = ('--liquibase formatted sql\n--changeset dev:20260601000000-1\nALTER TABLE orders ADD COLUMN s INT;\n'
       '--rollback ALTER TABLE orders DROP COLUMN s;\n--changeset dev:20260601000000-2\nDELETE FROM orders WHERE id > 5;\n--rollback not required\n')
  sha = self.r.branch('fsql', {f'{CL}/20260601000000_x.sql': sql})
  res = self.r.classify(sha)
  self.assertEqual([(c['class'], c['rule']) for c in res['changesets']], [('light', ''), ('heavy', 'empty-rollback')])
  yml = ('databaseChangeLog:\n- changeSet:\n    id: 20260701000000-1\n    author: dev\n    changes:\n    - addColumn:\n        tableName: orders\n'
       '        columns:\n        - column:\n            name: y\n            type: INT\n')
  sha = self.r.branch('yml', {f'{CL}/20260701000000_x.yaml': yml})
  res = self.r.classify(sha)
  try:
   import yaml  # noqa: F401
   self.assertEqual(res['class'], 'light', res)
  except ImportError:
   self.assertEqual(res['changesets'][0]['rule'], 'unparsed')

 def test_rules_are_configurable(self):
  sha = self.r.branch('cfg', {f'{CL}/20260801000000_x.xml': xml(cs('20260801000000-1', '<delete tableName="orders"><where>id = 1</where></delete>', SEL))})
  self.assertEqual(self.r.classify(sha)['class'], 'heavy')
  self.assertEqual(self.r.classify(sha, cfg={'referenceTables': '^orders$'})['class'], 'light')
  res = self.r.classify(sha, cfg={'extraRules': [{'id': 'no-orders', 'table': '^orders$', 'class': 'heavy', 'why': 'org rule'}], 'referenceTables': '^orders$'})
  self.assertEqual(res['changesets'][0]['rule'], 'no-orders')


class Plan(unittest.TestCase):
 def setUp(self):
  self.r = Repo(); self.tmp = tempfile.mkdtemp(prefix='mig-plan-')

 def tearDown(self):
  shutil.rmtree(self.r.d, ignore_errors=True); shutil.rmtree(self.tmp, ignore_errors=True)

 def manifest(self, name, sha):
  d = os.path.join(self.tmp, name); self.r.classify(sha, save=d); return os.path.join(d, 'manifest.json')

 def test_revert_only_the_leaving_layer_newest_first(self):
  a = self.manifest('a', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
  b = self.manifest('b', self.r.branch('b', {f'{CL}/20260901000000_b.xml': xml(cs('20260901000000-1', '<createIndex tableName="orders" indexName="ix_q"><column name="qty"/></createIndex>'))}))
  out = os.path.join(self.tmp, 'out')
  res = run('plan', '--leaving', a, '--staying', b, '--repo', self.r.d, '--out', out)
  self.assertEqual([c['id'] for c in res['revert']], [f'20260201000000-{i}' for i in (5, 4, 3, 2, 1, 0)])
  self.assertEqual(res['blocked'], [])
  cut = open(os.path.join(res['searchPath'], 'config', 'liquibase', 'changelog', '20260201000000_light.xml'), encoding='utf-8').read()
  self.assertEqual(cut.count('<changeSet'), 6)
  self.assertIn('config/liquibase/changelog/20260201000000_light.xml', open(os.path.join(res['searchPath'], 'localenv-revert.xml'), encoding='utf-8').read())

 def test_dependent_layer_blocks(self):
  a = self.manifest('a', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
  c = self.manifest('c', self.r.branch('c', {f'{CL}/20261001000000_c.xml': xml(cs('20261001000000-1',
   '<addForeignKeyConstraint baseTableName="orders" baseColumnNames="qty" constraintName="fk_orders_qty" referencedTableName="order_status" referencedColumnNames="id"/>'))}))
  res = run('plan', '--leaving', a, '--staying', c)
  self.assertEqual(res['blocked'][0]['uses'], ['order_status', 'order_status.id'])

 def test_changesets_still_in_release_are_kept(self):
  sha = self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE})
  a = self.manifest('a', sha)
  self.r.g('merge', '-q', '--no-ff', '-m', 'merged', 'a')   # the layer was merged into the target: nothing to revert
  res = run('plan', '--leaving', a, '--repo', self.r.d)
  self.assertEqual((res['count'], len(res['kept'])), (0, 6))

 def test_replaced_layer_reverts_only_what_changed(self):
  a1 = self.manifest('a1', self.r.branch('a', {f'{CL}/20260201000000_light.xml': LIGHT_FILE}))
  self.r.g('checkout', '-q', 'a')
  self.r.write(f'{CL}/20260201000000_light.xml', LIGHT_FILE.replace('VARCHAR(80)', 'VARCHAR(120)'))
  a2sha = self.r.commit('a v2'); self.r.g('checkout', '-q', 'main')
  a2 = self.manifest('a2', a2sha)
  res = run('plan', '--leaving', a1, '--staying', a2)
  self.assertEqual([c['id'] for c in res['revert']], ['20260201000000-1'])


PY = 'revision = "{}"\ndown_revision = "{}"\ndef upgrade():\n  {}\ndef downgrade():\n  {}\n'
GO = '-- +goose Up\n{};\n-- +goose Down\n{}\n'
AC, DC = 'ALTER TABLE t ADD c INT;', 'ALTER TABLE t DROP COLUMN c;'
TOOLS = [   # (base files, branch files, class, rule, revert command)
 ({'a/alembic.ini': ''}, {'a/versions/b2_c.py': PY.format('b2', 'a1', 'op.add_column("t", sa.Column("c"))', 'op.drop_column("t", "c")')}, 'light', '', 'alembic downgrade a1'),
 ({}, {'a/versions/c3_x.py': PY.format('c3', 'b2', 'op.drop_column("t", "c")', 'pass')}, 'heavy', 'empty-rollback', None),
 ({'manage.py': '', 's/migrations/0001_a.py': ''}, {'s/migrations/0002_b.py': "migrations.AddField(model_name='book', name='isbn')"}, 'light', '', 'python manage.py migrate s 0001_a'),
 ({}, {'s/migrations/0003_c.py': 'migrations.RunPython(fill)'}, 'heavy', 'no-rollback', None),
 ({'A/A.csproj': '', 'A/Migrations/20240101000000_I.cs': ''}, {'A/Migrations/20240201000000_E.cs': 'void Up(M b) { b.AddColumn<string>(name: "Email", table: "U"); }\n'
  'void Down(M b) { b.DropColumn(name: "Email", table: "U"); }', 'A/Migrations/AModelSnapshot.cs': 'x'}, 'light', '', 'dotnet ef database update 20240101000000_I'),
 ({}, {'db/migrate/20240201000000_e.rb': 'def change\n  add_column :users, :email, :string\nend'}, 'light', '', 'bin/rails db:migrate:down VERSION=20240201000000'),
 ({}, {'db/migrate/20240301000000_r.rb': 'def change\n  remove_column :users, :email\nend'}, 'heavy', 'no-rollback', None),
 ({}, {'migrations/20240201000000_u.js': "exports.up = (knex) => knex.schema.createTable('u', (t) => { t.string('e') })\n"
  "exports.down = (knex) => knex.schema.dropTable('u')"}, 'light', '', 'npx knex migrate:down 20240201000000_u.js'),
 ({'m/00001_a.sql': GO.format('CREATE TABLE t (id INT)', 'DROP TABLE t;')}, {'m/00002_b.sql': GO.format(AC[:-1], DC)}, 'light', '', 'goose -dir "m" down-to 00001'),
 ({}, {'f/V2__c.sql': AC, 'f/U2__c.sql': DC}, 'light', '', 'flyway undo'),
 ({}, {'f/V2__c.sql': AC}, 'heavy', 'no-rollback', None),
 ({}, {'f/R__v.sql': 'CREATE OR REPLACE VIEW v AS SELECT 1;'}, 'heavy', 'runs-on-change', None),
 ({}, {'p/migrations/2024_a/migration.sql': AC, 'p/migrations/2024_a/down.sql': DC}, 'light', '',
 'npx prisma db execute --file "p/migrations/2024_a/down.sql" && npx prisma migrate resolve --rolled-back 2024_a'),
 ({'sqitch.plan': ''}, {'deploy/c.sql': f'BEGIN;\n{AC}\nCOMMIT;', 'revert/c.sql': DC}, 'light', '', 'sqitch revert -y --to c^'),
 ({}, {'q/0002_c.up.sql': AC, 'q/0002_c.down.sql': DC}, 'light', '', 'psql -f "q/0002_c.down.sql"'),
]

class Tools(unittest.TestCase):
 def test_each_tool(self):
  for i, (base, br, cls, rule, cmd) in enumerate(TOOLS):
   r = Repo(); tmp = tempfile.mkdtemp(prefix='mig-tool-')
   try:
    for k, v in base.items():
     r.write(k, v)
    if base:
     r.commit('tool base')
    sha = r.branch(f't{i}', br)
    res = r.classify(sha, save=tmp, cfg={'exec': 'psql -f {file}'})
    self.assertEqual((res['class'], res['changesets'][-1]['rule']), (cls, rule), f'{i}: {res["reasons"]}')
    p = run('plan', '--leaving', os.path.join(tmp, 'manifest.json'), '--config', os.path.join(r.d, '..', os.path.basename(r.d) + '-cfg.json'))
    if cmd:
     self.assertEqual(p['revert'][0]['cmd'], cmd, i)
   finally:
    shutil.rmtree(r.d, ignore_errors=True); shutil.rmtree(tmp, ignore_errors=True)

 def test_dialect_detect_and_order(self):
  r = Repo()
  sha = r.branch('d', {f'{CL}/20261101000000_x.xml': xml(cs('20261101000000-1', '<sql>INSERT IGNORE INTO orders (id) VALUES (1)</sql>', SEL))})
  self.assertEqual([r.classify(sha, cfg={'dialect': d})['class'] for d in ('mysql', 'postgres')], ['light', 'heavy'])
  g2 = r.branch('g2', {'db/m/00002_b.sql': GO.format('CREATE TABLE b (id INT)', 'DROP TABLE b;')})
  g3 = r.branch('g3', {'db/m/00003_c.sql': GO.format('CREATE TABLE c (id INT)', 'DROP TABLE c;')})
  d = tempfile.mkdtemp(prefix='mig-ord-'); r.classify(g2, save=d + '/a'); r.classify(g3, save=d + '/b')
  self.assertEqual(list(run('detect', '--repo', r.d)), ['unknown tool'])   # a changelog, no master: UNRUN
  r.g('checkout', '-q', 'g3'); self.assertEqual(run('detect', '--repo', r.d)['goose'], 1)
  p = run('plan', '--leaving', d + '/a/manifest.json', '--staying', d + '/b/manifest.json')
  self.assertIn('goose order', p['blocked'][0]['uses'][0])
  shutil.rmtree(r.d, ignore_errors=True); shutil.rmtree(d, ignore_errors=True)
'''


def mig_selftest():
    import unittest
    ns = {'__file__': os.path.abspath(__file__), '__name__': 'migrations_selftest'}
    exec(compile(SELFTEST, 'migrations-selftest', 'exec'), ns)
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(v) for v in ns.values() if isinstance(v, type) and issubclass(v, unittest.TestCase))
    return 0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1


# ===== findings (revy module audits)
FINDINGS_SCHEMA = r'''A finding: exactly these 23 string keys ("" when unknown).

| Key | Format |
|---|---|
| `id` | `<MODULE>-<BUG\|PERF\|REF\|GAP\|UX\|RPT>-NNN` |
| `module`, `area`, `title`, `subtype`, `source` | short text (`subtype` e.g. Data Integrity, Validation, Concurrency, Memory leak, Schema/Migration) |
| `layer` | `Web UI` \| `Java API` \| `.NET API` \| `Python` \| `Node API` \| `Mobile` \| `Desktop` \| `DB` \| `Jobs` \| `Integration` \| `Cross-cutting` (or the profile's own) |
| `type` | `Bug` \| `Performance` \| `Tech Debt` \| `Functional Gap` \| `UX` \| `Reporting` |
| `in_scope` | `Yes` (Bug / Performance / Tech Debt) \| `No` |
| `severity` | `Critical` \| `High` \| `Medium` \| `Low` |
| `current`, `expected`, `suggested_fix` | 1-2 sentences (`current` prefixed `(unverified)` when inferred) |
| `business_impact`, `root_cause`, `customer_impact` | 1 sentence (in scope only) |
| `why_today`, `why_not_prod` | in scope only, prefixed `(inferred)` unless evidenced; concrete |
| `db_migration` | `Yes` \| `No` \| `Maybe` |
| `code_location` | `file:line`, table or endpoint |
| `product_decision` | `Yes` \| `No` |
| `effort` | `Low` \| `Medium` \| `High` \| `""` |
| `existing_notes` | prior comments, links, cross-refs, the evidence tier |

Example finding: `{"id": "NOTIF-BUG-002", "module": "Notifications", "layer": "Node API", "type": "Bug", "in_scope": "Yes", "subtype":
"Data Integrity", "title": "Digest ignores the unsubscribe flag", "area": "Email settings", "severity": "High", "current": "Opted-out
users get the digest.", "expected": "They never get it.", "business_impact": "Unwanted email.", "root_cause": "The job never reads the
flag.", "why_today": "(inferred) The flag came after the job.", "why_not_prod": "(inferred) Few opt-outs so far.", "customer_impact":
"Opted-out users get mail.", "db_migration": "No", "suggested_fix": "Filter on the flag; add a test.", "code_location":
"DigestJob.buildRecipients()", "product_decision": "No", "effort": "Low", "existing_notes": "Evidence: 3 of 3 test users.", "source": "module review"}`

Project profile (<kit>/skills/dev-kit/projects/<project>.local.md, local; one per project):
# Project profile: <name>
## Repo layout
| Layer | Repo / folder | Stack (dev.ps1 stack) | Notes (migration tool, single- or multi-tenant, ...) |
## Intended-behaviour sources
- docs / knowledge base / MCP tools / decision records
## Live / test data (read-only)
- how to query a test environment; never production writes
## Findings output
- folder, id prefix, workbook generator (if any)
## Known by-design behaviours (not bugs)
## Review lessons
'''

def validate(argv):
    KEYS = ['id', 'module', 'layer', 'type', 'in_scope', 'subtype', 'title', 'area', 'severity', 'current', 'expected',
      'business_impact', 'root_cause', 'why_today', 'why_not_prod', 'customer_impact', 'db_migration', 'suggested_fix',
      'code_location', 'product_decision', 'effort', 'existing_notes', 'source']
    VOCAB = {'type': {'Bug', 'Performance', 'Tech Debt', 'Functional Gap', 'UX', 'Reporting'}, 'in_scope': {'Yes', 'No'},
        'severity': {'Critical', 'High', 'Medium', 'Low'}, 'db_migration': {'Yes', 'No', 'Maybe', ''},
        'product_decision': {'Yes', 'No'}, 'effort': {'Low', 'Medium', 'High', ''}}
    IN_SCOPE = {'Bug', 'Performance', 'Tech Debt'}
    ID = re.compile(r'^[A-Z0-9]+(-[A-Z0-9]+)*-(BUG|PERF|REF|GAP|UX|RPT)-\d+$')

    if len(argv) < 1:
        print(__doc__.strip())
        return (2)

    problems, seen, rows = [], set(), 0
    for path in argv:
        try:
            data = json.load(open(path, encoding='utf-8'))
        except Exception as e:
            problems.append(f'{path}: not valid JSON ({e})')
            continue
        if not isinstance(data, list):
            problems.append(f'{path}: top level must be a JSON array')
            continue
        for o in data:
            rows += 1
            if not isinstance(o, dict):
                problems.append(f'{path}: row {rows} is not a JSON object')
                continue
            fid = o.get('id', '?')
            if set(o) != set(KEYS):
                problems.append(f'{fid}: keys differ (missing {sorted(set(KEYS) - set(o))}, extra {sorted(set(o) - set(KEYS))})')
                continue
            if any(not isinstance(v, str) for v in o.values()):
                problems.append(f'{fid!r}: all values must be strings')
                continue   # checks below need strings
            if fid in seen: problems.append(f'{fid}: duplicate id')
            seen.add(fid)
            if not ID.match(fid): problems.append(f'{fid}: id should look like ABBR-BUG-001')
            for k, allowed in VOCAB.items():
                if o[k] not in allowed: problems.append(f'{fid}: {k}={o[k]!r} not in {sorted(allowed)}')
            if o['type'] in IN_SCOPE:
                if o['in_scope'] != 'Yes': problems.append(f'{fid}: {o["type"]} must be in_scope Yes')
                for k in (CFG.get('findings') or {}).get('required') or ('root_cause', 'why_today', 'why_not_prod', 'db_migration', 'code_location'):   # kit.local.json findings.required
                    if not o.get(k): problems.append(f'{fid}: in-scope finding needs {k}')
                if o['severity'] == 'Critical' and o['current'].startswith('(unverified)'): problems.append(f'{fid}: unverified finding cannot be Critical')
            else:
                if o['in_scope'] != 'No' or o['product_decision'] != 'Yes': problems.append(f'{fid}: {o["type"]} must be in_scope No, product_decision Yes')
                for k in ('root_cause', 'why_today', 'why_not_prod', 'customer_impact'):
                    if o[k]: problems.append(f'{fid}: out-of-scope finding should leave {k} empty')
            if o['current'].startswith('(unverified)') and o['severity'] in ('Critical', 'High'):
                problems.append(f'{fid}: unverified findings are capped at Medium')

    for p in problems: print(p)
    print('rows', rows, '| schema problems:', 'none' if not problems else len(problems))
    return (1 if problems else 0)


def summary(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--sources', default='')
    ap.add_argument('--out', default=None)
    a = ap.parse_args(argv)
    rows = json.load(open(a.file, encoding='utf-8'))
    module = rows[0]['module'] if rows else os.path.splitext(os.path.basename(a.file))[0]
    out = a.out or os.path.dirname(os.path.abspath(a.file))
    base = os.path.join(out, os.path.splitext(os.path.basename(a.file))[0] + '-summary')

    SEV = ['Critical', 'High', 'Medium', 'Low']
    COL = {'Critical': ('#7f1d1d', '#fee2e2'), 'High': ('#991b1b', '#fde8e8'), 'Medium': ('#92400e', '#fef3c7'), 'Low': ('#374151', '#f3f4f6')}
    ins = [r for r in rows if r['in_scope'] == 'Yes']
    outs = [r for r in rows if r['in_scope'] != 'Yes']
    by_type = Counter(r['type'] for r in ins)
    by_sev = Counter(r['severity'] for r in ins)
    top = sorted([r for r in ins if r['severity'] in ('Critical', 'High')], key=lambda r: SEV.index(r['severity']))
    decide = [r for r in ins if r['product_decision'] == 'Yes']
    unverified = [r for r in ins if r['current'].startswith('(unverified)')]
    dbm = [r for r in ins if r['db_migration'] == 'Yes']

    # --- Markdown
    md = [f'# Technical audit — {module}', '']
    types = ', '.join(f'{by_type[t]} {t}' for t in ('Bug', 'Performance', 'Tech Debt') if by_type[t])
    ranked = sorted(ins, key=lambda r: (SEV.index(r['severity']), r['id']))
    md.append(f'**{len(ins)} in-scope findings** ({types}) · '
      f'**{len(outs)} out-of-scope** captured for product · severity: ' + ', '.join(f'{by_sev[s]} {s}' for s in SEV if by_sev[s]))
    if a.sources:
        md.append(f'\nSources used: {a.sources}')
    md.append(f'\n{len(unverified)} finding(s) rest on unverified inference (capped at Medium); {len(dbm)} need a DB migration.')
    if top:
        md += ['', '## Critical / High', '', '| ID | Sev | Title | Where | Fix |', '|---|---|---|---|---|']
        md += [f"| {r['id']} | {r['severity']} | {r['title']} | `{r['code_location']}` | {r['suggested_fix']} |" for r in top]
    if decide:
        md += ['', '## Needs a product decision', ''] + [f"- **{r['id']}** {r['title']} — {r['expected']}" for r in decide]
    md += ['', '## All in-scope findings', '', '| ID | Type | Sev | Title | Effort |', '|---|---|---|---|---|']
    md += [f"| {r['id']} | {r['type']} | {r['severity']} | {r['title']} | {r['effort']} |" for r in ranked]
    if outs:
        md += ['', '## Out of scope (captured for product)', ''] + [f"- {r['id']} ({r['type']}): {r['title']}" for r in outs]
    open(base + '.md', 'w', encoding='utf-8').write('\n'.join(md) + '\n')

    # --- HTML
    E = html.escape
    cell = 'border:1px solid #d1d5db;padding:6px 8px;vertical-align:top;font-size:10pt'
    h2 = "font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:16px"
    H = [f"<html><head><meta charset='utf-8'></head><body style='font-family:Arial,Helvetica,sans-serif;color:#111827;font-size:10.5pt'>",
     "<p style='font-size:9pt;color:#6b7280;margin:0'>TECHNICAL AUDIT</p>",
     f"<h1 style='font-size:20pt;margin:2px 0 8px 0'>{E(module)}</h1><table style='border-collapse:collapse;margin:6px 0 12px 0'><tr>"]
    for (fg, bg), n, lbl in [(COL[s], by_sev[s], s.upper()) for s in SEV] + [(('#374151', '#f3f4f6'), len(outs), 'OUT OF SCOPE')]:
        H.append(f"<td style='background:{bg};color:{fg};padding:8px 14px;text-align:center;border:1px solid #fff'><span style='font-size:18pt;font-weight:bold'>{n}</span><br><span style='font-size:8pt;font-weight:bold'>{lbl}</span></td>")
    H.append('</tr></table>')
    H.append(f"<p>{len(ins)} in-scope findings: " + types +
      f". {len(unverified)} rest on unverified inference; {len(dbm)} need a DB migration." + (f" Sources: {E(a.sources)}." if a.sources else '') + "</p>")

    def table(items, cols):
        t = ["<table style='border-collapse:collapse;width:100%'><tr>"] + [f"<td style='{cell};background:#1f3a68;color:#fff'><b>{c}</b></td>" for c, _ in cols] + ['</tr>']
        for i, r in enumerate(items):
            z = '#f8fafc' if i % 2 else '#ffffff'
            t.append(f"<tr style='background:{z}'>")
            for c, k in cols:
                v = E(r[k])
                if k == 'severity':
                    fg, bg = COL.get(r[k], ('#111', '#fff'))
                    t.append(f"<td style='{cell};background:{bg};color:{fg}'><b>{v}</b></td>")
                elif k == 'code_location': t.append(f"<td style='{cell};font-family:Consolas,monospace;font-size:9pt'>{v}</td>")
                else:
                    t.append(f"<td style='{cell}'>{v}</td>")
            t.append('</tr>')
        return ''.join(t) + '</table>'

    if top:
        H.append(f"<h2 style='{h2}'>Critical and High</h2>" + table(top, [('ID', 'id'), ('Sev', 'severity'), ('Title', 'title'), ('Current', 'current'), ('Where', 'code_location'), ('Fix', 'suggested_fix')]))
    if decide:
        H.append(f"<h2 style='{h2}'>Needs a product decision</h2>" + table(decide, [('ID', 'id'), ('Title', 'title'), ('Expected', 'expected'), ('Business impact', 'business_impact')]))
    H.append(f"<h2 style='{h2}'>All in-scope findings</h2>" + table(ranked,
      [('ID', 'id'), ('Type', 'type'), ('Sev', 'severity'), ('Title', 'title'), ('Why not visible in prod', 'why_not_prod'), ('Effort', 'effort'), ('DB', 'db_migration')]))
    if outs:
        H.append(f"<h2 style='{h2}'>Out of scope (captured for product)</h2>" + table(outs, [('ID', 'id'), ('Type', 'type'), ('Title', 'title'), ('Expected', 'expected')]))
    H.append("<p style='font-size:8pt;color:#9ca3af;margin-top:18px'>Generated by a revy module audit. Unverified findings are marked and capped at Medium.</p></body></html>")
    open(base + '.html', 'w', encoding='utf-8').write(''.join(H))
    print(base + '.md'); print(base + '.html')


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    a = sys.argv[1:]
    cmd = a[0] if a else ''
    # --help never becomes an id; unknown flags and missing args are usage errors
    use = [ln for ln in __doc__.splitlines() if re.match(rf'\s+python devtools\.py {re.escape(cmd)}\b', ln)] if cmd else []
    ARITY = {'task': 1, 'subtasks': 1, 'newtask': 5, 'status': 2, 'comment': 2, 'finish': 3, 'mr': 3, 'merge': 2, 'merge-wait': 2,
      'doc': 2, 'evidence': 1, 'keepboth': 1, 'lbcheck': 1, 'findings': 1, 'migrations': 1, 'selftest': 0}
    FLAGS, opt = {'findings': {'--sources', '--out'}}, {}
    for f in ('--type', '--parent', '--folder') if cmd in ('doc', 'evidence') else ():
        if f in a[1:-1]:
            i = a.index(f, 1); opt[f] = a[i + 1]; del a[i:i + 2]
    REPORT_TYPE = (opt.get('--type') or REPORT_TYPE).lower()
    if cmd in ('-h', '--help', 'help') or (use and any(x in ('-h', '--help') for x in a[1:]) and cmd != 'migrations'):
        print('\n'.join(use) if use else __doc__)
        sys.exit(0)
    bad = [x for x in a[1:] if re.match(r'^--?[A-Za-z][\w-]*$', x) and x not in FLAGS.get(cmd, set())] if cmd != 'migrations' else []
    if cmd not in ARITY or bad or len(a) - 1 < ARITY[cmd]:
        print((f'devtools.py {cmd}: unknown option {bad[0]}' if bad else f'devtools.py {cmd}: missing arguments') if cmd in ARITY else __doc__, file=sys.stderr)
        print('\n'.join(use) if use else '', file=sys.stderr)
        sys.exit(2)
    if cmd == 'task':
        t = task(a[1])
        print(' | '.join([t.get('name') or '', t.get('status') or '', t.get('url') or task_url(a[1]), str(t.get('parent') or '')]))
    elif cmd == 'subtasks':
        for row in subtasks(a[1], a[2:] or None):
            print(' | '.join(row))
    elif cmd == 'newtask':
        print(new_task(a[1], a[2], a[3], a[4], _body(a[5])))
    elif cmd == 'status':
        print(set_status(a[1], a[2]))
    elif cmd == 'comment':
        print(comment(a[1], _text(a[2]), a[3] if len(a) > 3 else 'comment-status'))
    elif cmd == 'finish':
        finish(a[1], a[2], _body(a[3]), *(a[4:5] or []))
        print('done')
    elif cmd == 'mr':
        print(mr_create(a[1], a[2], _body(a[3]), *(a[4:5] or [])))
    elif cmd == 'merge':          # merge now / arm merge-when-green; waits <= 90 s
        res = auto_merge(a[1], a[2])
        print(res)
        sys.exit(0 if merge_word(res) in ('MERGED', 'SCHEDULED') else 1)   # 1 = refused, conflict or wait
    elif cmd == 'merge-wait':     # blocks up to 90 min
        res = merge_when_green(a[1], a[2])
        print(res)
        sys.exit(0 if merge_word(res) in ('MERGED', 'SCHEDULED') else 1)
    elif cmd == 'keepboth':
        sys.exit(keepboth(a[1:]))
    elif cmd == 'lbcheck':
        sys.exit(lbcheck(a[1:]))
    elif cmd == 'selftest':
        sys.exit(selftest())
    elif cmd == 'migrations':
        sys.exit(mig_selftest() if a[1:2] == ['selftest'] else (mig_main(a[1:]) or 0))
    elif cmd == 'findings':   # schema | validate <file> | summary <file>
        sub = a[1] if len(a) > 1 else ''
        if sub == 'schema':
            print(FINDINGS_SCHEMA)
        elif sub in ('validate', 'summary'):
            sys.exit((validate if sub == 'validate' else summary)(a[2:]) or 0)
        else:
            print(__doc__)
            sys.exit(2)
    elif cmd == 'doc':
        title, path = a[1], a[2]
        if os.path.isfile(title) and not os.path.isfile(path):   # swapped order: doc <file> "<title>"
            title, path = path, title
        print(make_doc(title, path, *(a[3:4] or [])))
    elif cmd == 'evidence':
        print(json.dumps(make_evidence(a[1], a[2:], opt.get('--folder') or None, opt.get('--parent') or None)))
    else:
        print(__doc__)
        sys.exit(2)
