# Usage: loaded by devtools.py from adapters/ (a plugin); its verb: python -X utf8 devtools.py proof <task> [--impact | --preflight [<results.json>] [--json]] | --branch <b> --impact | selftest · matrix-scope [<task>] --dir <wt> [--json]. Exit codes: 0 ok · 1 gaps · 2 usage.
"""Proof plugin (testing.md "Proof"): each goal (cases spec check) proven on its own channel, and the impact map before code.
Wraps devtools.py: finish's builtin:testingDocs gate, auto_merge (`merge <wt> <iid> --head <sha>`: the reviewed head), mr_create (a non-Draft MR), render_cases (goals: proof + impact sections),
cases_cmd (`cases result ... viewport=<WxH> hit=PASS|FAIL`; `cases add` warns), cases_fill_checks (a filled check gets a channel).
crafty.ps1 wt commit runs `proof --branch <b> --impact` (refuses a non-WIP commit on a task branch without the map).
Gates on only when process.gates.finish = builtin:testingDocs. Config: qa.testerViewport {web, mobile} (1366x768, 390x844);
qa.aiWaiver (owner decision id: an ai goal's local run waived while its env runs no localEnv services[].aiStack);
qa.preflight {env, tool, tenantSql, roles, maxScanRows} (unset: off): `proof <task> --preflight` lists the read-only checks of the spec's
`preflight` (EXPLAIN + row count per query, NULL / value scans per field, env keys, each call x role); the agent runs them and saves
the results; `--preflight <results.json>` checks the file and records the run; a gap refuses finish, a non-Draft mr and merge.
Sections: L16 gaps · L180 wraps · L270 matrix scope · L368 preflight · L596 verb"""
import json, os, re, sys

DT = None
CHANNELS = ('ui', 'api', 'job', 'ai')
# ---- gaps: what a goal needs per channel
UI_EV = re.compile(r'(\.(png|jpe?g|gif|webp|mp4|webm|mov)|trace[\w.-]*\.zip)(\?\S*)?$', re.I)   # screenshot, video, browser trace (a HAR is API proof)
IMPACT = ('logic', 'callers', 'renders', 'path')
DRAFT = re.compile(r'(?i)^\s*(\[draft\]|draft:|wip:)')
VIEW = re.compile(r'^(viewport|hit|runs|repos)=(\S+)$')


def on():
    return DT.gate_how('finish') == 'builtin:testingDocs'


def viewports():
    v = DT.cfg('qa.testerViewport', None)
    v = v if isinstance(v, dict) else {}
    return {'web': str(v.get('web') or '1366x768'), 'mobile': str(v.get('mobile') or '390x844')}


def _list(v):
    return v if isinstance(v, list) else [v] if v not in (None, '') else []


def renders(c):
    """impact.renders as [{item, result}] (a bare string = an item with no result yet)."""
    return [r if isinstance(r, dict) else {'item': str(r)} for r in _list((c.get('impact') or {}).get('renders'))]


def impact_gaps(c):
    """The impact map (before the first code commit): logic (why it is so: git log / blame, tests incl. disabled), callers
    (cross-repo consumers), renders (screens, record types, states), path (the tester's UI -> API -> DB / AI -> UI)."""
    m = c.get('impact')
    if not isinstance(m, dict):
        return ['no impact map: devtools.py cases add <task> <spec.json> with "impact": {"logic", "callers", "renders": [{"item"}], "path"}'
                ' (testing.md "Impact map"; a one-line fix: a short map)']
    return [f'impact.{k} is empty' for k in IMPACT if not m.get(k)] + [f'impact.renders: an entry without "item"' for r in renders(c) if not r.get('item')]


def _ev_ui(x):
    """UI evidence: a screenshot / video / trace by its name (`<file>=<url>`) or URL; a bare host link with no type (a Drive
    /view link) counts on a case that recorded its screen (viewport)."""
    evs = [str(e).strip() for e in _list(x.get('evidence'))]
    return any(UI_EV.search(re.sub(r'=https?://.*$', '', e, 1)) or x.get('viewport') and re.match(r'https?://\S+$', e)
               and not re.search(r'\.\w{2,5}(\?\S*)?$', e.rsplit('/', 1)[-1]) for e in evs)


def _passed(x):
    return str(x.get('result') or '').upper().startswith('PASS')


def waiver_gap(g, tid):
    """A ui goal not provable locally: a staging pre-verify (its evidence link) or an owner's word (decide check -Id)."""
    if g.get('preverify'):
        return '' if re.search(r'https?://', str(g['preverify'])) else f'check {g.get("id")}: preverify names no evidence link (the staging run\'s screenshot or trace)'
    orch = os.path.join(DT.KIT_DIR, 'skills', 'bossy', 'bossy.ps1')
    word = DT._run([DT.PWSH, '-NoProfile', '-NonInteractive', '-File', orch, 'decide', 'check', '-Id', str(g['waiver']), '-Item', tid, '-Gate', 'proof',
                    '-MaxHours', '720'], write=False)   # gate proof: a scope or merge yes waives nothing
    return '' if word.startswith('WORD ') else f'check {g.get("id")}: waiver {g["waiver"]} is no owner word for {tid} ({word[:80]})'


def proof_gaps(c, tid='', me=''):
    """Every goal proven on its channel (ui: UI evidence at the testers' viewport + hit test; ai: a deterministic guard + one
    local run), impact items resolved, a failure path run. me: another agent's checks (by) on a shared task are its own. -> [str]"""
    if not c or not c.get('checks'):
        return ['no goals doc: devtools.py cases add <task> <spec.json> with its checks (templates.md "Test cases")']
    cases, vp, out = [x for x in c.get('cases') or [] if isinstance(x, dict)], viewports(), impact_gaps(c)
    out += [f'impact.renders {r["item"]!r}: no result (a case id + PASS, or "excluded: <why>")' for r in renders(c) if r.get('item') and not r.get('result')]
    out += preflight_gaps(c)
    if not any(x.get('type') in ('negative', 'edge') and str(x.get('result') or '').upper().startswith(('PASS', 'FAIL')) for x in cases):
        out.append('happy path only: run negative / edge cases (invalid input, role denial, empty data, the failure path a tester tries)')
    for g in [g for g in c['checks'] if not (me and g.get('by') and g['by'] != me)]:
        gid, ch = g.get('id'), str(g.get('channel') or '').lower()
        ok = [x for x in cases if x.get('check') == gid and _passed(x)]
        if ch not in CHANNELS:
            out.append(f'check {gid}: channel {ch or "unset"!r} (ui | api | job | ai: how a tester sees it)')
        elif ch == 'ui' and (g.get('preverify') or g.get('waiver')):
            out += [w for w in [waiver_gap(g, tid)] if w]
        elif ch == 'ui':
            want, shown = vp['mobile'] if g.get('mobile') else vp['web'], [x for x in ok if _ev_ui(x)]
            at = [x for x in shown if str(x.get('viewport')) == want or g.get('mobile') and str(x.get('viewport', '')).startswith('device')]
            if not shown:
                out.append(f'check {gid} (ui): no PASS case with UI evidence (screenshot, video, trace) of the testing doc steps; API or stub'
                           ' proof and NOT_TESTED_LOCAL prove no ui goal (staging: "preverify": "<link>"; owner: "waiver": "<decision id>")')
            elif not at:
                out.append(f'check {gid} (ui): not run at the testers\' screen {want} (browser.mjs testerScreen(); cases result ... viewport={want})')
            elif not any(str(x.get('hit') or '').upper() == 'PASS' for x in at):
                out.append(f'check {gid} (ui): no hit test of the controls touched (browser.mjs hitTest(); cases result ... hit=PASS)')
            elif len(rs := task_repos(tid)) > 1 and not any(rs <= set(str(x.get('repos') or '').split(',')) for x in at):   # owner 2026-11-26
                out.append(f'check {gid} (ui): the task spans {", ".join(sorted(rs))}: run every branch together on one lane through this'
                           f' path (cases result ... repos={",".join(sorted(rs))})')
        elif ch == 'ai':   # owner 2026-11-26 (dec-came-back C): proof = the declared pass rate over real model runs on a lane
            out += [f'check {gid} (ai): no deterministic guard: "guard": "<unit test: code validates the AI output / plan>"'] if not g.get('guard') else []
            rate = _rate(g.get('passRate'))
            if not rate:
                out.append(f'check {gid} (ai): no passRate: "passRate": "<k>/<n>" (k of n real model runs must pass, e.g. 4/5)')
            elif not any(_rate_ok(x.get('runs'), rate) for x in ok) and not ai_waived(g, c):
                lane, wv = ai_lane(c), str(DT.cfg('qa.aiWaiver', '') or '')
                out.append(f'check {gid} (ai): pass rate {rate[0]}/{rate[1]} not shown: run the real model {rate[1]} times on a lane, then cases result'
                           f' <task> <case> PASS runs=<passed>/<runs>' + (
                    f'; {lane} runs the AI stack, so waiver {wv} no longer applies (envy.ps1 use -Env {lane} -Services <its aiStack service>)' if wv and lane else ''))
    return out


