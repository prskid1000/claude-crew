# Usage: loaded by devtools.py from adapters/ (a plugin); its verb: python -X utf8 devtools.py precheck <task> [--mr <repo>!<iid> ...] [--dir <wt>] [--spec <mr.json>] [--json] | selftest. Exit codes: 0 ok · 1 problems · 2 usage.
"""Precheck plugin: the mechanical rules review findings repeat (kitty-precheck mined 1848 revy findings, 2026-11-25), run by devy
before it asks for review (crafty ship.md) so revy reads logic. Each problem prints `PRECHECK <ref> <CODE>: <problem> -> <fix>`.
MRs: --mr refs, else the task's tracked MRs, else the open MR of --dir's branch (or --spec rendered: before the MR opens).
Git (diff, commits, line endings, scope, loop head): --dir, else the repos[] checkout of each MR's repo (origin fetched).
Rules: TITLE (mrTitleFormat / keyed form, task id) · SECTIONS (mr.sections, empty, order) · PROSE (mr-title, mr-body; footer,
doc lines, Tags, Follow-ups uncounted) · HOW-TESTED (table, Not run / Pure logic line, a mark against its verdict) · UI (UI files
changed: a UI line, never "not a UI change") · DOCS (each required process doc linked by URL) · TRACKER (task link) · LINKS (every
Links bullet naming an MR / PR has its URL or ref) · COMMITS (commit prose: commitStyle subject, caps; no wip subject) · EOL (a file
whose diff is mostly line endings) · SCOPE (files outside the area globs) · LOOP (a local loop PASS whose head is the MR head, or only
docs changed since) · PROOF (devtools.py proof <task> gaps).
Sections: L21 rules · L154 context · L231 verb · L261 selftest"""
import contextlib, io, json, os, re, sys

DT = None
WIP = re.compile(r'(?i)^(wip|chore\(wip\))[:(]|released with uncommitted work')
BAD_MARK = re.compile(r'(❌|✗|:x:)\s*\**\s*PASS\b|(✅|✔|:white_check_mark:)\s*\**\s*FAIL\b')
DOC_ONLY = re.compile(r'(?i)\.(md|txt|rst|adoc)$')


# ---- rules: each (ctx) -> [(code, problem, fix)]; ctx holds the texts and git facts, no I/O here
def title_rx(fmt, task, tag, key=''):
    """mrTitleFormat as a regex: {type} a word, {task} the task id, {tag} tracker.branchTag, ({scope}) optional, others any text."""
    if key and '{key}' not in fmt:   # devtools.py render_title: a keyed task's naming form
        return re.compile(r'^[a-z]+(\([^)]*\))?!?:\s*\S.*\[' + re.escape(key) + r'\]$')
    val = {'type': r'[a-z]+!?', 'task': re.escape(task) if task else r'\S+', 'tag': re.escape(tag), 'key': re.escape(key) if key else r'\S+'}
    out, pos = '', 0
    for m in re.finditer(r'\(\{scope\}\)|\{(\w+)\}', fmt):
        out += re.sub(r'\\ ', r'\\s*', re.escape(fmt[pos:m.start()]))
        out += r'(?:\([^)]*\))?' if m.group(0) == '({scope})' else val.get(m.group(1), r'.+?')
        pos = m.end()
    return re.compile('^' + out + re.sub(r'\\ ', r'\\s*', re.escape(fmt[pos:])) + '$')


def r_title(c):
    fmt = c.get('titleFormat') or '{type}({scope}): {change} ({task})'
    if title_rx(fmt, c.get('task') or '', c.get('tag') or '', c.get('key') or '').match((c.get('title') or '').strip()):
        return []
    want = f"<type>(<scope>): <change> [{c['key']}]" if c.get('key') and '{key}' not in fmt else fmt
    return [('TITLE', f'title "{c.get("title")}" does not follow {want}', 'devtools.py render mr-title mr.json, then devtools.py mr --spec mr.json')]


