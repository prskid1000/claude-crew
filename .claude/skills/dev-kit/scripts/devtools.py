"""Tracker / git-host / docs helpers for agents. Works for any repo: the host (GitLab or GitHub) and project path
come from the worktree's `origin` remote, the MR target from the worktree's recorded target (wt.ps1 new).

  python devtools.py task <taskId>                                  summary: name | status | url | parent
  python devtools.py subtasks <parentId> [status ...]               id | status | name
  python devtools.py newtask <listId> <parentId|-> <assigneeId|-> "<name>" <desc.md>
  python devtools.py status <taskId> "<status>"
  python devtools.py comment <taskId> <file.md | "text">
  python devtools.py finish <taskId> <guideUrl> <solution.md> ["for review"]   guide link on top + comments + status
  python devtools.py mr <worktree> "<title>" <body.md> [target]     open a merge/pull request from the current branch
  python devtools.py merge <worktree> <iid>                         squash-merge once the pipeline is green (polls)
  python devtools.py doc "<title>" <file.html> [driveFolderId]      Google Doc, anyone-with-link can view; prints URL

Defaults can be set in ..\\kit.local.json (next to this skill's SKILL.md; copy kit.example.json):
  "driveParent": "<Drive folder id>"   default parent folder for `doc`
  "gitHost": "gitlab.example.com"      self-hosted GitLab (default gitlab.com); "githubHost" likewise (default github.com)
Tracker commands use the ClickUp CLI (`clickup`); swap the functions in the ClickUp section to use another tracker.
Windows: run from PowerShell (python hangs in git-bash). CLIs (clickup, glab, gh, gws) are resolved with shutil.which.
"""
import json, os, re, shutil, subprocess, sys, time

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the dev-kit skill folder
try:
    CFG = json.load(open(os.path.join(KIT, 'kit.local.json'), encoding='utf-8'))
except Exception:
    CFG = {}
CU, GLAB, GH, GWS = (shutil.which(x) for x in ('clickup', 'glab', 'gh', 'gws'))


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


# ---------- ClickUp ----------
def task(tid):
    return _json(_run([CU, 'task', 'view', tid, '--json']))


def task_url(tid):
    return f'https://app.clickup.com/t/{tid}'


def subtasks(parent, statuses=None):
    out = []
    for s in task(parent).get('subtasks') or []:
        st = (s.get('status') or {}).get('status')
        if not statuses or st in statuses:
            out.append((s['id'], st, s['name']))
    return out


def new_task(list_id, parent, assignee, name, desc_md):
    cmd = [CU, 'task', 'create', '--list-id', list_id, '--name', name, '--markdown-description', desc_md, '--priority', '2', '--json']
    if parent and parent != '-':
        cmd += ['--parent', parent]
    if assignee and assignee != '-':
        cmd += ['--assignee', assignee]
    return _json(_run(cmd)).get('id')


def set_status(tid, status):
    return _run([CU, 'status', 'set', status, tid])


def comment(tid, text):
    return _run([CU, 'comment', 'add', tid, text])


def finish(tid, guide_url, solution_md, status='for review'):
    t = task(tid)
    md = t.get('markdown_description') or t.get('description') or ''
    if guide_url not in md:
        _run([CU, 'task', 'edit', tid, '--markdown-description', f'Testing guide: {guide_url}\n\n{md}'])
    comment(tid, solution_md)
    comment(tid, f'How to test: follow the tester guide {guide_url}.')
    set_status(tid, status)


# ---------- Git host (GitLab or GitHub, from the origin remote) ----------
GITLAB_HOST = CFG.get('gitHost') or 'gitlab.com'
GITHUB_HOST = CFG.get('githubHost') or 'github.com'


def remote(worktree):
    url = _run(['git', '-C', worktree, 'remote', 'get-url', 'origin']).strip()
    for kind, host in (('gitlab', GITLAB_HOST), ('github', GITHUB_HOST), ('gitlab', 'gitlab.com'), ('github', 'github.com')):
        m = re.search(re.escape(host) + r'(?::\d+)?[:/](.+?)(?:\.git)?$', url)
        if m:
            return kind, m.group(1)
    raise SystemExit(f'unsupported remote: {url} (set "gitHost" / "githubHost" in kit.local.json for a self-hosted server)')


def target_of(worktree):
    gd = _run(['git', '-C', worktree, 'rev-parse', '--git-dir'])
    gd = gd if os.path.isabs(gd) else os.path.join(worktree, gd)
    f = os.path.join(gd, 'claude-target')
    return open(f).read().strip() if os.path.exists(f) else None


MR_SECTIONS = ('## Task', '## What changed', '## Verified', '## How to test')  # orchestrate/templates/MR_BODY.md
FOOTER = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'


