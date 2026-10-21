"""devtools.py: tracker / git-host / docs helpers for agents (dev-kit steps 6-7). Host and project come from the worktree's
`origin` remote, the MR target from its dev.ps1 wt record. Tracker reads and status changes: dev.ps1 tracker.

 python devtools.py comment <taskId> <file.md | "text"> [kind]   kind: comment-status (default), comment-deploy, decision-request ...
 python devtools.py finish <taskId> <guideUrl|guide.md> <solution.md> [review]   guide link on top, one solution comment (+ guide link), status
 python devtools.py mr <worktree> "<title>" <body.md> [target]   open a merge/pull request from the current branch
 python devtools.py merge <worktree> <iid>   merge now (per repos[].mergeMethod; green / no CI) or arm merge-when-green; waits <= 90 s;
  last line (read back): MERGED / SCHEDULED / WAIT (also: producer unmerged) / CONFLICT / PIPELINE_FAILED / NOT_MERGED
 python devtools.py doc "<title>" <file.html|.md> [parent] [--type <t>]   publish a document (reports.type); prints its URL/path
 python devtools.py evidence "<name>" [--parent <id>] [--folder <id>] [--files-from <list>] <file> ...   host evidence files (gdocs: Drive) -> JSON
 python devtools.py keepboth <file> [...]   append-only rebase conflicts: keep OURS then THEIRS
 python devtools.py selftest   offline self-test (and each installed plugin's)
Plugins: skills/dev-kit/adapters/*.py (kittool.py extra add <name>) register report adapters and verbs (migrations: extra migration-classify;
 lbcheck: extra liquibase; findings: extra module-audit).
Exit codes: 0 ok · 1 problem (merge refused, conflict, check issues) · 2 usage error · 3 the feature is an extra that is not installed.
Sections: L73 run · L118 tracker · L193 git host · L300 MR · L485 merge · L563 docs · L680 plugins · L693 keepboth · L712 selftest · L853 CLI
Config (..\\kit.local.json): "tracker" (dev.ps1 tracker, default none), "reports" + "driveParent" (doc / evidence:
kit.example.json reports._readme), "gitHost" / "githubHost" (self-hosted; default gitlab.com / github.com).
Windows: run from PowerShell (python hangs in git-bash); Linux/macOS: python3. CLIs are resolved with shutil.which.
"""
import contextlib, glob, html, importlib.util, json, os, re, shutil, subprocess, sys, tempfile, time

KIT = os.path.dirname(os.path.abspath(__file__))  # dev-kit skill folder
KIT_DIR = os.path.dirname(os.path.dirname(KIT))   # the kit (.claude)
sys.path.insert(0, os.path.join(KIT_DIR, 'skills', 'orchestrate'))
from kittool import kit_path, locked   # one path map and lock for every kit script


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
ADAPTERS = {'report': {}}   # kind -> name -> {verb: fn(a)}
VERBS = {}                  # plugin CLI verbs: name -> fn(argv) -> exit code


def _todo(verb):
    raise SystemExit(f'adapter verb {verb} is a stub (kittool.py new adapter): implement it first')


def extra_missing(feature, name):
    """The one line an agent acts on: install the extra, retry."""
    print(f'{feature} is an extra: run kittool.py extra add {name}', file=sys.stderr)
    sys.exit(3)

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


# no stuck_or_timeout_failure: a hanging test produces it too, a retry would hide it
INFRA = ('ci_quota_exceeded', 'runner_system_failure', 'scheduler_failure', 'api_failure',
         'runner_unsupported', 'no_matching_runner')


def _failed(H, hp, iid):
    """PIPELINE_FAILED text; only infra failure_reasons on the failed jobs -> retry the same sha, not a code fix."""
    hp = hp if isinstance(hp, dict) else {}
    jobs = H('ci.jobs', id=str(hp['id'])) if hp.get('id') else []
    why = sorted({str(j.get('failure_reason') or '') for j in jobs if isinstance(j, dict) and j.get('status') == 'failed'}) if isinstance(jobs, list) else []
    if why and all(w in INFRA for w in why):
        return f'INFRA {", ".join(why)}: retry on the same sha; no code change\nPIPELINE_FAILED'
    return f'pipeline {hp.get("status")} on !{iid}: fix it, do not merge\nPIPELINE_FAILED'


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
        return _failed(H, m.get('head_pipeline'), iid)
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
        return _failed(H, m.get('head_pipeline'), iid)
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