def task_repos(tid):
    """The repos of the task's tracked MRs (<repo>!<iid>): 2+ = one lane runs every branch."""
    mrs = ((DT.state_read(DT.task_file(tid)) or {}).get('track') or {}).get('mrs') or [] if tid else []
    return {str(m).split('!')[0].rsplit('/', 1)[-1] for m in mrs if '!' in str(m)}


def _rate(v):
    """'4/5' -> (4, 5): k of n runs; else None."""
    m = re.fullmatch(r'\s*(\d+)\s*/\s*(\d+)\s*', str(v or ''))
    return (int(m[1]), int(m[2])) if m and 0 < int(m[1]) <= int(m[2]) else None


def _rate_ok(runs, rate):
    """A case's runs '<passed>/<runs>' meets the rate: at least n runs, passed / runs >= k / n."""
    r = re.fullmatch(r'\s*(\d+)\s*/\s*(\d+)\s*', str(runs or ''))
    return bool(r) and int(r[2]) >= rate[1] and int(r[1]) <= int(r[2]) and int(r[1]) * rate[1] >= rate[0] * int(r[2])


def _by_name(items):
    """Services merged by name like envy's Merge-Cfg (a later entry's keys win)."""
    by = {}
    for s in [s for s in items if isinstance(s, dict)]:
        by[s.get('name') or id(s)] = {**by.get(s.get('name') or id(s), {}), **s}
    return list(by.values())


def ai_lane(c):
    """The local env running the AI stack (localEnv.envs.<env>.services[].aiStack, merged by name over defaults / extends) for this
    goals doc's env ("env": "<env> r<n>"; a lane id <env>-<bird> / <env><k> of a laned env is that env + its override keys; none
    named or unknown: any env) -> its name, else ''."""
    envs = DT.cfg('localEnv.envs', None)
    envs = envs if isinstance(envs, dict) else {}
    named, ai = (str(c.get('env') or '').split() or [''])[0], (lambda ss: any(s.get('aiStack') for s in ss))

    def svcs(n, seen=()):
        e = envs.get(n) if isinstance(envs.get(n), dict) else {}
        up = e.get('extends')
        return _by_name((svcs(up, seen + (n,)) if up and up not in seen else list(DT.cfg('localEnv.defaults.services', None) or [])) + list(e.get('services') or []))
    laned = [g for g in envs if g != named and int(((envs.get(g) or {}).get('lanes') or {}).get('max') or 1) > 1
             and (named.startswith(g + '-') or re.fullmatch(re.escape(g) + r'\d+', named))]
    if laned:
        over = envs.get(named) if isinstance(envs.get(named), dict) else {}
        return named if ai(_by_name(svcs(max(laned, key=len)) + list(over.get('services') or []))) else ''
    if named in envs:
        return named if ai(svcs(named)) else ''
    return next((n for n in envs if ai(svcs(n))), '')


def ai_waived(g, c):
    """An ai goal's local run waived (qa.aiWaiver: the owner decision) while its product's env runs no AI stack; a guard is still due."""
    return bool(DT.cfg('qa.aiWaiver', '') and g.get('guard') and not ai_lane(c))


def proof_of(g, c):
    """One goal's proof, for the goals doc."""
    if g.get('preverify') or g.get('waiver'):
        return f'preverify {g["preverify"]}' if g.get('preverify') else f'waiver {g["waiver"]}'
    ok = [x for x in c.get('cases') or [] if isinstance(x, dict) and x.get('check') == g.get('id') and _passed(x)]
    run = ' · '.join(f'{x.get("id")} PASS' + ''.join(f' {k} {x[k]}' for k in ('viewport', 'hit', 'runs') if x.get(k)) for x in ok) or (
        f'waiver {DT.cfg("qa.aiWaiver")} (no local AI lane)' if str(g.get('channel') or '').lower() == 'ai' and ai_waived(g, c) else 'none')
    return (f'guard {g["guard"]} · ' if g.get('guard') else '') + (f'pass rate {g["passRate"]} · ' if g.get('passRate') else '') + run


# ---- wraps: devtools.py functions this plugin gates (register)
def wrap_finish(orig):
    def run(p):
        ok, why = orig(p)
        if ok and (g := proof_gaps((p.get('ts') or {}).get('cases') or {}, p.get('task') or '', DT.me_agent())):
            return False, 'proof gaps (testing.md "Proof"): ' + '; '.join(g)
        return ok, why
    return run


def wrap_mr(orig):
    def run(worktree, title, body_md, tgt=None, check=False):   # no --override here: a wave's prior-work override must not pass it
        if not check and on() and not DRAFT.match(title or ''):
            tid = DT.task_of_branch(DT._run(['git', '-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD']))
            if tid and (g := proof_gaps((DT.state_read(DT.task_file(tid)) or {}).get('cases') or {}, tid, DT.me_agent())):
                raise SystemExit(f'mr refused: task {tid} proof gaps (testing.md "Proof"): {"; ".join(g)}. Close them, or open a Draft MR'
                                 ' (title "Draft: ..."). Nothing was opened.')
        return orig(worktree, title, body_md, tgt, check)
    return run


def wrap_render(orig):
    def run(c, kind, tid=''):
        out = orig(c, kind, tid)
        if kind != 'goals':
            return out
        imp, t = c.get('impact') or {}, DT._table
        sec = ['## Proof per goal (testing.md "Proof")', t(['Check', 'Channel', 'Proof'], [[g.get('id'), g.get('channel') or '?', proof_of(g, c)] for g in c.get('checks') or []]),
               '## Impact map (before code)', t(['Part', 'Map'], [['Logic changed (history, tests)', imp.get('logic', '')], ['Callers / consumers', imp.get('callers', '')],
                                                               ['Tester path', imp.get('path', '')]]),
               t(['Screen / record type / state', 'Result'], [[r.get('item'), r.get('result', '')] for r in renders(c)] or [['none listed', '']])]
        if (cf := pf_cfg()) and not pf_spec_gaps(c) and (plan := pf_plan(c, cf)):   # the staging-shaped run a reviewer opens
            pr = c.get('preflightRun') or {}
            done = pr.get('plan') == pf_hash(plan, cf)
            sec.append(f'Preflight ({len(plan)} read-only checks): ' + (f'{"ok" if pr.get("ok") else str(len(pr.get("gaps") or [])) + " gap(s)"} on'
                       f' {pr.get("env") or "?"} {pr.get("tenant") or ""} · {os.path.basename(str(pr.get("file") or ""))}' if done else 'not run'))
        return out.replace('## Test plan (automated)', '\n\n'.join(sec) + '\n\n## Test plan (automated)', 1)
    return run


def wrap_cases(orig):
    def run(a):
        a = list(a)
        if len(a) >= 2 and a[1] in ('add', 'result') and a[0] not in ('add', 'result', 'round', 'render', 'show'):
            a = [a[1], a[0]] + a[2:]   # cases <task> <verb>: as devtools.py swaps it
        kv = dict(VIEW.match(x).groups() for x in a[4:] if VIEW.match(x)) if a[:1] == ['result'] and len(a) > 3 else {}
        was = ((DT.state_read(DT.task_file(a[1])) or {}).get('cases') or {}).get('preflight') if a[:1] == ['add'] and len(a) > 1 and '--replace' not in a else None
        rc = orig([x for x in a if not (kv and VIEW.match(x))])
        if rc == 0 and isinstance(was, dict):
            DT.task_index(a[1], lambda x: pf_union(was, x.get('cases') or {}))
        if rc == 0 and a[:1] == ['result']:
            def put(x):
                for k in (x.get('cases') or {}).get('cases') or []:
                    if str(k.get('id')) == a[2]:
                        k.pop('viewport', None), k.pop('hit', None), k.pop('runs', None), k.pop('repos', None)
                        k.update(kv)   # a new result never keeps an old run's screen
            DT.task_index(a[1], put)
        c = (DT.state_read(DT.task_file(a[1])) or {}).get('cases') or {} if rc == 0 and a[:1] == ['add'] and on() else None
        if c is not None and (g := impact_gaps(c) + [f'check {x.get("id")}: channel unset (ui | api | job | ai)' for x in c.get('checks') or []
                                                     if str(x.get('channel') or '').lower() not in CHANNELS] + (pf_spec_gaps(c) if pf_cfg() else [])):
            print(f'WARN cases {a[1]}: {"; ".join(g)} (wt commit, mr and finish refuse until fixed)', file=sys.stderr)
        return rc
    return run


def wrap_fill(orig):
    def run(c):
        old = {id(g) for g in c.get('checks') or []}
        notes = orig(c)
        for g in [g for g in c.get('checks') or [] if id(g) not in old] if on() else []:   # only the checks it just made; others keep their gap
            g.setdefault('channel', 'job' if g.get('noUi') else 'ui')
        return notes
    return run


