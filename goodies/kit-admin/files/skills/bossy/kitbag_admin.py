"""kitbag goody kit-admin: kitty's tools - the install, config and recovery checks of agents/kitty.md steps 1-3, the step 4
scan, token cost, releases and the budget raise.

  python -X utf8 skills/bossy/kitbag.py audit setup [--fix] | config [--fill] | recover [--fix] | scan [--kit <dir>] [--json <file>]
  python -X utf8 skills/bossy/kitbag.py cost [<kit>] [--steps] [--json]   # start tokens per agent type, workflow prompts
  python -X utf8 skills/bossy/kitbag.py release [--tag] [--publish]        # next SemVer + notes from Conventional Commits
  python -X utf8 skills/bossy/kitbag.py budget raise -Reason "<why>"     # the token cap x1.1, only while over it

Installed by `kitbag.py goody add kit-admin` (or `goody sync`); kitbag.py loads it and shares its own names (out, run, git,
load_json, key_paths, manifest, cap_next, _sub_file).
Sections: L18 helpers · L60 setup · L169 config · L321 recover · L466 release · L517 budget-raise · L539 cost · L654 registry ·
  L658 scan
Exit codes: 0 ok · 1 an ACT or ASK finding remains, a refused raise, an unpublished release · 2 usage error.
"""
import datetime, json, os, re, shutil, subprocess, sys, tempfile, time
import os.path as osp

# ---- helpers: example config, pwsh, the live kit
OWN = KIT_DIR
# (example file or localFiles entry, local file, what it holds)
PAIRS = [('skills/crafty/kit.example.json', 'skills/crafty/kit.local.json', 'org settings (tracker, repos, reports, ...)'),
  ('localFiles:skills/pokey/targets.local.json', 'skills/pokey/targets.local.json', 'QA targets and test logins (secrets)'),
  ('localFiles:skills/phoney/swarm.config.json', 'skills/phoney/swarm.config.json', 'Android emulator lanes')]

def example_of(ex_rel):
    ex, err = load_json(osp.join(OWN, 'skills/crafty/kit.example.json'))
    if not ex_rel.startswith('localFiles:'):
        return {k: v for k, v in (ex or {}).items() if k != 'localFiles'}, err
    return ((ex or {}).get('localFiles') or {}).get(ex_rel[len('localFiles:'):]), err
# example value IS the default: --fill may write it
SAFE_DEFAULTS = {'kitAudit.everyDays', 'cleanup.maxBrowserProfiles', 'supervise.ramActPct', 'supervise.minDiskFreeGB',
    'build.mavenOffline', 'gate.heapMinGB'}
PLACEHOLDER = re.compile(r'<[^>]+>|/path/to|example\.(com|app)|your[- ]', re.I)
def pwsh(script, *a, timeout=120, stdin=''):
    exe = shutil.which('pwsh')
    if not exe:
        return 127, '', 'pwsh 7 not on PATH'
    return run([exe, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, *a], timeout=timeout, stdin=stdin)

def py():
    return sys.executable or shutil.which('python3') or shutil.which('python')

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

