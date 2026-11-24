"""devtools.py: tracker / git-host / docs helpers for agents (crafty steps 6-7). Host and project come from the worktree's
`origin` remote, the MR target from its crafty.ps1 wt record. Tracker reads and status changes: crafty.ps1 tracker.

 python -X utf8 devtools.py comment <taskId> --spec <c.json> [comment-solution|comment-status] (templates.md "Comment spec"; <file.md | "text"> [kind] warns) [--prose-ok "<why>"]   kind: comment-status (default), comment-deploy, decision-request ...
 python -X utf8 devtools.py finish <taskId> <testing.md|url|-> <solution.md> [review] [--ai <ai.md|url>] [--prose-ok "<why>"]   the docs given
  (process.gates.finish builtin:testingDocs: the required process.docs) by key after the local loop PASS, the description's links block, the solution comment (edits the last kit one), status;
  `cases` for a doc (finish <task> cases ... --ai cases, doc "<t>" cases --key <task>:testing-ai): rendered from the cases spec (a doc process.docs lacks: skipped)
 python -X utf8 devtools.py cases add|result|round|render|show <task> ...   the task's test cases (one spec, "render" section):
  goals file, AI doc and human doc rendered from it, never hand-written
 python -X utf8 devtools.py mr <worktree> --spec <mr.json> [target] [--prose-ok "<why>"] [--check]   open a merge/pull request from the current branch: title
  (mrTitleFormat) and body (templates.md "MR spec") rendered from the spec; the old form `mr <wt> "<title>" <body.md>` still works;
  --check: only the title / body gates, before the push (CHECK OK, nothing opened)
 python -X utf8 devtools.py spec write|link|gaps|show <task|subject> ...   the task's or a subject's spec doc (S-id rules, versioned,
  change log; Spec line on the task; finish refuses S-ids no case cites); spec --help: the JSON fields
 python -X utf8 devtools.py render <kind> <spec.json> [<out file>]   an artefact rendered from its spec (kinds: mr-title mr-body commit
  comment-solution comment-status final-report retro wave-brief; crafty.ps1 wt commit -Spec)
  comment / finish / mr: a text over its prose limits is refused (exit 1, nothing written); --prose-ok keeps a format the brief fixes
 finish / mr / doc --key <task>:testing-*: the prior-work gate (crafty.ps1 prior -Task <id> first); --override "<why>" passes, logged
 python -X utf8 devtools.py followups <findings.json> <mr url> ...   review findings that do not hold the merge -> each MR's "## Follow-ups"
 mr / merge [--scope "<glob>,.."] [--scope-ok <decision id>]: a diff outside the area (--scope, else the wt lease / new -Scope record)
  is refused naming the files (merge: the host's diff); --scope-ok = a person's decide record -Gate scope -Item <branch>, logged
 python -X utf8 devtools.py merge <worktree> <iid> [--override "<why>"] [--no-docs "<why>"]   merge now (per repos[].mergeMethod; green / no CI) or arm merge-when-green; waits <= 90 s;
  last line (read back): MERGED / SCHEDULED / WAIT (also: producer unmerged) / CONFLICT / PIPELINE_FAILED / NOT_MERGED (also: a bug fix
  whose AI testing doc has no local reproduction; --override passes, logged); --no-docs: an area with no human-facing change
  (brief kind foundation) passes the testing-docs gate, logged
 python -X utf8 devtools.py doc "<title>" <file.html|.md> [parent] [--type <t>] [--key <task|run>:<kind> [--mode append|replace] [--label <l>]]
  publish a document (reports.type); prints its URL/path; --key: the same doc every time (.state/published), a dated round each
  (same text: none; human doc: earlier rounds no env run tested show as one "Replaced drafts (not tested): <dates>" line)
  --run <cells.json> [--run-id <id>] (pokey finalize, key <task>:testing-doc): fills each human doc row's Result / Evidence from the
  checks that cover it (id, `case`, or a screen starting with the row id) over every run (the newest PASS / FAIL decides, each env
  named) + a dated "<env> run" section (same --run-id: replaced)
 python -X utf8 devtools.py docgaps --key <task>:testing-doc --run <cells.json> [--run-id <id>]   human doc row ids neither this run nor an earlier one covers
 python -X utf8 devtools.py relayout <key|doc url> ...   republish a --key doc with the current layout (cell-fit images): same rows and link
 python -X utf8 devtools.py evidence "<name>" [--parent <id>] [--folder <id>] [--files-from <list>] [--key <k>] <file> ...   host evidence files (gdocs: Drive; --key reuses its folder) -> JSON
 python -X utf8 devtools.py keepboth <file> [...]   append-only rebase conflicts: keep OURS then THEIRS
 python -X utf8 devtools.py selftest   offline self-test (and each installed plugin's)
Plugins: skills/crafty/adapters/*.py register report adapters and verbs (lbcheck: liquibase.py; findings: module_audit.py).
Exit codes: 0 ok · 1 problem (merge refused, conflict, check issues) · 2 usage error · 3 reports.type names no report adapter.
Sections: L55 config · L110 run · L198 tracker · L397 process · L608 git host · L681 scope · L773 MR · L988 merge · L1319 docs ·
  L1534 publish · L2032 render · L2610 spec · L3152 plugins · L3166 keepboth · L3185 selftest · L3906 CLI
Config (..\\kit.local.json): "tracker" (crafty.ps1 tracker, default none), "reports" + "driveParent" (doc / evidence:
kit.example.json reports._readme), "gitHost" / "githubHost" (self-hosted; default gitlab.com / github.com).
Windows: run from PowerShell (python hangs in git-bash); Linux/macOS: python3. CLIs are resolved with shutil.which.
"""
import contextlib, difflib, glob, html, importlib.util, io, json, os, re, shutil, subprocess, sys, tempfile, time, zlib
from datetime import datetime

KIT = os.path.dirname(os.path.abspath(__file__))  # crafty skill folder
KIT_DIR = os.path.dirname(os.path.dirname(KIT))   # the kit (.claude)
os.environ['GIT_OPTIONAL_LOCKS'] = '0'   # git probes never rewrite a repo's index (lib.ps1, kitbag.py too)
sys.path.insert(0, os.path.join(KIT_DIR, 'skills', 'bossy'))
from kitbag import kit_path, kit_stamp, locked, audited, state_read, state_write, task_index, task_file, read_tracking, kitlog   # one path map, lock, call log for all kit scripts


# ---- config: kit.local.json (a kit worktree reads the main clone's), report adapters, plugin verbs
def _cfg_file():
    own = os.path.join(KIT, 'kit.local.json')
    if os.path.exists(own):
        return own
    try:   # linked kit worktree: the main clone's
        cd = subprocess.run(['git', '-C', KIT, 'rev-parse', '--path-format=absolute', '--git-common-dir'], capture_output=True,
             text=True, encoding='utf-8', timeout=10).stdout.strip()
        alt = os.path.join(os.path.dirname(cd), 'skills', 'crafty', 'kit.local.json') if cd else ''
        return alt if alt and os.path.exists(alt) else own
    except Exception:
        return own


try:
    CFG = json.load(open(_cfg_file(), encoding='utf-8'))
except Exception:
    CFG = {}
try:   # vocab.json: the built-in vocabulary lib.ps1 reads too (statuses, tracker vendors, testing docs)
    VOCAB = json.load(open(os.path.join(KIT, 'vocab.json'), encoding='utf-8'))
except Exception:
    VOCAB = {}


def cfg(path, default=None):
    """kit.local.json value at a dotted path; missing / None / '' -> default (lib.ps1 Get-KitSetting)."""
    cur = CFG
    for p in path.split('.'):
        if not isinstance(cur, dict) or p not in cur:
            return default
        cur = cur[p]
    return default if cur is None or cur == '' or cur == [] else cur


def py_rx(rx):
    """A .NET regex (named groups (?<n>...)) -> Python's (?P<n>...)."""
    return re.sub(r'\(\?<(?=[A-Za-z_])', '(?P<', rx or '')


GWS = shutil.which('gws')
RCFG = CFG.get('reports') or {}
REPORT_TYPE = (os.environ.get('KIT_REPORT_TYPE') or RCFG.get('type') or 'markdown').lower()
ADAPTERS = {'report': {}}   # kind -> name -> {verb: fn(a)}
VERBS = {}                  # plugin CLI verbs: name -> fn(argv) -> exit code


def _todo(verb):
    raise SystemExit(f'adapter verb {verb} is a stub (kitbag.py new adapter): implement it first')


def no_report_adapter():
    """reports.type names no adapter (built in or skills/crafty/adapters/report_<type>.py): exit 3."""
    print(f'reports.type {REPORT_TYPE}: no such report adapter (skills/crafty/parity.json adapters.report)', file=sys.stderr)
    sys.exit(3)

# ---- run: CLI calls and their arguments
# reads retry transient errors (2 s, 6 s) in one deadline; writes never (a lost reply would duplicate)
TRANSIENT = re.compile(r'(?i)timed? ?out|connection (reset|refused|closed|aborted)|could not resolve|no such host|unreachable|dial tcp|\bEOF\b|TLS handshake|temporar|\b(429|500|502|503|504)\b|bad gateway|service unavailable|too many requests')
STOP_AT = [0.0]   # auto_merge's deadline


def _is_write(cmd):
    s = [str(c) for c in cmd[1:]]
    m = next((s[i + 1] for i, c in enumerate(s[:-1]) if c in ('-X', '--method')), 'GET')
    return m.upper() != 'GET' or any(w in s[:4] for w in ('create', 'merge', 'update', 'comment', 'note', 'edit', 'close', 'upload', 'delete'))


CMD_META = re.compile(r'[<>|&^%!"()]')


def _argv(cmd):
    """cmd.exe re-parses a .cmd / .bat shim's args (< > | & ^ % in user text redirect or vanish): run an npm shim's target directly."""
    exe = str(cmd[0])
    if os.name != 'nt' or not exe.lower().endswith(('.cmd', '.bat')):
        return cmd
    try:
        shim = open(exe, encoding='utf-8', errors='replace').read()
    except OSError:
        shim = ''
    dp0, m = os.path.dirname(exe), re.search(r'"%dp0%\\([^"%]+\.(js|mjs|cjs|exe))"\s+%\*', shim)
    if m:
        target = os.path.join(dp0, m.group(1))
        node = os.path.join(dp0, 'node.exe') if os.path.isfile(os.path.join(dp0, 'node.exe')) else shutil.which('node')
        return [target, *cmd[1:]] if m.group(2) == 'exe' else [node, target, *cmd[1:]]
    bad = next((str(c) for c in cmd[1:] if CMD_META.search(str(c))), None)
    if bad:
        raise SystemExit(f'{os.path.basename(exe)} is a cmd.exe shim and this argument has cmd characters (< > | & ^ % ! " ( )): {bad[:80]}'
                         ' - nothing was run; call the real program instead')
    return cmd


def net_sec():
    return min(120, int(os.environ.get('KIT_NET_TIMEOUT_SEC') or (CFG.get('net') or {}).get('timeoutSec') or 120))


def _run(cmd, cwd=None, check=False, write=None, sec=None):
    if not cmd[0]:
        raise SystemExit(f'CLI not found on PATH for: {cmd[1:3]}')
    write = _is_write(cmd) if write is None else write   # on the CLI's own words, before the shim swap shifts them
    cmd = _argv(cmd)
    sec = sec or net_sec()   # whole deadline; sec: the caller's (an idempotent retry with more time)
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
    if rc:   # never silent: the caller's own error then has the cause above it
        print(f'[cli] {os.path.basename(str(cmd[0]))} {" ".join(str(c) for c in cmd[1:3])[:60]}: exit {rc}: {out[-400:]}', file=sys.stderr)
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


# ---- tracker: crafty.ps1 tracker
DEV = os.path.join(KIT, 'crafty.ps1')
PWSH = shutil.which('pwsh') or shutil.which('powershell')
TRACKER_TYPE = (os.environ.get('KIT_TRACKER_TYPE') or (CFG.get('tracker') or {}).get('type') or 'none').lower()


def _tracker(*args):
    """crafty.ps1 tracker <verb>; long texts go via a temp file."""
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
        w = bool(argv) and argv[0] in ('status', 'comment', 'describe', 'create', 'rename', 'parent', 'attach', 'update')
        return _run([PWSH, '-NoProfile', '-NonInteractive', '-File', DEV, 'tracker', *argv], check=w, write=w)
    finally:
        for p in tmp:
            with contextlib.suppress(OSError):
                os.remove(p)


def task(tid):
    """{id, name, status, url, parent, assignees[], subtasks[{id,name,status,url}], list, description}; a failed read: {'raw': why}"""
    t = _json(_tracker('view', tid))
    if not t.get('id') and AUTH_FAIL.search(view_why(t)):   # one retry: a token refresh or a blip (_run retries only transient errors)
        t = _json(_tracker('view', tid))
    return t


AUTH_FAIL = re.compile(r'(?i)\b40[13]\b|unauthori[sz]ed|forbidden|not authorized')


def view_why(t):
    """A failed read's reason: plain-text output or a JSON error body ({err | error | message})."""
    return '' if t.get('id') else str(t.get('raw') or t.get('err') or t.get('error') or t.get('message') or '').strip()


def view_failed(tid, t):
    """One line for an unreadable tracker task (the error's first line), else ''."""
    return '' if t.get('id') else f'tracker view {tid} failed ({(view_why(t) or "no output").splitlines()[0][:160]})'



def prose(kind, text, tool=None):
    """Print kitbag.py prose findings for a text about to be published; never truncates."""
    tool = tool or os.path.join(KIT_DIR, 'skills', 'bossy', 'kitbag.py')
    try:
        r = subprocess.run([sys.executable, '-X', 'utf8', tool, 'prose', '--kind', kind, '-', '--json'], input=text, capture_output=True,
            text=True, encoding='utf-8', timeout=30)
        found = json.loads(r.stdout).get('findings', [])
    except (ValueError, OSError, subprocess.SubprocessError):   # tool path or call failed: same check in-process, never unchecked (retro 2026-11-23)
        try:
            from kitbag import writing_standards, prose_check
            kinds, banned = writing_standards(KIT_DIR)
            found = prose_check(kind, text, kinds[kind], banned) if kind in kinds else []
        except Exception as e:
            print(f'[prose] {kind} UNCHECKED ({e}): run python -X utf8 {os.path.join(KIT_DIR, "skills", "bossy", "kitbag.py")} prose --kind {kind} <file>', file=sys.stderr)
            return []
    for f in found:
        print(f'[prose] {kind}: {f} (templates.md "Writing standards": rewrite, nothing was cut)', file=sys.stderr)
    return found


PROSE_OK = ''   # --prose-ok "<why>": a format the brief fixes; the findings still print
OVERRIDE = ''   # --override "<why>": past the prior-work gate, logged
NO_DOCS = ''   # merge --no-docs "<why>": a foundation area (no human-facing change) passes the testing-docs gate, logged
SCOPE, SCOPE_OK = '', ''   # --scope "<globs>" (mr, merge): the area; --scope-ok <decision id>: a person's scope word, logged
def vendor():
    """The tracker vendor's built-in vocabulary (vocab.json trackers.<tracker.type>)."""
    return (VOCAB.get('trackers') or {}).get(TRACKER_TYPE) or {}


TAG = cfg('tracker.branchTag') or vendor().get('branchTag') or ''


def branch_rx():
    """lib.ps1 Get-KitTaskTagRx: tracker.branchRx, else branchTag, else the vendor's branchRx / idPattern ('' = none); group id."""
    v = vendor()
    rx = cfg('tracker.branchRx') or (rf'(?i){re.escape(TAG)}(?<id>[A-Za-z0-9]+)' if TAG else v.get('branchRx') or
                                     (rf'(?<![A-Za-z0-9])(?<id>{v["idPattern"]})(?![A-Za-z0-9])' if v.get('idPattern') else ''))
    return py_rx(rx)


def statuses():
    """Logical status -> board names: vocab.json statuses, tracker.statuses per key (a name or a list; null = off: [])."""
    out = {k: list(v) if isinstance(v, list) else [v] for k, v in (VOCAB.get('statuses') or {}).items()}
    for k, v in ((CFG.get('tracker') or {}).get('statuses') or {}).items():
        out[k] = [str(n) for n in (v if isinstance(v, list) else [v]) if n not in (None, '')]
    return out


def prior_gate(task, repo, what):
    """Check before create (crafty.ps1 prior; lib.ps1 Assert-KitPrior is the same gate for wt lease / new): prior ran within prior.validHours
    and found nothing for this repo (or a duplicate task); work tagged with the task (its wave branches *<tag><task>*, their commits
    and MRs) is its own: INFO, never a stop; --override passes, logged with the hits it passed."""
    if not task:
        return
    p = (state_read(os.path.join(kit_path('tasks'), re.sub(r'[^\w.-]', '_', task) + '.json')) or {}).get('prior') or {}
    try:   # validUntil: crafty.ps1 prior stores it from prior.validHours (pins and learned values included)
        fresh = datetime.now().astimezone() < datetime.fromisoformat(p['validUntil']).astimezone()
    except (KeyError, TypeError, ValueError):
        fresh = False
    if not fresh and not OVERRIDE:
        raise SystemExit(f'{what} refused: run crafty.ps1 prior -Task {task} first (check before create)')
    leaf = lambda r: re.split(r'[\\/]', r or '')[-1]
    hit, paired, known = [], [], (read_tracking().get('tasks') or {})
    for f in p.get('found') or []:
        if not isinstance(f, dict) or f.get('kind') in (None, '', 'doc', 'qa') or (f.get('kind') == 'task' and f.get('ref') in known):
            continue   # a tracked task is known work (a sibling), never an unseen duplicate
        if f.get('kind') != 'task' and f.get('repo') and f.get('tagged'):   # carries the task id: a sibling wave branch's work
            paired.append(f)
        elif f.get('kind') == 'task' or not f.get('repo') or (leaf(repo) in (leaf(f['repo']), leaf(f.get('proj'))) if repo else True):
            hit.append(f)
    if OVERRIDE:   # matched: absent = no fresh prior (unknown hits)
        kitlog('calls', 'prior-override', {'task': task, 'what': what, 'reason': OVERRIDE,
                                           **({'matched': [{'kind': h.get('kind'), 'ref': h.get('ref'), 'tagged': bool(h.get('tagged'))} for h in hit]} if fresh else {})})
        return
    for f in paired:
        print(f"INFO {what}: paired {f.get('kind')} {f.get('ref')} (task {task}: its own work)", file=sys.stderr)
    if hit:
        kitlog('calls', 'prior-refused', {'task': task, 'what': what, 'found': f"{hit[0].get('kind')} {hit[0].get('ref')}"})
        raise SystemExit(f"{what} refused: already exists: {'; '.join(f'{h.get("kind")} {h.get("ref")} {h.get("title")}' for h in hit)}: "
                         f"reuse it (a task: extend it with crafty.ps1 tracker scope -Task <id> -Add '<item>'), or --override '<reason>'")


def doc_prior(key):
    """doc --key <task>:testing-*: the prior-work gate on the first publish; the task's own published doc updates in place
    (5 --override past a duplicate-task refusal, 2026-11-22)."""
    if _pub_read(key).get('url'):
        print(f'INFO devtools.py doc --key {key}: updates its published doc in place (no prior-work gate)', file=sys.stderr)
    else:
        prior_gate(key.rpartition(':')[0], '', f'devtools.py doc --key {key}')


def task_of_branch(branch):
    rx = branch_rx()
    m = re.search(rx, branch or '') if rx else None
    return (m.group('id') if 'id' in m.re.groupindex else m.group(1 if m.re.groups else 0)) if m else ''


def prose_limits(kind):
    """'<kind>: <format> · limits <limits>' from templates.md "Writing standards" ('' when unknown)."""
    try:
        from kitbag import writing_standards
        s = writing_standards(KIT_DIR)[0].get(kind) or {}
    except Exception:   # a broken standards table must not block a write that passes
        return ''
    return f'{kind}: {s.get("format") or "-"} · limits {s.get("limits") or "-"}' if s else ''


def doc_section_gaps(kind, body):
    """A doc kind's listed `##` sections (templates.md "Writing standards"): missing, out of order, empty or a bare 'none' -> findings."""
    try:
        from kitbag import writing_standards, section_gaps, prose_parts
        spec = writing_standards(KIT_DIR)[0].get({'brief': 'wave-brief'}.get(kind, kind))
    except Exception:   # a broken standards table must not block a publish that passes
        return []
    return section_gaps(spec, prose_parts(body)[1]) if spec else []


def prose_gate(kind, text):
    """prose() before a write: over a limit -> exit 1 before anything is written, unless --prose-ok."""
    found = prose(kind, text)
    if found and not PROSE_OK:
        lim = prose_limits(kind)   # the rendered text, not the agent's file, is what failed (48 refusals guessed at it)
        print(f'[prose] {kind} as checked ({len(text.split())} words, {len(text)} chars):\n{text[:4000]}', file=sys.stderr)
        secs = re.split(r'(?m)^## +', text)[1:]   # per field next to the limits (retro 1709: 8 mr refusals guessed which field)
        if secs:
            mk = r'(?m)^\s*(?:[-*]|\d+\.)\s'
            cnt = lambda b: f'{len(re.sub(mk, "", b).split())}w {len(re.findall(mk, b))}b'
            print(f'[prose] {kind} per section ({lim or "limits: templates.md"}): '
                  + ' · '.join(f'{s.split(chr(10), 1)[0].strip()} {cnt(s.split(chr(10), 1)[1] if chr(10) in s else "")}' for s in secs), file=sys.stderr)
        raise SystemExit(f'[prose] {kind} refused: {len(found)} finding(s) above; rewrite to the limits (same facts){f" ({lim})" if lim else ""},'
                         ' or pass --prose-ok "<why>" for a format the brief fixes. Nothing was written.')
    return found



def set_status(tid, status):
    """status: logical (tracker.statuses) or the tracker's own name."""
    return _tracker('status', tid, status)


def comment(tid, text, kind='comment-status'):
    """A kit comment of this kind: the tracker edits (or replaces) the task's latest one of the same kind; no doc links."""
    text = no_doc_links(text)
    if not text.strip():   # only doc links: they live in the description
        return ''
    prose_gate(kind, text)
    return _tracker('comment', tid, text, '-Kind', kind, '-ProseOk', f'devtools.py checked it ({kind})')


# ---- process: gates + testing docs (lib.ps1 Test-KitProcessGate is the twin; README "Configuration" process)
def docs():
    """process.docs (an empty list = none), else vocab.json docs -> [{key, label, mrLabel, linkRx, headerRx, required}]."""
    pc = CFG.get('process') if isinstance(CFG.get('process'), dict) else {}
    out = []
    for d in (pc['docs'] if 'docs' in pc else VOCAB.get('docs')) or []:
        if isinstance(d, dict) and d.get('key') and d.get('label'):
            out.append({'key': d['key'], 'label': d['label'], 'mrLabel': d.get('mrLabel') or d['label'], 'linkRx': d.get('linkRx') or re.escape(d['label']),
                        'headerRx': py_rx(d.get('headerRx') or ''), 'required': d.get('required') is not False,
                        'columns': [str(c) for c in d.get('columns') or []], 'urlOnly': bool(d.get('urlOnly'))})
    return out


def human_head():
    """The human testing doc's columns: process.docs[testing-doc].columns (with '#' and 'Result'), else HUMAN_HEAD."""
    cols = next((d['columns'] for d in docs() if d['key'] == 'testing-doc' and d['columns']), [])
    return cols if '#' in cols and 'Result' in cols else HUMAN_HEAD


def need_docs():
    """The required process doc keys (unset: the vocab pair testing-doc + testing-ai; [] = none)."""
    return {d['key'] for d in docs() if d['required']}


def _label_alts():
    """Every doc label (+ mrLabel) as one regex alternation, longest first ('' when no docs); a urlOnly doc's label (Spec) only
    when a link follows its colon: a person's own 'Spec: ...' line stays."""
    link = r'(?=(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(?:\[open\]|https?://|[A-Za-z]:[\\/]))'
    return '|'.join(sorted({re.escape(x) + (link if d.get('urlOnly') else '') for d in docs() for x in (d['label'], d['mrLabel'])}, key=len, reverse=True))


def gate_how(gate):
    """process.gates.<gate>: '' (unset: pass) | builtin:<name> | a command line."""
    return str(cfg(f'process.gates.{gate}', '') or '').strip()


BUILTIN_GATES = {}   # adapter kind process-gate: builtin name -> {gate: fn(payload) -> (ok, why)}


