"""devtools.py: tracker / git-host / docs helpers for agents (dev-kit steps 6-7). Works for any repo: the host (GitLab or GitHub) and project path
come from the worktree's `origin` remote, the MR target from the worktree's recorded target (dev.ps1 wt new).

  python devtools.py task <taskId>                                  summary: name | status | url | parent
  python devtools.py subtasks <parentId> [status ...]               id | status | name
  python devtools.py newtask <listId|-> <parentId|-> <assignee|-> "<name>" <desc.md>
  python devtools.py status <taskId> "<status>"                     logical (review, promoted, inTest, closed) or the tracker's own name
  python devtools.py comment <taskId> <file.md | "text">
  python devtools.py finish <taskId> <guideUrl|guide.md> <solution.md> [review]   guide link on top + one solution comment (guide link appended if missing) + status
  python devtools.py mr <worktree> "<title>" <body.md> [target]     open a merge/pull request from the current branch
  python devtools.py merge <worktree> <iid>                         squash-merge now (green, or no CI) or schedule merge-when-green;
                                                                    waits <= 90 s; last line: MERGED / SCHEDULED / WAIT / CONFLICT /
                                                                    PIPELINE_FAILED / NOT_MERGED (read back from the host). A consumer
                                                                    whose producer (.state/tracking.json mergeAfter) is unmerged: WAIT
  python devtools.py doc "<title>" <file.html|.md> [driveFolderId]  publish a document (human testing doc, report); prints its URL/path
                                                                    (.md is converted to HTML for gdocs: tables, lists, code survive)
  python devtools.py keepboth <file> [...]                          append-only rebase conflicts: keep OURS then THEIRS
  python devtools.py lbcheck <master.xml> [since]                   Liquibase sanity check (run by dev.ps1 check -Step migrations)
  python devtools.py selftest                                       offline self-test
Exit codes: 0 ok · 1 problem (merge refused, conflict, check issues) · 2 usage error.

Defaults can be set in ..\\kit.local.json (next to this skill's SKILL.md; copy kit.example.json):
  "tracker": { "type": "clickup|github|gitlab|jira|none", ... }   task commands go through dev.ps1 tracker (default none)
  "reports": { "type": "gdocs|markdown" }  `doc`: gdocs = Google Doc via gws (default when gws is installed);
                                           markdown = the file is kept under <runtime>/work/docs and its path printed
  "driveParent": "<Drive folder id>"   default parent folder for `doc` (gdocs)
  "gitHost": "gitlab.example.com"      self-hosted GitLab (default gitlab.com); "githubHost" likewise (default github.com)
Windows: run from PowerShell (python hangs in git-bash); Linux/macOS: python3. CLIs (pwsh, glab, gh, gws) are resolved with
shutil.which, so the same names work on every OS.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

KIT = os.path.dirname(os.path.abspath(__file__))  # the dev-kit skill folder
KIT_DIR = os.path.dirname(os.path.dirname(KIT))   # the kit (.claude folder)
try:
    CFG = json.load(open(os.path.join(KIT, 'kit.local.json'), encoding='utf-8'))
except Exception:
    CFG = {}
GLAB, GH, GWS = (shutil.which(x) for x in ('glab', 'gh', 'gws'))
REPORT_TYPE = (os.environ.get('KIT_REPORT_TYPE') or (CFG.get('reports') or {}).get('type') or ('gdocs' if GWS else 'markdown')).lower()
import contextlib
with open(os.path.join(KIT, 'paths.json'), encoding='utf-8') as _f:
    MAP = json.load(_f)   # the kit's one path map (paths.json)


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


def _run(cmd, cwd=None, check=False):
    if not cmd[0]:
        raise SystemExit(f'CLI not found on PATH for: {cmd[1:3]}')
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding='utf-8')
    out = ((p.stdout or '') + (p.stderr or '')).strip()
    if check and p.returncode:   # a failed write (status, comment, create) must not print 'done' and exit 0
        raise SystemExit(f'failed (exit {p.returncode}): {" ".join(str(c) for c in cmd[-4:])[:120]}\n{out[-600:]}')
    return out


def _json(out):
    """CLIs may print notices around the JSON; decode the first JSON value."""
    starts = [i for i in (out.find('{'), out.find('[')) if i >= 0]
    try:
        return json.JSONDecoder().raw_decode(out[min(starts):])[0] if starts else json.loads(out)
    except Exception:
        return {'raw': out}


def _text(arg):
    return open(arg, encoding='utf-8').read() if os.path.isfile(arg) else arg


def _body(arg):
    """A body that must come from a file (mr, finish, newtask): a missing file is an error, never the file name as the body
    (an MR once opened with the literal 'body.md' as its description). Multi-line text passes as it is."""
    if os.path.isfile(arg) or '\n' in arg:
        return _text(arg)
    raise SystemExit(f'file not found: {arg} - write it first (nothing was created)')


# ---------- Tracker (dev.ps1 tracker: clickup | github | gitlab | jira | none, from kit.local.json "tracker") ----------
DEV = os.path.join(KIT, 'dev.ps1')   # dev.ps1 tracker <verb> ...: the tracker adapter
PWSH = shutil.which('pwsh') or shutil.which('powershell')
TRACKER_TYPE = (os.environ.get('KIT_TRACKER_TYPE') or (CFG.get('tracker') or {}).get('type') or 'none').lower()


def _tracker(*args):
    """Run dev.ps1 tracker <verb> ...; long texts go through a temp file (dev.ps1 tracker reads a file path as its content)."""
    tmp = []
    try:
        argv = []
        for x in args:
            x = str(x)
            if (len(x) > 200 or '\n' in x) and (not argv or argv[-1] != '-Name'):   # free text only; a name stays an argument
                fd, p = tempfile.mkstemp(suffix='.md')
                with os.fdopen(fd, 'w', encoding='utf-8', newline='') as fh:
                    fh.write(x)
                tmp.append(p)
                x = p
            argv.append(x)
        # reads ('view', 'url', ...) stay lenient (finish() handles a failed lookup); writes fail loudly
        return _run([PWSH, '-NoProfile', '-NonInteractive', '-File', DEV, 'tracker', *argv],
                    check=bool(argv) and argv[0] in ('status', 'comment', 'describe', 'create', 'rename', 'attach'))
    finally:
        for p in tmp:
            try:
                os.remove(p)
            except OSError:
                pass


def task(tid):
    """{ id, name, status, url, parent, assignees[], subtasks[{id,name,status,url}], list, description }"""
    return _json(_tracker('view', tid))


def task_url(tid):
    return _tracker('url', tid).strip()


def subtasks(parent, statuses=None):
    want = {s.lower() for s in statuses} if statuses else None
    out = []
    for s in task(parent).get('subtasks') or []:
        st = s.get('status') or ''
        if not want or st.lower() in want:
            out.append((str(s['id']), st, s.get('name') or ''))
    return out


def new_task(list_id, parent, assignee, name, desc_md, priority='2'):
    args = ['create', '-Name', name, '-Description', desc_md, '-Priority', priority]
    if list_id and list_id != '-':
        args += ['-List', list_id]
    if parent and parent != '-':
        args += ['-Parent', parent]
    if assignee and assignee != '-':
        args += ['-Assignee', assignee]
    return _json(_tracker(*args)).get('id')


def set_status(tid, status):
    """status: a logical name (review, promoted, inTest, closed, ... mapped by tracker.statuses) or the tracker's own name."""
    return _tracker('status', tid, status)


