"""devtools.py: tracker / git-host / docs helpers for agents (dev-kit steps 6-7). Works for any repo: the host (GitLab or GitHub) and project path
come from the worktree's `origin` remote, the MR target from the worktree's recorded target (dev.ps1 wt new).

  python devtools.py task <taskId>                                  summary: name | status | url | parent
  python devtools.py subtasks <parentId> [status ...]               id | status | name
  python devtools.py newtask <listId|-> <parentId|-> <assignee|-> "<name>" <desc.md>
  python devtools.py status <taskId> "<status>"                     logical (review, promoted, inTest, closed) or the tracker's own name
  python devtools.py comment <taskId> <file.md | "text"> [kind]   kind: comment-status (default), comment-deploy, decision-request ...
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
  python devtools.py migrations classify|plan|rules|selftest ...    the local env's migration audit (run by localenv.ps1; section "migrations")
  python devtools.py findings schema                                the 23 keys with their formats, an example, the project profile shape
  python devtools.py findings validate <module>.json [...]          a module audit's findings: the 23-key schema (revy, kind module)
  python devtools.py findings summary <module>.json [--sources ".."] [--out <dir>]   <module>-summary.md + .html
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
import argparse, hashlib, html, json, os, re, shutil, subprocess, sys, tempfile, time
from collections import Counter
import xml.etree.ElementTree as ET

KIT = os.path.dirname(os.path.abspath(__file__))  # dev-kit skill folder
KIT_DIR = os.path.dirname(os.path.dirname(KIT))   # the kit (.claude)
def _cfg_file():
  own = os.path.join(KIT, 'kit.local.json')
  if os.path.exists(own):
    return own
  try:   # linked kit worktree: main clone's config
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
GLAB, GH, GWS = (shutil.which(x) for x in ('glab', 'gh', 'gws'))
REPORT_TYPE = (os.environ.get('KIT_REPORT_TYPE') or (CFG.get('reports') or {}).get('type') or ('gdocs' if GWS else 'markdown')).lower()
import contextlib
with open(os.path.join(KIT, 'kit.example.json'), encoding='utf-8') as _f:
  MAP = json.load(_f)['_paths']   # kit path map (kit.example.json _paths)


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
    raise KeyError(f'kit_path: unknown name {name!r} (see skills/dev-kit/kit.example.json _paths)')
  p = os.path.normpath(p)
  if create:
    os.makedirs(p if is_dir else os.path.dirname(p), exist_ok=True)
  return p


@contextlib.contextmanager
def locked(path, stale=120):
  lock = path + '.lock'
  fd = None
  end = time.time() + stale + 10   # past stale: a dead writer's lock is taken over first
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
      if time.time() > end:   # never run unlocked (lost concurrent writes)
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


# reads retry transient errors (2 s, 6 s) inside one deadline; writes never retry (a lost reply would duplicate a task / comment)
TRANSIENT = re.compile(r'(?i)timed? ?out|connection (reset|refused|closed|aborted)|could not resolve|no such host|unreachable|dial tcp|\bEOF\b|TLS handshake|temporar|\b(429|500|502|503|504)\b|bad gateway|service unavailable|too many requests')
STOP_AT = [0.0]   # auto_merge sets its own end: no call outlives max_wait


def _is_write(cmd):
  s = [str(c) for c in cmd[1:]]
  m = next((s[i + 1] for i, c in enumerate(s[:-1]) if c in ('-X', '--method')), 'GET')
  return m.upper() != 'GET' or any(w in s[:4] for w in ('create', 'merge', 'update', 'comment', 'note', 'edit', 'close', 'upload', 'delete'))


def _run(cmd, cwd=None, check=False, write=None):
  if not cmd[0]:
    raise SystemExit(f'CLI not found on PATH for: {cmd[1:3]}')
  sec = min(120, int(os.environ.get('KIT_NET_TIMEOUT_SEC') or (CFG.get('net') or {}).get('timeoutSec') or 120))   # net.timeoutSec = the whole deadline
  write = _is_write(cmd) if write is None else write
  tries, delay, hangs = 1 if write else max(1, int(os.environ.get('KIT_NET_TRIES') or 3)), 2, 0
  end = min(time.time() + sec, STOP_AT[0] or float('inf'))
  for i in range(1, tries + 1):
    left = max(10 if STOP_AT[0] else 1, int((end - time.time()) / (2 if i == 1 and tries > 1 else 1)))   # a read keeps half for its one retry
    try:   # a hung CLI must not outlive the tool timeout
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
  if check and rc:   # a failed write must not print 'done' / exit 0
    raise SystemExit(f'failed (exit {rc}): {" ".join(str(c) for c in cmd[-4:])[:120]}\n{out[-600:]}')
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
  """Body from a file (mr, finish, newtask): a missing file is an error, never its name as the body; multi-line text passes."""
  if os.path.isfile(arg) or '\n' in arg:
    return _text(arg)
  raise SystemExit(f'file not found: {arg} - write it first (nothing was created)')


# --- Tracker (dev.ps1 tracker; kit.local.json "tracker")
DEV = os.path.join(KIT, 'dev.ps1')   # tracker adapter
PWSH = shutil.which('pwsh') or shutil.which('powershell')
TRACKER_TYPE = (os.environ.get('KIT_TRACKER_TYPE') or (CFG.get('tracker') or {}).get('type') or 'none').lower()


def _tracker(*args):
  """dev.ps1 tracker <verb> ...; long texts go via a temp file (it reads a file path as the content)."""
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
    # reads lenient + retried (finish() handles failed lookups); writes fail loudly, never retried
    w = bool(argv) and argv[0] in ('status', 'comment', 'describe', 'create', 'rename', 'attach')
    return _run([PWSH, '-NoProfile', '-NonInteractive', '-File', DEV, 'tracker', *argv], check=w, write=w)
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


def prose(kind, text):
  """Print kittool.py prose findings (templates.md "Writing standards") for a text about to be published; never truncates."""
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
  if list_id and list_id != '-':
    args += ['-List', list_id]
  if parent and parent != '-':
    args += ['-Parent', parent]
  if assignee and assignee != '-':
    args += ['-Assignee', assignee]
  return _json(_tracker(*args)).get('id')


def set_status(tid, status):
  """status: logical (review, promoted, inTest, closed, ... via tracker.statuses) or the tracker's own name."""
  return _tracker('status', tid, status)


def comment(tid, text, kind='comment-status'):
  prose(kind, text)
  return _tracker('comment', tid, text)


def finish(tid, guide_url, solution_md, status='review'):
  if os.path.isfile(guide_url):   # guide file: publish it, link it (never a local path)
    guide_url = make_doc(os.path.splitext(os.path.basename(guide_url))[0], guide_url)
  t = task(tid)
  md = t.get('description') or ''
  # failed lookup (no id/name): describing would wipe the description
  if t.get('id') and t.get('name') and guide_url not in md:
    _tracker('describe', tid, f'Testing doc: {guide_url}\n\n{md}')
  # one comment: solution + guide link unless it has one
  if guide_url not in solution_md:
    solution_md = f'{solution_md.rstrip()}\n\n**Testing doc**: {guide_url}'
  comment(tid, solution_md, 'comment-solution')
  set_status(tid, status)


# --- Git host (GitLab or GitHub, from origin)
GITLAB_HOST = CFG.get('gitHost') or 'gitlab.com'
GITHUB_HOST = CFG.get('githubHost') or 'github.com'
if CFG.get('gitHost') and not os.environ.get('GITLAB_HOST'):   # outside a checkout glab api hits gitlab.com
  os.environ['GITLAB_HOST'] = CFG['gitHost']


