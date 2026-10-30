"""devtools.py: tracker / git-host / docs helpers for agents (crafty steps 6-7). Host and project come from the worktree's
`origin` remote, the MR target from its crafty.ps1 wt record. Tracker reads and status changes: crafty.ps1 tracker.

 python -X utf8 devtools.py comment <taskId> <file.md | "text"> [kind] [--prose-ok "<why>"]   kind: comment-status (default), comment-deploy, decision-request ...
 python -X utf8 devtools.py finish <taskId> <testing.md|url> <solution.md> [review] --ai <ai.md|url> [--prose-ok "<why>"]   both docs (human + AI)
  by key after the local loop PASS, the description's links block, the solution comment (edits the last kit one), status
 python -X utf8 devtools.py mr <worktree> "<title>" <body.md> [target] [--prose-ok "<why>"]   open a merge/pull request from the current branch
  comment / finish / mr: a text over its prose limits is refused (exit 1, nothing written); --prose-ok keeps a format the brief fixes
 finish / mr / doc --key <task>:testing-*: the prior-work gate (crafty.ps1 prior -Task <id> first); --override "<why>" passes, logged
 python -X utf8 devtools.py merge <worktree> <iid>   merge now (per repos[].mergeMethod; green / no CI) or arm merge-when-green; waits <= 90 s;
  last line (read back): MERGED / SCHEDULED / WAIT (also: producer unmerged) / CONFLICT / PIPELINE_FAILED / NOT_MERGED
 python -X utf8 devtools.py doc "<title>" <file.html|.md> [parent] [--type <t>] [--key <task|run>:<kind> [--mode append|replace] [--label <l>]]
  publish a document (reports.type); prints its URL/path; --key: the same doc every time (.state/published), a dated round each
  --run <cells.json> (pokey finalize, key <task>:testing-doc): fills the human doc's Result / Evidence + a dated "<env> run" section
 python -X utf8 devtools.py evidence "<name>" [--parent <id>] [--folder <id>] [--files-from <list>] [--key <k>] <file> ...   host evidence files (gdocs: Drive; --key reuses its folder) -> JSON
 python -X utf8 devtools.py keepboth <file> [...]   append-only rebase conflicts: keep OURS then THEIRS
 python -X utf8 devtools.py selftest   offline self-test (and each installed plugin's)
Plugins: skills/crafty/adapters/*.py (kitbag.py goody add <name>) register report adapters and verbs (lbcheck: goody liquibase;
 findings: goody module-audit).
Exit codes: 0 ok · 1 problem (merge refused, conflict, check issues) · 2 usage error · 3 the feature is a goody that is not installed.
Sections: L36 config · L70 run · L154 tracker · L320 git host · L403 MR · L481 merge · L725 docs · L858 publish · L1068 plugins ·
  L1082 keepboth · L1101 selftest · L1402 CLI
Config (..\\kit.local.json): "tracker" (crafty.ps1 tracker, default none), "reports" + "driveParent" (doc / evidence:
kit.example.json reports._readme), "gitHost" / "githubHost" (self-hosted; default gitlab.com / github.com).
Windows: run from PowerShell (python hangs in git-bash); Linux/macOS: python3. CLIs are resolved with shutil.which.
"""
import contextlib, glob, html, importlib.util, json, os, re, shutil, subprocess, sys, tempfile, time
from datetime import datetime

KIT = os.path.dirname(os.path.abspath(__file__))  # crafty skill folder
KIT_DIR = os.path.dirname(os.path.dirname(KIT))   # the kit (.claude)
sys.path.insert(0, os.path.join(KIT_DIR, 'skills', 'bossy'))
from kitbag import kit_path, locked, audited, stamp_fn, state_read, state_write, task_index, read_tracking, kitlog   # one path map, lock, call log and goodies' usage stamps for every kit script


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
GWS = shutil.which('gws')
RCFG = CFG.get('reports') or {}
REPORT_TYPE = (os.environ.get('KIT_REPORT_TYPE') or RCFG.get('type') or ('gdocs' if GWS else 'markdown')).lower()
ADAPTERS = {'report': {}}   # kind -> name -> {verb: fn(a)}
VERBS = {}                  # plugin CLI verbs: name -> fn(argv) -> exit code


def _todo(verb):
    raise SystemExit(f'adapter verb {verb} is a stub (kitbag.py new adapter): implement it first')


def extra_missing(feature, name):
    """The one line an agent acts on: install the goody, retry."""
    print(f'{feature} is a goody: run kitbag.py goody add {name}', file=sys.stderr)
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


def _run(cmd, cwd=None, check=False, write=None):
    if not cmd[0]:
        raise SystemExit(f'CLI not found on PATH for: {cmd[1:3]}')
    write = _is_write(cmd) if write is None else write   # on the CLI's own words, before the shim swap shifts them
    cmd = _argv(cmd)
    sec = min(120, int(os.environ.get('KIT_NET_TIMEOUT_SEC') or (CFG.get('net') or {}).get('timeoutSec') or 120))   # the whole deadline
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
    if rc:   # never a silent failure: the caller's own error then has the cause above it
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
DEV = os.path.join(KIT, 'crafty.ps1')   # tracker adapter
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
    """Print kitbag.py prose findings for a text about to be published; never truncates."""
    tool = os.path.join(KIT_DIR, 'skills', 'bossy', 'kitbag.py')
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


PROSE_OK = ''   # --prose-ok "<why>": a format the brief fixes; the findings still print
OVERRIDE = ''   # --override "<why>": past the prior-work gate, logged
TAG = (CFG.get('tracker') or {}).get('branchTag') or {'clickup': 'CU-', 'github': 'GH-', 'gitlab': 'GL-'}.get(TRACKER_TYPE, '')


