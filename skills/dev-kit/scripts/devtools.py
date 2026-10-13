"""Tracker / git-host / docs helpers for agents. Works for any repo: the host (GitLab or GitHub) and project path
come from the worktree's `origin` remote, the MR target from the worktree's recorded target (wt.ps1 new).

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
                                                                    whose producer (tracking.local.json mergeAfter) is unmerged: WAIT
  python devtools.py doc "<title>" <file.html|.md> [driveFolderId]  publish a document (tester guide, report); prints its URL/path
                                                                    (.md is converted to HTML for gdocs: tables, lists, code survive)
  python devtools.py guide-mode                                     "always" or "complex": when a change gets a published tester guide

Defaults can be set in ..\\kit.local.json (next to this skill's SKILL.md; copy kit.example.json):
  "tracker": { "type": "clickup|github|gitlab|jira|none", ... }   task commands go through tracker.ps1 (default clickup)
  "reports": { "type": "gdocs|markdown" }  `doc`: gdocs = Google Doc via gws (default when gws is installed);
                                           markdown = the file is kept under <runtime>/work/docs and its path printed
  "reports": { "guide": "complex|always" } complex (default) = tester guide for complex changes, a comment for simple ones;
                                           always = every testable change gets a published tester guide (steps + screenshots)
  "driveParent": "<Drive folder id>"   default parent folder for `doc` (gdocs)
  "gitHost": "gitlab.example.com"      self-hosted GitLab (default gitlab.com); "githubHost" likewise (default github.com)
Windows: run from PowerShell (python hangs in git-bash); Linux/macOS: python3. CLIs (pwsh, glab, gh, gws) are resolved with
shutil.which, so the same names work on every OS.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the dev-kit skill folder
try:
    CFG = json.load(open(os.path.join(KIT, 'kit.local.json'), encoding='utf-8'))
except Exception:
    CFG = {}
GLAB, GH, GWS = (shutil.which(x) for x in ('glab', 'gh', 'gws'))
REPORT_TYPE = (os.environ.get('KIT_REPORT_TYPE') or (CFG.get('reports') or {}).get('type') or ('gdocs' if GWS else 'markdown')).lower()
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kitpaths import kit_path, locked  # noqa: E402  (the kit's one path map: kitpaths.json)


def _run(cmd, cwd=None):
    if not cmd[0]:
        raise SystemExit(f'CLI not found on PATH for: {cmd[1:3]}')
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding='utf-8')
    return ((p.stdout or '') + (p.stderr or '')).strip()


def _json(out):
    """CLIs may print notices around the JSON; decode the first JSON value."""
    starts = [i for i in (out.find('{'), out.find('[')) if i >= 0]
    try:
        return json.JSONDecoder().raw_decode(out[min(starts):])[0] if starts else json.loads(out)
    except Exception:
        return {'raw': out}


def _text(arg):
    return open(arg, encoding='utf-8').read() if os.path.isfile(arg) else arg


# ---------- Tracker (tracker.ps1: clickup | github | gitlab | jira | none, from kit.local.json "tracker") ----------
TRACKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tracker.ps1')
PWSH = shutil.which('pwsh') or shutil.which('powershell')
TRACKER_TYPE = (os.environ.get('KIT_TRACKER_TYPE') or (CFG.get('tracker') or {}).get('type') or 'clickup').lower()


def _tracker(*args):
    """Run tracker.ps1 <verb> ...; long texts go through a temp file (tracker.ps1 reads a file path as its content)."""
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
        return _run([PWSH, '-NoProfile', '-NonInteractive', '-File', TRACKER, *argv])
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
    """The MR target: the worktree's record (wt.ps1 new), else kit.local.json repos[].target of this repo, else origin/HEAD.
    A fallback is printed (stderr) with where it came from; None only when all three are missing."""
    gd = _run(['git', '-C', worktree, 'rev-parse', '--git-dir'])
    gd = gd if os.path.isabs(gd) else os.path.join(worktree, gd)
    f = os.path.join(gd, 'claude-target')
    if os.path.exists(f):
        return open(f).read().strip() or None
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
            print(f"[mr] target {r['target']} (no wt.ps1 record; kit.local.json repos[].target of {r.get('name') or co})", file=sys.stderr)
            return r['target']
    # 2. the remote's default branch
    head = _run(['git', '-C', worktree, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD'])
    if head.startswith('origin/') and '\n' not in head:
        print(f'[mr] target {head[7:]} (no wt.ps1 record, no kit.local.json repos[].target; origin/HEAD)', file=sys.stderr)
        return head[7:]
    return None


MR_SECTIONS = ('## Task', '## What changed', '## Verified', '## How to test')  # orchestrate/templates/MR_BODY.md
FOOTER = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'


def _verified_gaps(body_md):
    """'## Verified' should say what was not run and how pure logic was proven (MR_BODY.md): True when it has neither line."""
    m = re.search(r'^## Verified[^\n]*\n(.*?)(?=^## |\Z)', body_md, re.M | re.S)
    sec = m.group(1) if m else ''
    return bool(m) and not re.search(r'(?im)^\s*[-*]?\s*(\*\*)?(not run|pure logic)(\*\*)?\s*:', sec)


UI_FILES = re.compile(r'\.(html?|s?css|less|sass|tsx|jsx|vue|svelte)$|(^|/)res/layout[^/]*/[^/]+\.xml$', re.I)


def _ui_line_missing(worktree, tgt, body_md):
    """MR_BODY.md '## Verified' carries '- UI: <spec / screenshot> (or "not a UI change")': the changed UI files when the body has no
    UI: line and the diff against origin/<target> touches templates or styles, else []."""
    if re.search(r'(?im)^\s*[-*]?\s*(\*\*)?UI(\*\*)?\s*:', body_md) or not tgt:
        return []
    out = _run(['git', '-C', worktree, 'diff', '--name-only', f'origin/{tgt}...HEAD'])
    return [f for f in out.splitlines() if UI_FILES.search(f.strip())]


def mr_create(worktree, title, body_md, tgt=None):
    missing = [h for h in MR_SECTIONS if h not in body_md]
    if missing:
        print(f'[mr] body is missing {missing} - see .claude/skills/orchestrate/templates/MR_BODY.md', file=sys.stderr)
    if _verified_gaps(body_md):
        print('[mr] "## Verified" has neither a "Not run: <gate and why>" nor a "Pure logic: <spec file or node output>" line'
              ' - say what was not run (or "Not run: nothing") - see MR_BODY.md', file=sys.stderr)
    link = {'clickup': 'clickup.com', 'github': '/issues/', 'gitlab': '/issues/', 'jira': '/browse/'}.get(TRACKER_TYPE)
    if link and link not in body_md:
        print(f'[mr] body has no tracker ({TRACKER_TYPE}) task link', file=sys.stderr)
    if FOOTER not in body_md:
        body_md = body_md.rstrip() + '\n\n' + FOOTER + '\n'
    host, _ = remote(worktree)
    src = _run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'])
    tgt = tgt or target_of(worktree)
    if not tgt:
        raise SystemExit('no target: no wt.ps1 record, no kit.local.json repos[].target for this repo and no origin/HEAD'
                         ' - pass it as the 4th argument (git remote set-head origin --auto fixes origin/HEAD)')
    ui = _ui_line_missing(worktree, tgt, body_md)
    if ui:
        print(f'[mr] the diff touches templates/styles ({", ".join(ui[:3])}{" ..." if len(ui) > 3 else ""}) but "## Verified" has no'
              ' "UI: <committed spec or screenshot link>" line (or "UI: not a UI change") - see MR_BODY.md', file=sys.stderr)
    if host == 'gitlab':
        out = _run([GLAB, 'mr', 'create', '--source-branch', src, '--target-branch', tgt, '--title', title,
                    '--description', body_md, '--remove-source-branch', '--squash-before-merge', '--yes'], cwd=worktree)
        m = re.findall(r'https://[^\s/]+/\S+/merge_requests/\d+', out)
    else:
        out = _run([GH, 'pr', 'create', '--head', src, '--base', tgt, '--title', title, '--body', body_md], cwd=worktree)
        m = re.findall(r'https://[^\s/]+/\S+/pull/\d+', out)
    return m[-1] if m else out


def _remember_automerge(ref):
    """GitLab drops 'merge when pipeline succeeds' when new commits are pushed (e.g. a rebase after scheduling).
    Record the intent in the durable tracking file (<kit>/tracking.local.json, "automerge"); track.ps1 run (every supervise
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
        return f'conflict on !{iid}: wt.ps1 sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again\nCONFLICT'
    if (m.get('head_pipeline') or {}).get('status') in ('failed', 'canceled'):
        return f'pipeline {m["head_pipeline"]["status"]} on !{iid}: fix it, do not merge\nPIPELINE_FAILED'
    return f'not merged: !{iid} is {m.get("state")} ({m.get("detailed_merge_status") or m.get("merge_status")}); merge reply: {str(put)[:300]}\nNOT_MERGED'


def _norm_ref(ref):
    """'web!12', a quoted ref, an MR/PR URL or an alias (kit.local.json repoAliases) -> (repo, iid) as track.ps1 stores them."""
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
    """'merged' / 'opened' / 'closed' / '' (unknown) of <repo>!<iid>, resolved like track.ps1 (gitlabGroup, else the remote's group)."""
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
    """Producer-before-consumer: the mergeAfter pairs ('<consumer>!<iid>><producer>!<iid>', written by track.ps1 add -MergeAfter)
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
            if not sep or not d or not o or str(d[1]) != str(iid) or not _same_repo(d[0], proj):
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
    A consumer MR whose registered producer (track.ps1 -MergeAfter) is not merged yet is not merged: WAIT ("waiting for producer")."""
    host, proj = remote(worktree)
    waiting = unmerged_producers(proj, iid, lambda r, i: _host_mr_state(host, proj, r, i))
    if waiting:
        lines = [f'waiting for producer {ref} ({st}; task {tid}): {proj}!{iid} merges only after it' for ref, st, tid in waiting]
        if any(st == 'closed' for _, st, _ in waiting):
            return '\n'.join(lines) + '\nproducer MR closed: fix the merge order (track.ps1 mergeAfter) with the coordinator\nNOT_MERGED'
        return '\n'.join(lines) + '\nnot merged now: track.ps1 run (supervise) merges it once the producer merged\nWAIT'
    if host == 'gitlab':
        enc = proj.replace('/', '%2F')
        m = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}']))
        if m.get('state') == 'merged':
            return f'already merged !{iid}\nMERGED'
        if m.get('state') and m.get('state') != 'opened':
            return f'!{iid} is {m.get("state")}, not open\nNOT_MERGED'
        if m.get('has_conflicts'):
            return 'CONFLICT: wt.ps1 sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again\nCONFLICT'
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

                def _no_ci():
                    pls = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}/pipelines'])) or []
                    refp = _json(_run([GLAB, 'api', f'projects/{src_proj}/pipelines?ref={ref}&per_page=1'])) if ref else {}
                    return (not pls and isinstance(refp, list) and not refp), bool(pls)

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
            return 'CONFLICT: wt.ps1 sync, resolve (keepboth.py for append-only files), re-check, push --force-with-lease to YOUR branch'
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
    markdown: keep the file (.md or .html) and return its path - attach it with tracker.ps1 attach <task> <path>."""
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
        print(new_task(a[1], a[2], a[3], a[4], _text(a[5])))
    elif cmd == 'status':
        print(set_status(a[1], a[2]))
    elif cmd == 'comment':
        print(comment(a[1], _text(a[2])))
    elif cmd == 'finish':
        finish(a[1], a[2], _text(a[3]), *(a[4:5] or []))
        print('done')
    elif cmd == 'mr':
        print(mr_create(a[1], a[2], _text(a[3]), *(a[4:5] or [])))
    elif cmd == 'merge':          # schedules the merge on green and returns at once
        print(auto_merge(a[1], a[2]))
    elif cmd == 'merge-wait':     # old behaviour: poll until merged (blocks up to 90 min)
        print(merge_when_green(a[1], a[2]))
    elif cmd == 'doc':
        title, path = a[1], a[2]
        if os.path.isfile(title) and not os.path.isfile(path):   # tolerate the swapped order: doc <file> "<title>"
            title, path = path, title
        print(make_doc(title, path, *(a[3:4] or [])))
    elif cmd == 'guide-mode':
        print('always' if str((CFG.get('reports') or {}).get('guide') or '').lower() == 'always' else 'complex')
    else:
        print(__doc__)
