"""kit-audit: the mechanical half of the kit audit (skills/kit-audit/SKILL.md). The agent reads and judges; this script lists.

  python -X utf8 kit-audit.py setup   [--kit <dir>] [--fix]    # install state: clone, pre-push gate, excludes, runtime, hooks, ports, CLIs
  python -X utf8 kit-audit.py config  [--kit <dir>] [--fill]   # local config vs example, docs and the keys scripts read
  python -X utf8 kit-audit.py recover [--kit <dir>] [--fix]    # worktrees, kit branches, launches, board, tracked local files, runtime
  python -X utf8 kit-audit.py scan    [--kit <dir>]            # consistency + script pitfall candidates (run it on the audit worktree)
  python -X utf8 kit-audit.py stamp   [--kit <dir>]            # record the audit time (resets the weekly SessionStart nudge)
  python -X utf8 kit-audit.py due     [--kit <dir>]            # when the last audit ran and whether the next one is due
  any: --json <file> (findings as JSON)

--kit default: setup/config/recover/stamp/due = the LIVE clone (the main worktree of this script's kit repo, so running it from an
audit worktree still checks the installed kit); scan = the kit this script lives in (the worktree you are changing).
Output: one line per finding `<LEVEL> <CODE> <where>: <what> [-> <fix>]`. LEVEL: FIX (repaired now) | ACT (repair it) |
ASK (only the lead can supply it: hosts, ids, credentials) | WARN (judge it: candidate, not proof) | INFO.
--fix / --fill repair only what is safe and reversible; everything else is listed. Never prints a config VALUE (key paths only:
local files hold hosts, ids and passwords). Exit 1 when an ACT or ASK finding remains, else 0.
"""
import datetime, json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
OWN = os.path.abspath(os.path.join(HERE, '..', '..', '..'))   # <kit>/skills/kit-audit/scripts -> <kit>
sys.path.insert(0, os.path.join(OWN, 'skills', 'dev-kit', 'scripts'))
from kitpaths import kit_path, MAP  # noqa: E402

PAIRS = [('skills/dev-kit/kit.example.json', 'skills/dev-kit/kit.local.json', 'org settings (tracker, repos, reports, ...)'),
         ('skills/qa-kit/targets.example.json', 'skills/qa-kit/targets.local.json', 'QA targets and test logins (secrets)'),
         ('skills/android-swarm/swarm.example.json', 'skills/android-swarm/swarm.config.json', 'Android emulator lanes')]
# keys whose example value IS the documented default: --fill may write them (behaviour does not change, the file gets explicit)
SAFE_DEFAULTS = {'kitAudit.everyDays', 'reports.guide', 'cleanup.maxBrowserProfiles', 'supervise.ramActPct', 'supervise.minDiskFreeGB',
                 'build.mavenOffline', 'gate.heapMinGB'}
# subtrees whose keys are user-chosen names (or samples): never "missing" against the example
USER_MAPS = ('localEnv', 'repos', 'repoAliases', 'targets', 'linkFromByTarget', 'tracker.statuses', 'gate.startHeapGB', 'lanes', 'app')
PLACEHOLDER = re.compile(r'<[^>]+>|/path/to|example\.(com|app)|your[- ]', re.I)
AUTOMATIC = {'input', 'args', 'matches', 'error', 'host', 'home', 'pid', 'pwd', 'profile', 'this', 'event', 'sender', 'ofs',
             'psitem', 'iswindows', 'islinux', 'ismacos', 'executioncontext', 'myinvocation', 'psboundparameters', 'lastexitcode'}
LIBS = ('kitconfig.ps1', 'kitpaths.ps1', 'sysinfo.ps1', 'localenv-lib.ps1', 'report.ps1', '_config.ps1')

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
    if not os.path.isfile(path):
        return None, 'missing'
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f), None
    except ValueError as e:
        return None, f'invalid JSON ({e.msg}, line {e.lineno})'