def comment(tid, text):
    return _tracker('comment', tid, text)


def finish(tid, guide_url, solution_md, status='review'):
    if os.path.isfile(guide_url):   # a guide file: publish it first, the task gets the link (never a local path)
        guide_url = make_doc(os.path.splitext(os.path.basename(guide_url))[0], guide_url)
    t = task(tid)
    md = t.get('description') or ''
    # a failed lookup has no id/name: describing would overwrite the real description with just the guide line
    if t.get('id') and t.get('name') and guide_url not in md:
        _tracker('describe', tid, f'Testing guide: {guide_url}\n\n{md}')
    # one comment: the solution, plus the guide link only when the solution doesn't carry it already
    if guide_url not in solution_md:
        solution_md = f'{solution_md.rstrip()}\n\nHow to test: follow the tester guide {guide_url}.'
    comment(tid, solution_md)
    set_status(tid, status)


# ---------- Git host (GitLab or GitHub, from the origin remote) ----------
GITLAB_HOST = CFG.get('gitHost') or 'gitlab.com'
GITHUB_HOST = CFG.get('githubHost') or 'github.com'
if CFG.get('gitHost') and not os.environ.get('GITLAB_HOST'):   # glab api outside a checkout would otherwise talk to gitlab.com
    os.environ['GITLAB_HOST'] = CFG['gitHost']


def remote(worktree):
    url = _run(['git', '-C', worktree, 'remote', 'get-url', 'origin']).strip()
    for kind, host in (('gitlab', GITLAB_HOST), ('github', GITHUB_HOST), ('gitlab', 'gitlab.com'), ('github', 'github.com')):
        m = re.search(re.escape(host) + r'(?::\d+)?[:/](.+?)(?:\.git)?$', url)
        if m:
            return kind, m.group(1)
    raise SystemExit(f'unsupported remote: {url} (set "gitHost" / "githubHost" in kit.local.json for a self-hosted server)')