def remote(worktree):
  url = _run(['git', '-C', worktree, 'remote', 'get-url', 'origin']).strip()
  for kind, host in (('gitlab', GITLAB_HOST), ('github', GITHUB_HOST), ('gitlab', 'gitlab.com'), ('github', 'github.com')):
    m = re.search(re.escape(host) + r'(?::\d+)?[:/](.+?)(?:\.git)?$', url)
    if m:
      return kind, m.group(1)
  raise SystemExit(f'unsupported remote: {url} (set "gitHost" / "githubHost" in kit.local.json for a self-hosted server)')


def target_of(worktree):
  """MR target: the worktree's record (dev.ps1 wt new), else kit.local.json repos[].target, else origin/HEAD.
    A fallback is printed (stderr) with its source; None when all three are missing."""
  gd = _run(['git', '-C', worktree, 'rev-parse', '--git-dir'])
  gd = gd if os.path.isabs(gd) else os.path.join(worktree, gd)
  f = os.path.join(gd, 'claude-target')
  if os.path.exists(f):
    with open(f, encoding='utf-8-sig') as fh:
      return fh.read().strip() or None
  # 1. kit.local.json repos[]: checkout = this main checkout, or name/alias = remote repo name
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


MR_SECTIONS = ('## Summary', '## Changes', '## How tested', '## Risks', '## Links')  # templates.md "MR body"
FOOTER = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'


def _verified_gaps(body_md):
  """True when '## How tested' says neither what was not run nor how pure logic was proven (templates.md "MR body")."""
  m = re.search(r'^## How tested[^\n]*\n(.*?)(?=^## |\Z)', body_md, re.M | re.S)
  sec = m.group(1) if m else ''
  return bool(m) and not re.search(r'(?im)^\s*[-*]?\s*(\*\*)?(not run|pure logic)(\*\*)?\s*:', sec)


UI_FILES = re.compile(r'\.(html?|s?css|less|sass|tsx|jsx|vue|svelte)$|(^|/)res/layout[^/]*/[^/]+\.xml$', re.I)


def _ui_line_missing(worktree, tgt, body_md):
  """Changed UI files (templates / styles vs origin/<target>) when '## How tested' has no 'UI:' line (templates.md "MR body"), else []."""
  if re.search(r'(?im)^\s*[-*]?\s*(\*\*)?UI(\*\*)?\s*:', body_md) or not tgt:
    return []
  out = _run(['git', '-C', worktree, 'diff', '--name-only', f'origin/{tgt}...HEAD'])
  return [f for f in out.splitlines() if UI_FILES.search(f.strip())]


def mr_create(worktree, title, body_md, tgt=None):
  missing = [h for h in MR_SECTIONS if h not in body_md]
  if missing:
    print(f'[mr] body is missing {missing} - see templates.md "MR body"', file=sys.stderr)
  prose('mr-title', title)
  prose('mr-body', body_md)
  if _verified_gaps(body_md):
    print('[mr] "## How tested" has neither a "Not run: <gate and why>" nor a "Pure logic: <spec file or node output>" line'
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
    print(f'[mr] the diff touches templates/styles ({", ".join(ui[:3])}{" ..." if len(ui) > 3 else ""}) but "## How tested" has no'
       ' "UI: <committed spec or screenshot link>" line (or "UI: not a UI change") - see templates.md "MR body"', file=sys.stderr)
  if host == 'gitlab':
    out = _run([GLAB, 'mr', 'create', '--source-branch', src, '--target-branch', tgt, '--title', title,
          '--description', body_md, '--remove-source-branch', '--squash-before-merge', '--yes'], cwd=worktree)
    m = re.findall(r'https://[^\s/]+/\S+/merge_requests/\d+', out)
    if not m and 'already exists' in out.lower():   # retry after a timeout: report the first call's MR
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
  except Exception as e:   # a lost intent is never re-armed: say so
    print(f'[merge] could not record the merge-when-green intent for {ref} in {path}: {e}', file=sys.stderr)


MERGE_WORDS = ('MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED')


def merge_word(res):
  """Status word on the last line of auto_merge's result (NOT_MERGED when none)."""
  last = (str(res or '').strip().splitlines() or [''])[-1].strip()
  return last if last in MERGE_WORDS else 'NOT_MERGED'


def _progress(msg):
  print(f'[merge] {msg}', flush=True)   # flushed: a watcher sees it is alive


def _gitlab_no_ci_config(enc, m):
  """True when the project has no CI: no required pipeline, no custom CI config path, no Auto DevOps, no .gitlab-ci.yml on
    the MR's target branch (only a 404 counts as missing; any other error = 'has CI')."""
  p = _json(_run([GLAB, 'api', f'projects/{enc}']))
  if not p.get('id') or p.get('only_allow_merge_if_pipeline_succeeds') or p.get('ci_config_path') or p.get('auto_devops_enabled'):
    return False
  tgt = (m.get('target_branch') or '').replace('/', '%2F')
  if not tgt:
    return False
  f = _run([GLAB, 'api', f'projects/{enc}/repository/files/.gitlab-ci.yml?ref={tgt}'])
  return bool(re.search(r'\b404\b', f)) and 'not found' in f.lower() and 'file_name' not in f   # an HTTP 404, not any '404' text


def _gitlab_final(enc, proj, iid, put, st):
  """Re-read the MR after the merge PUT (it can take a moment); its state -> result text + status word."""
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
  """'web!12', a quoted ref, an MR/PR URL or an alias (repoAliases) -> (repo, iid) as orch.ps1 track stores them."""
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
  """Does a tracking ref's repo ('web', 'group/web') name the origin project path ('group/sub/web')?"""
  a, b = repo.lower().strip('/'), proj.lower().strip('/')
  return a == b or b.endswith('/' + a)


def _host_mr_state(host, proj, repo, iid):
  """'merged'/'opened'/'closed'/'' (unknown) of <repo>!<iid>, resolved like orch.ps1 track (gitlabGroup, else the remote's group)."""
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
  """Unmerged producers of this MR (<proj>!<iid>): tracking-file mergeAfter pairs ('<consumer>!<iid>><producer>!<iid>', orch.ps1
    track add -MergeAfter). state_of(repo, iid) -> 'merged'/'opened'/'closed'/''. Returns [(producer ref, state, task id)]."""
  path = tracking or kit_path('tracking')
  try:
    with open(path, encoding='utf-8-sig') as fh:
      data = json.load(fh) if os.path.exists(path) else {}
  except FileNotFoundError:
    data = {}
  except Exception as e:   # unreadable: order unknown -> WAIT, never "no producers"
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
      if not _same_repo(d[0], proj):   # repo not matched: a missing alias would skip the merge order
        print(f'[merge] mergeAfter {pair} (task {tid}) names repo {d[0]}, this remote is {proj}: not applied'
           ' - add kit.local.json repoAliases if they are the same repo', file=sys.stderr)
        continue
      st = state_of(o[0], o[1])
      if st != 'merged':
        out.append((f'{o[0]}!{o[1]}', st or 'unknown', tid))
  return out


def held(proj):
  """holdMerge: true (every repo) or repo names / aliases / paths; a held repo's MRs are never merged by a script."""
  h = CFG.get('holdMerge')
  if h is True:
    return True
  names = [str((CFG.get('repoAliases') or {}).get(x) or x) for x in (h if isinstance(h, list) else [])]
  return any(_same_repo(n, proj) for n in names)


def _gh_workflows(worktree):
  d = os.path.join(worktree, '.github', 'workflows')
  return os.path.isdir(d) and any(f.endswith(('.yml', '.yaml')) for f in os.listdir(d))


def auto_merge(worktree, iid, max_wait=90):
  STOP_AT[0] = time.time() + max_wait   # every host call ends inside max_wait (10 s floor per call)
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
    args = ['-f', 'squash=true', '-f', 'should_remove_source_branch=true'] + (['-f', f"sha={m['sha']}"] if m.get('sha') else [])   # a push after the read refuses the merge
    # no CI: merge-when-green waits forever. No pipeline required + no CI config -> merge now; CI file + no pipeline 5 min
    # after the MR update (not the commit date: an old commit pushed now has none YET) -> no CI; else WAIT
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

        # HEAD pipelines only: an older commit's armed merge-when-green without CI or WAITed early
        def _no_ci():
          pls = _json(_run([GLAB, 'api', f'projects/{enc}/merge_requests/{iid}/pipelines']))
          if not isinstance(pls, list):   # query failed: unknown, never 'no CI' (-> WAIT)
            return False, False
          pls = [p for p in pls if isinstance(p, dict) and (not sha or p.get('sha') == sha)] if isinstance(pls, list) else []
          refp = _json(_run([GLAB, 'api', f'projects/{src_proj}/pipelines?ref={ref}&sha={sha}&per_page=1'])) if ref else {}
          refp = [p for p in refp if isinstance(p, dict) and (not sha or p.get('sha') == sha)] if isinstance(refp, list) else None
          head = pls or refp or []
          return (not head and refp is not None), bool(head)

        when = m.get('updated_at') or m.get('created_at') or ''
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(when.replace('Z', '+00:00'))).total_seconds() if when else 0
        none_yet, has = _no_ci()
        waited = 0
        # poll 15 s with progress, <= max_wait (a tool timeout kills a silent sleep)
        while none_yet and age + waited <= 300 and waited + 15 <= max_wait:
          _progress(f'no pipeline on !{iid} yet; checking again in 15 s ({int(300 - age - waited)} s until it counts as no CI)')
          time.sleep(15)
          waited += 15
          none_yet, has = _no_ci()
        if has:
          st = 'running'
        # CI config, no head pipeline (rules skipped it / never started): never merge without CI
        if none_yet and age + waited > 300:
          return (f'no pipeline for the head of !{iid} although the repo has CI (rules skipped it, or it never started): '
              f'run the pipeline, then merge again; or the coordinator merges by hand\nNOT_MERGED')
        if not has and not no_ci:
          left = int(max(30, 310 - age - waited)) if none_yet else 60
          return f'WAIT: no pipeline on !{iid} yet (a pipeline is still expected); run merge again in {left} s\nWAIT'
    if st == 'manual' or st == 'skipped':   # merge-when-green never fires: not SCHEDULED
      return f'pipeline {st} on !{iid}: start its manual jobs (or ask the coordinator), then run merge again\nNOT_MERGED'
    if st == 'scheduled':
      return f'pipeline scheduled (delayed job) on !{iid}: run merge again once it runs\nWAIT'
    if st != 'success' and not no_ci:
      args += ['-f', 'merge_when_pipeline_succeeds=true']
    put = _json(_run([GLAB, 'api', '-X', 'PUT', f'projects/{enc}/merge_requests/{iid}/merge', *args]))
    return _gitlab_final(enc, proj, iid, put, st)
  out = _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch', '--auto'], cwd=worktree)
  if 'clean status' in out.lower():   # no required checks: auto-merge refused; merge only on finished green CI
    pv = _json(_run([GH, 'pr', 'view', str(iid), '--json', 'statusCheckRollup'], cwd=worktree))
    roll = pv.get('statusCheckRollup') if isinstance(pv, dict) else None
    cs = [r.get('conclusion') or r.get('state') for r in roll or []]
    if roll is None or any(c in ('FAILURE', 'CANCELLED', 'ERROR', 'TIMED_OUT') for c in cs):
      return f'#{iid}: checks unreadable or failed: {str(pv)[:200]}\n' + ('PIPELINE_FAILED' if roll else 'WAIT')
    if (not cs and _gh_workflows(worktree)) or any(c not in ('SUCCESS', 'NEUTRAL', 'SKIPPED') for c in cs):
      return f'#{iid}: workflows still running (or not started yet), no required checks: run merge again in a few minutes\nWAIT'
    out = _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch'], cwd=worktree)
  v = _json(_run([GH, 'pr', 'view', str(iid), '--json', 'state,mergeable,autoMergeRequest,statusCheckRollup'], cwd=worktree))
  concl = [r.get('conclusion') or r.get('state') for r in v.get('statusCheckRollup') or []]
  word = ('MERGED' if v.get('state') == 'MERGED' else 'SCHEDULED' if v.get('autoMergeRequest') else
      'CONFLICT' if v.get('mergeable') == 'CONFLICTING' else
      'PIPELINE_FAILED' if any(c in ('FAILURE', 'CANCELLED', 'ERROR', 'TIMED_OUT') for c in concl) else 'NOT_MERGED')
  return f'{out[:300] or f"#{iid}: {word.lower()}"}\n{word}'