def process_gate(gate, payload):
    """lib.ps1 Test-KitProcessGate -> (ok, why, how): unset = pass; builtin:<name>; else the command with the payload JSON on stdin
    (exit 0 = pass, stdout = why). Callable payload values reach built-ins only."""
    how = gate_how(gate)
    if not how:
        return True, '', 'none'
    m = re.match(r'^builtin:([\w-]+)$', how)
    if m:
        fn = (BUILTIN_GATES.get(m.group(1)) or {}).get(gate)
        if not fn:
            return False, f'process.gates.{gate} = {how}: no such built-in for this gate in devtools.py', how
        ok, why = fn(payload)
        return bool(ok), str(why or ''), how
    argv = [a or b or c for a, b, c in re.findall(r'"([^"]*)"|\'([^\']*)\'|(\S+)', how)]
    exe = shutil.which(argv[0]) or argv[0]
    try:
        r = subprocess.run([exe] + argv[1:], input=json.dumps({**{k: v for k, v in payload.items() if not callable(v)}, 'gate': gate}, default=str),
                           capture_output=True, text=True, encoding='utf-8', timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        return False, f'process.gates.{gate} hook failed: {e}', how
    out = (r.stdout or '').strip()
    return r.returncode == 0, out or ('' if r.returncode == 0 else f'process.gates.{gate} hook exit {r.returncode}: {(r.stderr or "").strip()[:300]}'), how


def link_line_rx():
    """A description's doc-link line (any process doc label, the old 'Testing goals (AI)' too) and the blank lines after it."""
    alts = '|'.join(x for x in (_label_alts(), r'Testing goals \(AI\)') if x)
    return re.compile(r'(?im)^[ \t]*(\*\*)?(' + alts + r')(\*\*)?[ \t]*:[^\n]*\n?(?:[ \t]*\n)*')


def links_block(desc, *urls):
    """The description with one fixed links block on top (bold labels, web links as [open](url)); every older doc-link line removed.
    urls: one {doc key: url} dict, or urls in process.docs order (human, AI by default)."""
    md = lambda u: f'[open]({u})' if re.match(r'https?://\S+$', u or '') else u
    dk = docs()
    by = urls[0] if len(urls) == 1 and isinstance(urls[0], dict) else {d['key']: u for d, u in zip(dk, urls)}
    head = ''.join(f'**{d["label"]}:** {md(by[d["key"]])}\n\n' for d in dk if by.get(d['key']))
    return head + link_line_rx().sub('', desc or '').lstrip()   # a blank line: Markdown joins adjacent lines


def no_doc_links(md):
    """A comment without doc links: a '<doc label>: x' field at a line start or after ' · ' goes, up to the next ' · '."""
    alts = '|'.join(x for x in (_label_alts(), r'Testing goals(?: \(AI\))?') if x)
    md = re.sub(r'(?im)(?:^[ \t]*|[ \t]+·[ \t]*)(?:\*\*)?(?:' + alts + r')(?:\*\*)?[ \t]*:[^\n]*?(?=[ \t]+·[ \t]|$)', '', md or '')
    md = re.sub(r'(?m)^[ \t]*·[ \t]*', '', md)
    return re.sub(r'\n{3,}', '\n\n', '\n'.join(ln for ln in md.split('\n') if ln.strip() or not ln)).strip() + '\n' if md.strip() else ''


def _doc_url(tid, kind, doc):
    """A file -> published by key <task>:<kind> (same doc every round); a URL -> remembered as that key's link."""
    if os.path.isfile(doc):
        return publish(f'{tid}:{kind}', os.path.splitext(os.path.basename(doc))[0], doc)
    if not re.match(r'https?://', doc):
        raise SystemExit(f'{kind} {doc!r}: neither a file nor a URL')
    rec = _pub_read(f'{tid}:{kind}')
    if rec.get('url') and rec['url'] != doc:   # a second link would move the next publish (and its history) to another doc
        raise SystemExit(f'finish {tid}: {kind} already is {rec["url"]}; pass the file (it updates that doc, rounds kept), not {doc}. Nothing was written.')
    _pub_update(f'{tid}:{kind}', url=doc)
    return doc


def _finish_strict(p):
    """builtin:testingDocs for finish: each required process doc given (testing-doc: the guide, testing-ai: --ai), the local
    loop PASS (no guide file), the AI doc's case gaps."""
    tid, guide, ai = p['task'], p.get('guide'), p.get('ai')
    if not ai and 'testing-ai' in need_docs():
        return False, 'no AI testing doc (--ai <ai.md|url>, templates.md "Test cases"); process.docs requires it on every task'
    if not guide and 'testing-doc' in need_docs():
        return False, 'no human testing doc (finish <task> <testing.md|url> ...); process.docs requires it on every task'
    if not (guide and os.path.isfile(guide)):   # a URL or no human doc: the local-loop gate still holds
        ok, ev = local_pass(tid)
        if not ok:
            return False, f'the local test loop is {"at " + repr(ev) if ev else "not recorded"}, not PASS (crafty.ps1 checkpoint -Step loop -Item {tid} -Evidence "round <n> PASS")'
    t, ts = p['t'], p['ts']
    rd = lambda f: open(f, encoding='utf-8').read()
    rounds = _pub_read(f'{tid}:testing-ai').get('rounds') or []
    ai_md = rd(ai) if os.path.isfile(ai) else ((rounds or [{}])[-1].get('body') or '')
    own = rounds[:-1] if rounds and rounds[-1].get('body') == ai_md else rounds   # the newest round, already published, is the caller's
    gaps = case_gaps(ai_md, rd(guide) if os.path.isfile(guide) else None, t.get('description') or '', [r['body'] for r in own],
                     f'finish {tid}', [r['body'] for r in _pub_read(f'{tid}:testing-doc').get('rounds') or []], tid,
                     {str(e.get('id')) for e in (ts.get('cases') or {}).get('checks') or []
                      if isinstance(e, dict) and e.get('by') and me_agent() and e['by'] != me_agent()}) if ai_md.strip() else []
    return (False, '; '.join(gaps) + '. Fix the AI doc (run the cases), then finish again') if gaps else (True, '')


def bug_twins(tid, ts):
    """Bug tasks fixed by tid's MRs: tracked with only MRs of tid, or named in tid's cases 'tasks' row; a bug kind prefix name only."""
    tr = read_tracking().get('tasks') or {}
    mine = {_norm_ref(r) for r in (tr.get(tid) or {}).get('mrs') or []} - {None}
    by_mrs = [o for o, x in tr.items() if o != tid and (s := {_norm_ref(r) for r in (x or {}).get('mrs') or []} - {None}) and s <= mine]
    named = [w for w in re.findall(r'\b[\w-]*\d[\w-]*\b', str((ts.get('cases') or {}).get('tasks') or '')) if w != tid]
    bp = ((CFG.get('tracker') or {}).get('kindPrefixes') or {}).get('bug') or cfg('tracker.bugPrefix', '[Bug]')
    out = []
    for o in dict.fromkeys(by_mrs + named):
        x = task(o)
        if why := view_failed(o, x):   # tid itself read fine (auth works): the word is no task id here
            print(f'[finish] {why}: skipped' + (f'; tracker auth works ({tid} read), so {o} is no task id: the cases "tasks" row names tracker task ids only'
                  if AUTH_FAIL.search(view_why(x)) else f'; if {o} is a [Bug] task this fixes, add its doc links by hand'), file=sys.stderr)
        elif str(x.get('name') or '').startswith(bp) or 'bug' in [str(t).lower() for t in x.get('tags') or []]:   # keyed: the kind is a tag
            out.append(x)
    return out


def finish(tid, guide, solution_md, status='review', ai=None):
    """The docs given (human, AI; process.gates.finish builtin:testingDocs: the required process.docs) published by key, the
    description's links block, one solution comment, status (never backwards). guide '-' = none."""
    ai = ai or _pub_read(f'{tid}:testing-ai').get('url')
    guide = None if guide in (None, '', '-') else guide
    solution_md = no_doc_links(solution_md)   # doc links live only in the description
    if gate_how('finish') == 'builtin:testingDocs' and not ai and 'testing-ai' in need_docs():   # before the prose gate, as always
        raise SystemExit(f'finish {tid}: no AI testing doc (--ai <ai.md|url>, templates.md "Test cases"); process.docs requires it on every task. Nothing was written.')
    prose_gate('comment-solution', solution_md)   # before doc, describe, status
    t, ts = task(tid), state_read(task_file(tid[len(TAG):] if TAG and tid.startswith(TAG) else tid)) or {}   # state keys carry no tag
    if why := view_failed(tid, t):   # was a silent skip of the links block
        raise SystemExit(f'finish {tid}: {why}; check tracker auth (crafty.ps1 tracker view {tid}; never log in headlessly), then finish again. Nothing was written.')
    ok, why, how = process_gate('finish', {'task': tid, 'guide': guide, 'ai': ai, 'status': status, 't': t, 'ts': ts})
    if not ok:
        raise SystemExit(f'finish {tid}: {why}{"" if how.startswith("builtin:") else f" (process.gates.finish {how})"}. Nothing was written.')
    if gaps := spec_trace_gaps(tid):   # every spec rule is proven by a case (templates.md "Spec")
        raise SystemExit(f'finish {tid}: spec S-id(s) {", ".join(gaps)} have no test case: cases add a check or case with "spec" naming each. Nothing was written.')
    if (sr := spec_rec(tid)).get('data') and not sr.get('retired') and (dg := spec_diagram_gap(sr['data'])):   # owner 2026-11-24: proper diagrams
        raise SystemExit(f'finish {tid}: spec section {dg} has no diagram: spec write a Mermaid diagram (or {{"diagrams": {{"na": "<why>"}}}}). Nothing was written.')
    ai_url = _doc_url(tid, 'testing-ai', ai) if ai else ''
    guide_url = _doc_url(tid, 'testing-doc', guide) if guide else ''
    md = t.get('description') or ''
    new = links_block(md, {**spec_link(tid), 'testing-doc': guide_url, 'testing-ai': ai_url})   # the Spec line stays
    given = {k: u for k, u in (('testing-doc', guide_url), ('testing-ai', ai_url)) if u}   # by doc key (crafty.ps1 Get-KitSpecDocUrl)
    # failed lookup: describing would wipe the description
    if ts.get('spec') and given and all(re.match(r'https?://', u) for u in given.values()):   # a spec-rendered task refuses describe: the links go into its spec
        _tracker('update', tid, '-Spec', json.dumps({'docs': given, **({'proseOk': PROSE_OK} if PROSE_OK else {})}) + '\n')   # \n: via a file, quotes kept
    elif t.get('id') and t.get('name') and new != md:
        _tracker('describe', tid, new)
    for o in bug_twins(tid, ts) if given else []:   # its promotion needs the same links (a bug task was stuck unpromoted)
        od = o.get('description') or ''; nd = links_block(od, {**task_doc_links(o['id']), 'testing-doc': guide_url, 'testing-ai': ai_url})
        if (state_read(task_file(o['id'])) or {}).get('spec'):
            _tracker('update', o['id'], '-Spec', json.dumps({'docs': given}) + '\n')
        elif nd != od:
            _tracker('describe', o['id'], nd)
        print(f'[finish] {o["id"]}: {tid}\'s testing doc links (fixed by the same MRs)', file=sys.stderr)
    comment(tid, solution_md, 'comment-solution')
    mst, read_ok = [], True
    if gate_how('mrBody') == 'builtin:testingDocs':
        try:   # after the tracker writes: a host error must not fail finish
            for ref in refresh_mr_docs(tid, states=mst):
                print(f'[finish] {ref}: testing doc lines written', file=sys.stderr)
        except Exception as e:
            read_ok = False
            print(f'[finish] {tid}: MR testing doc lines not written ({e}): devtools.py merge writes them, or devtools.py mr', file=sys.stderr)
        for ref, st, ok in mst:   # each MR with its tester guide state; no MR tracked = a no-MR outcome
            print(f'[finish] MR {ref} ({st}): tester guide {"linked" if ok else "MISSING"}', file=sys.stderr)
        if read_ok and not mst:
            print(f'[finish] {tid}: no MR tracked (bossy.ps1 track add -Task {tid} -Mrs <repo>!<n> before merge)', file=sys.stderr)
        if miss := [ref for ref, st, ok in mst if not ok and st == 'opened']:
            raise SystemExit(f'finish {tid}: open MR(s) {", ".join(miss)} have no tester guide line after the update (a doc not published, or the host refused it): add the testing doc'
                             f' lines (devtools.py mr), then finish again. Docs and comment are written; the status was not moved.')
    cs = statuses()   # the same list lib.ps1 reads
    past = [str(n).lower() for k in ('promoted', 'inTest', 'closed') for n in cs.get(k) or []]
    if str(t.get('status', '')).strip().lower() in past:   # a fix round after the merge: links and comment only
        print(f'[finish] {tid} is {t.get("status")}: status kept (never backwards)', file=sys.stderr)
    else:
        try:
            set_status(tid, status)
        except SystemExit as e:   # a parent with open subtasks follows them (lib.ps1 Set-TrackerStatus SKIPPED): docs and comment stand
            if 'SKIPPED' not in str(e):
                raise
            print(f'[finish] {tid}: status kept: {str(e).split("SKIPPED:", 1)[1].strip().splitlines()[0]}', file=sys.stderr)
    tid = tid[len(TAG):] if TAG and tid.startswith(TAG) else tid   # tracking keys carry no tag
    tr = ((read_tracking().get('tasks') or {}).get(tid) or {})
    if tr and not tr.get('done'):   # merged MRs waited on these links: promote now, not a supervise sweep later
        print(_run([PWSH, '-NoProfile', '-NonInteractive', '-File', os.path.join(KIT_DIR, 'skills', 'bossy', 'bossy.ps1'), 'track', 'run', '-Task', tid], write=True, sec=180), file=sys.stderr)


# ---- git host: lib.ps1 git-host adapters via crafty.ps1 host
GITLAB_HOST = CFG.get('gitHost') or ''   # unset: gitHostType names any origin host (as lib.ps1)
GITHUB_HOST = CFG.get('githubHost') or 'github.com'   # arch-ok: github's public host name, not a choice
if CFG.get('gitHost') and not os.environ.get('GITLAB_HOST'):   # else glab api outside a checkout hits gitlab.com
    os.environ['GITLAB_HOST'] = CFG['gitHost']


def host_group():
    """gitHostGroup (gitlabGroup: its older name, still read): the group / owner of short refs <repo>!<iid>."""
    return CFG.get('gitHostGroup') or CFG.get('gitlabGroup') or ''


def mr_word(host=None):
    """The git host's word for a merge request in texts it shows (vocab.json mrWord: MR on GitLab, PR elsewhere)."""
    w = VOCAB.get('mrWord') or {}
    return w.get(host_kind(host if host is not None else GITLAB_HOST)) or w.get('_default') or 'MR'


def host_kind(host):
    """Adapter name of a host (as lib.ps1 Get-HostKind)."""
    # gitHost unset: gitHostType names any origin host
    if CFG.get('gitHostType') and (host == GITLAB_HOST or (not CFG.get('gitHost') and host != GITHUB_HOST)):
        return CFG['gitHostType']
    if host == GITHUB_HOST:
        return 'github'
    # registry: git-host adapters: lib.ps1 Get-HostKind (same detection)
    return next((k for k, rx in (('github', 'github'), ('bitbucket', 'bitbucket'), ('azure', r'dev\.azure\.com|visualstudio\.com'),
                  ('gitea', 'gitea|forgejo|codeberg'), ('gitlab', 'gitlab')) if re.search(rx, host or '')), '')   # unknown: '' (no vendor guess)


def remote(worktree):
    """(adapter, project path) of the worktree's origin (Azure: org/project/repo)."""
    if not os.path.isdir(worktree):   # git's "fatal: cannot change to" text parsed as a remote -> a wrong project path
        raise SystemExit(f'not a folder: {worktree} (cwd {os.getcwd()}) - pass the worktree path, absolute, not a repo name')
    url = _run(['git', '-C', worktree, 'remote', 'get-url', 'origin'], check=True).strip()
    m = re.match(r'^(?:\w+://)?(?:[^@/\s]+@)?(?:ssh\.)?([^/:\s]+)(?::\d+)?[:/](?:v3/)?(\S+?)(?:\.git)?/?$', url)
    if not m:
        raise SystemExit(f'unsupported remote: {url}')
    return host_kind(m.group(1)), m.group(2).replace('/_git/', '/')


def _host(verb, **a):
    """One git-host / ci verb via crafty.ps1 host; JSON from the last line (ci.log: text); unknown = {'raw': output}."""
    fd, p = tempfile.mkstemp(suffix='.json')
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        json.dump(a, fh)
    try:
        out = _run([PWSH, '-NoProfile', '-NonInteractive', '-File', DEV, 'host', verb, '@' + p], write=verb in ('mr.create', 'mr.update', 'mr.merge', 'mr.unauto', 'mr.labels'))
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


def wt_record(worktree, key):
    """A crafty.ps1 wt lease / new record (<git dir>/claude-<key>) as its lines; None when absent."""
    gd = _run(['git', '-C', worktree, 'rev-parse', '--git-dir'])
    f = os.path.join(gd if os.path.isabs(gd) else os.path.join(worktree, gd), f'claude-{key}')
    if os.path.exists(f):
        with open(f, encoding='utf-8-sig') as fh:
            return [ln.strip() for ln in fh.read().splitlines() if ln.strip()]
    return None


# ---- scope: an area's path globs (brief agents[].paths); a diff outside them is refused (lib.ps1 Get-KitScopeOutside: same rule)
def glob_rx(g):
    """A repo-relative area glob as a regex: ** any folders, * and ? within one name, {a,b} either, a trailing / = everything below;
    case-sensitive like git paths (crafty ConvertTo-KitGlobRx: the same rule)."""
    g = re.sub(r'^\./', '', g.strip().replace('\\', '/'))
    g = g + '**' if g.endswith('/') else g
    part = lambda s: ''.join({'**/': '(?:.*/)?', '**': '.*', '*': '[^/]*', '?': '[^/]'}.get(p, re.escape(p)) for p in re.split(r'(\*\*/?|\*|\?)', s))
    return re.compile(''.join('(?:' + '|'.join(part(x) for x in p[1:-1].split(',')) + ')' if p.startswith('{') and p.endswith('}') else part(p)
                              for p in re.split(r'(\{[^{}]*\})', g)) + r'\Z')


def scope_outside(files, globs):
    """The files no glob matches ([] when there are no globs: no area, no check)."""
    rx = [glob_rx(g) for g in globs if g.strip()]
    return [f for f in files if rx and not any(r.match(f) for r in rx)]


def _json_or_none(line):
    try:
        return json.loads(line)
    except ValueError:
        return None


def scope_of(worktree, given='', mr='', log=None, branch=''):
    """Area globs: --scope (comma list), else the worktree's wt lease / new -Scope record when the worktree is on `branch` (a pool
    slot re-leased to another area holds that area's record), else the MR's last scope-log area (a deferred merge: bossy.ps1
    track run); [] = no area."""
    on = not branch or _run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD']).strip() == branch
    if given or (on and (rec := wt_record(worktree, 'scope'))):
        return [g.strip() for g in given.split(',') if g.strip()] if given else rec
    try:
        lines = open(log or kit_path('scope-log'), encoding='utf-8').read().splitlines() if mr else []
    except OSError:
        lines = []
    areas = [x for x in (_json_or_none(ln) for ln in lines if f'"{mr}"' in ln) if x and x.get('event') == 'area' and x.get('mr') == mr]   # a torn line: skipped
    return list(areas[-1].get('globs') or []) if areas else []


def scope_refusal(files, globs, branch, ref='', what='mr'):
    """'' when the files stay in the area or --scope-ok names a person's scope word for this branch / MR; else the refusal."""
    out = scope_outside(files, globs)
    if not out:
        return ''
    # --scope-ok <id>, else any scope word recorded for this branch / MR (K73: a recorded gate was refused without the id)
    orch = os.path.join(KIT_DIR, 'skills', 'bossy', 'bossy.ps1')
    for k in [['-Item', branch]] + ([['-Mrs', ref]] if ref else []):
        word = _run([PWSH, '-NoProfile', '-NonInteractive', '-File', orch, 'decide', 'check', *(['-Id', SCOPE_OK] if SCOPE_OK else []), '-Gate', 'scope', '-MaxHours', '720', *k], write=False)
        if word.startswith('WORD '):
            kitlog('calls', 'scope-override', {'what': what, 'branch': branch, 'mr': ref, 'decision': SCOPE_OK or (word.split() + ['', ''])[1], 'outside': out[:20]})
            return ''
    return (f'{what} refused: {len(out)} file(s) outside the area ({", ".join(globs)}): {", ".join(out[:12])}{" ..." if len(out) > 12 else ""}.'
            f' Revert them (a product bug in a test-only area: pin today\'s behaviour, decide ask); an owner-approved exception:'
            f' bossy.ps1 decide record -Gate scope -Item {branch} ..., then --scope-ok <id>')


def scope_note(url, globs, branch):
    """The MR's area in the durable scope log: deploy plan and supervise compare its merged diff with it."""
    m = re.search(r'([^/]+)/(?:-/)?(?:merge_requests|pulls?|pull-requests|pullrequest)/(\d+)', url or '')
    if globs and m:
        kitlog('scope-log', 'area', {'mr': f'{m.group(1)}!{m.group(2)}', 'url': url, 'branch': branch, 'globs': globs})


def target_of(worktree):
    """MR target: the worktree's record (crafty.ps1 wt lease / new), else kit.local.json repos[].target, else origin/HEAD.
    A fallback is printed (stderr) with its source; None when all three are missing."""
    rec = wt_record(worktree, 'target')
    if rec is not None:
        return (rec or [None])[0]
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
            print(f"[mr] target {r['target']} (no crafty.ps1 wt record; kit.local.json repos[].target of {r.get('name') or co})", file=sys.stderr)
            return r['target']
    head = _run(['git', '-C', worktree, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD'])
    if head.startswith('origin/') and '\n' not in head:
        print(f'[mr] target {head[7:]} (no crafty.ps1 wt record, no kit.local.json repos[].target; origin/HEAD)', file=sys.stderr)
        return head[7:]
    return None


# ---- MR: open a merge / pull request
MR_SECTIONS = tuple(f'## {s}' for s in cfg('mr.sections', ['Summary', 'Changes', 'How tested', 'Risks', 'Links']))  # templates.md "MR spec"
FOOTER = str(cfg('mr.footer', '') or '')   # a line every MR body ends with (default none)


def _verified_gaps(body_md):
    """True when '## How tested' has no 'Not run:' / 'Pure logic:' line."""
    m = re.search(r'^## How tested[^\n]*\n(.*?)(?=^## |\Z)', body_md, re.M | re.S)
    sec = m.group(1) if m else ''
    return bool(m) and not re.search(r'(?im)^\s*[-*|]?\s*(\*\*)?(not run|pure logic)(\*\*)?\s*[:|]', sec)   # a line or a table row


def _how_tested_table(body_md):
    """True when '## How tested' starts with a Markdown table (templates.md "MR spec": | Check | Result |)."""
    return bool(re.search(r'(?m)^## How tested[^\n]*\n\s*\|', body_md))


UI_FILES = re.compile(py_rx(cfg('mr.uiFilesRx', r'\.(html?|s?css|less|sass|tsx|jsx|vue|svelte)$|(^|/)res/layout[^/]*/[^/]+\.xml$')), re.I)


def _ui_line_missing(worktree, tgt, body_md):
    """Changed UI files vs origin/<target> when the body has no 'UI:' line, else []."""
    if re.search(r'(?im)^\s*[-*|]?\s*(\*\*)?UI(\*\*)?\s*[:|]', body_md) or not tgt:
        return []
    out = _run(['git', '-C', worktree, 'diff', '--name-only', f'origin/{tgt}...HEAD'])
    return [f for f in out.splitlines() if UI_FILES.search(f.strip())]


def task_link():
    """A tracker task link's fragment in an MR body: tracker.urlFragment, else the vendor's (vocab.json)."""
    return cfg('tracker.urlFragment') or vendor().get('urlFragment') or ''


def doc_label_rx(d):
    return re.compile(r'(?i)^[ \t>*_|-]*' + d['linkRx'] + ':')


def doc_link_rx(d):
    return re.compile(r'(?im)^[ \t>*_|-]*' + d['linkRx'] + r':[ \t*_|]*(\[[^\]\n]*\]\()?(https?://|[A-Za-z]:[\\/])\S')


def with_doc_lines(body, tid):
    """(body, missing): each process doc's "<mrLabel>: <url>" line from <tid>'s published records (older lines of a published kind
    replaced: its own URL or no link), under "## Links" or above the footer; missing = the required doc keys with no record.
    Another task's linked line stays: one MR of several tasks lists every task's docs (retro tidy-20261123-01)."""
    dk = docs()
    urls = {d['key']: _pub_read(f'{tid}:{d["key"]}').get('url') for d in dk}
    lines = [ln for ln in (body or '').split('\n') if not any(urls[d['key']] and doc_label_rx(d).match(ln) and (urls[d['key']] in ln or not doc_link_rx(d).match(ln)) for d in dk)]
    add = [f'- {d["mrLabel"]}: {urls[d["key"]]}' for d in dk if urls[d['key']]]
    at = next((i + 1 for i, ln in enumerate(lines) if ln.strip() == '## Links'), next((i for i, ln in enumerate(lines) if FOOTER and FOOTER in ln), len(lines)))
    return '\n'.join(lines[:at] + add + lines[at:]) if add else body, [d['key'] for d in dk if d['required'] and not urls[d['key']]]


def _ref_path(host, repo):
    """A tracked ref's repo -> its host path: as is with a '/', gitlabGroup/<repo>, else the origin of repos[] <repo>'s checkout."""
    if '/' in repo:
        return repo
    if host == 'gitlab' and host_group():
        return f"{host_group()}/{repo}"
    co = next((r.get('checkout') for r in CFG.get('repos') or [] if isinstance(r, dict) and repo in [r.get('name')] + list(r.get('aliases') or [])), '')
    return remote(co)[1] if co and os.path.isdir(co) else repo


def refresh_mr_docs(tid, host=None, states=None):
    """The open MRs tracked for <tid> get both doc lines (finish publishes the docs after the MRs opened) -> the refs updated;
    states (a list) gets (ref, MR state, tester guide linked) per tracked MR."""
    host, done = host or host_kind(GITLAB_HOST), []
    need = [d for d in docs() if d['required']]
    for ref in ((read_tracking().get('tasks') or {}).get(tid) or {}).get('mrs') or []:
        r = _norm_ref(ref)
        path = r and _ref_path(host, r[0])
        m = _host('mr.get', type=host, repo=path, n=r[1]) if r else None
        if not isinstance(m, dict) or not m.get('state'):
            print(f'[mr] {ref}: not readable as {path} ({str(m)[:120]}): add its testing doc lines by hand', file=sys.stderr)
            if states is not None:
                states.append((ref, 'unreadable', False))
            continue
        old = new = str(m.get('description') or m.get('body') or '').replace('\r\n', '\n')
        if m.get('state') == 'opened':
            new = with_doc_lines(old, tid)[0]
            if new != old and isinstance(_host('mr.update', type=host, repo=path, n=r[1], title=m.get('title') or '', body=new), dict):
                done.append(ref)
            else:
                new = old
        if states is not None:
            states.append((ref, m['state'], all(doc_link_rx(d).search(new) for d in need)))
    return done


def mr_create(worktree, title, body_md, tgt=None, check=False):
    """check: the title / body gates only, before the push (no git host call)."""
    missing = [h for h in MR_SECTIONS if h not in body_md]
    if missing:
        print(f'[mr] body is missing {missing} - templates.md "MR spec"', file=sys.stderr)
    for kind in ('mr-title', 'mr-body'):   # the limits first: 29 refusals came from guessing them
        if lim := prose_limits(kind):
            print(f'[prose] {lim}', file=sys.stderr)
    prose_gate('mr-title', title)
    prose_gate('mr-body', body_md)
    if _verified_gaps(body_md):
        print('[mr] "## How tested" has neither a "Not run: <gate and why>" nor a "Pure logic: <spec file or node output>" line'
             ' - say what was not run (or "Not run: nothing") - see templates.md "MR spec"', file=sys.stderr)
    if '## How tested' in body_md and not _how_tested_table(body_md):
        print('[mr] "## How tested" is not a table: use "| Check | Result |" rows (templates.md "MR spec")', file=sys.stderr)
    link = task_link()
    if link and link not in body_md:
        print(f'[mr] body has no tracker ({TRACKER_TYPE}) task link', file=sys.stderr)
    if check:
        return 'CHECK OK: title and body pass the limits; push, then mr without --check (nothing was opened)'
    if FOOTER and FOOTER not in body_md:
        body_md = body_md.rstrip() + '\n\n' + FOOTER + '\n'
    host, proj = remote(worktree)
    src = _run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'])
    prior_gate(task_of_branch(src), proj, f'devtools.py mr {src}')
    how = gate_how('mrBody')
    if task_of_branch(src) and how == 'builtin:testingDocs':   # doc lines merge needs, from published records; a missing doc fails here, not at merge
        body_md, nodoc = with_doc_lines(body_md, task_of_branch(src))
        for k in nodoc:
            print(f'[mr] WARNING: task {task_of_branch(src)} has no published {k} doc: devtools.py merge refuses this MR until it has one;'
                  f' after the local loop PASS: devtools.py finish (it adds the line to this MR)', file=sys.stderr)
    elif how and not how.startswith('builtin:'):   # a hook checks the body: a refusal is a warning (merge gates it)
        ok, why, _ = process_gate('mrBody', {'task': task_of_branch(src), 'branch': src, 'title': title, 'body': body_md})
        if not ok:
            print(f'[mr] WARNING: process.gates.mrBody: {why}', file=sys.stderr)
    tgt = tgt or target_of(worktree)
    if not tgt:
        raise SystemExit('no target: no crafty.ps1 wt record, no kit.local.json repos[].target for this repo and no origin/HEAD'
                  ' - pass it as the 4th argument (git remote set-head origin --auto fixes origin/HEAD)')
    globs = scope_of(worktree, SCOPE)
    if globs and (no := scope_refusal(_run(['git', '-C', worktree, '-c', 'core.quotepath=false', 'diff', '--name-only', f'origin/{tgt}...HEAD']).splitlines(), globs, src)):
        raise SystemExit(no)
    ui = _ui_line_missing(worktree, tgt, body_md)
    if ui:
        print(f'[mr] the diff touches templates/styles ({", ".join(ui[:3])}{" ..." if len(ui) > 3 else ""}) but "## How tested" has no'
         ' "UI: <committed spec or screenshot link>" line (or "UI: not a UI change") - templates.md "MR spec"', file=sys.stderr)
    ex = _host('mr.list', type=host, repo=proj, state='opened', source_branch=src)   # one MR per branch: a re-run edits it
    old = next((x for x in ex if isinstance(x, dict) and x.get('web_url')), None) if isinstance(ex, list) else None
    if old:
        up = _host('mr.update', type=host, repo=proj, n=old.get('iid') or old.get('number'), title=title, body=body_md)
        if not (isinstance(up, dict) and up.get('web_url')):
            print(f'[mr] {old["web_url"]} is open from {src}; its body was not updated (git host has no mr.update: {str(up)[:200]}) - edit it by hand', file=sys.stderr)
        mr_labels(host, proj, old, src, title, body_md)
        scope_note(old['web_url'], globs, src)
        return old['web_url']
    m = _host('mr.create', type=host, repo=proj, source=src, target=tgt, title=title, body=body_md)
    url = m.get('web_url') if isinstance(m, dict) else None
    if not url:   # a retry after a timeout: the first call's MR
        ex = _host('mr.list', type=host, repo=proj, state='opened', source_branch=src)
        url = next((x['web_url'] for x in ex if isinstance(x, dict) and x.get('web_url')), None) if isinstance(ex, list) else None
        if url:
            print(f'[mr] an open MR from {src} already exists (a previous call opened it): {url} - update its description if needed', file=sys.stderr)
    if not url:
        raise SystemExit(f'MR not created: {str(m)[:500]}')
    mr_labels(host, proj, m if isinstance(m, dict) and (m.get('iid') or m.get('number')) else {'iid': (re.search(r'(\d+)/?$', url) or [0, ''])[1]}, src, title, body_md)
    scope_note(url, globs, src)
    return url


def mr_labels(host, proj, m, src, title, body_md):
    """MR / PR labels = its task's tags + its repo (owner 2026-11-24): git-host verb mr.labels ({labels} back), else a 'Tags:' body line."""
    tid, n = task_of_branch(src), str(m.get('iid') or m.get('number') or '')
    if not (tid and n and naming_on()):
        return
    k, have = task_key(tid), (state_read(task_file(tid)) or {}).get('tags') or []
    try:
        tg = naming().tags({**({'key': k} if k else {}), 'repo': proj.rsplit('/', 1)[-1]}, have)['tags']
    except ValueError as e:
        return print(f'[mr] labels skipped: {e}', file=sys.stderr)
    if isinstance(r := _host('mr.labels', type=host, repo=proj, n=n, labels=tg), dict) and 'labels' in r:
        return
    line, b = 'Tags: ' + ', '.join(tg), re.sub(r'(?m)^Tags: .*\n?', '', body_md).rstrip()
    if line not in body_md:
        _host('mr.update', type=host, repo=proj, n=n, title=title, body=b.replace(FOOTER, f'{line}\n\n{FOOTER}') if FOOTER and FOOTER in b else f'{b}\n\n{line}\n')


def of_mr(items, url, urls):
    """The findings for one MR: those naming it (/5 is not /55; as buildy.js followUps), and those naming none of urls."""
    hit = lambda f, u: re.search(re.escape(u) + r'(?!\d)', str(f.get('mr') or ''))
    return [f for f in items if hit(f, url) or not any(hit(f, u) for u in urls)]


def followups(findings, url):
    """Review findings that do not hold the merge -> the MR body's "## Follow-ups" (above the footer), one bullet each; a bullet
    already there (same file + problem) is kept once. -> the bullets added"""
    m, r = re.match(r'^\w+://([^/]+)/(.+?)/(?:-/merge_requests|pulls?|pull-requests|pullrequest)/(\d+)', str(url)), _norm_ref(url)
    if m:
        host, proj, iid = host_kind(m.group(1)), m.group(2).replace('/_git/', '/'), m.group(3)
    elif r:   # <repo>!<iid> or <group>/<repo>!<iid>: the configured host
        host = host_kind(GITLAB_HOST); proj, iid = _ref_path(host, r[0]), r[1]
    else:
        raise SystemExit(f'followups: {url!r} is no MR / PR URL, <repo>!<iid> or <group>/<repo>!<iid>')
    mr = _host('mr.get', type=host, repo=proj, n=iid)
    if not isinstance(mr, dict) or not mr.get('title'):
        raise SystemExit(f'followups: {url} not readable: {str(mr)[:200]}')
    body, key = str(mr.get('description') or mr.get('body') or '').replace('\r\n', '\n'), lambda s: re.sub(r'\W+', ' ', s.split(': ', 1)[-1]).strip().lower()
    sec = re.search(r'(?ms)^## Follow-ups[ \t]*\n(.*?)(?=^## |' + (f'^{re.escape(FOOTER)}|' if FOOTER else '') + r'\Z)', body)
    seen, new = {key(b) for b in re.findall(r'(?m)^- (.+)$', sec.group(1) if sec else '')}, []
    for f in findings:
        b = f"{f.get('severity') or 'should-fix'}: `{f.get('file') or '-'}{':' + str(f['line']) if f.get('line') else ''}`: {' '.join(str(f.get('problem') or '').split())[:300]}"
        if key(b) not in seen:
            seen.add(key(b)); new.append(b)
    if not new:
        return []
    add = ''.join(f'- {b}\n' for b in new)
    if sec:
        body = body[:sec.end(1)].rstrip('\n') + '\n' + add + '\n' + body[sec.end(1):].lstrip('\n')
    else:
        cut = body.rfind(FOOTER) if FOOTER and FOOTER in body else len(body)
        body = body[:cut].rstrip() + '\n\n## Follow-ups\n' + add + ('\n' + body[cut:] if cut < len(body) else '')
    up = _host('mr.update', type=host, repo=proj, n=iid, title=mr['title'], body=body)
    if not (isinstance(up, dict) and up.get('web_url')):
        raise SystemExit(f'followups: {url} not updated ({str(up)[:200]}): add these by hand under "## Follow-ups":\n{add}')
    return new


# ---- merge: merge now or arm merge-when-green; producers first
def _remember_automerge(ref):
    """GitLab drops merge-when-green on a new push (e.g. a rebase): record the intent in .state/automerge.json (under the
    tracking lock, lib.ps1 Update-KitTracking); bossy.ps1 track run re-arms it every supervise round until the MR merges."""
    path = kit_path('automerge')
    try:
        with locked(os.path.join(kit_path('tasks', create=True), '_tracking')):
            am = (state_read(path) or {}).get('refs') or {}
            am[ref] = kit_stamp()
            state_write(path, {'refs': am})
    except Exception as e:   # a lost intent is never re-armed
        print(f'[merge] could not record the merge-when-green intent for {ref} in {path}: {e}', file=sys.stderr)


MERGE_WORDS = ('MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED')
RESOLVE = 'crafty.ps1 wt sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again'
def no_doc_rx():
    """'<first required doc's mrLabel>: none' on one line ('none yet, link below' passes); None when no doc is required."""
    d = next((x for x in docs() if x['required']), None)
    return re.compile(r'(?im)^[ \t>*_-]*' + re.escape(d['mrLabel']) + r'[ \t*_]*:[ \t*_]*(none|n/?a)[ \t.]*($|[|;,(\u00b7])') if d else None


def merge_word(res):
    """auto_merge's last-line status word (NOT_MERGED when none)."""
    last = (str(res or '').strip().splitlines() or [''])[-1].strip()
    return last if last in MERGE_WORDS else 'NOT_MERGED'


def _progress(msg):
    print(f'[merge] {msg}', flush=True)


# no stuck_or_timeout_failure: hanging tests cause it too; a retry would hide them
INFRA = ('ci_quota_exceeded', 'runner_system_failure', 'scheduler_failure', 'api_failure',
         'runner_unsupported', 'no_matching_runner')


def _failed(H, hp, iid):
    """PIPELINE_FAILED text; only infra failure_reasons on the failed jobs -> retry the same sha, not a code fix."""
    hp = hp if isinstance(hp, dict) else {}
    jobs = H('ci.jobs', id=str(hp['id'])) if hp.get('id') else []
    bad = [j for j in jobs if isinstance(j, dict) and j.get('status') == 'failed'] if isinstance(jobs, list) else []
    why = sorted({str(j.get('failure_reason') or j.get('reason') or '') for j in bad})   # reason: the ci adapter's normalised word
    if bad and all(j.get('reason') == 'infra' or str(j.get('failure_reason') or '') in INFRA for j in bad):
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
    if m.get('merge_when_pipeline_succeeds') or put.get('merge_when_pipeline_succeeds') or put.get('auto_merge') == 'kit':   # kit: emulated (bossy.ps1 track run)
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
    """'web!12', quoted ref, MR/PR URL or alias -> (repo, iid) as bossy.ps1 track stores them."""
    r = str(ref or '').strip().strip('\'"')
    group = host_group()
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
    known = {n for r in CFG.get('repos') or [] if isinstance(r, dict) for n in [r.get('name')] + list(r.get('aliases') or []) if n}
    if '/' in repo and repo.rsplit('/', 1)[-1] in known:   # <group>/<repo>!<iid> -> the configured repo
        repo = repo.rsplit('/', 1)[-1]
    repo = str((CFG.get('repoAliases') or {}).get(repo) or repo)
    return repo, m.group('iid')


def _same_repo(repo, proj):
    """Does a ref's repo ('web', 'group/web') name the origin path ('group/sub/web')?"""
    a, b = repo.lower().strip('/'), proj.lower().strip('/')
    return a == b or b.endswith('/' + a)


def _host_mr_state(host, proj, repo, iid):
    """State of <repo>!<iid> ('' = unknown), path resolved like bossy.ps1 track."""
    if '/' in repo:
        path = repo
    else:
        group = host_group() if host == 'gitlab' else ''
        path = f"{group or proj.rsplit('/', 1)[0]}/{repo}"
    m = _host('mr.get', type=host, repo=path, n=str(iid))
    return str(m.get('state') or '') if isinstance(m, dict) else ''



def unmerged_producers(proj, iid, state_of, tracking=None):
    """Unmerged producers of this MR (<proj>!<iid>): tracking-file mergeAfter pairs ('<consumer>!<iid>><producer>!<iid>', bossy.ps1
    track add -MergeAfter). state_of(repo, iid) -> 'merged'/'opened'/'closed'/''. Returns [(producer ref, state, task id)]."""
    try:
        data = read_tracking(tracking)
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


def no_mr_pipelines(proj):
    """repos[].ci.mrPipelines false: the repo runs CI only on other branches (deploy), so an MR never gets a pipeline."""
    return any(isinstance(r, dict) and isinstance(r.get('ci'), dict) and r['ci'].get('mrPipelines') is False
               and any(_same_repo(str(n), proj) for n in [r.get('name') or ''] + list(r.get('aliases') or []) if n)
               for r in CFG.get('repos') or [])


def auto_merge(worktree, iid, max_wait=90):
    STOP_AT[0] = time.time() + max_wait   # 10 s floor per call
    try:
        return _auto_merge(worktree, iid, max_wait)
    finally:
        STOP_AT[0] = 0.0


def _mr_task(m, proj, iid):
    """The task of an MR: its branch's tag, else the tracked task that lists it ('' when none)."""
    return task_of_branch(m.get('source_branch')) or next((t for t, x in (read_tracking().get('tasks') or {}).items() if any(
        (lambda r: r and r[1] == iid and _same_repo(r[0], proj))(_norm_ref(y)) for y in (x or {}).get('mrs') or [])), '')


def bug_fix_rx():
    """process.bugFixRx, else a bug-fix branch (tracker.bugBranchRx, else bugBranchPrefix (fix/) or bugfix/), a fix(...): title or the bug kind prefix ([Bug])."""
    bp = ((CFG.get('tracker') or {}).get('kindPrefixes') or {}).get('bug') or cfg('tracker.bugPrefix', '[Bug]')
    br = cfg('tracker.bugBranchRx', re.escape(cfg('tracker.bugBranchPrefix', 'fix/')) + '|bugfix/')
    return re.compile(py_rx(cfg('process.bugFixRx') or (r'(?im)^(?:' + br + r')|^fix(?:\([^)]*\))?!?:|' + re.escape(bp))))


REPRO = re.compile(r'(?i)\brepro(?:duc\w*|s)?\b')


def _repro_row(p):
    """builtin:reproRow for bugFix: the AI testing doc of a bug fix's task has a repro row (no task / no stored rounds: unknown, passes)."""
    tid = p.get('task')
    rounds = [str(r.get('body') or '') for r in (_pub_read(f'{tid}:testing-ai').get('rounds') or [])] if tid else []
    return (True, '') if not rounds or any(REPRO.search(b) for b in rounds) else (False, f'bug fix of task {tid} with no local reproduction in its AI testing doc')


def _repro_gap(m, proj, iid):
    """NOT_MERGED text when process.gates.bugFix refuses a bug fix (builtin:reproRow: its AI testing doc holds no local reproduction;
    a devy merged a [Bug] fix on unit tests only); '' when no bug fix, the gate passes or --override."""
    if not gate_how('bugFix') or not bug_fix_rx().search(f"{m.get('source_branch') or ''}\n{m.get('title') or ''}"):
        return ''
    tid = _mr_task(m, proj, iid)
    ok, why, how = process_gate('bugFix', {'task': tid, 'mr': f'{proj}!{iid}', 'branch': m.get('source_branch') or '', 'title': m.get('title') or ''})
    if ok:
        return ''
    if OVERRIDE:
        kitlog('calls', 'repro-override', {'task': tid, 'mr': f'{proj}!{iid}', 'reason': OVERRIDE})
        return ''
    if how != 'builtin:reproRow':
        return f'!{iid}: process.gates.bugFix ({how}): {why}; --override "<why>" passes, logged\nNOT_MERGED'
    return (f'!{iid}: {why}: reproduce it first (envy SKILL.md "Debug locally"),'
            f' add a "repro" row (the bug before the fix, the same steps after; not reproducible locally: the row says why),'
            f' devtools.py doc --key {tid}:testing-ai, merge again; --override "<why>" passes, logged\nNOT_MERGED')


def _merge_docs(m, proj, iid, H, body):
    """builtin:testingDocs for merge -> NOT_MERGED text or '': a task MR (a tracker task link in its body) links every required doc
    (written here from the published records), and its first doc line never says "none"; --no-docs passes, logged."""
    if NO_DOCS:   # 2026-11-21: a foundation area's MR was refused, its 5 consumer areas never started
        kitlog('calls', 'docs-exempt', {'mr': f'{proj}!{iid}', 'branch': m.get('source_branch') or '', 'reason': NO_DOCS})
        _progress(f'!{iid}: testing-docs gate passed by --no-docs ({NO_DOCS}), logged')
        return ''
    req = [d for d in docs() if d['required']]
    link = task_link()
    if link and link in body and not all(doc_link_rx(d).search(body) for d in req):   # a task's MR: the docs linked first
        tid = _mr_task(m, proj, iid)
        new, nodoc = with_doc_lines(body, tid) if tid else (body, [d['key'] for d in req])
        if nodoc or not isinstance(H('mr.update', title=m.get('title') or '', body=new), dict):   # body fixed here: 4 runs lost merges to it
            return (f'!{iid}: a task MR without {" and ".join(chr(34) + d["mrLabel"] + ": <url>" + chr(34) for d in req)} lines (task {tid or "unknown"}: no published {" / ".join(nodoc) or "doc write"});'
                    f' after the local loop PASS: devtools.py finish (it writes them), merge again\nNOT_MERGED')
        _progress(f'!{iid}: testing doc lines written from task {tid}\'s published docs'); body = new
    nd = no_doc_rx()
    if nd and nd.search(body):   # merged 3x with no doc: testers had nothing to follow (a published doc replaced "none" above)
        return (f'!{iid}: the MR body says "{req[0]["mrLabel"]}: none"; every change gets a human testing doc: write it, devtools.py doc, '
                f'put its link in the MR body, merge again\nNOT_MERGED')
    return ''


BUILTIN_GATES.update({'testingDocs': {'finish': _finish_strict}, 'reproRow': {'bugFix': _repro_row}})   # merge / mrBody testingDocs: inline (host calls)


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
            return '\n'.join(lines) + '\nproducer MR closed: fix the merge order (bossy.ps1 track mergeAfter) with the coordinator\nNOT_MERGED'
        return '\n'.join(lines) + '\nnot merged now: bossy.ps1 track run (supervise) merges it once the producer merged\nWAIT'
    H = _mr_api(host, proj, iid)
    for i in range(2):   # one retry: a blip must not cost an agent round
        raw = H('mr.get')
        m = raw if isinstance(raw, dict) else {}
        if m.get('state') or i:
            break
        time.sleep(3)
    if m.get('state') == 'merged':
        return f'already merged !{iid}\nMERGED'
    if not m.get('state'):
        return f'!{iid}: no MR state from the git host for {proj} (auth status? network? path?); reply: {str(raw)[:300]}\nWAIT'
    if m.get('state') != 'opened':
        return f'!{iid} is {m.get("state")}, not open\nNOT_MERGED'
    ref = f'{proj.rsplit("/", 1)[-1]}!{iid}'
    if globs := scope_of(worktree, SCOPE, ref, branch=m.get('source_branch') or ''):   # the host's diff, not the worktree's: what merges is checked
        ch = H('mr.changes')
        ch = ch if isinstance(ch, dict) else {}
        files = sorted({p for c in ch.get('changes') or [] for p in (c.get('new_path'), c.get('old_path')) if p})
        if ch.get('overflow') or not files or (len(files) >= 100 and host != 'gitlab'):   # unpaged lists stop at 100: never read a cut list as in-area
            files.append('<the host change list is empty or cut: merge by hand or --scope-ok>')
        scope_note(m.get('web_url') or '', globs, m.get('source_branch') or '')
        if no := scope_refusal(files, globs, m.get('source_branch') or '', ref, 'merge'):
            return f'!{iid}: {no}\nNOT_MERGED'
    body = str(m.get('description') or m.get('body') or '').replace('\r\n', '\n')
    if gate_how('merge') == 'builtin:testingDocs':
        if no := _merge_docs(m, proj, iid, H, body):
            return no
    elif gate_how('merge'):   # a hook: the MR facts on stdin
        ok, why, how = process_gate('merge', {'task': _mr_task(m, proj, iid), 'mr': f'{proj}!{iid}', 'branch': m.get('source_branch') or '',
                                              'target': m.get('target_branch') or '', 'title': m.get('title') or '', 'body': body})
        if not ok:
            return f'!{iid}: process.gates.merge ({how}): {why}\nNOT_MERGED'
    if gap := _repro_gap(m, proj, iid):
        return gap
    if m.get('has_conflicts') or m.get('detailed_merge_status') == 'conflict':
        return f'CONFLICT: {RESOLVE}\nCONFLICT'
    st = (m.get('head_pipeline') or {}).get('status')
    if st in ('failed', 'canceled'):
        return _failed(H, m.get('head_pipeline'), iid)
    # no CI config -> merge now (merge-when-green waits forever); CI, no pipeline 5 min after the MR update -> NOT_MERGED
    no_ci = False
    if st is None:
        if no_mr_pipelines(proj):
            no_ci = True
            _progress(f'repos[].ci.mrPipelines is false for {proj} (CI runs on other branches only): merging !{iid} on review + local checks')
        elif H('ci.config', ref=m.get('target_branch') or '') is False:
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



# ---- docs: make_doc / make_evidence -> ADAPTERS['report'][reports.type]
_q = lambda s: subprocess.list2cmdline([str(s)]) if os.name == 'nt' else __import__('shlex').quote(str(s))


def keep_doc(title, path, keep=None, url=None):
    """Copy into keep (default <runtime>/work/docs); already there: in place; url = the kept file of an earlier publish."""
    if keep and os.path.abspath(keep) == os.path.dirname(os.path.abspath(path)):
        return path
    slug = re.sub(r'[^A-Za-z0-9]+', '-', title).strip('-')[:80] or 'doc'
    dst = url if url and not re.match(r'https?://', url) and os.path.splitext(url)[1] == os.path.splitext(path)[1] else \
        os.path.join(keep or kit_path('docs', create=True), slug + os.path.splitext(path)[1])
    if os.path.abspath(dst) != os.path.abspath(path):
        shutil.copyfile(path, dst)
    return dst


def _cells(row):
    """A Markdown table row's cells; empty ones kept (a fresh human doc's Result / Evidence)."""
    r = row.strip()
    r = r[1:] if r.startswith('|') else r
    return [c.strip() for c in re.split(r'(?<!\\)\|', r[:-1] if r.endswith('|') and not r.endswith('\\|') else r)]   # \| stays inside its cell


# inline styles only: Google Docs' HTML import keeps just span / cell styles and header widths
CODE_CSS = "font-family:'Roboto Mono';font-size:9pt;background-color:#f1f3f4"
CELL_CSS = 'vertical-align:top;padding:4pt'
HEAD_CSS = CELL_CSS + ';background-color:#e8eaed'
COL_ROLES = ((30, r'screenshot|ui steps'), (12, r'extra evidence'), (20, r'expected on screen'),   # the human doc: the screenshot readable
             (5, r'#|no\.?|id|round'), (10, r'type|result|status|date|verdict|retest'), (20, r'evidence|links?|fix commit|bugs found'),
             (25, r'expected|observed|pass rule|saw|why|value'), (40, r'steps?\b.*|check|goal|how checked|what.*|cases run|item|setting'))


def col_widths(headers):
    """Column widths in % by header role (# 5, Step 40, Expected 25, Result 10, Evidence 20; human doc: UI steps 30, Expected on
    screen 20, Screenshot 30, Extra evidence 12; others share the rest), summing to
    100; None when no header has a known role (the renderer's default widths)."""
    w = [next((p for p, rx in COL_ROLES if re.fullmatch(rx, re.sub(r'[*_`]', '', h).strip().lower())), 0) for h in headers]
    if not any(w):
        return None
    w = [x or max(10, (100 - sum(w)) // max(1, w.count(0))) for x in w]
    return [round(x * 100 / sum(w), 1) for x in w]


PAGE_PT = 468   # Google Doc text width (8.5 in page, 1 in margins): measured Evidence cells 76 / 85 / 90 pt = their % less padding


def cell_img_px(pct):
    """Widest image (px) that fits a cell of pct % of the page: the cell's width less its 4 pt padding each side, less a border px."""
    return max(40, int((pct * PAGE_PT / 100 - 8) * 4 / 3) - 2)


def full_link(src):
    """The full-size view of an image src: a Drive file's /file/d/<id>/view, any other src itself."""
    m = re.search(r'drive\.google\.com/(?:uc|open|thumbnail)\?(?:[^"\s]*&(?:amp;)?)?id=([\w-]+)|drive\.google\.com/file/d/([\w-]+)|googleusercontent\.com/d/([\w-]+)', src)
    return f'https://drive.google.com/file/d/{m[1] or m[2] or m[3]}/view' if m else src


def md_to_html(md, title=''):
    """Dependency-free Markdown -> HTML for `doc` (gws uploads Markdown as plain text): headings, tables (header bold and shaded,
    widths by role, cells padded and top-aligned; an image in a cell fits it, with an "open full" link under it), lists,
    emphasis, monospace code spans and blocks, links, images, rules."""

    def img(m, cap):
        w = min(600, int(m[3] or m[4] or 600))   # default and cap 600 px (the page width)
        if not cap:
            return f'<p><img src="{m[2]}" width="{w}"><br><i>{m[1]}</i></p>'
        return f'<p><img src="{m[2]}" width="{min(w, cap)}"><br><i>{m[1]}</i><br><a href="{full_link(m[2])}"{new_tab(full_link(m[2]))}>open full</a></p>'

    new_tab = lambda u: ' target="_blank" rel="noopener"' if re.match(r'https?://', u) else ''   # ui-check: a web link never replaces the doc

    def inline(t, cap=None):
        t = html.escape(t, quote=False).replace('&lt;br&gt;', '<br>')   # a line break inside a table cell (evidence previews)
        code = []   # code spans set aside: emphasis and link rules never touch them
        t = re.sub(r'`([^`]+)`', lambda m: code.append(m[1]) or f'\0{len(code) - 1}\0', t)
        t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
        t = re.sub(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])', r'<i>\1</i>', t)
        # images before links: ![alt](url "width px"); in a cell: cell-fit, stacked, each linked
        t = re.sub(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;(\d+)&quot;|\s+"(\d+)")?\)', lambda m: img(m, cap), t)
        t = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', lambda m: f'<a href="{m[2]}"{new_tab(m[2])}>{m[1]}</a>', t)
        return re.sub(r'\0(\d+)\0', lambda m: f'<span style="{CODE_CSS}">{code[int(m[1])]}</span>', t)

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
            out.append(f'<pre style="{CODE_CSS}">' + html.escape('\n'.join(lines[i + 1:j])) + '</pre>'); i = j + 1; continue
        if l.startswith('|') and i + 1 < len(lines) and re.match(r'^\|[\s:|-]+\|?\s*$', lines[i + 1]):
            close(); head = _cells(l); cw = col_widths(head) or [None] * len(head)
            caps = [cell_img_px(w or 100 / len(head)) for w in cw]   # no known role: the renderer shares the width evenly
            rows = ['<tr>' + ''.join(f'<th style="{HEAD_CSS}{f";width:{w}%" if w else ""}"><b>{inline(c)}</b></th>' for c, w in zip(head, cw)) + '</tr>']
            i += 2
            while i < len(lines) and lines[i].startswith('|'):
                rows.append('<tr>' + ''.join(f'<td data-l="{html.escape(re.sub(r"[*`]", "", head[j]) if j < len(head) else "", quote=True)}" style="{CELL_CSS}">{inline(c.replace(chr(92) + "|", "|"), caps[j] if j < len(caps) else caps[-1])}</td>'
                                             for j, c in enumerate(_cells(lines[i]))) + '</tr>'); i += 1
            out.append(f'<table border="1" style="border-collapse:collapse{";width:100%" if any(cw) else ""}">' + ''.join(rows) + '</table>'); continue
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
    # a phone (ui-check 390 px squeezed a 5-column table's cells to 62 px): each row stacks, a cell under its column name
    narrow = ('<style>@media (max-width:640px){table,tbody,tr,td{display:block;width:auto!important}td{overflow-wrap:anywhere}tr:first-child{display:none}'
              'td::before{content:attr(data-l);display:block;font-weight:bold}}</style>')
    return f'<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title>{narrow}</head><body>' + '\n'.join(out) + '</body></html>'


def _html_of(a):
    """a's file as HTML (Markdown -> <name>.doc.html)."""
    p = a['path']
    if not p.lower().endswith(('.md', '.markdown')):
        return p
    conv = os.path.splitext(p)[0] + '.doc.html'
    with open(p, encoding='utf-8') as fh, open(conv, 'w', encoding='utf-8') as out:
        out.write(md_to_html(fh.read(), a['title']))
    return conv


def make_doc(title, path, parent=None, url=None, tags=(), old_tags=()):
    """Publish via reports.type -> URL or kept path; parent: a remote id or a folder to keep it in; url: an earlier publish of
    this doc, updated in place where the adapter can; tags: its task's (a 'tags' adapter sets them natively too, old ones off)."""
    ad = ADAPTERS['report'].get(REPORT_TYPE) or no_report_adapter()
    keep = parent if parent and os.path.isdir(parent) else None
    return ad['publish']({'title': title, 'path': path, 'parent': None if keep else parent, 'keep': keep, 'url': url, 'tags': list(tags), 'oldTags': list(old_tags)})


def doc_tags(tid):
    """A doc's tags = its task's (task index, else from its kit key): specs, testing docs, QA reports filter like tasks (owner 2026-11-24)."""
    if not (tid and naming_on()):
        return []
    have, k = (state_read(task_file(tid)) or {}).get('tags') or [], task_key(tid)
    try:
        return list(have) or (naming().tags({'key': k}, [])['tags'] if k else [])
    except ValueError:
        return list(have)


def with_tags(text, ext, tags):
    """The 'Tags: a, b' line under the title (Markdown) or first in the body (HTML), an older one replaced: every doc store shows it."""
    line = 'Tags: ' + ', '.join(tags)
    if ext == '.html':
        t = re.sub(r'<p>Tags: [^<]*</p>', '', text)
        return t if not tags else t.replace('<body>', f'<body><p>{html.escape(line)}</p>', 1) if '<body>' in t else f'<p>{html.escape(line)}</p>' + t
    t = re.sub(r'(?m)^Tags: .*\n\n?', '', text)
    m = re.match(r'# .*\n', t)
    return t if not tags else t[:m.end()] + f'\n{line}\n' + t[m.end():] if m else f'{line}\n\n' + t


def redact_files(files):
    """Text evidence masked in place before upload (retro: a saved request body with a test password reached Drive): JSON keys
    matching _paths.log.secretKey -> [redacted], strings through the log's secret masks (emails stay: test data)."""
    import kitbag
    rxs = [(rx, r) for rx, r in kitbag._MASKS if 'redacted' in r]

    def red(v):
        if isinstance(v, dict):
            return {k: '[redacted]' if re.search(kitbag.LOG['secretKey'], str(k)) and v[k] not in (None, '') else red(x) for k, x in v.items()}
        if isinstance(v, list):
            return [red(x) for x in v]
        for rx, r in rxs if isinstance(v, str) else ():
            v = rx.sub(r, v)
        return v
    for f in [f for f in files if re.search(r'\.(json|har|txt|log)$', str(f), re.I) and os.path.isfile(f)]:
        try:
            t = open(f, encoding='utf-8-sig', newline='').read()
        except UnicodeDecodeError:   # not UTF-8 text: never rewritten
            continue
        try:
            j = json.loads(t)
            n = t if red(j) == j else json.dumps(red(j), indent=2, ensure_ascii=False)
        except ValueError:
            n = red(t)
        if n != t:
            open(f, 'w', encoding='utf-8', newline='').write(n)
            print(f'[evidence] {os.path.basename(f)}: secrets redacted before upload', file=sys.stderr)


def make_evidence(name, files, folder=None, parent=None, key=None):
    """Host evidence files -> {folderId, folderLink, label, files}; {} = they stay in the run folder; key: reuse its folder.
    Evidence store (README "Adapters"): reports.evidence report (default: the report adapter's own host, e.g. gdocs = Drive) |
    local (the run folder) | command (reports.evidenceCommand: a bucket / share CLI)."""
    st = str(RCFG.get('evidence') or 'report').lower()
    ad = ADAPTERS['report'].get(REPORT_TYPE)
    if ad is None and st == 'report':   # evidence stays in the run folder; say why once
        print(f'reports.type {REPORT_TYPE}: no such report adapter, evidence stays in the run folder', file=sys.stderr)
    fn = {'local': None, 'command': _evidence_command}.get(st, (ad or {}).get('evidence'))
    if not fn:
        return {}
    redact_files(files)
    rec = _pub_read(key) if key else {}
    out = fn({'name': name, 'files': files, 'folder': folder or rec.get('folderId'), 'parent': parent})
    if key and out.get('folderId'):
        _pub_update(key, folderId=out['folderId'], folderLink=out.get('folderLink') or rec.get('folderLink'))
        out['folderLink'] = out.get('folderLink') or rec.get('folderLink')
    return out


# ---- publish: one artefact per key (<task or run>:<kind>), same link every round; .state/published/
PUB_KINDS = {'testing-doc': 'append', 'testing-ai': 'append', 'qa-report': 'append'}   # other kinds: replace
GOALS_MARK = re.compile(r'(?m)^#{1,2} (Testing goals\b|Goals \(what must be true\))')   # templates.md "Testing goals"
CHECKS_TABLE = re.compile(r'(?im)^\|\s*#\s*\|\s*(UI steps\s*\|\s*Expected on screen\s*\|\s*Screenshot\s*\|\s*Extra evidence\s*\|\s*Result|Steps\s*\|\s*Expected\s*\|\s*Result\s*\|\s*Evidence)\s*\|')   # "Human testing doc" (positive cases; the 5-column form: docs before 2026-11-20)
HUMAN_HEAD = ['#', 'UI steps', 'Expected on screen', 'Screenshot', 'Extra evidence', 'Result']
# a human check names what a person clicks and sees, never an endpoint (owner 2026-11-20)
API_WORDS = re.compile(r'(?i)\bcurl\b|/api/|\bpayload\b|\brequest body\b|\bpostman\b|\bswagger\b|\b(call|calls|send|sends|hit|invoke)\b[^.|]{0,25}\bAPI\b'
                       r'|(?-i:\b(GET|POST|PUT|PATCH|DELETE)(\s+/(?=[\w{:.-])|\s+request\b))')
EV_LABEL = re.compile(r'\s*((?:\*\*[^*]+\*\*\s*)+(?:[A-Z][A-Z _]*(?:\([^)]*\))?:)?\s*)')   # '**V1** PASS: ' / '**stg** ' before a check's evidence
IMG_MD = re.compile(r'!\[[^\]]*\]\([^)]*\)|<img\b[^>]*>')
AI_TABLE = re.compile(r'(?im)^\|\s*#\s*\|\s*Type\s*\|\s*Steps\s*/\s*API call[^|]*\|\s*Expected\s*\|\s*Result\s*\|\s*Evidence\s*\|')   # "Testing doc (AI)"
ROUNDS_TABLE = re.compile(r'(?im)^\|\s*Round\s*\|\s*Date\s*\|\s*Cases run\s*\|\s*Result\s*\|\s*Bugs found\s*\|\s*Fix commit\s*\|\s*Retest\s*\|[^\n]*\n\|[-:| ]+\|[ \t]*\n?((?:\|[^\n]*\n?)*)')   # its loop history


def _pub_file(key):
    return os.path.join(kit_path('published', create=True), re.sub(r'[^\w.-]+', '_', key) + '.json')


def _pub_read(key):
    try:
        with open(_pub_file(key), encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _pub_write(key, rec):
    """The key's record (bodies, rounds); a task doc kind also points the task index (.state/tasks/<id>.json docs.<kind>) at it."""
    rec = state_write(_pub_file(key), rec)
    scope, _, kind = key.rpartition(':')
    tasks = kit_path('tasks')
    if scope and (kind in ('testing-doc', 'testing-ai') or os.path.isfile(os.path.join(tasks, re.sub(r'[^\w.-]', '_', scope) + '.json'))):
        try:
            task_index(scope, lambda x: x['docs'].__setitem__(kind, {k: rec.get(k) for k in ('key', 'url', 'type', 'title', 'updated')}), tasks)
        except Exception as e:   # the doc is published; only its pointer is missing
            print(f'[publish] {key}: task index not updated: {e}', file=sys.stderr)


def _pub_update(key, **fields):
    """Merge fields into a key's record under its lock (publish holds the same lock for a whole round)."""
    with locked(_pub_file(key)):
        _pub_write(key, {**_pub_read(key), 'key': key, **fields, 'updated': time.strftime('%Y-%m-%d %H:%M')})


def local_pass(task):
    """The newest `crafty.ps1 checkpoint -Step loop -Item <task>` evidence across agents: (True|False|None, evidence)."""
    last = None
    for f in glob.glob(os.path.join(kit_path('agents'), '*', 'resume*.json')):   # resume-<run>.json; old resume.json
        try:
            with open(f, encoding='utf-8') as fh:
                steps = json.load(fh).get('steps') or []
        except (OSError, ValueError):
            continue
        for s in steps:
            if str(s.get('step', '')).lower() == 'loop' and task in re.split(r'[\s,;]+', str(s.get('item', ''))) and (not last or s.get('at', '') >= last.get('at', '')):
                last = s
    if not last:
        return None, ''
    ev = str(last.get('evidence', ''))
    return bool(re.search(r'\bPASS\b', ev) and not re.search(r'\b(FAIL|BLOCKED)\b', ev)), ev


def _demote(md):
    """A round's Markdown under a '## Round' heading: its H1 dropped, every other heading one level down."""
    return re.sub(r'(?m)^(#{1,5}) ', r'#\1 ', re.sub(r'\A\s*# [^\n]*\n', '', md))


def _body_of(h):
    m = re.search(r'(?is)<body[^>]*>(.*)</body>', h)
    return m.group(1) if m else h


def _table_rows(md, cells=None, full=False):
    """Rows of every table whose header has '#', 'Result' and 'Evidence' (or 'Screenshot' + 'Extra evidence'): [(id, result, evidence)]
    (full: + its other cells joined); cells {id: {result, evidence}} -> the Markdown with those cells filled (images -> Screenshot,
    the rest -> Extra evidence). -> (rows, md)"""
    out, rows, cols = [], [], None
    one = lambda v: re.sub(r'\s*\n\s*', ' ', str(v or '')).replace('|', '\\|')   # a newline would end the row
    for line in md.split('\n'):
        c = _cells(line) if line.lstrip().startswith('|') else None
        low = [x.lower() for x in c] if c else []
        if c and '#' in low and 'result' in low and ('evidence' in low or 'screenshot' in low):
            cols = {n: i for i, n in enumerate(low)}
            evc = [cols[n] for n in ('evidence', 'screenshot', 'extra evidence') if n in cols]
        elif c and cols and not re.fullmatch(r'[\s|:-]+', line) and len(c) == len(cols):
            rows.append((c[cols['#']], c[cols['result']], ' '.join(c[j] for j in evc if c[j])) + ((' | '.join(x for j, x in enumerate(c) if j not in [cols['#'], cols['result']] + evc),) if full else ()))
            if cells and c[cols['#']] in cells:
                ev = str(cells[c[cols['#']]].get('evidence') or '')
                c[cols['result']] = one(cells[c[cols['#']]].get('result'))
                if 'evidence' in cols:
                    c[cols['evidence']] = one(ev)
                else:
                    segs = [(m.group(1) if (m := EV_LABEL.match(s)) else '', s) for s in ev.split('<br>')]   # one segment per check / env
                    c[cols['screenshot']] = one('<br>'.join(lb + ' '.join(im) for lb, s in segs if (im := IMG_MD.findall(s))))
                    if 'extra evidence' in cols:
                        c[cols['extra evidence']] = one('<br>'.join(r for lb, s in segs if (r := re.sub(r'\s{2,}', ' ', IMG_MD.sub('', s)).strip()) and r != lb.strip()))
                line = '| ' + ' | '.join(c) + ' |'
        elif not c:
            cols = None
        out.append(line)
    return rows, '\n'.join(out)


def _refs(c):
    """The human-doc rows a run check covers: its `case` (ids), else its screen's leading row id ('T1 Bulk ...')."""
    r = c.get('case') if isinstance(c, dict) else None
    if r:
        return [x for x in (r if isinstance(r, list) else re.split(r'[\s,;]+', str(r))) if x]
    m = re.match(r'\s*([A-Za-z]*\d+[a-z]?)\b', str((c or {}).get('screen') or '')) if isinstance(c, dict) else None
    return [m.group(1)] if m else []


def _row_cells(md, cells):
    """A run's cells {check id: {result, evidence, case, screen, why}} -> cells per human-doc row id (+ ids, why): the row's own check,
    else every check that covers it (_refs) in one cell: FAIL > NOT TESTED > PENDING > PASS (out-of-scope ones count only alone)."""
    out, nat = {}, lambda x: [int(t) if t.isdigit() else t for t in re.split(r'(\d+)', x[0])]
    for rid, *_ in _table_rows(md)[0]:
        by = sorted(((cid, c) for cid, c in cells.items() if cid == rid or rid in _refs(c)), key=nat)
        if not by:
            continue
        if len(by) == 1 and by[0][0] == rid:   # the row's own check alone: its cell as is
            out[rid] = dict(cells[rid], ids=[rid])
            continue
        res = [str(c.get('result') or '').upper() for _, c in by]
        live = [x for x in res if not x.startswith('OUT OF SCOPE')] or res
        word = next((w for w in ('FAIL', 'NOT TESTED', 'PENDING') if any(x.startswith(w) for x in live)), None) or (
            'OUT OF SCOPE' if all(x.startswith('OUT OF SCOPE') for x in res) else 'PASS' if all(x.startswith('PASS') for x in live) else 'NOT TESTED')   # an empty / unknown result never reads PASS
        out[rid] = {'result': f'{word} ({", ".join(cid for cid, _ in by)})', 'ids': [cid for cid, _ in by],
                    'why': '; '.join(c['why'] for _, c in by if c.get('why') and _word(c.get('result')) == word),
                    'evidence': '<br>'.join(f'**{cid}** {c.get("result") or ""}: {c.get("evidence") or c.get("why") or "none"}' for cid, c in by)}
    return out


def _word(result):
    """A cell's result word ('PASS (V1, V2)' -> PASS); empty or unknown -> NOT TESTED, never PASS."""
    r = str(result or '').upper()
    return next((w for w in ('PASS', 'FAIL', 'NOT TESTED', 'PENDING', 'OUT OF SCOPE') if r.startswith(w)), 'NOT TESTED')


def _runs_cells(md, runs):
    """Each human-doc row over every run that covers it (oldest first): the newest PASS / FAIL run decides, so a later NOT TESTED,
    PENDING or OUT OF SCOPE never replaces an earlier result and a later FAIL does; 2+ runs: each named by its env, the ones with
    another result after ' · ' with their why ('PASS (stg V5, V7) · local: not tested (T2) — <why>'); one run: its cell as is."""
    per, out = {}, {}
    for r in runs:
        for rid, c in _row_cells(md, r.get('cells') or {}).items():
            per.setdefault(rid, []).append((r.get('label') or r.get('id') or 'env', c))
    for rid, got in per.items():
        if len(got) == 1:
            out[rid] = got[0][1]
            continue
        words = [_word(c.get('result')) for _, c in got]
        word = words[([i for i, w in enumerate(words) if w in ('PASS', 'FAIL')] or [-1])[-1]]
        same = [f'{env} {", ".join(c.get("ids") or [])}'.strip() for (env, c), w in zip(got, words) if w == word and word in ('PASS', 'FAIL')]
        rest = [f'{env}: {w.lower()} ({", ".join(c.get("ids") or [])})' + (f' — {c["why"]}' if c.get('why') else '') for (env, c), w in zip(got, words) if w != word or not same]
        out[rid] = {'result': word + (f' ({" + ".join(same)})' if same else '') + ''.join(f' · {x}' for x in rest), 'ids': [i for _, c in got for i in c.get('ids') or []],
                    'evidence': '<br>'.join(f'**{env}** ' + (c.get('evidence') or c.get('why') or 'none') for env, c in got)}
    return out


def run_gaps(md, cells, earlier=()):
    """Human-doc rows no check of a run covers and no earlier published run (earlier: their records) covered (pokey finalize refuses them)."""
    filled = _runs_cells(md, list(earlier) + [{'cells': cells or {}}])
    return [rid for rid, *_ in _table_rows(md)[0] if rid not in filled]


def sample_run_doc(tmp):
    """Report adapter selftests: a human doc whose T1 row an env run filled from checks V1 (screen) + V2 (case), and whose T2 row
    keeps that run's PASS (V3) after a later local run left it NOT TESTED -> its path."""
    body = '# Testing: X\n\n| # | Steps | Expected | Result | Evidence |\n|---|---|---|---|---|\n| T1 | open a | a shown | | |\n| T2 | open b | b shown | | |\n'
    cells = {'V1': {'result': 'PASS', 'evidence': '![V1: List](https://img/v1.png "260")', 'screen': 'T1 list'},
             'V2': {'result': 'PASS', 'evidence': '`GET /a -> 200 · po: X1` [Resp](https://f/v2)', 'case': 'T1'},
             'V3': {'result': 'PASS', 'evidence': '`GET /b -> 200`', 'case': 'T2'}}
    p = os.path.join(tmp, 'run-doc.md')
    with open(p, 'w', encoding='utf-8') as fh:
        fh.write(_table_rows(body, _runs_cells(body, [{'label': 'stg', 'cells': cells}, {'label': 'local', 'cells': {'T2': {'result': 'NOT TESTED', 'why': 'read-only'}}}]))[1])
    return p


NO_RUN = re.compile(r'(?is)\s*(|[—–-]|(n/?a|not[ _]tested([ _]local)?|untested|out[ _]of[ _]scope|skip(ped)?|pending|blocked)\b.*)')
EVIDENCE_LINK = re.compile(r'(?i)https?://|!\[|<img\b')
# a waiver, not data; same regex: pokey.ps1 $preEx
PRE_EXISTING = re.compile(r'(?i)\b(known|ignored?|waived?|accepted|not (our|my|this)|out of scope)\b.{0,40}pre-?existing|pre-?existing\b.{0,30}\b(bug|defect|issue|'
                          r'failure|error|overlap|problem|broken|behaviou?r)|\b(unrelated to|not caused by) (this|the) (change|task)\b')
RAN = re.compile(r'(?i)^[\W_]*(pass|not[ _]tested[ _]local)')   # a Result that ran (markup allowed)
THRESHOLD = re.compile(r'(?i)(>=|<=|[<>≥≤=]|\b(at least|at most|max|min)\b)\s*\d')   # a measured Expected
# a quality to measure: a word after a requirement cue or a bound with a unit; qa.qualityWords overrides ('' = off)
QUALITY = (r'(?i)\b(must|should|needs? to|has to|to be|so that|make[sd]?)\W+(\w+\W+){0,3}?(?P<w>fast(er)?|instant(ly)?|prominent|eye-catching|shiny|noticeable|'
           r'readable|legible)\b|(?:<|<=|≤|under|within|below|less than|at most)\s*(?P<n>\d+(?:\.\d+)?)\s*(?:ms|s|sec\w*|min\w*|px|%)(?!\w)')


def split_rows(md, prior=()):
    """AI doc case rows -> (fresh, earlier): earlier = a row unchanged from a published round (any agent's), grandfathered."""
    rows, seen = _table_rows(md, full=True)[0], {r for p in prior for r in _table_rows(p, full=True)[0]}
    return [r for r in rows if r not in seen], [r for r in rows if r in seen]


def _warn_earlier(where, earlier):
    """One WARN line per rule earlier rows break: they never block the caller's round."""
    for rule, ids in earlier.items():
        if ids:
            print(f'WARN {where}: {len(ids)} earlier row(s) {rule} ({", ".join(ids[:8])}{" ..." if len(ids) > 8 else ""}): grandfathered;'
                  ' their owner fixes them in a later round', file=sys.stderr)


def case_gaps(ai_md, human_md=None, task_md='', prior=(), where='testing-ai', human_prior=(), tid='', skip=()):
    """AI doc rule breaks of the rows this round adds or changes (prior / human_prior = published round bodies; earlier rows
    and checks: WARN only), each
    naming its fix (pre-existing waiver, qa.notLocal PASS, qa.matrix gap); with the human doc and task: a human check no AI row
    ran, a NOT_TESTED_LOCAL row no check carries, an unmeasured stated quality. -> [str]"""
    qa, out = CFG.get('qa') or {}, []
    rows, earlier = split_rows(ai_md, prior)
    passed = lambda r: (m := RAN.match(r or '')) and m.group(1).lower() == 'pass'
    local = lambda r: (m := RAN.match(r or '')) and m.group(1).lower() != 'pass'
    pre_of = lambda rs: [i for i, r, _, _ in rs if passed(r) and PRE_EXISTING.search(r)]
    old = {'waive a failure as pre-existing': pre_of(earlier)}
    if pre := pre_of(rows):
        out.append(f'row(s) {", ".join(pre)} waive a failure as pre-existing: a case here is the task\'s own check: FAIL it, fix it'
                   ' (only a step outside the doc can be pre-existing)')
    for d in qa.get('notLocal') or []:
        try:
            hit_of = lambda rs: [i for i, r, _, text in rs if passed(r) and re.search(d.get('match') or '(?!)', f'{i} | {text}', re.I)]
            hit, old[f'PASS on {d.get("name")} (qa.notLocal)'] = hit_of(rows), hit_of(earlier)
        except re.error as e:
            raise SystemExit(f'kit.local.json qa.notLocal {d.get("name")!r}: match is no regex ({e}): fix it')
        if hit:
            out.append(f'row(s) {", ".join(hit)} PASS on {d.get("name")}, not run locally (qa.notLocal; a stub proves nothing):'
                       ' NOT_TESTED_LOCAL naming the stub; the deployed run tests its human check')
    mx, norm = qa.get('matrix') or {}, lambda v: re.sub(r'[^a-z0-9.]+', '-', str(v).lower()).strip('-')
    want = [(k, str(v)) for k in ('viewports', 'fontScales', 'themes') for v in mx.get(k) or []]
    ui = lambda t: re.search(r'!\[|<img\b|\.(png|jpe?g)\b', t, re.I)
    if want and (ui(ai_md) if not prior else any(ui(' | '.join(r)) for r in rows + earlier)):
        toks = set(re.split(r'[\s,;_|()]+', ' '.join(re.findall(r'(?im)\bMatrix:(.*)$', ai_md)).lower()))   # values or matrix() tags
        miss = [v for k, v in want if norm(v) not in toks and not (k == 'fontScales' and 'f' + norm(v) in toks)]
        fresh_ui = not prior or any(ui(' | '.join(r)) for r in rows)
        if miss and fresh_ui:   # the cases and the exact line: 9 refusals listed values only
            cases = [r[0] for r in (rows if prior else rows + earlier) if r[0] and ui(' | '.join(r))]
            line = ', '.join(('f' if k == 'fontScales' else '') + norm(v) for k, v in want)
            out.append(f'UI cases miss qa.matrix value(s) {", ".join(miss)} (case(s) {", ".join(cases) or "with screenshots"}): run each'
                       f' per variant (browser.mjs matrix()), then add this line under the cases table: "Matrix: {line}"')
        elif miss:
            old[f'are UI cases missing qa.matrix value(s) {", ".join(miss)}'] = [r[0] for r in earlier if ui(' | '.join(r))]
    _warn_earlier(where, old)
    if human_md is not None:
        hnew, hold = split_rows(human_md, human_prior)
        hid = [r[0] for r in hnew + hold if r[0] and r[0] != '#']
        has = lambda h, i: re.search(rf'(?<![\w-]){re.escape(h)}(?![\w-])', i)   # the AI row's # cell names it: "A3 (T2)"
        ran = [h for h in hid if any(has(h, i) and RAN.match(r or '') for i, r, _, _ in rows + earlier)]
        _warn_earlier(where, {'are human checks no AI row ran': [r[0] for r in hold if r[0] not in ran]})
        if wait := [r[0] for r in hnew if r[0] in skip and r[0] not in ran]:   # another agent's: its finish runs them
            print(f'[{where}] human check(s) {", ".join(wait)} belong to other agents: WAIT', file=sys.stderr)
        if unran := [r[0] for r in hnew if r[0] and r[0] != '#' and r[0] not in ran and r[0] not in skip]:
            add = ', '.join(f'{{"id": "A<n>", "type": "positive", "check": "{h}", ...}}' for h in unran)
            out.append(f'human check(s) {", ".join(unran)} have no AI row that ran them: the loop runs each'
                       ' (its AI row\'s # cell names it: "A3 (T2)")' + (f'; devtools.py cases add {tid} with case(s) {add}, cases result once run,'
                       f' then devtools.py doc "<title>" cases --key {tid}:testing-ai' if tid else ''))
        orphan = [i for i, r, _, _ in rows if local(r) and not any(has(h, i) for h in hid)]
        if orphan:
            out.append(f'row(s) {", ".join(orphan)} are NOT_TESTED_LOCAL but no human check carries them:'
                       ' add one (the deployed run is its only test), named in the # cell')
    words = qa.get('qualityWords', QUALITY)
    if words:
        try:
            found = list(re.finditer(words, task_md or ''))
        except re.error as e:
            raise SystemExit(f'kit.local.json qa.qualityWords is no regex ({e}): fix it, or "" to turn the check off')
        stem = lambda w: re.sub(r'(er|ly)$', '', w.lower())
        terms = {(g.get('n') or stem(g.get('w') or m.group(0))) for m in found for g in [m.groupdict()]}
        miss = sorted(t for t in terms if not any(re.search(rf'(?<![\w.]){re.escape(t)}', text.lower()) and THRESHOLD.search(text) for *_, text in rows + earlier))
        if miss:
            out.append(f'the task states {", ".join(repr(t) for t in miss)}: add a case per term measuring it, a threshold in'
                       ' Expected (contrast() >= 3, layoutIssues() count = 0, p95 of 5 runs <= the bound)')
    return out


def bare_evidence(rows):
    """Ids of rows with a Result but no evidence a reader can open (a link, an inline image): a test name or 'same' proves nothing."""
    return [i for i, r, e in rows if not NO_RUN.fullmatch(r or '') and not EVIDENCE_LINK.search(e or '')]


def _round_rows(md):
    """The first cells (round numbers) of the AI doc's Rounds table; None without one."""
    m = ROUNDS_TABLE.search(md or '')
    return None if not m else [_cells(l)[0] for l in m.group(1).splitlines() if l.strip()]


def _after(a, b):
    """Record a (round or run) is newer than b: by seq, else by minute."""
    return a['seq'] > b['seq'] if 'seq' in a and 'seq' in b else a['at'] >= b['at']


def _compose(title, rounds, runs=(), kind=''):
    """The newest version on top (Result / Evidence filled from the env runs newer than that version, _runs_cells: a fix round
    after a run starts empty), then env runs and earlier rounds newest first under dated headings ('## <env> run <date>',
    '## Round <n> — <date>'), each kept whole; the human doc (testing-doc) keeps only earlier rounds an env run tested, the
    rest become one 'Replaced drafts (not tested): <dates>' line; one round, no run = unchanged. -> (text, ext)"""
    top = rounds[-1]
    if runs and top['ext'] == '.md' and _after(runs[-1], top):
        top = dict(top, body=_table_rows(top['body'], _runs_cells(top['body'], [r for r in runs if _after(r, top)]))[1])   # every run of this version
    ran = {max(i for i, r in enumerate(rounds) if i == 0 or _after(u, r)) for u in runs}   # each run tested the newest round before it
    shown = [i for i in range(len(rounds) - 1) if kind != 'testing-doc' or i in ran]
    days = sorted({rounds[i]['at'][:10] for i in range(len(rounds) - 1) if i not in shown})
    note = f'Replaced drafts (not tested): {", ".join(days)}' if days else ''
    secs = [(f'{r["label"] or "env"} run {r["at"]}', r) for r in reversed(runs)]
    secs += [(f'Round {i + 1} — {rounds[i]["at"]}{" " + rounds[i]["label"] if rounds[i]["label"] else ""}', rounds[i]) for i in reversed(shown)]
    if not secs and not note:
        return top['body'], top['ext']
    if any(r['ext'] == '.html' for r in [top] + [r for _, r in secs]):
        h = lambda r: _body_of(r['body'] if r['ext'] == '.html' else md_to_html(r['body']))
        body = h(top) + (f'<p>{html.escape(note)}</p>' if note else '') + ''.join(f'<h2>{html.escape(n)}</h2>{h(r)}' for n, r in secs)
        return f'<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title></head><body>{body}</body></html>', '.html'
    return top['body'].rstrip() + ''.join(f'\n\n{x}' for x in ([note] if note else []) + [f'## {n}\n\n{_demote(r["body"]).strip()}' for n, r in secs]) + '\n', '.md'


def _check_doc(kind, scope, path, body, prior=()):
    """testing-doc (human, positive cases, after the loop PASS) / testing-ai (the local loop record, every case): their tables;
    row rules judge only rows not in a published round (prior: their bodies), so one agent's round passes on a shared doc."""
    if GOALS_MARK.search(body):
        raise SystemExit(f'{path} is the local goals file (templates.md "Test cases"): never published; publish the AI doc'
                         ' (`doc "<title>" cases --key <task>:testing-ai`) and, after the loop PASS, the human doc. Nothing was published.')
    hh = human_head()
    tb, name, tpl = (CHECKS_TABLE if hh == HUMAN_HEAD else re.compile(r'(?im)^\|\s*' + r'\s*\|\s*'.join(map(re.escape, hh)) + r'\s*\|'), '| ' + ' | '.join(hh) + ' |', 'Human testing doc') if kind == 'testing-doc' else \
        (AI_TABLE, '| # | Type | Steps / API call + payload | Expected | Result | Evidence |', 'Testing doc (AI)')
    tb = next((re.compile(d['headerRx']) for d in docs() if d['key'] == kind and d['headerRx']), tb)   # process.docs[].headerRx
    if not tb.search(body):
        raise SystemExit(f'{path} has no case table "{name}" (templates.md "Test cases"). Nothing was published.')
    neg = re.search(r'(?im)^\|[^\n]*\|\s*negative\s*\|', body)
    if kind == 'testing-doc' and neg:
        raise SystemExit(f'{path} has a negative row: the human doc holds positive cases only; negative ones go in the AI doc. Nothing was published.')
    if kind == 'testing-doc' and (re.search(r'!\[', body) or any(r or e for _, r, e in _table_rows(body)[0])):
        raise SystemExit(f'{path} has evidence or results: the human doc ships with Result / Evidence empty; a deployed-env run fills them'
                         ' (local evidence lives in the AI doc). Nothing was published.')
    if kind == 'testing-doc' and (api := [r[0] for r in split_rows(body, prior)[0] if API_WORDS.search(r[3])]):
        raise SystemExit(f'{path}: row(s) {", ".join(api)} name an API call or endpoint: a human check says what a person clicks or types and'
                         ' what they see on screen (templates.md "Test cases"). Nothing was published.')
    if kind == 'testing-ai':
        if not neg:
            raise SystemExit(f'{path} has no negative row: the AI doc covers every positive and negative case (templates.md "Test cases"). Nothing was published.')
        fresh, earlier = split_rows(body, prior)
        _warn_earlier(f'{scope}:{kind}', {'lack an Evidence link': bare_evidence([r[:3] for r in earlier])})
        bare = bare_evidence([r[:3] for r in fresh])
        if bare:
            raise SystemExit(f'{path}: row(s) {", ".join(bare)} have a Result but no Evidence link: upload the screenshot, request + response JSON'
                             ' or test run output (devtools.py evidence) and put its link or inline image in the cell, never a bare file or test name.'
                             ' Nothing was published.')
        gaps = case_gaps(body, prior=prior, where=f'{scope}:{kind}')
        if gaps:
            raise SystemExit(f'{path}: ' + '; '.join(gaps) + '. Nothing was published.')
        return   # published every loop round: it is the loop's record
    ok, ev = local_pass(scope)
    if not ok:
        raise SystemExit(f'{kind} of {scope} refused: its local test loop is {"at " + repr(ev) if ev else "not recorded"}, not PASS.'
                         f' Run the loop until every case passes, then `crafty.ps1 checkpoint -Step loop -Item {scope} -Evidence "round <n> PASS"`.'
                         ' Nothing was published.')


def publish(key, title, path, parent=None, mode=None, label='', run=None, run_id=''):
    """Publish or update by key: the first call creates the doc, later calls update the same doc (append: a dated round on top,
    earlier rounds below; replace: the new text only). run = {check id: {result, evidence, case, screen}} of a deployed-env run
    (pokey finalize on <task>:testing-doc): fills the human doc's Result / Evidence per row (_row_cells) and adds the report as a
    dated '<env> run' section; run_id: a re-publish of the same run replaces its section; no human doc yet -> the report is
    published as <scope>:qa-report."""
    scope, _, kind = key.rpartition(':')
    if not scope or not kind:
        raise SystemExit(f'--key {key!r}: use <task or run>:<kind>, e.g. 86abc:testing-doc')
    with open(path, encoding='utf-8') as fh:
        body = fh.read()
    if run is not None and not _pub_read(key).get('rounds'):
        key, kind, run = f'{scope}:qa-report', 'qa-report', None
    if kind in ('testing-doc', 'testing-ai') and run is None:
        _check_doc(kind, scope, path, body, [r['body'] for r in _pub_read(key).get('rounds') or []])
    if path.lower().endswith('.md') and not PROSE_OK and (gaps := doc_section_gaps('qa-report' if run is not None else kind, body)):
        raise SystemExit(f'{path}: {kind} sections (templates.md "Writing standards"): {"; ".join(gaps)}. Nothing was published.')
    bare = bare_evidence([(i, (c or {}).get('result'), (c or {}).get('evidence')) for i, c in (run or {}).items()])
    if bare:
        print(f'[publish] {key}: run row(s) {", ".join(bare)} have a Result but no Evidence link or inline image', file=sys.stderr)
    if kind in ('testing-doc', 'testing-ai') and mode == 'replace':
        print(f'[publish] {key}: a testing doc keeps every round and run: --mode replace ignored', file=sys.stderr)
        mode = 'append'
    f = _pub_file(key)
    with locked(f):
        rec = _pub_read(key)
        rounds, runs = list(rec.get('rounds') or []), list(rec.get('runs') or [])
        if kind == 'testing-ai' and run is None:   # the loop history: appended, never rewritten
            had, have = _round_rows(rounds[-1]['body']) if rounds else None, _round_rows(body)
            if have is None and (not rounds or had is not None):
                raise SystemExit(f'{path} has no Rounds table "| Round | Date | Cases run | Result | Bugs found | Fix commit | Retest |" (templates.md'
                                 ' "Test cases"): one row per loop round. Nothing was published.')
            lost = [r for r in had or [] if r not in have]
            if lost:
                raise SystemExit(f'{path} dropped Rounds row(s) {", ".join(lost)} of the published doc: rounds are appended, earlier rows stay. Nothing was published.')
            if have is None:
                print(f'[publish] {key}: no Rounds table (a doc from before it): add one from templates.md "Test cases"', file=sys.stderr)
        new = {'at': time.strftime('%Y-%m-%d %H:%M'), 'seq': time.time(), 'label': label, 'ext': os.path.splitext(path)[1].lower(), 'body': body}
        stale = bool(rounds and runs) and _after(runs[-1], rounds[-1])
        if run is not None:
            runs = [r for r in runs if not (run_id and r.get('id') == run_id)] + [dict(new, cells=run, **({'id': run_id} if run_id else {}))]
            if rounds and (gap := run_gaps(rounds[-1]['body'], run, [r for r in runs[:-1] if _after(r, rounds[-1])])):
                print(f'[publish] {key}: row(s) {", ".join(gap)} no run covers stay empty', file=sys.stderr)
        elif kind in ('testing-doc', 'testing-ai') and rounds and rounds[-1]['body'] == body and not stale:
            pass   # same text again (finish after the last loop round): no new round
        else:
            rounds = (rounds if (mode or PUB_KINDS.get(kind, 'replace')) == 'append' else []) + [new]
        old = rec.get('rounds') or []   # v<n>: +1 per new text, never for the same text again
        ver = int(rec.get('ver') or len(old)) + (1 if rounds and rounds[-1] is new and (not old or old[-1].get('body') != body) else 0)
        title = doc_title(scope, kind, rec.get('title') or title, max(ver, 1))
        url = _render(key, rec, title, rounds, runs, parent)
        _pub_write(key, {**rec, 'key': key, 'title': title, 'ver': max(ver, 1), 'url': url, 'type': REPORT_TYPE,
                         'updated': new['at'], 'rounds': rounds, 'runs': runs})
    return url


DOC_KIND_NAMES = {'testing-goals': 'Testing goals', 'testing-doc': 'Testing doc', 'testing-ai': 'Testing doc (AI)', 'qa-report': 'QA report',
                  'spec': 'Spec', 'brief': 'Brief', 'retro': 'Retro', 'runbook': 'Runbook'}


def doc_title(scope, kind, title, ver):
    """A keyed task's doc (naming on): `<KEY> <Kind> v<n> — <outcome>` (kitbag.py naming make doc), the outcome from the task name;
    else the given title (old style: accepted one version, warned)."""
    k = task_key(scope)
    if not k:
        if naming_on() and not re.match(KEY_RX, str(title)):
            print(f'[publish] {scope}:{kind}: no kit key on {scope}: old-style title {title!r} kept (one version; tracker create keys new tasks)', file=sys.stderr)
        return title
    nm = re.sub(r'\s*\(was [^)]*\)\s*$', '', _KEYS.get(f'name:{scope}', ''))
    out = nm[km.end():].strip() if (km := re.match(KEY_RX, nm)) else re.sub(rf'^\S+ v\d+ — ', '', str(title))   # make's clean drops an old [Type] Area: head
    return naming().make('doc', {'key': k, 'kind': DOC_KIND_NAMES.get(kind, kind.replace('-', ' ').capitalize()), 'ver': ver, 'title': out})


def _render(key, rec, title, rounds, runs, parent=None):
    """Compose a key's rounds and runs and publish them over its earlier doc -> URL."""
    text, ext = _compose(title, rounds, runs, key.rpartition(':')[2])
    tg = doc_tags(key.rpartition(':')[0])
    text = with_tags(text, ext, tg) if naming_on() else text   # naming off: the doc as before
    out = os.path.join(kit_path('docs', create=True), re.sub(r'[^\w.-]+', '_', key) + ext)
    with open(out, 'w', encoding='utf-8', newline='') as fh:
        fh.write(text)
    own = {'markdown': out, 'html': os.path.splitext(out)[0] + '.doc.html'}.get(REPORT_TYPE)   # kept types: one file per key, never per title
    url = make_doc(title, out, parent, rec.get('url') or own, tg, rec.get('tags') or ())
    rec['tags'] = tg   # the caller writes rec: the next publish nulls tags gone since
    if rec.get('url') and url != rec['url']:
        print(f'[publish] {key}: reports.type {REPORT_TYPE} could not update {rec["url"]} in place: new link {url}', file=sys.stderr)
    return url


def relayout(ref):
    """Republish a published doc (key <task or run>:<kind>, or its URL) from its record with the current layout: same rounds,
    runs and link, no new round."""
    key = ref
    if re.match(r'https?://', ref):
        did = (re.search(r'/d/([\w-]+)', ref) or [None, ref])[1]
        recs = [r for r in (state_read(p) or {} for p in glob.glob(os.path.join(kit_path('published', create=True), '*.json'))) if r.get('key') and did in str(r.get('url') or '')]
        if len(recs) != 1:
            sys.exit(f'relayout {ref}: ' + (f'{len(recs)} published records hold this link: pass its key' if recs else 'no published record holds this link (.state/published)'))
        key = recs[0]['key']
    with locked(_pub_file(key)):
        rec = _pub_read(key)
        if not rec.get('rounds'):
            sys.exit(f'relayout {key}: no published record (.state/published): publish it with devtools.py doc --key first')
        url = _render(key, rec, rec['title'], rec['rounds'], rec.get('runs') or [])
        _pub_write(key, {**rec, 'url': url, 'type': REPORT_TYPE, 'relaid':time.strftime('%Y-%m-%d %H:%M')})
    return url


ADAPTERS.setdefault('report', {})   # gdocs (Google Doc + Drive evidence): adapters/report_gdocs.py
# adapter:report/markdown: the file, kept (an earlier publish: the same file)
ADAPTERS['report']['markdown'] = {'publish': lambda a: keep_doc(a['title'], a['path'], a['keep'], a.get('url'))}
# adapter:report/html: Markdown -> HTML (md_to_html), kept
ADAPTERS['report']['html'] = {'publish': lambda a: keep_doc(a['title'], _html_of(a), a['keep'], a.get('url'))}


# adapter:report/command: reports.command {title} {path} {parent} {url} (earlier publish: update); last output word = URL
def _command(a):
    c = RCFG.get('command') or sys.exit('reports.type command needs reports.command')
    for k, v in (('title', a['title']), ('path', a['path']), ('parent', a['parent'] or a['keep'] or ''), ('url', a.get('url') or '')):
        c = c.replace('{' + k + '}', _q(v))
    r = subprocess.run(c, shell=True, capture_output=True, text=True, errors='replace', timeout=300)
    u = (r.stdout.split() or [''])[-1]
    return u if u and not r.returncode else sys.exit(f'reports.command failed (exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}')


ADAPTERS['report']['command'] = {'publish': _command}
# adapter-end:report


# evidence store command: reports.evidenceCommand {name} {parent} {files} (each file quoted); prints '<file name> <URL>' per
# file, the URL last (a folder link line: 'folder <URL>'); a failure keeps the files in the run folder
def _evidence_command(a):
    c = RCFG.get('evidenceCommand') or sys.exit('reports.evidence command needs reports.evidenceCommand')
    c = c.replace('{name}', _q(a['name'])).replace('{parent}', _q(a.get('parent') or '')).replace('{files}', ' '.join(_q(f) for f in a['files']))
    r = subprocess.run(c, shell=True, capture_output=True, text=True, errors='replace', timeout=600)
    if r.returncode:
        print(f'reports.evidenceCommand failed (exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}; evidence stays in the run folder', file=sys.stderr)
        return {}
    got = dict(ln.rsplit(None, 1) for ln in r.stdout.splitlines() if len(ln.rsplit(None, 1)) == 2)   # the URL last: a file name may hold spaces
    return {'folderLink': got.pop('folder', ''), 'label': a['name'], 'files': {k: {'src': v.strip(), 'link': v.strip()} for k, v in got.items()}}


# ---- render: agent-written artefacts from small specs (one renderer per kind; agents never write the Markdown)
# lists merged by key on update; any other key replaces
SPEC_KEYS = {'checks': 'id', 'qualities': 'id', 'unchanged': 'id', 'cases': 'id', 'rounds': 'round', 'switches': 'setting',
             'outOfScope': 'item', 'changes': 'text', 'risks': 'text', 'mrs': 'url', 'checksRun': 'name'}
CASE_TYPES = ('positive', 'negative', 'edge', 'regression', 'repro')


def merge_spec(old, new, keys=None):
    """new into old: SPEC_KEYS (or keys) lists by key (an entry's fields merged), other keys replaced; None deletes."""
    out = dict(old or {})
    for k, v in (new or {}).items():
        key = (keys or SPEC_KEYS).get(k)
        if v is None:
            out.pop(k, None)
        elif key and isinstance(v, list):
            by = {str(e.get(key)): dict(e) for e in out.get(k) or [] if isinstance(e, dict)}
            for e in v:
                if not isinstance(e, dict) or e.get(key) in (None, ''):
                    raise SystemExit(f'spec {k}: each entry is an object with {key!r}: {str(e)[:80]}')
                if e.get('_del'):   # {"<key>": ..., "_del": true} removes that entry
                    by.pop(str(e[key]), None)
                    continue
                by[str(e[key])] = {**by.get(str(e[key]), {}), **e}
            out[k] = list(by.values())
        else:
            out[k] = v
    return out


def _cell(v):
    """A table cell: one line, pipes escaped."""
    return re.sub(r'\s*\n\s*', ' ', ' · '.join(map(str, v)) if isinstance(v, list) else str(v if v is not None else '')).replace('|', '\\|').strip()


def _table(head, rows):
    return '\n'.join(['| ' + ' | '.join(head) + ' |', '|' + '---|' * len(head)] + ['| ' + ' | '.join(_cell(c) for c in r) + ' |' for r in rows])


EV_TYPES = {'png': 'screenshot', 'jpg': 'screenshot', 'jpeg': 'screenshot', 'gif': 'screenshot', 'webp': 'screenshot', 'json': 'json', 'har': 'har',
            'log': 'log', 'txt': 'log', 'out': 'log', 'mp4': 'video', 'webm': 'video', 'mov': 'video', 'html': 'page', 'pdf': 'pdf', 'csv': 'csv',
            'xml': 'xml', 'sql': 'sql', 'md': 'notes'}


def _ev_type(name):
    """The link text for an evidence file: its type (json, screenshot, log, video ...), never a URL segment such as 'view'."""
    ext = name.rsplit('.', 1)[-1].lower() if '.' in name else ''
    return EV_TYPES.get(ext, ext if 1 < len(ext) <= 5 and ext.isalnum() else 'file')


def _ev(cid, ev):
    """Evidence: an image URL inline, another URL as a link named by its type; '<file>=<url>' (devtools.py evidence prints
    the names) types a host link without one (a Drive /view link); text as is."""
    def one(e):
        named = re.match(r'([\w.\-]+)=(https?://\S+)$', e)
        name, url = (named[1], named[2]) if named else ('', e)
        if not re.match(r'https?://\S+$', url):
            return e
        if not named and re.match(r'https?://\S+\.(png|jpe?g|gif|webp)(\?\S*)?$', url, re.I):
            return f'![{cid}]({url})'
        return f'[{_ev_type(name or re.sub(r"[?#].*", "", url).rstrip("/").rsplit("/", 1)[-1])}]({url})'
    return ' · '.join(one(e) for e in (str(x).strip() for x in (ev if isinstance(ev, list) else [ev] if ev else [])))


def _verdict(results):
    rs = [str(r).upper() for r in results if r]
    return 'FAIL' if any(r.startswith('FAIL') for r in rs) else 'PASS' if rs and len(rs) == len(results) and all(r.startswith('PASS') for r in rs) else ''


def cases_gaps(c):
    """A cases spec's shape errors (the doc gates judge the rendered text)."""
    ids = [x.get('id') for k in ('checks', 'qualities', 'unchanged') for x in c.get(k) or []]
    out = [f'case {x.get("id") or "?"}: type {x.get("type")!r} (one of {"/".join(CASE_TYPES)})' for x in c.get('cases') or [] if x.get('type') not in CASE_TYPES]
    out += [f'case {x["id"]}: check {x["check"]!r} is no checks/qualities/unchanged id' for x in c.get('cases') or [] if x.get('check') and x['check'] not in ids]
    out += [f'{k}: an entry without {SPEC_KEYS[k]}' for k in ('checks', 'qualities', 'unchanged', 'cases') for x in c.get(k) or [] if not x.get(SPEC_KEYS[k])]
    out += [f'check {x["id"]}: steps / expected name an API call or endpoint; a human check says what a person clicks or types and sees'
            ' (a backend change through the UI action that triggers it; no UI trigger: noUi, steps = the screen or log where its effect shows)'
            for x in c.get('checks') or []   # process.humanDocUiOnly false: a human check may name API calls
            if x.get('id') and cfg('process.humanDocUiOnly', True) is not False and API_WORDS.search(f'{x.get("steps", "")} {x.get("expected", "")}')]
    out += [f'{k} {x.get("id")}: spec {v!r} is no S-id (S<n> or <subject>:S<n>)' for k in ('checks', 'cases') for x in c.get(k) or []
            for v in _as_list(x.get('spec')) if not SID_REF.match(str(v))]
    out += [f'{k}: an object' for k in ('plan',) if c.get(k) and not isinstance(c[k], dict)]
    return out + ([] if c.get('title') else ['title'])


SID_REF = re.compile(r'^(?:[\w.-]+:)?S\d+$')   # a spec rule id a check, case, MR or QA result cites


def _as_list(v):
    return [x for x in (v if isinstance(v, list) else re.split(r'[\s,]+', str(v)) if v else []) if str(x).strip()]


def _sids(x):
    """' [S1, S2]': the spec rules a check or case proves (its 'spec' field), cited in every rendered doc."""
    return f' [{", ".join(map(str, _as_list(x.get("spec"))))}]' if _as_list(x.get('spec')) else ''


def render_cases(c, kind, tid=''):
    """The goals file, AI doc or human doc (templates.md "Test cases") from one cases spec."""
    cases, head = c.get('cases') or [], f'{tid} {c.get("title", "")}'.strip()
    of = lambda cid: [x for x in cases if x.get('check') == cid]
    rnd = c.get('rounds') or []
    if kind == 'goals':
        row = lambda g, gid: [gid, (g.get('goal') or g.get('expected') or g.get('steps', '')) + _sids(g), g.get('how') or ' · '.join(
                              filter(None, [f'UI: {g["steps"]}' if g.get('steps') and g.get('expected') else '', ', '.join(x['id'] for x in of(g['id']))])),
                              g.get('rule') or g.get('expected', ''), _verdict([x.get('result') for x in of(g['id'])]) if of(g['id']) else '']
        goals = [row(g, f'G{i} ({g["id"]})') for i, g in enumerate(c.get('checks') or [], 1)] + [row(g, g['id']) for k in ('qualities', 'unchanged') for g in c.get(k) or []]
        plan = c.get('plan') or {}
        return '\n\n'.join([f'# Testing goals: {head}', f'Change: {c.get("change", "")}. Repos/MRs: {_cell(c.get("repos", ""))}. Local env: {c.get("env", "none")}, services {_cell(c.get("services", "none"))}.',
                          '## Goals (what must be true)', 'Before merge (each human check; Q = a stated quality, measured):',
                          _table(['#', 'Goal', 'How checked', 'Pass rule', 'Result'], goals), '## Test plan (automated)']
                         + ([f'- {k}: {_cell(v)}' for k, v in plan.items() if v] or ['n/a — no automated test planned']) + ['## Data needed', c.get('data') or 'n/a — no test data needed', '## Reproduction (bugs)', c.get('repro') or 'n/a — not a bug',
                         '## Rounds', _table(['Round', 'What failed', 'Fix'], [[r.get('round'), r.get('bugs') or 'none', r.get('fix') or ''] for r in rnd])]) + '\n'
    if kind == 'ai':
        rows = [[f'{x["id"]} ({x["check"]})' if x.get('check') else x['id'], x.get('type'), x.get('steps', ''), x.get('expected', '') + _sids(x), x.get('result') or '',
                 _ev(x['id'], x.get('evidence'))] for x in cases]
        return '\n\n'.join([f'# Testing doc (AI): {head}', f'Setup and cleanup: {c.get("setup") or "n/a — no setup"}.', 'Cases:',
                          _table(['#', 'Type', 'Steps / API call + payload', 'Expected', 'Result', 'Evidence'], rows)]
                         + [f'Matrix: {_cell(c["matrix"]) if c.get("matrix") else "n/a — no qa.matrix variant"}']
                         + ['Rounds (one per round, appended):', _table(['Round', 'Date', 'Cases run', 'Result', 'Bugs found', 'Fix commit', 'Retest'],
                            [[r.get(k, '') for k in ('round', 'date', 'cases', 'result', 'bugs', 'fix', 'retest')] for r in rnd])]) + '\n'
    if kind != 'human':
        raise SystemExit(f'cases render: kind {kind!r}: goals | ai | human')
    areas, hh = {}, human_head()
    for t in c.get('checks') or []:   # a column by its name: '#', *step*, *expect*; the rest stay empty for the run
        st = (f'**No UI trigger** ({t["noUi"]}): ' if t.get('noUi') else '') + t.get('steps', '')
        areas.setdefault(t.get('area') or 'Checks', []).append([t['id'] if h == '#' else st if 'step' in h.lower() else t.get('expected', '') + _sids(t) if 'expect' in h.lower() else '' for h in hh])
    sw, oos = c.get('switches') or [], c.get('outOfScope') or []
    return '\n\n'.join([f'# Testing: {c.get("title", "")}', _table(['', ''], [['Tasks', c.get('tasks') or tid], ['Environment', c.get('environment') or ''],
                      ['Logins', c.get('logins') or ''], ['Test data', c.get('testData') or '']]), '## What changed', c.get('whatChanged') or c.get('change', ''),
                      '## Before you start / Feature switches'] + (['Set these first, restore them after:', _table(['Setting', 'Where', 'Value'],
                      [[s.get('setting'), s.get('where', ''), s.get('value', '')] for s in sw])] if sw else ['n/a — no feature switch to set'])
                     + ['## Checks', ('Do each check in the app as a user would; a screenshot of what you see, every check; network or log JSON'
                        ' from that action only as extra evidence. "No UI trigger": check the visible effect it names.') if cfg('process.humanDocUiOnly', True) is not False
                        else 'Do each check as its steps say (UI or API); evidence for every check.']
                     + [f'{a}:\n\n' + _table(human_head(), r) for a, r in areas.items()]
                     + ['## Out of scope'] + ([_table(['Item', 'Why'], [[o.get('item'), o.get('why', '')] for o in oos])] if oos else ['n/a — nothing left out'])
                     + ['## Result (testers)', 'All checks pass -> close the task. A check of this change fails or could not be tested -> failedTesting with the'
                        ' check ids and why. A defect outside this change -> one [Bug] task under the original ask.']) + '\n'


def cases_file(tid, kind):
    """<task>'s cases spec rendered to work/docs/<task>-<kind>.md -> its path (refused on spec gaps)."""
    c = (state_read(task_file(tid)) or {}).get('cases')
    if not c:
        raise SystemExit(f'task {tid} has no cases spec: devtools.py cases add {tid} <spec.json> first')
    if gaps := cases_gaps(c):
        raise SystemExit(f'cases spec of {tid}: ' + '; '.join(gaps))
    txt = render_cases(c, kind, tid)
    out = os.path.join(kit_path('docs', create=True), re.sub(r'[^\w.-]+', '_', f'{tid}-{kind}') + '.md')
    with open(out, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(txt)
    return out


def me_agent():
    return os.environ.get('CLAUDE_AGENT') or os.environ.get('KIT_AGENT') or ''


def own_spec(old, new, replace=False):
    """cases add on a shared task: entries tagged by the caller; another agent's id refused, its title / change kept."""
    me, by, _ = me_agent(), old.get('by'), new.pop('by', None)
    owners = sorted(({str(by)} if by else set()) | {str(e['by']) for k in SPEC_KEYS for e in old.get(k) or [] if isinstance(e, dict) and e.get('by')})
    if not me and owners:   # an unnamed caller would overwrite agents' rows (retro 2026-11-18)
        raise SystemExit(f'cases add: this spec holds rows of {", ".join(owners)}: set CLAUDE_AGENT=<your agent id> and add again. Nothing was written.')
    for k in ('cases', 'checks', 'qualities', 'unchanged') if me else ():
        es = [e for e in new.get(k) or [] if isinstance(e, dict)]
        theirs = {str(e.get('id')): e['by'] for e in old.get(k) or [] if isinstance(e, dict) and e.get('by') not in (None, me)}
        if clash := [f'{e["id"]} ({theirs[str(e["id"])]})' for e in es if str(e.get('id')) in theirs]:
            raise SystemExit(f'cases add: {k} id(s) {", ".join(clash)} belong to another agent: use your own ids ({me}-<id>). Nothing was written.')
        for e in es:
            e.setdefault('by', me)
    if me and not by:
        new['by'] = me   # the first adder owns the top-level fields
    elif me and by != me and not replace:   # title / change: first wins; other fields merged per item ('<old>; <agent>: <new>')
        for k in [k for k in new if k not in SPEC_KEYS and old.get(k) not in (None, '', new[k])]:
            o, v = old[k], new[k]
            if k not in ('title', 'change') and isinstance(o, dict) == isinstance(v, dict) and isinstance(o, list) == isinstance(v, list):
                new[k] = _merge_val(o, v, me)
            else:
                print(f'cases add: {k} kept ({str(o)[:60]!r}, set by {by}; --replace to change it)', file=sys.stderr)
                new.pop(k)


def _merge_val(o, v, me):
    """One shared-spec scalar: the second agent's value appended once ('<old>; <agent>: <new>')."""
    if isinstance(o, dict) and isinstance(v, dict):
        return {**o, **{k: _merge_val(o.get(k), x, me) for k, x in v.items()}}
    if isinstance(o, list) and isinstance(v, list):
        return o + [e for e in v if e not in o]
    if o in (None, ''):
        return v
    if v in (None, '') or str(v) == str(o) or isinstance(o, (dict, list)) or isinstance(v, (dict, list)):   # a type clash: first wins
        return o
    return o if f'{o}'.endswith(f'; {me}: {v}') or f'; {me}: {v}; ' in f'{o}; ' else f'{o}; {me}: {v}'


USAGE_EXAMPLES = {'evidence': 'python -X utf8 devtools.py evidence "T1 local run" shots/t1-list.png api/t1-get.json --key T1:evidence',
                  'doc': 'python -X utf8 devtools.py doc "T1 testing doc (AI)" ai-t1.md --key T1:testing-ai'}


def cases_cmd(a):
    """cases add <task> <spec.json|JSON> [--replace] · result <task> <id> <PASS|FAIL|...> [<evidence> ...] · round <task> [--fix <sha>] [--bugs <t>]
    [--retest <t>] · render <task> goals|ai|human -> the rendered file's path · show <task>: cases, results, rounds, gaps. Examples (one per verb):
      python -X utf8 devtools.py cases show T1
      python -X utf8 devtools.py cases add T1 cases-t1.json
      python -X utf8 devtools.py cases result T1 A1 PASS A1_resp.json=https://drive.example/file/d/1Ab/view
      python -X utf8 devtools.py cases round T1 --fix 1a2b3c4 --bugs none
      python -X utf8 devtools.py cases render T1 ai"""
    verbs = ('add', 'result', 'round', 'render', 'show')
    if a and a[0] in ('--help', '-h', 'help'):   # 47 of 61 usage errors (2026-11-18..21) were help asks: usage, exit 0
        print(cases_cmd.__doc__)
        return 0
    if len(a) >= 2 and a[0] not in verbs and a[1] in verbs:   # cases <task> <verb> ...: the common swapped form
        a = [a[1], a[0]] + list(a[2:])
    if len(a) < 2 or a[0] not in verbs:
        print(cases_cmd.__doc__, file=sys.stderr)
        near = difflib.get_close_matches(a[0].lower(), verbs, 1, 0.5) if a and a[0] not in verbs else []   # retro 2205: 30 usage errors
        print(f'did you mean: cases {near[0]} (see its example above)' if near else f'cases {a[0]} needs <task> first (example above)' if a and a[0] in verbs else 'cases <verb> <task> ...: verbs ' + ', '.join(verbs), file=sys.stderr)
        return 2
    verb, tid, rest = a[0], a[1], a[2:]
    if verb == 'show':   # read-only: what an agent wanted from "cases show" (retro tidy-20261124-01)
        c = (state_read(task_file(tid)) or {}).get('cases')
        if not c:
            print(f'task {tid} has no cases spec: devtools.py cases add {tid} <spec.json> first')
            return 1
        print(f'cases {tid}: {c.get("title") or "(no title)"} · {len(c.get("rounds") or [])} round(s)')
        for k in c.get('cases') or []:
            print(f'  {k.get("id")} · {k.get("type") or "?"} · {k.get("result") or "open"}' + (f' (round {k["ran"]})' if k.get('ran') else ''))
        for r in c.get('rounds') or []:
            print(f'  round {r.get("round")}: {r.get("result") or "-"}' + (f' · failed {r["failed"]}' if r.get('failed') else ''))
        for g in cases_gaps(c):
            print(f'  GAP {g}')
        return 0
    if verb == 'render':
        print(cases_file(tid, rest[0] if rest else 'ai'))
        return 0
    opt = {rest[i][2:]: rest[i + 1] for i in range(len(rest) - 1) if rest[i] in ('--fix', '--bugs', '--retest')}
    if verb == 'add':
        if not (rest and os.path.isfile(rest[0])):
            raise SystemExit('cases add <task> <spec.json>: write the spec to a file first (inline JSON loses its quotes on Windows)')
        try:
            new = json.loads(open(rest[0], encoding='utf-8-sig').read())
        except ValueError as e:
            raise SystemExit(f'cases add: {rest[0]} is no JSON ({e})')
        if not isinstance(new, dict):
            raise SystemExit('cases add: the spec is one JSON object (templates.md "Test cases")')
    elif verb == 'result':
        if len(rest) < 2:
            raise SystemExit('cases result <task> <case id> <PASS|FAIL|NOT_TESTED_LOCAL ...> [<evidence link> ...]\n'
                             '  e.g. python -X utf8 devtools.py cases result T1 A1 PASS https://drive.example/a1.png')
        new = {'cases': [{'id': rest[0], 'result': rest[1], 'evidence': rest[2:]}]}   # evidence replaced: an old FAIL's link never stays
    gaps, mgap = [], ''

    def change(x):
        nonlocal gaps, mgap
        c = x.get('cases') or {}
        if verb == 'result' and rest[0] not in [k.get('id') for k in c.get('cases') or []]:
            ids = ', '.join(str(k.get('id')) for k in c.get('cases') or []) or 'none'
            raise SystemExit(f'cases result: {tid} has no case {rest[0]}; its cases: {ids} (a new one: cases add it first)')
        n = len(c.get('rounds') or []) + 1   # the round in progress
        if verb == 'result':
            new['cases'][0]['ran'] = n
        if verb == 'round':
            ran = [k for k in c.get('cases') or [] if k.get('result') and k.get('ran', n) == n]   # only cases run this round
            cnt = {}
            for k in ran:
                w = str(k['result']).split()[0].upper()
                cnt[w] = cnt.get(w, 0) + 1
            c = merge_spec(c, {'rounds': [{'round': n, 'date': time.strftime('%Y-%m-%d'), 'cases': ', '.join(k['id'] for k in ran),
                                           'result': ', '.join(f'{v} {w}' for w, v in cnt.items()), 'bugs': opt.get('bugs') or 'none',
                                           'fix': opt.get('fix') or '', 'retest': opt.get('retest') or '',
                                           # retro tidy-20261124-03: a 7-round loop showed no cause per round
                                           'failed': '; '.join(f"{k['id']}: {k['result']}" for k in ran if str(k['result']).upper().startswith('FAIL'))}]})
        else:
            if verb == 'add':   # a shared task: one wave agent never rewrites another's title or ids
                old_of = lambda k, i: next((x for x in c.get(k) or [] if isinstance(x, dict) and str(x.get('id')) == str(i)), None)
                dup = [f'{k} {e.get("id")}' for k in ('cases', 'checks', 'qualities', 'unchanged') for e in new.get(k) or [] if isinstance(e, dict)
                       and (o := old_of(k, e.get('id'))) and any(o.get(f) != v for f, v in e.items() if f != 'by')]
                if dup and '--replace' not in rest:   # retro: an existing id was overwritten silently
                    raise SystemExit(f'cases add: {", ".join(dup)} exist(s) with other values: a new id for a new case, or --replace to change it. Nothing was written.')
                own_spec(c, new, '--replace' in rest)
            c = merge_spec(c, new)
        gaps = cases_gaps(c)
        if not gaps and verb in ('add', 'result'):   # the qa.matrix gap now, not first at finish (4 late refusals, retro 2026-11-22)
            mgap = next((g for g in case_gaps(render_cases(c, 'ai', tid)) if g.startswith('UI cases miss qa.matrix')), '')
        x['cases'] = c
    task_index(tid, change)
    print(f'cases {tid}: {verb} ok' + (f' (render refuses until fixed: {"; ".join(gaps)})' if gaps else ''))
    if mgap:
        print(f'WARN cases {tid}: {mgap} (the spec\'s "matrix" field renders that line); doc and finish refuse until then', file=sys.stderr)
    if verb == 'add' and (sg := spec_trace_gaps(tid)):
        print(f'WARN cases {tid}: spec S-id(s) {", ".join(sg)} have no check or case citing them ("spec"); finish refuses until then', file=sys.stderr)
    return 0


def fmt_line(f, s):
    """A title / subject format ({type} {scope} {change} {task} {tag} {code} {repo}): empty () and a dangling ' -' dropped."""
    vals = {'tag': TAG, **{k: str(v) for k, v in s.items() if v and not isinstance(v, (list, dict))}}
    keep = []   # a filled placeholder -> a sentinel while the empty ones' () and ' -' are dropped
    out = re.sub(r'\{(\w+)\}', lambda m: (keep.append(vals[m.group(1)]) or f'\x00{len(keep) - 1}\x00') if vals.get(m.group(1)) else '', f)
    out = re.sub(r'\s{2,}', ' ', re.sub(r'\s+-\s*(?=\(|$)', ' ', re.sub(r'\s*\(\s*\)', '', out))).strip()
    return re.sub(r'\x00(\d+)\x00', lambda m: keep[int(m.group(1))], out)


_NAMING = []
KEY_RX = r'([A-Z]{2,6}-[A-Z]{2,6}-\d{2,})(?:\.\d+)?(?=\s|$)'


def naming():
    """kitbag_naming.py (a kitbag plugin, with kitbag's names): make / clean / naming_cfg; None without the plugin (naming off)."""
    p = os.path.join(KIT_DIR, 'skills', 'bossy', 'kitbag_naming.py')
    if not _NAMING and not os.path.isfile(p):
        return None
    if not _NAMING:
        import kitbag
        sp = importlib.util.spec_from_file_location('kitbag_naming', p)
        m = importlib.util.module_from_spec(sp)
        m.__dict__.update({n: v for n, v in vars(kitbag).items() if not n.startswith('__')})
        sp.loader.exec_module(m)
        _NAMING.append(m)
    return _NAMING[0]


_KEYS = {}
naming_on = lambda: bool((n := naming()) and n.naming_cfg()['areas'])


def task_key(tid):
    """A task's kit key (naming on): its spec's, else its tracker name's prefix; '' when none or naming is off."""
    if not tid or not naming_on():
        return ''
    if tid not in _KEYS:
        _KEYS[f'name:{tid}'] = nm = str(task(tid).get('name') or '')
        _KEYS[tid] = ((state_read(task_file(tid)) or {}).get('spec') or {}).get('key') or ((m := re.match(KEY_RX, nm)) and m[1]) or ''
    return _KEYS[tid]


def render_title(s):
    """MR / PR title: a keyed task (naming): `<type>(<scope>): <change> [<KEY>]` (kitbag.py naming make mr) unless mrTitleFormat
    names {key}; else kit.local.json mrTitleFormat (templates.md kind mr-title)."""
    k = str(s.get('key') or '') or task_key(s.get('task'))
    fmt = CFG.get('mrTitleFormat') or ''
    if k and '{key}' not in fmt:
        return naming().make('mr', {'type': s.get('type'), 'scope': s.get('scope'), 'summary': s.get('change') or s.get('summary'), 'key': k})
    return fmt_line(fmt or '{type}({scope}): {change} ({task})', {**s, 'key': k})


def render_commit(s):
    """Commit message: commitFormat subject, a bullet per change, trailers (e.g. Co-Authored-By) after a blank line."""
    body = [f'- {c["text"]}' + (f' (`{c["technical"]}`)' if c.get('technical') else '') for c in s.get('changes') or [] if c.get('text')]
    body += [f'- Spec: {", ".join(map(str, _as_list(s["specIds"])))}'] if _as_list(s.get('specIds')) else []   # the S-ids this commit builds
    k = str(s.get('key') or '') or task_key(s.get('task'))   # naming: the MR title's form, <type>(<scope>): <change> [<KEY>]
    subj = naming().make('mr', {**s, 'summary': s.get('change'), 'key': k}) if k and not CFG.get('commitFormat') else fmt_line(CFG.get('commitFormat') or '{type}({scope}): {change}', {**s, 'key': k})
    return '\n'.join([subj] +([''] + body if body else []) + ([''] + list(s['trailers']) if s.get('trailers') else [])) + '\n'


def render_mr_body(s):
    """templates.md "MR spec" from an MR spec; the Local env row from the loop checkpoint when the spec has none."""
    t = s.get('task') or ''
    url = s.get('taskUrl') or (t and ((_tracker('url', t) or '').strip().splitlines() or [''])[-1])
    ev = '' if s.get('localEnv') or not t else local_pass(t)[1]
    loop = s.get('localEnv') or (f'{s.get("env") or "local"}: {ev}' if ev else 'none')
    checks = s.get('checksRun') or []
    rows = [['Checks', ' · '.join(f'{c["name"]} {"✅" if str(c.get("result", "")).upper() in ("PASS", "OK", "0", "") else "❌ " + str(c["result"])}' for c in checks) or 'none'],
            ['Local env', loop], ['Not run', s.get('notRun') or 'nothing'], ['UI', s.get('ui') or 'not a UI change'],
            ['Pure logic', s.get('pureLogic') or 'none'], ['Regression', s.get('regression') or 'not a fix']]
    risks = [f'- {r["text"]}' for r in s.get('risks') or [] if r.get('text')] + [f'- **Behaviour limits:** {s.get("limits") or "none"}', f'- **Needs after deploy:** {s.get("afterDeploy") or "none"}']
    sib = s.get('siblings') or []
    return '\n\n'.join(['## Summary', (f'[{t}]({url}) — ' if t and url else f'{t} — ' if t else '') + str(s.get('summary') or s.get('change') or ''),
                        '## Changes', '\n'.join(f'- {c["text"]}' + (f' · **Technical:** `{c["technical"]}`' if c.get('technical') else '') for c in s.get('changes') or []) or 'n/a — the spec lists no change',
                        '## How tested', _table(['Check', 'Result'], rows), '## Risks', '\n'.join(risks), '## Links',
                        (f'- **Sibling {mr_word()}s:** {", ".join(link_refs(x) for x in sib)} (merge order: producers first)' if sib else f'- **Sibling {mr_word()}s:** none')
                        + (f' · **Spec S-ids:** {", ".join(map(str, _as_list(s["specIds"])))}' + (f' (v{v})' if (v := spec_rec(t).get('version')) else '')   # one bullet: Links cap
                           if _as_list(s.get('specIds')) else '')]) + '\n'



_MR_URLS = {}


def mr_link(ref):
    """repo!iid -> [repo!iid](full MR URL) via the git-host adapter's mr.url (owner: comments and MR bodies link full URLs,
    never a bare ref); no URL (unknown repo, no host): the ref as is. lib.ps1 Format-KitMrLink, the same."""
    r = _norm_ref(ref)
    if not r:
        return str(ref)
    if not _MR_URLS.get(r):   # a failed lookup is not cached
        host = host_kind(GITLAB_HOST)
        try:
            out = _host('mr.url', type=host, repo=_ref_path(host, r[0]), n=r[1]) if host else ''
        except (Exception, SystemExit) as e:   # a host error never fails the render: the ref stays
            print(f'[render] {ref}: no MR URL ({str(e)[:120]})', file=sys.stderr)
            out = ''
        u = (str(out.get('raw') or '') if isinstance(out, dict) else str(out or '')).strip().splitlines()
        _MR_URLS[r] = u[-1].strip() if u and re.match(r'^https?://[^/\s]+/\S+$', u[-1].strip()) else ''
    return f'[{ref}]({_MR_URLS[r]})' if _MR_URLS[r] else str(ref)


def link_refs(text):
    """Every bare MR ref (repo!iid) in a rendered text -> its full-URL link; refs inside a link or a `code span` stay."""
    rx = r'(?<![\[\w/.!-])([\w.-]+(?:/[\w.-]+)*!\d+)(?![\w\]])'
    return ''.join(p if p.startswith('`') else re.sub(rx, lambda m: mr_link(m.group(1)), p) for p in re.split(r'(`[^`]*`)', str(text or '')))


def render_solution(s):
    """templates.md "Comment spec" comment-solution: MRs (merge state) from the task's tracking, the local proof from the loop checkpoint."""
    t = s.get('task') or ''
    tr = ((read_tracking().get('tasks') or {}).get(t[len(TAG):] if TAG and t.startswith(TAG) else t) or {}) if t else {}
    mrs = [link_refs(m) for m in s.get('mrs') or [f'{m} ({"MERGED" if tr.get("allMergedAt") else "OPEN"})' for m in tr.get('mrs') or []]]
    proof = s.get('localProof') or (t and local_pass(t)[1]) or 'none'
    return comment_template('comment-solution', '**Solution:** {solution}\n**MRs:** {mrs} · **Local proof:** {localProof}\n**After deploy:** {afterDeploy} · **Deferred:** {deferred}\n',
                            {**s, 'solution': s.get('solution', ''), 'mrs': ' · '.join(mrs) or 'none', 'localProof': proof,
                             'afterDeploy': s.get('afterDeploy') or 'nothing', 'deferred': s.get('deferred') or 'none'})


def render_status(s):
    """comment-status: `<status> — <why> · <link>`."""
    return comment_template('comment-status', '{status} — {why}{linkPart}\n', {**s, 'why': link_refs(s.get('why')), 'linkPart': f' · {link_refs(s["link"])}' if s.get('link') else ''})


def comment_template(kind, default, vals):
    """tracker.commentTemplates.<kind> (else default) with each {field} filled from vals ('' when absent)."""
    tpl = str(((CFG.get('tracker') or {}).get('commentTemplates') or {}).get(kind) or default)
    return re.sub(r'\{(\w+)\}', lambda m: '' if vals.get(m.group(1)) is None else str(vals[m.group(1)]), tpl)


SPEC_NEEDS = {'mr-body': ('type', 'change', 'summary'), 'mr-title': ('type', 'change'), 'commit': ('type', 'change'),
              'comment-solution': ('solution',), 'comment-status': ('status', 'why'), 'final-report': ('role',), 'retro': ('date',),
              'wave-brief': ('name', 'agents', 'mandate')}


def spec_gaps(s, kind):
    """What a spec lacks for its kind (SPEC_NEEDS) + change entries without text; a bare string item becomes {"text": it}."""
    for k in ('changes', 'risks'):   # retro: render commit crashed 2x on 'str' object has no attribute 'get'
        if isinstance(s.get(k), (str, list)):
            s[k] = [{'text': c} if isinstance(c, str) else c for c in ([s[k]] if isinstance(s[k], str) else s[k])]
    return [k for k in SPEC_NEEDS.get(kind, ()) if not s.get(k)] + [f'{k}[{i}].text' for k in ('changes', 'risks') for i, c in enumerate(s.get(k) or [])
                                                                   if not isinstance(c, dict) or k == 'changes' and not c.get('text')]


# templates.md "Final reports": each role's JSON keys in reading order (others: the generic shape)
REPORT_KEYS = {'devy': ('mrs', 'localTest', 'doc', 'done', 'deferred', 'needsDecision', 'seed', 'hooks', 'disputes'),
               'revy': ('findings',), 'checky': ('summary', 'report', 'rule', 'results'),
               'kitty': ('branch', 'commits', 'fixed', 'proposed', 'ask', 'report', 'next'), '*': ('result', 'links', 'next')}


def render_report(s):
    """A crew member's final report (role JSON) as one line per key: lists joined with ' · ', objects as 'key value' pairs."""
    val = lambda v: ' · '.join(val(x) for x in v) if isinstance(v, list) else ' '.join(f'{k} {val(x)}' for k, x in v.items() if x not in (None, '', [])) \
        if isinstance(v, dict) else str(v)
    keys = REPORT_KEYS.get(s.get('role'), REPORT_KEYS['*'])
    keys = list(keys) + [k for k in s if k not in keys and k not in ('role', 'agent')]   # never drop a key: listed ones first
    return '\n'.join([f'**{s.get("role", "agent")}** {s.get("agent", "")}'.rstrip()] + [f'**{k}:** {val(s[k])}' for k in keys if s.get(k) not in (None, '', [], {})]) + '\n'


def render_retro(s):
    """The /tidy retro report (kit-report) from the judge's lists: Changed, Awaiting approval, Rejected tables."""
    a, p, r = s.get('applied') or [], s.get('proposed') or [], s.get('rejected') or []
    sec = lambda h, cols, keys, rows: [f'## {h}', _table(cols, [[x.get(k, '') for k in keys] for x in rows]) if rows else f'n/a — nothing {h.lower()}']
    return '\n\n'.join([f'# Retro {s.get("date", "")}', f'**Result:** {len(a)} applied · {len(p)} awaiting approval · {len(r)} rejected']
                         + sec('Changed', ['Change', 'File', 'Digest count'], ('change', 'file', 'count'), a)
                         + sec('Awaiting approval', ['Proposal', 'Exact edit'], ('proposal', 'edit'), p)
                         + sec('Rejected', ['Signal', 'Why'], ('signal', 'why'), r) + ([f'**Lint:** {s["lint"]}'] if s.get('lint') else [])) + '\n'


def _oq(q):
    """An openQuestions entry: {question, blocks, answers}; a plain string is a question the Spike phase (rechy) answers."""
    return {'question': q, 'answers': 'rechy'} if isinstance(q, str) else dict(q or {})


def wave_ids(s):
    """N3 (naming on): agent ids -> area-<AREA> (its task key's AREA; -2, -3 for a second one), dependsOn and contract producers /
    consumers with them; never typed by briefy. A legacy id without a keyed task stays."""
    if not naming_on():
        return s
    rx, used, new = naming().patterns(naming().naming_cfg())['area'], {a['id'] for a in s['agents']}, {}
    for a in s['agents']:
        key = '' if re.match(rx, a['id']) else task_key(a.get('task') or s.get('task') or '')
        if key:
            base, i = f'area-{key.split("-")[1]}', 1
            while (cand := base if i == 1 else f'{base}-{i}') in used:
                i += 1
            used.add(cand)
            new[a['id']] = cand
    sub = lambda v: [sub(x) for x in v] if isinstance(v, list) else re.sub(r'[^,;\s]+', lambda m: new.get(m[0], m[0]), str(v)) if v else v
    return {**s, 'contracts': [{**c, 'producer': sub(c.get('producer')), 'consumers': sub(c.get('consumers'))} for c in s.get('contracts') or []], 'agents': [{**a, 'id': new.get(a['id'], a['id']), **({'dependsOn': [new.get(p, p) for p in a['dependsOn']]} if a.get('dependsOn') else {})}
                            for a in s['agents']]}


def run_label(s):
    """'<KEY> <short title>' of a wave's task (naming on; '' without a key): the title without key, [Type] and 'Area:'."""
    tid = s.get('task') or next((a['task'] for a in s['agents'] if a.get('task')), '')
    if not (key := task_key(tid)):
        return ''
    rest = re.sub(rf'^(?:{re.escape(key)}\S*\s+)?(?:\[[^\]]+\]\s*)?(?:[^:]{{1,30}}:\s*)?', '', _KEYS.get(f'name:{tid}', ''))
    return f'{key} {" ".join(rest.split()[:7])}'.strip()


def wave_order(s):
    """Areas in waves (owner 2026-11-23): an area waits on its dependsOn and the producers of contracts it consumes; wave n = the
    areas whose waits all sit in earlier waves (one wave = parallel); a cycle is the last row. -> [(wave, [ids])], {id: [waits]}."""
    ids, ws = [a['id'] for a in s['agents']], lambda v: re.findall(r'[^,;\s]+', ' '.join(v) if isinstance(v, list) else str(v or ''))
    waits = {a['id']: set(a.get('dependsOn') or []) for a in s['agents']}
    for c in s.get('contracts') or []:
        for con in ws(c.get('consumers')):
            if con in waits:
                waits[con] |= set(ws(c.get('producer'))) - {con}
    waits, left, waves = {k: sorted(v & set(ids)) for k, v in waits.items()}, list(ids), []
    for _ in range(len(ids)):   # each round places one area at least, or ends on a cycle
        if not left:
            break
        ready = [a for a in left if not set(waits[a]) & set(left)]
        waves.append((len(waves) + 1, ready) if ready else ('cycle', left))
        left = [a for a in left if a not in ready] if ready else []
    return waves, waits


def order_tasks(s):
    """<brief>.order.json for `crafty.ps1 tracker order <parent> -Apply`: per area task its wave label (naming on: tag wave-<n>) and the tasks it waits on
    (an area sharing its task with another: skipped, its subtask gets links once made)."""
    waves, waits = wave_order(s)
    tk = {a['id']: a.get('task') or s.get('task') or '' for a in s['agents']}
    shared = {t for t in tk.values() if t and list(tk.values()).count(t) > 1}
    return {'parent': s.get('task') or '', 'tasks': [{'task': tk[a], 'area': a, 'wave': s.get('wave') or (f'{s["name"]} wave {w}' if w != 'cycle' else ''),
             'waitsOn': sorted({tk[d] for d in waits[a] if tk[d] and tk[d] != tk[a]})} for w, grp in waves for a in grp if tk[a] and tk[a] not in shared]}


def render_wave_brief(s):
    """templates.md "Wave brief" from briefy's spec; the contracts file and the /buildy args come from the same spec (wave_files)."""
    s = wave_ids(s)
    yn = lambda v: f'yes: {v}' if isinstance(v, str) and v else ('yes' if v else 'no')
    rows = lambda keys, xs: [[str(x.get(k) or '') for k in keys] for x in xs]
    qs = [f'{q.get("question", "")} · blocks {q.get("blocks") or "—"} · answers: {q.get("answers") or "owner"}' for q in map(_oq, s.get('openQuestions') or [])]
    return '\n'.join([
        f'# Wave brief: {s["name"]}, {s.get("date") or time.strftime("%Y-%m-%d")}',
        f'**Read first:** `{s.get("kitDir") or "<kit>"}/skills/crafty/SKILL.md`; this brief wins where they differ.',
        f'**Items:** {s.get("items") or "—"} · **Decisions:** {s.get("decisions") or "none"}; final, don\'t re-ask (a NEW choice -> crafty D1).',
        f'**Local env:** {s.get("localEnv") or "none"} · **Test env after deploy:** {s.get("testEnv") or "—"} (never production).',
        '## Repos', _table(['Repo', 'Main checkout', 'Target', 'Link deps from', 'Migrations'], rows(('repo', 'checkout', 'target', 'linkFrom', 'migrations'), s.get('repos') or [])),
        '## Agents', _table(['Agent', 'Items', 'Area (screens / packages / files)', 'Paths (enforced)', 'Repos', 'Migration range', 'Services (leased, nothing else)', 'Complex?'],
                            [r[:3] + [', '.join(f'`{g}`' for g in a.get('paths') or []) or 'any'] + r[3:] + [yn(a.get('complex'))]
                             for r, a in zip(rows(('id', 'items', 'area', 'repos', 'migrationRange', 'services'), s['agents']), s['agents'])]), '',
        f'**Overlaps:** {s.get("overlaps") or "none"} · **Contracts:** `{s.get("contractsFile") or s["name"] + ".contracts.md"}` ({len(s.get("contracts") or [])} crossing)',
        *([f'**Specs** (build against their S-ids; `devtools.py spec show <task>`): ' + ' · '.join(
            f'{t} v{r.get("version")} {r.get("url")}' for t in s['specs'] if (r := spec_rec(t)).get('url') and not r.get('retired'))] if s.get('specs') else []),
        f'**Branch:** `{s.get("branch") or "f/<tag><task>-<slug>"}`, pool slots leased as the agent id · **Tracker:** {s.get("tracker") or "—"}.',
        # the limits where devy reads first (retro 2026-11-22: 13 mr prose refusals)
        # wrapped: one 340-char line failed the brief's own 130ch prose check (briefys 2026-11-23)
        *__import__('textwrap').wrap(f'**MR limits** (`devtools.py mr` refuses over them; `devtools.py mr <worktree> --spec <mr.json> --check` first: the same gates, nothing opened): {prose_limits("mr-title") or "mr-title"}; '
                                     f'{prose_limits("mr-body") or "mr-body"}', 128, break_long_words=False, break_on_hyphens=False),
        'Rule changes during the wave are appended below and to the contracts file: re-read both before every push.', '',
        '## Order (waves: a row runs in parallel; `crafty.ps1 tracker order <parent> -Apply <brief>.order.json` links the tasks)', _table(['Wave', 'Areas (parallel)', 'Tasks', 'Waits on'], [[str(w), ', '.join(g), ', '.join(sorted({a.get('task') or s.get('task') or '—' for a in s['agents'] if a['id'] in g})), ', '.join(sorted({d for x in g for d in wo[x]})) or '—'] for wv in [wave_order(s)] for wo in [wv[1]] for w, g in wv[0]]),
        '## openQuestions', *(qs or ['n/a — no open question']), '## Findings (rechy)', 'n/a — no spike yet (the Spike phase appends here)',
        '## Rule changes during the wave (newest last)', 'n/a — none yet (appended during the wave)']) + '\n'


def wave_files(s, brief_path):
    """{path: text} beside the brief: <name>.contracts.md and <name>.args.json (/buildy launch args); same spec, no retyping."""
    stem, s = os.path.splitext(brief_path)[0], wave_ids(s)
    con = '\n'.join([f'# Contracts: {s["name"]}', _table(['Field / endpoint', 'Type', 'Producer', 'Consumers', 'Merge / deploy order', 'Backward-compatible'],
                     [[str(c.get(k) or '') for k in ('name', 'type', 'producer', 'consumers', 'order')] + ['yes' if c.get('compatible') else 'no'] for c in s.get('contracts') or []])
                     if s.get('contracts') else 'n/a — nothing crosses areas', '## Rule changes during the wave (newest last)', 'n/a — none yet (appended during the wave)']) + '\n'
    keep = ('id', 'items', 'area', 'paths', 'note', 'kind', 'complex', 'model', 'effort', 'dependsOn', 'migrations', 'branch', 'branches', 'debate', 'task')   # buildy's agent keys
    if not s.get('run') and naming_on() and (n := naming()):   # naming: buildy-<YYYYMMDD>-<nn>, once per brief (a re-render keeps its args' run)
        old = ''
        with contextlib.suppress(OSError, ValueError, AttributeError), open(f'{stem}.args.json', encoding='utf-8') as fh:
            old = json.load(fh).get('run') or ''
        s = {**s, 'run': old or n.next_id('buildy')}
    args = {'brief': brief_path.replace('\\', '/'), 'agents': [{k: a[k] for k in keep if a.get(k) not in (None, '', [], False)} for a in s['agents']],
            'mode': s.get('mode') or 'feature', 'mandate': s['mandate'], **({'task': s['task']} if s.get('task') else {}),
            **({'run': s['run']} if s.get('run') else {}),   # buildy reads `run`, never `name` (its args check refuses unknown keys)
            **({'label': lb} if (lb := s.get('label') or run_label(s)) else {}),   # N3 '<KEY> <short title>': board show, dashboard
            'openQuestions': [q['question'] for q in map(_oq, s.get('openQuestions') or []) if q['question'] and (q.get('answers') or '') == 'rechy'],
            **({'holdMerge': s['holdMerge']} if s.get('holdMerge') else {}), **({'kitDir': s['kitDir']} if s.get('kitDir') else {})}
    return {f'{stem}.contracts.md': con, f'{stem}.args.json': json.dumps(args, ensure_ascii=False, indent=1) + '\n',
            f'{stem}.order.json': json.dumps(order_tasks(s), ensure_ascii=False, indent=1) + '\n'}


# ---- spec: one versioned spec doc per task or standing subject; its S-ids are cited by cases, commits, MRs and QA results
SPEC_KINDS, SPEC_LISTS = ('feature', 'bug', 'subject'), {'rules': 'id', 'decisions': 'id', 'users': 'who', 'metrics': 'metric', 'glossary': 'term'}
# per kind (f / b / s), every section always rendered (owner dec-0001): (field, kinds, heading, purpose, the plain-words questions briefy asks);
# {"na": "<why>"} = does not apply; a '#' heading nests under the one before
SPEC_SECTIONS = (
    ('summary', 'fbs', 'Summary', 'one line: what changes, for whom (bug: ~10 words)', 'In one sentence, what will be different for users?'),
    ('impact', 'b', 'Impact', 'who is hit, how many, since when, severity, workaround', 'Who is hit and how badly? Since when? Is there a workaround?'),
    ('problem', 'f', 'Problem and evidence', 'the pain, who feels it, the proof, the cost of doing nothing', 'What hurts today and for whom? What shows it (tickets, numbers, quotes)? What if we do nothing?'),
    ('metrics', 'f', 'Success metrics', 'number, target, by when', 'How will you know it worked? Which number moves, by how much, by when?'),
    ('scope', 'f', 'Scope, no-gos and appetite', 'in, out, the time budget', 'What must be in the first version? What are we not doing? How much time is it worth?'),
    ('purpose', 's', 'Purpose and boundary', 'what the subject covers, where it stops', 'What is this part of the product for? Where does it stop?'),
    ('glossary', 's', 'Glossary', 'domain terms, one line each', 'Which words do your users use that we must use the same way?'),
    ('users', 'f', 'Users and flows', 'who, step by step', 'Who uses it? Walk me through what they do, start to finish.'),
    ('users', 's', 'Actors and flows', 'roles and their main flows', 'Who touches it, and what does each one do?'),
    ('repro', 'b', 'Reproduce', 'steps, env / build, frequency, expected, actual, evidence', 'What did you do, what did you expect, what happened? Every time?'),
    ('regression', 'b', 'Regression range', 'last good version or date, first bad', 'Did it ever work? When did it stop?'),
    ('rootCause', 'b', 'Root cause', 'trigger vs root cause, the 5-whys chain', 'What set it off, and why could that happen at all?'),
    ('fix', 'b', 'Fix and rules', 'how it is fixed; the S-ids it must hold below', 'What is the right behaviour, exactly?'),
    ('rules', 'fs', 'Behaviour rules', 'S1..Sn, one testable rule each with Given / When / Then; edge cases under their rule', 'What must always happen? What when it is empty, too big, not allowed or done twice?'),
    ('rules', 'b', '### Rules', 'the S-ids the fix holds (new or existing)', 'Which rule did it break, and which new rule keeps it fixed?'),
    ('algorithm', 'fs', 'Algorithm', 'the core logic in plain steps: inputs, steps and branches, outputs, limits, failures; enough to build it without the code (n/a only for a pure UI or text change)',
     'What goes in and what comes out? What are the steps, and where does it branch? What are the limits, and what happens when a step fails?'),
    ('algorithm', 'b', '### Fix algorithm', 'the corrected logic in plain steps: inputs, steps and branches, outputs, limits, failures', 'Step by step, what must the code now do?'),
    ('design', 'f', 'Design', 'approach, impacted modules, contracts, at least one diagram chosen by need: C4 context / container (structure), sequence (interactions), '
     'state (lifecycles), flowchart (the algorithm), ER (data)', 'Does this picture match how you see it working?'),
    ('ui', 'f', 'UI screens and states', 'screens; empty / loading / error / success; the theme rule', 'Which screens change? What does the user see when nothing is there, while it loads, or when it fails?'),
    ('crossCutting', 'f', 'Cross-cutting', 'one line each or "none": security and privacy, permissions, performance budget, observability, accessibility, i18n, cost, backward compatibility',
     'Who must not see this? How fast must it feel? Any language or accessibility need?'),
    ('dataModel', 's', 'Data model and states', 'entities, a state-machine diagram, invariants', 'What states can it be in? What must never happen?'),
    ('interfaces', 's', 'Interfaces', 'APIs, jobs, integrations (contracts file rows)', 'Which screens, systems or jobs talk to it?'),
    ('quality', 's', 'Quality scenarios', 'performance, security, availability as concrete scenarios', 'How many, how fast, who may see what?'),
    ('detection', 'b', 'Detection gap', 'why tests or monitoring missed it, the regression test added', 'Why did no test or alert catch it?'),
    ('dataRepair', 'b', 'Data repair', 'rows to fix, backfill, customers to tell', 'Was any data saved wrong that we must fix?'),
    ('risks', 'f', 'Risks and rabbit holes', 'risk -> mitigation; what could make it take much longer', 'What worries you? What could make this take much longer?'),
    ('risks', 's', 'Risks and tech debt', 'known weak spots', 'Which parts break often or are hard to change?'),
    ('rollout', 'fb', 'Rollout', 'flag, migration / backfill, rollback, who is told (bug: the hotfix path)', 'Everyone at once or a few customers first? If it goes wrong, what do we switch back?'),
    ('tests', 'f', 'Acceptance and test strategy', 'each S-id -> test layer and env', 'Which test, on which env, proves each rule?'),
    ('dependencies', 'f', 'Dependencies', 'other teams, vendors, tasks', 'Do we wait on anyone else?'),
    ('decisions', 'fbs', 'Decisions', 'one row per choice (MADR): drivers, options, chosen, why, confirm-by', 'Which ways could we do this? What matters most when choosing? How will we know the choice held?'),
    ('questions', 'fbs', 'Open questions', 'the spec stays draft while any remain', ''),
)
# the parts of an object-valued section: each is answered, 'n/a' or asked
SPEC_PARTS = {'impact': ('who', 'howMany', 'since', 'severity', 'workaround'), 'problem': ('pain', 'evidence', 'costOfNothing'), 'scope': ('in', 'out', 'appetite'),
              'purpose': ('covers', 'boundary'), 'repro': ('steps', 'env', 'frequency', 'expected', 'actual', 'evidence'), 'regression': ('lastGood', 'firstBad'),
              'rootCause': ('trigger', 'cause', 'whys'), 'fix': ('approach',), 'algorithm': ('inputs', 'steps', 'outputs', 'limits', 'failures'),
              'design': ('approach', 'modules', 'contracts', 'diagrams'), 'ui': ('screens', 'states', 'theme'),
              'crossCutting': ('security', 'permissions', 'performance', 'observability', 'accessibility', 'i18n', 'cost', 'compatibility'),
              'dataModel': ('entities', 'diagrams', 'invariants'), 'detection': ('why', 'test'), 'rollout': ('flag', 'migration', 'rollback', 'tell')}
SPEC_LABELS = {'howMany': 'How many', 'costOfNothing': 'Cost of doing nothing', 'in': 'In', 'out': 'Out (no-gos)', 'lastGood': 'Last good', 'firstBad': 'First bad',
               'cause': 'Root cause', 'whys': '5 whys', 'i18n': 'i18n', 'compatibility': 'Backward compatibility', 'tell': 'Who is told', 'enable': 'How to enable',
               'theme': 'Theme rule', 'env': 'Env / build', 'security': 'Security and privacy', 'performance': 'Performance budget', 'test': 'Regression test added'}
SPEC_DIAGRAMS = ('design', 'dataModel')   # feature / subject: at least one diagram here unless n/a with a reason
MMDC_PIN = '12.2.0'   # @mermaid-js/mermaid-cli, installed by spec setup into <runtime>/tools/mmdc (reversy-style pin)
SPEC_FIELDS = """spec JSON (devtools.py spec write; merged into the stored spec: lists by key, objects by part, a list part whole): kind feature|bug|subject · title
 · change (what changed and why: every version after v1) · the kind's sections (spec template <kind> prints them with purpose and
 questions): a value, an object of its parts, or {"na": "<why>"}; a missing one is open (rendered as its question; the spec stays draft).
 Shapes: rules [{id: S1, text, acceptance (Given / When / Then), status: removed}] (an id is never reused) · edges [{text, rule: S1}]
 (rendered under its rule) · decisions [{id, question, drivers, options: [{id: A, text, pros, cons}], chosen, why, confirm, by}] ·
 users [{who, flow}] · metrics [{metric, target, by}] · glossary [{term, meaning}] · risks [{text, mitigation}] · tests [{rule, layer,
 env}] · algorithm {inputs, steps [..], outputs, limits, failures} (or pseudocode) · design {approach, modules [..], contracts [{name,
 ref}], diagrams [{title, type: c4|sequence|state|flowchart|er, mermaid}]} (feature: at least one diagram; dataModel the same for a
 subject) · crossCutting {security, permissions, performance, observability, accessibility, i18n, cost, compatibility} · other
 objects: the parts spec template names. Old fields (goal, nonGoals, options, approach, impact, contracts, diagrams, edges,
 repro.rootCause) map onto these on read.
Interview (briefy, the architect; people are the business owners): spec questions <key> prints every open section and part as one
 question; batch them to the owner (bossy.ps1 decide ask, via the coordinator), never guess; write each answer back (or n/a + why).
Diagram images: spec setup (once per machine: mmdc pinned into <runtime>/tools); without it the Mermaid source block stays."""


def spec_rec(key):
    """The published spec record of a task or subject (<key>:spec), else the one the task links (task index specKey)."""
    r = _pub_read(f'{key}:spec') if key else {}
    if not r.get('data') and key and (sk := (state_read(task_file(key)) or {}).get('specKey')) and sk != key:
        r = _pub_read(f'{sk}:spec')
    return r


def spec_shape(s):
    """Shape errors that refuse a write (kind, S-id form, an id twice)."""
    ids = [str(r.get('id')) for r in s.get('rules') or [] if isinstance(r, dict)]
    return ([] if s.get('kind') in SPEC_KINDS else [f'kind ({"/".join(SPEC_KINDS)})']) + ([] if s.get('title') else ['title']) \
        + [f'rule id {i!r}: S<n>' for i in ids if not re.match(r'^S\d+$', i)] + [f'rule {i}: twice' for i in sorted({i for i in ids if ids.count(i) > 1})]


def spec_sections(kind):
    """The kind's sections in doc order (an unknown kind: feature)."""
    k = (kind if kind in SPEC_KINDS else 'feature')[0]
    return [x for x in SPEC_SECTIONS if k in x[1]]


def spec_migrate(s):
    """A spec in the v1 shape (18 sections) -> the per-kind v2 shape; v2 input is returned as is (no rule changes)."""
    s, live = dict(s or {}), lambda v: v not in (None, '', [], {})
    if 'goal' in s:
        g = s.pop('goal')
        s.setdefault('summary', g)
    if isinstance(s.get('scope'), (list, str)) or 'nonGoals' in s:
        sc, ng = s.pop('scope', None), s.pop('nonGoals', None)
        s['scope'] = {**({'in': sc} if live(sc) else {}), **({'out': ng} if live(ng) else {})} if not _na(sc) else sc
    keep = lambda **kv: {k: v for k, v in kv.items() if v}   # only given parts: a partial write never blanks a stored one
    dec = [] if _na(s.get('decisions')) else [{**{k: x for k, x in d.items() if k != 'answer'}, **keep(chosen=d.get('chosen') or d.get('answer'))}
                                              for d in s.get('decisions') or [] if isinstance(d, dict)]
    if 'options' in s:
        o = s.pop('options')
        dec = [{'id': x.get('choice'), 'question': x.get('choice'), **keep(options=x.get('options'), chosen=x.get('chosen'), confirm=x.get('revisit'),
                why='; '.join(y for y in (x.get('why'), x.get('rejected') and f'rejected: {x["rejected"]}') if y))}
               for x in (o if isinstance(o, list) else []) if isinstance(x, dict)] + dec
        s['decisions'] = dec or (s.get('decisions') if _na(s.get('decisions')) else o)
    elif dec:
        s['decisions'] = dec
    old = {k: s.pop(k) for k in ('approach', 'impact', 'contracts', 'diagrams') if k in s and (k != 'impact' or s.get('kind') != 'bug')}   # bug: Impact is its own section
    if old:   # bug -> Fix; subject -> Data model (diagrams) + Interfaces (contracts), the rest carried; feature -> Design
        part = {'approach': old.get('approach'), 'modules': old.get('impact'), 'contracts': old.get('contracts'), 'diagrams': old.get('diagrams')}
        part = {k: v for k, v in part.items() if v is not None}
        tgt = {'bug': 'fix', 'subject': 'dataModel'}.get(s.get('kind'), 'design')
        if tgt == 'dataModel':
            if 'contracts' in part:
                s.setdefault('interfaces', part.pop('contracts'))
            s.update({f'earlier {k}': part.pop(k) for k in ('approach', 'modules') if k in part})
        if part:
            s[tgt] = {**(s.get(tgt) if isinstance(s.get(tgt), dict) and not _na(s.get(tgt)) else {}), **part}
    if isinstance(s.get('repro'), dict) and 'rootCause' in s['repro']:
        s['repro'] = dict(s['repro'])
        rc = s['repro'].pop('rootCause')
        if live(rc):
            s.setdefault('rootCause', {'cause': rc})
    return s


def _na(v):
    return isinstance(v, dict) and set(v) == {'na'}


def _open(v):
    return v in (None, '', [], {}) or _na(v) and not str(v['na']).strip()


def _label(k):
    return SPEC_LABELS.get(k) or re.sub(r'(?<=[a-z])([A-Z])', r' \1', k).capitalize()


def spec_diagram_gap(s):
    """'' or the section of a feature / subject spec that needs a diagram (Design / Data model): finish and the interview refuse it."""
    s = spec_migrate(s)
    for f, kinds, head, _, _ in spec_sections(s.get('kind')):
        v = s.get(f)
        dg = v.get('diagrams') if isinstance(v, dict) else None
        if f in SPEC_DIAGRAMS and not _na(v) and not (_na(dg) and str(dg['na']).strip()) \
                and not any(isinstance(x, dict) and str(x.get('mermaid') or '').strip() for x in (dg if isinstance(dg, list) else [dg])):
            return head
    return ''


def spec_questions(s):
    """The interview: one question per open section, part or rule gap (a draft spec is not ready while any is left)."""
    s, out = spec_migrate(s), []
    for f, kinds, head, purpose, q in spec_sections(s.get('kind')):
        v, h = s.get(f), head.lstrip('# ')
        if f == 'questions' or _na(v) and str(v['na']).strip():
            continue
        if _open(v):
            out.append(f'{h} ({purpose}): {q}' + (' (n/a needs its reason)' if _na(v) else ''))
            continue
        if isinstance(v, dict):
            out += [f'{h}: {_label(k)}?' for k in SPEC_PARTS.get(f, ()) if k != 'diagrams' and _open(v.get(k))]
    if (gap := spec_diagram_gap(s)) and not any(x.startswith(gap + ' (') for x in out):
        out.append(f'{gap}: which diagram shows it (C4 context / container, sequence, state, flowchart of the algorithm, ER)? Mermaid source, or n/a + why')
    for r in s.get('rules') or []:
        out += [f'{r.get("id")}: {k}? ({"the rule" if k == "text" else "Given / When / Then"})' for k in ('text', 'acceptance')
                if r.get('status') != 'removed' and not r.get(k)]
    out += [f'{d.get("id")}: which option, and why?' for d in s.get('decisions') or [] if isinstance(d, dict) and not d.get('chosen')]
    return out + ([] if _na(s.get('questions')) else [f'Open: {q}' for q in s.get('questions') or []])


def mmdc_path():
    """The pinned mmdc (spec setup) or one on PATH, else ''."""
    p = os.path.join(kit_path('tools'), 'mmdc', 'node_modules', '.bin', 'mmdc' + ('.cmd' if os.name == 'nt' else ''))
    return p if os.path.isfile(p) else shutil.which('mmdc') or ''


def mmdc_setup():
    """Install the pinned mermaid-cli into <runtime>/tools/mmdc; a local Chrome / Edge is reused (no browser download)."""
    npm, d = shutil.which('npm'), os.path.join(kit_path('tools', create=True), 'mmdc')
    if not npm:
        raise SystemExit('spec setup: npm is not on PATH (install Node.js); diagrams stay Mermaid source blocks')
    exe = globals().get('find_browser', lambda: '')()   # adapters/report_pdf.py: the kit's one Python browser list
    os.makedirs(d, exist_ok=True)
    r = subprocess.run([npm, 'install', '--prefix', d, '--no-audit', '--no-fund', f'@mermaid-js/mermaid-cli@{MMDC_PIN}'], capture_output=True, text=True,
                       errors='replace', timeout=600, env={**os.environ, **({'PUPPETEER_SKIP_DOWNLOAD': '1'} if exe else {})})
    if r.returncode:
        raise SystemExit(f'spec setup: npm install failed (exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}')
    with open(os.path.join(d, 'puppeteer.json'), 'w', encoding='utf-8') as fh:
        json.dump({'executablePath': exe, 'args': ['--no-sandbox']} if exe else {'args': ['--no-sandbox']}, fh)
    return f'mmdc {MMDC_PIN}: {mmdc_path() or d}' + (f' (browser {exe})' if exe else ' (puppeteer browser)')


def _diagram(key, i, d, n=2):
    """A diagram: the image (pinned mmdc renders the Mermaid source; hosted where the doc store hosts evidence) above its source block."""
    src, mmdc, img = str(d.get('mermaid') or '').strip(), mmdc_path(), ''
    if src and mmdc:
        base = os.path.join(kit_path('docs', create=True), re.sub(r'[^\w.-]+', '_', f'{key}-d{i}-{zlib.crc32(src.encode()):08x}'))
        pk, png = f'{key}:spec', base + '.png'
        if not os.path.isfile(png):
            with open(base + '.mmd', 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(src + '\n')
            cfg = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(mmdc))), 'puppeteer.json')
            try:
                subprocess.run([mmdc, '-i', base + '.mmd', '-o', png, '-b', 'white', '-s', '2'] + (['-p', cfg] if os.path.isfile(cfg) else []), capture_output=True, timeout=120)
            except (OSError, subprocess.SubprocessError):
                pass
        if os.path.isfile(png):
            hosted = (_pub_read(pk).get('diagramSrc') or {}).get(os.path.basename(png))
            if not hosted and (hosted := ((make_evidence(f'{key} spec diagrams', [png], key=pk).get('files') or {}).get(os.path.basename(png)) or {}).get('src')):
                _pub_update(pk, diagramSrc={**(_pub_read(pk).get('diagramSrc') or {}), os.path.basename(png): hosted})
            if hosted or REPORT_TYPE in ('markdown', 'html'):   # a kept local doc reads the file; a hosted doc needs a hosted image
                img = f'![{d.get("title", "diagram")}]({(hosted or png).replace(chr(92), "/")})\n\n'
            else:
                print(f'[spec] {key}: diagram "{d.get("title", "")}" image not hosted (reports.evidence): kept as Mermaid source', file=sys.stderr)
        else:
            print(f'[spec] {key}: diagram "{d.get("title", "")}" did not render (mmdc {mmdc}): kept as Mermaid source', file=sys.stderr)
    elif src:
        print(f'[spec] {key}: diagram "{d.get("title", "")}" kept as Mermaid source (devtools.py spec setup installs mmdc for an image)', file=sys.stderr)
    kind = f' ({d["type"]})' if d.get('type') else ''
    return f'{"#" * (n + 1)} {d.get("title") or f"Diagram {i}"}{kind}\n\n{img}```mermaid\n{src}\n```'


def _spec_val(k, v, key):
    """One part's Markdown lines."""
    if _na(v):
        return [f'- **{_label(k)}:** n/a — {v["na"]}' if str(v['na']).strip() else f'- **{_label(k)}:** **open**']
    if v in (None, '', [], {}):
        return [f'- **{_label(k)}:** **open**']
    if k == 'diagrams':
        return ['', '\n\n'.join(_diagram(key, i, d if isinstance(d, dict) else {'mermaid': d}) for i, d in enumerate(v if isinstance(v, list) else [v], 1)), '']
    if k == 'contracts' and isinstance(v, list) and all(isinstance(x, dict) for x in v):
        return [f'- **{_label(k)}:**', '', _table(['Contract', 'Contracts file row'], [[x.get('name', ''), x.get('ref', '')] for x in v]), '']
    if k == 'pseudocode':
        return ['- **Pseudocode:**', '', f'```\n{v}\n```', '']
    if isinstance(v, list) and k in ('steps', 'whys'):
        return [f'- **{_label(k)}:**'] + [f'{i}. {x}' for i, x in enumerate(v, 1)]
    if isinstance(v, list):
        return [f'- **{_label(k)}:** ' + '; '.join(str(x) if not isinstance(x, dict) else ' · '.join(str(y) for y in x.values() if y) for x in v)]
    return [f'- **{_label(k)}:** {v}']


def _spec_body(f, v, s, key):
    """One section's body (v answered, never None)."""
    li = lambda xs: '\n'.join(f'- {x}' if isinstance(x, str) else '- ' + ' · '.join(str(y) for y in x.values() if y) for x in (xs if isinstance(xs, list) else [xs]))
    tab = lambda head, keys, xs: _table(head, [[x.get(k, '') if isinstance(x, dict) else (x if k == keys[0] else '') for k in keys] for x in xs])
    if f == 'users' and isinstance(v, list):
        return tab(['Who', 'Flow'], ('who', 'flow'), v)
    if f == 'metrics' and isinstance(v, list):
        return tab(['Metric', 'Target', 'By when'], ('metric', 'target', 'by'), v)
    if f == 'glossary' and isinstance(v, list):
        return tab(['Term', 'Meaning'], ('term', 'meaning'), v)
    if f == 'rules' and isinstance(v, list):
        edges = [e for e in s.get('edges') or [] if not _na(s.get('edges'))]
        cut = lambda r: [f'- {e}' if isinstance(e, str) else f'- {e.get("text", "")} ({e["rule"]})' for e in edges if (e.get('rule') if isinstance(e, dict) else None) == r]
        rest = [x for r in [None] + [x.get('id') for x in v] for x in cut(r)]
        return 'One testable rule per S-id; test cases, commits, MRs and QA results cite it.\n\n' + _table(['S-id', 'Rule', 'Acceptance'], [
            [r['id'] + (' (removed)' if r.get('status') == 'removed' else ''), r.get('text') or '**open**', r.get('acceptance') or '**open**'] for r in v]) \
            + ('\n\n**Edge cases** (under their rule)\n\n' + '\n'.join(rest) if rest else '')
    if f == 'decisions' and isinstance(v, list):
        return '\n\n'.join(f'**{d.get("question") or d.get("id")}**' + (f' ({d["id"]})' if d.get('id') and d.get('id') != d.get('question') else '')
                           + f' · drivers: {d.get("drivers") or "—"} · chosen: {d.get("chosen") or "**open**"} · why: {d.get("why") or "—"}'
                           + f' · confirm-by: {d.get("confirm") or "—"}' + (f' · by: {d["by"]}' if d.get('by') else '')
                           + ('\n\n' + tab(['Option', 'What', 'Pros', 'Cons'], ('id', 'text', 'pros', 'cons'), d['options']) if isinstance(d.get('options'), list) and d['options'] else '')
                           for d in v)
    if f == 'risks' and isinstance(v, list):
        return '\n'.join(f'- {r}' if isinstance(r, str) else f'- {r.get("text", "")}' + (f' · mitigation: {r["mitigation"]}' if r.get('mitigation') else '') for r in v)
    if isinstance(v, dict):
        keys = list(SPEC_PARTS.get(f, ())) + [k for k in v if k not in SPEC_PARTS.get(f, ())]
        return '\n'.join(x for k in keys for x in _spec_val(k, v.get(k), key)).strip()
    return li(v) if isinstance(v, list) else str(v)


def render_spec(s, key, ver, log, tasks=()):
    """The spec doc (templates.md "Spec"): the kind's sections, each always present (answered, 'n/a — <why>' or its purpose +
    open question), the change log with the S-ids each version touched."""
    s = spec_migrate(s)
    qs, last, parts = spec_questions(s), (log or [{}])[-1], []
    for f, kinds, head, purpose, q in spec_sections(s.get('kind')):
        v = s.get(f)
        if f == 'questions':
            body = '\n'.join(f'- {x}' for x in qs) if qs else 'none — every section answered'
        elif _na(v):
            body = f'n/a — {v["na"]}' if str(v['na']).strip() else f'**Open** ({purpose}): {q} (n/a needs its reason)'
        elif v in (None, '', [], {}):
            body = f'**Open** ({purpose}): {q}'
        else:
            body = _spec_body(f, v, s, key)
        parts += [head if head.startswith('#') else f'## {head}', body]
    known = {f for f, *_ in spec_sections(s.get('kind'))} | {'kind', 'title', 'edges'}
    if extra := {k: v for k, v in s.items() if k not in known and v not in (None, '', [], {})}:   # a v1 field this kind has no section for: shown, never lost
        parts += ['## Carried from the earlier template', _spec_body('carried', extra, s, key)]
    head = [f'# {key} Spec v{ver} — {s.get("title", "")}',
            _table(['', ''], [['Kind', s.get('kind', '')], ['Status', f'draft · {len(qs)} open question(s)' if qs else 'ready'],
                              ['Version', f'v{ver} · {last.get("date", "")} · {last.get("by", "")}'], ['Tasks', ', '.join(tasks) or 'none (standing subject spec)']])]
    log_t = _table(['Version', 'Date', 'By', 'What changed', 'S-ids'], [[f'v{e["v"]}', e.get('date', ''), e.get('by', ''), e.get('what', ''), ', '.join(e.get('ids') or []) or '—'] for e in log])
    return '\n\n'.join(head + parts + ['## Change log', log_t]) + '\n'


def spec_template(kinds=SPEC_KINDS):
    """The blank template per kind (the template doc): each section's heading, purpose and the questions briefy asks."""
    out = ['# Spec template', 'Rendered by `devtools.py spec write`; every section always present: answered, `n/a — <why>` or its open question. '
           'S-ids (S1..Sn, never reused) are cited by test cases, commits, MRs and QA results. Diagrams: Mermaid source kept, an image rendered.']
    for k in kinds:
        out.append(f'## Kind: {k}')
        for f, _, head, purpose, q in spec_sections(k):
            parts = ', '.join(SPEC_PARTS.get(f, ()))
            out.append(f'{"#" * (head.count("#") + 1) if head.startswith("#") else "###"} {head.lstrip("# ")}\n\n*{purpose}*' + (f' · parts: {parts}' if parts else '')
                       + (f'\n\nAsk: {q}' if q else ''))
        out.append('### Change log\n\n*version, date, by, what changed and why, S-ids touched*')
    return '\n\n'.join(out) + '\n'


def spec_link(tid, rec=None):
    """{'spec': link text} for a task's description links block: '[open](url) · v<n>' (+ the S-ids its last change touched)."""
    rec = rec or spec_rec(tid)
    if not rec.get('url') or rec.get('retired'):   # a retired spec: its Spec line goes
        return {}
    ids = (rec.get('log') or [{}])[-1].get('retest') or []   # S-ids of built work this version changed
    u = f'[open]({rec["url"]})' if re.match(r'https?://\S+$', rec['url']) else rec['url']
    return {'spec': f'{u} · v{rec.get("version")}' + (f' (changed {", ".join(ids)}: retest)' if ids else '')}


def task_doc_links(tid):
    """Every published doc link of a task (process.docs) for links_block: a new links block never drops another doc's line."""
    return {**{d['key']: u for d in docs() if d['key'] != 'spec' and (u := _pub_read(f'{tid}:{d["key"]}').get('url'))}, **spec_link(tid)}


def link_task_spec(tid, rec):
    """The task's Spec line: through its tracker spec (spec-rendered task) or the description's links block; no tracker: skipped."""
    t = task(tid) if TRACKER_TYPE != 'none' else {}
    if 'spec' not in [d['key'] for d in docs()]:
        print(f'WARN [spec] {tid}: process.docs (kit.local.json) has no "spec" doc: the task gets no Spec line (add vocab.json\'s spec entry)', file=sys.stderr)
    try:
        if not t.get('id'):
            raise SystemExit(view_why(t)[:120] or f'tracker.type {TRACKER_TYPE}')
        if (state_read(task_file(tid)) or {}).get('spec') and re.match(r'https?://', rec.get('url') or ''):   # retired: the Spec field emptied
            _tracker('update', tid, '-Spec', json.dumps({'docs': {'spec': '' if rec.get('retired') else rec['url']}}) + '\n')
        elif (new := links_block(t.get('description') or '', task_doc_links(tid))) != (t.get('description') or ''):
            _tracker('describe', tid, new)
    except SystemExit as e:   # the doc is published and recorded; finish writes the Spec line with the testing docs
        print(f'[spec] {tid}: Spec line not written on the tracker ({str(e)[:160]}); finish writes it', file=sys.stderr)


def spec_write(key, path, by='', subject=False):
    """Merge a spec JSON into <key>'s spec, bump the version with a change-log line (S-ids touched), publish it (replace: one doc,
    same link), link it on its tasks and mark their changed S-ids for retest -> URL."""
    new, pk = load_spec(path), f'{key}:spec'
    what, rec = str(new.pop('change', '') or ''), _pub_read(pk)
    subject = bool(subject or rec.get('subject'))
    old = spec_migrate(rec.get('data') or {})
    kd = new.get('kind') or old.get('kind')
    new = {k: v for k, v in spec_migrate({**new, 'kind': kd}).items() if k != 'kind' or 'kind' in new}
    for k, v in list(new.items()):   # an object section merges by part ({"rollout": {"tell": ".."}} answers one part); a None part deletes it
        if k in SPEC_PARTS and isinstance(v, dict) and not _na(v) and isinstance(old.get(k), dict) and not _na(old[k]):
            new[k] = {p: x for p, x in {**old[k], **v}.items() if x is not None}
    data = merge_spec(old, new, SPEC_LISTS)
    if gaps := spec_shape(data):
        raise SystemExit(f'spec {key} refused: {"; ".join(gaps)} (devtools.py spec --help). Nothing was written.')
    if data == old:
        print(f'spec {key}: unchanged (v{rec.get("version")})', file=sys.stderr)
        return rec.get('url') or ''
    ver = int(rec.get('version') or 0) + 1
    if ver > 1 and not what:
        raise SystemExit(f'spec {key}: v{ver} needs a "change" line (what changed and why) for its change log. Nothing was written.')
    was = {str(r.get('id')): r for r in old.get('rules') or []}
    ids = [str(r['id']) for r in data.get('rules') or [] if was.get(str(r['id'])) != r]
    log = list(rec.get('log') or []) + [{'v': ver, 'date': time.strftime('%Y-%m-%d'), 'by': by or me_agent() or 'unknown', 'what': what or 'first version', 'ids': ids,
                                         'retest': [i for i in ids if i in was] if rec.get('ready') else []}]
    tasks = list(rec.get('tasks') or ([] if subject else [key]))
    for t in tasks if not subject else ():   # the task index first: publish points its docs.spec at the record
        task_index(t, lambda x: x.__setitem__('specKey', key))
    out = os.path.join(kit_path('docs', create=True), re.sub(r'[^\w.-]+', '_', key) + '-spec.md')
    with open(out, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(render_spec(data, key, ver, log, tasks))
    url = publish(pk, f'{key} Spec — {data["title"]}', out, mode='replace')
    qs = spec_questions(data)
    _pub_update(pk, data=data, version=ver, log=log, tasks=tasks, subject=subject, ready=not qs, retired=None)   # a new version un-retires
    for t in tasks:
        sel = (state_read(task_file(t)) or {}).get('specIds') if subject else None
        mine = [i for i in log[-1]['retest'] if not sel or i in sel]   # a new rule or an answer to a draft is no retest
        if mine:   # built or deployed work on these S-ids is retested; briefy messages the agents (E8)
            task_index(t, lambda x: x.__setitem__('specRetest', {'key': key, 'version': ver, 'ids': mine}))
            print(f'RETEST {t}: {", ".join(mine)} (spec {key} v{ver})')
        link_task_spec(t, _pub_read(pk))
    print(f'spec {key} v{ver} {"ready" if not qs else f"draft, {len(qs)} open (spec questions {key})"}: {url}'
          + (f' · changed {", ".join(ids)}' if ver > 1 and ids else ''), file=sys.stderr)
    return url


def spec_retire(key, reason, by=''):
    """A superseded spec: its doc republished with a SUPERSEDED banner (v+1, change log), its tasks lose the link and the Spec line."""
    pk, rec = f'{key}:spec', _pub_read(f'{key}:spec')
    if not rec.get('data') or not reason:
        raise SystemExit(f'spec retire {key}: {"--reason <why> (e.g. superseded by <task>)" if rec.get("data") else "no spec (spec show " + key + ")"}. Nothing was written.')
    if rec.get('retired'):
        print(f'spec {key}: already retired ({rec["retired"].get("reason")})', file=sys.stderr)
        return rec.get('url') or ''
    ver, tasks, day, who = int(rec.get('version') or 0) + 1, list(rec.get('tasks') or []), time.strftime('%Y-%m-%d'), by or me_agent() or 'unknown'
    log = list(rec.get('log') or []) + [{'v': ver, 'date': day, 'by': who, 'what': f'retired: {reason}', 'ids': [], 'retest': []}]
    out = os.path.join(kit_path('docs', create=True), re.sub(r'[^\w.-]+', '_', key) + '-spec.md')
    with open(out, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(f'**SUPERSEDED** {day}: {reason}. Do not build or test against this spec.\n\n' + render_spec(rec['data'], key, ver, log, tasks))
    url = publish(pk, f'[Superseded] {key} Spec — {rec["data"].get("title")}', out, mode='replace')
    _pub_update(pk, version=ver, log=log, ready=False, retired={'reason': reason, 'date': day, 'by': who})
    for t in dict.fromkeys(tasks + ([] if rec.get('subject') else [key])):
        task_index(t, lambda x: [x.pop(f, None) for f in ('specKey', 'specIds', 'specRetest')] if x.get('specKey') in (key, None) else None)
        link_task_spec(t, _pub_read(pk))   # links_block without the spec: the Spec line goes
    print(f'spec {key} retired (v{ver}, {len(tasks)} task(s) unlinked): {url}', file=sys.stderr)
    return url


def spec_trace_gaps(tid):
    """The S-ids of a task's spec (own, or a linked subject's: the ids the link names) that no check or case of its cases spec cites."""
    rec, ts = spec_rec(tid), state_read(task_file(tid)) or {}
    key = (rec.get('key') or '').rpartition(':')[0]
    if not rec.get('data') or rec.get('retired'):
        return []
    want = [str(r['id']) for r in rec['data'].get('rules') or [] if r.get('status') != 'removed']
    want = [i for i in want if key == tid or not ts.get('specIds') or i in ts['specIds']]
    c = ts.get('cases') or {}
    cited = {str(v) for k in ('checks', 'cases') for x in c.get(k) or [] for v in _as_list(x.get('spec'))}
    return [i for i in want if i not in cited and f'{key}:{i}' not in cited]


def spec_cmd(a):
    """spec write <task|subject> <spec.json> [--subject] [--by <who>] · questions <key> · link <task> <subject> [--ids S1,S2]
    · trace <task> · show <task|subject> · retire <task|subject> --reason <why> · template [feature|bug|subject] · setup
      python -X utf8 devtools.py spec write T1 spec-t1.json --by briefy-w2      (a task's spec: linked on T1 as its Spec line)
      python -X utf8 devtools.py spec questions T1 [--kind bug]   (open sections, parts and rule gaps: the interview, one per line; exit 1 when any)
      python -X utf8 devtools.py spec template bug     (the kind's sections: purpose + questions; no kind: all three)
      python -X utf8 devtools.py spec setup            (once per machine: pinned mmdc into <runtime>/tools for diagram images)
      python -X utf8 devtools.py spec write orders-list spec.json --subject     (a standing spec for a module or flow)
      python -X utf8 devtools.py spec link T1 orders-list --ids S1,S3           (a task builds against a standing spec)
      python -X utf8 devtools.py spec trace T1         (S-ids no test case cites: exit 1; finish refuses them)
      python -X utf8 devtools.py spec retire T1 --reason 'superseded by T7'   (doc marked SUPERSEDED, Spec line and links removed)"""
    verbs = ('write', 'questions', 'link', 'trace', 'show', 'retire', 'template', 'setup')
    if a and a[0] == 'setup':
        print(mmdc_setup())
        return 0
    if a and a[0] == 'template':
        print(spec_template([k for k in a[1:2] if k in SPEC_KINDS] or SPEC_KINDS), end='')
        return 0
    if not a or a[0] in ('-h', '--help', 'help') or a[0] not in verbs or len(a) < 2:
        hlp = a and a[0] in ('-h', '--help', 'help')
        print(spec_cmd.__doc__ + '\n' + SPEC_FIELDS, file=sys.stdout if hlp else sys.stderr)
        return 0 if hlp else 2
    opt = {a[i][2:]: a[i + 1] for i in range(len(a) - 1) if a[i] in ('--by', '--ids', '--reason', '--kind')}
    verb, key = a[0], a[1]
    if verb == 'write':
        if len(a) < 3:
            raise SystemExit('spec write <task|subject> <spec.json> [--subject] [--by <who>]')
        print(spec_write(key, a[2], opt.get('by') or '', '--subject' in a))
    elif verb == 'questions':
        rec = spec_rec(key)
        qs = spec_questions(rec.get('data') or {'kind': opt.get('kind') or 'feature'})
        print('\n'.join(f'Q{i} {q}' for i, q in enumerate(qs, 1)) or f'{key}: ready (no open question)')
        return 1 if qs else 0
    elif verb == 'link':
        rec = _pub_read(f'{a[2]}:spec') if len(a) > 2 else {}
        if not rec.get('data'):
            raise SystemExit(f'spec link {key}: no spec {a[2] if len(a) > 2 else "<subject>"} (spec write <subject> <spec.json> --subject first)')
        ids = _as_list(opt.get('ids'))
        task_index(key, lambda x: x.update(specKey=a[2], **({'specIds': ids} if ids else {})))
        _pub_update(f'{a[2]}:spec', tasks=sorted(set(rec.get('tasks') or []) | {key}))
        link_task_spec(key, rec)
        print(f'spec {a[2]} v{rec.get("version")} linked on {key}' + (f' ({", ".join(ids)})' if ids else ''))
    elif verb == 'retire':
        print(spec_retire(key, opt.get('reason') or '', opt.get('by') or ''))
    elif verb == 'trace':
        gaps = spec_trace_gaps(key)
        print('\n'.join(f'{key}: {i} has no test case (cases add: a check or case with "spec": "{i}")' for i in gaps) or f'{key}: every S-id has a test case')
        return 1 if gaps else 0
    else:
        rec, rt = spec_rec(key), (state_read(task_file(key)) or {}).get('specRetest')
        if not rec.get('data'):
            print(f'{key}: no spec')
            return 1
        print(f'{rec["key"]} v{rec.get("version")} {"retired: " + rec["retired"].get("reason", "") if rec.get("retired") else "ready" if rec.get("ready") else "draft"} {rec.get("url")} · S-ids '
              + ', '.join(str(r['id']) for r in rec['data'].get('rules') or [] if r.get('status') != 'removed')
              + (f' · retest {", ".join(rt["ids"])} (v{rt["version"]})' if rt else ''))
    return 0


RENDERERS = {'mr-title': render_title, 'mr-body': render_mr_body, 'commit': render_commit, 'comment-solution': render_solution,
             'comment-status': render_status, 'final-report': render_report, 'retro': render_retro, 'wave-brief': render_wave_brief}   # devtools.py render <kind> <spec.json>; comment / finish --spec


def load_spec(src):
    """A spec: a JSON file path or the JSON itself (starts with '{'); a Windows path's lone backslash (D:\\x) is kept, not an error."""
    if str(src).lstrip().startswith('{'):
        text = src
    elif not os.path.isfile(src):
        print(f'no such spec file {src} (pass a file path or inline JSON)', file=sys.stderr)
        raise SystemExit(2)   # a usage error, not a traceback
    else:
        text = open(src, encoding='utf-8-sig').read()
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:   # retro 1549: retro.json with raw Windows paths failed render retro
        if 'escape' not in str(e):
            raise
        return json.loads(re.sub(r'\\(["\\/]|u[0-9a-fA-F]{4})|\\', lambda m: m.group(0) if m.group(1) else '\\\\', text))   # \t \n \b in a path stay text


def spec_text(path, kind, task='', add=None):
    """A spec file rendered as kind (refused on gaps); task fills the spec's task when it has none; add: keys the caller knows."""
    s = {**load_spec(path), **(add or {})}
    s = {'task': task, **s} if task else s
    if gaps := spec_gaps(s, kind):
        raise SystemExit(f'{kind} spec refused: missing {", ".join(gaps)} (templates.md "Comment spec" / "MR spec")')
    return RENDERERS[kind](s)


def render_cmd(a):
    """render <kind> <spec.json> [<out file>]: the artefact's text on stdout or into the file (kinds: RENDERERS); refused on spec gaps."""
    if len(a) < 2 or a[0] not in RENDERERS:
        print(f'usage: devtools.py render {"|".join(RENDERERS)} <spec.json>', file=sys.stderr)
        return 2
    if a[0] == 'wave-brief' and len(a) < 3:
        print('usage: devtools.py render wave-brief <spec.json> <brief.md> (contracts + /buildy args land beside it)', file=sys.stderr)
        return 2
    con = {'contractsFile': os.path.basename(os.path.splitext(a[2])[0]) + '.contracts.md'} if a[0] == 'wave-brief' else None   # the file wave_files writes
    if a[0] == 'wave-brief' and (draft := [t for t in load_spec(a[1]).get('specs') or [] if not spec_rec(t).get('ready')]):   # Spec before build
        why = lambda t: f'retired: {r["retired"].get("reason")}' if (r := spec_rec(t)).get('retired') else 'not ready (devtools.py spec questions <task>)'
        raise SystemExit(f'wave-brief refused: spec of {"; ".join(f"{t} {why(t)}" for t in draft)}. Nothing was written.')
    txt = spec_text(a[1], a[0], add=con).rstrip('\n') + '\n'
    if len(a) > 2:   # an out file: written, its path printed
        extra = wave_files(load_spec(a[1]), a[2]) if a[0] == 'wave-brief' else {}
        for path, body in {a[2]: txt, **extra}.items():
            with open(path, 'w', encoding='utf-8', newline='\n') as fh:
                fh.write(body)
            print(path)
        return 0
    sys.stdout.flush()
    sys.stdout.buffer.write(txt.encode('utf-8'))   # LF on every OS (a commit message, a golden file)
    return 0


# ---- plugins: skills/crafty/adapters/*.py
def load_plugins(folder=os.path.join(KIT, 'adapters')):
    """Each skills/crafty/adapters/*.py (a plugin) gets this module in register(dt) and adds adapters or verbs."""
    this = sys.modules[__name__]
    for path in sorted(glob.glob(os.path.join(folder, '*.py'))):
        spec = importlib.util.spec_from_file_location('kit_plugin_' + os.path.splitext(os.path.basename(path))[0], path)
        plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(plugin)
        plugin.register(this)


load_plugins()


# ---- keepboth: append-only rebase conflicts
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


# ---- selftest: offline checks
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
    g0 = globals()   # today's two-doc process = the legacy config rows (kit.local.json process.gates, mr.footer); neutral checks below
    LEGACY_GATES = {'promote': 'builtin:testingDocs', 'merge': 'builtin:testingDocs', 'finish': 'builtin:testingDocs', 'mrBody': 'builtin:testingDocs', 'bugFix': 'builtin:reproRow'}
    CFG['process'] = {'gates': dict(LEGACY_GATES)}; g0['FOOTER'] = '\U0001f916 Generated with [Claude Code](https://claude.com/claude-code)'
    refused('a missing body file is refused', lambda: _body('no-such-body.md'), 'file not found')
    expect('multi-line body text passes', _body('a\nb') == 'a\nb')
    refused('merge: a repo name instead of a worktree folder is refused', lambda: remote('no-such-checkout-x1'), 'not a folder')
    page = md_to_html('![shot 1](https://x/a.png "260") [link](https://y)\n![b](c.png)')
    expect('md_to_html: images with width (default 600) and captions, links stay links', '<img src="https://x/a.png" width="260"><br><i>shot 1</i>' in page
           and '<img src="c.png" width="600">' in page and '<a href="https://y" target="_blank" rel="noopener">link</a>' in page)
    spec_only = ['svc/api/cypress/**', 'svc/api/package.json']   # incident 2026-11-14: a spec-only area's MR changed product files
    diff = ['svc/api/cypress/e2e/inv.cy.js', 'svc/api/package.json', 'svc/api/src/main/java/InventoryService.java', 'svc/api/cypress.config.js']
    expect('scope: files outside the area globs are named (** any depth, an exact file, a sibling is outside)',
           scope_outside(diff, spec_only) == diff[2:] and scope_outside(diff, []) == [] and scope_outside(['a/b/c.ts'], ['a/']) == []
           and scope_outside(['a/x.ts', 'a/b/x.ts'], ['a/*.ts']) == ['a/b/x.ts'] and scope_outside(['x/test/y.ts', 'test/z.ts'], ['**/test/**']) == []
           and scope_outside(['s/a.ts', 's/b/c.html', 's/d.css', 'S/a.ts'], ['s/**/*.{ts,html}']) == ['s/d.css', 'S/a.ts'])   # K61: {a,b}, case kept
    no = scope_refusal(diff, spec_only, 'f/t1-specs', what='merge')
    expect('scope: the refusal names the files, the area and the decision path', 'merge refused: 2 file(s)' in no and 'InventoryService.java' in no
           and '-Gate scope -Item f/t1-specs' in no and scope_refusal(diff[:2], spec_only, 'b') == '')
    td = tempfile.mkdtemp(); lg = os.path.join(td, 'scopes.jsonl')
    with open(lg, 'w', encoding='utf-8') as fh:
        fh.write(''.join(json.dumps({'event': 'area', 'mr': 'api!5', 'globs': g}) + '\n' for g in (['old/**'], spec_only)) + '{"event": "area", "mr": "api!55", "globs": ["x"]}\n{"event": "area", "mr": "api!5", "glo\n')
    expect('scope: a deferred merge (no record, no --scope) takes the MR\'s last logged area, a torn line skipped', scope_of(td, '', 'api!5', lg) == spec_only
           and scope_of(td, '', 'api!6', lg) == [] and scope_of(td, 'a/**, b/', 'api!5', lg) == ['a/**', 'b/'])
    for c in (['init', '-q', '-b', 'f/area-m'], ['-c', 'user.name=t', '-c', 'user.email=t@e', 'commit', '-q', '--allow-empty', '-m', 'x']):
        subprocess.run(['git', '-C', td, *c], capture_output=True)
    with open(os.path.join(td, '.git', 'claude-scope'), 'w', encoding='utf-8') as fh:
        fh.write('web/site/**\n')   # incident 2026-11-21: a pool slot re-leased to area M refused another branch's MR with M's globs
    expect('scope: merge reads the worktree record only when the slot is on the MR\'s branch, else the MR\'s logged area',
           scope_of(td, '', 'api!5', lg, branch='f/area-m') == ['web/site/**'] and scope_of(td, '', 'api!5', lg, branch='fix/other') == spec_only
           and scope_of(td, '', 'api!6', lg, branch='fix/other') == [])
    shutil.rmtree(td, ignore_errors=True)
    wb = {'name': 'w', 'mandate': ['m'], 'agents': [{'id': 'W2c', 'items': 'A1', 'area': 'specs', 'paths': spec_only}]}
    expect('wave brief: an area\'s paths are in the brief and the /buildy args', 'svc/api/cypress/**' in render_wave_brief(wb)
           and json.loads(wave_files(wb, 'b.md')['b.args.json'])['agents'][0]['paths'] == spec_only)
    expect('wave brief: the MR title and body limits from "Writing standards" (retro 2026-11-22)', ' '.join(f'; {prose_limits("mr-body") or "mr-body"}'.split()) in ' '.join(render_wave_brief(wb).split())
           and (not os.path.exists(os.path.join(KIT_DIR, 'skills/crafty/templates.md')) or ' limits ' in prose_limits('mr-body')))   # a test kit may lack templates.md
    td = tempfile.mkdtemp(); wsp, wbp = os.path.join(td, 'w.json'), os.path.join(td, 'wave-x.md')
    with open(wsp, 'w', encoding='utf-8') as fh:
        json.dump(wb, fh)
    with contextlib.redirect_stdout(io.StringIO()):
        render_cmd(['wave-brief', wsp, wbp])
    expect('wave brief: names the contracts file it writes (<brief stem>.contracts.md)', '`wave-x.contracts.md`' in open(wbp, encoding='utf-8').read() and os.path.isfile(os.path.join(td, 'wave-x.contracts.md')))
    shutil.rmtree(td, ignore_errors=True)
    # order (owner 2026-11-23): dependsOn + contract producers -> waves; one task per area -> its waits-on tasks; a shared task skipped; a cycle last
    wo = {'name': 'v2', 'agents': [{'id': 'A', 'task': 't1'}, {'id': 'B', 'task': 't2', 'dependsOn': ['A']}, {'id': 'C', 'task': 't3'}, {'id': 'D', 'task': 't4'}, {'id': 'E', 'task': 't4'}],
          'contracts': [{'producer': 'B', 'consumers': 'C, D'}]}
    ot = order_tasks(wo); cy = wave_order({'agents': [{'id': 'X', 'dependsOn': ['Y']}, {'id': 'Y', 'dependsOn': ['X']}, {'id': 'Z'}]})[0]
    expect('wave order: A then B (dependsOn) then C (contract consumer); D / E share t4 (skipped); labels "<name> wave <n>" (naming on: tracker order makes them wave-<n>); a cycle is its own row',
           wave_order(wo)[0] == [(1, ['A', 'E']), (2, ['B']), (3, ['C', 'D'])] and [(t['task'], t['wave'], t['waitsOn']) for t in ot['tasks']] == [('t1', 'v2 wave 1', []), ('t2', 'v2 wave 2', ['t1']), ('t3', 'v2 wave 3', ['t2'])]
           and cy == [(1, ['Z']), ('cycle', ['X', 'Y'])] and '| 2 | B | t2 | A |' in render_wave_brief(wo) and 'b.order.json' in wave_files({**wo, 'mandate': ['m']}, 'b.md'))
    agent_env = {n: os.environ.pop(n, None) for n in ('CLAUDE_AGENT', 'KIT_AGENT')}
    try:
        own_spec({'by': 'AA', 'checks': [{'id': 'S2', 'by': 'BB'}]}, {'checks': [{'id': 'S3'}]})
        anon = ''
    except SystemExit as e:
        anon = str(e)
    finally:
        os.environ.update({n: v for n, v in agent_env.items() if v})
    expect('cases add: no CLAUDE_AGENT on a spec holding agents\' rows is refused', 'holds rows of AA, BB: set CLAUDE_AGENT' in anon)

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
        calls.clear(); g['_host'] = lambda verb, **a: calls.append((verb, a)) or {'raw': 'null'}
        res = auto_merge('.', '7', max_wait=0)
        expect('no MR state: mr.get retried once, WAIT names the project and the reply', merge_word(res) == 'WAIT' and 'g/r' in res
               and "'raw': 'null'" in res and [v for v, _ in calls] == ['mr.get', 'mr.get'])
        def nd(body):   # a fake per case: merged state carries from mr.merge to the re-read
            f = fake(cfg=False)
            return lambda v, **a: dict(f(v, **a), description=body) if v == 'mr.get' else f(v, **a)
        ok = [merge_word(auto_merge('.', '7')) for g['_host'] in (nd('Testing doc:\n\nNone of the old steps'), nd('- Testing doc: none yet, link below'))]
        calls.clear(); g['_host'] = nd('Fix x\n- Testing doc: none · Sibling MRs: -')
        r = auto_merge('.', '7'); none_merged = not merged()
        calls.clear(); g['_host'] = nd('- Testing doc: https://doc/1 (none of the old steps)')
        expect('MR body "Testing doc: none": NOT_MERGED, no merge call; a linked doc merges', merge_word(r) == 'NOT_MERGED' and 'Testing doc: none' in r
               and none_merged and merge_word(auto_merge('.', '7')) == 'MERGED' and ok == ['MERGED', 'MERGED'])
        tt0 = g['TRACKER_TYPE']; g['TRACKER_TYPE'] = 'clickup'
        calls.clear(); g['_host'] = nd('https://app.clickup.com/t/9\n- Testing doc: pending'); rp = auto_merge('.', '7'); pend = not merged()
        calls.clear(); g['_host'] = nd('https://app.clickup.com/t/9\n- Testing doc: [d](https://doc/1)\n- Testing doc (AI): https://doc/2'); g['TRACKER_TYPE'] = tt0
        expect('MR with a task link: "Testing doc: pending" NOT_MERGED, a linked doc merges', merge_word(rp) == 'NOT_MERGED' and pend and merge_word(auto_merge('.', '7')) == 'MERGED')
        kl0, logged = g['kitlog'], []; g['kitlog'] = lambda *a: logged.append(a); g['TRACKER_TYPE'] = 'clickup'; g['NO_DOCS'] = 'foundation area M'
        try:
            calls.clear(); g['_host'] = nd('https://app.clickup.com/t/9\n- Testing doc: none'); rx = merge_word(auto_merge('.', '7'))
        finally:
            g['kitlog'], g['NO_DOCS'], g['TRACKER_TYPE'] = kl0, '', tt0
        expect('merge --no-docs: a foundation area\'s task MR with no / "none" doc lines merges, the exemption logged with its reason',
               rx == 'MERGED' and [x[1] for x in logged if x[1] == 'docs-exempt'] and any(x[2].get('reason') == 'foundation area M' for x in logged if x[1] == 'docs-exempt'))
        pr0, tag0 = g['_pub_read'], g['TAG']; g['TAG'] = 'CU-'; g['TRACKER_TYPE'] = 'clickup'
        g['_pub_read'] = lambda key: {'url': f'https://d/{key.split(":")[1]}'} if key.startswith('T7:') and not key.endswith(g.get('_nodoc', '-')) else {}
        tb = lambda body: (lambda f: lambda v, **a: dict(f(v, **a), source_branch='f/CU-T7-x') if v == 'mr.get' else f(v, **a))(nd(body))
        lb = 'https://app.clickup.com/t/T7\n## Links\n- Testing doc: pending\n\n' + FOOTER
        calls.clear(); g['_host'] = tb(lb); rf = merge_word(auto_merge('.', '7')); up = [a.get('body', '') for v, a in calls if v == 'mr.update']
        g['_host'] = tb(lb.replace('pending', 'none')); rnone = merge_word(auto_merge('.', '7')); rt0, ups = g['read_tracking'], []
        g['read_tracking'] = lambda *a: {'tasks': {'T7': {'mrs': ['o/web!5', 'web!6']}}}
        g['_host'] = lambda v, **a: (ups.append(a) or {}) if v == 'mr.update' else ({'state': 'opened', 'title': 't', 'description': 'x'} if a.get('repo') == 'o/web' else {})
        cfg0 = g['CFG']; g['CFG'] = {}   # hermetic: a live repos[] entry 'web' would rewrite o/web!5
        with _c.redirect_stderr(io.StringIO()):
            rr = refresh_mr_docs('T7', 'github', states=(rst := []))
        g['read_tracking'], g['CFG'] = rt0, cfg0; rfin = rr == ['o/web!5'] and rst == [('o/web!5', 'opened', True), ('web!6', 'unreadable', False)] and 'Testing doc (AI): https://d/testing-ai' in ups[0]['body'] and rnone == 'MERGED'
        g['_nodoc'] = 'testing-ai'; calls.clear(); g['_host'] = tb(lb); rn = auto_merge('.', '7'); nm = not merged()
        wl, miss = with_doc_lines(lb, 'T7'); wm = with_doc_lines(lb.replace('- Testing doc: pending', '- Testing doc: https://d/T8-doc\n- Testing doc: pending'), 'T7')[0]; g.pop('_nodoc')
        g['_pub_read'] = lambda key: {'rounds': [{'body': g['_aib']}]} if key == 'T7:testing-ai' else {}
        fb = lambda: (lambda f: lambda v, **a: dict(f(v, **a), source_branch='fix/CU-T7-x') if v == 'mr.get' else f(v, **a))(nd('x'))
        g['_aib'] = '| A1 | regression | s | ok | PASS | [j](https://j) |'; calls.clear(); g['_host'] = fb(); rb = auto_merge('.', '7'); bnm = not merged()
        g['_aib'] += '\n| A0 | repro | the bug, then the fix | 500, then 200 | PASS | [j](https://j) |'; calls.clear(); g['_host'] = fb()
        expect('merge: a bug fix (branch fix/) whose AI doc has no repro row: NOT_MERGED, no merge call; with one: MERGED',
               merge_word(rb) == 'NOT_MERGED' and 'no local reproduction' in rb and bnm and merge_word(auto_merge('.', '7')) == 'MERGED')
        g['_pub_read'], g['TAG'], g['TRACKER_TYPE'] = pr0, tag0, tt0
        expect(f'merge: a task MR without doc lines (or "none") gets them from the published docs and merges; finish writes them into tracked open MRs; a doc not published: NOT_MERGED naming it ({rf}, {miss})',
               rf == 'MERGED' and rfin and up and '## Links\n- Testing doc: https://d/testing-doc\n- Testing doc (AI): https://d/testing-ai\n' in up[0] and 'pending' not in up[0]
               and merge_word(rn) == 'NOT_MERGED' and 'testing-ai' in rn and nm and miss == ['testing-ai'] and 'Testing doc: https://d/testing-doc' in wl and 'pending' not in wl and '- Testing doc: https://d/T8-doc' in wm and 'pending' not in wm)   # several tasks: lines merged
        # neutral: process.gates unset -> no doc lines, no "none" refusal, no repro gate; a hook gate refuses with its stdout
        g['CFG']['process'] = {}; g['TRACKER_TYPE'] = 'clickup'; g['TAG'] = 'CU-'
        g['_pub_read'] = lambda key: {}
        calls.clear(); g['_host'] = tb('https://app.clickup.com/t/T7\n- Testing doc: none'); n1 = merge_word(auto_merge('.', '7')); n1u = [v for v, _ in calls if v == 'mr.update']
        calls.clear(); g['_host'] = fb(); n2 = merge_word(auto_merge('.', '7'))
        hk = os.path.join(tempfile.mkdtemp(), 'gate.py')
        with open(hk, 'w', encoding='utf-8') as fh:
            fh.write('import json, sys\np = json.load(sys.stdin)\nprint(p["gate"] + " says no to " + p["mr"])\nsys.exit(0 if p["branch"].startswith("ok/") else 1)\n')
        g['CFG']['process'] = {'gates': {'merge': f'"{sys.executable}" "{hk}"'}}
        calls.clear(); g['_host'] = tb('x'); n3 = auto_merge('.', '7'); n3m = not merged()
        hok = process_gate('merge', {'mr': 'g/r!7', 'branch': 'ok/x'})
        shutil.rmtree(os.path.dirname(hk), ignore_errors=True)
        g['CFG']['process'] = {'gates': dict(LEGACY_GATES)}
        g['_pub_read'], g['TAG'], g['TRACKER_TYPE'] = pr0, tag0, tt0
        expect(f'process.gates unset: a task MR with no / "none" doc lines and a bug fix with no repro row merge, no body rewrite; a hook gate refuses with its stdout, exit 0 passes ({n1}, {n2}, {n3!r})',
               n1 == 'MERGED' and not n1u and n2 == 'MERGED' and merge_word(n3) == 'NOT_MERGED' and 'merge says no to g/r!7' in n3 and n3m and hok[0] and hok[2].endswith(f'"{hk}"'))
        calls.clear(); g['_host'] = fake(cfg=False)
        expect('no CI config: merged at once, not merge-when-green', merge_word(auto_merge('.', '7')) == 'MERGED' and merged() and not merged()[0]['auto'])
        repos0 = CFG.get('repos'); CFG['repos'] = [{'name': 'r', 'ci': {'mrPipelines': False}}]
        try:
            calls.clear(); g['_host'] = fake()
            expect('repos[].ci.mrPipelines false: no pipeline wait, merged at once', merge_word(auto_merge('.', '7', max_wait=0)) == 'MERGED'
                   and merged() and not merged()[0]['auto'] and not [v for v, _ in calls if v.startswith('ci.')])
        finally:
            CFG.pop('repos') if repos0 is None else CFG.update(repos=repos0)
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
    mrt = with_doc_lines(render_mr_body({'type': 'feat', 'change': 'x', 'summary': 'y', 'localEnv': 'none'}), '')[0] + '- Testing doc: https://d/1\n'
    expect('MR body: the rendered How tested is a table, all sections in order, a doc link the merge gate reads; a bullet list is flagged',
           _how_tested_table(mrt) and not _how_tested_table('## How tested\n- tests pass\n') and all(h in mrt for h in MR_SECTIONS) and doc_link_rx(docs()[0]).search(mrt))
    cfg0 = dict(CFG); CFG.clear(); CFG['gitHostType'] = 'github'
    expect('gitHostType, no gitHost: any origin', host_kind('git.corp.example') == 'github')
    expect('mr_word: PR on a GitHub host', mr_word('git.corp.example') == 'PR')
    CFG.clear(); expect('mr_word: GitLab MR, unknown host MR', (mr_word('gitlab.example.com'), mr_word('x.example')) == ('MR', 'MR')); CFG.update(cfg0)
    _process_selftest(expect, LEGACY_GATES)
    _report_selftest(expect)
    _publish_selftest(expect, refused)
    print(f'{fails} failure(s)')
    return 1 if fails else 0


def _process_selftest(expect, legacy):
    """process gates and tracker vocabulary: neutral (unset) vs today's legacy rows; one source of statuses; vendor branch ids."""
    g, cfg0 = globals(), json.loads(json.dumps(CFG))
    keep = {k: g[k] for k in ('TRACKER_TYPE', 'TAG', 'local_pass', '_pub_read')}
    try:
        g['local_pass'], g['_pub_read'] = (lambda t: (None, '')), (lambda k: {})
        CFG['process'] = {}
        p = {'task': 'T1', 'guide': None, 'ai': None, 't': {}, 'ts': {}}
        neutral = [process_gate(x, p)[0] for x in ('promote', 'merge', 'finish', 'bugFix', 'mrBody')]
        CFG['process'] = {'gates': dict(legacy)}
        strict = process_gate('finish', p)
        CFG['process'] = {'gates': dict(legacy), 'docs': []}
        nodocs = links_block('**Testing doc (human):** x\n\nbody', {'testing-doc': 'https://h'})
        CFG['process'] = {'gates': {'merge': 'builtin:noSuch'}}
        unknown = process_gate('merge', p)
        expect(f'process gates: unset = all five pass with no docs; legacy finish refuses without the AI doc; an unknown built-in refuses; '
               f'process.docs [] = no links block ({strict[1][:40]!r})', all(neutral) and not strict[0] and 'no AI testing doc' in strict[1]
               and nodocs == '**Testing doc (human):** x\n\nbody' and not unknown[0] and 'no such built-in' in unknown[1])
        one = lambda keys: [{'key': x, 'label': f'Doc {x}'} for x in keys]
        CFG['process'] = {'gates': dict(legacy), 'docs': one(['testing-doc'])}
        h1 = process_gate('finish', {**p, 'guide': 'https://h/g'})
        h0 = process_gate('finish', p)
        CFG['process'] = {'gates': dict(legacy), 'docs': one(['testing-ai'])}
        a1 = process_gate('finish', {**p, 'ai': 'https://h/a'})
        lb = links_block('body', {'testing-doc': 'https://h/g', 'testing-ai': 'https://h/a'})
        CFG['process'] = {'gates': dict(legacy), 'docs': []}
        n0 = process_gate('finish', p)
        expect('process.docs drives finish: one human doc needs no AI doc, one AI doc no guide, [] none; the local loop gate always holds;'
               ' the links block lists only configured docs',
               all('local test loop' in x[1] for x in (h1, a1, n0)) and 'no human testing doc' in h0[1]
               and lb == '**Doc testing-ai:** [open](https://h/a)\n\nbody')
        CFG['tracker'] = {'statuses': {'promoted': None, 'inTest': 'deployed'}}
        st = statuses()
        expect('statuses: one source (vocab.json) per key overridden; null = off ([]); a name = a list',
               st['promoted'] == [] and st['inTest'] == ['deployed'] and st['closed'] == ['closed', 'complete', 'done'])
        CFG['tracker'] = {}; g['TRACKER_TYPE'], g['TAG'] = 'jira', ''
        j = (task_of_branch('feature/SHOP-42-cart'), task_of_branch('feature/cart'), task_link())
        g['TRACKER_TYPE'] = 'azure'
        a = (task_of_branch('feature/1234-cart'), task_of_branch('AB#77 fix'))
        CFG['tracker'] = {'branchRx': r'(?<id>TCK\d+)'}
        c = task_of_branch('x/TCK9-y')
        expect(f'branch ids: jira from the vendor idPattern, azure branchRx, tracker.branchRx wins ({j}, {a}, {c})',
               j == ('SHOP-42', '', '/browse/') and a == ('1234', '77') and c == 'TCK9')
        CFG['tracker'] = {'commentTemplates': {'comment-status': '[{status}] {why}\n'}}
        expect('tracker.commentTemplates: a kind renders from its template; default unchanged',
               render_status({'status': 'blocked', 'why': 'x'}) == '[blocked] x\n' and render_solution({'solution': 's'}).startswith('**Solution:** s\n'))
        CFG['tracker'] = {'bugBranchRx': 'hotfix/', 'kindPrefixes': {'bug': '[Defect]'}}
        b = bug_fix_rx()
        expect('bug fix: tracker.bugBranchRx + the bug kind prefix', bool(b.search('hotfix/x')) and not b.search('fix/x') and bool(b.search('[Defect] y')))
        CFG['tracker'] = {'bugBranchPrefix': 'hotfix/'}
        b = bug_fix_rx()
        expect('bug fix: no bugBranchRx -> the brief prefix tracker.bugBranchPrefix or bugfix/', bool(b.search('hotfix/x')) and bool(b.search('bugfix/x')) and not b.search('fix/x'))
    finally:
        CFG.clear(); CFG.update(cfg0); g.update(keep)


def _publish_selftest(expect, refused):
    """publish by key, the local-loop gate, both doc shapes, a QA run filling the AI doc, the links block, finish, MR reuse,
    evidence folder reuse (markdown type, stubbed tracker and host)."""
    g, tmp = globals(), tempfile.mkdtemp()
    saved = {k: g[k] for k in ('REPORT_TYPE', 'kit_path', '_tracker', 'task', 'PROSE_OK', 'remote', '_run', '_host', 'CFG')}
    w = lambda p, t: open(p, 'w', encoding='utf-8').write(t) and p

    def kp(n, create=False):
        p = os.path.join(tmp, n); os.makedirs(p, exist_ok=True); return p
    try:
        g.update(REPORT_TYPE='markdown', kit_path=kp, PROSE_OK='selftest', CFG={**CFG, 'qa': {}})
        doc = ('# Testing: X\n## What changed\nThe list sorts by date.\n## Before you start / Feature switches\nSet first:\n| Setting | Where | Value |\n'
               '|---|---|---|\n| sort | Settings | on |\n## Checks\nList screen:\n| # | Steps | Expected | Result | Evidence |\n|---|---|---|---|---|\n'
               '| T1 | 1. Open the list. | Newest first. | | |\n'
               '## Out of scope\n| Item | Why |\n|---|---|\n| Email | qa.outOfScope |\n## Result (testers)\nAll pass -> close.\n')
        ait = '| # | Type | Steps / API call + payload | Expected | Result | Evidence |\n|---|---|---|---|---|---|\n'
        rt = 'Rounds:\n| Round | Date | Cases run | Result | Bugs found | Fix commit | Retest |\n|---|---|---|---|---|---|---|\n'
        aidoc = ('# Testing doc (AI): X\nCases:\n' + ait + '| A1 | positive | GET /list | 200, newest first | | |\n'
                 '| A2 | negative | GET /list as viewer | 403 | | |\n| A3 | edge | GET /list, no rows | 200, [] | | |\n'
                 + rt + '| 1 | 2026-10-29 | A1-A3 | 2 PASS, 1 FAIL | A3: 500 | abc123 | round 2 |\n')
        human, ai = w(os.path.join(tmp, 'h.md'), doc), w(os.path.join(tmp, 'a.md'), aidoc)
        tf = os.path.join(KIT, 'templates.md')
        if os.path.isfile(tf):   # a full kit (a test kit may copy scripts only)
            cs = {'title': 'X', 'checks': [{'id': 'T1', 'steps': 's', 'expected': 'e'}], 'cases': [{'id': 'A1', 'type': 'negative', 'steps': 's', 'expected': 'e'}]}
            ra, rh = render_cases(cs, 'ai'), render_cases(cs, 'human')
            expect('cases render: the AI doc has negative rows, its case and Rounds tables; the human doc positive checks only',
                   '| negative |' in ra and AI_TABLE.search(ra) and ROUNDS_TABLE.search(ra) and CHECKS_TABLE.search(rh) and 'negative' not in rh.lower())
            dv = 'https://drive.google.com/file/d/1Ab/view?usp=drivesdk'
            expect('cases evidence: links named by type (json, screenshot, log), never a URL segment such as "view"; an image URL inline',
                   _ev('A1', [f'A1_resp.json={dv}', f'A1_list.png={dv}', 'https://x/run.log', 'https://x/a.png', dv, 'curl 200', '[s](https://x/a?u=https://y/z)'])
                   == f'[json]({dv}) · [screenshot]({dv}) · [log](https://x/run.log) · ![A1](https://x/a.png) · [file]({dv}) · curl 200 · [s](https://x/a?u=https://y/z)')
            long_cell = doc.replace('Newest first.', ' '.join(['word'] * 30) + '.')
            expect('prose: a table doc passes (cell words, no table-syntax findings); a 30-word cell sentence is a finding',
                   not prose('testing-doc', doc) and any('30 words' in f for f in prose('testing-doc', long_cell)))
            if os.path.exists(os.path.join(KIT_DIR, 'skills/crafty/templates.md')):
                expect('prose: a missing kitbag.py path falls back in-process (4 Risks bullets still a finding; Links has its own cap 9)',
                       any('Risks: 4 bullets' in f for f in prose('mr-body', '## Risks\n' + '- x\n' * 4, tool=os.path.join(KIT_DIR, 'no-such-kitbag.py')))
                       and not any('Links' in f and 'bullets' in f for f in prose('mr-body', '## Links\n' + '- x\n' * 9)))
            with contextlib.redirect_stderr(io.StringIO()) as pg_err:
                g['PROSE_OK'] = ''; refused('prose_gate: the refusal names the kind\'s format and limits (mr-title)', lambda: prose_gate('mr-title', 'x' * 200), 'limits 1l 90ch'); g['PROSE_OK'] = 'selftest'
            expect('prose_gate: a refusal prints the rendered text it checked', 'mr-title as checked (1 words, 200 chars):\n' + 'x' * 200 in pg_err.getvalue())
        h = md_to_html(doc.replace('| | |\n', '| PASS | ![T1: list](https://img/1.png "900") |\n').replace('1. Open the list.', 'Run `tool check -Step test -Tests ALongClassNameSmokeTest`')
                       + '```\n{"a": 1}\n```\n')
        th = re.findall(r'<th style="([^"]*)"><b>([^<]*)</b></th>', h)
        expect('md_to_html (the gdocs upload): tables stay HTML tables, header bold + shaded, widths by role (# 5, Steps 40, Expected 25,'
               ' Result 10, Evidence 20), cells padded and top-aligned, images inline and fit to the cell (human Evidence 112 px)',
               [(n, re.search(r'width:([\d.]+)%', s)[1]) for s, n in th[3:8]] == [('#', '5.0'), ('Steps', '40.0'), ('Expected', '25.0'), ('Result', '10.0'), ('Evidence', '20.0')]
               and all(HEAD_CSS in s for s, _ in th) and re.search(rf'<td data-l="[^"]*" style="{CELL_CSS}"><p><img src="https://img/1.png" width="112"', h) and '| T1 |' not in h)
        d1, d2 = 'https://drive.google.com/uc?export=view&id=1Ab-C', 'https://drive.google.com/uc?export=view&id=2De_F'
        ha = md_to_html(ait.split('\n')[0] + '\n|---|---|---|---|---|---|\n' + f'| A1 | positive | GET /x | 200 | PASS | ![A1: list]({d1} "600")<br>![A1: zoom]({d2}) |\n')
        hq = md_to_html(f'| Check | Result | Observed | Evidence |\n|---|---|---|---|\n| T1 | PASS | ok | ![T1: phone]({d1} "260") |\n')
        imgs = re.findall(r'<img src="([^"]+)" width="(\d+)"><br><i>([^<]*)</i><br><a href="([^"]+)"[^>]*>open full</a>', ha)
        expect('md_to_html: a cell image fits its column (AI Evidence 100 px, QA report 118 px, a smaller asked width kept, outside a table'
               ' 600), images stack in one cell, each with an "open full" link to its Drive /file/d/<id>/view',
               [(w, c, l) for _, w, c, l in imgs] == [('100', 'A1: list', 'https://drive.google.com/file/d/1Ab-C/view'), ('100', 'A1: zoom', 'https://drive.google.com/file/d/2De_F/view')]
               and 'width="118"' in hq and 'width="40"' in md_to_html('| a | b |\n|---|---|\n| x | ![s](https://x/s.png "40") |\n')
               and 'width="600"' in md_to_html(f'![s]({d1})') and 'open full' not in md_to_html(f'![s]({d1})')
               and full_link('https://x/s.png') == 'https://x/s.png' and full_link('https://drive.google.com/file/d/9Z/view?usp=x') == 'https://drive.google.com/file/d/9Z/view')
        expect('md_to_html: backtick spans and fenced blocks are monospace on grey; text outside them stays plain; an unknown table'
               ' gets no widths, an AI table sums to 100',
               f'Run <span style="{CODE_CSS}">tool check -Step test -Tests ALongClassNameSmokeTest</span>' in h and f'<pre style="{CODE_CSS}">{{&quot;a&quot;: 1}}</pre>' in h
               and h.count(CODE_CSS) == 2 and f'<span style="{CODE_CSS}">src/**/a/**</span>' in md_to_html('`src/**/a/**`') and col_widths(['Name', 'Owner']) is None and round(sum(col_widths(_cells(ait.split('\n')[0]))), 1) == 100.0)
        refused('testing-doc: local screenshots or results in the human doc -> refused', lambda: publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'hi.md'), doc.replace('| | |\n', '| PASS | |\n'))), 'evidence or results')
        goals = w(os.path.join(tmp, 'g.md'), '# Testing goals: T9 X\n## Goals (what must be true)\n| G1 |\n')
        refused('testing-doc: no "| # | Steps | Expected | Result | Evidence |" table -> refused', lambda: publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'h0.md'), '# Testing: X\n## Checks\n### T1 — s\n')), 'no case table')
        refused('testing-doc: a negative row -> refused (human = positive cases)', lambda: publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'hn.md'), doc.replace('| T1 |', '| T1 | negative |'))), 'negative row')
        refused('testing-ai: no negative row -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'a0.md'), aidoc.replace('negative', 'positive'))), 'no negative row')
        row = lambda i, s, r, e='[j](https://j)': f'| {i} | positive | {s} | ok | {r} | {e} |\n'
        cg = lambda rows, hm=None, tm='': case_gaps('# AI\n' + ait + ''.join(rows), hm, tm)
        refused('testing-ai: a non-FAIL row waived as pre-existing -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'ap.md'), aidoc.replace('| A3 | edge | GET /list, no rows | 200, [] | | |', '| A3 | edge | GET /list, no rows | 200, [] | PASS (pre-existing overlap) | [j](https://j) |'))), 'waive a failure as pre-existing')
        expect('case_gaps: "pre-existing records" and a FAIL row naming a pre-existing bug are no waiver',
               not cg([row('A1', 's', 'PASS', 'pre-existing records kept [j](https://j)'), row('A2', 's', 'FAIL pre-existing bug'), row('A3', 's', 'PASS: pre-existing tenant kept')]))
        g['CFG'] = {**CFG, 'qa': {'notLocal': [{'name': 'help service', 'match': r'/help\b'}], 'matrix': {'viewports': ['1280x720', '1920x1080'], 'fontScales': [2]}}}
        expect('case_gaps: a qa.notLocal PASS -> NOT_TESTED_LOCAL; UI evidence needs each qa.matrix value on a "Matrix:" line',
               [x.split(' ')[1] for x in cg([row('A1', 'GET /help', 'PASS'), row('A2', 'GET /help', 'NOT_TESTED_LOCAL: stub'), row('A3', 's', 'PASS', '![a](https://i/a.png)'), 'Matrix: 1280x720, 2\n'])]
               == ['A1', 'cases'] and all(x in cg([row('A3', 's', 'PASS', '![a](https://i/a.png)')])[0] for x in ('1920x1080', 'case(s) A3', '"Matrix: 1280x720, 1920x1080, f2"')) and not cg([row('A3', 's', 'PASS', '![a](https://i/a.png)'), 'Matrix: 1280x720, 1920x1080, 2\n']))
        g['CFG'] = {**CFG, 'qa': {}}
        hm2 = doc.replace('| T1 | 1. Open the list. | Newest first. | | |\n', '| T1 | 1. Open the list. | Newest first. | | |\n| T2 | 2. Sort. | Oldest first. | | |\n')
        expect('case_gaps: each human check needs an AI row that ran it; a NOT_TESTED_LOCAL row a human check',
               [x.split(' ')[:3] for x in cg([row('A1 (T1)', 's', 'PASS'), row('A2', 's', 'NOT_TESTED_LOCAL')], hm2)] == [['human', 'check(s)', 'T2'], ['row(s)', 'A2', 'are']]
               and not cg([row('A1 (T1)', 's', 'PASS'), row('A2 (T2)', 's', '**NOT_TESTED_LOCAL**')], hm2))
        q = 'The icon must be very prominent; help answers in under 10 s.'
        expect('case_gaps: a stated quality ("prominent", "under 10 s") needs a case measuring it with a threshold',
               "'10', 'prominent'" in cg([row('A1', 'icon is prominent', 'PASS')], None, q)[0]
               and not cg([row('Q1', 'icon contrast (prominent): ratio >= 3', 'PASS'), row('Q2', 'help p95 of 5 runs <= 10 s', 'PASS')], None, q))
        expect('case_gaps: no quality in "quick fix, slow query log, in contrast, responsive layout"; "must load faster" -> "fast"',
               not cg([], None, 'A quick fix of the slow query log, in contrast to v1, for a responsive layout bug.')
               and "'fast'" in cg([], None, 'The list must load faster.')[0] and not cg([row('Q1', 'fast: p95 <= 2 s', 'PASS')], None, 'The list must load faster.'))
        g['CFG'] = {**CFG, 'qa': {'matrix': {'viewports': ['1280x720', '1920x1080'], 'fontScales': [2], 'themes': ['High contrast']}}}
        expect('case_gaps: the "Matrix:" line may list matrix() tags (1280x720_f2_high-contrast)',
               not cg([row('A3', 's', 'PASS', '![a](https://i/a.png)'), 'Matrix: 1280x720_f2_high-contrast, 1920x1080_f2_high-contrast\n']))
        mxs = w(os.path.join(tmp, 'mx.json'), json.dumps({'title': 'm', 'cases': [{'id': 'A1', 'type': 'positive', 'steps': 's', 'expected': 'e', 'result': 'PASS',
                'evidence': ['s.png=https://i/s.png']}, {'id': 'A2', 'type': 'negative', 'steps': 's', 'expected': 'e'}]}))
        with contextlib.redirect_stderr(io.StringIO()) as fe, contextlib.redirect_stdout(io.StringIO()):
            cases_cmd(['add', 'T78', mxs])
        task_index('T78', lambda x: x.pop('cases', None))
        expect('cases add: a UI case without each qa.matrix value warns at once, not first at finish', 'WARN cases T78: UI cases miss qa.matrix value(s) 1280x720' in fe.getvalue())
        c80 = lambda e: w(os.path.join(tmp, 'c80.json'), json.dumps({'title': 'd', 'cases': [{'id': 'A1', 'type': 'negative', 'steps': 's', 'expected': e}]}))
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            cases_cmd(['add', 'T80', c80('e1')]); cases_cmd(['add', 'T80', c80('e1')])   # the same file again: no change, no refusal
            refused('cases add: an existing id with other values is refused without --replace', lambda: cases_cmd(['add', 'T80', c80('e2')]), 'cases A1 exist(s) with other values')
            cases_cmd(['add', 'T80', c80('e3'), '--replace'])
        expect('cases add --replace changes an existing case', (state_read(task_file('T80')) or {})['cases']['cases'][0]['expected'] == 'e3')
        task_index('T80', lambda x: x.pop('cases', None))
        sc = {'type': 'fix', 'change': 'c', 'summary': 's', 'changes': ['bare text', {'text': 't2'}], 'risks': 'one risk'}
        expect('render commit / mr-body: a bare string change or risk is its text (no AttributeError); a non-object item is a gap',
               not spec_gaps(sc, 'commit') and '- bare text' in render_commit(sc) and '- one risk' in render_mr_body(sc) and spec_gaps({**sc, 'changes': [3]}, 'commit') == ['changes[0].text']
               and re.search(r'(?m)^- \*\*Sibling .*none · \*\*Spec S-ids:\*\* S1$', render_mr_body({**sc, 'specIds': ['S1']})))   # one Links bullet
        expect('spec_migrate: a bug keeps its Impact section; a feature\'s legacy impact still maps to design.modules',
               spec_migrate({'kind': 'bug', 'impact': {'who': 'drivers'}})['impact'] == {'who': 'drivers'} and spec_migrate({'kind': 'feature', 'impact': ['m1']})['design'] == {'modules': ['m1']})
        ev1, ev2 = w(os.path.join(tmp, 'ev.json'), json.dumps({'request': {'body': {'login': 'qa', 'newPassword': 'Pw-1234567'}}, 'mail': 'a@b.example'})), w(os.path.join(tmp, 'ev.txt'), 'password=Pw-1234567&x=1')
        with contextlib.redirect_stderr(io.StringIO()):
            redact_files([ev1, ev2, os.path.join(tmp, 'none.json')])
        expect('evidence upload: secret JSON keys and password=... text are redacted in place, other values (an email) stay',
               json.loads(open(ev1, encoding='utf-8').read()) == {'request': {'body': {'login': 'qa', 'newPassword': '[redacted]'}}, 'mail': 'a@b.example'} and 'Pw-1234567' not in open(ev2, encoding='utf-8').read())
        with contextlib.redirect_stderr(io.StringIO()) as fe:
            refused('doc --key: the first publish of a task doc needs a fresh prior', lambda: doc_prior('T79:testing-ai'), 'run crafty.ps1 prior -Task T79')
            _pub_update('T79:testing-ai', url='https://x/d79'); doc_prior('T79:testing-ai')
        expect('doc --key: the task\'s own published doc updates in place (no prior gate)', 'updates its published doc in place' in fe.getvalue())
        g['CFG'] = {**CFG, 'qa': {'notLocal': [{'name': 'help service', 'match': r'/help\b'}], 'matrix': {'viewports': ['1280x720']}}}
        legacy = ('# AI\n' + ait + row('L1', 'GET /help', 'PASS', '`test_help`') + '| L2 | negative | s | ok | PASS | ![a](https://i/a.png) |\n'
                  + rt + '| 1 | 2026-11-01 | L1-L2 | 2 PASS | | | |\n')
        _pub_write('TS:testing-ai', {'key': 'TS:testing-ai', 'title': 'X', 'rounds': [{'at': '2026-11-01 10:00', 'seq': 1.0, 'label': '', 'ext': '.md', 'body': legacy}], 'runs': []})
        mine = lambda r: w(os.path.join(tmp, 'sh.md'), legacy.replace('Rounds:', r + 'Rounds:').replace('| 2 PASS | | | |\n', '| 2 PASS | | | |\n| 2 | 2026-11-05 | P1 | 1 PASS | | | |\n'))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            ok = publish('TS:testing-ai', 'X', mine(row('P1', 'GET /list', 'PASS')))
        expect('testing-ai: a shared doc whose earlier rows (any agent) lack evidence, PASS on qa.notLocal or miss qa.matrix accepts a'
               ' new compliant round; earlier rows only WARN', ok and 'WARN TS:testing-ai: 1 earlier row(s) lack an Evidence link (L1)' in err.getvalue()
               and 'PASS on help service' in err.getvalue() and 'qa.matrix' in err.getvalue())
        refused('testing-ai: a new row without an Evidence link on a shared doc -> refused', lambda: publish('TS:testing-ai', 'X', mine(row('P2', 'GET /x', 'PASS', 'test_x'))), 'P2 have a Result but no Evidence link')
        refused('testing-ai: a new qa.notLocal PASS on a shared doc -> refused', lambda: publish('TS:testing-ai', 'X', mine(row('P3', 'GET /help', 'PASS'))), 'row(s) P3 PASS on help service')
        hm3 = doc.replace('| T1 | 1. Open the list. | Newest first. | | |\n', '| T1 | 1. Open the list. | Newest first. | | |\n| T2 | 2. Sort. | Oldest first. | | |\n')
        with contextlib.redirect_stderr(io.StringIO()):
            hg = [case_gaps('# AI\n' + ait + row('P1 (T2)', 's', 'PASS'), hm, '', (), 'x', [doc]) for hm in (hm3, hm3.replace('| T2 | 2. Sort.', '| T2 | 2. Sort first.'))]
        expect('case_gaps: an earlier human check (another agent\'s, T1) no AI row ran only WARNs; a new or changed one no row ran fails',
               not hg[0] and not hg[1] and case_gaps('# AI\n' + ait + row('P1', 's', 'PASS'), hm3, '', (), 'x', [doc])[0].startswith('human check(s) T2 have'))
        expect('case_gaps: a new human check another wave agent owns (skip) = WAIT, no gap',
               not [g for g in case_gaps('# AI\n' + ait + row('P1', 's', 'PASS'), hm3, '', (), 'x', [doc], skip={'T2'}) if 'T2' in g])
        refused('testing-ai: a new UI row missing qa.matrix on a shared doc -> refused',lambda: publish('TS:testing-ai', 'X', mine(row('P4', 's', 'PASS', '![b](https://i/b.png)'))), 'UI cases miss qa.matrix')
        g['CFG'] = {**CFG, 'qa': {}}
        os.makedirs(os.path.join(kp('agents'), 'd1'))
        loop = lambda ev: w(os.path.join(kp('agents'), 'd1', 'resume.json'), json.dumps({'steps': [{'step': 'loop', 'item': 'T9', 'evidence': ev, 'at': '2026-10-29T10:00:00'}]}))
        refused('testing-doc: refused without a local loop PASS', lambda: publish('T9:testing-doc', 'X', human), 'not recorded')
        loop('round 1 FAIL G2')
        refused('testing-doc: refused while the loop is FAIL', lambda: publish('T9:testing-doc', 'X', human), 'round 1 FAIL')
        ua = publish('T9:testing-ai', 'X', ai, label='loop round 1')
        expect('testing-ai: the loop record publishes during the loop (no PASS needed)', bool(ua))
        loop('round 2 PASS')
        refused('goals.md is never published (human or AI key)', lambda: publish('T9:testing-ai', 'X', goals), 'never published')
        u1 = publish('T9:testing-doc', 'X', human)
        u2 = publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'h2.md'), doc.replace('| T1 |', '| T2 |')))
        publish('T9:testing-doc', 'X', os.path.join(tmp, 'h2.md'))
        body = open(u2, encoding='utf-8').read()
        expect('human doc round 2: same doc, newest on top, the untested round 1 only a "Replaced drafts (not tested)" date; an identical republish adds no round',
               u1 == u2 and body.index('| T2 |') < body.index(f'Replaced drafts (not tested): {time.strftime("%Y-%m-%d")}') and '| T1 |' not in body
               and '## Round' not in body and len(_pub_read('T9:testing-doc')['rounds']) == 2 and _pub_read('T9:testing-doc')['url'] == u1)
        ix = state_read(os.path.join(kp('tasks'), 'T9.json')) or {}
        expect('publish by key: the task index points at the doc (docs.testing-doc, schemaVersion 1)', ix.get('docs', {}).get('testing-doc', {}).get('url') == u1 and ix.get('schemaVersion') == 1)
        refused('testing-ai: no Rounds table -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'a1.md'), aidoc.split('Rounds:')[0])), 'no Rounds table')
        refused('testing-ai: a round that drops an earlier Rounds row -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'a3.md'), aidoc.replace('| 1 | 2026-10-29', '| 2 | 2026-10-30'))), 'dropped Rounds row(s) 1')
        a2 = aidoc.replace('| A1 | positive | GET /list | 200, newest first | |', '| A1 (T1) | positive | GET /list | 200, newest first | PASS | [json](https://d/a1)') + '| 2 | 2026-10-30 | A1-A3 | 3 PASS | none | def456 | A3 PASS |\n'
        for ev in ('test_router.py "help patterns are narrow"', 'same'):
            refused(f'testing-ai: a PASS row whose Evidence is {ev!r} (no link, no inline image) -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'ab.md'), a2.replace('[json](https://d/a1)', ev))), 'A1 (T1) have a Result but no Evidence link')
        a2p = w(os.path.join(tmp, 'a2.md'), a2); ua2 = publish('T9:testing-ai', 'X', a2p, label='loop round 2', mode='replace')
        ab = open(ua2, encoding='utf-8').read()
        expect('testing-ai: round 2 updates the same doc, round 1 kept whole below (its rows, its Rounds row); --mode replace ignored',
               ua2 == ua and ab.index('| 2 | 2026-10-30') < ab.index('## Round 1') < ab.rindex('| A1 | positive | GET /list | 200, newest first | | |') and ab.count('| 1 | 2026-10-29') == 2)
        rep = w(os.path.join(tmp, 'r.md'), '# QA\n## Results\n| Check | Result | Observed | Evidence |\n|---|---|---|---|\n| T2 | PASS | ok | |\n')
        expect('the human doc starts with Result / Evidence empty', _table_rows(open(u2, encoding='utf-8').read())[0][0] == ('T2', '', ''))
        pt = _table_rows('| # | Steps | Result | Evidence |\n|---|---|---|---|\n| A1 | a \\| b | PASS | |', {'A1': {'result': 'PASS', 'evidence': 'x|y'}})
        expect('a \\| in a cell: the row is still read, a filled x|y too, the HTML shows |', pt[0] == [('A1', 'PASS', '')] and _table_rows(pt[1])[0] == [('A1', 'PASS', 'x\\|y')] and 'a | b</td>' in md_to_html(pt[1]))
        nh = '| ' + ' | '.join(HUMAN_HEAD) + ' |\n|---|---|---|---|---|---|\n| T1 | Click Save | Saved shown | | | |'
        nf = _table_rows(nh, {'T1': {'result': 'PASS', 'evidence': '![T1: saved](https://img/t1.png)<br>`POST -> 200` [Resp](https://f/t1)'}})
        expect('human doc (UI form): a run fills Screenshot with the images, Extra evidence with the rest; rows read back',
               nf[1].endswith('| T1 | Click Save | Saved shown | ![T1: saved](https://img/t1.png) | `POST -> 200` [Resp](https://f/t1) | PASS |')
               and _table_rows(nf[1])[0] == [('T1', 'PASS', '![T1: saved](https://img/t1.png) `POST -> 200` [Resp](https://f/t1)')] and CHECKS_TABLE.search(nh)
               and col_widths(HUMAN_HEAD) and 0 not in col_widths(HUMAN_HEAD) and col_widths(HUMAN_HEAD)[3] >= 25)
        nm = _table_rows(nh, {'T1': {'result': 'PASS (V1, V2)', 'evidence': '**V1** PASS: ![V1: a](https://img/a.png)<br>**V2** PASS: ![V2: b](https://img/b.png) [Resp](https://f/v2)'}})[1]
        expect('human doc (UI form): checks sharing a row keep their labels in Screenshot; Extra evidence holds no bare label',
               '| **V1** PASS: ![V1: a](https://img/a.png)<br>**V2** PASS: ![V2: b](https://img/b.png) | **V2** PASS: [Resp](https://f/v2) |' in nm)
        expect('API_WORDS: endpoint calls and API tools caught; screen wording (a DELETE / ARCHIVE button, a page showing HTTP 404, a webhook endpoint field, Send request) passes',
               all(API_WORDS.search(x) for x in ('GET /orders', 'Send a POST request', 'call the API', 'curl -X', 'open /api/x', 'in Postman'))
               and not any(API_WORDS.search(x) for x in ('Click DELETE / ARCHIVE', 'Page shows HTTP 404', 'Enter the webhook endpoint URL', 'Click Send request')))
        refused('testing-doc: a row naming an endpoint -> refused (human checks run from the UI)', lambda: publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'hapi.md'),
                doc.replace('1. Open the list.', 'POST /api/list with a payload'))), 'API call or endpoint')
        expect('cases spec: a human check naming an endpoint is a gap; a UI one with noUi is not',
               any('API call' in x for x in cases_gaps({'title': 'x', 'checks': [{'id': 'T1', 'steps': 'GET /orders', 'expected': '200'}]}))
               and not cases_gaps({'title': 'x', 'checks': [{'id': 'T1', 'steps': 'Open Job history', 'expected': 'a run at 02:00', 'noUi': 'nightly job'}]})
               and '**No UI trigger** (nightly job): Open Job history' in render_cases({'title': 'x', 'checks': [{'id': 'T1', 'steps': 'Open Job history', 'expected': 'e', 'noUi': 'nightly job'}]}, 'human'))
        cg0 = dict(CFG); CFG.update(process={'humanDocUiOnly': False, 'docs': [{'key': 'testing-doc', 'label': 'Human testing doc', 'columns': ['#', 'Steps', 'Expected', 'Result', 'Evidence']}]})
        try:
            hd = render_cases({'title': 'x', 'checks': [{'id': 'T1', 'steps': 'GET /orders', 'expected': '200'}]}, 'human')
            expect('process.docs[].columns + humanDocUiOnly false: the human table uses the columns, an API step is no gap',
                   '| # | Steps | Expected | Result | Evidence |' in hd and '| T1 | GET /orders | 200 |  |  |' in hd and not cases_gaps({'title': 'x', 'checks': [{'id': 'T1', 'steps': 'GET /orders', 'expected': '200'}]}))
        finally:
            CFG.clear(); CFG.update(cg0)
        ur = publish('T9:testing-doc', 'X', rep, label='stg', run={'T2': {'result': 'PASS', 'evidence': '![T2: list](https://img/s2.png)'}})
        hb = open(ur, encoding='utf-8').read()
        expect('env run: the human doc (same link) gets Result / Evidence from the deployed run and a dated "<env> run" section; no report doc',
               ur == u1 and '| T2 | 1. Open the list. | Newest first. | PASS | ![T2: list](https://img/s2.png) |' in hb
               and hb.index('| T2 |') < hb.index('Replaced drafts') < hb.index('## stg run ') and '## Round' not in hb and not _pub_read('T9:qa-report'))
        ur2 = publish('T9:testing-doc', 'X', rep, label='stg', run={'T2': {'result': 'FAIL', 'evidence': 'x'}})
        hb2 = open(ur2, encoding='utf-8').read()
        expect('a retest run adds a second "<env> run" section; the first stays; its FAIL decides the row, the earlier PASS named',
               ur2 == u1 and hb2.count('## stg run ') == 2 and '| T2 | 1. Open the list. | Newest first. | FAIL (stg T2) · stg: pass (T2) | **stg** ![T2: list](https://img/s2.png)<br>**stg** x |' in hb2)
        before = _pub_read('T9:testing-doc')
        expect('relayout: the same doc and text again, no new round or run; an unpublished key is refused',
               relayout('T9:testing-doc') == u1 and open(u1, encoding='utf-8').read() == hb2 and len(_pub_read('T9:testing-doc')['rounds']) == len(before['rounds'])
               and len(_pub_read('T9:testing-doc')['runs']) == len(before['runs']))
        refused('relayout: an unpublished key -> refused', lambda: relayout('T0:testing-doc'), 'no published record')
        refused('relayout: a link no record holds -> refused', lambda: relayout('https://docs.google.com/document/d/NOPE/edit'), 'no published record holds this link')
        u3 = publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'h3.md'), doc.replace('| T1 |', '| T3 |')), label='fix round')
        hb3 = open(u3, encoding='utf-8').read()
        expect('a fix round after a run: a fresh version on top, both runs, the tested round 2 whole; the untested round 1 stays a date',
               u3 == u1 and '| T3 | 1. Open the list. | Newest first. | | |' in hb3 and hb3.count('## stg run ') == 2 and hb3.index('| T3 |') < hb3.index('## stg run ')
               < hb3.index('## Round 2') and '## Round 1' not in hb3 and hb3.count('Replaced drafts (not tested)') == 1)
        vr = {'V1': {'result': 'PASS', 'evidence': '![V1: list](https://img/v1.png)', 'screen': 'T3 list'}, 'V2': {'result': 'PASS', 'evidence': '`GET /l -> 200` [l](https://f/l)', 'case': 'T3'},
              'A1': {'result': 'OUT OF SCOPE', 'evidence': '', 'screen': 'App only'}}
        with contextlib.redirect_stderr(io.StringIO()):
            publish('T9:testing-doc', 'X', rep, label='stg', run=vr, run_id='R1-Q1')
            u4 = publish('T9:testing-doc', 'X', rep, label='stg', run=dict(vr, V2=dict(vr['V2'], result='FAIL')), run_id='R1-Q1')
        hb4 = open(u4, encoding='utf-8').read()
        expect('markdown: run checks V1 (screen "T3 ...") + V2 (case T3) fill row T3 (FAIL > PASS, ids named, each evidence); the same --run-id replaces its section',
               u4 == u1 and '| T3 | 1. Open the list. | Newest first. | FAIL (V1, V2) | **V1** PASS: ![V1: list](https://img/v1.png)<br>**V2** FAIL: `GET /l -> 200` [l](https://f/l) |' in hb4
               and hb4.count('## stg run ') == 3)
        with contextlib.redirect_stderr(io.StringIO()):
            hb5 = open(publish('T9:testing-doc', 'X', rep, label='local', run={'L1': {'result': 'PASS', 'evidence': 'x', 'screen': 'App only'}}, run_id='R2-Q1'), encoding='utf-8').read()
        expect('a later run that covers other rows (a local run of the app part) keeps each row from the newest run covering it; both sections kept',
               '| FAIL (V1, V2) |' in hb5 and hb5.count('## stg run ') == 3 and hb5.count('## local run ') == 1)
        with contextlib.redirect_stderr(io.StringIO()):
            publish('T9:testing-doc', 'X', rep, label='stg', run=vr, run_id='R1-Q1')
            hb6 = open(publish('T9:testing-doc', 'X', rep, label='local', run={'T3': {'result': 'NOT TESTED', 'evidence': '', 'why': 'PO field read-only'}}, run_id='R3-Q1'), encoding='utf-8').read()
        expect('a later NOT TESTED never replaces an earlier PASS: both envs named, the why kept, each evidence by env; all sections kept',
               '| PASS (stg V1, V2) · local: not tested (T3) — PO field read-only | **stg** **V1** PASS' in hb6 and '<br>**local** PO field read-only |' in hb6
               and hb6.count('## stg run ') == 3 and hb6.count('## local run ') == 2)
        rt = '| # | Steps | Result | Evidence |\n|---|---|---|---|\n| T1 | a | | |\n'
        rc = lambda *rs: _runs_cells(rt, [{'label': e, 'cells': c} for e, c in rs])['T1']['result']
        expect('_runs_cells: a later FAIL overrides a PASS (env named); a later PASS after a FAIL decides; PASS on two envs joins them; one run as is',
               rc(('stg', {'T1': {'result': 'PASS'}}), ('local', {'A1': {'result': 'FAIL', 'case': 'T1'}})) == 'FAIL (local A1) · stg: pass (T1)'
               and rc(('stg', {'T1': {'result': 'FAIL'}}), ('stg', {'T1': {'result': 'PASS'}}), ('local', {'T1': {'result': 'PENDING'}})) == 'PASS (stg T1) · stg: fail (T1) · local: pending (T1)'
               and rc(('stg', {'V1': {'result': 'PASS', 'case': 'T1'}, 'V2': {'result': 'PASS', 'case': 'T1'}}), ('local', {'A1': {'result': 'PASS', 'case': 'T1'}})) == 'PASS (stg V1, V2 + local A1)'
               and rc(('stg', {'T1': {'result': 'PASS'}})) == 'PASS'
               and rc(('stg', {'T1': {'result': 'NOT TESTED', 'why': 'x'}}), ('local', {'T1': {'result': 'NOT TESTED', 'why': 'y'}})) == 'NOT TESTED · stg: not tested (T1) — x · local: not tested (T1) — y')
        expect('_table_rows: a multi-line cell (a why with a newline) stays one row', _table_rows(rt, {'T1': {'result': 'NOT TESTED', 'evidence': 'a\nb'}})[1].endswith('| T1 | a | NOT TESTED | a b |\n'))
        expect('run_gaps: a row an earlier published run covers is no gap (a run of the app part needs no NOT TESTED filler)',
               run_gaps(rt, {'A1': {'result': 'PASS', 'screen': 'App only'}}) == ['T1'] and not run_gaps(rt, {'A1': {'result': 'PASS', 'screen': 'App only'}}, [{'label': 'stg', 'cells': {'T1': {'result': 'PASS'}}}]))
        expect('_row_cells: a row\'s own check next to a FAIL variant reads FAIL (ids in natural order); an unknown result never reads PASS',
               _row_cells(rt, {'V10': {'result': 'PASS', 'case': 'T1'}, 'V2': {'result': 'FAIL', 'case': 'T1'}, 'T1': {'result': 'PASS'}})['T1']['result'] == 'FAIL (T1, V2, V10)'
               and _row_cells(rt, {'V1': {'result': '', 'case': 'T1'}, 'V2': {'result': 'PASS', 'case': 'T1'}})['T1']['result'] == 'NOT TESTED (V1, V2)')
        expect('run_gaps: a row no check covers (id, case or screen) is named; a covered one is not',
               run_gaps(open(os.path.join(tmp, 'h3.md'), encoding='utf-8').read(), {'A1': {'result': 'PASS', 'screen': 'App only'}}) == ['T3'] and not run_gaps(open(os.path.join(tmp, 'h3.md'), encoding='utf-8').read(), vr))
        nr = publish('T7:testing-doc', 'X', rep, run={})
        expect('a run without a human doc: the report is published by <task>:qa-report', _pub_read('T7:qa-report').get('url') == nr)
        legacy = ''.join(f'Testing doc: [https://d/{i}](https://d/{i})\n\n' for i in range(7)) + 'Testing goals (AI): x\nThe ask.\n'
        expect('links block: 7 legacy lines -> one human + one AI line, the rest kept',
               links_block(legacy, 'https://h', 'https://a') == '**Testing doc (human):** [open](https://h)\n\n**Testing doc (AI):** [open](https://a)\n\nThe ask.\n'
               and links_block(links_block(legacy, 'https://h', 'https://a'), 'https://h', 'https://a').count('Testing doc') == 2)
        calls, st = [], {'s': 'in progress', 'd': 'Testing doc: https://old\n\nThe ask.'}
        g['_tracker'] = lambda *a: calls.append(a) or (a[0] == 'describe' and st.update(d=a[2])) or ''
        g['task'] = lambda t: {'id': t, 'name': 'n', 'status': st['s'], 'description': st['d']}
        refused('finish: no AI doc -> refused, nothing written', lambda: finish('T8', human, '**Solution** — x'), 'no AI testing doc')
        refused('finish: a human check no AI row ran -> refused', lambda: finish('T9', w(os.path.join(tmp, 'h4.md'), hm2), '**Solution** — x', ai=a2p), 'T2 have no AI row')
        refused('finish: the refusal names the AI row and the doc command per check', lambda: finish('T9', w(os.path.join(tmp, 'h4.md'), hm2), '**Solution** — x', ai=a2p),
                'devtools.py cases add T9 with case(s) {"id": "A<n>", "type": "positive", "check": "T2", ...}, cases result once run, then devtools.py doc "<title>" cases --key T9:testing-ai')
        a5 = w(os.path.join(tmp, 'a5.md'), a2.replace('| A3 | edge | GET /list, no rows | 200, [] | | |', '| A3 | edge | GET /list, no rows | 200, [] | NOT_TESTED_LOCAL | |'))
        with contextlib.redirect_stderr(io.StringIO()):
            publish('T5:testing-ai', 'X', a5)
        refused('finish: the newest published AI round (the caller\'s) is judged: its NOT_TESTED_LOCAL row no human check carries -> refused',
                lambda: finish('T5', human, '**Solution** — x', ai=a5), 'A3 are NOT_TESTED_LOCAL')
        expect('finish refused before any tracker write', not calls)
        finish('T9', human, '**Solution** — x\n**MRs**: a · **Testing doc**: <link>', ai=a2p)
        expect('finish with the last loop round\'s AI doc adds no second round', open(ua, encoding='utf-8').read().count('## Round ') == 1)
        refused('finish: a URL other than the doc the key has -> refused (pass the file)', lambda: finish('T9', human, '**Solution** — x', ai='https://other/doc'), 'already is')
        d = next(a[2] for a in calls if a[0] == 'describe'); c = next(a for a in calls if a[0] == 'comment')
        expect('finish: links block (human + AI) on top, solution comment of kind comment-solution without doc links, status review',
               d.startswith(f'**Testing doc (human):** {u1}\n\n**Testing doc (AI):** {ua}\n') and 'https://old' not in d and c[3:5] == ('-Kind', 'comment-solution')
               and u1 not in c[2] and 'Testing doc' not in c[2] and '**MRs**: a' in c[2] and calls[-1] == ('status', 'T9', 'review'))
        all_c = [a[2] for a in calls if a[0] == 'comment']; calls.clear(); st['s'] = 'promoted'
        finish('T9', human, '**Solution** — x\n**Testing doc**: <link>\n**Testing doc (AI)**: <ai>', ai=a2p)
        all_c += [a[2] for a in calls if a[0] == 'comment']
        expect('finish on a promoted task: docs and comment, status never moved back', not [a for a in calls if a[0] == 'status'] and [a for a in calls if a[0] == 'comment'])
        g0, st['s'] = g['_tracker'], 'in progress'
        def _skip(*a):   # a parent with open subtasks: crafty.ps1 tracker status exits 1 with SKIPPED
            if a[0] == 'status':
                raise SystemExit('failed (exit 1): tracker status T9\ntracker: SKIPPED: T9 not set to review: it follows its 2 open subtask(s)')
            return g0(*a)
        g['_tracker'] = _skip
        with contextlib.redirect_stderr(io.StringIO()) as fe:
            finish('T9', human, '**Solution** — x', ai=a2p)
        g['_tracker'] = g0
        expect('finish on a parent with open subtasks: status kept (it follows them), no failure', 'status kept: T9 not set to review' in fe.getvalue())
        expect('no_doc_links: prose and other fields kept, a links-only text empty',
               no_doc_links('Fixed the Testing goals: now 5 rows pass.\nDone') == 'Fixed the Testing goals: now 5 rows pass.\nDone\n'
               and no_doc_links('**MRs**: a · **Testing doc**: https://d · **After deploy**: seed') == '**MRs**: a · **After deploy**: seed\n'
               and no_doc_links('**Testing doc**: x · **After deploy**: y') == '**After deploy**: y\n' and no_doc_links('Testing doc (human): https://x') == '')
        expect('finish twice: no comment holds a doc link; the description holds both links once, on top',
               len(all_c) == 2 and not [x for x in all_c if 'Testing doc' in x or u1 in x or ua in x or '<link>' in x]
               and st['d'].startswith(f'**Testing doc (human):** {u1}\n\n**Testing doc (AI):** {ua}\n') and st['d'].count(u1) == 1 and st['d'].count(ua) == 1)
        sv = {x: g[x] for x in ('read_tracking', 'task', 'refresh_mr_docs')}; calls.clear()
        g.update(read_tracking=lambda: {'tasks': {'T9': {'mrs': ['web!5', 'web!6']}, 'B1': {'mrs': ['web!5']}, 'B2': {'mrs': ['web!7']}, 'N1': {'mrs': ['web!6']}}},
                 task=lambda t: {'id': t, 'name': 'n' if t in ('T9', 'N1') else '[Bug] b', 'status': 'promoted', 'description': st['d'] if t == 'T9' else 'Saw x.'},
                 refresh_mr_docs=lambda t, host=None, states=None: [])
        task_index('T9', lambda x: x.update(cases={'tasks': 'T9, bug B3'}))
        try:
            finish('T9', human, '**Solution** — x', ai=a2p)
        finally:
            g.update(sv); task_index('T9', lambda x: x.pop('cases', None))
        bd = {a[1]: a[2] for a in calls if a[0] == 'describe'}
        expect(f'finish: a [Bug] task with only its MRs or named in its cases tasks row gets the same doc links; other MRs or no bug prefix: none ({sorted(bd)})',
               sorted(bd) == ['B1', 'B3'] and all(v.startswith(f'**Testing doc (human):** {u1}\n\n**Testing doc (AI):** {ua}\n') and v.endswith('Saw x.') for v in bd.values()))
        sv = {x: g[x] for x in ('_tracker', 'read_tracking', 'refresh_mr_docs', 'task')}; views = []   # retro 2026-11-22: UP-T1..T5 read as tasks, 401 each
        g.update(_tracker=lambda *a: (views.append(a[1]) or (f'failed to fetch task {a[1]}: 401 Unauthorized' if a[1] != 'T9' else json.dumps({'id': 'T9', 'name': 'n', 'status': 'promoted', 'description': st['d']}))) if a[0] == 'view' else calls.append(a) or '',
                 read_tracking=lambda: {'tasks': {}}, refresh_mr_docs=lambda t, host=None, states=None: [], task=saved['task'])
        task_index('T9', lambda x: x.update(cases={'tasks': 'UP-T1'}))
        try:
            with contextlib.redirect_stderr(io.StringIO()) as fe:
                finish('T9', human, '**Solution** — x', ai=a2p)
            calls.clear()
            refused('finish: an unreadable task (401 twice) -> one line naming the auth check, nothing written', lambda: finish('T8', human, '**Solution** — x', ai=a2p), 'check tracker auth (crafty.ps1 tracker view T8')
        finally:
            g.update(sv); task_index('T9', lambda x: x.pop('cases', None))
        expect(f'finish: a cases "tasks" word that is no task (401) -> one retry, one skip line, finish goes on ({views})',
               views.count('UP-T1') == 2 and views.count('T8') == 2 and 'UP-T1 is no task id' in fe.getvalue() and not calls)
        jb = {'err': 'Team not authorized', 'ECODE': 'OAUTH_027'}
        expect('a JSON error body (no id) is a failed read with its reason, retried as an auth error',
               view_failed('X1', jb) == 'tracker view X1 failed (Team not authorized)' and AUTH_FAIL.search(view_why(jb)) and not view_failed('X1', {'id': 'X1'}))
        expect('_merge_val (K32): nested dicts per key, a type clash keeps the first, a prefix of an earlier value still appends, a repeat adds nothing',
               _merge_val({'a': {'x': 1}}, {'a': {'y': 2}}, 'B') == {'a': {'x': 1, 'y': 2}} and _merge_val(['a'], 'b', 'B') == ['a'] and _merge_val('a', ['b'], 'B') == 'a'
               and _merge_val('A; B: xy', 'x', 'B') == 'A; B: xy; B: x' and _merge_val('A; B: x', 'x', 'B') == 'A; B: x')
        rm0 = g['refresh_mr_docs']; calls.clear(); st['s'] = 'in progress'   # K33
        g['refresh_mr_docs'] = lambda t, host=None, states=None: states.extend([('web!5', 'opened', False), ('web!6', 'merged', True)]) or []
        with contextlib.redirect_stderr(io.StringIO()) as fe:
            refused('finish: an open MR without its tester guide line -> refused', lambda: finish('T9', human, '**Solution** — x', ai=a2p), 'web!5 have no tester guide')
        g['refresh_mr_docs'] = rm0
        expect('finish lists each MR with its tester guide state; refused before the status move',
               'MR web!5 (opened): tester guide MISSING' in fe.getvalue() and 'MR web!6 (merged): tester guide linked' in fe.getvalue() and not [a for a in calls if a[0] == 'status'])
        hc = []
        g.update(remote=lambda w: ('gitlab', 'g/r'), _run=lambda *a, **k: 'f/x', _host=lambda v, **a: hc.append(v) or (
            [{'iid': 5, 'web_url': 'https://h/g/r/5'}] if v == 'mr.list' else {'web_url': 'https://h/g/r/5'}))
        u = mr_create('.', 'fix(x): y (T9)', '## Summary\n## Changes\n## How tested\n| Not run | nothing |\n## Risks\n## Links\n', 'main')
        expect('mr: an open MR from the branch is edited (mr.update), never a second one', u == 'https://h/g/r/5' and hc == ['mr.list', 'mr.update'])
        hc.clear(); uc = mr_create('.', 'fix(x): y (T9)', '## Summary\n## Changes\n## How tested\n| Not run | nothing |\n## Risks\n## Links\n', 'main', check=True)
        with contextlib.redirect_stderr(io.StringIO()):
            g['PROSE_OK'] = ''; (refused if os.path.exists(os.path.join(KIT_DIR, 'skills/crafty/templates.md')) else lambda *x: None)('mr --check: an over-limit body is refused before the push (a test kit without templates.md has no limits)', lambda: mr_create('.', 'fix(x): y', '## Summary\n' + 'word ' * 400 + '\n## Changes\n## How tested\n## Risks\n## Links\n', 'main', check=True), 'mr-body refused'); g['PROSE_OK'] = 'selftest'
        expect('mr --check: the gates only, no git host call (CHECK OK)', uc.startswith('CHECK OK') and hc == [])
        mb = {'b': '## Summary\nx\n\n' + FOOTER + '\n'}
        g['_host'] = lambda v, **a: {'title': 't', 'description': mb['b']} if v == 'mr.get' else (mb.update(b=a['body']) or {'web_url': 'https://h/g/r/5'})
        fx = lambda p, s='nit': {'mr': 'https://h/g/r/5', 'file': 'a.ts', 'line': 3, 'severity': s, 'problem': p}
        n1 = followups([fx('rename x'), fx('rename  x', 'should-fix'), fx('add a test')], 'https://h/g/r/-/merge_requests/5')
        n2 = followups([fx('add a test'), fx('trim y')], 'https://h/g/r/-/merge_requests/5')
        mb['b'] = mb['b'].replace('\n', '\r\n'); n3 = followups([fx('trim y'), fx('z')], 'https://h/g/r/-/merge_requests/5')
        u5, u55 = 'https://h/g/r/-/merge_requests/5', 'https://h/g/r/-/merge_requests/55'
        expect('followups: per MR, a finding naming /55 is not /5; one naming no MR goes to each', [len(of_mr([{'mr': u55}, {'mr': '-'}], u, [u5, u55])) for u in (u5, u55)] == [1, 2])
        expect('followups: a "## Follow-ups" section above the footer, one bullet per finding, a repeat (same file + problem) kept once, CRLF body too',
               len(n1) == 2 and len(n2) == 1 and n3 == ['nit: `a.ts:3`: z'] and mb['b'].count('## Follow-ups') == 1 and mb['b'].count('- ') == 4 and mb['b'].index('trim y') < mb['b'].index(FOOTER))
        g.update(remote=saved['remote'], _run=saved['_run'], _host=saved['_host'])
        seen = []
        ADAPTERS['report']['markdown']['evidence'] = lambda a: seen.append(a['folder']) or {'folderId': a['folder'] or 'F1', 'folderLink': 'https://f/F1', 'files': {}}
        make_evidence('e', [], key='T9:evidence'); ev = make_evidence('e', [], key='T9:evidence')
        expect('evidence by key: the second run reuses the task folder', seen == [None, 'F1'] and ev['folderLink'] == 'https://f/F1')
        w(os.path.join(kp('agents'), 'd1', 'resume.json'), json.dumps({'steps': [{'step': 'loop', 'item': 'T6', 'evidence': 'round 1 PASS', 'at': '2026-10-29T10:00:00'}]}))
        calls.clear(); finish('T6', human, '**Solution** — x', ai='https://x/ai-doc')
        expect('finish: an unreadable AI doc (a URL) skips the case checks', any(a[0] == 'comment' for a in calls))
        task_index('T6', lambda x: x.update(spec={'title': 't'})); _pub_update('T6:testing-doc', url='https://x/h'); calls.clear()
        w(os.path.join(kp('agents'), 'd1', 'resume.json'), json.dumps({'steps': [{'step': 'loop', 'item': 'CU-T6', 'evidence': 'round 1 PASS', 'at': '2026-10-29T10:00:00'}]}))
        g['TAG'], tg = 'CU-', g['TAG']
        try:
            finish('CU-T6', 'https://x/h', '**Solution** — x', ai='https://x/ai-doc')
        finally:
            g['TAG'] = tg
        expect('finish on a spec-rendered task (tagged id too): links into its spec (tracker update), never describe', [a[0] for a in calls if a[0] in ('update', 'describe')] == ['update'])
        calls.clear(); g['PROSE_OK'], po = 'brief item list', g['PROSE_OK']; g['TAG'], tg = 'CU-', g['TAG']
        try:
            finish('CU-T6', 'https://x/h', '**Solution** — x', ai='https://x/ai-doc')
        finally:
            g['PROSE_OK'], g['TAG'] = po, tg
        expect('finish --prose-ok passes through to the spec update (proseOk)', [json.loads(a[3]).get('proseOk') for a in calls if a[0] == 'update'] == ['brief item list'])
    finally:
        ADAPTERS['report']['markdown'].pop('evidence', None)
        g.update(saved); shutil.rmtree(tmp, ignore_errors=True)


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
        use('gdocs', {'evidence': 'command', 'evidenceCommand': _q(sys.executable) + ' -c "import sys,os; print(\'folder https://b.ex/\' + sys.argv[1]); [print(os.path.basename(f), \'https://b.ex/\' + os.path.basename(f)) for f in sys.argv[2:]]" {name} {files}'})
        ev = make_evidence('run1', [png])
        use('gdocs', {'evidence': 'local'})
        expect('evidence store: command -> a link per file + the folder; local keeps the files (any report type)', ev.get('folderLink') == 'https://b.ex/run1' and ev['files']['s.png']['src'] == 'https://b.ex/s.png' and make_evidence('e', [png]) == {})
        use('no-such-type', {}); err = io.StringIO()
        try:
            with _c.redirect_stderr(err):
                make_doc('T', md)
        except SystemExit as e:
            expect('a report type with no adapter: exit 3 + one line naming it', e.code == 3 and 'reports.type no-such-type: no such report adapter' in err.getvalue())
        tl = with_tags('# T\n\nx\n', '.md', ['wave-2'])   # every store: the line; gdocs / confluence: native too (owner 2026-11-24)
        expect('doc tags: a Tags line under the title (once, replaced), first in an HTML body; native: gdocs, confluence',
               tl == '# T\n\nTags: wave-2\n\nx\n' and with_tags(tl, '.md', ['bug']) == '# T\n\nTags: bug\n\nx\n' and with_tags(tl, '.md', []) == '# T\n\nx\n'
               and with_tags('<body><p>x</p>', '.html', ['bug']) == '<body><p>Tags: bug</p><p>x</p>' and {n for n, x in ADAPTERS['report'].items() if x.get('tags')} == {'confluence', 'gdocs'} & set(ADAPTERS['report']))   # a test kit may load only some
        for name, adapter in ADAPTERS['report'].items():
            if adapter.get('selftest'):
                use(name, {}); adapter['selftest'](expect, tmp, md)
    finally:
        g.update(saved); shutil.rmtree(tmp, ignore_errors=True)