def target_of(worktree):
    """The MR target: the worktree's record (dev.ps1 wt new), else kit.local.json repos[].target of this repo, else origin/HEAD.
    A fallback is printed (stderr) with where it came from; None only when all three are missing."""
    gd = _run(['git', '-C', worktree, 'rev-parse', '--git-dir'])
    gd = gd if os.path.isabs(gd) else os.path.join(worktree, gd)
    f = os.path.join(gd, 'claude-target')
    if os.path.exists(f):
        with open(f, encoding='utf-8-sig') as fh:
            return fh.read().strip() or None
    # 1. kit.local.json repos[]: the entry whose checkout is this worktree's main checkout, or whose name/alias is the remote's repo name
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
    # 2. the remote's default branch
    head = _run(['git', '-C', worktree, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD'])
    if head.startswith('origin/') and '\n' not in head:
        print(f'[mr] target {head[7:]} (no dev.ps1 wt record, no kit.local.json repos[].target; origin/HEAD)', file=sys.stderr)
        return head[7:]
    return None


MR_SECTIONS = ('## Task', '## What changed', '## Verified', '## How to test')  # dev-kit/MR_BODY.md
FOOTER = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'


def _verified_gaps(body_md):
    """'## Verified' should say what was not run and how pure logic was proven (templates.md "MR body"): True when it has neither line."""
    m = re.search(r'^## Verified[^\n]*\n(.*?)(?=^## |\Z)', body_md, re.M | re.S)
    sec = m.group(1) if m else ''
    return bool(m) and not re.search(r'(?im)^\s*[-*]?\s*(\*\*)?(not run|pure logic)(\*\*)?\s*:', sec)


UI_FILES = re.compile(r'\.(html?|s?css|less|sass|tsx|jsx|vue|svelte)$|(^|/)res/layout[^/]*/[^/]+\.xml$', re.I)


def _ui_line_missing(worktree, tgt, body_md):
    """templates.md "MR body" '## Verified' carries '- UI: <spec / screenshot> (or "not a UI change")': the changed UI files when the body has no
    UI: line and the diff against origin/<target> touches templates or styles, else []."""
    if re.search(r'(?im)^\s*[-*]?\s*(\*\*)?UI(\*\*)?\s*:', body_md) or not tgt:
        return []
    out = _run(['git', '-C', worktree, 'diff', '--name-only', f'origin/{tgt}...HEAD'])
    return [f for f in out.splitlines() if UI_FILES.search(f.strip())]


def mr_create(worktree, title, body_md, tgt=None):
    missing = [h for h in MR_SECTIONS if h not in body_md]
    if missing:
        print(f'[mr] body is missing {missing} - see .claude/skills/dev-kit/MR_BODY.md', file=sys.stderr)
    if _verified_gaps(body_md):
        print('[mr] "## Verified" has neither a "Not run: <gate and why>" nor a "Pure logic: <spec file or node output>" line'
              ' - say what was not run (or "Not run: nothing") - see templates.md "MR body"', file=sys.stderr)
    link = {'clickup': 'clickup.com', 'github': '/issues/', 'gitlab': '/issues/', 'jira': '/browse/'}.get(TRACKER_TYPE)
    if link and link not in body_md:
        print(f'[mr] body has no tracker ({TRACKER_TYPE}) task link', file=sys.stderr)
    if FOOTER not in body_md:
        body_md = body_md.rstrip() + '\n\n' + FOOTER + '\n'
    host, _ = remote(worktree)
    src = _run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'])
    tgt = tgt or target_of(worktree)
    if not tgt:
        raise SystemExit('no target: no dev.ps1 wt record, no kit.local.json repos[].target for this repo and no origin/HEAD'
                         ' - pass it as the 4th argument (git remote set-head origin --auto fixes origin/HEAD)')
    ui = _ui_line_missing(worktree, tgt, body_md)
    if ui:
        print(f'[mr] the diff touches templates/styles ({", ".join(ui[:3])}{" ..." if len(ui) > 3 else ""}) but "## Verified" has no'
              ' "UI: <committed spec or screenshot link>" line (or "UI: not a UI change") - see templates.md "MR body"', file=sys.stderr)
    if host == 'gitlab':
        out = _run([GLAB, 'mr', 'create', '--source-branch', src, '--target-branch', tgt, '--title', title,
                    '--description', body_md, '--remove-source-branch', '--squash-before-merge', '--yes'], cwd=worktree)
        m = re.findall(r'https://[^\s/]+/\S+/merge_requests/\d+', out)
        if not m and 'already exists' in out.lower():   # a retry after a timed-out first call: report the MR that call opened
            _, proj = remote(worktree)
            ex = _json(_run([GLAB, 'api', f"projects/{proj.replace('/', '%2F')}/merge_requests?state=opened&source_branch={src}"]))
            m = [x['web_url'] for x in ex if isinstance(x, dict) and x.get('web_url')] if isinstance(ex, list) else []
            if m:
                print(f'[mr] an open MR from {src} already exists (a previous call opened it): {m[-1]} - update its description if needed', file=sys.stderr)
    else:
        out = _run([GH, 'pr', 'create', '--head', src, '--base', tgt, '--title', title, '--body', body_md], cwd=worktree)
        m = re.findall(r'https://[^\s/]+/\S+/pull/\d+', out)
    if not m:
        raise SystemExit(f'MR not created: {out[:500]}')
    return m[-1]


def _remember_automerge(ref):
    """GitLab drops 'merge when pipeline succeeds' when new commits are pushed (e.g. a rebase after scheduling).
    Record the intent in the durable tracking file (<kit>/tracking.local.json, "automerge"); orch.ps1 track run (every supervise
    round) re-arms it until the MR merges."""
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
    except Exception:
        pass


MERGE_WORDS = ('MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED')


def merge_word(res):
    """The status word on the last line of auto_merge's result (NOT_MERGED when there is none)."""
    last = (str(res or '').strip().splitlines() or [''])[-1].strip()
    return last if last in MERGE_WORDS else 'NOT_MERGED'


def _progress(msg):
    print(f'[merge] {msg}', flush=True)   # flushed at once: a caller watching the output sees it is alive


def _gitlab_no_ci_config(enc, m):
    """True when the project shows it has no CI: it does not require a pipeline to merge, has no custom CI config path,
    no Auto DevOps and no .gitlab-ci.yml on the MR's target branch. (A 404 is required: any other error counts as 'has CI'.)"""
    p = _json(_run([GLAB, 'api', f'projects/{enc}']))
    if not p.get('id') or p.get('only_allow_merge_if_pipeline_succeeds') or p.get('ci_config_path') or p.get('auto_devops_enabled'):
        return False
    tgt = (m.get('target_branch') or '').replace('/', '%2F')
    if not tgt:
        return False
    f = _run([GLAB, 'api', f'projects/{enc}/repository/files/.gitlab-ci.yml?ref={tgt}'])
    return '404' in f and 'file_name' not in f


def _gitlab_final(enc, proj, iid, put, st):
    """Re-read the MR after the merge PUT (a merge can take a moment) and turn its state into the result text + status word."""
    m = {}
    for i in range(4):
        m = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}']))
        if m.get('state') == 'merged' or m.get('merge_when_pipeline_succeeds') or i == 3:
            break
        _progress(f're-reading !{iid} ({m.get("detailed_merge_status") or m.get("merge_status") or m.get("state")})')
        time.sleep(3)
    if m.get('state') == 'merged':
        return f'merged !{iid}\nMERGED'
    if m.get('merge_when_pipeline_succeeds') or put.get('merge_when_pipeline_succeeds'):
        _remember_automerge(f'{proj}!{iid}')
        return f'scheduled: GitLab merges !{iid} automatically when the pipeline ({st}) succeeds\nSCHEDULED'
    if m.get('has_conflicts') or m.get('detailed_merge_status') == 'conflict':
        return f'conflict on !{iid}: dev.ps1 wt sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again\nCONFLICT'
    if (m.get('head_pipeline') or {}).get('status') in ('failed', 'canceled'):
        return f'pipeline {m["head_pipeline"]["status"]} on !{iid}: fix it, do not merge\nPIPELINE_FAILED'
    return f'not merged: !{iid} is {m.get("state")} ({m.get("detailed_merge_status") or m.get("merge_status")}); merge reply: {str(put)[:300]}\nNOT_MERGED'


def _norm_ref(ref):
    """'web!12', a quoted ref, an MR/PR URL or an alias (kit.local.json repoAliases) -> (repo, iid) as orch.ps1 track stores them."""
    r = str(ref or '').strip().strip('\'"')
    group = CFG.get('gitlabGroup') or ''
    m = re.search(r'://[^/]+/(?P<p>[\w./-]+?)/(?:-/merge_requests|pull)/(?P<i>\d+)', r)
    if m:
        p = m.group('p')
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
    """Does a tracking ref's repo ('web', 'group/web') name the project path from the origin remote ('group/sub/web')?"""
    a, b = repo.lower().strip('/'), proj.lower().strip('/')
    return a == b or b.endswith('/' + a)


def _host_mr_state(host, proj, repo, iid):
    """'merged' / 'opened' / 'closed' / '' (unknown) of <repo>!<iid>, resolved like orch.ps1 track (gitlabGroup, else the remote's group)."""
    if '/' in repo:
        path = repo
    else:
        group = CFG.get('gitlabGroup') if host == 'gitlab' else ''
        path = f"{group or proj.rsplit('/', 1)[0]}/{repo}"
    if host == 'gitlab':
        return str(_json(_run([GLAB, 'api', f"projects/{path.replace('/', '%2F')}/merge_requests/{iid}"])).get('state') or '')
    s = str(_json(_run([GH, 'pr', 'view', str(iid), '--repo', path, '--json', 'state'])).get('state') or '')
    return {'MERGED': 'merged', 'OPEN': 'opened', 'CLOSED': 'closed'}.get(s, '')


def unmerged_producers(proj, iid, state_of, tracking=None):
    """Producer-before-consumer: the mergeAfter pairs ('<consumer>!<iid>><producer>!<iid>', written by orch.ps1 track add -MergeAfter)
    in the durable tracking file whose consumer is this MR (<proj>!<iid>) and whose producer is not merged yet.
    state_of(repo, iid) -> 'merged' / 'opened' / 'closed' / ''. Returns [(producer ref, state, task id)]."""
    path = tracking or kit_path('tracking')
    try:
        data = json.load(open(path, encoding='utf-8-sig')) if os.path.exists(path) else {}
    except Exception:
        return []
    out = []
    for tid, t in ((data or {}).get('tasks') or {}).items():
        if not isinstance(t, dict):
            continue
        for pair in t.get('mergeAfter') or []:
            dep, sep, on = str(pair).partition('>')
            d, o = _norm_ref(dep), _norm_ref(on)
            if not sep or not d or not o or str(d[1]) != str(iid):
                continue
            if not _same_repo(d[0], proj):   # same iid, repo name not matched: a missing alias silently skips the merge order
                print(f'[merge] mergeAfter {pair} (task {tid}) names repo {d[0]}, this remote is {proj}: not applied'
                      ' - add kit.local.json repoAliases if they are the same repo', file=sys.stderr)
                continue
            st = state_of(o[0], o[1])
            if st != 'merged':
                out.append((f'{o[0]}!{o[1]}', st or 'unknown', tid))
    return out


def auto_merge(worktree, iid, max_wait=90):
    """Ask the host to merge as soon as the pipeline is green (GitLab 'merge when pipeline succeeds', GitHub auto-merge), or merge
    at once when it is green already or the project has no CI. Waits at most max_wait seconds (with flushed progress lines), so it
    finishes inside an agent's tool timeout. The result's LAST line is exactly one status word (merge_word):
    MERGED / SCHEDULED / WAIT (run again in a few minutes) / CONFLICT / PIPELINE_FAILED / NOT_MERGED, read back from the host.
    A consumer MR whose registered producer (orch.ps1 track -MergeAfter) is not merged yet is not merged: WAIT ("waiting for producer")."""
    iid = str(iid).strip().rsplit('!', 1)[-1].lstrip('#')   # '!203' / 'web!203' / '#12' -> the number
    host, proj = remote(worktree)
    waiting = unmerged_producers(proj, iid, lambda r, i: _host_mr_state(host, proj, r, i))
    if waiting:
        lines =[f'waiting for producer {ref} ({st}; task {tid}): {proj}!{iid} merges only after it' for ref, st, tid in waiting]
        if any(st == 'closed' for _, st, _ in waiting):
            return '\n'.join(lines) + '\nproducer MR closed: fix the merge order (orch.ps1 track mergeAfter) with the coordinator\nNOT_MERGED'
        return '\n'.join(lines) + '\nnot merged now: orch.ps1 track run (supervise) merges it once the producer merged\nWAIT'
    if host == 'gitlab':
        enc = proj.replace('/', '%2F')
        m = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}']))
        if m.get('state') == 'merged':
            return f'already merged !{iid}\nMERGED'
        if m.get('state') and m.get('state') != 'opened':
            return f'!{iid} is {m.get("state")}, not open\nNOT_MERGED'
        if m.get('has_conflicts'):
            return 'CONFLICT: dev.ps1 wt sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again\nCONFLICT'
        st = (m.get('head_pipeline') or {}).get('status')
        if st in ('failed', 'canceled'):
            return f'PIPELINE {st}: fix it, do not merge\nPIPELINE_FAILED'
        args = ['-f', 'squash=true', '-f', 'should_remove_source_branch=true']
        # A repo without MR CI never gets a pipeline: merge_when_pipeline_succeeds would then wait forever (two reviewed MRs once
        # stayed open while the poller slept and died with its agent). Decide from the project first: no pipeline required and no
        # CI config at all -> merge now. Otherwise (a CI file whose rules may skip MRs): no pipeline for the MR head and none on the
        # source ref for > 5 min since the MR was last updated -> no CI for this MR. A head-commit date is no proof (an old commit
        # pushed just now has no pipeline YET); with no head pipeline GitLab would merge a merge_when_pipeline_succeeds at once, so
        # an MR whose pipeline is still expected gets WAIT, never a merge.
        no_ci = False
        if st is None:
            if _gitlab_no_ci_config(enc, m):
                no_ci = True
                _progress(f'project has no CI (no pipeline required, no CI config on {m.get("target_branch")}): merging !{iid} now')
            else:
                from datetime import datetime, timezone
                src_proj = m.get('source_project_id') or enc
                ref = (m.get('source_branch') or '').replace('/', '%2F')
                sha = m.get('sha') or ''

                # pipelines of the MR's HEAD commit only: an older commit's pipeline (before a rebase / force-push, or the branch's
                # previous push) once made merge arm merge-when-green with no head pipeline (GitLab may then merge without CI), or
                # return WAIT at once instead of waiting for the new pipeline to appear
                def _no_ci():
                    pls = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}/pipelines']))
                    pls = [p for p in pls if isinstance(p, dict) and (not sha or p.get('sha') == sha)] if isinstance(pls, list) else []
                    refp = _json(_run([GLAB, 'api', f'projects/{src_proj}/pipelines?ref={ref}&sha={sha}&per_page=1'])) if ref else {}
                    refp = [p for p in refp if isinstance(p, dict) and (not sha or p.get('sha') == sha)] if isinstance(refp, list) else None
                    head = pls or refp or []
                    return (not head and refp is not None), bool(head)

                when = m.get('updated_at') or m.get('created_at') or ''
                age = (datetime.now(timezone.utc) - datetime.fromisoformat(when.replace('Z', '+00:00'))).total_seconds() if when else 0
                none_yet, has = _no_ci()
                waited = 0
                # short check only: poll every 15 s with a progress line, never past max_wait (a tool timeout kills a silent sleep)
                while none_yet and age + waited <= 300 and waited + 15 <= max_wait:
                    _progress(f'no pipeline on !{iid} yet; checking again in 15 s ({int(300 - age - waited)} s until it counts as no CI)')
                    time.sleep(15)
                    waited += 15
                    none_yet, has = _no_ci()
                if has:
                    st = 'running'
                no_ci = none_yet and age + waited > 300
                if not has and not no_ci:
                    left = int(max(30, 310 - age - waited)) if none_yet else 60
                    return f'WAIT: no pipeline on !{iid} yet (a pipeline is still expected); run merge again in {left} s\nWAIT'
        if st == 'manual' or st == 'skipped':   # merge-when-green would never fire: say so instead of SCHEDULED
            return f'pipeline {st} on !{iid}: start its manual jobs (or ask the coordinator), then run merge again\nNOT_MERGED'
        if st == 'scheduled':
            return f'pipeline scheduled (delayed job) on !{iid}: run merge again once it runs\nWAIT'
        if st != 'success' and not no_ci:
            args += ['-f', 'merge_when_pipeline_succeeds=true']
        put = _json(_run([GLAB, 'api', '-X', 'PUT', f'projects/{enc}/merge_requests/{iid}/merge', *args]))
        return _gitlab_final(enc, proj, iid, put, st)
    out = _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch', '--auto'], cwd=worktree)
    if 'clean status' in out.lower():   # nothing to wait for (no required checks): auto-merge is refused, merge directly
        out = _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch'], cwd=worktree)
    v = _json(_run([GH, 'pr', 'view', str(iid), '--json', 'state,mergeable,autoMergeRequest,statusCheckRollup'], cwd=worktree))
    concl = [r.get('conclusion') or r.get('state') for r in v.get('statusCheckRollup') or []]
    word = ('MERGED' if v.get('state') == 'MERGED' else 'SCHEDULED' if v.get('autoMergeRequest') else
            'CONFLICT' if v.get('mergeable') == 'CONFLICTING' else
            'PIPELINE_FAILED' if any(c in ('FAILURE', 'CANCELLED', 'ERROR', 'TIMED_OUT') for c in concl) else 'NOT_MERGED')
    return f'{out[:300] or f"#{iid}: {word.lower()}"}\n{word}'