def merge_when_green(worktree, iid, timeout_min=90):
  """Poll the pipeline; squash-merge when green, never on failure or conflict. Prefer auto_merge (no waiting)."""
  host, proj = remote(worktree)
  if held(proj):
    return f'{proj}!{iid} is held for approval (kit.local.json holdMerge)\nNOT_MERGED'
  waiting = unmerged_producers(proj, iid, lambda r, i: _host_mr_state(host, proj, r, i))
  if waiting:
    return '; '.join(f'waiting for producer {ref} ({st}; task {tid})' for ref, st, tid in waiting) + ': not merged\nWAIT'
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
      return 'already merged\nMERGED'
    if conflict:
      return 'CONFLICT: dev.ps1 wt sync, resolve (devtools.py keepboth for append-only files), re-check, push --force-with-lease to YOUR branch\nCONFLICT'
    if bad:
      return f'PIPELINE {st}: fix it, do not merge\nPIPELINE_FAILED'
    if host == 'gitlab' and st is None:   # no MR CI: auto_merge() decides
      res = auto_merge(worktree, iid)
      if merge_word(res) != 'WAIT':
        return res
    if ok:
      if host == 'gitlab':
        put = _json(_run([GLAB, 'api', '-X', 'PUT', f'projects/{enc}/merge_requests/{iid}/merge',
                 '-f', 'squash=true', '-f', 'should_remove_source_branch=true', *(['-f', f"sha={m['sha']}"] if m.get('sha') else [])]))
        return _gitlab_final(enc, proj, iid, put, st)
      out = _run([GH, 'pr', 'merge', str(iid), '--squash', '--delete-branch'], cwd=worktree)
      v = _json(_run([GH, 'pr', 'view', str(iid), '--json', 'state'], cwd=worktree))
      return f"{out[:300]}\n{'MERGED' if isinstance(v, dict) and v.get('state') == 'MERGED' else 'NOT_MERGED'}"
    time.sleep(60)
  return 'TIMEOUT waiting for pipeline\nWAIT'


# --- Documents (reports.type: gdocs | markdown)
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
  """markdown reports: keep a copy under <runtime>/work/docs (worktrees get removed); return its path."""
  d = kit_path('docs', create=True)
  slug = re.sub(r'[^A-Za-z0-9]+', '-', title).strip('-')[:80] or 'doc'
  dst = os.path.join(d, slug + os.path.splitext(path)[1])
  if os.path.abspath(dst) != os.path.abspath(path):
    shutil.copyfile(path, dst)
  return dst