def counted(body, footer, doc_rx):
    """The body as devtools.py mr counted it: no footer, doc link lines, Tags line or Follow-ups section (added after the gate)."""
    b = re.sub(r'(?ms)^## Follow-ups[ \t]*\n.*?(?=^## |\Z)', '', body.replace('\r\n', '\n'))
    b = b.replace(footer, '') if footer else b
    return '\n'.join(ln for ln in b.split('\n') if not ln.startswith('Tags: ') and not any(r.match(ln) for r in doc_rx))


def r_sections(c):
    body, out = c.get('body') or '', []
    miss = [h for h in c.get('sections') or [] if not re.search(r'(?m)^' + re.escape(h) + r'\s*$', body)]
    if miss:
        out.append(('SECTIONS', f'body is missing {", ".join(miss)}', 'templates.md "MR spec": render the body from mr.json'))
    out += [('SECTIONS', g, 'fill it, or n/a — <why>') for g in c.get('sectionGaps') or [] if not g.startswith('missing sections')]
    return out


def r_prose(c):
    return [('PROSE', f'{k}: {f}', f'rewrite (same facts) under templates.md "Writing standards" {k}') for k, fs in (c.get('prose') or {}).items() for f in fs]


def r_how_tested(c):
    body, out = c.get('body') or '', []
    m = re.search(r'(?ms)^## How tested[^\n]*\n(.*?)(?=^## |\Z)', body)
    if not m:
        return out
    if not re.match(r'\s*\|', m.group(1)):
        out.append(('HOW-TESTED', '"## How tested" is not a table', 'use "| Check | Result |" rows'))
    if not re.search(r'(?im)^\s*[-*|]?\s*(\*\*)?(not run|pure logic)(\*\*)?\s*[:|]', m.group(1)):
        out.append(('HOW-TESTED', '"## How tested" has no "Not run:" or "Pure logic:" line', 'add "Not run: <what, why>" (or "Not run: nothing")'))
    for bad in BAD_MARK.finditer(body):
        out.append(('HOW-TESTED', f'"{bad.group(0)}": the mark contradicts its verdict', 'one mark per result (PASS ✅, FAIL ❌)'))
    return out


def r_ui(c):
    ui = c.get('uiFiles') or []
    if not ui:
        return []
    line = re.search(r'(?im)^\s*[-*|]?\s*(\*\*)?UI(\*\*)?\s*[:|]\s*(.*)$', c.get('body') or '')
    if not line:
        return [('UI', f'UI files changed ({", ".join(ui[:3])}) and the body has no "UI:" line', '"UI: <committed spec or screenshot link>"')]
    if re.search(r'(?i)not a UI change', line.group(3)):
        return [('UI', f'"UI: not a UI change" but UI files changed ({", ".join(ui[:3])})', '"UI: <committed spec or screenshot link>"')]
    return []


def r_docs(c):
    out = []
    for d in c.get('docs') or []:
        if not d['rx'].search(c.get('body') or ''):
            fix = 'devtools.py mr --spec mr.json again (adds its published line)' if d.get('url') else 'devtools.py finish <task> cases solution.json review --ai cases'
            out.append(('DOCS', f'no "{d["label"]}: <url>" line{" (published: " + d["url"] + ")" if d.get("url") else ""}', fix))
    return out


def r_tracker(c):
    link = c.get('taskLink') or ''
    return [('TRACKER', f'body has no tracker task link ({link})', 'the task URL in "## Summary" or "## Links"')] if link and link not in (c.get('body') or '') else []


def r_links(c):
    m = re.search(r'(?ms)^## Links[^\n]*\n(.*?)(?=^## |\Z)', c.get('body') or '')
    bad = [ln.strip() for ln in (m.group(1) if m else '').split('\n') if re.match(r'\s*[-*]', ln) and re.search(r'\b(MR|PR|merge request|pull request)\b', ln)
           and not re.search(r'https?://|[\w./-]+!\d+|#\d+', ln)]
    return [('LINKS', f'"{b[:80]}" names an MR with no URL', 'the full MR URL ([repo!n](<url>))') for b in bad]