def wrap_merge(orig):
    def run(worktree, iid, *k):   # merge ... --head <sha>: the reviewed head (buildy early review); the host MR must still be at it
        want = (sys.argv[sys.argv.index('--head') + 1] if '--head' in sys.argv[:-1] else '').strip().lower()
        if want:
            m = DT._mr_api(*DT.remote(worktree), str(iid).rsplit('!', 1)[-1].lstrip('#'))('mr.get')
            got = str((m if isinstance(m, dict) else {}).get('sha') or '').lower()
            if not got:
                return f'!{iid}: no MR head from the host (--head {want[:12]} not checked); run merge again\nWAIT'
            if len(want) < 7 or not got.startswith(want):
                return (f'HEAD MOVED: !{iid} is at {got[:12]} on the host, the reviewed head is {want[:12]}: later commits are '
                        'unreviewed. Review them (revy kind mr), then merge without --head\nNOT_MERGED')
        return orig(worktree, iid, *k)
    return run


# ---- matrix scope: the qa.matrix variants a diff needs (qa.matrixRun); pokey matrix.mjs --task runs the recorded set
MX_RUN = {'parallel': 4, 'full': [r'\.(css|scss|sass|less|styl|pcss)$', r'(^|/)(layouts?|styles?|themes?|tokens?)(/|\.|$)', r'tailwind\.config',
                                  r'\.(svg|png|jpe?g|webp|gif|woff2?|ttf)$'],
          'newScreen': [r'\.(html|vue|svelte|jsx|tsx)$', r'(^|/)(pages?|screens?|views?|routes?)(/|\.|$)'], 'reduced': {'viewports': ['web', 'mobile'], 'locales': 1},
          'tests': [r'\.(spec|test|e2e|cy)\.[^/]+$', r'(^|/)(cypress|e2e|__tests__|__mocks__|tests?|spec)/', r'Tests?\.(java|kt|cs)$', r'(^|/)test_[^/]*\.py$', r'_test\.(py|go)$']}
AXES = ('viewports', 'fontScales', 'themes', 'locales')
MX_LINE = re.compile(r'(?im)\bMatrix:(.*)$')


def mx_run():
    v = DT.cfg('qa.matrixRun', None)
    return {**MX_RUN, **(v if isinstance(v, dict) else {})}


def matrix_scope(files):
    """files [(git status A|M|D, path)] -> {scope, reason, matrix}: full when a path matches qa.matrixRun.full (layout, style,
    assets) or an added one .newScreen, or no diff was read (test files, .tests, never count); else reduced: .reduced viewports (testerViewport names or WxH) and
    the first .reduced.locales of qa.matrix.locales."""
    run, full = mx_run(), DT.cfg('qa.matrix', None) or {}
    def rx(k):
        try:
            return [re.compile(p, re.I) for p in run.get(k) or []]
        except re.error as e:
            raise SystemExit(f'kit.local.json qa.matrixRun.{k}: a pattern is no regex ({e}): fix it')
    hit = lambda pats, fs: next((p for _, p in fs if any(x.search(p) for x in pats)), '')
    tests = rx('tests')   # a spec beside a layout component is no layout change
    paths = [(str(s), q) for s, p in files if not any(x.search(q := str(p).replace('\\', '/')) for x in tests)]
    why = (f'{h} is layout / style' if (h := hit(rx('full'), paths)) else '') or (f'{h} is a new screen' if (h := hit(rx('newScreen'), [f for f in paths if f[0].startswith('A')])) else '')
    if why or not files:
        return {'scope': 'full', 'reason': why or 'no diff read', 'matrix': {k: list(full.get(k) or []) for k in AXES}}
    red, tv = run.get('reduced') or {}, viewports()
    return {'scope': 'reduced', 'reason': f'{len(paths)} file(s), no layout / style or new screen' + (f' ({len(files) - len(paths)} test file(s) not counted)' if len(files) > len(paths) else ''),
            'matrix': {'viewports': list(dict.fromkeys(tv.get(v, v) for v in red.get('viewports') or [])), 'locales': list(full.get('locales') or [])[:int(red.get('locales', 1) or 0)]}}


def changed_files(wt):
    """The worktree's diff against its merge base with origin/<target>, uncommitted and untracked files too; [] when unreadable."""
    g = ['git', '-C', wt, '-c', 'core.quotepath=false']   # plain paths: a quoted "my style.css" missed \.css$
    base = DT._run(g + ['merge-base', 'HEAD', f'origin/{DT.target_of(wt) or "main"}']).strip()
    if not re.fullmatch(r'[0-9a-f]{7,40}', base):
        return []
    fs = [tuple(ln.split('\t', 1)) for ln in DT._run(g + ['diff', '--name-status', '--no-renames', base]).splitlines() if '\t' in ln]
    return fs + [('A', p) for p in DT._run(g + ['ls-files', '--others', '--exclude-standard']).splitlines() if p and not re.match(r'(warning|error|fatal):', p)]


def matrix_scope_cmd(argv):
    """matrix-scope [<task>] --dir <worktree> [--json]: the variants the diff needs, recorded on the task (its branch's when not named)
    as cases.matrixScope; the gate then accepts that reduced set, its line ending "(reduced: <reason>)"."""
    if '--dir' not in argv[:-1]:
        print(matrix_scope_cmd.__doc__, file=sys.stderr)
        return 2
    wt = argv[argv.index('--dir') + 1]
    own = DT.task_of_branch(br := DT._run(['git', '-C', wt, 'rev-parse', '--abbrev-ref', 'HEAD']))
    tid = next((x for x in argv if not x.startswith('-') and x != wt), '') or own
    if own and tid != own:
        raise SystemExit(f'matrix-scope: {wt} is on {br}, task {own}\'s branch, not {tid}\'s: --dir <{tid}\'s worktree>. Nothing was recorded.')
    sc = {**matrix_scope(changed_files(wt)), 'head': DT._run(['git', '-C', wt, 'rev-parse', 'HEAD'])[:12], 'dir': os.path.abspath(wt)}
    if tid:
        DT.task_index(tid, lambda x: x.setdefault('cases', {}).__setitem__('matrixScope', sc))
    n = 1
    for k in AXES:
        n *= max(1, len(sc['matrix'].get(k) or []))
    if '--json' in argv:
        print(json.dumps(sc))
        return 0
    print(f'matrix-scope {tid or wt}: {sc["scope"]} ({sc["reason"]}): {n} variant(s) per UI case {json.dumps({k: v for k, v in sc["matrix"].items() if v})}'
          + (f'\nrun: node <kit>/skills/pokey/matrix.mjs --task {tid} --case <id> --script <case.mjs> --out <dir>' if tid else ' (no task: not recorded)'))
    return 0


def wrap_gaps(orig):
    """case_gaps + the change-sized matrix: a "(reduced: ...)" Matrix line passes on the recorded reduced set (finish: the task must
    record it); a full line also needs each qa.matrix.locales value."""
    def run(ai_md, *a, **k):
        out, tid = orig(ai_md, *a, **k), (a[5] if len(a) > 5 else k.get('tid', ''))
        line = ' '.join(MX_LINE.findall(ai_md or '')).lower()
        toks, norm = set(re.split(r'[\s,;_|()]+', line)), (lambda v: re.sub(r'[^a-z0-9.]+', '-', str(v).lower()).strip('-'))
        gi = next((i for i, g in enumerate(out) if g.startswith('UI cases miss qa.matrix')), None)
        if '(reduced:' not in line:
            locs = [v for v in (DT.cfg('qa.matrix', None) or {}).get('locales') or [] if norm(v) not in toks]
            if locs and gi is None and re.search(r'!\[|<img\b|\.(png|jpe?g)\b', ai_md or '', re.I):
                out.append(f'UI cases miss qa.matrix locale(s) {", ".join(locs)}: run each per variant (pokey matrix.mjs), then add them to the "Matrix:" line')
            return out
        rec = ((DT.state_read(DT.task_file(tid)) or {}).get('cases') or {}).get('matrixScope') if tid else None
        fs = changed_files(rec['dir']) if tid and (rec or {}).get('scope') == 'reduced' and os.path.isdir(rec.get('dir') or '') else []
        now = matrix_scope(fs) if fs else None   # gone or unreadable worktree: the record holds
        if tid and ((rec or {}).get('scope') != 'reduced' or (now or {}).get('scope') == 'full'):   # recomputed: a later CSS / layout / screen commit
            msg = (f'task {tid} now needs the full matrix ({now["reason"]})' if now and now['scope'] == 'full' else
                   f'the "Matrix:" line says reduced but task {tid} records scope {(rec or {}).get("scope") or "none"}') + f': devtools.py matrix-scope {tid} --dir <worktree>, then run the variants it names'
            return out[:gi] + [msg] + out[gi + 1:] if gi is not None else out + [msg]
        want = (rec or matrix_scope([('M', 'x')]))['matrix']
        miss = [str(v) for kx in AXES for v in want.get(kx) or [] if norm(v) not in toks]
        if gi is not None:
            out = out[:gi] + ([f'UI cases miss reduced-matrix value(s) {", ".join(miss)}: run them (pokey matrix.mjs --task {tid or "<task>"})'] if miss else []) + out[gi + 1:]
        return out
    return run