def md_to_html(md, title=''):
  """Dependency-free Markdown -> HTML for `doc` (gws uploads Markdown as plain text): headings, tables, lists, emphasis, code,
    links, rules."""
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
  """Publish a document. gdocs: HTML (or Markdown) as a Google Doc, anyone-with-link reader; avoid '&' in titles.
    markdown: keep the file (.md / .html), return its path (attach: dev.ps1 tracker attach <task> <path>)."""
  if REPORT_TYPE != 'gdocs':
    return keep_doc(title, html_path)
  if not GWS:
    raise SystemExit('reports.type is gdocs but the gws CLI is not on PATH (or set "reports": {"type": "markdown"})')
  if html_path.lower().endswith(('.md', '.markdown')):   # Markdown would upload as plain text: convert first
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
  # gws uploads only cwd files: run in the file's folder
  cwd = os.getcwd()
  os.chdir(os.path.dirname(os.path.abspath(html_path)))
  try:
    r = gws('drive', 'files', 'create', params={'supportsAllDrives': True, 'fields': 'id,webViewLink'}, body=body, upload=os.path.basename(html_path))
  finally:
    os.chdir(cwd)
  if 'id' not in r:
    raise SystemExit(f'gws upload failed: {r}')
  url = f"https://docs.google.com/document/d/{r['id']}/edit"
  p = gws('drive', 'permissions', 'create', params={'fileId': r['id'], 'supportsAllDrives': True}, body={'type': 'anyone', 'role': 'reader'})
  if not (isinstance(p, dict) and p.get('id')):
    raise SystemExit(f'{url} was uploaded but not shared (anyone with the link): {str(p)[:300]} - share it by hand or fix gws auth')
  return url


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
    if re.search(r'^(<<<<<<<|>>>>>>>) ', text, re.M):   # a block the pattern missed: never report success
      print(path, 'STILL HAS CONFLICT MARKERS: resolve by hand', file=sys.stderr)
      left += 1
  return 1 if left else 0


def lbcheck(argv):
  """Liquibase sanity check: replays master.xml's changelogs in order (schema only, approximate); flags addColumn / createTable
of an existing column / table without guarding <preConditions>, and schema changeSets without <rollback>.
Reports files whose name timestamp >= since (yyyyMMddHHmmss; default all) plus basenames in env LBCHECK_CHANGED ('|'-separated;
dev.ps1 check passes recently changed changelogs, so untimestamped names are checked too). Includes resolve against the
including file, the classpath root (above 'config/liquibase/...', else 'resources') or master.xml's folder.
Prints one line per issue, then 'ISSUES <n>'; exit 1 when n > 0."""
  sys.stdout.reconfigure(encoding='utf-8')
  MASTER = os.path.abspath(argv[0])
  SINCE = argv[1] if len(argv) > 1 else '0'
  MASTER_DIR = os.path.dirname(MASTER)
  # classpath root: .../resources of .../resources/config/liquibase/master.xml
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
      # CI rule: a changeSet commented not reversible still needs a NON-EMPTY <rollback>; ET drops comments: scan raw text
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
        if f.lower().endswith('.xml'):   # .sql / .yaml includes are valid Liquibase: not a PARSE ERROR
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
  """Offline checks (missing body file refused; mergeAfter finds producers, warns on an unmatched repo name; merge_word).
    Exit 0 = all pass."""
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
  # CI gate: CI + no head pipeline after 5 min -> NOT_MERGED; failed query -> WAIT; never a merge
  g = globals()
  saved = {k: g[k] for k in ('_run', 'remote', 'unmerged_producers', '_progress')}
  old = '2020-01-01T00:00:00Z'
  puts = []
  def canned(pls):
    def run(cmd, cwd=None, check=False):
      s = ' '.join(str(c) for c in cmd)
      if '-X PUT' in s:
        puts.append(s)
        return '{"merged":"yes"}'
      if s.endswith('merge_requests/7'):
        return json.dumps({'state': 'opened', 'sha': 'abc', 'source_branch': 'f/x', 'target_branch': 'main', 'updated_at': old})
      if 'merge_requests/7/pipelines' in s:
        return pls
      if 'pipelines?ref=' in s:
        return '[]'
      if s.endswith('projects/g%2Fr'):
        return '{"id": 1}'
      return '{"file_name": ".gitlab-ci.yml"}'   # has a CI file
    return run
  try:
    g['remote'] = lambda wt: ('gitlab', 'g/r'); g['unmerged_producers'] = lambda *a, **k: []; g['_progress'] = lambda m: None
    g['_run'] = canned('[]')
    expect('CI repo, no head pipeline after 5 min: NOT_MERGED, no merge call', merge_word(auto_merge('.', '7', max_wait=0)) == 'NOT_MERGED' and not puts)
    g['_run'] = canned('error: 500 Internal Server Error')
    expect('a failed pipeline query is WAIT, no merge call', merge_word(auto_merge('.', '7', max_wait=0)) == 'WAIT' and not puts)
  finally:
    g.update(saved)
  expect('lbcheck has its XML parser (ET imported)', 'ET' in g)
  # batch 2: holdMerge, unreadable tracking, GitHub clean status + running workflows, share failure, lost intent
  saved = {k: g[k] for k in ('_run', 'remote', 'unmerged_producers', 'gws', 'REPORT_TYPE', 'GWS', 'kit_path')}
  cfg0 = dict(CFG)
  try:
    g['remote'] = lambda wt: ('gitlab', 'g/web'); g['_run'] = lambda *a, **k: puts.append('called') or '{}'
    CFG['holdMerge'] = ['web']; puts.clear()
    expect('holdMerge: a held repo is NOT_MERGED, no host call', merge_word(auto_merge('.', '7')) == 'NOT_MERGED' and not puts)
    CFG.pop('holdMerge', None)
    fd, bad = tempfile.mkstemp(suffix='.json'); os.write(fd, b'{broken'); os.close(fd)
    w = saved['unmerged_producers']('g/web', '7', lambda r, i: 'merged', tracking=bad); os.remove(bad)
    expect('an unreadable tracking file is a wait, not "no producers"', len(w) == 1 and 'unreadable' in w[0][0])
    g['unmerged_producers'] = lambda *a, **k: []
    g['remote'] = lambda wt: ('github', 'o/web')
    def ghrun(cmd, cwd=None, check=False):
      s = ' '.join(str(c) for c in cmd)
      if '--auto' in s:
        return 'Pull request #7 is in clean status'
      if 'statusCheckRollup' in s and 'state,' not in s:
        return '{"statusCheckRollup": [{"status": "IN_PROGRESS", "conclusion": ""}]}'
      puts.append(s)
      return '{}'
    g['_run'] = ghrun; puts.clear()
    expect('GitHub clean status with a running workflow: WAIT, no direct merge', merge_word(auto_merge('.', '7')) == 'WAIT' and not any('pr merge' in p for p in puts))
    g['REPORT_TYPE'] = 'gdocs'; g['GWS'] = 'gws'
    g['gws'] = lambda *a, **k: {'id': 'D1'} if 'files' in a else {'error': 'insufficient permissions'}
    fd, md = tempfile.mkstemp(suffix='.html'); os.close(fd)
    try:
      make_doc('t', md); expect('a doc that could not be shared is refused', False)
    except SystemExit as e:
      expect('a doc that could not be shared is refused', 'not shared' in str(e))
    os.remove(md)
    g['kit_path'] = lambda n: os.path.join(tempfile.gettempdir(), 'no-such-dir-kit', 'x', 'tracking.json')
    err = io.StringIO()
    with _c.redirect_stderr(err):
      _remember_automerge('web!7')
    expect('a lost merge-when-green intent is reported', 'could not record' in err.getvalue())
  finally:
    g.update(saved); CFG.clear(); CFG.update(cfg0)
  print(f'{fails} failure(s)')
  return 1 if fails else 0