def merge_when_green(worktree, iid, timeout_min=90):
    """Poll the pipeline; squash-merge when green. Never merges on failure or conflict. Prefer auto_merge (no waiting)."""
    host, proj = remote(worktree)
    waiting = unmerged_producers(proj, iid, lambda r, i: _host_mr_state(host, proj, r, i))
    if waiting:
        return '; '.join(f'waiting for producer {ref} ({st}; task {tid})' for ref, st, tid in waiting) + ': not merged'
    end = time.time() + timeout_min * 60
    while time.time() < end:
        if host == 'gitlab':
            enc = proj.replace('/', '%2F')
            m = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}']))
            state, conflict = m.get('state'), m.get('has_conflicts')
            st = (m.get('head_pipeline') or {}).get('status')
            ok, bad = st == 'success', st in ('failed', 'canceled')
        else:
            m = _json(_run([GH, 'pr', 'view', str(iid), '--json', 'state,mergeable,statusCheckRollup'], cwd=worktree))
            state = {'MERGED': 'merged'}.get(m.get('state'), m.get('state'))
            conflict = m.get('mergeable') == 'CONFLICTING'
            runs = m.get('statusCheckRollup') or []
            concl = [r.get('conclusion') or r.get('state') for r in runs]
            bad = any(c in ('FAILURE', 'CANCELLED', 'ERROR', 'TIMED_OUT') for c in concl)
            ok = bool(runs) and all(c in ('SUCCESS', 'NEUTRAL', 'SKIPPED') for c in concl)
            st = 'success' if ok else ('failed' if bad else 'running')
        if state == 'merged':
            return 'already merged'
        if conflict:
            return 'CONFLICT: dev.ps1 wt sync, resolve (devtools.py keepboth for append-only files), re-check, push --force-with-lease to YOUR branch'
        if bad:
            return f'PIPELINE {st}: fix it, do not merge'
        if host == 'gitlab' and st is None:   # no MR CI in this repo: auto_merge() decides (merges once no pipeline is coming)
            res = auto_merge(worktree, iid)
            if merge_word(res) != 'WAIT':
                return res
        if ok:
            if host == 'gitlab':
                return _run([GLAB, 'api', '-X', 'PUT', f'projects/{enc}/merge_requests/{iid}/merge',
                             '-f', 'squash=true', '-f', 'should_remove_source_branch=true'])[:300]
            return _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch'], cwd=worktree)[:300]
        time.sleep(60)
    return 'TIMEOUT waiting for pipeline'