def prior_gate(task, repo, what):
    """Check before create (crafty.ps1 prior; lib.ps1 Assert-KitPrior is the same gate): prior ran within prior.validHours and found
    nothing for this repo (or a duplicate task); --override passes, logged."""
    if not task:
        return
    if OVERRIDE:
        kitlog('calls', 'prior-override', {'task': task, 'what': what, 'reason': OVERRIDE})
        return
    p = (state_read(os.path.join(kit_path('tasks'), re.sub(r'[^\w.-]', '_', task) + '.json')) or {}).get('prior') or {}
    reg = json.load(open(os.path.join(KIT_DIR, 'skills', 'bossy', 'params.registry.json'), encoding='utf-8'))['params']
    hours = float(re.search(r'default=([\d.]+)', reg['prior.validHours']).group(1))
    try:
        fresh = (datetime.now().astimezone() - datetime.fromisoformat(p['at'])).total_seconds() < hours * 3600
    except (KeyError, TypeError, ValueError):
        fresh = False
    if not fresh:
        raise SystemExit(f'{what} refused: run crafty.ps1 prior -Task {task} first (check before create)')
    leaf = lambda r: re.split(r'[\\/]', r or '')[-1]
    hit = [f for f in p.get('found') or [] if isinstance(f, dict) and f.get('kind') and (f.get('kind') == 'task' or not repo or not f.get('repo') or leaf(f['repo']) == leaf(repo))]
    if hit:
        kitlog('calls', 'prior-refused', {'task': task, 'what': what, 'found': f"{hit[0].get('kind')} {hit[0].get('ref')}"})
        raise SystemExit(f"{what} refused: already exists: {'; '.join(f'{h.get("kind")} {h.get("ref")} {h.get("title")}' for h in hit)}: "
                         f"reuse it (a task: extend it with crafty.ps1 tracker scope -Task <id> -Add '<item>'), or --override '<reason>'")


def task_of_branch(branch):
    m = re.search(rf'(?i){re.escape(TAG)}([A-Za-z0-9]+)', branch or '') if TAG else None
    return m.group(1) if m else ''


def prose_gate(kind, text):
    """prose() before a write: over a limit -> exit 1 before anything is written, unless --prose-ok."""
    found = prose(kind, text)
    if found and not PROSE_OK:
        raise SystemExit(f'[prose] {kind} refused: {len(found)} finding(s) above; rewrite to the limits (same facts), or pass'
                         ' --prose-ok "<why>" for a format the brief fixes. Nothing was written.')
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


LINK_LINE = re.compile(r'(?im)^[ \t]*(\*\*)?(Testing doc( \((human|AI)\))?|Testing goals \(AI\))(\*\*)?[ \t]*:[^\n]*\n?(?:[ \t]*\n)*')


def links_block(desc, human, ai):
    """The description with one fixed links block on top (bold labels, web links as [open](url)); every older testing-doc line removed."""
    md = lambda u: f'[open]({u})' if re.match(r'https?://\S+$', u or '') else u
    return f'**Testing doc (human):** {md(human)}\n\n**Testing doc (AI):** {md(ai)}\n\n' + LINK_LINE.sub('', desc or '').lstrip()   # a blank line: Markdown joins adjacent lines


def no_doc_links(md):
    """A comment without testing-doc links: a 'Testing doc: x' field at a line start or after ' · ' goes, up to the next ' · '."""
    md = re.sub(r'(?im)(?:^[ \t]*|[ \t]+·[ \t]*)(?:\*\*)?Testing (?:doc|goals)(?: \((?:human|AI)\))?(?:\*\*)?[ \t]*:[^\n]*?(?=[ \t]+·[ \t]|$)', '', md or '')
    md = re.sub(r'(?m)^[ \t]*·[ \t]*', '', md)
    return re.sub(r'\n{3,}', '\n\n', '\n'.join(ln for ln in md.split('\n') if ln.strip() or not ln)).strip() + '\n' if md.strip() else ''


def _doc_url(tid, kind, doc):
    """A file -> published by key <task>:<kind> (same doc every round); a URL -> remembered as that key's link."""
    if os.path.isfile(doc):
        return publish(f'{tid}:{kind}', os.path.splitext(os.path.basename(doc))[0], doc)
    if not re.match(r'https?://', doc):
        raise SystemExit(f'{kind} {doc!r}: neither a file nor a URL')
    rec = _pub_read(f'{tid}:{kind}')
    if rec.get('url') and rec['url'] != doc:   # a second link would take the next publish (and its history) to another doc
        raise SystemExit(f'finish {tid}: {kind} already is {rec["url"]}; pass the file (it updates that doc, rounds kept), not {doc}. Nothing was written.')
    _pub_update(f'{tid}:{kind}', url=doc)
    return doc


def finish(tid, guide, solution_md, status='review', ai=None):
    """Both docs (human + AI) published by key, the description's links block, one solution comment, status (never backwards)."""
    ai = ai or _pub_read(f'{tid}:testing-ai').get('url')
    if not ai:
        raise SystemExit(f'finish {tid}: no AI testing doc (--ai <ai.md|url>, templates.md "Testing doc (AI)"); both docs are linked on every task. Nothing was written.')
    solution_md = no_doc_links(solution_md)   # the doc links live only in the description
    prose_gate('comment-solution', solution_md)   # before doc, describe, status
    if not os.path.isfile(guide):   # a URL: the local-loop gate still holds
        ok, ev = local_pass(tid)
        if not ok:
            raise SystemExit(f'finish {tid}: the local test loop is {"at " + repr(ev) if ev else "not recorded"}, not PASS (crafty.ps1 checkpoint -Step loop -Item {tid} -Evidence "round <n> PASS"). Nothing was written.')
    ai_url, guide_url = _doc_url(tid, 'testing-ai', ai), _doc_url(tid, 'testing-doc', guide)
    t = task(tid)
    md = t.get('description') or ''
    new = links_block(md, guide_url, ai_url)
    # failed lookup: describing would wipe the description
    if t.get('id') and t.get('name') and new != md:
        _tracker('describe', tid, new)
    comment(tid, solution_md, 'comment-solution')
    cs = (CFG.get('tracker') or {}).get('statuses') or {}   # a name or a list of names (lib.ps1 tracker statuses)
    past = [str(n).lower() for k in ('promoted', 'inTest', 'closed') for n in ([cs[k]] if isinstance(cs.get(k), str) else cs.get(k) or
            {'promoted': ['promoted'], 'inTest': ['in test', 'for test'], 'closed': ['closed', 'complete', 'done']}[k])]
    if str(t.get('status', '')).strip().lower() in past:   # a fix round after the merge: links and comment only
        print(f'[finish] {tid} is {t.get("status")}: status kept (never backwards)', file=sys.stderr)
    else:
        set_status(tid, status)