def mr_create(worktree, title, body_md, tgt=None):
    missing = [h for h in MR_SECTIONS if h not in body_md]
    if missing:
        print(f'[mr] body is missing {missing} - see .claude/skills/orchestrate/templates/MR_BODY.md', file=sys.stderr)
    if 'clickup.com' not in body_md:
        print('[mr] body has no tracker (ClickUp) link', file=sys.stderr)
    if FOOTER not in body_md:
        body_md = body_md.rstrip() + '\n\n' + FOOTER + '\n'
    host, _ = remote(worktree)
    src = _run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'])
    tgt = tgt or target_of(worktree)
    if not tgt:
        raise SystemExit('no target: pass it, or create the worktree with wt.ps1 new')
    if host == 'gitlab':
        out = _run([GLAB, 'mr', 'create', '--source-branch', src, '--target-branch', tgt, '--title', title,
                    '--description', body_md, '--remove-source-branch', '--squash-before-merge', '--yes'], cwd=worktree)
        m = re.findall(r'https://[^\s/]+/\S+/merge_requests/\d+', out)
    else:
        out = _run([GH, 'pr', 'create', '--head', src, '--base', tgt, '--title', title, '--body', body_md], cwd=worktree)
        m = re.findall(r'https://[^\s/]+/\S+/pull/\d+', out)
    return m[-1] if m else out


def auto_merge(worktree, iid):
    """Ask the host to merge as soon as the pipeline is green (GitLab 'merge when pipeline succeeds', GitHub auto-merge).
    Returns at once, so an agent never has to sit through a long pipeline. Merges straight away if it is already green."""
    host, proj = remote(worktree)
    if host == 'gitlab':
        enc = proj.replace('/', '%2F')
        m = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}']))
        if m.get('state') == 'merged':
            return 'already merged'
        if m.get('has_conflicts'):
            return 'CONFLICT: wt.ps1 sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again'
        st = (m.get('head_pipeline') or {}).get('status')
        if st in ('failed', 'canceled'):
            return f'PIPELINE {st}: fix it, do not merge'
        args = ['-f', 'squash=true', '-f', 'should_remove_source_branch=true']
        # A repo without MR CI never gets a pipeline: merge_when_pipeline_succeeds would then wait forever.
        # No pipeline at all on the MR and the head commit pushed > 5 min ago = no CI for MRs -> merge now.
        no_ci = False
        if st is None:
            pls = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}/pipelines'])) or []
            sha = m.get('sha') or ''
            c = _json(_run([GLAB, 'api', f'projects/{enc}/repository/commits/{sha}'])) if sha else {}
            when = c.get('committed_date') or c.get('created_at')
            if not pls and when:
                from datetime import datetime, timezone
                age = (datetime.now(timezone.utc) - datetime.fromisoformat(when.replace('Z', '+00:00'))).total_seconds()
                no_ci = age > 300
            if not pls and not no_ci:
                return f'WAIT: no pipeline on !{iid} yet (pushed < 5 min ago); run merge again in a few minutes'
        if st != 'success' and not no_ci:
            args += ['-f', 'merge_when_pipeline_succeeds=true']
        out = _json(_run([GLAB, 'api', '-X', 'PUT', f'projects/{enc}/merge_requests/{iid}/merge', *args]))
        if out.get('state') == 'merged':
            return 'merged'
        if out.get('merge_when_pipeline_succeeds'):
            return f'scheduled: GitLab merges !{iid} automatically when the pipeline ({st}) succeeds'
        return f'not merged: {str(out)[:300]}'
    out = _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch', '--auto'], cwd=worktree)
    return out[:300] or f'scheduled: GitHub auto-merges #{iid} when checks pass'


def merge_when_green(worktree, iid, timeout_min=90):
    """Poll the pipeline; squash-merge when green. Never merges on failure or conflict. Prefer auto_merge (no waiting)."""
    host, proj = remote(worktree)
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
            if not res.startswith('WAIT'):
                return res
        if ok:
            if host == 'gitlab':
                return _run([GLAB, 'api', '-X', 'PUT', f'projects/{enc}/merge_requests/{iid}/merge',
                             '-f', 'squash=true', '-f', 'should_remove_source_branch=true'])[:300]
            return _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch'], cwd=worktree)[:300]
        time.sleep(60)
    return 'TIMEOUT waiting for pipeline'


# ---------- Google Docs ----------
def gws(*args, params=None, body=None, upload=None):
    cmd = [GWS, *args]
    if params is not None:
        cmd += ['--params', json.dumps(params)]
    if body is not None:
        cmd += ['--json', json.dumps(body)]
    if upload:
        cmd += ['--upload', upload]
    return _json(_run(cmd))


def make_doc(title, html_path, parent=None):
    """Upload HTML as a Google Doc shared anyone-with-link (reader). Avoid '&' in titles."""
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
        print(' | '.join([t.get('name', ''), (t.get('status') or {}).get('status', ''), task_url(a[1]), str(t.get('parent') or '')]))
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
        print(make_doc(a[1], a[2], *(a[3:4] or [])))
    else:
        print(__doc__)