# ===== migrations: local env migration audit (run by localenv.ps1). LIGHT changeSets revert when their layer leaves; HEAVY need a snapshot.
#   python devtools.py migrations classify --repo <checkout> --base <ref> --head <sha> [--config <json file>] [--under a,b] [--save <dir>]
#   python devtools.py migrations plan --leaving <manifest.json,..> [--staying <manifest.json,..>] [--repo <worktree>] [--out <dir>]
#   python devtools.py migrations rules [--config <json file>] | migrations selftest. Exit: 0 ok · 1 error · 2 usage.
# classify: migration files (config "pattern", below --under) changed merge-base..head -> { class: light|heavy|none, changesets:
#   [ { file, path, id, author, hash, status, class, rule, why, guarded, creates, refs } ], reasons }; --save: manifest.json + files/.
# plan: leaving changeSets absent from --repo / staying manifests -> { revert (newest first), kept, blocked }; --out: revert.json,
#   files/ (changelogs cut to the reverts), localenv-revert.xml. Rules: DEFAULT_RULES ("rules" replaces, "extraRules" first; first
#   match decides; none = light). Parsers: Liquibase XML/YAML/JSON/SQL + config "parsers" [ { match, parser | cmd } ]; unparsed = HEAVY.
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
  'pattern': r'(?i)(^|/)(db/)?(changelog|migrations?|liquibase|flyway|alembic)(/|\.)',
  'logicalRoot': r'^(?:.*/)?src/main/resources/',   # classpath path (DATABASECHANGELOG.FILENAME)
  'smallDataRows': 20,
  'referenceTables': r'(?i)(^|_)(ref|lookup|types?|status(es)?|configs?|settings?|authorit(y|ies)|permissions?|roles?|menus?|features?|translations?)$',
  'heavySql': [r'\bDROP\s+(TABLE|COLUMN|DATABASE|SCHEMA)\b', r'\bTRUNCATE\b', r'\bMODIFY\b', r'\bCHANGE\s+(COLUMN\s+)?\w',
        r'\bDELIMITER\b', r'\bCREATE\s+(DEFINER|PROCEDURE|FUNCTION|TRIGGER|EVENT)\b', r'\bRENAME\s+TABLE\b',
        r'\bALTER\s+TABLE\b.*\bDROP\s+(?!(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK|PRIMARY\s+KEY|DEFAULT)\b)[`"]?\w',
        r'\bON\s+DUPLICATE\s+KEY\s+UPDATE\b', r'\bREPLACE\s+INTO\b', r'\bWHERE\s+(1\s*=\s*1|TRUE|1)\s*$'],
  'lightSql': [r'^SET\s', r'^ALTER\s+TABLE\s+\S+\s+(ADD|RENAME|DROP\s+(INDEX|KEY|FOREIGN\s+KEY|CONSTRAINT|CHECK))\b',
        r'^CREATE\s+(UNIQUE\s+|FULLTEXT\s+)?INDEX\b', r'^CREATE\s+TABLE\b', r'^CREATE\s+(OR\s+REPLACE\s+)?VIEW\b',
        r'^DROP\s+(INDEX|VIEW)\b', r'^INSERT\s+(IGNORE\s+)?INTO\b', r'^UPDATE\b.+\bWHERE\b', r'^DELETE\s+FROM\b.+\bWHERE\b'],
}
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
    with open(path, encoding='utf-8-sig') as f:
      user = json.load(f) or {}
    cfg.update({k: v for k, v in user.items() if v is not None})
  rules = cfg.get('rules') or DEFAULT_RULES
  cfg['rules'] = list(cfg.get('extraRules') or []) + list(rules)
  return cfg


def git(repo, *a, ok=False):
  p = subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, encoding='utf-8', errors='replace')
  if p.returncode and not ok:
    raise SystemExit(f'git {" ".join(a)}: {p.stderr.strip()}')
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
  if t == 'createTable':
    c['creates'] = [tbl] + [f'{tbl}.{x}' for x in cols]
  elif t == 'addColumn':
    c['creates'] = [f'{tbl}.{x}' for x in cols]; c['refs'] = [tbl]
  elif t == 'createView':
    c['creates'] = [tbl]
  elif t == 'renameColumn':
    c['creates'] = [f'{tbl}.{attrs.get("newColumnName", "").lower()}']; c['refs'] = [tbl, f'{tbl}.{attrs.get("oldColumnName", "").lower()}']
  elif t == 'renameTable':
    c['creates'] = [attrs.get('newTableName', '').lower()]; c['refs'] = [attrs.get('oldTableName', '').lower()]
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
    if isinstance(col, dict) and col.get('name'):
      cols.append(str(col['name']).lower())
  cols += [x for k in ('columnName', 'columnNames') for x in split_names(str(body.get(k) or ''))]
  return change_from(t, {k: str(v) for k, v in body.items() if not isinstance(v, (list, dict))}, cols, str(body.get('where') or ''), str(body.get('sql') or ''))


# --- parsers: text -> [ changeset ]
def cs_record(id_, author, attrs, changes, rb_state, rb_changes, on_fail, raw):
  return {'id': str(id_), 'author': str(author), 'attrs': {k: str(v) for k, v in attrs.items()}, 'changes': changes,
      'rollback': rb_state, 'rollbackChanges': rb_changes, 'onFail': on_fail or '', 'hash': h(raw)}


def parse_xml(text):
  root = ET.fromstring(text.lstrip('﻿').encode('utf-8'))
  if local(root.tag) != 'databaseChangeLog':
    raise ValueError('not a Liquibase XML changelog')
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
      elif t == 'preConditions':
        on_fail = ch.get('onFail', 'HALT')
      elif t not in NON_CHANGE:
        changes.append(xml_change(ch))
    out.append(cs_record(cs.get('id'), cs.get('author'), cs.attrib, changes, rb, rbc, on_fail, raws[i] if i < len(raws) else ET.tostring(cs, encoding='unicode')))
  return out


def parse_struct(doc):
  out = []
  for item in (doc or {}).get('databaseChangeLog') or []:
    cs = item.get('changeSet') if isinstance(item, dict) else None
    if not isinstance(cs, dict):
      continue
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
    if not m:
      continue
    author, id_, rest = m.group(1) or m.group(2), m.group(3), m.group(4)
    attrs = dict(re.findall(r'(\w+):(\S+)', rest))
    rb_lines = [l.split('rollback', 1)[1].strip() for l in body.splitlines() if re.match(r'\s*--\s*rollback\b', l)]
    rb = 'missing' if not rb_lines else ('empty' if all(not x or re.match(r'(?i)not\s+required|empty', x) for x in rb_lines) else 'present')
    on_fail = (re.search(r'(?im)^--\s*preconditions\s+.*onFail:(\w+)', body) or [None, ''])[1]
    sql = '\n'.join(l for l in body.splitlines() if not re.match(r'\s*--', l))
    out.append(cs_record(id_, author, attrs, [change_from('sql', {}, [], '', sql)], rb, ['sql'] if rb == 'present' else [], on_fail, b))
  return out


def parse(path, text, cfg):
  """-> (changesets or None, why-not, parser)"""
  for p in cfg.get('parsers') or []:
    if re.search(p.get('match', '$^'), path):
      if p.get('cmd'):
        r = subprocess.run(f'{p["cmd"]} "{path}"', shell=True, capture_output=True, text=True, input=text)
        if r.returncode:
          return None, f'parser command failed: {r.stderr.strip()[:200]}', 'cmd'
        return json.loads(r.stdout).get('changesets', []), '', 'cmd'
      if p.get('parser') == 'heavy':
        return None, f'parser "heavy" set for {path}', 'heavy'
      return run_parser(p.get('parser'), path, text)
  ext = os.path.splitext(path)[1].lower()
  if ext == '.xml':
    return run_parser('liquibase-xml', path, text)
  if ext in ('.yaml', '.yml'):
    return run_parser('liquibase-yaml', path, text)
  if ext == '.json':
    return run_parser('liquibase-json', path, text)
  if ext == '.sql':
    if re.match(r'\s*--\s*liquibase\s+formatted\s+sql', text, re.I):
      return run_parser('liquibase-sql', path, text)
    return None, FILE_RULES['raw-sql-file'], 'raw-sql-file'
  return None, f'no parser for {ext or "this file"}', 'unparsed'