# ---- preflight: the read-only checks a change needs on staging-shaped data (owner 2026-11-26, dec-staging-2 A); the agent runs them, this checks the saved file
PF_PARTS = ('queries', 'fields', 'envKeys', 'calls')
PF_SQL = re.compile(r'(?is)^\s*(select|with)\b(?![^;]*\b(insert|update|delete|drop|alter|truncate|create|grant|into)\b)[^;]*;?\s*$')
PF_LIT = re.compile(r"'(?:[^'\\]|\\.|'')*'")   # string literals: blanked before PF_SQL (a 'delete' status, a ';' in text)
PF_NAME = re.compile(r'[A-Za-z_][\w$]*(\.[A-Za-z_][\w$]*)?')
PF_SCAN = re.compile(r'(?i)\b(seq scan|full table scan|table scan|scan table)\b')
PF_HOW = 'devtools.py proof <task> --preflight lists them; run each read-only, save the results, then proof <task> --preflight <results.json>'


def pf_cfg():
    """qa.preflight {env, tool, tenantSql, roles [], maxScanRows (10000)}; unset = no preflight (None)."""
    v = DT.cfg('qa.preflight', None)
    if not isinstance(v, dict):
        return None
    n = v.get('maxScanRows')
    return {**{k: str(v.get(k) or '') for k in ('env', 'tool', 'tenantSql')}, 'roles': [str(r) for r in _list(v.get('roles'))],
            'maxScanRows': n if isinstance(n, int) and not isinstance(n, bool) else 10000}


def pf_spec_gaps(c):
    """The cases spec's `preflight`: all four lists (an empty one says the change has none), each entry well-formed and read-only."""
    p = c.get('preflight')
    if not isinstance(p, dict) or any(not isinstance(p.get(k), list) for k in PF_PARTS):
        return ['no preflight: devtools.py cases add <task> <spec.json> with "preflight": {"queries": [{id, sql, table}], "fields": [{table, column}],'
                ' "envKeys": [], "calls": [{id, call, allow: [roles]}]} (testing.md "Preflight"; [] = the change has none)']
    out, name = [], (lambda v: bool(PF_NAME.fullmatch(str(v or ''))))
    for q in p['queries']:
        q = q if isinstance(q, dict) else {}
        sql = PF_LIT.sub("''", str(q.get('sql') or ''))
        if not (q.get('id') and name(q.get('table'))):
            out.append(f'preflight query {q.get("id") or "?"}: needs "id" and "table" (the table its row count is taken from)')
        elif not PF_SQL.match(sql):
            out.append(f'preflight query {q["id"]}: "sql" is not one read-only SELECT (a changed UPDATE / DELETE: the SELECT of its WHERE)')
        elif '?' in sql:
            out.append(f'preflight query {q["id"]}: "sql" holds a ? placeholder: EXPLAIN runs it as written, give literal values shaped like real ones')
    out += [f'preflight field {f!r}: needs "table" and "column" names, "values" a list' for f in p['fields']
            if not (isinstance(f, dict) and name(f.get('table')) and name(f.get('column')) and isinstance(f.get('values') or [], list))]
    out += [f'preflight call {x!r}: needs "id", "call" (<METHOD> <path>) and "allow" (the roles that may make it)' for x in p['calls']
            if not (isinstance(x, dict) and x.get('id') and x.get('call') and isinstance(x.get('allow'), list))]
    ids = [str(x.get('id')) for k in ('queries', 'calls') for x in p[k] if isinstance(x, dict)]
    out += [f'preflight id {i} is used twice: one id per query and call' for i in dict.fromkeys(ids) if ids.count(i) > 1]
    return out


def pf_union(old, c):
    """cases add on a task that has a preflight: each list joined by key (query / call id, table.column, the env key; the new entry
    wins, {"_del": true} removes one), so a second area's spec never drops the first's checks; --replace starts over."""
    new = c.get('preflight')
    if not isinstance(new, dict):
        return
    key = lambda k, e: str(e) if k == 'envKeys' else f'{e.get("table")}.{e.get("column")}' if k == 'fields' else str(e.get('id'))
    for k in PF_PARTS:
        by = {key(k, e): e for e in _list(old.get(k)) if k == 'envKeys' or isinstance(e, dict)}
        for e in [e for e in _list(new.get(k)) if k == 'envKeys' or isinstance(e, dict)]:
            if k != 'envKeys' and e.get('_del'):
                by.pop(key(k, e), None)
            else:
                by[key(k, e)] = e
        if isinstance(new.get(k), list):
            new[k] = list(by.values())


def pf_plan(c, cf):
    """The checks to run -> [{id, kind, run}] (run: SQL for the read-only tool, or the question to answer)."""
    p, env, out = c.get('preflight') or {}, cf['env'] or 'the test env', []
    for q in p.get('queries') or []:
        out += [{'id': f'{q["id"]}.explain', 'kind': 'explain', 'run': 'EXPLAIN ' + str(q['sql']).strip().rstrip(';'), 'by': str(q.get('scanOk') or '')},
                {'id': f'{q["id"]}.rows', 'kind': 'rows', 'run': f'SELECT COUNT(*) AS n FROM {q["table"]}'}]
    for f in p.get('fields') or []:
        t, col = f['table'], f['column']
        out.append({'id': f'{t}.{col}.scan', 'kind': 'scan', 'run': f'SELECT COUNT(*) AS total, SUM(CASE WHEN {col} IS NULL THEN 1 ELSE 0 END) AS nulls FROM {t}',
                    'by': str(f.get('nullOk') or '')})
        if f.get('values'):
            out.append({'id': f'{t}.{col}.values', 'kind': 'values', 'run': f'SELECT {col} AS v, COUNT(*) AS n FROM {t} GROUP BY {col} ORDER BY n DESC LIMIT 50',
                        'by': sorted(map(str, f['values']))})
    out += [{'id': f'env.{k}', 'kind': 'env', 'run': f'is {k} set on {env}? save {{"present": true | false, "source": "<where seen>"}} (the name only, never its value)'}
            for k in p.get('envKeys') or []]
    for x in p.get('calls') or []:
        for r in dict.fromkeys([*map(str, cf['roles']), *map(str, x['allow'])]):
            out.append({'id': f'{x["id"]}.{r}', 'kind': 'call', 'run': f'may role {r} make {x["call"]} on {env}? save {{"status": <http status>}} (a read-only call) or'
                                                                     ' {"allowed": true | false, "source": "<file:line of the rule>"}',
                        'by': r in map(str, x['allow'])})
    return out


def pf_hash(plan, cf):
    import hashlib
    return hashlib.sha1(json.dumps([plan, cf['env'], cf['tenantSql'], cf['maxScanRows']], sort_keys=True).encode()).hexdigest()[:12]


def _pf_rows(v):
    """A saved result as rows [{lower key: value}] (a list, {"rows": [...]} or one object)."""
    v = v.get('rows') if isinstance(v, dict) and isinstance(v.get('rows'), list) else v
    return [{str(k).lower(): x for k, x in r.items()} for r in (v if isinstance(v, list) else [v]) if isinstance(r, dict)]


def _pf_int(rows, key):
    """rows[0][key] as an int (else its first numeric value); None when there is none."""
    r = rows[0] if rows else {}
    for x in [r.get(key), *r.values()]:
        if isinstance(x, (int, float)) and not isinstance(x, bool) or isinstance(x, str) and re.fullmatch(r'\d+(\.0+)?', x.strip()):
            return int(float(x))
    return None