# ---- setup: audit setup, the install checks
def cmd_setup(kit, fix):
    if not osp.isdir(osp.join(kit, '.git')) and not osp.isfile(osp.join(kit, '.git')):
        out('ACT', 'SETUP-CLONE', kit, 'not a git clone of the kit repo', 'README "Install": git clone <kit repo> <workspace>/.claude')
        return
    setup_ps = osp.join(kit, 'skills', 'bossy', 'bossy.ps1')
    need_setup = []
    rc, hp, _ = git(kit, 'config', 'core.hooksPath')
    if hp != '.githooks':
        need_setup.append('core.hooksPath is not .githooks (pre-push gate off)')
    cfg, _ = load_json(osp.join(kit, 'skills/crafty/kit.local.json'))
    rc, ex, _ = git(kit, 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude')
    excl = open(ex, encoding='utf-8', errors='replace').read() if rc == 0 and osp.isfile(ex) else ''
    miss = [p for p in ((cfg or {}).get('localOnly') or []) if f"/{p.replace(chr(92), '/').strip('/')}" not in excl]
    if miss:
        need_setup.append(f'{len(miss)} localOnly path(s) not in .git/info/exclude')
    for n in ('work', 'cache', 'logs'):
        if not osp.isdir(kit_path(n, kit=kit)):
            need_setup.append(f'runtime folder {n}/ missing')
    pf = kit_path('kit-protect', kit=kit)   # bossy.ps1 setup records the kit origin's main / goodies protection
    st = [x for x in open(pf, encoding='utf-8', errors='replace').read().split('\n') if x.strip()] if osp.isfile(pf) else []
    bad = [x for x in st if not re.match(r'^\S+ (ok|set|skip)', x)] if st else ['unchecked']
    if bad:
        need_setup.append('origin main / goodies protection: ' + ', '.join(bad))
    if need_setup:
        if fix:
            rc, o, e = pwsh(setup_ps, 'setup', timeout=120)
            out('FIX' if rc == 0 else 'ACT', 'SETUP-INSTALL', 'bossy.ps1 setup', '; '.join(need_setup) + ('' if rc == 0 else f' (bossy.ps1 setup failed: {e[:200]})'))
        else:
            out('ACT', 'SETUP-INSTALL', kit, '; '.join(need_setup), f'pwsh -File {setup_ps} setup')
    for ex_rel, loc_rel, what in PAIRS:
        if not osp.isfile(osp.join(kit, loc_rel)):
            lvl = 'ASK' if loc_rel.endswith('kit.local.json') else 'INFO'
            out(lvl, 'SETUP-CONFIG', loc_rel, f'missing ({what})', 'bossy.ps1 setup -WriteLocal, then fill it (the config step lists the keys)')
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
    pk = osp.join(kit, 'skills', 'bossy', 'kitbag.py')
    if osp.isfile(pk):
        rc, o, e = run([py(), '-X', 'utf8', pk, 'port', '--check'], timeout=60)
        if rc:
            out('ACT', 'SETUP-PORTS', 'kitbag.py port --check', (o or e)[:300], f'python -X utf8 {pk} port (in the clone that changed, then commit)')
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
    hk = get(cfg, 'gitHostType') or next((k for k, rx in (('github', 'github'), ('bitbucket', 'bitbucket'), ('azure', r'dev\.azure|visualstudio'), ('gitea', 'gitea|forgejo|codeberg')) if re.search(rx, str(get(cfg, 'gitHost') or ''))), 'gitlab')
    host_cli = {'github': 'gh', 'gitlab': 'glab'}.get(hk)   # REST hosts need a token, no CLI
    for v in {'bitbucket': ['BITBUCKET_TOKEN'], 'azure': ['AZURE_DEVOPS_EXT_PAT'], 'gitea': ['GITEA_TOKEN']}.get(hk, []):
        if not os.environ.get(v):
            out('ASK', 'SETUP-AUTH', v, f'environment variable not set (git host {hk})')
    for exe in sorted(set(need + [host_cli] if host_cli else need)):
        if not shutil.which(exe):
            out('ASK', 'SETUP-CLI', exe, f'not on PATH (tracker.type {tt} / git host need it): install it and log in by hand')
            continue
        auth = {'gh': ['gh', 'auth', 'status'], 'glab': ['glab', 'auth', 'status']}.get(exe)
        if auth:
            rc, o, e = run([shutil.which(exe)] + auth[1:], timeout=30)
            if rc:
                out('ASK', 'SETUP-AUTH', exe, 'not logged in (auth status failed): the owner logs in by hand, never headlessly')
    envs = {'jira': ['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN'], 'jira-server': ['JIRA_BASE_URL'] + ([] if os.environ.get('JIRA_TOKEN') or (os.environ.get('JIRA_EMAIL') and os.environ.get('JIRA_API_TOKEN')) else ['JIRA_TOKEN']), 'linear': ['LINEAR_API_KEY'], 'azure': ['AZURE_DEVOPS_EXT_PAT'], 'youtrack': ['YOUTRACK_URL', 'YOUTRACK_TOKEN']}
    for v in envs.get(tt, []):
        if not os.environ.get(v):
            out('ASK', 'SETUP-AUTH', v, f'environment variable not set (tracker.type {tt})')
    rt = (os.environ.get('KIT_REPORT_TYPE') or get(cfg, 'reports.type') or ('gdocs' if shutil.which('gws') else 'markdown')).lower()
    if rt == 'gdocs' and not shutil.which('gws'):
        out('ASK', 'SETUP-CLI', 'gws', 'reports.type gdocs needs the gws CLI on PATH, logged in')

# ---- config: audit config, missing org values
def cmd_config(kit, fill):
    doc, documented = config_doc_keys(OWN)
    for ex_rel, loc_rel, what in PAIRS:
        ex, _ = example_of(ex_rel)
        loc, err = load_json(osp.join(kit, loc_rel))
        if err == 'missing':
            if loc_rel.endswith('kit.local.json'):
                out('ASK', 'CONFIG-FILE', loc_rel, f'missing ({what})', 'bossy.ps1 setup -WriteLocal; the lead fills org values')
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

# ---- recover: audit recover, stopped work and leftovers
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
        tip = br or str(w.get('HEAD', ''))   # a detached worktree: its own HEAD commit, never the main clone's
        rc_m, _, _ = git(kit, 'merge-base', '--is-ancestor', tip, 'origin/main') if tip else (1, '', '')
        _, ahead, _ = git(kit, 'rev-list', '--count', f'origin/main..{tip}') if tip else (0, '?', '')
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
    cfg, _ = load_json(osp.join(kit, 'skills/crafty/kit.local.json'))
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
             'still running in a live session? leave it; dead -> resume (bossy E3) or bossy.ps1 launch -Done -RunId <id>')
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
                e['leftBy'] = 'kitbag audit recover (no heartbeat > 12 h)'
                with open(p, 'w', encoding='utf-8') as fh:
                    json.dump(e, fh, indent=2)
                out('FIX', 'RECOVER-BOARD', f, f'stale board entry {e.get("agent")} ({e.get("run")}) marked left ({age_h:.0f} h without a heartbeat)')
            else:
                out('WARN', 'RECOVER-BOARD', f, f'board entry {e.get("agent")} ({e.get("run")}) has no heartbeat for {age_h:.1f} h',
                 'bossy.ps1 supervise -AutoFix closes finished workflow agents; > 12 h: kitbag.py audit recover --fix marks it left')
    for root in (cfg or {}).get('worktreeRoots') or []:
        root = osp.expanduser(str(root))
        for d in sorted(os.listdir(root)) if osp.isdir(root) else []:
            gp = osp.join(root, d, '.git')
            if osp.isfile(gp):
                gd = open(gp, encoding='utf-8', errors='replace').read().replace('gitdir:', '').strip()
                if not osp.isdir(gd):
                    out('ACT', 'RECOVER-ORPHAN', osp.join(root, d), 'worktree folder whose repo record is gone (git cannot see or clean it)',
                     'check it holds nothing unpushed, then the lead deletes the folder; run git worktree prune in its repo')
    cl = osp.join(kit, 'skills', 'bossy', 'bossy.ps1')
    rc, o, e = pwsh(cl, 'cleanup', *(['-Quiet'] if fix else ['-DryRun']), timeout=300)   # without the verb: usage, exit 2
    if rc == 124:
        out('WARN', 'RECOVER-CLEANUP', 'bossy.ps1 cleanup', 'did not finish within 5 min (git host lookups for many branches?): run it by hand with -DryRun')
    elif rc != 0:
        out('ACT', 'RECOVER-CLEANUP', 'bossy.ps1 cleanup', f'exit {rc}: {(e or o)[:200]}')
    elif o and not fix:
        out('INFO', 'RECOVER-CLEANUP', 'bossy.ps1 cleanup -DryRun', f'{len(o.splitlines())} line(s) of clutter it would remove (--fix runs it; safe: it skips anything in use)')
    elif fix:
        out('FIX', 'RECOVER-CLEANUP', 'bossy.ps1 cleanup', 'ran (bossy.ps1 audit -Since 1h shows what it freed)')
    rt = kit_path('runtime', kit=kit)
    size = 0
    for d, _, fs in os.walk(rt):
        for f in fs:
            try:
                size += osp.getsize(osp.join(d, f))
            except OSError:
                pass
    if size > 5 * 1024 ** 3:
        out('WARN', 'RECOVER-RUNTIME', rt, f'runtime holds {size / 1024 ** 3:.1f} GB', 'find the folder that grows; add a prune rule to bossy.ps1 cleanup')