# ---- git host: lib.ps1 git-host adapters via crafty.ps1 host
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
        out = _run([PWSH, '-NoProfile', '-NonInteractive', '-File', DEV, 'host', verb, '@' + p], write=verb in ('mr.create', 'mr.update', 'mr.merge', 'mr.unauto'))
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
    """MR target: the worktree's record (crafty.ps1 wt new), else kit.local.json repos[].target, else origin/HEAD.
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
            print(f"[mr] target {r['target']} (no crafty.ps1 wt record; kit.local.json repos[].target of {r.get('name') or co})", file=sys.stderr)
            return r['target']
    head = _run(['git', '-C', worktree, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD'])
    if head.startswith('origin/') and '\n' not in head:
        print(f'[mr] target {head[7:]} (no crafty.ps1 wt record, no kit.local.json repos[].target; origin/HEAD)', file=sys.stderr)
        return head[7:]
    return None


# ---- MR: open a merge / pull request
MR_SECTIONS = ('## Summary', '## Changes', '## How tested', '## Risks', '## Links')  # templates.md "MR body"
FOOTER = '🤖 Generated with [Claude Code](https://claude.com/claude-code)'


def _verified_gaps(body_md):
    """True when '## How tested' has no 'Not run:' / 'Pure logic:' line."""
    m = re.search(r'^## How tested[^\n]*\n(.*?)(?=^## |\Z)', body_md, re.M | re.S)
    sec = m.group(1) if m else ''
    return bool(m) and not re.search(r'(?im)^\s*[-*|]?\s*(\*\*)?(not run|pure logic)(\*\*)?\s*[:|]', sec)   # a line or a table row


def _how_tested_table(body_md):
    """True when '## How tested' starts with a Markdown table (templates.md "MR body": | Check | Result |)."""
    return bool(re.search(r'(?m)^## How tested[^\n]*\n\s*\|', body_md))


UI_FILES = re.compile(r'\.(html?|s?css|less|sass|tsx|jsx|vue|svelte)$|(^|/)res/layout[^/]*/[^/]+\.xml$', re.I)


def _ui_line_missing(worktree, tgt, body_md):
    """Changed UI files vs origin/<target> when the body has no 'UI:' line, else []."""
    if re.search(r'(?im)^\s*[-*|]?\s*(\*\*)?UI(\*\*)?\s*[:|]', body_md) or not tgt:
        return []
    out = _run(['git', '-C', worktree, 'diff', '--name-only', f'origin/{tgt}...HEAD'])
    return [f for f in out.splitlines() if UI_FILES.search(f.strip())]


TASK_LINK = {'clickup': 'clickup.com', 'github': '/issues/', 'gitlab': '/issues/', 'jira': '/browse/', 'jira-server': '/browse/',
             'linear': 'linear.app', 'azure': '_workitems', 'youtrack': '/issue/'}


def mr_create(worktree, title, body_md, tgt=None):
    missing = [h for h in MR_SECTIONS if h not in body_md]
    if missing:
        print(f'[mr] body is missing {missing} - templates.md "MR body"', file=sys.stderr)
    prose_gate('mr-title', title)
    prose_gate('mr-body', body_md)
    if _verified_gaps(body_md):
        print('[mr] "## How tested" has neither a "Not run: <gate and why>" nor a "Pure logic: <spec file or node output>" line'
             ' - say what was not run (or "Not run: nothing") - see templates.md "MR body"', file=sys.stderr)
    if '## How tested' in body_md and not _how_tested_table(body_md):
        print('[mr] "## How tested" is not a table: use "| Check | Result |" rows (templates.md "MR body")', file=sys.stderr)
    link = TASK_LINK.get(TRACKER_TYPE)
    if link and link not in body_md:
        print(f'[mr] body has no tracker ({TRACKER_TYPE}) task link', file=sys.stderr)
    if FOOTER not in body_md:
        body_md = body_md.rstrip() + '\n\n' + FOOTER + '\n'
    host, proj = remote(worktree)
    src = _run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'])
    prior_gate(task_of_branch(src), proj, f'devtools.py mr {src}')
    tgt = tgt or target_of(worktree)
    if not tgt:
        raise SystemExit('no target: no crafty.ps1 wt record, no kit.local.json repos[].target for this repo and no origin/HEAD'
                  ' - pass it as the 4th argument (git remote set-head origin --auto fixes origin/HEAD)')
    ui = _ui_line_missing(worktree, tgt, body_md)
    if ui:
        print(f'[mr] the diff touches templates/styles ({", ".join(ui[:3])}{" ..." if len(ui) > 3 else ""}) but "## How tested" has no'
         ' "UI: <committed spec or screenshot link>" line (or "UI: not a UI change") - templates.md "MR body"', file=sys.stderr)
    ex = _host('mr.list', type=host, repo=proj, state='opened', source_branch=src)   # one MR per branch: a re-run edits it
    old = next((x for x in ex if isinstance(x, dict) and x.get('web_url')), None) if isinstance(ex, list) else None
    if old:
        up = _host('mr.update', type=host, repo=proj, n=old.get('iid') or old.get('number'), title=title, body=body_md)
        if not (isinstance(up, dict) and up.get('web_url')):
            print(f'[mr] {old["web_url"]} is open from {src}; its body was not updated (git host has no mr.update: {str(up)[:200]}) - edit it by hand', file=sys.stderr)
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
    return url


# ---- merge: merge now or arm merge-when-green; producers first
def _remember_automerge(ref):
    """GitLab drops merge-when-green on a new push (e.g. a rebase): record the intent in .state/automerge.json (under the
    tracking lock, lib.ps1 Update-KitTracking); bossy.ps1 track run re-arms it every supervise round until the MR merges."""
    path = kit_path('automerge')
    try:
        with locked(os.path.join(kit_path('tasks', create=True), '_tracking')):
            am = (state_read(path) or {}).get('refs') or {}
            am[ref] = datetime.now().astimezone().isoformat()
            state_write(path, {'refs': am})
    except Exception as e:   # a lost intent is never re-armed
        print(f'[merge] could not record the merge-when-green intent for {ref} in {path}: {e}', file=sys.stderr)


MERGE_WORDS = ('MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED', 'NOT_MERGED')
RESOLVE = 'crafty.ps1 wt sync, resolve, re-check, push --force-with-lease to YOUR branch, then run merge again'
DOC_LINK = re.compile(r'(?im)^[ \t>*_|-]*testing doc(?! \(ai\))[^:\n]{0,12}:[ \t*_|]*(\[[^\]\n]*\]\()?(https?://|[A-Za-z]:[\\/])\S')
AI_LINK = re.compile(DOC_LINK.pattern.replace('testing doc(?! \\(ai\\))[^:\\n]{0,12}', 'testing doc \\(ai\\)[ \\t*_]*'))
NO_DOC = re.compile(r'(?im)^[ \t>*_-]*testing doc[ \t*_]*:[ \t*_]*(none|n/?a)[ \t.]*($|[|;,(\u00b7])')   # one line; 'none yet, link below' passes


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
    """State of <repo>!<iid> ('' = unknown), path resolved like bossy.ps1 track."""
    if '/' in repo:
        path = repo
    else:
        group = CFG.get('gitlabGroup') if host == 'gitlab' else ''
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
    if NO_DOC.search(m.get('description') or m.get('body') or ''):   # merged 3x with no doc: testers had nothing to follow
        return (f'!{iid}: the MR body says "Testing doc: none"; every change gets a human testing doc: write it, devtools.py doc, '
                f'put its link in the MR body, merge again\nNOT_MERGED')
    body = m.get('description') or m.get('body') or ''
    if TASK_LINK.get(TRACKER_TYPE, '\0') in body and not (DOC_LINK.search(body) and AI_LINK.search(body)):   # a task's MR: both docs linked first
        return (f'!{iid}: a task MR without "Testing doc: <url>" and "Testing doc (AI): <url>" lines; after the local loop PASS: devtools.py finish, then devtools.py mr'
                f' with the link (edits this MR), merge again\nNOT_MERGED')
    if m.get('has_conflicts') or m.get('detailed_merge_status') == 'conflict':
        return f'CONFLICT: {RESOLVE}\nCONFLICT'
    st = (m.get('head_pipeline') or {}).get('status')
    if st in ('failed', 'canceled'):
        return _failed(H, m.get('head_pipeline'), iid)
    # no CI config -> merge now (merge-when-green would wait forever); CI + no pipeline 5 min after the MR update -> NOT_MERGED
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
    return [c.strip() for c in (r[:-1] if r.endswith('|') and not r.endswith('\\|') else r).split('|')]


# Inline styles, not <code> / <col> / classes: Google Docs' HTML import keeps span and cell styles and the header cells' widths only
CODE_CSS = "font-family:'Roboto Mono';font-size:9pt;background-color:#f1f3f4"
CELL_CSS = 'vertical-align:top;padding:4pt'
HEAD_CSS = CELL_CSS + ';background-color:#e8eaed'
COL_ROLES = ((5, r'#|no\.?|id|round'), (10, r'type|result|status|date|verdict|retest'), (20, r'evidence|links?|fix commit|bugs found'),
             (25, r'expected|observed|pass rule|saw|why|value'), (40, r'steps?\b.*|check|goal|how checked|what.*|cases run|item|setting'))


def col_widths(headers):
    """Column widths in % by header role (# 5, Step 40, Expected 25, Result 10, Evidence 20; others share the rest), summing to
    100; None when no header has a known role (the renderer's default widths)."""
    w = [next((p for p, rx in COL_ROLES if re.fullmatch(rx, re.sub(r'[*_`]', '', h).strip().lower())), 0) for h in headers]
    if not any(w):
        return None
    w = [x or max(10, (100 - sum(w)) // max(1, w.count(0))) for x in w]
    return [round(x * 100 / sum(w), 1) for x in w]


def md_to_html(md, title=''):
    """Dependency-free Markdown -> HTML for `doc` (gws uploads Markdown as plain text): headings, tables (header bold and shaded,
    widths by role, cells padded and top-aligned), lists, emphasis, monospace code spans and blocks, links, images, rules."""

    def inline(t):
        t = html.escape(t, quote=False).replace('&lt;br&gt;', '<br>')   # a line break inside a table cell (evidence previews)
        code = []   # code spans set aside: emphasis and link rules never touch them
        t = re.sub(r'`([^`]+)`', lambda m: code.append(m[1]) or f'\0{len(code) - 1}\0', t)
        t = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', t)
        t = re.sub(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])', r'<i>\1</i>', t)
        # images before links: ![alt](url "width px"), default and cap 600 px (the page width)
        t = re.sub(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;(\d+)&quot;|\s+"(\d+)")?\)',
                   lambda m: f'<p><img src="{m[2]}" width="{min(600, int(m[3] or m[4] or 600))}"><br><i>{m[1]}</i></p>', t)
        t = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', r'<a href="\2">\1</a>', t)
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
            rows = ['<tr>' + ''.join(f'<th style="{HEAD_CSS}{f";width:{w}%" if w else ""}"><b>{inline(c)}</b></th>' for c, w in zip(head, cw)) + '</tr>']
            i += 2
            while i < len(lines) and lines[i].startswith('|'):
                rows.append('<tr>' + ''.join(f'<td style="{CELL_CSS}">{inline(c)}</td>' for c in _cells(lines[i])) + '</tr>'); i += 1
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


def make_doc(title, path, parent=None, url=None):
    """Publish via reports.type -> URL or kept path; parent: a remote id or a folder to keep it in; url: an earlier publish of
    this doc, updated in place where the adapter can."""
    ad = ADAPTERS['report'].get(REPORT_TYPE) or extra_missing(f'reports.type {REPORT_TYPE}', f'report-{REPORT_TYPE}')
    keep = parent if parent and os.path.isdir(parent) else None
    stamp_fn(ad['publish'])
    return ad['publish']({'title': title, 'path': path, 'parent': None if keep else parent, 'keep': keep, 'url': url})


def make_evidence(name, files, folder=None, parent=None, key=None):
    """Host evidence files -> {folderId, folderLink, label, files}; {} = they stay in the run folder; key: reuse its folder."""
    ad = ADAPTERS['report'].get(REPORT_TYPE)
    if ad is None:   # evidence stays in the run folder; say why once
        print(f'reports.type {REPORT_TYPE} is a goody: run kitbag.py goody add report-{REPORT_TYPE}', file=sys.stderr)
    fn = (ad or {}).get('evidence')
    if not fn:
        return {}
    stamp_fn(fn)
    rec = _pub_read(key) if key else {}
    out = fn({'name': name, 'files': files, 'folder': folder or rec.get('folderId'), 'parent': parent})
    if key and out.get('folderId'):
        _pub_update(key, folderId=out['folderId'], folderLink=out.get('folderLink') or rec.get('folderLink'))
        out['folderLink'] = out.get('folderLink') or rec.get('folderLink')
    return out


# ---- publish: one artefact per key (<task or run>:<kind>), the same id and link on every round; .state/published/
PUB_KINDS = {'testing-doc': 'append', 'testing-ai': 'append', 'qa-report': 'append'}   # other kinds: replace
GOALS_MARK = re.compile(r'(?m)^#{1,2} (Testing goals\b|Goals \(what must be true\))')   # templates.md "Testing goals"
CHECKS_TABLE = re.compile(r'(?im)^\|\s*#\s*\|\s*Steps\s*\|\s*Expected\s*\|\s*Result\s*\|\s*Evidence\s*\|')   # "Human testing doc" (positive cases)
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
    for f in glob.glob(os.path.join(kit_path('agents'), '*', 'resume.json')):
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


def _table_rows(md, cells=None):
    """Rows of every table whose header has '#', 'Result' and 'Evidence': [(id, result, evidence)]; cells {id: {result,
    evidence}} -> the Markdown with those two cells filled. -> (rows, md)"""
    out, rows, cols = [], [], None
    for line in md.split('\n'):
        c = _cells(line) if line.lstrip().startswith('|') else None
        low = [x.lower() for x in c] if c else []
        if c and '#' in low and 'result' in low and 'evidence' in low:
            cols = {n: i for i, n in enumerate(low)}
        elif c and cols and not re.fullmatch(r'[\s|:-]+', line) and len(c) == len(cols):
            rows.append((c[cols['#']], c[cols['result']], c[cols['evidence']]))
            if cells and c[cols['#']] in cells:
                for k in ('result', 'evidence'):
                    c[cols[k]] = str(cells[c[cols['#']]].get(k) or '').replace('|', '\\|')
                line = '| ' + ' | '.join(c) + ' |'
        elif not c:
            cols = None
        out.append(line)
    return rows, '\n'.join(out)


def _round_rows(md):
    """The first cells (round numbers) of the AI doc's Rounds table; None without one."""
    m = ROUNDS_TABLE.search(md or '')
    return None if not m else [_cells(l)[0] for l in m.group(1).splitlines() if l.strip()]


def _compose(title, rounds, runs=()):
    """The newest version on top (Result / Evidence filled by the newest env run when it is newer than that version: a fix round
    after a run starts empty), then env runs and earlier rounds newest first under dated headings ('## <env> run <date>',
    '## Round <n> — <date>'), each kept whole; one round, no run = unchanged. -> (text, ext)"""
    top = rounds[-1]
    if runs and top['ext'] == '.md' and ((runs[-1]['seq'] > top['seq']) if 'seq' in runs[-1] and 'seq' in top else runs[-1]['at'] >= top['at']):
        top = dict(top, body=_table_rows(top['body'], runs[-1].get('cells') or {})[1])
    secs = [(f'{r["label"] or "env"} run {r["at"]}', r) for r in reversed(runs)]
    secs += [(f'Round {i + 1} — {r["at"]}{" " + r["label"] if r["label"] else ""}', r) for i, r in reversed(list(enumerate(rounds[:-1])))]
    if not secs:
        return top['body'], top['ext']
    if any(r['ext'] == '.html' for r in [top] + [r for _, r in secs]):
        h = lambda r: _body_of(r['body'] if r['ext'] == '.html' else md_to_html(r['body']))
        body = h(top) + ''.join(f'<h2>{html.escape(n)}</h2>{h(r)}' for n, r in secs)
        return f'<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title></head><body>{body}</body></html>', '.html'
    return top['body'].rstrip() + '\n\n' + '\n\n'.join(f'## {n}\n\n{_demote(r["body"]).strip()}' for n, r in secs) + '\n', '.md'


def _check_doc(kind, scope, path, body):
    """testing-doc (human, positive cases, after the loop PASS) / testing-ai (the local loop record, every case): their tables."""
    if GOALS_MARK.search(body):
        raise SystemExit(f'{path} is the local goals file (templates.md "Testing goals"): never published; publish the AI doc'
                         ' ("Testing doc (AI)") and, after the loop PASS, the human doc. Nothing was published.')
    tb, name, tpl = (CHECKS_TABLE, '| # | Steps | Expected | Result | Evidence |', 'Human testing doc') if kind == 'testing-doc' else \
        (AI_TABLE, '| # | Type | Steps / API call + payload | Expected | Result | Evidence |', 'Testing doc (AI)')
    if not tb.search(body):
        raise SystemExit(f'{path} has no case table "{name}" (templates.md "{tpl}"). Nothing was published.')
    neg = re.search(r'(?im)^\|[^\n]*\|\s*negative\s*\|', body)
    if kind == 'testing-doc' and neg:
        raise SystemExit(f'{path} has a negative row: the human doc holds positive cases only; negative ones go in the AI doc. Nothing was published.')
    if kind == 'testing-doc' and (re.search(r'!\[', body) or any(r or e for _, r, e in _table_rows(body)[0])):
        raise SystemExit(f'{path} has evidence or results: the human doc ships with Result / Evidence empty; a deployed-env run fills them'
                         ' (local evidence lives in the AI doc). Nothing was published.')
    if kind == 'testing-ai':
        if not neg:
            raise SystemExit(f'{path} has no negative row: the AI doc covers every positive and negative case (templates.md "{tpl}"). Nothing was published.')
        return   # published every loop round: it is the loop's record
    ok, ev = local_pass(scope)
    if not ok:
        raise SystemExit(f'{kind} of {scope} refused: its local test loop is {"at " + repr(ev) if ev else "not recorded"}, not PASS.'
                         f' Run the loop until every case passes, then `crafty.ps1 checkpoint -Step loop -Item {scope} -Evidence "round <n> PASS"`.'
                         ' Nothing was published.')


def publish(key, title, path, parent=None, mode=None, label='', run=None):
    """Publish or update by key: the first call creates the doc, later calls update the same doc (append: a dated round on top,
    earlier rounds below; replace: the new text only). run = {id: {result, evidence}} of a deployed-env run (pokey finalize on
    <task>:testing-doc): fills the human doc's Result / Evidence and adds the report as a dated '<env> run' section; no human
    doc yet -> the report is published as <scope>:qa-report."""
    scope, _, kind = key.rpartition(':')
    if not scope or not kind:
        raise SystemExit(f'--key {key!r}: use <task or run>:<kind>, e.g. 86abc:testing-doc')
    with open(path, encoding='utf-8') as fh:
        body = fh.read()
    if run is not None and not _pub_read(key).get('rounds'):
        key, kind, run = f'{scope}:qa-report', 'qa-report', None
    if kind in ('testing-doc', 'testing-ai') and run is None:
        _check_doc(kind, scope, path, body)
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
                                 ' "Testing doc (AI)"): one row per loop round. Nothing was published.')
            lost = [r for r in had or [] if r not in have]
            if lost:
                raise SystemExit(f'{path} dropped Rounds row(s) {", ".join(lost)} of the published doc: rounds are appended, earlier rows stay. Nothing was published.')
            if have is None:
                print(f'[publish] {key}: no Rounds table (a doc from before it): add one from templates.md "Testing doc (AI)"', file=sys.stderr)
        new = {'at': time.strftime('%Y-%m-%d %H:%M'), 'seq': time.time(), 'label': label, 'ext': os.path.splitext(path)[1].lower(), 'body': body}
        stale = bool(rounds and runs) and ((runs[-1]['seq'] > rounds[-1]['seq']) if 'seq' in runs[-1] and 'seq' in rounds[-1] else runs[-1]['at'] >= rounds[-1]['at'])
        if run is not None:
            runs.append(dict(new, cells=run))
        elif kind in ('testing-doc', 'testing-ai') and rounds and rounds[-1]['body'] == body and not stale:
            pass   # the same text again (finish after the last loop round): no second round
        else:
            rounds = (rounds if (mode or PUB_KINDS.get(kind, 'replace')) == 'append' else []) + [new]
        text, ext = _compose(rec.get('title') or title, rounds, runs)
        out = os.path.join(kit_path('docs', create=True), re.sub(r'[^\w.-]+', '_', key) + ext)
        with open(out, 'w', encoding='utf-8', newline='') as fh:
            fh.write(text)
        own = {'markdown': out, 'html': os.path.splitext(out)[0] + '.doc.html'}.get(REPORT_TYPE)   # kept types: one file per key, never per title
        url = make_doc(rec.get('title') or title, out, parent, rec.get('url') or own)
        if rec.get('url') and url != rec['url']:
            print(f'[publish] {key}: reports.type {REPORT_TYPE} could not update {rec["url"]} in place: new link {url}', file=sys.stderr)
        _pub_write(key, {**rec, 'key': key, 'title': rec.get('title') or title, 'url': url, 'type': REPORT_TYPE,
                         'updated': new['at'], 'rounds': rounds, 'runs': runs})
    return url