def r_commits(c):
    out = []
    for sha, msg, found in c.get('commits') or []:
        subj = msg.split('\n', 1)[0]
        if WIP.search(subj):
            out.append(('COMMITS', f'{sha[:10]} "{subj[:60]}" is a WIP commit', 'squash it into a real commit (crafty.ps1 wt commit), push'))
        out += [('COMMITS', f'{sha[:10]}: {f}', 'reword it (amend the head, push --force-with-lease: your own branch only)') for f in found]
    return out


def r_eol(c):
    return [('EOL', f'{p}: {raw} changed lines, {real} without line-ending changes', 'restore its line endings (.gitattributes / the file\'s own CRLF or LF)')
            for p, raw, real in c.get('eol') or [] if raw >= 20 and real * 2 < raw]


def r_scope(c):
    out = c.get('outside') or []
    return [('SCOPE', f'{len(out)} file(s) outside the area {c.get("globs")}: {", ".join(out[:5])}', 'revert them, or a decide record -Gate scope id (devtools.py mr --scope-ok)')] if out else []


def r_loop(c):
    ok, head, mr_head, since = c.get('loopOk'), c.get('loopHead') or '', c.get('head') or '', c.get('sinceLoop')
    if not c.get('task'):   # no task branch: no loop to find
        return []
    if ok is None:
        return [('LOOP', 'no local loop checkpoint for this task', 'run the loop, then crafty.ps1 checkpoint -Step loop -Item <task> -Evidence "round <n> PASS"')]
    if not ok:
        return [('LOOP', f'the last local loop is not PASS ({c.get("loopEv", "")[:100]})', 'fix and rerun the loop')]
    if head and mr_head and not mr_head.startswith(head[:7]) and not head.startswith(mr_head[:7]) and since:
        return [('LOOP', f'local loop PASS at {head[:10]}, MR head {mr_head[:10]} changed {", ".join(since[:3])}', 'rerun the loop on this head, checkpoint it')]
    return []


def r_proof(c):
    return [('PROOF', g, 'testing.md "Proof": close the gap (devtools.py cases result)') for g in c.get('proofGaps') or []]


RULES = (r_title, r_sections, r_prose, r_how_tested, r_ui, r_docs, r_tracker, r_links, r_commits, r_eol, r_scope, r_loop, r_proof)


def run_rules(c):
    return [x for r in RULES for x in r(c)]


# ---- context: texts from the host or the spec, facts from git and the kit's records
def _std():
    from kitbag import writing_standards, prose_check
    kinds, banned = writing_standards(DT.KIT_DIR)
    return lambda kind, text: prose_check(kind, text, kinds[kind], banned) if kind in kinds else []


def git_facts(gdir, base, head):
    """files, commits (sha, message), eol [(path, raw, real)] between base and head in gdir."""
    g = ['git', '-C', gdir, '-c', 'core.quotepath=false']
    files = [ln.strip() for ln in DT._run(g + ['diff', '--name-only', f'{base}...{head}']).splitlines() if ln.strip()]
    log = DT._run(g + ['log', '--no-merges', '--format=%H%x1f%B%x1e', f'{base}..{head}'])
    commits = [tuple(x.strip().split('\x1f', 1)) for x in log.split('\x1e') if '\x1f' in x]
    num = lambda *o: {ln.split('\t')[2]: int(ln.split('\t')[0]) + int(ln.split('\t')[1]) for ln in DT._run(g + ['diff', '--numstat', *o, f'{base}...{head}']).splitlines()
                      if ln.count('\t') >= 2 and ln.split('\t')[0].isdigit()}
    raw, real = num(), num('--ignore-cr-at-eol')
    return files, commits, [(p, n, real.get(p, 0)) for p, n in raw.items()]