# ---- release: next SemVer + notes from Conventional Commits
def cmd_release(a):
    """Next vX.Y.Z + notes (breaking + Migration lines, features, fixes, retired lessons) from Conventional Commits since the last
    tag; prints only. --tag: annotated tag with the notes; --publish: also a GitHub release (gh, never logs in)."""
    kit = KIT_DIR
    last = git(kit, 'describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*')[1]
    rng = f'{last}..HEAD' if last else 'HEAD'
    log = git(kit, 'log', rng, '--no-merges', '--format=%h%x1f%s%x1f%b%x1e')[1]
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
        print(f'kitbag release: nothing since {last or "the first commit"}')
        return 0
    ver = f'v{major + 1}.0.0' if bump == 3 else f'v{major}.{minor + 1}.0' if bump == 2 else f'v{major}.{minor}.{patch + 1}'
    retired = [l[1:] for l in git(kit, 'log', rng, '-p', '--unified=0', '--format=', '--', 'LESSONS.md')[1].split('\n') if l.startswith('-- ')]
    notes = [f'# {ver} ({datetime.date.today().isoformat()})', '']
    for g, items in groups.items():
        if items:
            notes += [f'## {g}', *items, '']
    if retired:
        notes += ['## Retired lessons (bossy.ps1 learn -History)', *[f'- {x[2:]}' for x in retired[:200]], '']
    text = '\n'.join(notes)
    print(text)
    if '--tag' in a or '--publish' in a:
        nf = osp.join(kit_path('cache', create=True, kit=kit), f'release-{ver}.md')
        with open(nf, 'w', encoding='utf-8') as fh:
            fh.write(text)
        rc, _, err = git(kit, 'tag', '-a', ver, '-F', nf)
        print(f'tag {ver}: ' + (f'created (push it: git push origin {ver})' if not rc else err))
        if '--publish' in a and not rc:
            gh = shutil.which('gh')
            if not gh:
                print('kitbag release: gh not on PATH: the GitHub release was not published')
                return 1
            rc, o, err = run([gh, 'release', 'create', ver, '-F', nf, '--title', ver], cwd=kit)
            print(o or err)
            return rc
    return 0