def pf_check(c, res, cf):
    """The saved results against the plan -> gaps: a missing or failed check, a full scan of a large table, NULLs or values the
    change does not name, an env key not set, a role allowed or denied against the change's allow-list."""
    if not isinstance(res, dict) or not isinstance(res.get('results'), dict):
        return ['the results file is no {"env", "tenant", "results": {"<id>": <rows>}} object']
    got, p, out = res['results'], c.get('preflight') or {}, []
    if cf['env'] and str(res.get('env') or '') != cf['env']:
        out.append(f'results are from env {res.get("env") or "unnamed"!r}, not qa.preflight.env {cf["env"]!r}')
    if cf['tenantSql'] and not res.get('tenant'):
        out.append('no "tenant": run qa.preflight.tenantSql first, then every query on the tenant it names')
    where = f' on {res.get("tenant") or res.get("env") or "the env"}'
    for s in pf_plan(c, cf):
        v = got.get(s['id'])
        if v in (None, '', [], {}) or isinstance(v, dict) and v.get('error'):
            out.append(f'{s["id"]}: {"failed (" + str(v["error"])[:80] + ")" if v else "no result"}; run: {s["run"]}')
        elif not isinstance(v, dict) if s['kind'] in ('env', 'call') else not _pf_rows(v):
            out.append(f'{s["id"]}: unreadable result ({str(v)[:40]!r}): save {"an object" if s["kind"] in ("env", "call") else "the rows as objects"}; run: {s["run"]}')
    rows = lambda i: _pf_rows(got.get(i)) if not (isinstance(got.get(i), dict) and got[i].get('error')) else []
    for q in p.get('queries') or []:
        ex, n = rows(f'{q["id"]}.explain'), _pf_int(rows(f'{q["id"]}.rows'), 'n')
        scan = any(str(r.get('type') or '').upper() == 'ALL' or any(PF_SCAN.search(str(x)) for x in r.values()) for r in ex)
        if ex and n is None:
            out.append(f'{q["id"]}.rows: no row count read')
        elif scan and n > int(cf['maxScanRows']) and not q.get('scanOk'):
            out.append(f'query {q["id"]}: full scan of {q["table"]} ({n} rows{where}, over qa.preflight.maxScanRows {cf["maxScanRows"]}): an index or a bounded'
                       ' WHERE, or "scanOk": "<why>"')
    for f in p.get('fields') or []:
        fid = f'{f["table"]}.{f["column"]}'
        sc = rows(fid + '.scan')
        tot, nul = _pf_int(sc, 'total'), (_pf_int([{'nulls': sc[0].get('nulls')}], 'nulls') if sc else None)
        if sc and (tot is None or 'nulls' not in sc[0]):
            out.append(f'{fid}.scan: no "total" / "nulls" read')
        elif nul and not f.get('nullOk'):
            out.append(f'field {fid}: {nul} of {tot} rows are NULL{where}: handle NULL and prove it, then "nullOk": "<case id>"')
        seen = [str(r.get('v')) for r in rows(fid + '.values') if r.get('v') is not None]
        if f.get('values') and (odd := [x for x in seen if x not in map(str, f['values'])]):
            out.append(f'field {fid}: value(s) {", ".join(odd[:8])} exist{where} that "values" does not name: handle each, then list it')
    for k in p.get('envKeys') or []:
        v = got.get(f'env.{k}')
        if isinstance(v, dict) and not v.get('error') and v.get('present') is not True:
            out.append(f'env key {k} is not set{where}: it must be there before the deploy (name it in the MR "## Risks")')
    for x in p.get('calls') or []:
        for r in dict.fromkeys([*map(str, cf['roles']), *map(str, x['allow'])]):
            v = got.get(f'{x["id"]}.{r}')
            if not isinstance(v, dict) or v.get('error'):
                continue
            st = v.get('status')
            ok = v['allowed'] if isinstance(v.get('allowed'), bool) else (st < 300) if isinstance(st, int) and (200 <= st < 300 or st in (401, 403)) else None
            want = r in map(str, x['allow'])
            if ok is None:
                out.append(f'{x["id"]}.{r}: neither "allowed" nor a 2xx / 401 / 403 "status" ({st!r}; a redirect: follow it, save "allowed")')
            elif ok != want:
                out.append(f'call {x["id"]} ({x["call"]}): role {r} is {"allowed" if ok else "denied"}{where}, the change expects {"allowed" if want else "denied"}')
    return out


def preflight_gaps(c):
    """The proof gate's share: with qa.preflight set, the spec declares its preflight and its last checked run is ok for this plan."""
    cf = pf_cfg()
    if not cf:
        return []
    if sg := pf_spec_gaps(c):
        return sg
    plan, run = pf_plan(c, cf), c.get('preflightRun') or {}
    if not plan:
        return []
    if run.get('plan') != pf_hash(plan, cf):
        return [f'preflight: {len(plan)} check(s) not run for this plan: {PF_HOW}']
    return [f'preflight {g}' for g in run.get('gaps') or []]


def wrap_loop_gap(orig):
    def run(m, proj, iid, worktree):   # devtools.py merge: precheck's LOOP rule, then the task's preflight
        if gap := orig(m, proj, iid, worktree):
            return gap
        tid = DT._mr_task(m, proj, iid) if on() and pf_cfg() else ''
        c = (DT.state_read(DT.task_file(tid)) or {}).get('cases') or {} if tid else {}
        g = preflight_gaps(c) if c.get('checks') else []   # no goals doc: not this flow's MR
        if g and DT.OVERRIDE:
            DT.kitlog('calls', 'preflight-override', {'task': tid, 'mr': f'{proj}!{iid}', 'reason': DT.OVERRIDE})
        return f'!{iid}: task {tid} {g[0]}; --override "<why>" passes, logged\nNOT_MERGED' if g and not DT.OVERRIDE else ''
    return run


def preflight_cmd(tid, argv):
    """proof <task> --preflight [--json]: the read-only checks to run · --preflight <results.json>: check the saved results, record
    the run on the task (cases.preflightRun); exit 1 on a gap."""
    cf, c = pf_cfg(), (DT.state_read(DT.task_file(tid)) or {}).get('cases') or {}
    if not cf:
        print('preflight: qa.preflight is not set (README "Configuration"): nothing to run')
        return 0
    if sg := pf_spec_gaps(c):
        print('\n'.join(f'GAP {tid}: {g}' for g in sg))
        return 1
    i = argv.index('--preflight')
    path, plan = (argv[i + 1] if len(argv) > i + 1 and not argv[i + 1].startswith('-') else ''), pf_plan(c, cf)
    if not path:
        if '--json' in argv:
            print(json.dumps({'env': cf['env'], 'tenantSql': cf['tenantSql'], 'checks': plan, 'save': {'env': cf['env'], 'tenant': '', 'results': {s['id']: [] for s in plan}}}, indent=1))
            return 0
        if cf['tenantSql']:
            print(f'RUN tenant: {cf["tenantSql"]}   (the largest tenant: run every query below on it, save it as "tenant")')
        for s in plan:
            print(f'{"RUN" if s["kind"] in ("explain", "rows", "scan", "values") else "ASK"} {s["id"]}: {s["run"]}')
        tool = cf['tool'] or "the org's read-only SQL tool"
        print(f'preflight {tid}: {len(plan)} check(s) on {cf["env"] or "the test env"}, read-only ({tool}; never a write, never rows copied out).'
              f' Save {{"env": "{cf["env"]}", "tenant": "<it>", "results": {{"<id>": <the rows>}}}} (--json: the skeleton), then: devtools.py proof {tid} --preflight <results.json>')
        return 0
    try:
        res = json.load(open(path, encoding='utf-8-sig'))
    except (OSError, ValueError) as e:
        print(f'preflight {tid}: {path} is not readable JSON ({str(e)[:120]})', file=sys.stderr)
        return 2
    gaps = pf_check(c, res, cf)
    rec = {'plan': pf_hash(plan, cf), 'ok': not gaps, 'gaps': gaps, 'file': os.path.abspath(path), 'at': DT.kit_stamp(),
           'env': str(res.get('env') or '') if isinstance(res, dict) else '', 'tenant': str(res.get('tenant') or '') if isinstance(res, dict) else ''}
    DT.task_index(tid, lambda x: x.setdefault('cases', {}).__setitem__('preflightRun', rec))
    for g in gaps:
        print(f'GAP {tid}: preflight {g}')
    print(f'preflight {tid}: {len(plan)} check(s), {len(gaps)} gap(s)' + ('' if gaps else ' - recorded, the proof gate passes it'))
    return 1 if gaps else 0


# ---- verb: proof <task> [--preflight [<results.json>]] | --branch <b> --impact | selftest
def proof_cmd(argv):
    if argv[:1] == ['selftest']:
        return selftest()
    br = argv[argv.index('--branch') + 1] if '--branch' in argv[:-1] else ''
    tid = DT.task_of_branch(br) if br else next((x for x in argv if not x.startswith('-')), '')
    if not (tid or br) or argv[:1] in (['-h'], ['--help']):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if not tid or not on():
        return 0   # no task branch, or no testing-docs flow: nothing to prove
    if '--preflight' in argv:
        return preflight_cmd(tid, argv)
    c = (DT.state_read(DT.task_file(tid)) or {}).get('cases') or {}
    gaps = impact_gaps(c) if '--impact' in argv else proof_gaps(c, tid)
    for g in gaps:
        print(f'GAP {tid}: {g}')
    print(f'proof {tid}: {len(gaps)} gap(s)' + (' (impact map: testing.md "Impact map")' if gaps and '--impact' in argv else ''))
    return 1 if gaps else 0