R = ADAPTERS.setdefault('report', {})   # gdocs (Google Doc + Drive evidence): goody report-gdocs
# adapter:report/markdown: the file, kept (an earlier publish: the same file)
R['markdown'] = {'publish': lambda a: keep_doc(a['title'], a['path'], a['keep'], a.get('url'))}
# adapter:report/html: Markdown -> HTML (md_to_html), kept
R['html'] = {'publish': lambda a: keep_doc(a['title'], _html_of(a), a['keep'], a.get('url'))}


# adapter:report/command: reports.command with {title} {path} {parent} {url} (an earlier publish: update it); last output word = the URL
def _command(a):
    c = RCFG.get('command') or sys.exit('reports.type command needs reports.command')
    for k, v in (('title', a['title']), ('path', a['path']), ('parent', a['parent'] or a['keep'] or ''), ('url', a.get('url') or '')):
        c = c.replace('{' + k + '}', _q(v))
    r = subprocess.run(c, shell=True, capture_output=True, text=True, errors='replace', timeout=300)
    u = (r.stdout.split() or [''])[-1]
    return u if u and not r.returncode else sys.exit(f'reports.command failed (exit {r.returncode}): {(r.stdout + r.stderr)[-300:]}')


R['command'] = {'publish': _command}
# adapter-end:report