def live_kit():
    """The installed clone: the main worktree of this script's repo (an audit worktree checks the live kit, not itself)."""
    rc, common, _ = git(OWN, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    if rc == 0 and common:
        main = os.path.dirname(os.path.normpath(common))
        if os.path.isfile(os.path.join(main, 'skills', 'dev-kit', 'scripts', 'kitpaths.json')):
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


def read(kit, rel):
    try:
        with open(os.path.join(kit, rel), encoding='utf-8', errors='replace') as f:
            return f.read().replace('\r\n', '\n')
    except OSError:
        return ''


def strip_ps_comments(text):
    text = re.sub(r'<#.*?#>', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    return '\n'.join(re.sub(r'(^|\s)#(?![>{]).*$', r'\1', l) if not re.search(r"""['"][^'"]*#""", l) else l for l in text.split('\n'))


def config_doc_keys(kit):
    doc = read(kit, 'skills/dev-kit/reference/configuration.md')
    return doc, set(re.findall(r'`([A-Za-z][\w]*(?:\.[\w]+)*)', doc))


def script_config_keys(kit, files):
    """Top-level kit.local.json keys the scripts read (Get-KitSetting / Get-KitValue / CFG.get / $cfg.<key>)."""
    keys = {}
    pats = [re.compile(r"Get-Kit(?:Setting|Value)\s+'([\w.]+)'"), re.compile(r"""CFG\.get\(\s*['"](\w+)"""),
            re.compile(r"""CFG\[['"](\w+)"""), re.compile(r'\$cfg\.(\w+)')]
    for f in files:
        if not f.endswith(('.ps1', '.py')) or f.startswith('skills/kit-audit/'):
            continue
        text = read(kit, f)
        loads = re.search(r"""Join-Path[^\n]*kit\.local\.json['"]""", text)
        use = pats if loads else pats[:3]   # $cfg.<key> means kit.local.json only where the file loads it
        for ln, line in enumerate(text.split('\n'), 1):
            for rx in use:
                for m in rx.finditer(line):
                    keys.setdefault(m.group(1), f'{f}:{ln}')
    return keys


# ------------------------------------------------------------------ setup
def cmd_setup(kit, fix):
    if not os.path.isdir(os.path.join(kit, '.git')) and not os.path.isfile(os.path.join(kit, '.git')):
        out('ACT', 'SETUP-CLONE', kit, 'not a git clone of the kit repo', 'docs/install.md: git clone <kit repo> <workspace>/.claude')
        return
    setup_ps = os.path.join(kit, 'skills', 'orchestrate', 'scripts', 'kit-setup.ps1')
    need_setup = []
    rc, hp, _ = git(kit, 'config', 'core.hooksPath')
    if hp != '.githooks':
        need_setup.append('core.hooksPath is not .githooks (pre-push gate off)')
    cfg, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.local.json'))
    rc, ex, _ = git(kit, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude')
    excl = open(ex, encoding='utf-8', errors='replace').read() if rc == 0 and os.path.isfile(ex) else ''
    miss = [p for p in ((cfg or {}).get('localOnly') or []) if f"/{p.replace(chr(92), '/').strip('/')}" not in excl]
    if miss:
        need_setup.append(f'{len(miss)} localOnly path(s) not in .git/info/exclude')
    for n in ('work', 'cache', 'logs'):
        if not os.path.isdir(kit_path(n, kit=kit)):
            need_setup.append(f'runtime folder {n}/ missing')
    if need_setup:
        if fix:
            rc, o, e = pwsh(setup_ps, timeout=120)
            out('FIX' if rc == 0 else 'ACT', 'SETUP-INSTALL', 'kit-setup.ps1', '; '.join(need_setup) + ('' if rc == 0 else f' (kit-setup failed: {e[:200]})'))
        else:
            out('ACT', 'SETUP-INSTALL', kit, '; '.join(need_setup), f'pwsh -File {setup_ps}')
    for ex_rel, loc_rel, what in PAIRS:
        if not os.path.isfile(os.path.join(kit, loc_rel)):
            lvl = 'ASK' if loc_rel.endswith('kit.local.json') else 'INFO'
            out(lvl, 'SETUP-CONFIG', loc_rel, f'missing ({what})', f'copy {ex_rel} and fill it (config step lists the keys)')
    # hooks: every script exists; the synchronous SessionStart ones run clean, fast, and print valid JSON or nothing
    sj, err = load_json(os.path.join(kit, 'settings.json'))
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
                path = os.path.join(kit, rel)
                if not os.path.isfile(path):
                    out('ACT', 'SETUP-HOOKS', f'settings.json {event}', f'{rel} does not exist')
                    continue
                if event != 'SessionStart' or h.get('async'):
                    continue
                extra = [a for a in h.get('args', []) if a.startswith('-') and a not in ('-NoProfile', '-NonInteractive', '-ExecutionPolicy', '-File')]
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
    sl = os.path.join(kit, 'settings.local.json')
    if os.path.isfile(sl) and load_json(sl)[1]:
        out('ACT', 'SETUP-CONFIG', 'settings.local.json', load_json(sl)[1])
    # Codex / Antigravity ports and their deployed copies at the workspace root
    pk = os.path.join(kit, 'skills', 'orchestrate', 'scripts', 'port-kit.py')
    if os.path.isfile(pk):
        rc, o, e = run([py(), '-X', 'utf8', pk, '--check'], timeout=60)
        if rc:
            out('ACT', 'SETUP-PORTS', 'port-kit.py --check', (o or e)[:300], f'python -X utf8 {pk} (in the clone that changed, then commit)')
    ws = os.path.dirname(kit)
    for n in ('AGENTS.md', 'GEMINI.md'):
        src, dst = os.path.join(kit, n), os.path.join(ws, n)
        if os.path.isfile(src) and (not os.path.isfile(dst) or read(kit, n) != read(ws, n)):
            out('WARN', 'SETUP-PORTS', f'<workspace>/{n}', 'missing or differs from the kit copy (Codex/Antigravity read this one)', f'python -X utf8 {pk}')
    # CLIs: present and logged in (check only; never log in from here)
    for exe in ('git', 'pwsh', 'node'):
        if not shutil.which(exe):
            out('ACT', 'SETUP-CLI', exe, 'not on PATH (the kit needs it)')
    tt = (os.environ.get('KIT_TRACKER_TYPE') or get(cfg, 'tracker.type') or 'clickup').lower()
    need = {'clickup': ['clickup'], 'github': ['gh'], 'gitlab': ['glab'], 'jira': [], 'none': []}.get(tt, [])
    host_cli = 'gh' if 'github' in str(get(cfg, 'gitHost') or '') else 'glab'
    for exe in sorted(set(need + [host_cli])):
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


# ------------------------------------------------------------------ config
def cmd_config(kit, fill):
    doc, documented = config_doc_keys(OWN)
    for ex_rel, loc_rel, what in PAIRS:
        ex, _ = load_json(os.path.join(OWN, ex_rel))
        loc, err = load_json(os.path.join(kit, loc_rel))
        if err == 'missing':
            if loc_rel.endswith('kit.local.json'):
                out('ASK', 'CONFIG-FILE', loc_rel, f'missing ({what})', f'copy {ex_rel}; the lead fills org values')
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
                out('ACT', 'CONFIG-TYPE', f'{loc_rel} {p}', f'is {type(lv).__name__}, expected {type(ev).__name__} (as in {os.path.basename(ex_rel)})')
        for p in key_paths(loc):
            top = p.split('.')[0]
            if get(ex, p) is None and p not in documented and f'`{p}' not in doc and not any(p.startswith(m + '.') for m in USER_MAPS) \
                    and top not in ('default', 'browser', 'keepFreeGB'):
                out('WARN', 'CONFIG-UNKNOWN', f'{loc_rel} {p}', 'key not in the example nor configuration.md: a typo, or an undocumented key a script reads?')
        if changed:
            bak = os.path.join(kit, loc_rel) + time.strftime('.bak-%Y%m%d-%H%M%S')
            shutil.copyfile(os.path.join(kit, loc_rel), bak)
            with open(os.path.join(kit, loc_rel), 'w', encoding='utf-8') as f:
                json.dump(loc, f, indent=2, ensure_ascii=False)
                f.write('\n')
            out('INFO', 'CONFIG-DEFAULT', loc_rel, f'written (backup {os.path.basename(bak)}: delete it once checked)')
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
            out('ACT', 'CONFIG-UNDOC', where, f'script reads kit.local.json "{key}", not documented in configuration.md (nor kit.example.json)')


def config_rules(kit, c):
    """Values a feature in use needs and no default can supply: ASK the lead (key paths only, never values)."""
    tt = (os.environ.get('KIT_TRACKER_TYPE') or get(c, 'tracker.type') or 'clickup').lower()
    if tt not in ('clickup', 'github', 'gitlab', 'jira', 'none'):
        out('ACT', 'CONFIG-VALUE', 'kit.local.json tracker.type', 'not one of clickup / github / gitlab / jira / none')
    if tt in ('github', 'gitlab') and not get(c, 'tracker.repo'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json tracker.repo', f'tracker.type {tt} needs owner/name or group/project')
    rt = (os.environ.get('KIT_REPORT_TYPE') or get(c, 'reports.type') or ('gdocs' if shutil.which('gws') else 'markdown')).lower()
    if rt == 'gdocs' and not c.get('driveParent'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json driveParent', 'reports.type gdocs needs the Drive folder id for guides and evidence')
    if not c.get('orgTerms'):
        out('ASK', 'CONFIG-NEED', 'kit.local.json orgTerms', 'empty: the pre-push org-term gate checks nothing; the lead lists org, product, host and tenant names')
    for p in c.get('localOnly') or []:
        if not os.path.exists(os.path.join(kit, p)):
            out('WARN', 'CONFIG-VALUE', f'kit.local.json localOnly {p}', 'path does not exist in the clone (stale entry?)')
    for k in ('reposRoot',):
        if c.get(k) and not os.path.isdir(os.path.expanduser(str(c[k]))):
            out('ACT', 'CONFIG-VALUE', f'kit.local.json {k}', 'folder does not exist on this machine')
    for i, root in enumerate(c.get('worktreeRoots') or []):
        if root and not os.path.isdir(os.path.dirname(os.path.abspath(os.path.expanduser(str(root))))):
            out('ACT', 'CONFIG-VALUE', f'kit.local.json worktreeRoots[{i}]', 'its parent folder does not exist on this machine')
    for i, r in enumerate(c.get('repos') or []):
        w = f'kit.local.json repos[{i}]'
        if not isinstance(r, dict):
            out('ACT', 'CONFIG-TYPE', w, 'must be an object')
            continue
        for k in ('name', 'checkout', 'target'):
            if not r.get(k):
                out('ASK' if k != 'name' else 'ACT', 'CONFIG-NEED', f'{w}.{k}', 'missing')
        if r.get('checkout') and not os.path.isdir(os.path.expanduser(str(r['checkout']).replace('<workspace>', os.path.dirname(kit)))):
            out('ACT', 'CONFIG-VALUE', f'{w}.checkout', 'folder does not exist on this machine')
        for k in ('linkFrom',):
            if r.get(k) and not os.path.isdir(os.path.expanduser(str(r[k]))):
                out('ACT', 'CONFIG-VALUE', f'{w}.{k}', 'folder does not exist (wt.ps1 new fails)')
        for t, d in (r.get('linkFromByTarget') or {}).items():
            if d and not os.path.isdir(os.path.expanduser(str(d))):
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
                if s.get('key') and not os.path.isfile(os.path.expanduser(str(s['key']))):
                    out('ACT', 'CONFIG-VALUE', f'{dw}.ssh.key', 'key file not found on this machine')
    le = c.get('localEnv') or {}
    ports = {}
    for env, e in (le.get('envs') or {}).items():
        for s in (e or {}).get('services') or []:
            if s.get('port') and not s.get('external'):   # external infra (a DB server) may be shared by several envs
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
    if get(s, 'app.appDir') and not os.path.isdir(os.path.expanduser(str(get(s, 'app.appDir')))):
        out('ACT', 'CONFIG-VALUE', 'swarm.config.json app.appDir', 'folder does not exist on this machine')


# ------------------------------------------------------------------ recover
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
    main = os.path.normcase(os.path.abspath(kit))
    in_wt = set()
    for w in wts:
        path = w.get('worktree', '')
        br = str(w.get('branch', '')).replace('refs/heads/', '')
        if not path or os.path.normcase(os.path.abspath(path)) == main or 'prunable' in w:
            continue
        in_wt.add(br)
        _, wd, _ = git(path, 'status', '--porcelain')
        rc_m, _, _ = git(kit, 'merge-base', '--is-ancestor', br or 'HEAD', 'origin/main')
        _, ahead, _ = git(kit, 'rev-list', '--count', f'origin/main..{br}') if br else (0, '?', '')
        _, remote, _ = git(kit, 'ls-remote', '--heads', 'origin', br, timeout=60) if br else (0, '', '')
        idle_h = (time.time() - max((os.path.getmtime(os.path.join(path, f)) for f in os.listdir(path)), default=0)) / 3600 if os.path.isdir(path) else 99
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
    cfg, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.local.json'))
    lo = [p.replace('\\', '/').strip('/') for p in ((cfg or {}).get('localOnly') or [])]
    bad = sorted(set([f for f in ig.splitlines() if f] + [f for f in tracked(kit) if '.local.' in os.path.basename(f) or any(f == p or f.startswith(p + '/') for p in lo)]))
    for f in bad:
        out('ACT', 'RECOVER-TRACKED-LOCAL', f, 'tracked although git-ignored / local-only (it is published on push)',
            f'git -C {kit} rm --cached -- {f} in a kit commit (the lead confirms; the file stays on disk)')
    # launch records, board entries, product worktrees, runtime size
    ld = kit_path('launches', kit=kit)
    for f in sorted(os.listdir(ld)) if os.path.isdir(ld) else []:
        r, err = load_json(os.path.join(ld, f))
        if err or not isinstance(r, dict):
            out('ACT', 'RECOVER-LAUNCH', f, f'unreadable launch record ({err})', 'delete it')
        elif not r.get('completed'):
            age = (time.time() - os.path.getmtime(os.path.join(ld, f))) / 3600
            out('WARN', 'RECOVER-LAUNCH', r.get('runId', f), f'workflow launch with no completion, {age:.0f} h old ({os.path.basename(str(r.get("script", "")))})',
                'still running in a live session? leave it; dead -> resume (orchestrate E6) or launch-record.ps1 -Done -RunId <id>')
    bd = kit_path('board', kit=kit)
    for f in sorted(os.listdir(bd)) if os.path.isdir(bd) else []:
        p = os.path.join(bd, f)
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
                e['leftBy'] = 'kit-audit (no heartbeat > 12 h)'
                with open(p, 'w', encoding='utf-8') as fh:
                    json.dump(e, fh, indent=2)
                out('FIX', 'RECOVER-BOARD', f, f'stale board entry {e.get("agent")} ({e.get("run")}) marked left ({age_h:.0f} h without a heartbeat)')
            else:
                out('WARN', 'RECOVER-BOARD', f, f'board entry {e.get("agent")} ({e.get("run")}) has no heartbeat for {age_h:.1f} h',
                    'supervise.ps1 -AutoFix closes finished workflow agents; > 12 h: kit-audit.py recover --fix marks it left')
    for root in (cfg or {}).get('worktreeRoots') or []:
        root = os.path.expanduser(str(root))
        for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            gp = os.path.join(root, d, '.git')
            if os.path.isfile(gp):
                gd = open(gp, encoding='utf-8', errors='replace').read().replace('gitdir:', '').strip()
                if not os.path.isdir(gd):
                    out('ACT', 'RECOVER-ORPHAN', os.path.join(root, d), 'worktree folder whose repo record is gone (git cannot see or clean it)',
                        'check it holds nothing unpushed, then the lead deletes the folder; run git worktree prune in its repo')
    cl = os.path.join(kit, 'skills', 'orchestrate', 'scripts', 'cleanup.ps1')
    rc, o, e = pwsh(cl, *(['-Quiet'] if fix else ['-DryRun']), timeout=300)
    if rc == 124:
        out('WARN', 'RECOVER-CLEANUP', 'cleanup.ps1', 'did not finish within 5 min (git host lookups for many branches?): run it by hand with -DryRun')
    elif rc != 0:
        out('ACT', 'RECOVER-CLEANUP', 'cleanup.ps1', f'exit {rc}: {(e or o)[:200]}')
    elif o and not fix:
        out('INFO', 'RECOVER-CLEANUP', 'cleanup.ps1 -DryRun', f'{len(o.splitlines())} line(s) of clutter it would remove (--fix runs it; safe: it skips anything in use)')
    elif fix:
        out('FIX', 'RECOVER-CLEANUP', 'cleanup.ps1', 'ran (log: <runtime>/logs/cleanup.log)')
    rt = kit_path('runtime', kit=kit)
    size = 0
    for d, _, fs in os.walk(rt):
        for f in fs:
            try:
                size += os.path.getsize(os.path.join(d, f))
            except OSError:
                pass
    if size > 5 * 1024 ** 3:
        out('WARN', 'RECOVER-RUNTIME', rt, f'runtime holds {size / 1024 ** 3:.1f} GB', 'find the folder that grows; add a prune rule to cleanup.ps1')


# ------------------------------------------------------------------ scan
def cmd_scan(kit):
    files = tracked(kit) or []
    lint = os.path.join(kit, 'skills', 'orchestrate', 'scripts', 'kit-lint.py')
    tmp = os.path.join(kit_path('cache', create=True, kit=kit), 'kit-audit-lint.json')
    run([py(), '-X', 'utf8', lint, kit, '--warn', '--no-flow', '--json', tmp], timeout=120)
    lj, _ = load_json(tmp)
    for p in lj or []:
        out('ACT', f'LINT-{p["code"]}', p['where'], p['problem'])
    live = live_kit()
    kl = os.path.join(live, 'skills', 'dev-kit', 'kit.local.json')
    if os.path.isfile(kl):
        rc, o, _ = run([py(), '-X', 'utf8', lint, kit, '--no-flow', '--org-terms', kl], timeout=120)
        for l in o.splitlines():
            if l.startswith('ORG-TERM'):
                out('ACT', 'GENERIC-ORG-TERM', l.split()[1].rstrip(':'), l.split(':', 1)[1].strip())
    pk = os.path.join(kit, 'skills', 'orchestrate', 'scripts', 'port-kit.py')
    rc, o, e = run([py(), '-X', 'utf8', pk, '--check'], timeout=60)
    if rc:
        out('ACT', 'PORT-DRIFT', 'port-kit.py --check', (o or e)[:300], f'python -X utf8 {pk}')
    agents = {os.path.basename(f)[:-3] for f in files if re.match(r'agents/[^/]+\.md$', f)}
    for f in files:
        t = read(kit, f)
        if re.match(r'skills/[^/]+/LESSONS(\.local)?\.md$', f) and len(t.rstrip('\n').split('\n')) > 40:
            out('ACT', 'LESSONS-LONG', f, f'{len(t.rstrip().split(chr(10)))} lines (cap 40)', f'learn.ps1 -Skill {f.split("/")[1]} -Trim')
        if f.startswith('workflows/') and f.endswith('.js'):
            for m in re.finditer(r"agentType:\s*'([\w-]+)'", t):
                if m.group(1) not in agents:
                    out('ACT', 'WF-AGENT', f, f'spawns agentType {m.group(1)}, which has no agents/{m.group(1)}.md')
        if re.match(r'agents/[^/]+\.md$', f):
            tools = re.search(r'^tools:\s*(.+)$', t, re.M)
            sk = re.search(r'skills/([\w-]+)/SKILL\.md', t)
            if tools and sk:
                st = read(kit, f'skills/{sk.group(1)}/SKILL.md')
                tl = tools.group(1)
                if re.search(r'\.ps1\b', st) and not re.search(r'\b(Bash|PowerShell)\b', tl):
                    out('ACT', 'AGENT-TOOLS', f, f'its skill {sk.group(1)} runs scripts, but tools ({tl}) has neither Bash nor PowerShell')
                if re.search(r'\b(Edit|Write)\b', st) and 'never edits' not in t.lower() and not re.search(r'\b(Edit|Write)\b', tl) and 'read-only' not in t.lower():
                    out('WARN', 'AGENT-TOOLS', f, f'its skill mentions editing files, tools ({tl}) cannot edit')
    # config: example keys documented (nested), documented keys read by some script
    doc, documented = config_doc_keys(kit)
    ex, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.example.json'))
    for p in key_paths(ex or {}):
        if '.' in p and not any(p.startswith(m + '.') for m in USER_MAPS) and p not in documented and f'`{p}' not in doc:
            out('ACT', 'CONFIG-UNDOC', f'kit.example.json {p}', 'not documented in skills/dev-kit/reference/configuration.md')
    code = '\n'.join(read(kit, f) for f in files if f.endswith(('.ps1', '.py', '.mjs', '.js')))
    table = doc.split('### Tracker')[0]
    for key in sorted({m for m in re.findall(r'^\| `([A-Za-z][\w.]*)`', table, re.M)}):
        leaf = key.split('.')[-1]
        if not re.search(r'[\'".]' + re.escape(leaf) + r'\b', code):
            out('WARN', 'CONFIG-UNUSED', f'configuration.md {key}', 'documented, but no script seems to read it (dead key, or read under another name?)')
    reads = script_config_keys(kit, files)
    for key, where in sorted(reads.items()):
        top = key.split('.')[0]
        if top not in documented and f'`{top}' not in doc:
            out('ACT', 'CONFIG-UNDOC', where, f'script reads kit.local.json "{key}", not documented in configuration.md')
        elif ex is not None and top not in ex:
            out('WARN', 'CONFIG-EXAMPLE', where, f'"{top}" is documented but missing from kit.example.json')
    # generic: absolute machine paths
    for f in files:
        if f.startswith(('examples/', '.codex/', '.agents/')) or not f.endswith(('.ps1', '.py', '.js', '.mjs', '.md', '.json')):
            continue
        for ln, line in enumerate(read(kit, f).split('\n'), 1):
            if re.search(r'(?<![\w/])[A-Za-z]:[\\/](?:Users|Codebase|src|work|Projects)\b|/home/\w+/|/Users/\w+/', line) and not re.search(r'e\.g\.|example|<|//|^\s*#|Windows:', line):
                out('WARN', 'GENERIC-PATH', f'{f}:{ln}', 'absolute machine path: config key or derived path instead?')
    # script pitfall candidates (each is a lead to read, not a verdict)
    for f in files:
        t = read(kit, f)
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
    # one variable, two spellings, both ASSIGNED (e.g. a list $L and a loop $l): the second silently overwrites the first
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
        if os.path.basename(f) in LIBS and re.match(r'\s*exit\b', line):
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
            code = strip_ps_comments(read(kit, f))
            m = re.search(r'(?is)^\s*param\s*\((.*?)\)\s*$', code, re.M) or re.search(r'(?is)\bparam\s*\((.*?)\)\s*\n', code)
            if m:
                ps = {x.lower() for x in re.findall(r'\$(\w+)', m.group(1))} | {x.lower() for x in re.findall(r"Alias\('([^']+)'", m.group(1))}
                params.setdefault(os.path.basename(f), set()).update(ps)
    for f in files:
        if not f.endswith('.md') or f.startswith(('.codex/', '.agents/')) or f.endswith(('HISTORY.md',)):
            continue
        for ln, line in enumerate(read(kit, f).split('\n'), 1):
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


# ------------------------------------------------------------------ stamp / due
def last_audit(kit):
    p = kit_path('last-kit-audit', kit=kit)
    try:
        return datetime.datetime.fromisoformat(open(p, encoding='utf-8').read().strip()[:19])
    except (OSError, ValueError):
        return None


def cmd_stamp(kit):
    p = kit_path('last-kit-audit', create=True, kit=kit)
    now = datetime.datetime.now().isoformat(timespec='seconds')
    with open(p, 'w', encoding='utf-8') as f:
        f.write(now + '\n')
    out('FIX', 'AUDIT-STAMP', p, f'last kit audit = {now} (the SessionStart nudge resets)')


def cmd_due(kit):
    cfg, _ = load_json(os.path.join(kit, 'skills/dev-kit/kit.local.json'))
    every = get(cfg, 'kitAudit.everyDays')
    every = 7 if every is None else every
    last = last_audit(kit)
    if not every:
        out('INFO', 'AUDIT-DUE', kit, 'weekly audit nudge off (kitAudit.everyDays 0)')
    elif not last or (datetime.datetime.now() - last).days >= every:
        out('INFO', 'AUDIT-DUE', kit, f'due (last {last.date() if last else "never"}, every {every} days)')
    else:
        out('INFO', 'AUDIT-DUE', kit, f'not due (last {last.date()}, next {(last + datetime.timedelta(days=every)).date()})')


def main():
    a = sys.argv[1:]
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
    kit = os.path.abspath(kit) if kit else (OWN if cmd == 'scan' else live_kit())
    {'setup': lambda: cmd_setup(kit, fix), 'config': lambda: cmd_config(kit, fill), 'recover': lambda: cmd_recover(kit, fix),
     'scan': lambda: cmd_scan(kit), 'stamp': lambda: cmd_stamp(kit), 'due': lambda: cmd_due(kit)}[cmd]()
    order = {'FIX': 0, 'ACT': 1, 'ASK': 2, 'WARN': 3, 'INFO': 4}
    for x in sorted(findings, key=lambda x: (order[x['level']], x['code'], x['where'])):
        print(f"{x['level']:4} {x['code']} {x['where']}: {x['what']}" + (f" -> {x['fix']}" if x['fix'] else ''))
    n = {lv: sum(1 for x in findings if x['level'] == lv) for lv in order}
    print(f'kit-audit {cmd} ({kit}): ' + ', '.join(f'{v} {k}' for k, v in n.items() if v) if findings else f'kit-audit {cmd} ({kit}): nothing found')
    if js:
        with open(js, 'w', encoding='utf-8') as f:
            json.dump(findings, f, indent=1)
    sys.exit(1 if n['ACT'] or n['ASK'] else 0)


if __name__ == '__main__':
    main()