# --- Documents: make_doc / make_evidence -> ADAPTERS['report'][reports.type]
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
        # images before links: ![alt](url "width px"), default 600 px
        t = re.sub(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;(\d+)&quot;|\s+"(\d+)")?\)',
                   lambda m: f'<p><img src="{m[2]}" width="{m[3] or m[4] or 600}"><br><i>{m[1]}</i></p>', t)
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
    ad = ADAPTERS['report'].get(REPORT_TYPE) or extra_missing(f'reports.type {REPORT_TYPE}', f'report-{REPORT_TYPE}')
    keep = parent if parent and os.path.isdir(parent) else None
    return ad['publish']({'title': title, 'path': path, 'parent': None if keep else parent, 'keep': keep})


def make_evidence(name, files, folder=None, parent=None):
    """Host evidence files -> {folderId, folderLink, label, files}; {} = they stay in the run folder."""
    ad = ADAPTERS['report'].get(REPORT_TYPE)
    if ad is None:   # evidence stays in the run folder; say why once
        print(f'reports.type {REPORT_TYPE} is an extra: run kittool.py extra add report-{REPORT_TYPE}', file=sys.stderr)
    fn = (ad or {}).get('evidence')
    return fn({'name': name, 'files': files, 'folder': folder, 'parent': parent}) if fn else {}


R = ADAPTERS.setdefault('report', {})   # gdocs (Google Doc + Drive evidence): extra report-gdocs
# adapter:report/markdown: the file, kept
R['markdown'] = {'publish': lambda a: keep_doc(a['title'], a['path'], a['keep'])}
# adapter:report/html: Markdown -> HTML (md_to_html), kept
R['html'] = {'publish': lambda a: keep_doc(a['title'], _html_of(a), a['keep'])}


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


def load_plugins(folder=os.path.join(KIT, 'adapters')):
    """Each skills/dev-kit/adapters/*.py (an installed extra) gets this module in register(dt) and adds adapters or verbs."""
    this = sys.modules[__name__]
    for path in sorted(glob.glob(os.path.join(folder, '*.py'))):
        spec = importlib.util.spec_from_file_location('kit_plugin_' + os.path.splitext(os.path.basename(path))[0], path)
        plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(plugin)
        plugin.register(this)


load_plugins()


# --- keepboth (rebase), self-test
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
    page = md_to_html('![shot 1](https://x/a.png "260") [link](https://y)\n![b](c.png)')
    expect('md_to_html: images with width (default 600) and captions, links stay links', '<img src="https://x/a.png" width="260"><br><i>shot 1</i>' in page
           and '<img src="c.png" width="600">' in page and '<a href="https://y">link</a>' in page)

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
    sleep0, time.sleep = time.sleep, lambda s: None   # fake clock: re-read waits cost nothing
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
        calls.clear(); g['_host'] = lambda v, **a: [{'status': 'failed', 'failure_reason': 'ci_quota_exceeded'}] if v == 'ci.jobs' else fake(hp={'status': 'failed', 'id': 9})(v, **a)
        r = auto_merge('.', '7')
        expect('infra-only job failures: INFRA retry, no merge', r.startswith('INFRA ci_quota_exceeded') and merge_word(r) == 'PIPELINE_FAILED' and not merged())
        calls.clear(); g['_host'] = lambda v, **a: [{'status': 'failed', 'failure_reason': 'script_failure'}] if v == 'ci.jobs' else fake(hp={'status': 'failed', 'id': 9})(v, **a)
        expect('a script failure: fix it', 'fix it' in auto_merge('.', '7'))
        calls.clear(); g['_host'] = lambda v, **a: [{'status': 'failed', 'failure_reason': 'stuck_or_timeout_failure'}] if v == 'ci.jobs' else fake(hp={'status': 'failed', 'id': 9})(v, **a)
        r = auto_merge('.', '7')
        expect('a timeout: fix it, not INFRA', 'INFRA' not in r and 'fix it' in r)
        calls.clear(); g['_host'] = fake(hp={'status': 'running'}, put={'auto_merge': 'kit'})
        expect('kit-emulated merge-when-green: SCHEDULED', merge_word(auto_merge('.', '7')) == 'SCHEDULED')
    finally:
        g.update(saved); time.sleep = sleep0
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
    sent, run0 = [], g['_run']
    g['_run'] = lambda argv, **k: sent.append(argv[-1]) or sent.append(open(argv[-1], encoding='utf-8').read()) or ''
    try:
        _tracker('comment', '1', 'x' * 300)
    finally:
        g['_run'] = run0
    expect('a 300-char tracker text goes via a temp file, then is removed', sent[1:] == ['x' * 300] and not os.path.exists(sent[0]))
    cfg0 = dict(CFG); CFG.clear(); CFG['gitHostType'] = 'github'
    expect('gitHostType, no gitHost: any origin', host_kind('git.corp.example') == 'github'); CFG.update(cfg0)
    _report_selftest(expect)
    print(f'{fails} failure(s)')
    return 1 if fails else 0