def selftest():
    res = []
    ex = lambda what, cond: res.append(print(f'{"PASS" if cond else "FAIL"} proof: {what}') or bool(cond))
    imp = {'logic': 'x is so since abc1 (test X disabled: expects login)', 'callers': ['web list', 'app sync'], 'renders': [{'item': 'list', 'result': 'A1 PASS'}], 'path': 'UI -> API -> DB -> UI'}
    good = {'impact': imp, 'checks': [{'id': 'T1', 'channel': 'ui'}, {'id': 'T2', 'channel': 'ai', 'guard': 'PlanGuardTest', 'passRate': '4/5'}, {'id': 'T3', 'channel': 'api'}],
            'cases': [{'id': 'A1', 'check': 'T1', 'type': 'positive', 'result': 'PASS', 'evidence': ['s.png=https://h/v'], 'viewport': '1366x768', 'hit': 'PASS'},
                      {'id': 'A2', 'check': 'T2', 'type': 'negative', 'result': 'PASS', 'evidence': ['r.json'], 'runs': '4/5'}]}
    ex('a goal per channel, proven (ai: its guard + its pass rate over real runs): no gaps', proof_gaps(good) == [])
    tr0, DT.task_file, DT.state_read = (DT.task_file, DT.state_read), (lambda t: t), (lambda f: {'track': {'mrs': ['g/api!1', 'g/web!2']}} if f == 'X2' else {})
    try:
        two = proof_gaps(good, 'X2')
        ex('a task with MRs in 2 repos: a ui goal needs a case run with every branch on one lane (repos=api,web); one repo: no gap',
           any('spans api, web' in g for g in two) and not proof_gaps({**good, 'cases': [{**good['cases'][0], 'repos': 'api,web'}, good['cases'][1]]}, 'X2') and not proof_gaps(good, 'X1'))
    finally:
        DT.task_file, DT.state_read = tr0
    gr = lambda r, n='4/5': proof_gaps({**good, 'checks': good['checks'][:1] + [{**good['checks'][1], 'passRate': r}] + good['checks'][2:], 'cases': good['cases'][:1] + [{**good['cases'][1], 'runs': n}]})
    ex('ai pass rate (owner 2026-11-26): none declared, 3/5 under 4/5, 8/10 over 4/5 ok, 4/4 too few runs',
       any('no passRate' in g for g in gr('')) and any('pass rate 4/5 not shown' in g for g in gr('4/5', '3/5')) and not gr('4/5', '8/10') and gr('4/5', '4/4'))
    ex('no cases spec = no goals doc', proof_gaps({})[0].startswith('no goals doc'))
    api0, rem0, argv0, sha = DT._mr_api, DT.remote, sys.argv, ['abc1234def']
    DT.remote, DT._mr_api = (lambda w: ('h', 'g/p')), (lambda h, p, n: lambda verb, **a: {'sha': sha[0]} if sha[0] else None)
    try:
        mg = wrap_merge(lambda w, i, *k: 'ok\nMERGED')
        hd = lambda *a: [sys.__setattr__('argv', ['devtools.py', 'merge', '.', '7', *a]), mg('.', 'g/p!7')][1]
        ok = (hd('--head', 'ABC1234').endswith('MERGED') and 'NOT_' not in hd('--head', 'abc1234') and hd('--head', '9999999').startswith('HEAD MOVED') and
              hd('--head', '9999999').endswith('NOT_MERGED') and hd('--head', 'abc').endswith('NOT_MERGED') and hd() == 'ok\nMERGED')
        sha[0] = ''
        ex('merge --head: the host MR at the reviewed head merges, a moved head (or a sha under 7 chars) is NOT_MERGED, no host answer is WAIT, no --head merges',
           ok and hd('--head', 'abc1234').endswith('\nWAIT') and hd() == 'ok\nMERGED')
    finally:
        DT._mr_api, DT.remote, sys.argv = api0, rem0, argv0
    api_only = {**good, 'cases': [{**good['cases'][0], 'evidence': ['put.json=https://h/x']}, good['cases'][1]]}
    ex('a ui goal proven by API JSON is a gap', any('T1 (ui): no PASS case with UI evidence' in g for g in proof_gaps(api_only)))
    nt = {**good, 'cases': [{**good['cases'][0], 'result': 'NOT_TESTED_LOCAL stubbed'}, good['cases'][1]]}
    ex('a ui goal NOT_TESTED_LOCAL is a gap; a preverify link passes it', any('T1 (ui)' in g for g in proof_gaps(nt)) and
       not proof_gaps({**nt, 'checks': [{**good['checks'][0], 'preverify': 'staging https://h/shot.png'}] + good['checks'][1:]}))
    small = {**good, 'cases': [{**good['cases'][0], 'viewport': '1920x1080'}, good['cases'][1]]}
    ex('another viewport is a gap; mobile wants the mobile one', any("testers' screen 1366x768" in g for g in proof_gaps(small)) and
       any("testers' screen 390x844" in g for g in proof_gaps({**good, 'checks': [{**good['checks'][0], 'mobile': True}] + good['checks'][1:]})))
    ex('no hit test is a gap', any('no hit test' in g for g in proof_gaps({**good, 'cases': [{**good['cases'][0], 'hit': ''}, good['cases'][1]]})))
    ex('an ai goal without a guard is a gap', any('no deterministic guard' in g for g in proof_gaps({**good, 'checks': good['checks'][:1] + [{'id': 'T2', 'channel': 'ai'}] + good['checks'][2:]})))
    cfg0 = DT.cfg
    try:
        lanes = {'max': 3}
        conf = {'qa.aiWaiver': 'dec-9', 'localEnv.envs': {'shop': {'lanes': lanes, 'services': [{'name': 'api'}]}, 'crm': {'lanes': lanes, 'services': [{'name': 'llm', 'aiStack': True}]},
                'crm-kestrel': {'services': [{'name': 'db'}]}, 'b': {'extends': 'crm', 'services': [{'name': 'llm', 'aiStack': False}]},
                'tool': {'services': [{'name': 'llm', 'aiStack': True}]}, 'tool-eu': {'services': [{'name': 'api'}]}}}
        DT.cfg = lambda p, d=None: conf.get(p, d)
        norun = {**good, 'cases': good['cases'][:1] + [{**good['cases'][1], 'check': 'T9'}]}
        gp = lambda env, **k: proof_gaps({**norun, 'env': env, **k})
        ex('qa.aiWaiver: an ai goal with its guard and no local run passes while its env runs no AI stack (proof says waiver)',
           not gp('shop-kestrel r4') and 'waiver dec-9 (no local AI lane)' in proof_of(good['checks'][1], {**norun, 'env': 'shop r4'}))
        ex('qa.aiWaiver stops once the env runs an aiStack service (lane id too); no guard, no waiver, unknown env: any env',
           any('crm-osprey runs the AI stack, so waiver dec-9 no longer applies' in g for g in gp('crm-osprey r2'))
           and any('pass rate 4/5 not shown' in g for g in gp('shop r1', checks=good['checks'][:1] + [{'id': 'T2', 'channel': 'ai', 'passRate': '4/5'}]))
           and any('pass rate 4/5 not shown' in g for g in gp('')) and any('pass rate 4/5 not shown' in g for g in gp('nope r1')))
        ex('ai lane: a lane override key keeps its env\'s aiStack, <env><k> is a lane, an extends child turning it off and a non-laned'
           ' sibling env have none, defaults.services count', [ai_lane({'env': e}) for e in ('crm-kestrel r1', 'crm2 r1', 'b r1', 'tool-eu r1', 'shop r1')]
           == ['crm-kestrel', 'crm2', '', '', ''] and (conf.update({'localEnv.defaults.services': [{'name': 'm', 'aiStack': True}]}) or ai_lane({'env': 'shop r1'})) == 'shop')
        conf.pop('localEnv.defaults.services')
        conf.pop('qa.aiWaiver')
        ex('no qa.aiWaiver: the local run is due everywhere', any('pass rate 4/5 not shown' in g and 'waiver' not in g for g in gp('shop r1')))
    finally:
        DT.cfg = cfg0
    ex('happy path only and an unset channel are gaps', [g[:15] for g in proof_gaps({**good, 'checks': good['checks'] + [{'id': 'T4'}], 'cases': [{**x, 'type': 'positive'} for x in good['cases']]})] ==
       ['happy path only', "check T4: chann"])
    ex('impact map: missing, an empty part, an open render', impact_gaps({})[0].startswith('no impact map') and impact_gaps({'impact': {**imp, 'path': ''}}) == ['impact.path is empty']
       and any("'list': no result" in g for g in proof_gaps({**good, 'impact': {**imp, 'renders': ['list']}})))
    ex('Draft / WIP titles skip the mr gate; "Drafting" does not', all(DRAFT.match(t) for t in ('Draft: x', '[Draft] x', 'WIP: x')) and not any(DRAFT.match(t) for t in ('feat: drafts list', 'Drafting rules')))
    ev = lambda e, **k: proof_gaps({**good, 'cases': [{**good['cases'][0], 'evidence': [e], **k}, good['cases'][1]]})
    ex('a HAR is API proof; a typeless Drive link counts with its viewport; "my shot.png=<url>" is a screenshot', any('UI evidence' in g for g in ev('n.har=https://h/n'))
       and not ev('https://drive.example/file/d/1Ab/view') and any('UI evidence' in g for g in ev('https://drive.example/file/d/1Ab/view', viewport=''))
       and not ev('my shot.png=https://h/v'))
    ex('a negative case never run is happy path only', any(g.startswith('happy path only') for g in proof_gaps({**good, 'cases': [good['cases'][0], {**good['cases'][1], 'result': ''}]})))
    ex('a shared task: another agent\'s open check is its own', not proof_gaps({**good, 'checks': good['checks'] + [{'id': 'B1', 'by': 'devy-b'}]}, '', 'devy-a'))
    keep = {n: getattr(DT, n) for n in ('_run', 'state_read', 'task_index')}
    try:
        calls = []
        DT._run = lambda cmd, **k: calls.append(cmd) or ('WORD d-1 proof' if 'd-1' in cmd else 'NO-WORD')
        wv = lambda w: proof_gaps({**nt, 'checks': [{**good['checks'][0], 'waiver': w}] + good['checks'][1:]}, 'T1')
        ex('a waiver is an owner word on gate proof (decide check -Gate proof); another id is a gap', not wv('d-1') and any('is no owner word' in g for g in wv('d-2'))
           and all(c[c.index('-Gate') + 1] == 'proof' for c in calls))
        st = {'cases': {'cases': [{'id': 'A1'}]}}
        DT.state_read, DT.task_index = (lambda f: None), (lambda t, fn: fn(st))
        seen = []
        wrap_cases(lambda a: seen.append(a) or 0)(['T1', 'result', 'A1', 'PASS', 'x.png=https://h/x', 'viewport=1366x768', 'hit=PASS'])
        ex('cases <task> result ... viewport= hit=: swapped back, fields stored, evidence kept', seen == [['result', 'T1', 'A1', 'PASS', 'x.png=https://h/x']]
           and st['cases']['cases'][0] == {'id': 'A1', 'viewport': '1366x768', 'hit': 'PASS'})
    finally:
        for n, f in keep.items():
            setattr(DT, n, f)
    keep = {n: getattr(DT, n) for n in ('cfg', 'state_read', '_mr_task', 'OVERRIDE', 'kitlog')}
    try:   # owner 2026-11-26 (dec-staging-2 A): the script lists read-only checks, the agent runs them, the script judges the saved file
        conf = {'qa.preflight': {'env': 'stage', 'roles': ['admin', 'guest'], 'maxScanRows': 1000}}
        DT.cfg = lambda p, d=None: conf.get(p, d)
        cf = pf_cfg()
        spec = {'queries': [{'id': 'Q1', 'sql': "SELECT id FROM orders WHERE note LIKE 'delete; a%'", 'table': 'orders'}], 'fields': [{'table': 'orders', 'column': 'paid', 'values': ['Y', 'N']}],
                'envKeys': ['PAY_URL'], 'calls': [{'id': 'C1', 'call': 'GET /api/orders', 'allow': ['admin']}]}
        pc = {**good, 'preflight': spec}
        ids = [s['id'] for s in pf_plan(pc, cf)]
        ex('preflight plan: EXPLAIN + row count per query, null scan + values per field, each env key, each call x role (config roles too)',
           ids == ['Q1.explain', 'Q1.rows', 'orders.paid.scan', 'orders.paid.values', 'env.PAY_URL', 'C1.admin', 'C1.guest'] and pf_plan(pc, cf)[0]['run'].startswith('EXPLAIN SELECT id FROM orders'))
        okr = {'env': 'stage', 'tenant': 't9', 'results': {'Q1.explain': [{'type': 'ref', 'key': 'ix_note', 'rows': 12}], 'Q1.rows': [{'n': 250000}], 'orders.paid.scan': {'rows': [{'TOTAL': 250000, 'NULLS': '0'}]},
               'orders.paid.values': [{'v': 'Y', 'n': 9}, {'v': 'N', 'n': 4}], 'env.PAY_URL': {'present': True, 'source': 'env page'}, 'C1.admin': {'status': 200}, 'C1.guest': {'allowed': False, 'source': 'Sec.java:40'}}}
        bad = lambda **k: pf_check(pc, {**okr, 'results': {**okr['results'], **k}}, cf)
        ex('preflight check: a full result file passes; another env, a missing id and a failed query are gaps', pf_check(pc, okr, cf) == [] and any('not qa.preflight.env' in g for g in pf_check(pc, {**okr, 'env': 'dev'}, cf))
           and any(g.startswith('Q1.rows: no result') for g in bad(**{'Q1.rows': None})) and any('failed (timeout)' in g for g in bad(**{'env.PAY_URL': {'error': 'timeout'}})) and pf_check(pc, [], cf))
        scan = {'Q1.explain': [{'type': 'ALL', 'key': None}]}
        ex('preflight check: a full scan over maxScanRows blocks (MySQL type ALL, a "Seq Scan" plan line); a small table or scanOk passes',
           any('query Q1: full scan of orders (250000 rows on t9' in g for g in bad(**scan)) and bad(**{'Q1.explain': [{'QUERY PLAN': 'Seq Scan on orders'}]}) and not bad(**scan, **{'Q1.rows': [{'n': 40}]})
           and not pf_check({**pc, 'preflight': {**spec, 'queries': [{**spec['queries'][0], 'scanOk': 'nightly job'}]}}, {**okr, 'results': {**okr['results'], **scan}}, cf))
        ex('preflight check: NULL rows without nullOk, a value "values" does not name, an env key not set, a role allowed against the allow-list, an odd status',
           any('field orders.paid: 31 of 250000 rows are NULL on t9' in g for g in bad(**{'orders.paid.scan': [{'total': 250000, 'nulls': 31}]}))
           and any('value(s) X exist' in g for g in bad(**{'orders.paid.values': [{'v': 'Y'}, {'v': 'X'}, {'v': None}]})) and any('env key PAY_URL is not set' in g for g in bad(**{'env.PAY_URL': {'present': False}}))
           and any('role guest is allowed on t9, the change expects denied' in g for g in bad(**{'C1.guest': {'status': 200}})) and any('role admin is denied' in g for g in bad(**{'C1.admin': {'status': 403}}))
           and any('C1.admin: neither' in g for g in bad(**{'C1.admin': {'status': 500}})))
        sg = lambda **k: pf_spec_gaps({'preflight': {**spec, **k}})
        ex('preflight spec: missing = a gap, four empty lists = nothing to run; a write, two statements or a bad table name are refused',
           pf_spec_gaps({})[0].startswith('no preflight') and pf_spec_gaps({'preflight': {'queries': []}}) and not preflight_gaps({**good, 'preflight': {k: [] for k in PF_PARTS}})
           and all(sg(queries=[{'id': 'Q', 'table': 'orders', 'sql': s}]) for s in ('UPDATE orders SET a=1', 'SELECT 1; DROP TABLE x', 'SELECT * FROM a FOR UPDATE'))
           and sg(queries=[{'id': 'Q', 'table': 'a b', 'sql': 'SELECT 1'}]) and sg(fields=[{'table': 'orders'}]) and sg(calls=[{'id': 'C', 'call': 'GET /x'}]) and not sg())
        ex('preflight spec: SELECT ... INTO, a ? placeholder, an id used twice, a table name ending in a newline and "values" that is no list are refused',
           all(sg(queries=[{'id': 'Q', 'table': 'orders', 'sql': s}]) for s in ('SELECT * INTO t2 FROM orders', 'SELECT id FROM orders WHERE note = ?'))
           and any('Q1 is used twice' in g for g in sg(calls=[{'id': 'Q1', 'call': 'GET /x', 'allow': []}])) and sg(queries=[{'id': 'Q', 'table': 'orders\n', 'sql': 'SELECT 1'}])
           and sg(fields=[{'table': 'orders', 'column': 'paid', 'values': 5}]))
        ex('preflight check: a result it cannot read is a gap (false, a string, empty rows, rows that are arrays, a scan without nulls); a 302 is no access',
           all(any('unreadable result' in g for g in bad(**k)) for k in ({'env.PAY_URL': False}, {'C1.guest': 'denied'}, {'Q1.explain': 'ok'}, {'Q1.rows': {'rows': []}}, {'Q1.explain': [['ALL']]}))
           and any('orders.paid.scan: no "total" / "nulls" read' in g for g in bad(**{'orders.paid.scan': [{'total': 5}]})) and any('C1.admin: neither' in g for g in bad(**{'C1.admin': {'status': 302}})))
        un = {'preflight': {'queries': [], 'fields': [{'table': 'orders', 'column': 'paid', 'nullOk': 'A2'}], 'envKeys': ['B_KEY'], 'calls': [{'id': 'C1', '_del': True}]}}
        pf_union(spec, un)
        ex('preflight on a shared task: a second cases add joins the lists (its entry wins, _del removes one), the first area\'s query stays',
           [q['id'] for q in un['preflight']['queries']] == ['Q1'] and un['preflight']['fields'] == [{'table': 'orders', 'column': 'paid', 'nullOk': 'A2'}]
           and un['preflight']['envKeys'] == ['PAY_URL', 'B_KEY'] and un['preflight']['calls'] == [])
        conf['qa.preflight'] = {'env': 'stage', 'roles': None, 'maxScanRows': '10k'}
        ex('qa.preflight: roles null and a maxScanRows that is no number fall back (no roles, 10000)', pf_cfg()['roles'] == [] and pf_cfg()['maxScanRows'] == 10000)
        conf['qa.preflight'] = {'env': 'stage', 'roles': ['admin', 'guest'], 'maxScanRows': 1000}
        run = {'plan': pf_hash(pf_plan(pc, cf), cf), 'ok': True, 'gaps': []}
        ex('proof gate: qa.preflight set: no preflight, an unrun plan, a changed plan and a recorded gap block; a recorded ok run passes; unset: no gate',
           any(g.startswith('no preflight') for g in proof_gaps(good)) and any('7 check(s) not run' in g for g in proof_gaps(pc)) and not proof_gaps({**pc, 'preflightRun': run})
           and any('not run' in g for g in proof_gaps({**pc, 'preflight': {**spec, 'envKeys': []}, 'preflightRun': run}))
           and any('not run' in g for g in proof_gaps({**pc, 'preflight': {**spec, 'calls': [{**spec['calls'][0], 'allow': ['admin', 'guest']}]}, 'preflightRun': run}))
           and any('not run' in g for g in proof_gaps({**pc, 'preflight': {**spec, 'fields': [{**spec['fields'][0], 'nullOk': 'A2'}]}, 'preflightRun': run}))
           and proof_gaps({**pc, 'preflightRun': {**run, 'ok': False, 'gaps': ['env key PAY_URL is not set']}}) == ['preflight env key PAY_URL is not set']
           and (conf.clear() or proof_gaps(good) == []))
        conf['qa.preflight'] = {'env': 'stage'}
        g_on, st = globals()['on'], {'T1': {'cases': pc}, 'T2': {}}
        DT._mr_task, DT.state_read, DT.task_file, tf0, DT.kitlog = (lambda m, p, i: m['t']), (lambda f: st.get(f)), (lambda t: t), DT.task_file, (lambda *a: None)
        try:
            globals()['on'], DT.OVERRIDE = (lambda: True), ''
            mg = wrap_loop_gap(lambda *a: '')
            held, free = mg({'t': 'T1'}, 'g/r', '7', ''), mg({'t': 'T2'}, 'g/r', '8', '')
            DT.OVERRIDE = 'owner said so'
            ex('merge: an unrun preflight is NOT_MERGED; a task with no goals doc and --override merge; the LOOP refusal comes first',
               held.endswith('NOT_MERGED') and 'preflight' in held and free == '' and mg({'t': 'T1'}, 'g/r', '7', '') == '' and wrap_loop_gap(lambda *a: 'LOOP\nNOT_MERGED')({'t': 'T2'}, 'g/r', '8', '').startswith('LOOP'))
        finally:
            globals()['on'], DT.task_file = g_on, tf0
    finally:
        for n, f in keep.items():
            setattr(DT, n, f)
    g0 = lambda p: (True, '')
    ex('finish: a passing testingDocs gate then refuses on proof gaps', not wrap_finish(g0)({'task': 'T1', 'ts': {'cases': api_only}})[0] and wrap_finish(g0)({'task': 'T1', 'ts': {'cases': good}})[0])
    md = wrap_render(lambda c, k, t='': '# Testing goals\n\n## Test plan (automated)\n')(good, 'goals')
    ex('goals doc: proof per goal + impact map before the test plan', md.index('## Proof per goal') < md.index('## Impact map') < md.index('## Test plan') and 'A1 PASS viewport 1366x768 hit PASS' in md)
    g_on = globals()['on']
    try:
        globals()['on'] = lambda: True
        fc = {'checks': [{'id': 'T0'}], 'cases': []}
        wrap_fill(lambda c: c['checks'].extend([{'id': 'T5', 'steps': 'open'}, {'id': 'T6', 'noUi': 'job'}]) or ['x'])(fc)
    finally:
        globals()['on'] = g_on
    ex('a filled check gets a channel (ui, a noUi one job); an older one keeps its gap', [g.get('channel') for g in fc['checks']] == [None, 'ui', 'job'])
    keep = {n: getattr(DT, n) for n in ('cfg', 'state_read')}
    try:   # owner 2026-11-25: a menu change ran 9 variants x 5 cases; the matrix is sized to the diff
        mx = {'viewports': ['1366x768', '1920x1080', '390x844'], 'fontScales': [1, 1.5, 2], 'locales': ['en-GB', 'de-DE']}
        conf = {'qa.matrix': mx, 'qa.testerViewport': {'web': '1366x768', 'mobile': '390x844'}}
        DT.cfg = lambda p, d=None: conf.get(p, d)
        sc = lambda *fs: matrix_scope(list(fs))
        ex('matrix scope: CSS, a layout file, a new screen or no diff = full; a menu label / logic edit = tester web + mobile + one locale',
           [sc(('M', 'src/app/menu.scss'))['scope'], sc(('M', 'src/layout/shell.ts'))['scope'], sc(('A', 'src/app/orders/list.html'))['scope'], sc()['scope']] == ['full'] * 4
           and sc(('M', 'src/app/menu/menu.component.html'), ('M', 'src/i18n/en.json')) == {'scope': 'reduced', 'reason': '2 file(s), no layout / style or new screen',
                                                                                              'matrix': {'viewports': ['1366x768', '390x844'], 'locales': ['en-GB']}}
           and sc(('M', 'a.css'))['matrix']['fontScales'] == [1, 1.5, 2])
        nav = 'shopapp/web-ui/src/app/layout/components/navbar/vertical/style-1/navigation-search'   # 2026-11-25: its spec made a menu change full
        tst = [(f'M', p) for p in (nav + '.spec.ts', 'web/cypress/e2e/menu.cy.ts', 'api/src/test/java/x/MenuTest.java', 'svc/tests/test_menu.py', 'web/src/menu.test.tsx')]
        ex('matrix scope: test files never count (*.spec.ts, *.test.*, cypress/**, *Test.java, test_*.py); a layout source still does; only tests = reduced',
           sc(('M', 'web/src/app/menu/menu.config.ts'), *tst) == {'scope': 'reduced', 'reason': '1 file(s), no layout / style or new screen (5 test file(s) not counted)',
                                                                    'matrix': {'viewports': ['1366x768', '390x844'], 'locales': ['en-GB']}}
           and sc(('M', nav + '.component.ts'), *tst)['scope'] == 'full' and sc(*tst)['scope'] == 'reduced')
        conf['qa.matrixRun'] = {'full': ['('], 'reduced': {'viewports': ['web'], 'locales': 0}}
        try:
            sc(('M', 'x.ts'))
            bad = ''
        except SystemExit as e:
            bad = str(e)
        conf['qa.matrixRun'] = {'reduced': {'viewports': ['web'], 'locales': 0}}
        ex('qa.matrixRun: a bad pattern names its key; reduced keys override the default', 'qa.matrixRun.full' in bad and sc(('M', 'x.ts'))['matrix'] == {'viewports': ['1366x768'], 'locales': []})
        conf.pop('qa.matrixRun')
        core = lambda md, *a: ['UI cases miss qa.matrix value(s) 1920x1080 (case(s) A1): run each'] if '1920x1080' not in md else []
        doc = lambda line: f'| A1 | s | PASS | ![a](https://h/a.png) |\n{line}\n'
        rec = {'scope': 'reduced', 'matrix': {'viewports': ['1366x768', '390x844'], 'locales': ['en-GB']}}
        DT.state_read = lambda f: {'cases': {'matrixScope': rec}}
        g = wrap_gaps(core)
        red = 'Matrix: 1366x768_en-gb, 390x844_en-gb (reduced: 1 file(s), no layout / style or new screen)'
        ex('gate: a reduced line passes on the recorded set; a missing value, an unrecorded scope and a full scope do not',
           g(doc(red), None, '', (), 'x', (), 'T1') == [] and 'reduced-matrix value(s) 390x844' in g(doc(red.replace(', 390x844_en-gb', '')), None, '', (), 'x', (), 'T1')[0]
           and (DT.__setattr__('state_read', lambda f: {}) or 'records scope none' in g(doc(red), None, '', (), 'x', (), 'T1')[0])
           and (rec.update(scope='full') or DT.__setattr__('state_read', lambda f: {'cases': {'matrixScope': rec}}) or 'records scope full' in g(doc(red), None, '', (), 'x', (), 'T1')[0]))
        cf0, rec2 = globals()['changed_files'], {**rec, 'scope': 'reduced', 'dir': os.getcwd()}
        try:
            DT.state_read = lambda f: {'cases': {'matrixScope': rec2}}
            globals()['changed_files'] = lambda d: [('M', 'menu.ts'), ('A', 'shell/theme.scss')]
            ex('gate: a reduced record goes stale when its worktree diff now holds a style file (recomputed at the gate)',
               'now needs the full matrix (shell/theme.scss is layout / style)' in g(doc(red), None, '', (), 'x', (), 'T1')[0])
        finally:
            globals()['changed_files'] = cf0
        ex('gate: a full line also needs every qa.matrix.locales value', 'locale(s) de-DE' in ' '.join(g(doc('Matrix: 1366x768_f1_en-gb, 1920x1080_f2_en-gb'))) and not g(doc('Matrix: 1920x1080_en-gb, de-de')))
    finally:
        for n, f in keep.items():
            setattr(DT, n, f)
    return 0 if all(res) else 1


def register(dt):
    global DT
    DT = dt
    dt.VERBS['proof'] = proof_cmd
    dt.VERBS['matrix-scope'] = matrix_scope_cmd
    if sys.argv[1:2] == ['selftest']:   # devtools.py selftest proves the core gates alone; proof selftest proves these
        return
    dt.case_gaps = wrap_gaps(dt.case_gaps)
    gates = dt.BUILTIN_GATES.get('testingDocs') or {}
    if 'finish' in gates:
        gates['finish'] = wrap_finish(gates['finish'])
    dt.mr_create, dt.render_cases, dt.cases_cmd, dt.cases_fill_checks = wrap_mr(dt.mr_create), wrap_render(dt.render_cases), wrap_cases(dt.cases_cmd), wrap_fill(dt.cases_fill_checks)
    dt.auto_merge = wrap_merge(dt.auto_merge)
    dt.merge_loop_gap = wrap_loop_gap(getattr(dt, 'merge_loop_gap', lambda *a: ''))   # precheck.py registers first (sorted)