# ---- budget-raise: the token cap x1.1, only over it
def budget_raise(kit, total, cap, flags):
    """budget raise -Reason "<why trimming cannot make room>" (kitbag.py budget hands over): only while the total is over the
    cap, multiplies the cap by 1.1, rounded to 1k, and prints the commit message carrying the reason (stored nowhere else)."""
    why = next((str(v).strip() for f, v in flags.items() if f.lower().lstrip('-') == 'reason'), '')
    if not why:
        print('budget raise: -Reason "<why trimming cannot make room>" is required', file=sys.stderr)
        return 2
    if total <= cap:
        print(f'budget raise: refused - the kit total {total} fits the cap {cap}: nothing to raise', file=sys.stderr)
        return 1
    new = cap_next(cap)
    bad = cap_problem(kit, new)
    if bad:
        print(f'budget raise: refused - {bad}', file=sys.stderr)
        return 1
    _sub_file(kit, PATHS_JSON, lambda t: re.sub(r'("totalTokens":\s*)\d+', lambda m: m.group(1) + str(new), t, count=1))
    print(f'cap {cap} -> {new} (kit total {total}); commit message: chore(kit): raise the token cap to {new} - {why}')
    if total > new:
        print(f'still over: {total} > {new}: trim more (one raise per commit)')
    return 0