def loop_facts(tid):
    ok, ev = DT.local_pass(tid)
    return ok, ev, str((getattr(DT.local_pass, 'last', None) or {}).get('head') or '')


def context(tid, title, body, gdir='', base='', head='', ref=''):
    prose = _std()
    dk = DT.docs() if DT.gate_how('mrBody') == 'builtin:testingDocs' or DT.gate_how('finish') == 'builtin:testingDocs' else []
    docs = [{'label': d['mrLabel'], 'rx': DT.doc_link_rx(d), 'url': DT._pub_read(f'{tid}:{d["key"]}').get('url') if tid else ''} for d in dk if d['required'] and tid]
    text = counted(body, DT.FOOTER, [DT.doc_label_rx(d) for d in DT.docs()])
    c = {'task': tid, 'title': title, 'body': body, 'titleFormat': DT.CFG.get('mrTitleFormat') or '', 'tag': DT.TAG, 'key': DT.task_key(tid) if tid else '',
         'sections': list(DT.MR_SECTIONS), 'sectionGaps': DT.doc_section_gaps('mr-body', text), 'docs': docs, 'taskLink': DT.task_link(),
         'prose': {k: f for k, f in (('mr-title', prose('mr-title', title)), ('mr-body', prose('mr-body', text))) if f}}
    if gdir and base and head:
        files, commits, eol = git_facts(gdir, base, head)
        c.update(head=head, uiFiles=[f for f in files if DT.UI_FILES.search(f)], eol=eol, commits=[(s, m, prose('commit', m)) for s, m in commits])
        c['globs'] = DT.scope_of(gdir, DT.SCOPE, ref)
        c['outside'] = DT.scope_outside(files, c['globs'])
    if tid:
        c['loopOk'], c['loopEv'], c['loopHead'] = loop_facts(tid)
        if gdir and c.get('loopHead') and head:
            c['sinceLoop'] = [f for f in DT._run(['git', '-C', gdir, 'diff', '--name-only', c['loopHead'], head]).splitlines() if f.strip() and not DOC_ONLY.search(f)]
        if 'proof' in DT.VERBS:
            with contextlib.redirect_stdout(io.StringIO()) as o:
                DT.VERBS['proof']([tid])
            c['proofGaps'] = [ln.split(': ', 1)[1] for ln in o.getvalue().splitlines() if ln.startswith('GAP ')]
    return c


def mr_targets(tid, refs, wt, spec):
    """[(ref, title, body, gdir, base, head)] for each MR to check."""
    host = DT.host_kind(DT.GITLAB_HOST)
    if spec:   # before the MR opens: the rendered texts, the worktree's head
        s = json.load(open(spec, encoding='utf-8'))
        tgt = DT.target_of(wt) or 'main'
        return [(f'spec {os.path.basename(spec)}', DT.render_title(s), DT.render_mr_body(s), wt, f'origin/{tgt}', 'HEAD')]
    if not refs and wt:
        host, proj = DT.remote(wt)
        src = DT._run(['git', '-C', wt, 'rev-parse', '--abbrev-ref', 'HEAD']).strip()
        ex = DT._host('mr.list', type=host, repo=proj, state='opened', source_branch=src)
        refs = [x.get('web_url') for x in ex if isinstance(x, dict) and x.get('web_url')] if isinstance(ex, list) else []
    refs = refs or ((DT.read_tracking().get('tasks') or {}).get(tid) or {}).get('mrs') or []
    out = []
    for ref in refs:
        r = DT._norm_ref(ref)
        if not r:
            raise SystemExit(f'precheck: {ref!r} is no <repo>!<iid> or MR URL')
        m = DT._host('mr.get', type=host, repo=DT._ref_path(host, r[0]), n=r[1])
        if not isinstance(m, dict) or not m.get('title'):
            raise SystemExit(f'precheck: {ref} not readable ({str(m)[:160]})')
        co = wt or next((x.get('checkout') for x in DT.CFG.get('repos') or [] if isinstance(x, dict) and r[0] in [x.get('name')] + list(x.get('aliases') or [])), '')
        gdir = co if co and os.path.isdir(co) else ''
        if gdir:
            DT._run(['git', '-C', gdir, 'fetch', '-q', 'origin', m.get('target_branch') or 'main', m.get('source_branch') or ''])
        out.append((f'{r[0]}!{r[1]}', m['title'], str(m.get('description') or m.get('body') or ''), gdir, f'origin/{m.get("target_branch") or "main"}', m.get('sha') or ''))
    return out