# ---------- Documents (reports.type: gdocs = Google Docs via gws, markdown = files under <runtime>/work/docs) ----------
def gws(*args, params=None, body=None, upload=None):
    cmd = [GWS, *args]
    if params is not None:
        cmd += ['--params', json.dumps(params)]
    if body is not None:
        cmd += ['--json', json.dumps(body)]
    if upload:
        cmd += ['--upload', upload]
    return _json(_run(cmd))


def keep_doc(title, path):
    """markdown reports: keep a copy under <runtime>/work/docs (worktrees get removed) and return its path."""
    d = kit_path('docs', create=True)
    slug = re.sub(r'[^A-Za-z0-9]+', '-', title).strip('-')[:80] or 'doc'
    dst = os.path.join(d, slug + os.path.splitext(path)[1])
    if os.path.abspath(dst) != os.path.abspath(path):
        shutil.copyfile(path, dst)
    return dst


def md_to_html(md, title=''):
    """Small Markdown -> HTML converter (no dependency) for `doc`: headings, tables, lists, bold, italics, code, links, rules.
    gws uploads Markdown as plain text (tables become pipes), so .md guides are converted before upload."""
    import html as _h

    def inline(t):
        t = _h.escape(t, quote=False)
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
            out.append('<pre><code>' + _h.escape('\n'.join(lines[i + 1:j])) + '</code></pre>'); i = j + 1; continue
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
    return f'<!doctype html><html><head><meta charset="utf-8"><title>{_h.escape(title)}</title></head><body>' + '\n'.join(out) + '</body></html>'