# ---- CLI: argument checks, verb dispatch
def _cli():
    global REPORT_TYPE, PROSE_OK, OVERRIDE, SCOPE, SCOPE_OK, NO_DOCS
    a = sys.argv[1:]
    cmd = a[0] if a else ''
    if cmd in VERBS:   # a plugin verb parses its own arguments
        sys.exit(VERBS[cmd](a[1:]) or 0)
    if cmd == 'cases':   # cases and render parse their own arguments; one arm each: lint's flow finds the verb
        sys.exit(cases_cmd(a[1:]))
    if cmd == 'render':
        sys.exit(render_cmd(a[1:]))
    if cmd == 'spec':
        sys.exit(spec_cmd(a[1:]))
    # --help never becomes an id; unknown flags and missing args are usage errors
    use = [ln for ln in __doc__.splitlines() if re.match(rf'\s+python -X utf8 devtools\.py {re.escape(cmd)}\b', ln)] if cmd else []
    ARITY = {'comment': 2, 'finish': 3, 'mr': 3, 'followups': 2, 'merge': 2, 'doc': 2, 'docgaps': 0, 'relayout': 1, 'evidence': 1, 'keepboth': 1, 'selftest': 0}
    FLAGS, opt = {}, {}
    CHECK = cmd == 'mr' and '--check' in a   # the body gates before the push (retro 2026-11-22: 9 mr-body refusals after it)
    a = [x for x in a if not (CHECK and x == '--check')]
    for f in ('--type', '--parent', '--folder', '--files-from', '--key', '--mode', '--label', '--run', '--run-id', '--override') if cmd in ('doc', 'evidence', 'docgaps') else ('--prose-ok', '--ai', '--override', '--spec') + (('--scope', '--scope-ok') if cmd == 'mr' else ()) if cmd in ('comment', 'finish', 'mr') else ('--override', '--scope', '--scope-ok', '--no-docs') if cmd == 'merge' else ():
        if f in a[1:-1]:
            i = a.index(f, 1); opt[f] = a[i + 1]; del a[i:i + 2]
        elif len(a) > 1 and a[-1] == f:   # an empty variable left the flag bare: name it, not "unknown option"
            print(f'devtools.py {cmd}: {f} needs a value (an empty variable?)\n' + '\n'.join(ln for ln in __doc__.splitlines() if re.match(rf'\s+python -X utf8 devtools\.py {re.escape(cmd)}\b', ln)), file=sys.stderr)
            sys.exit(2)
    ARITY['mr'], ARITY['comment'] = (1, 1) if opt.get('--spec') else (3, 2)
    REPORT_TYPE = (opt.get('--type') or REPORT_TYPE).lower()
    PROSE_OK = opt.get('--prose-ok') or ''
    OVERRIDE = opt.get('--override') or ''
    SCOPE, SCOPE_OK, NO_DOCS = opt.get('--scope') or '', opt.get('--scope-ok') or '', opt.get('--no-docs') or ''
    if PROSE_OK:
        print(f'[prose] --prose-ok: {PROSE_OK}', file=sys.stderr)
    if not cmd:   # agents call it bare to see the verbs: no usage error
        print(f"devtools.py verbs: {', '.join(sorted(set(ARITY) | set(VERBS)))}\n{__doc__}")
        sys.exit(0)
    if cmd in ('-h', '--help', 'help') or (use and any(x in ('-h', '--help') for x in a[1:])):
        print('\n'.join(use) if use else __doc__)
        sys.exit(0)
    bad = [x for x in a[1:] if re.match(r'^--?[A-Za-z][\w-]*$', x) and x not in FLAGS.get(cmd, set())]
    if cmd not in ARITY or bad or len(a) - 1 < ARITY[cmd]:
        print((f'devtools.py {cmd}: unknown option {bad[0]}' if bad else f'devtools.py {cmd}: missing arguments') if cmd in ARITY
              else f"devtools.py: unknown verb {cmd}: python -X utf8 devtools.py <verb> ... (verbs: {', '.join(sorted(ARITY))})\n{__doc__}", file=sys.stderr)
        print('\n'.join(use) if use else '', file=sys.stderr)
        if cmd in USAGE_EXAMPLES:   # retro 2026-11-17: 7x 'evidence: missing arguments'
            print(f'  e.g. {USAGE_EXAMPLES[cmd]}', file=sys.stderr)
        sys.exit(2)
    if cmd == 'comment' and opt.get('--spec'):   # comment <task> --spec <json> [kind]: rendered
        kd = a[2] if len(a) > 2 else 'comment-status'
        if kd not in RENDERERS:
            raise SystemExit(f'comment --spec: kind {kd} has no renderer ({", ".join(k for k in RENDERERS if k.startswith("comment-"))})')
        print(comment(a[1], spec_text(opt['--spec'], kd, a[1]), kd))
    elif cmd == 'comment':
        print('WARN devtools.py comment: hand-written text; render it: comment <task> --spec <c.json> [kind] (templates.md "Comment spec")', file=sys.stderr)
        print(comment(a[1], _text(a[2]), a[3] if len(a) > 3 else 'comment-status'))
    elif cmd == 'finish':
        prior_gate(a[1], '', f'devtools.py finish {a[1]}')
        # 'cases' = rendered from the task's cases spec, only for a doc process.docs lists (one command fits any doc set)
        rc = lambda p, k, key: (cases_file(a[1], k) if key in {d['key'] for d in docs()} else None) if p == 'cases' else p
        sol = spec_text(a[3], 'comment-solution', a[1]) if a[3].endswith('.json') else _body(a[3])   # a .json = the comment spec
        finish(a[1], rc(a[2], 'human', 'testing-doc'), sol, *(a[4:5] or ['review']), ai=rc(opt.get('--ai'), 'ai', 'testing-ai'))
        print('done')
    elif cmd == 'mr' and opt.get('--spec'):   # title + body rendered (devtools.py "render"); a 2nd positional = target
        if len(a) > 3:
            raise SystemExit('mr --spec <mr.json>: no title or body arguments (both are rendered); only <worktree> [target]')
        s = load_spec(opt['--spec'])
        if gaps := spec_gaps(s, 'mr-body'):
            raise SystemExit(f'mr spec refused: missing {", ".join(gaps)}')
        print(mr_create(a[1], render_title(s), render_mr_body(s), *(a[2:3] or [None]), check=CHECK))
    elif cmd == 'mr':
        print('WARN devtools.py mr: a hand-written title / body; render them: mr <wt> --spec <mr.json> (templates.md "MR spec")', file=sys.stderr)
        print(mr_create(a[1], a[2], _body(a[3]), *(a[4:5] or [None]), check=CHECK))
    elif cmd == 'followups':   # each finding to its MR (an unnamed MR: every MR)
        items, urls = json.load(open(a[1], encoding='utf-8')), a[2:]
        for u in urls:
            new = followups(of_mr(items, u, urls), u)
            print(f'followups {u}: {len(new)} added' + ''.join(f'{chr(10)}  - {b}' for b in new))
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
        if path == 'cases' and (dk := (opt.get('--key') or '').rpartition(':')[2]) in ('testing-doc', 'testing-ai') and dk not in {d['key'] for d in docs()}:
            print(f'devtools.py doc: {dk} is not in process.docs: not published (the cases spec keeps the record)')
            sys.exit(0)
        if path == 'cases' and (opt.get('--key') or '').rpartition(':')[2] in ('testing-doc', 'testing-ai'):   # rendered from the cases spec
            path = cases_file(opt['--key'].rpartition(':')[0], {'testing-doc': 'human', 'testing-ai': 'ai'}[opt['--key'].rpartition(':')[2]])
        if os.path.isfile(title) and not os.path.isfile(path):   # swapped order: doc <file> "<title>"
            title, path = path, title
        if not os.path.isfile(path):
            print(f'devtools.py doc: file not found: {path} - write it first (nothing was published)', file=sys.stderr)
            sys.exit(2)
        if opt.get('--mode') not in (None, 'append', 'replace'):
            print('devtools.py doc: --mode append|replace', file=sys.stderr)
            sys.exit(2)
        if (opt.get('--key') or '').rpartition(':')[2] in ('testing-doc', 'testing-ai') and not opt.get('--run'):   # a dev round's task doc
            doc_prior(opt['--key'])
        print(publish(opt['--key'], title, path, *(a[3:4] or [None]), mode=opt.get('--mode'), label=opt.get('--label') or '',
                      run=json.load(open(opt['--run'], encoding='utf-8-sig')) if opt.get('--run') else None, run_id=opt.get('--run-id') or '') if opt.get('--key')
              else make_doc(title, path, *(a[3:4] or [])))
    elif cmd == 'docgaps':
        if not (opt.get('--key') and opt.get('--run')):
            print('devtools.py docgaps --key <task>:testing-doc --run <cells.json> [--run-id <id>]', file=sys.stderr)
            sys.exit(2)
        rec = _pub_read(opt['--key']); rounds = rec.get('rounds') or []   # earlier runs of the newest version cover rows too; --run-id: not its own earlier publish
        print('\n'.join(run_gaps(rounds[-1]['body'], json.load(open(opt['--run'], encoding='utf-8-sig')),
                                 [r for r in rec.get('runs') or [] if _after(r, rounds[-1]) and not (opt.get('--run-id') and r.get('id') == opt['--run-id'])]) if rounds else []))
    elif cmd == 'relayout':
        for ref in a[1:]:
            print(relayout(ref))
    elif cmd == 'evidence':
        ff = open(opt['--files-from'], encoding='utf-8-sig').read().splitlines() if opt.get('--files-from') else []   # one path per line: no command-line limit
        print(json.dumps(make_evidence(a[1], a[2:] + [x for x in ff if x.strip()], opt.get('--folder') or None, opt.get('--parent') or None, opt.get('--key'))))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(audited('devtools.py', sys.argv[1:], _cli))