# ---- verb: precheck <task> [--mr <ref> ...] [--dir <wt>] [--spec <mr.json>] [--json] | selftest
def precheck_cmd(argv):
    if argv[:1] == ['selftest']:
        return selftest()
    opt = lambda k: argv[argv.index(k) + 1] if k in argv[:-1] else ''
    refs = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == '--mr']
    vals = {opt(k) for k in ('--dir', '--spec')} | set(refs)
    tid = next((a for a in argv if not a.startswith('-') and a not in vals), '')
    if not (tid or refs or opt('--dir')) or argv[:1] in (['-h'], ['--help']):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    wt = opt('--dir')
    if wt and not tid:
        tid = DT.task_of_branch(DT._run(['git', '-C', wt, 'rev-parse', '--abbrev-ref', 'HEAD']).strip())
    found, todo = [], mr_targets(tid, refs, wt, opt('--spec'))
    if not todo:
        print(f'precheck {tid}: no MR (pass --mr, --dir with an open MR, or --spec mr.json)', file=sys.stderr)
        return 2
    for ref, title, body, gdir, base, head in todo:
        for code, problem, fix in run_rules(context(tid, title, body.replace('\r\n', '\n'), gdir, base, head, ref)):
            found.append({'mr': ref, 'code': code, 'problem': problem, 'fix': fix})
    if '--json' in argv:
        print(json.dumps(found, indent=1, ensure_ascii=False))
    else:
        for f in found:
            print(f"PRECHECK {f['mr']} {f['code']}: {f['problem']} -> {f['fix']}")
        print(f'precheck {tid or "-"}: {len(found)} problem(s) in {len(todo)} MR(s)' + ('' if found else ' - ask for review'))
    return 1 if found else 0