def make_doc(title, html_path, parent=None):
    """Publish a document. gdocs: upload HTML (or Markdown text) as a Google Doc shared anyone-with-link (reader); avoid '&' in titles.
    markdown: keep the file (.md or .html) and return its path - attach it with dev.ps1 tracker attach <task> <path>."""
    if REPORT_TYPE != 'gdocs':
        return keep_doc(title, html_path)
    if not GWS:
        raise SystemExit('reports.type is gdocs but the gws CLI is not on PATH (or set "reports": {"type": "markdown"})')
    if html_path.lower().endswith(('.md', '.markdown')):   # Markdown would upload as plain text: convert it first
        conv = os.path.splitext(html_path)[0] + '.doc.html'
        with open(html_path, encoding='utf-8') as fh:
            text = fh.read()
        with open(conv, 'w', encoding='utf-8') as fh:
            fh.write(md_to_html(text, title))
        html_path = conv
    body = {'name': title, 'mimeType': 'application/vnd.google-apps.document'}
    parent = parent or CFG.get('driveParent')
    if parent:
        body['parents'] = [parent]
    # gws only uploads files inside the current directory: run from the file's folder with a relative name
    cwd = os.getcwd()
    os.chdir(os.path.dirname(os.path.abspath(html_path)))
    try:
        r = gws('drive', 'files', 'create', params={'supportsAllDrives': True, 'fields': 'id,webViewLink'}, body=body, upload=os.path.basename(html_path))
    finally:
        os.chdir(cwd)
    if 'id' not in r:
        raise SystemExit(f'gws upload failed: {r}')
    gws('drive', 'permissions', 'create', params={'fileId': r['id'], 'supportsAllDrives': True}, body={'type': 'anyone', 'role': 'reader'})
    return f"https://docs.google.com/document/d/{r['id']}/edit"


