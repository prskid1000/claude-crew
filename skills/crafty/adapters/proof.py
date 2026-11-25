# Usage: loaded by devtools.py from adapters/ (a plugin); its verb: python -X utf8 devtools.py proof <task> [--impact] | --branch <b> --impact | selftest. Exit codes: 0 ok · 1 gaps · 2 usage.
"""Proof plugin (testing.md "Proof"): each goal (cases spec check) proven on its own channel, and the impact map before code.
Wraps devtools.py: finish's builtin:testingDocs gate, mr_create (a non-Draft MR), render_cases (goals: proof + impact sections),
cases_cmd (`cases result ... viewport=<WxH> hit=PASS|FAIL`; `cases add` warns), cases_fill_checks (a filled check gets a channel).
crafty.ps1 wt commit runs `proof --branch <b> --impact` (refuses a non-WIP commit on a task branch without the map).
Gates on only when process.gates.finish = builtin:testingDocs. Config: qa.testerViewport {web, mobile} (1366x768, 390x844).
Sections: L12 gaps · L111 wraps · L178 verb"""
import os, re, sys

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
            out += [f'check {gid} (ai): no local run PASS (one run; never N reruns)'] if not ok else []
    return out


def proof_of(g, c):
    """One goal's proof, for the goals doc."""
    if g.get('preverify') or g.get('waiver'):
        return f'preverify {g["preverify"]}' if g.get('preverify') else f'waiver {g["waiver"]}'
    ok = [x for x in c.get('cases') or [] if isinstance(x, dict) and x.get('check') == g.get('id') and _passed(x)]
    run = ' · '.join(f'{x.get("id")} PASS' + ''.join(f' {k} {x[k]}' for k in ('viewport', 'hit') if x.get(k)) for x in ok) or 'none'
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
    return 0 if all(res) else 1


def register(dt):
    global DT
    DT = dt
    dt.VERBS['proof'] = proof_cmd
    if sys.argv[1:2] == ['selftest']:   # devtools.py selftest proves the core gates alone; proof selftest proves these
        return
    gates = dt.BUILTIN_GATES.get('testingDocs') or {}
    if 'finish' in gates:
        gates['finish'] = wrap_finish(gates['finish'])
    dt.mr_create, dt.render_cases, dt.cases_cmd, dt.cases_fill_checks = wrap_mr(dt.mr_create), wrap_render(dt.render_cases), wrap_cases(dt.cases_cmd), wrap_fill(dt.cases_fill_checks)