# ---- plugins: skills/crafty/adapters/*.py (installed goodies)
def load_plugins(folder=os.path.join(KIT, 'adapters')):
    """Each skills/crafty/adapters/*.py (an installed goody) gets this module in register(dt) and adds adapters or verbs."""
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
    refused('a missing body file is refused', lambda: _body('no-such-body.md'), 'file not found')
    expect('multi-line body text passes', _body('a\nb') == 'a\nb')
    refused('merge: a repo name instead of a worktree folder is refused', lambda: remote('no-such-checkout-x1'), 'not a folder')
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
        calls.clear(); g['_host'] = lambda verb, **a: calls.append((verb, a)) or {'raw': 'null'}
        res = auto_merge('.', '7', max_wait=0)
        expect('no MR state: mr.get retried once, WAIT names the project and the reply', merge_word(res) == 'WAIT' and 'g/r' in res
               and "'raw': 'null'" in res and [v for v, _ in calls] == ['mr.get', 'mr.get'])
        def nd(body):   # one fake per case: its merged state carries from mr.merge to the re-read
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
    tf = os.path.join(KIT, 'templates.md')
    mrt = re.search(r'(?ms)^## MR body\n.*?```markdown\n(.*?)```', open(tf, encoding='utf-8').read()).group(1) if os.path.isfile(tf) else '## How tested\n| Check | Result |\n'
    expect('MR body: the template\'s How tested is a table, Links has bold labels and a [text](url) doc link the merge gate reads; a bullet list is flagged',
           _how_tested_table(mrt) and not _how_tested_table('## How tested\n- tests pass\n')
           and (not os.path.isfile(tf) or ('- **Testing doc:** [open](<url>)' in mrt and DOC_LINK.search(mrt.replace('<url>', 'https://d/1')))))
    cfg0 = dict(CFG); CFG.clear(); CFG['gitHostType'] = 'github'
    expect('gitHostType, no gitHost: any origin', host_kind('git.corp.example') == 'github'); CFG.update(cfg0)
    _report_selftest(expect)
    _publish_selftest(expect, refused)
    print(f'{fails} failure(s)')
    return 1 if fails else 0