# ---------- append-only conflicts (rebase), Liquibase sanity check, self-test ----------
def keepboth(paths):
    """Resolve simple conflict blocks by keeping OURS then THEIRS (append-only files only: changelog includes, route/nav lists,
    i18n keys, DI registrations, barrel exports, requirements.txt, item lists). Never on real code conflicts."""
    left = 0

    pat = re.compile(r'<<<<<<< [^\r\n]*\r?\n(.*?)(?:\|\|\|\|\|\|\| [^\r\n]*\r?\n.*?)?=======\r?\n(.*?)>>>>>>> [^\r\n]*(?:\r?\n|\Z)', re.S)   # last block may end the file
    for path in paths:
        text = open(path, encoding='utf-8', newline='').read()
        n = len(pat.findall(text))
        text = pat.sub(lambda m: m.group(1) + m.group(2), text)
        open(path, 'w', encoding='utf-8', newline='').write(text)
        print(path, 'resolved', n, 'block(s)')
        if re.search(r'^(<<<<<<<|>>>>>>>) ', text, re.M):   # a block the pattern could not take: never report success
            print(path, 'STILL HAS CONFLICT MARKERS: resolve by hand', file=sys.stderr)
            left += 1
    return 1 if left else 0


def lbcheck(argv):
    """Liquibase sanity check for any repo: replays the changelogs in master.xml order (schema only, approximate) and
flags addColumn of a column that already exists, or createTable of a table that already exists, when the changeSet
has no guarding <preConditions>. Also flags schema changeSets without a <rollback>.

  python devtools.py lbcheck <path/to/master.xml> [sinceTimestamp]

Only files whose name starts with a timestamp >= sinceTimestamp (yyyyMMddHHmmss) are reported (default: all), plus files named
in env LBCHECK_CHANGED (basenames separated by '|'; dev.ps1 check passes the changelog files git changed recently, so repos that
do not name changelogs with a timestamp are checked too).
Includes are resolved relative to the including file, the classpath root (the folder above 'config/liquibase/...', else the
'resources' folder) or master.xml's folder.
Prints one line per issue and ends with 'ISSUES <n>'; the exit code is 1 when n > 0."""
    sys.stdout.reconfigure(encoding='utf-8')
    MASTER = os.path.abspath(argv[0])
    SINCE = argv[1] if len(argv) > 1 else '0'
    MASTER_DIR = os.path.dirname(MASTER)
    # classpath root: for .../resources/config/liquibase/master.xml it is .../resources
    m = re.search(r'^(.*?)[\\/]config[\\/]liquibase[\\/]', MASTER) or re.search(r'^(.*[\\/]resources)[\\/]', MASTER)
    CP_ROOT = m.group(1) if m else MASTER_DIR
    CHANGED = {f for f in os.environ.get('LBCHECK_CHANGED', '').split('|') if f}
    SCHEMA_TAGS = {'createTable', 'addColumn', 'dropColumn', 'dropTable', 'renameColumn', 'modifyDataType',
                   'addForeignKeyConstraint', 'createIndex', 'addUniqueConstraint', 'sql', 'update', 'insert', 'delete'}
    AUTO_ROLLBACK = {'createTable', 'addColumn', 'renameColumn', 'createIndex', 'addForeignKeyConstraint', 'addUniqueConstraint'}

    tables, issues = {}, []


    def local(tag):
        return tag.split('}', 1)[-1]


    def resolve(f, base):
        for p in (os.path.join(base, f), os.path.join(CP_ROOT, f.lstrip('/')), os.path.join(MASTER_DIR, f.lstrip('/'))):
            if os.path.exists(p):
                return p
        return os.path.join(CP_ROOT, f.lstrip('/'))


    def apply(fname, cs, report):
        guarded = any(local(ch.tag) == 'preConditions' for ch in cs)
        has_rb = any(local(ch.tag) == 'rollback' for ch in cs)
        kinds = set()
        for el in cs.iter():
            t = local(el.tag)
            if el is not cs and t in SCHEMA_TAGS:
                kinds.add(t)
            tn = (el.get('tableName') or '').lower()
            if t == 'createTable':
                if tn in tables and report and not guarded:
                    issues.append(f'{fname} {cs.get("id")}: createTable {tn} but the table already exists')
                tables.setdefault(tn, {})
                for c in el:
                    if local(c.tag) == 'column':
                        tables[tn][(c.get('name') or '').lower()] = c.get('type')
            elif t == 'addColumn':
                tables.setdefault(tn, {})
                for c in el:
                    if local(c.tag) == 'column':
                        cn = (c.get('name') or '').lower()
                        if cn in tables[tn] and report and not guarded:
                            issues.append(f'{fname} {cs.get("id")}: addColumn {tn}.{cn} already exists ({tables[tn][cn]})')
                        tables[tn][cn] = c.get('type')
            elif t == 'dropTable':
                tables.pop(tn, None)
            elif t == 'dropColumn':
                if tn in tables:
                    tables[tn].pop((el.get('columnName') or '').lower(), None)
            elif t == 'renameColumn':
                old, new = (el.get('oldColumnName') or '').lower(), (el.get('newColumnName') or '').lower()
                if tn in tables and old in tables[tn]:
                    tables[tn][new] = tables[tn].pop(old)
        if report and kinds and not has_rb and not kinds <= AUTO_ROLLBACK:
            issues.append(f'{fname} {cs.get("id")}: {", ".join(sorted(kinds))} without a <rollback>')


    def walk(path, fname):
        try:
            root = ET.parse(path).getroot()
        except Exception as e:
            issues.append(f'PARSE ERROR {fname}: {e}')
            return
        ts = re.match(r'(\d{14})', os.path.basename(fname))
        report = (bool(ts) and ts.group(1) >= SINCE) or os.path.basename(fname) in CHANGED or (not ts and SINCE == '0')   # a changed old changelog counts too
        if report:
            # CI rule: a changeSet whose comment (XML comment or <comment>) says it is not reversible must still carry a NON-EMPTY
            # <rollback> (an empty <rollback/> is rejected too). The XML parser drops comments, so check the raw text per changeSet.
            try:
                raw = open(path, encoding='utf-8', errors='replace').read()
            except OSError:
                raw = ''
            for m in re.finditer(r'<changeSet\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</changeSet>', raw, re.S):
                body = m.group(2)
                rb = re.search(r'<rollback\s*/>|<rollback\b[^>]*>(.*?)</rollback>', body, re.S)
                empty_rb = rb is None or not (rb.group(1) or '').strip()
                if re.search(r'not\s+reversible|irreversible|non-reversible|cannot\s+be\s+(rolled|reverted)|no\s+rollback', body, re.I) and empty_rb:
                    issues.append(f'{fname} {m.group(1)}: marked not reversible but its <rollback> is missing or empty (CI changelog checks reject both): write a real rollback (reverse update / restore statement), not an empty tag')
        for node in root:
            t = local(node.tag)
            if t == 'changeSet':
                for rb in [c for c in node if local(c.tag) == 'rollback']:
                    node.remove(rb)
                    node.append(ET.Element('rollback'))  # keep the marker, drop its content
                apply(fname, node, report)
            elif t == 'include':
                f = node.get('file') or ''
                if f.lower().endswith('.xml'):   # .sql / .yaml includes are valid Liquibase, not XML: not a PARSE ERROR
                    walk(resolve(f, os.path.dirname(path)), f)
            elif t == 'includeAll':
                d = resolve(node.get('path'), os.path.dirname(path))
                for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
                    if f.endswith('.xml'):
                        walk(os.path.join(d, f), f)


    walk(MASTER, 'master.xml')
    for i in issues:
        print(i)
    print('ISSUES', len(issues))
    return 1 if issues else 0