# ---- selftest: each rule on a fixed context (no git, no host)
def selftest():
    res = []
    ex = lambda what, cond: res.append(print(f'{"PASS" if cond else "FAIL"} precheck: {what}') or bool(cond))
    codes = lambda c: {x[0] for x in run_rules(c)}
    body = ('## Summary\nSave orders. https://t/t/T1\n## Changes\n- Save\n## How tested\n| Check | Result |\n|---|---|\n| tests | PASS |\n'
            'Not run: nothing\n## Risks\n- none known: one field\n## Links\n- Testing doc: https://d/1\n- Producer: web!12\n')
    rx = re.compile(r'(?im)^[ \t>*_|-]*Testing doc:[ \t*_|]*(\[[^\]\n]*\]\()?(https?://|[A-Za-z]:[\\/])\S')
    good = {'task': 'T1', 'title': 'fix: save the order - ORD (CU-T1) (web)', 'body': body, 'titleFormat': '{type}: {change} - {code} ({tag}{task}) ({repo})', 'tag': 'CU-',
            'sections': ['## Summary', '## Changes', '## How tested', '## Risks', '## Links'], 'docs': [{'label': 'Testing doc', 'rx': rx, 'url': 'https://d/1'}],
            'taskLink': 'https://t/t/', 'uiFiles': [], 'commits': [('a' * 40, 'fix: save the order', [])], 'eol': [('a.ts', 4, 4)], 'loopOk': True, 'loopHead': 'abc1234', 'head': 'abc1234ff'}
    ex('a clean MR passes every rule', run_rules(good) == [])
    ex('TITLE: a conventional scope title misses the org format', 'TITLE' in codes({**good, 'title': 'fix(cypress): pin replay answers (T1)'}))
    ex('TITLE: no repo suffix', 'TITLE' in codes({**good, 'title': 'fix: save the order - ORD (CU-T1)'}))
    ex('TITLE: default format, empty scope, task id', not title_rx('{type}({scope}): {change} ({task})', 'T1', '').match('feat: x (T2)') and title_rx('{type}({scope}): {change} ({task})', 'T1', '').match('feat: x (T1)'))
    ex('TITLE: a keyed task ends with [KEY]', title_rx('', 'T1', '', 'ORD-1').match('feat(web): save [ORD-1]') and not title_rx('', 'T1', '', 'ORD-1').match('feat(web): save (T1)'))
    ex('SECTIONS: a missing Risks section', 'SECTIONS' in codes({**good, 'body': body.replace('## Risks\n- none known: one field\n', '')}))
    ex('PROSE: findings of the prose check', 'PROSE' in codes({**good, 'prose': {'mr-body': ['300 words (max 260)']}}))
    ex('PROSE: footer, doc lines, Tags and Follow-ups are uncounted', counted('a\n- Testing doc: https://d\nTags: x\n## Follow-ups\n- y\nFOOT', 'FOOT', [re.compile(r'(?i)^[ \t>*_|-]*Testing doc:')]).split() == ['a'])
    ex('HOW-TESTED: no table, no Not run line', len([x for x in run_rules({**good, 'body': body.replace('| Check | Result |\n|---|---|\n| tests | PASS |\nNot run: nothing\n', 'tests passed\n')}) if x[0] == 'HOW-TESTED']) == 2)
    ex('HOW-TESTED: a red cross next to PASS', 'HOW-TESTED' in codes({**good, 'body': body.replace('| tests | PASS |', '| tests | ❌ PASS 48/48 |')}))
    ex('UI: UI files and no UI line', 'UI' in codes({**good, 'uiFiles': ['src/a.html']}))
    ex('UI: "not a UI change" with UI files changed', 'UI' in codes({**good, 'uiFiles': ['src/a.html'], 'body': body.replace('Not run: nothing', 'Not run: nothing\nUI: not a UI change')}))
    ex('DOCS: "Testing doc: see task" is no link', 'DOCS' in codes({**good, 'body': body.replace('Testing doc: https://d/1', 'Testing doc: see task')}))
    ex('TRACKER: no task link', 'TRACKER' in codes({**good, 'body': body.replace('https://t/t/T1', 'T1')}))
    ex('LINKS: a sibling MR named without its URL', 'LINKS' in codes({**good, 'body': body + '- JT java MR (producer)\n'}))
    ex('COMMITS: a WIP head and a prose finding', len([x for x in run_rules({**good, 'commits': [('b' * 40, 'wip: java released with uncommitted work', []), ('c' * 40, 'Fix', ['subject misses conv'])]}) if x[0] == 'COMMITS']) == 2)
    ex('EOL: 486 lines of which 8 real', 'EOL' in codes({**good, 'eol': [('A.java', 486, 8)]}))
    ex('SCOPE: a file outside the globs', 'SCOPE' in codes({**good, 'globs': ['src/orders/**'], 'outside': ['src/chat/a.ts']}))
    ex('LOOP: none, not PASS, and code changed after the PASS head', all('LOOP' in codes({**good, **x}) for x in ({'loopOk': None}, {'loopOk': False}, {'head': 'def5678', 'sinceLoop': ['src/a.ts']})))
    ex('LOOP: only docs changed after the PASS head', 'LOOP' not in codes({**good, 'head': 'def5678', 'sinceLoop': []}))
    ex('PROOF: proof gaps', 'PROOF' in codes({**good, 'proofGaps': ["check T1 (ui): no PASS case with UI evidence"]}))
    return 0 if all(res) else 1


def register(dt):
    global DT
    DT = dt
    dt.VERBS['precheck'] = precheck_cmd