def run_parser(name, path, text):
  try:
    fn = {'liquibase-xml': parse_xml, 'liquibase-yaml': parse_yaml, 'liquibase-json': lambda t: parse_struct(json.loads(t)),
       'liquibase-sql': parse_formatted_sql}[name]
    return fn(text), '', name
  except KeyError:
    return None, f'unknown parser {name}', 'unparsed'
  except Exception as ex:  # noqa: BLE001 - any parse failure makes the file HEAVY
    return None, f'{name} parse failed: {str(ex)[:160]}', 'unparsed'


# --- rules
def setting(v, cfg):
  return cfg.get(v[1:]) if isinstance(v, str) and v.startswith('@') else v


def sql_unsafe(body, cfg):
  s = re.sub(r'/\*.*?\*/', ' ', body or '', flags=re.S)
  s = '\n'.join(l for l in s.splitlines() if not l.strip().startswith('--'))
  for stmt in (norm(x) for x in s.split(';')):
    if not stmt:
      continue
    if any(re.search(p, stmt, re.I) for p in cfg['heavySql']) or not any(re.search(p, stmt, re.I | re.S) for p in cfg['lightSql']):
      return stmt[:90]
    if re.match(r'(?i)INSERT\b', stmt) and len(re.findall(r'\)\s*,\s*\(', stmt)) + 1 > int(cfg['smallDataRows']):
      return f'{stmt[:60]}... (over smallDataRows rows)'
    m = re.match(r'(?i)DELETE\s+FROM\s+[`"]?(?:\w+\.)?(\w+)', stmt)
    if m and not re.search(cfg['referenceTables'], m.group(1)):
      return stmt[:90]
  return None


def match(rule, item, ctx, cfg):
  """item: the changeset (scope changeset) or one change; ctx: { cs, created, rows }"""
  cs = ctx['cs']
  for k, want in rule.items():
    want = setting(want, cfg)
    if k in ('id', 'class', 'why', 'scope'):
      continue
    if k == 'status' and not re.search(want, cs['status']):
      return False
    if k == 'attr' and not all(re.search(p, cs['attrs'].get(a, '')) for a, p in want.items()):
      return False
    if k == 'rollback' and cs['rollback'] != want:
      return False
    if k == 'onlyTag' and (all(c['type'] == 'tagDatabase' for c in cs['changes'])) != want:
      return False
    if k == 'autoRollback' and (all(c['type'] in AUTO for c in cs['changes'])) != want:
      return False
    if k == 'onFail' and not re.search(want, cs['onFail']):
      return False
    if k == 'change' and not re.search(want, item.get('type', '')):
      return False
    if k == 'known' and (item.get('type') in KNOWN) != want:
      return False
    if k == 'createdHere':
      t = item.get('table', '')
      targets = [t] if item.get('type') in ('dropTable', 'createTable') or not item.get('columns') else [f'{t}.{c}' for c in item['columns']]
      if all(x in ctx['created'] or x.split('.')[0] in ctx['created'] for x in targets) != want:
        return False
    if k == 'where' and item.get('where') != want:
      return False
    if k == 'table' and not re.search(want, item.get('table', '')):
      return False
    if k == 'rowsOver' and ctx['rows'].get(item.get('table'), 0) <= int(want):
      return False
    if k == 'sqlUnsafe':
      ctx['stmt'] = sql_unsafe(item.get('sql'), cfg)
      if bool(ctx['stmt']) != want:
        return False
  return True


def judge(cs, created, cfg):
  """-> (class, rule id, why) of one changeset"""
  rows = {}
  for c in cs['changes']:
    if c['type'] == 'insert':
      rows[c['table']] = rows.get(c['table'], 0) + 1
  ctx = {'cs': cs, 'created': created, 'rows': rows, 'stmt': ''}
  items = [('changeset', cs)] + [('change', c) for c in cs['changes']]
  for scope, item in items:
    for r in cfg['rules']:
      rs = r.get('scope') or 'change'
      if rs != scope or not match(r, item, ctx, cfg):
        continue
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


def classify(a, cfg):
  repo = a.repo
  mb = (git(repo, 'merge-base', a.base, a.head, ok=True) or '').strip() or a.base
  under = [u.strip().strip('/').replace('\\', '/') for u in (a.under or '').split(',') if u.strip()]
  tok = (git(repo, 'diff', '--name-status', '-z', '-M', mb, a.head) or '').split('\0')
  rows, i = [], 0
  while i < len(tok) and tok[i]:
    n = 3 if tok[i][0] in 'RC' else 2   # R<score>\0old\0new, else <st>\0path
    rows.append(tok[i:i + n]); i += n
  out, reasons, files, created = [], [], [], set()
  parsed = []
  for r in rows:
    st, path, old = r[0][0], r[-1], r[1] if len(r) > 2 else r[1]
    if not re.search(cfg['pattern'], path) or (under and not any(path == u or path.startswith(u + '/') for u in under)):
      continue
    head_text = git(repo, 'show', f'{a.head}:{path}', ok=True) if st != 'D' else None
    base_text = git(repo, 'show', f'{mb}:{old}', ok=True) if st in 'MRD' else None
    files.append({'path': path, 'logical': logical(path, cfg), 'status': st})
    parsed.append((st, path, old, head_text, base_text))
  for st, path, old, head_text, base_text in parsed:
    lp = logical(path, cfg)
    if (st != 'D' and head_text is None) or (st in 'MRD' and base_text is None):
      out.append({'file': lp, 'path': path, 'id': '*', 'author': '', 'hash': '', 'status': 'unparsed', 'class': 'heavy', 'rule': 'unparsed',
            'why': FILE_RULES['unparsed'].format(why='git show could not read it'), 'guarded': False, 'creates': [], 'refs': [], 'changes': []})
      continue
    new_cs, why_h, _ = parse(path, head_text, cfg) if head_text is not None else ([], '', '')
    old_cs, why_b, _ = parse(old, base_text, cfg) if base_text is not None else ([], '', '')
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
      if (c['id'], c['author']) not in {(x['id'], x['author']) for x in new_cs}:
        c['status'] = 'removed'; new_cs.append(c)
    for c in new_cs:
      if c['status'] == 'same':
        continue
      c.update({'file': lp, 'path': path})
      out.append(c)
  for c in out:   # file order: only EARLIER changeSets' objects count as "created here"
    if c['id'] == '*':
      continue
    c['class'], c['rule'], c['why'] = judge(c, created, cfg)
    if c['status'] == 'added':
      for ch in c['changes']:
        created.update(ch['creates'])
    c['guarded'] = bool(re.search(r'(?i)MARK_RAN|CONTINUE', c['onFail']))
    c['creates'] = sorted({x for ch in c['changes'] for x in ch['creates']})
    c['refs'] = sorted({x for ch in c['changes'] for x in ch['refs']} - set(c['creates']))
  for c in out:
    if c['class'] == 'heavy':
      reasons.append(f"{c['file']}::{c['id']} {c['rule']}: {c['why']}")
  res = {'repo': repo, 'base': a.base, 'mergeBase': mb, 'head': a.head, 'class': 'none' if not out else ('heavy' if reasons else 'light'),
     'reasons': reasons, 'files': files,
     'changesets': [{k: c.get(k) for k in ('file', 'path', 'id', 'author', 'hash', 'status', 'class', 'rule', 'why', 'guarded', 'creates', 'refs')} | {'types': [ch['type'] for ch in c.get('changes', [])]} for c in out]}
  if a.save:
    os.makedirs(os.path.join(a.save, 'files'), exist_ok=True)
    for f in files:
      t = git(repo, 'show', f'{a.head}:{f["path"]}', ok=True)
      if t is not None:
        dst = os.path.join(a.save, 'files', *f['logical'].split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'w', encoding='utf-8', newline='') as fh:
          fh.write(t)
    res['saved'] = os.path.abspath(a.save)
    with open(os.path.join(a.save, 'manifest.json'), 'w', encoding='utf-8') as fh:
      json.dump(res, fh, indent=1)
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
      if m and ((m.group(3), m.group(1) or m.group(2)) in ids):
        kept.append(p)
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
            cs, _, _ = parse(f, open(p, encoding='utf-8').read(), cfg) if os.path.exists(p) else ([], '', '')
          except OSError:
            cs = []
          in_tree[f] = {(c['id'], c['author']): c['hash'] for c in cs or []}
  revert, kept = [], []
  for m in reversed(leaving):   # newest layer first, its changeSets newest first
    for c in reversed(m.get('changesets', [])):
      if c['id'] == '*' or c['status'] == 'removed':
        continue
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
      if hit:
        blocked.append({'key': key(c), 'layer': m.get('layer') or os.path.dirname(m['_path']), 'uses': hit})
  res = {'revert': [{k: c[k] for k in ('file', 'path', 'id', 'author', 'hash', 'guarded', 'layer')} for c in revert], 'kept': kept, 'blocked': blocked, 'count': len(revert)}
  if a.out and revert:
    fd = os.path.join(a.out, 'files')
    os.makedirs(fd, exist_ok=True)
    by_file = {}
    for c in revert:
      by_file.setdefault((c['file'], c['path']), set()).add((c['id'], c['author']))
    src_dirs = {c['file']: m.get('saved') for m in leaving for c in m.get('changesets', [])}
    for (lf, path), ids in by_file.items():
      src = os.path.join(src_dirs.get(lf) or '', 'files', *lf.split('/'))
      text = open(src, encoding='utf-8').read() if os.path.exists(src) else ''
      dst = os.path.join(fd, *lf.split('/'))
      os.makedirs(os.path.dirname(dst), exist_ok=True)
      with open(dst, 'w', encoding='utf-8', newline='') as fh:
        fh.write(cut_file(text, path, ids))
    inc = ''.join(f'  <include file="{lf}" relativeToChangelogFile="false"/>\n' for lf, _ in by_file)
    with open(os.path.join(fd, 'localenv-revert.xml'), 'w', encoding='utf-8') as fh:
      fh.write('<?xml version="1.0" encoding="UTF-8"?>\n<databaseChangeLog xmlns="http://www.liquibase.org/xml/ns/dbchangelog" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog '
          'http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">\n' + inc + '</databaseChangeLog>\n')
    res['searchPath'] = os.path.abspath(fd); res['changelog'] = 'localenv-revert.xml'
    with open(os.path.join(a.out, 'revert.json'), 'w', encoding='utf-8') as fh:
      json.dump(res, fh, indent=1)
    res['manifest'] = os.path.abspath(os.path.join(a.out, 'revert.json'))
  return res