# ---- cost: start tokens per agent type + workflow prompts (kitty step 8 after a workflow change)
# Runs every workflow under node with mock agents (one canned result per step label) and records each prompt's size.
COST_MJS = r'''import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const kit = (process.argv[2] || '.claude').replace(/[\\/]+$/, '')
const MR = (repo, n) => ({ url: `https://git.example.com/acme/${repo}/-/merge_requests/${n}`, repo, merged: false })
const report = (id) => ({ mrs: [MR('api', id === 'X2' ? 2 : 1)], worktrees: [`${id.toLowerCase()}-api`], done: ['A1'], deferred: [], needsLiveCheck: ['open the form and save'], seed: [], foreignHooks: [], summary: 'implemented, checks green', needsDecision: [], localTest: { status: 'PASS', env: 'shop r1', rounds: 1, failing: [], goalsDoc: 'goals.md' }, testerGuide: 'doc',
 changedLines: id === 'X2' ? 12 : 30, changedFiles: id === 'X2' ? ['src/auth/LoginService.java'] : ['web/src/order-form.ts'] })

function mock(label) {
 const [kind, rest = ''] = label.split(':'); const id = rest.split('@')[0]
 switch (kind) {
  case 'build': case 'fix': case 'ship': return report(id)
  case 'review': return { findings: id === 'X2' ? [{ mr: MR('api', 2).url, file: 'src/Order.java', line: 10, severity: 'blocking', problem: 'null check missing', fix: 'add it' }] : [] }
  case 'ci': return { done: true, mrs: [{ mr: MR('api', 1).url, status: 'success' }] }
  case 'learn': return { signals: 1, lessonsChanged: [] }
  case 'test': case 'retest': return { code: id, checks: [
   { id: 'T1', subtask_id: 't1', screen: 'Orders', result: 'PASS', what_was_done: 'saved', observed: 'saved', evidence: [`${id}-T1_01_saved.jpeg`] },
   { id: 'T2', subtask_id: 't1', screen: 'Orders', result: 'PASS_WITH_NOTE', what_was_done: 'opened', observed: 'label differs', evidence: [] },
   { id: 'T3', subtask_id: 't1', screen: 'Orders', result: 'FAIL', what_was_done: 'cancelled', observed: 'PUT /api/orders -> 500', evidence: [] }],
   findings: ['seed data was old'], setup_changes: [], data_created: [] }
  case 'audit': return { reclassify: [{ id: 'T2', defect: false, reason: 'cosmetic' }], newDefects: [] }
  case 'verify': return { verdicts: [{ id: 'T3', outcome: 'confirmed', observed: '500 again', evidence: [] }] }
  case 'close': case 'hold': case 'add-followups': return { ok: true, output: 'published' }
  case 'prepare': return { runDir: SAMPLE['testy'].runDir, items: 2, left: [{ id: 't3', reason: 'not live' }], summary: 'sample' }
  case 'load-run': return { json: JSON.stringify(SAMPLE['testy']) }
  case 'analyse': return { proposals: [{ file: `${kit}/skills/crafty/LESSONS.md`, change: 'add-lesson', text: 'x', evidence: '2 signals', occurrences: 2, confidence: 'high' }] }
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

const calls = []
for (const wf of Object.keys(SAMPLE)) {
 const src = readFileSync(join(kit, 'workflows', `${wf.split('#')[0]}.js`), 'utf8').replace(/^export const meta/m, 'const meta')
 const body = new Function('args', 'agent', 'pipeline', 'parallel', 'log', 'phase', `return (async () => {\n${src}\n})()`)
 const agent = async (prompt, opts = {}) => {
  calls.push({ wf, label: opts.label || '?', agentType: opts.agentType || '', model: opts.model || '', effort: opts.effort || '', bytes: Buffer.byteLength(prompt, 'utf8') })
  return mock(opts.label || '')
 }
 const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => { let r = it; for (const [i, s] of stages.entries()) r = i === 0 ? await s(it) : await s(r, it); return r }))
 const parallel = async (fns) => Promise.all(fns.map((f) => f()))
 await body(JSON.parse(JSON.stringify(SAMPLE[wf])), agent, pipeline, parallel, () => {}, () => {})
}
console.log(JSON.stringify({ calls }))
'''

def workflow_calls(kit):
    """Every agent() call of the sample workflow runs: {wf, label, agentType, model, effort, tokens}; [] without node."""
    node = shutil.which('node')
    if not node:
        return []
    with tempfile.TemporaryDirectory() as tmp:
        src = osp.join(tmp, 'cost.mjs')
        with open(src, 'w', encoding='utf-8') as fh:
            fh.write(COST_MJS)
        rc, o, e = run([node, src, kit], timeout=120)
    try:
        calls = json.loads(o).get('calls', [])
    except ValueError:
        print(f'kitbag cost: the workflow render failed (exit {rc}): {(e or o)[:300]}', file=sys.stderr)
        return []
    for c in calls:
        c['tokens'] = (c['bytes'] + 3) // 4
    return calls

