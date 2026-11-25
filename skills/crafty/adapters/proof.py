# Usage: loaded by devtools.py from adapters/ (a plugin); its verb: python -X utf8 devtools.py proof <task> [--impact] | --branch <b> --impact | selftest · matrix-scope [<task>] --dir <wt> [--json]. Exit codes: 0 ok · 1 gaps · 2 usage.
"""Proof plugin (testing.md "Proof"): each goal (cases spec check) proven on its own channel, and the impact map before code.
Wraps devtools.py: finish's builtin:testingDocs gate, mr_create (a non-Draft MR), render_cases (goals: proof + impact sections),
cases_cmd (`cases result ... viewport=<WxH> hit=PASS|FAIL`; `cases add` warns), cases_fill_checks (a filled check gets a channel).
crafty.ps1 wt commit runs `proof --branch <b> --impact` (refuses a non-WIP commit on a task branch without the map).
Gates on only when process.gates.finish = builtin:testingDocs. Config: qa.testerViewport {web, mobile} (1366x768, 390x844);
qa.aiWaiver (owner decision id: an ai goal's local run waived while its env runs no localEnv services[].aiStack).
Sections: L13 gaps · L151 wraps · L218 matrix scope · L314 verb"""
import json, os, re, sys

DT = None
CHANNELS = ('ui', 'api', 'job', 'ai')
# ---- gaps: what a goal needs per channel
UI_EV = re.compile(r'(\.(png|jpe?g|gif|webp|mp4|webm|mov)|trace[\w.-]*\.zip)(\?\S*)?$', re.I)   # screenshot, video, browser trace (a HAR is API proof)
IMPACT = ('logic', 'callers', 'renders', 'path')
DRAFT = re.compile(r'(?i)^\s*(\[draft\]|draft:|wip:)')
VIEW = re.compile(r'^(viewport|hit)=(\S+)$')


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
        elif ch == 'ai':
            out += [f'check {gid} (ai): no deterministic guard: "guard": "<unit test: code validates the AI output / plan>"'] if not g.get('guard') else []
            if not ok and not ai_waived(g, c):
                lane, wv = ai_lane(c), str(DT.cfg('qa.aiWaiver', '') or '')
                out.append(f'check {gid} (ai): no local run PASS (one run; never N reruns)' + (
                    f'; {lane} runs the AI stack, so waiver {wv} no longer applies (envy.ps1 use -Env {lane} -Services <its aiStack service>)' if wv and lane else ''))
    return out


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
    run = ' · '.join(f'{x.get("id")} PASS' + ''.join(f' {k} {x[k]}' for k in ('viewport', 'hit') if x.get(k)) for x in ok) or (
        f'waiver {DT.cfg("qa.aiWaiver")} (no local AI lane)' if str(g.get('channel') or '').lower() == 'ai' and ai_waived(g, c) else 'none')
    return (f'guard {g["guard"]} · ' if g.get('guard') else '') + run


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
        return out.replace('## Test plan (automated)', '\n\n'.join(sec) + '\n\n## Test plan (automated)', 1)
    return run


def wrap_cases(orig):
    def run(a):
        a = list(a)
        if len(a) >= 2 and a[1] in ('add', 'result') and a[0] not in ('add', 'result', 'round', 'render', 'show'):
            a = [a[1], a[0]] + a[2:]   # cases <task> <verb>: as devtools.py swaps it
        kv = dict(VIEW.match(x).groups() for x in a[4:] if VIEW.match(x)) if a[:1] == ['result'] and len(a) > 3 else {}
        rc = orig([x for x in a if not (kv and VIEW.match(x))])
        if rc == 0 and a[:1] == ['result']:
            def put(x):
                for k in (x.get('cases') or {}).get('cases') or []:
                    if str(k.get('id')) == a[2]:
                        k.pop('viewport', None), k.pop('hit', None)
                        k.update(kv)   # a new result never keeps an old run's screen
            DT.task_index(a[1], put)
        c = (DT.state_read(DT.task_file(a[1])) or {}).get('cases') or {} if rc == 0 and a[:1] == ['add'] and on() else None
        if c is not None and (g := impact_gaps(c) + [f'check {x.get("id")}: channel unset (ui | api | job | ai)' for x in c.get('checks') or []
                                                     if str(x.get('channel') or '').lower() not in CHANNELS]):
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