def mig_main(argv):
  ap = argparse.ArgumentParser(prog='devtools.py migrations')
  ap.add_argument('cmd', choices=['classify', 'plan', 'rules'])
  for o in ('--repo', '--base', '--head', '--config', '--under', '--save', '--leaving', '--staying', '--out'):
    ap.add_argument(o)
  a = ap.parse_args(argv)
  cfg = load_cfg(a.config)
  if a.cmd == 'rules':
    res = {'rules': cfg['rules'], **{k: cfg[k] for k in DEFAULTS}}
  elif a.cmd == 'classify':
    res = classify(a, cfg)
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
                    '<dropColumn tableName="orders" columnName="note"/>', pre='<preConditions onFail="MARK_RAN"><not><columnExists tableName="orders" columnName="note"/></not></preConditions>'),
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
        self.heavy('dropcol', '<dropColumn tableName="orders" columnName="qty"/>', 'drop-data', '<addColumn tableName="orders"><column name="qty" type="INT"/></addColumn>')
        self.heavy('droptable', '<dropTable tableName="orders"/>', 'drop-data', '<sql>CREATE TABLE orders (id BIGINT)</sql>')
        self.heavy('unbounded', '<update tableName="orders"><column name="qty" valueNumeric="0"/></update>', 'unbounded', '<sql>UPDATE orders SET qty = NULL WHERE 1=0</sql>')
        self.heavy('delrows', '<delete tableName="orders"><where>qty = 0</where></delete>', 'delete-rows', '<sql>SELECT 1</sql>')
        self.heavy('emptyrb', '<addColumn tableName="orders"><column name="x" type="INT"/></addColumn>', 'empty-rollback', '')
        self.heavy('norb', '<sql>ALTER TABLE orders ADD COLUMN y INT</sql>', 'no-rollback', None)
        self.heavy('always', '<sql>ALTER TABLE orders ADD COLUMN z INT</sql>', 'runs-always', '<sql>ALTER TABLE orders DROP INDEX z</sql>', attrs=' runAlways="true"')
        self.heavy('rawsql', '<sql>ALTER TABLE orders MODIFY qty BIGINT</sql>', 'raw-sql', '<sql>ALTER TABLE orders MODIFY qty INT</sql>')
        self.heavy('retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="SMALLINT"/>', 'retype', '<modifyDataType tableName="orders" columnName="qty" newDataType="INT"/>')
        self.heavy('loaddata', '<loadData tableName="orders" file="x.csv"/>', 'bulk-file', '<sql>SELECT 1</sql>')

    def test_order_and_sql_gaps_are_heavy(self):
        # drop an existing column, add it back later: the first changeSet still drops data
        sha = self.r.branch('dropreadd', {f'{CL}/20260402000000_x.xml': xml(
            cs('20260402000000-1', '<dropColumn tableName="orders" columnName="qty"/>', '<addColumn tableName="orders"><column name="qty" type="INT"/></addColumn>'),
            cs('20260402000000-2', '<addColumn tableName="orders"><column name="qty" type="INT"/></addColumn>'))})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'drop-data'), res['reasons'])
        # CREATE TABLE IF NOT EXISTS then a drop of it: the table may have existed
        sha = self.r.branch('ifnot', {f'{CL}/20260403000000_x.xml': xml(
            cs('20260403000000-1', '<sql>CREATE TABLE IF NOT EXISTS orders (id BIGINT)</sql>', '<sql>SELECT 1</sql>'),
            cs('20260403000000-2', '<dropTable tableName="orders"/>', '<sql>CREATE TABLE orders (id BIGINT)</sql>'))})
        self.assertEqual(self.r.classify(sha)['changesets'][1]['rule'], 'drop-data')
        for name, body in (('altdrop', 'ALTER TABLE orders ADD note INT, DROP qty'), ('upsert', 'INSERT INTO orders (id) VALUES (1) ON DUPLICATE KEY UPDATE qty = 0'),
                           ('trivwhere', 'UPDATE orders SET qty = 0 WHERE 1=1')):
            self.heavy(name, f'<sql>{body}</sql>', 'raw-sql', '<sql>SELECT 1</sql>')
        self.heavy('trivxml', '<update tableName="orders"><column name="qty" valueNumeric="0"/><where>1=1</where></update>', 'unbounded', '<sql>SELECT 1</sql>')

    def test_non_ascii_path_is_read(self):
        sha = self.r.branch('uml', {f'{CL}/20260404000000_bestellung_\u00e4.xml': xml(cs('20260404000000-1', '<dropTable tableName="orders"/>', '<sql>CREATE TABLE orders (id BIGINT)</sql>'))})
        self.assertEqual(self.r.classify(sha)['class'], 'heavy')

    def test_drop_own_is_light(self):
        sha = self.r.branch('dropown', {f'{CL}/20260401000000_own.xml': xml(
            cs('20260401000000-1', '<addColumn tableName="orders"><column name="tmp" type="INT"/></addColumn>'),
            cs('20260401000000-2', '<dropColumn tableName="orders" columnName="tmp"/>', '<addColumn tableName="orders"><column name="tmp" type="INT"/></addColumn>'))})
        self.assertEqual(self.r.classify(sha)['class'], 'light')

    def test_edit_applied_and_raw_file(self):
        base = f'{CL}/20260101000000_base.xml'
        sha = self.r.branch('edit', {base: xml(TAG('20260101000000'), cs('20260101000000-1', '<createTable tableName="orders"><column name="id" type="BIGINT"/></createTable>'))})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'edits-applied'))
        sha = self.r.branch('rawfile', {'api/src/main/resources/db/migrations/V2__x.sql': 'UPDATE orders SET qty = 1;'})
        res = self.r.classify(sha)
        self.assertEqual((res['class'], res['changesets'][0]['rule']), ('heavy', 'raw-sql-file'))

    def test_mixed_is_heavy_and_names_the_changeset(self):
        sha = self.r.branch('mixed', {f'{CL}/20260501000000_mixed.xml': xml(
            TAG('20260501000000'), cs('20260501000000-1', '<addColumn tableName="orders"><column name="ok" type="INT"/></addColumn>'),
            cs('20260501000000-2', '<delete tableName="orders"/>', '<sql>SELECT 1</sql>'))})
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
        sha = self.r.branch('cfg', {f'{CL}/20260801000000_x.xml': xml(cs('20260801000000-1', '<delete tableName="orders"><where>id = 1</where></delete>', '<sql>SELECT 1</sql>'))})
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