def cmd_cost(a):
    """Start tokens (UTF-8 bytes / 4) per agent type (always-loaded files, agent definition, its skill, its LESSONS.md sections)
    plus each workflow run's prompts."""
    flags, rest = parse_opts(a)
    kit = osp.abspath(rest[0] if rest else KIT_DIR)
    tok = lambda s: (len(s.encode('utf-8')) + 3) // 4
    ftok = lambda rel: tok(read(osp.join(kit, rel)))
    k = load(kit)
    rules = [f for f in k.files if re.match(r'rules/[^/]+\.md$', f) and not f.endswith('.local.md') and 'paths' not in frontmatter(k.texts[f])]
    always = ftok('CLAUDE.md') + ftok('AGENTS.md') + sum(ftok(r) for r in rules)
    always += sum(tok(frontmatter(k.texts.get(f'skills/{s}/SKILL.md', '')).get('description', '')) for s in k.skills)
    lessons = read(osp.join(kit, 'LESSONS.md'))
    lesson_tokens = lambda name: tok((re.search(r'^## ' + re.escape(name) + r'\n(.*?)(?=^## |\Z)', lessons, re.S | re.M) or [''])[0])
    calls = workflow_calls(kit)
    if '--steps' in flags:
        for c in calls:
            print(f"{c['wf']:15} {c['label']:18} {c['agentType']:12} {c['model']:7} {c['effort']:6} {c['tokens']:6}")
        return 0
    rows = []
    for agent, m in (manifest(kit).get('agents') or {}).items():   # an agent reads its skill and the lessons of both
        skill = m.get('skill') or ''
        files = ftok(f'agents/{agent}.md') + (ftok(f'skills/{skill}/SKILL.md') if skill else 0)
        rows.append({'agent': f'{agent} (start)', 'always': always, 'files': files + sum(lesson_tokens(x) for x in {agent, skill} if x)})
    for wf in sorted({c['wf'] for c in calls}):
        cs = [c for c in calls if c['wf'] == wf]
        rows.append({'agent': f'run: {wf} ({len(cs)} steps)', 'always': always * len(cs), 'files': sum(c['tokens'] for c in cs)})
    for row in rows:
        row['total'] = row['always'] + row['files']
    if '--json' in flags:
        print(json.dumps(rows, indent=1))
        return 0
    print('| Agent / run | always-loaded | start files / prompts | total |\n|---|---:|---:|---:|')
    for row in rows:
        print(f"| {row['agent']} | {row['always']} | {row['files']} | {row['total']} |")
    return 0

# ---- registry: audit verbs, commands, args for kitbag.py
def aread(kit, rel):
    return read(osp.join(kit, rel))

# ---- scan: consistency and script pitfall candidates for agents/kitty.md step 4 (the agent proves each; moved from kitbag.py)
LIBS = ('lib.ps1',)   # dot-sourced: an exit there ends the caller
def config_doc_keys(kit):
    doc = section(read(osp.join(kit, 'README.md')), 'Configuration') or ''
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
        if not f.endswith(('.ps1', '.py')) or f.endswith('kitbag.py'):
            continue
        text = read(osp.join(kit, f))
        use = pats if re.search(r"""Join-Path[^\n]*kit\.local\.json['"]""", text) else pats[:3]   # $cfg.<key> only where kit.local.json is loaded
        for ln, line in enumerate(text.split('\n'), 1):
            for rx in use:
                for m in rx.finditer(line):
                    keys.setdefault(m.group(1), f'{f}:{ln}')
    return keys