def _publish_selftest(expect, refused):
    """publish by key, the local-loop gate, both doc shapes, a QA run filling the AI doc, the links block, finish, MR reuse,
    evidence folder reuse (markdown type, stubbed tracker and host)."""
    g, tmp = globals(), tempfile.mkdtemp()
    saved = {k: g[k] for k in ('REPORT_TYPE', 'kit_path', '_tracker', 'task', 'PROSE_OK', 'remote', '_run', '_host')}
    w = lambda p, t: open(p, 'w', encoding='utf-8').write(t) and p

    def kp(n, create=False):
        p = os.path.join(tmp, n); os.makedirs(p, exist_ok=True); return p
    try:
        g.update(REPORT_TYPE='markdown', kit_path=kp, PROSE_OK='selftest')
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
        if os.path.isfile(tf):   # a full kit (goody test kits copy scripts only)
            tpl = open(tf, encoding='utf-8').read()
            blk = lambda n: re.search(rf'(?ms)^## {re.escape(n)}\n.*?```markdown\n(.*?)```', tpl).group(1)
            expect('templates: the AI doc has negative rows and its case table; the human doc has positive rows only',
                   '| negative |' in blk('Testing doc (AI)') and AI_TABLE.search(blk('Testing doc (AI)')) and ROUNDS_TABLE.search(blk('Testing doc (AI)')) and CHECKS_TABLE.search(blk('Human testing doc'))
                   and 'negative' not in blk('Human testing doc').lower())
            long_cell = doc.replace('Newest first.', ' '.join(['word'] * 30) + '.')
            expect('prose: a table doc passes (cell words, no table-syntax findings); a 30-word cell sentence is a finding',
                   not prose('testing-doc', doc) and any('30 words' in f for f in prose('testing-doc', long_cell)))
        h = md_to_html(doc.replace('| | |\n', '| PASS | ![T1: list](https://img/1.png "900") |\n').replace('1. Open the list.', 'Run `tool check -Step test -Tests ALongClassNameSmokeTest`')
                       + '```\n{"a": 1}\n```\n')
        th = re.findall(r'<th style="([^"]*)"><b>([^<]*)</b></th>', h)
        expect('md_to_html (the gdocs upload): tables stay HTML tables, header bold + shaded, widths by role (# 5, Steps 40, Expected 25,'
               ' Result 10, Evidence 20), cells padded and top-aligned, images inline and capped at 600 px',
               [(n, re.search(r'width:([\d.]+)%', s)[1]) for s, n in th[3:8]] == [('#', '5.0'), ('Steps', '40.0'), ('Expected', '25.0'), ('Result', '10.0'), ('Evidence', '20.0')]
               and all(HEAD_CSS in s for s, _ in th) and re.search(rf'<td style="{CELL_CSS}"><p><img src="https://img/1.png" width="600"', h) and '| T1 |' not in h)
        expect('md_to_html: backtick spans and fenced blocks are monospace on grey; text outside them stays plain; an unknown table'
               ' gets no widths, an AI table sums to 100',
               f'Run <span style="{CODE_CSS}">tool check -Step test -Tests ALongClassNameSmokeTest</span>' in h and f'<pre style="{CODE_CSS}">{{&quot;a&quot;: 1}}</pre>' in h
               and h.count(CODE_CSS) == 2 and f'<span style="{CODE_CSS}">src/**/a/**</span>' in md_to_html('`src/**/a/**`') and col_widths(['Name', 'Owner']) is None and round(sum(col_widths(_cells(ait.split('\n')[0]))), 1) == 100.0)
        refused('testing-doc: local screenshots or results in the human doc -> refused', lambda: publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'hi.md'), doc.replace('| | |\n', '| PASS | |\n'))), 'evidence or results')
        goals = w(os.path.join(tmp, 'g.md'), '# Testing goals: T9 X\n## Goals (what must be true)\n| G1 |\n')
        refused('testing-doc: no "| # | Steps | Expected | Result | Evidence |" table -> refused', lambda: publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'h0.md'), '# Testing: X\n## Checks\n### T1 — s\n')), 'no case table')
        refused('testing-doc: a negative row -> refused (human = positive cases)', lambda: publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'hn.md'), doc.replace('| T1 |', '| T1 | negative |'))), 'negative row')
        refused('testing-ai: no negative row -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'a0.md'), aidoc.replace('negative', 'positive'))), 'no negative row')
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
        body = open(u2, encoding='utf-8').read()
        expect('publish by key: round 2 updates the same doc, newest version on top, earlier rounds dated below', u1 == u2 and
               body.index('| T2 |') < body.index('## Round 1') < body.index('| T1 |') and _pub_read('T9:testing-doc')['url'] == u1)
        ix = state_read(os.path.join(kp('tasks'), 'T9.json')) or {}
        expect('publish by key: the task index points at the doc (docs.testing-doc, schemaVersion 1)', ix.get('docs', {}).get('testing-doc', {}).get('url') == u1 and ix.get('schemaVersion') == 1)
        refused('testing-ai: no Rounds table -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'a1.md'), aidoc.split('Rounds:')[0])), 'no Rounds table')
        refused('testing-ai: a round that drops an earlier Rounds row -> refused', lambda: publish('T9:testing-ai', 'X', w(os.path.join(tmp, 'a3.md'), aidoc.replace('| 1 | 2026-10-29', '| 2 | 2026-10-30'))), 'dropped Rounds row(s) 1')
        a2 = aidoc.replace('| A1 | positive | GET /list | 200, newest first | |', '| A1 | positive | GET /list | 200, newest first | PASS |') + '| 2 | 2026-10-30 | A1-A3 | 3 PASS | none | def456 | A3 PASS |\n'
        a2p = w(os.path.join(tmp, 'a2.md'), a2); ua2 = publish('T9:testing-ai', 'X', a2p, label='loop round 2', mode='replace')
        ab = open(ua2, encoding='utf-8').read()
        expect('testing-ai: round 2 updates the same doc, round 1 kept whole below (its rows, its Rounds row); --mode replace ignored',
               ua2 == ua and ab.index('| 2 | 2026-10-30') < ab.index('## Round 1') < ab.rindex('| A1 | positive | GET /list | 200, newest first | | |') and ab.count('| 1 | 2026-10-29') == 2)
        rep = w(os.path.join(tmp, 'r.md'), '# QA\n## Results\n| Check | Result | Observed | Evidence |\n|---|---|---|---|\n| T2 | PASS | ok | |\n')
        expect('the human doc starts with Result / Evidence empty', _table_rows(open(u2, encoding='utf-8').read())[0][0] == ('T2', '', ''))
        ur = publish('T9:testing-doc', 'X', rep, label='stg', run={'T2': {'result': 'PASS', 'evidence': '![T2: list](https://img/s2.png)'}})
        hb = open(ur, encoding='utf-8').read()
        expect('env run: the human doc (same link) gets Result / Evidence from the deployed run and a dated "<env> run" section; no report doc',
               ur == u1 and '| T2 | 1. Open the list. | Newest first. | PASS | ![T2: list](https://img/s2.png) |' in hb
               and hb.index('| T2 |') < hb.index('## stg run ') < hb.index('## Round 1') and not _pub_read('T9:qa-report'))
        ur2 = publish('T9:testing-doc', 'X', rep, label='stg', run={'T2': {'result': 'FAIL', 'evidence': 'x'}})
        hb2 = open(ur2, encoding='utf-8').read()
        expect('a retest run adds a second "<env> run" section; the first stays', ur2 == u1 and hb2.count('## stg run ') == 2 and '| T2 | 1. Open the list. | Newest first. | FAIL | x |' in hb2)
        u3 = publish('T9:testing-doc', 'X', w(os.path.join(tmp, 'h3.md'), doc.replace('| T1 |', '| T3 |')), label='fix round')
        hb3 = open(u3, encoding='utf-8').read()
        expect('a fix round after a run: a fresh version on top with Result / Evidence empty; both runs and the earlier rounds stay',
               u3 == u1 and '| T3 | 1. Open the list. | Newest first. | | |' in hb3 and hb3.count('## stg run ') == 2 and hb3.index('| T3 |') < hb3.index('## stg run '))
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
        expect('no_doc_links: prose and other fields kept, a links-only text empty',
               no_doc_links('Fixed the Testing goals: now 5 rows pass.\nDone') == 'Fixed the Testing goals: now 5 rows pass.\nDone\n'
               and no_doc_links('**MRs**: a · **Testing doc**: https://d · **After deploy**: seed') == '**MRs**: a · **After deploy**: seed\n'
               and no_doc_links('**Testing doc**: x · **After deploy**: y') == '**After deploy**: y\n' and no_doc_links('Testing doc (human): https://x') == '')
        expect('finish twice: no comment holds a doc link; the description holds both links once, on top',
               len(all_c) == 2 and not [x for x in all_c if 'Testing doc' in x or u1 in x or ua in x or '<link>' in x]
               and st['d'].startswith(f'**Testing doc (human):** {u1}\n\n**Testing doc (AI):** {ua}\n') and st['d'].count(u1) == 1 and st['d'].count(ua) == 1)
        hc = []
        g.update(remote=lambda w: ('gitlab', 'g/r'), _run=lambda *a, **k: 'f/x', _host=lambda v, **a: hc.append(v) or (
            [{'iid': 5, 'web_url': 'https://h/g/r/5'}] if v == 'mr.list' else {'web_url': 'https://h/g/r/5'}))
        u = mr_create('.', 'fix(x): y (T9)', '## Summary\n## Changes\n## How tested\n| Not run | nothing |\n## Risks\n## Links\n', 'main')
        expect('mr: an open MR from the branch is edited (mr.update), never a second one', u == 'https://h/g/r/5' and hc == ['mr.list', 'mr.update'])
        g.update(remote=saved['remote'], _run=saved['_run'], _host=saved['_host'])
        seen = []
        ADAPTERS['report']['markdown']['evidence'] = lambda a: seen.append(a['folder']) or {'folderId': a['folder'] or 'F1', 'folderLink': 'https://f/F1', 'files': {}}
        make_evidence('e', [], key='T9:evidence'); ev = make_evidence('e', [], key='T9:evidence')
        expect('evidence by key: the second run reuses the task folder', seen == [None, 'F1'] and ev['folderLink'] == 'https://f/F1')
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
        use('no-such-type', {}); err = io.StringIO()
        try:
            with _c.redirect_stderr(err):
                make_doc('T', md)
        except SystemExit as e:
            expect('a report type that is not installed: exit 3 + the goody add line', e.code == 3 and 'kitbag.py goody add report-no-such-type' in err.getvalue())
        for name, adapter in ADAPTERS['report'].items():
            if adapter.get('selftest'):
                use(name, {}); adapter['selftest'](expect, tmp, md)
    finally:
        g.update(saved); shutil.rmtree(tmp, ignore_errors=True)


# ---- CLI: argument checks, verb dispatch
def _cli():
    global REPORT_TYPE, PROSE_OK, OVERRIDE
    a = sys.argv[1:]
    cmd = a[0] if a else ''
    if cmd in VERBS:   # a plugin verb parses its own arguments
        stamp_fn(VERBS[cmd])
        sys.exit(VERBS[cmd](a[1:]) or 0)
    if cmd == 'lbcheck':
        extra_missing('devtools.py lbcheck (Liquibase check)', 'liquibase')
    if cmd == 'findings':
        extra_missing('devtools.py findings (module audits)', 'module-audit')
    # --help never becomes an id; unknown flags and missing args are usage errors
    use = [ln for ln in __doc__.splitlines() if re.match(rf'\s+python -X utf8 devtools\.py {re.escape(cmd)}\b', ln)] if cmd else []
    ARITY = {'comment': 2, 'finish': 3, 'mr': 3, 'merge': 2, 'doc': 2, 'evidence': 1, 'keepboth': 1, 'selftest': 0}
    FLAGS, opt = {}, {}
    for f in ('--type', '--parent', '--folder', '--files-from', '--key', '--mode', '--label', '--run', '--override') if cmd in ('doc', 'evidence') else ('--prose-ok', '--ai', '--override') if cmd in ('comment', 'finish', 'mr') else ():
        if f in a[1:-1]:
            i = a.index(f, 1); opt[f] = a[i + 1]; del a[i:i + 2]
        elif len(a) > 1 and a[-1] == f:   # an empty variable left the flag bare: name it, never "unknown option"
            print(f'devtools.py {cmd}: {f} needs a value (an empty variable?)\n' + '\n'.join(ln for ln in __doc__.splitlines() if re.match(rf'\s+python -X utf8 devtools\.py {re.escape(cmd)}\b', ln)), file=sys.stderr)
            sys.exit(2)
    REPORT_TYPE = (opt.get('--type') or REPORT_TYPE).lower()
    PROSE_OK = opt.get('--prose-ok') or ''
    OVERRIDE = opt.get('--override') or ''
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
        sys.exit(2)
    if cmd == 'comment':
        print(comment(a[1], _text(a[2]), a[3] if len(a) > 3 else 'comment-status'))
    elif cmd == 'finish':
        prior_gate(a[1], '', f'devtools.py finish {a[1]}')
        finish(a[1], a[2], _body(a[3]), *(a[4:5] or ['review']), ai=opt.get('--ai'))
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
        if not os.path.isfile(path):
            print(f'devtools.py doc: file not found: {path} - write it first (nothing was published)', file=sys.stderr)
            sys.exit(2)
        if opt.get('--mode') not in (None, 'append', 'replace'):
            print('devtools.py doc: --mode append|replace', file=sys.stderr)
            sys.exit(2)
        if (opt.get('--key') or '').rpartition(':')[2] in ('testing-doc', 'testing-ai') and not opt.get('--run'):   # a dev round's task doc
            prior_gate(opt['--key'].rpartition(':')[0], '', f"devtools.py doc --key {opt['--key']}")
        print(publish(opt['--key'], title, path, *(a[3:4] or [None]), mode=opt.get('--mode'), label=opt.get('--label') or '',
                      run=json.load(open(opt['--run'], encoding='utf-8-sig')) if opt.get('--run') else None) if opt.get('--key')
              else make_doc(title, path, *(a[3:4] or [])))
    elif cmd == 'evidence':
        ff = open(opt['--files-from'], encoding='utf-8-sig').read().splitlines() if opt.get('--files-from') else []   # one path per line: no command-line limit
        print(json.dumps(make_evidence(a[1], a[2:] + [x for x in ff if x.strip()], opt.get('--folder') or None, opt.get('--parent') or None, opt.get('--key'))))


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.exit(audited('devtools.py', sys.argv[1:], _cli))