Example finding: `{"id": "NOTIF-BUG-002", "module": "Notifications", "layer": "Node API", "type": "Bug", "in_scope": "Yes",
"subtype": "Data Integrity", "title": "Digest emails ignore the user's unsubscribe flag", "area": "Settings / Email
preferences",
"severity": "High", "current": "Opted-out users still receive the weekly digest.", "expected": "Opted-out users never receive
it.",
"business_impact": "Unwanted email to users who opted out.", "root_cause": "The digest job never reads the per-user flag.",
"why_today": "(inferred) The flag was added after the job.", "why_not_prod": "(inferred) Few users opted out so far.",
"customer_impact": "Opted-out users keep getting the digest.", "db_migration": "No", "suggested_fix": "Filter on the opt-out
flag; add a test.",
"code_location": "DigestJob.buildRecipients()", "product_decision": "No", "effort": "Low", "existing_notes": "Evidence: 3 of 3
opted-out test users got it.", "source": "module review"}`

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

# validate (exit 1 on a problem): JSON array, 23 string keys, vocab, unique ids, in-scope triage filled, out-of-scope analysis
# empty. summary: <module>-summary.md (chat / MR) + .html (share via doc).
def validate(argv):

  KEYS = ['id', 'module', 'layer', 'type', 'in_scope', 'subtype', 'title', 'area', 'severity', 'current', 'expected',
      'business_impact', 'root_cause', 'why_today', 'why_not_prod', 'customer_impact', 'db_migration', 'suggested_fix',
      'code_location', 'product_decision', 'effort', 'existing_notes', 'source']
  VOCAB = {
    'type': {'Bug', 'Performance', 'Tech Debt', 'Functional Gap', 'UX', 'Reporting'},
    'in_scope': {'Yes', 'No'},
    'severity': {'Critical', 'High', 'Medium', 'Low'},
    'db_migration': {'Yes', 'No', 'Maybe', ''},
    'product_decision': {'Yes', 'No'},
    'effort': {'Low', 'Medium', 'High', ''},
  }
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
      if fid in seen:
        problems.append(f'{fid}: duplicate id')
      seen.add(fid)
      if not ID.match(fid):
        problems.append(f'{fid}: id should look like ABBR-BUG-001')
      for k, allowed in VOCAB.items():
        if o[k] not in allowed:
          problems.append(f'{fid}: {k}={o[k]!r} not in {sorted(allowed)}')
      if o['type'] in IN_SCOPE:
        if o['in_scope'] != 'Yes':
          problems.append(f'{fid}: {o["type"]} must be in_scope Yes')
        for k in ('root_cause', 'why_today', 'why_not_prod', 'db_migration', 'code_location'):
          if not o[k]:
            problems.append(f'{fid}: in-scope finding needs {k}')
        if o['severity'] == 'Critical' and o['current'].startswith('(unverified)'):
          problems.append(f'{fid}: unverified finding cannot be Critical')
      else:
        if o['in_scope'] != 'No' or o['product_decision'] != 'Yes':
          problems.append(f'{fid}: {o["type"]} must be in_scope No, product_decision Yes')
        for k in ('root_cause', 'why_today', 'why_not_prod', 'customer_impact'):
          if o[k]:
            problems.append(f'{fid}: out-of-scope finding should leave {k} empty')
      if o['current'].startswith('(unverified)') and o['severity'] in ('Critical', 'High'):
        problems.append(f'{fid}: unverified findings are capped at Medium')

  for p in problems:
    print(p)
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
  md.append(f'**{len(ins)} in-scope findings** ({", ".join(f"{by_type[t]} {t}" for t in ("Bug", "Performance", "Tech Debt") if by_type[t])}) · '
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
  md += [f"| {r['id']} | {r['type']} | {r['severity']} | {r['title']} | {r['effort']} |" for r in sorted(ins, key=lambda r: (SEV.index(r['severity']), r['id']))]
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
  for s in SEV:
    fg, bg = COL[s]
    H.append(f"<td style='background:{bg};color:{fg};padding:8px 14px;text-align:center;border:1px solid #fff'><span style='font-size:18pt;font-weight:bold'>{by_sev[s]}</span><br><span style='font-size:8pt;font-weight:bold'>{s.upper()}</span></td>")
  H.append(f"<td style='background:#f3f4f6;color:#374151;padding:8px 14px;text-align:center;border:1px solid #fff'><span style='font-size:18pt;font-weight:bold'>{len(outs)}</span><br><span style='font-size:8pt;font-weight:bold'>OUT OF SCOPE</span></td></tr></table>")
  H.append(f"<p>{len(ins)} in-scope findings: " + ', '.join(f'{by_type[t]} {t}' for t in ('Bug', 'Performance', 'Tech Debt') if by_type[t]) +
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
        elif k == 'code_location':
          t.append(f"<td style='{cell};font-family:Consolas,monospace;font-size:9pt'>{v}</td>")
        else:
          t.append(f"<td style='{cell}'>{v}</td>")
      t.append('</tr>')
    return ''.join(t) + '</table>'

  if top:
    H.append(f"<h2 style='{h2}'>Critical and High</h2>" + table(top, [('ID', 'id'), ('Sev', 'severity'), ('Title', 'title'), ('Current', 'current'), ('Where', 'code_location'), ('Fix', 'suggested_fix')]))
  if decide:
    H.append(f"<h2 style='{h2}'>Needs a product decision</h2>" + table(decide, [('ID', 'id'), ('Title', 'title'), ('Expected', 'expected'), ('Business impact', 'business_impact')]))
  H.append(f"<h2 style='{h2}'>All in-scope findings</h2>" + table(sorted(ins, key=lambda r: (SEV.index(r['severity']), r['id'])),
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
  # per-command usage from the header; --help never becomes an id; unknown flags and missing args are usage errors
  use = [ln for ln in __doc__.splitlines() if re.match(rf'\s+python devtools\.py {re.escape(cmd)}\b', ln)] if cmd else []
  ARITY = {'task': 1, 'subtasks': 1, 'newtask': 5, 'status': 2, 'comment': 2, 'finish': 3, 'mr': 3, 'merge': 2, 'merge-wait': 2,
      'doc': 2, 'keepboth': 1, 'lbcheck': 1, 'findings': 1, 'migrations': 1, 'selftest': 0}
  FLAGS = {'findings': {'--sources', '--out'}}
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
  elif cmd == 'merge-wait':     # old: poll until merged (blocks up to 90 min)
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
  else:
    print(__doc__)
    sys.exit(2)