# ---- matrix scope: the qa.matrix variants a diff needs (qa.matrixRun); ui-checks.mjs matrix --task runs the recorded set
MX_RUN = {'parallel': 4, 'full': [r'\.(css|scss|sass|less|styl|pcss)$', r'(^|/)(layouts?|styles?|themes?|tokens?)(/|\.|$)', r'tailwind\.config',
                                  r'\.(svg|png|jpe?g|webp|gif|woff2?|ttf)$'],
          'newScreen': [r'\.(html|vue|svelte|jsx|tsx)$', r'(^|/)(pages?|screens?|views?|routes?)(/|\.|$)'], 'reduced': {'viewports': ['web', 'mobile'], 'locales': 1}}
AXES = ('viewports', 'fontScales', 'themes', 'locales')
MX_LINE = re.compile(r'(?im)\bMatrix:(.*)$')


def mx_run():
    v = DT.cfg('qa.matrixRun', None)
    return {**MX_RUN, **(v if isinstance(v, dict) else {})}


def matrix_scope(files):
    """files [(git status A|M|D, path)] -> {scope, reason, matrix}: full when a path matches qa.matrixRun.full (layout, style,
    assets) or an added one .newScreen, or no diff was read; else reduced: .reduced viewports (testerViewport names or WxH) and
    the first .reduced.locales of qa.matrix.locales."""
    run, full = mx_run(), DT.cfg('qa.matrix', None) or {}
    def rx(k):
        try:
            return [re.compile(p, re.I) for p in run.get(k) or []]
        except re.error as e:
            raise SystemExit(f'kit.local.json qa.matrixRun.{k}: a pattern is no regex ({e}): fix it')
    hit = lambda pats, fs: next((p for _, p in fs if any(x.search(p) for x in pats)), '')
    paths = [(str(s), str(p).replace('\\', '/')) for s, p in files]
    why = (f'{h} is layout / style' if (h := hit(rx('full'), paths)) else '') or (f'{h} is a new screen' if (h := hit(rx('newScreen'), [f for f in paths if f[0].startswith('A')])) else '')
    if why or not paths:
        return {'scope': 'full', 'reason': why or 'no diff read', 'matrix': {k: list(full.get(k) or []) for k in AXES}}
    red, tv = run.get('reduced') or {}, viewports()
    return {'scope': 'reduced', 'reason': f'{len(paths)} file(s), no layout / style or new screen',
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
          + (f'\nrun: node <kit>/skills/pokey/adapters/ui-checks.mjs matrix --task {tid} --case <id> --script <case.mjs> --out <dir>' if tid else ' (no task: not recorded)'))
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
                out.append(f'UI cases miss qa.matrix locale(s) {", ".join(locs)}: run each per variant (ui-checks.mjs matrix), then add them to the "Matrix:" line')
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
            out = out[:gi] + ([f'UI cases miss reduced-matrix value(s) {", ".join(miss)}: run them (ui-checks.mjs matrix --task {tid or "<task>"})'] if miss else []) + out[gi + 1:]
        return out
    return run


# ---- verb: proof <task> | --branch <b> --impact | selftest
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
    good = {'impact': imp, 'checks': [{'id': 'T1', 'channel': 'ui'}, {'id': 'T2', 'channel': 'ai', 'guard': 'PlanGuardTest'}, {'id': 'T3', 'channel': 'api'}],
            'cases': [{'id': 'A1', 'check': 'T1', 'type': 'positive', 'result': 'PASS', 'evidence': ['s.png=https://h/v'], 'viewport': '1366x768', 'hit': 'PASS'},
                      {'id': 'A2', 'check': 'T2', 'type': 'negative', 'result': 'PASS', 'evidence': ['r.json']}]}
    ex('a goal per channel, proven (ai: its guard + ONE local run, no reruns): no gaps', proof_gaps(good) == [])
    ex('no cases spec = no goals doc', proof_gaps({})[0].startswith('no goals doc'))
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
           and any('no local run PASS' in g for g in gp('shop r1', checks=good['checks'][:1] + [{'id': 'T2', 'channel': 'ai'}]))
           and any('no local run PASS' in g for g in gp('')) and any('no local run PASS' in g for g in gp('nope r1')))
        ex('ai lane: a lane override key keeps its env\'s aiStack, <env><k> is a lane, an extends child turning it off and a non-laned'
           ' sibling env have none, defaults.services count', [ai_lane({'env': e}) for e in ('crm-kestrel r1', 'crm2 r1', 'b r1', 'tool-eu r1', 'shop r1')]
           == ['crm-kestrel', 'crm2', '', '', ''] and (conf.update({'localEnv.defaults.services': [{'name': 'm', 'aiStack': True}]}) or ai_lane({'env': 'shop r1'})) == 'shop')
        conf.pop('localEnv.defaults.services')
        conf.pop('qa.aiWaiver')
        ex('no qa.aiWaiver: the local run is due everywhere', any('no local run PASS' in g and 'waiver' not in g for g in gp('shop r1')))
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