def cmd_scan(kit):
    files = tracked(kit) or []
    k = load(kit)
    local = osp.join(main_clone(kit), 'skills', 'crafty', 'kit.local.json')
    terms = (load_json(local)[0] or {}).get('orgTerms') if osp.isfile(local) else None
    for code, where, problem in lint(k, graph(k), terms):
        out('ACT', ('GENERIC-' if code == 'ORG-TERM' else 'LINT-') + code, where, problem)
    if osp.samefile(kit, KIT_DIR) and 'port' in PLUGINS:   # ports (goody ports) are checked for the kit this file lives in
        with contextlib.redirect_stdout(io.StringIO()) as said:
            stale = PLUGINS['port'](['--check'])
        if stale:
            out('ACT', 'PORT-DRIFT', 'kitbag.py port --check', said.getvalue().strip()[:300], 'python -X utf8 skills/bossy/kitbag.py port')
    texts = {f: read(osp.join(kit, f)) for f in files}
    for f in sec_files(files):
        for ln, nm, n in sec_sizes(f, texts[f]):
            out('WARN', 'SECTION-BIG', f'{f}:{ln}', f'section "{nm}" is {n} lines (> {SEC_BIG})', 'split it with another ---- marker')
    for f in files:
        if re.match(r'agents/[^/]+\.md$', f):
            tools = re.search(r'^tools:\s*(.+)$', texts[f], re.M)
            sk = re.search(r'skills/([\w-]+)/SKILL\.md', texts[f])
            if tools and sk:
                st, tl = read(osp.join(kit, f'skills/{sk.group(1)}/SKILL.md')), tools.group(1)
                if re.search(r'\.ps1\b', st) and not re.search(r'\b(Bash|PowerShell)\b', tl):
                    out('ACT', 'AGENT-TOOLS', f, f'its skill {sk.group(1)} runs scripts, but tools ({tl}) has neither Bash nor PowerShell')
                if re.search(r'\b(Edit|Write)\b', st) and 'never edits' not in texts[f].lower() and not re.search(r'\b(Edit|Write)\b', tl) and 'read-only' not in texts[f].lower():
                    out('WARN', 'AGENT-TOOLS', f, f'its skill mentions editing files, tools ({tl}) cannot edit')
    # config: example keys documented, documented keys read
    doc, documented = config_doc_keys(kit)
    ex, _ = load_json(osp.join(kit, PATHS_JSON))
    for p in key_paths(ex or {}):
        if '.' in p and not any(p.startswith(m + '.') for m in USER_MAPS) and p not in documented and f'`{p}' not in doc:
            out('ACT', 'CONFIG-UNDOC', f'kit.example.json {p}', 'not documented in README "Configuration"')
    code = '\n'.join(t for f, t in texts.items() if f.endswith(('.ps1', '.py', '.mjs', '.js')))
    for key in sorted(set(re.findall(r'^\| `([A-Za-z][\w.]*)`', doc.split('### Tracker')[0], re.M))):
        if not re.search(r'[\'".]' + re.escape(key.split('.')[-1]) + r'\b', code):
            out('WARN', 'CONFIG-UNUSED', f'README Configuration {key}', 'documented, but no script seems to read it (dead key, or read under another name?)')
    for key, where in sorted(script_config_keys(kit, files).items()):
        top = key.split('.')[0]
        if top not in documented and f'`{top}' not in doc:
            out('ACT', 'CONFIG-UNDOC', where, f'script reads kit.local.json "{key}", not documented in README "Configuration"')
        elif ex is not None and top not in ex:
            out('WARN', 'CONFIG-EXAMPLE', where, f'"{top}" is documented but missing from kit.example.json')
    for f, t in texts.items():
        if not f.startswith(('examples/',) + GENERATED) and f.endswith(('.ps1', '.py', '.js', '.mjs', '.md', '.json')):
            for ln, line in enumerate(t.split('\n'), 1):
                if re.search(r'(?<![\w/])[A-Za-z]:[\\/](?:Users|Codebase|src|work|Projects)\b|/home/\w+/|/Users/\w+/', line) and not re.search(r'e\.g\.|example|<|//|^\s*#|Windows:', line):
                    out('WARN', 'GENERIC-PATH', f'{f}:{ln}', 'absolute machine path: config key or derived path instead?')
        if f.endswith('.ps1'):
            ps_pitfalls(f, t)
        elif f.endswith('.py'):
            for ln, line in enumerate(t.split('\n'), 1):
                if re.match(r'\s*except\s*:', line):
                    out('WARN', 'PY-BARE-EXCEPT', f'{f}:{ln}', 'bare except: hides real errors (KeyboardInterrupt too)')
                if re.search(r'(?<![\w.])open\(', line) and 'encoding' not in line and not re.search(r"""['"][rwax+]*b[rwax+]*['"]""", line):
                    out('WARN', 'PY-ENCODING', f'{f}:{ln}', 'open() without encoding= reads cp1252 on Windows')
    doc_flags(texts)