def _report_selftest(expect):
    """Each core report adapter, then each installed plugin's selftest(expect, tmp, md) (no network)."""
    import contextlib as _c, io
    g, tmp = globals(), tempfile.mkdtemp()
    saved = {k: g[k] for k in ('REPORT_TYPE', 'kit_path', 'RCFG')}
    md, png = os.path.join(tmp, 'r.md'), os.path.join(tmp, 's.png')
    with open(md, 'w', encoding='utf-8') as fh:
        fh.write('# T\n\n---\n' + ''.join(f'- b{i}\n' for i in range(151)) + '```\nx\n```\n')
    open(png, 'wb').close()

    def use(report_type, rcfg):
        g.update(REPORT_TYPE=report_type, RCFG=rcfg)
    try:
        g['kit_path'] = lambda n, create=False: tmp
        use('markdown', {})
        expect('markdown: kept in place, else in docs; no evidence host', make_doc('T', md, tmp) == md and make_doc('My T', md) == os.path.join(tmp, 'My-T.md') and not make_evidence('e', [png]))
        use('html', {})
        expect('html: Markdown -> HTML, kept', '<h1>T</h1>' in open(make_doc('T', md, tmp), encoding='utf-8').read())
        use('command', {'command': _q(sys.executable) + ' -c "import sys; print(\'https://w.ex/\' + sys.argv[1])" {title}'})
        expect('command: {title} filled, the last output = the URL', make_doc('T1', md) == 'https://w.ex/T1')
        use('no-such-type', {}); err = io.StringIO()
        try:
            with _c.redirect_stderr(err):
                make_doc('T', md)
        except SystemExit as e:
            expect('a report type that is not installed: exit 3 + the extra add line', e.code == 3 and 'kittool.py extra add report-no-such-type' in err.getvalue())
        for name, adapter in ADAPTERS['report'].items():
            if adapter.get('selftest'):
                use(name, {}); adapter['selftest'](expect, tmp, md)
    finally:
        g.update(saved); shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    a = sys.argv[1:]
    cmd = a[0] if a else ''
    if cmd in VERBS:   # a plugin verb parses its own arguments
        sys.exit(VERBS[cmd](a[1:]) or 0)
    if cmd == 'migrations':
        extra_missing('devtools.py migrations (migration classes)', 'migration-classify')
    if cmd == 'lbcheck':
        extra_missing('devtools.py lbcheck (Liquibase check)', 'liquibase')
    if cmd == 'findings':
        extra_missing('devtools.py findings (module audits)', 'module-audit')
    # --help never becomes an id; unknown flags and missing args are usage errors
    use = [ln for ln in __doc__.splitlines() if re.match(rf'\s+python devtools\.py {re.escape(cmd)}\b', ln)] if cmd else []
    ARITY = {'comment': 2, 'finish': 3, 'mr': 3, 'merge': 2, 'doc': 2, 'evidence': 1, 'keepboth': 1, 'selftest': 0}
    FLAGS, opt = {}, {}
    for f in ('--type', '--parent', '--folder', '--files-from') if cmd in ('doc', 'evidence') else ():
        if f in a[1:-1]:
            i = a.index(f, 1); opt[f] = a[i + 1]; del a[i:i + 2]
    REPORT_TYPE = (opt.get('--type') or REPORT_TYPE).lower()
    if cmd in ('-h', '--help', 'help') or (use and any(x in ('-h', '--help') for x in a[1:])):
        print('\n'.join(use) if use else __doc__)
        sys.exit(0)
    bad = [x for x in a[1:] if re.match(r'^--?[A-Za-z][\w-]*$', x) and x not in FLAGS.get(cmd, set())]
    if cmd not in ARITY or bad or len(a) - 1 < ARITY[cmd]:
        print((f'devtools.py {cmd}: unknown option {bad[0]}' if bad else f'devtools.py {cmd}: missing arguments') if cmd in ARITY else __doc__, file=sys.stderr)
        print('\n'.join(use) if use else '', file=sys.stderr)
        sys.exit(2)
    if cmd == 'comment':
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
    elif cmd == 'keepboth':
        sys.exit(keepboth(a[1:]))
    elif cmd == 'selftest':
        sys.exit(selftest())
    elif cmd == 'doc':
        title, path = a[1], a[2]
        if os.path.isfile(title) and not os.path.isfile(path):   # swapped order: doc <file> "<title>"
            title, path = path, title
        print(make_doc(title, path, *(a[3:4] or [])))
    elif cmd == 'evidence':
        ff = open(opt['--files-from'], encoding='utf-8-sig').read().splitlines() if opt.get('--files-from') else []   # one path per line: no command-line limit
        print(json.dumps(make_evidence(a[1], a[2:] + [x for x in ff if x.strip()], opt.get('--folder') or None, opt.get('--parent') or None)))