def selftest():
    """Offline checks: a missing MR/solution body file is refused; mergeAfter pairs find the producer and warn on a repo name that
    does not match the remote; merge_word reads the last line. Exit 0 = all pass."""
    import contextlib as _c, io
    fails = 0


    def expect(what, cond):
        nonlocal fails
        print(('PASS ' if cond else 'FAIL ') + what)
        fails += 0 if cond else 1


    try:
        _body('no-such-body.md')
        expect('a missing body file is refused', False)
    except SystemExit as e:
        expect('a missing body file is refused', 'file not found' in str(e))
    expect('multi-line body text passes as it is', _body('a\nb') == 'a\nb')

    fd, path = tempfile.mkstemp(suffix='.json')
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump({'tasks': {'T1': {'mergeAfter': ['web!5>api!3', 'other!5>api!4']}}}, f)
    err = io.StringIO()
    with _c.redirect_stderr(err):
        out = unmerged_producers('group/web', '5', lambda r, i: 'opened', tracking=path)
    os.remove(path)
    expect('the open producer is found', out == [('api!3', 'opened', 'T1')])
    expect('a pair naming another repo is reported, not silently skipped', 'names repo other' in err.getvalue())
    expect('merge_word reads the last line', merge_word('x\nWAIT') == 'WAIT' and merge_word('x') == 'NOT_MERGED')
    print(f'{fails} failure(s)')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    a = sys.argv[1:]
    cmd = a[0] if a else ''
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
        print(comment(a[1], _text(a[2])))
    elif cmd == 'finish':
        finish(a[1], a[2], _body(a[3]), *(a[4:5] or []))
        print('done')
    elif cmd == 'mr':
        print(mr_create(a[1], a[2], _body(a[3]), *(a[4:5] or [])))
    elif cmd == 'merge':          # merges now / schedules merge-when-green; waits <= 90 s for a pipeline to appear
        print(auto_merge(a[1], a[2]))
    elif cmd == 'merge-wait':     # old behaviour: poll until merged (blocks up to 90 min)
        print(merge_when_green(a[1], a[2]))
    elif cmd == 'keepboth':
        sys.exit(keepboth(a[1:]))
    elif cmd == 'lbcheck':
        sys.exit(lbcheck(a[1:]))
    elif cmd == 'selftest':
        sys.exit(selftest())
    elif cmd == 'doc':
        title, path = a[1], a[2]
        if os.path.isfile(title) and not os.path.isfile(path):   # tolerate the swapped order: doc <file> "<title>"
            title, path = path, title
        print(make_doc(title, path, *(a[3:4] or [])))
    else:
        print(__doc__)
        sys.exit(2)