def ps_pitfalls(f, t):
    code = strip_ps_comments(t)
    lines = code.split('\n')
    for lb, b, a, la in ps_case(t):   # the second spelling overwrites the first
        out('WARN', 'PS-CASE', f'{f}:{lb}', f'${b} (line {lb}) is the same variable as ${a} (line {la}): PowerShell names are case-insensitive')
    for ln, line in enumerate(lines, 1):
        m = re.search(r'\$(\w+)\s*=(?![=~])', line)
        if m and m.group(1).lower() in AUTOMATIC - {'lastexitcode'} and not re.search(r'\[(ref)\]', line):
            out('WARN', 'PS-AUTOVAR', f'{f}:{ln}', f'assigns automatic variable ${m.group(1)} (silently overwritten / ignored)')
        if re.search(r'\.Substring\(\s*[^,()]+,\s*\d+\s*\)', line) and not re.search(r'Min\(|\.Length\s*-g[te]|-g[te]\s*\d|ToString\(|GetBytes|Guid', line):
            out('WARN', 'PS-SUBSTRING', f'{f}:{ln}', '.Substring(i, n) with a fixed n and no length guard on the line: throws on short strings')
        if osp.basename(f) in LIBS and re.match(r'\s*exit\b', line):
            out('WARN', 'PS-LIB-EXIT', f'{f}:{ln}', 'exit in a dot-sourced library ends the CALLER')
    pm = re.search(r'(?is)^\s*param\s*\((.*?)\)\s*$', code, re.M)
    if pm:
        for m in re.finditer(r'\[string\[\]\]\s*\$(\w+)', pm.group(1)):
            v = m.group(1)
            if not re.search(r'Split-KitList[^\n]*\$' + v + r'\b|\$' + v + r'\b[^\n]*-split', code, re.I):
                out('WARN', 'PS-FILE-ARRAY', f, f'[string[]]${v}: `pwsh -File` passes "a,b" as ONE string; use Split-KitList')
        for m in re.finditer(r'\$(input|args|host|error|matches|pid|home)\b', pm.group(1), re.I):
            out('ACT', 'PS-AUTOVAR', f, f'parameter ${m.group(1)} shadows an automatic variable')

def doc_flags(texts):
    """`<script>.ps1 -Flag` in Markdown where the script has no such parameter (docs that contradict scripts)."""
    params = {}
    for f, t in texts.items():
        if f.endswith('.ps1'):   # any verb's param block taking the flag counts
            for m in re.finditer(r'(?is)\bparam\s*\((.*?)\)\s*\n', strip_ps_comments(t)):
                ps = {x.lower() for x in re.findall(r'\$(\w+)', m.group(1))} | {x.lower() for x in re.findall(r"Alias\('([^']+)'", m.group(1))}
                params.setdefault(osp.basename(f), set()).update(ps)
    for f, t in texts.items():
        if not f.endswith('.md') or f.startswith(GENERATED) or f.endswith('LESSONS.md'):
            continue
        for ln, line in enumerate(t.split('\n'), 1):
            for span in re.findall(r'`([^`]+)`', line):
                for m in re.finditer(r'([\w-]+\.ps1)((?:\s+[^\s|;]+)*)', span):
                    s = m.group(1)
                    for flag in re.findall(r'(?<![\w-])-([A-Za-z]\w+)', m.group(2)) if s in params else []:
                        fl = flag.lower()
                        if fl not in ('file', 'noprofile', 'command', 'whatif', 'verbose', 'erroraction') and not any(p.startswith(fl) for p in params[s]):
                            out('WARN', 'DOC-FLAG', f'{f}:{ln}', f'`{s} -{flag}`: {s} has no such parameter')

AUDIT_VERBS = {'scan': lambda kit, flags: cmd_scan(kit), 'setup': lambda kit, flags: cmd_setup(kit, '--fix' in flags), 'config': lambda kit, flags: cmd_config(kit, '--fill' in flags),
  'recover': lambda kit, flags: cmd_recover(kit, '--fix' in flags)}
COMMANDS = {'cost': cmd_cost, 'release': cmd_release, 'budget raise': budget_raise}   # 'budget raise': called by kitbag.py budget
ARGS = {'audit': ({'--fix', '--fill'}, {'--kit', '--json'}, False), 'cost': ({'--steps', '--json'}, set(), True),
  'release': ({'--tag', '--publish'}, set(), False)}
