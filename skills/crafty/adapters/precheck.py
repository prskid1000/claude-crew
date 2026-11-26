# Usage: loaded by devtools.py from adapters/ (a plugin); its verb: python -X utf8 devtools.py precheck <task> [--mr <repo>!<iid> ...] [--dir <wt>] [--spec <mr.json>] [--scope-ok <id>] [--kind dev-env] [--json] | selftest. Exit codes: 0 ok · 1 problems · 2 usage.
"""Precheck plugin: the mechanical rules review findings repeat (kitty-precheck mined 1848 revy findings, 2026-11-25), run by devy
before it asks for review (crafty ship.md) so revy reads logic. Each problem prints `PRECHECK <ref> <CODE>: <problem> -> <fix>`.
MRs: --mr refs, else the task's tracked MRs, else the open MR of --dir's branch (or --spec rendered: before the MR opens).
Git (diff, commits, line endings, scope, loop head): --dir, else the repos[] checkout of each MR's repo (origin fetched).
Rules: TITLE (mrTitleFormat / keyed form, task id) · SECTIONS (mr.sections, empty, order) · PROSE (mr-title, mr-body; footer,
doc lines, Tags, Follow-ups uncounted) · HOW-TESTED (table, Not run / Pure logic line, a mark against its verdict) · UI (UI files
changed: a UI line, never "not a UI change") · DOCS (each required process doc linked by URL) · TRACKER (task link) · LINKS (every
Links bullet naming an MR / PR has its URL or ref) · COMMITS (commit prose: commitStyle subject, caps; no wip subject; the head
carries repos[].commitMarker) · EOL (a file
whose diff is mostly line endings) · SCOPE (files outside the area globs) · LOOP (a local loop PASS whose head is the MR head, or only
docs changed since) · PROOF (devtools.py proof <task> gaps).
--kind dev-env (crafty ship.md "Dev-env change"; also read from the task's track record, onMerged closed): DOCS and PROOF off, DEFAULTS
on (a removed line of a code / config file with a string, number, flag or name its hunk's added code no longer holds = a changed
default: no dev-env change; a heuristic that fails closed: a rename or a refactor is flagged too).
Dev-env change, the steps (a new key or an env override whose unset path is today's value; instead of finish, plain track add, deploy request):
  crafty.ps1 tracker create -Spec <json> (kind Chore); crafty.ps1 tracker tags <task> kind=chore flow=dev-env
  crafty.ps1 checkpoint -Agent <id> -Run <run> -Step loop -Item <task> -Dir <wt> -Evidence "round 1 PASS: <the env run that used it>"
  devtools.py mr <wt> --spec mr.json; bossy.ps1 track add -Task <task> -Mrs <repo>!<iid> -OnMerged closed   (closed once merged, never promoted)
  devtools.py comment <task> --spec solution.json comment-solution; crafty.ps1 tracker status <task> review
  devtools.py precheck <task> --dir <wt> --kind dev-env
  devtools.py merge <wt> <iid> --no-docs 'dev-env <what>'   (runs DEFAULTS again: a changed default = NOT_MERGED, no override)
Sections: L33 rules · L250 context · L376 verb · L417 selftest · L498 areas"""
import contextlib, io, json, os, re, subprocess, sys

DT = None
WIP = re.compile(r'(?i)^(wip|chore\(wip\))[:(]|released with uncommitted work')
BAD_MARK = re.compile(r'(❌|✗|:x:)\s*\**\s*PASS\b|(✅|✔|:white_check_mark:)\s*\**\s*FAIL\b')
DOC_ONLY = re.compile(r'(?i)\.(md|txt|rst|adoc)$')
OWNER_WORD = re.compile(r'(?i)\bowner word\b')


# ---- rules: each (ctx) -> [(code, problem, fix)]; ctx holds the texts and git facts, no I/O here
def title_rx(fmt, task, tag, key='', known=()):
    """mrTitleFormat as a regex: {type} a word, {task} the task id, {tag} tracker.branchTag; as devtools.py fmt_line drops an empty
    placeholder with its ' -' or '()', every one but type / change / task / key is optional."""
    if key and '{key}' not in fmt:   # devtools.py render_title: a keyed task's naming form
        return re.compile(r'^[a-z]+(\([^)]*\))?!?:\s*\S.*\[' + re.escape(key) + r'\]$')
    val = {'type': r'[a-z]+!?', 'task': re.escape(task) if task else r'\S+', 'tag': re.escape(tag), 'key': re.escape(key) if key else r'\S+'}
    need, lit = {'type', 'change', 'task', 'key', *known}, lambda s: re.sub(r'\\ ', r'\\s*', re.escape(s))
    fill = lambda s: re.sub(r'\{(\w+)\}', lambda m: val.get(m.group(1), r'.+?'), lit(s).replace(r'\{', '{').replace(r'\}', '}'))
    out, pos = '', 0
    for m in re.finditer(r'\s*-\s*\{(\w+)\}|\(([^()]*\{\w+\}[^()]*)\)|\{(\w+)\}', fmt):
        names = set(re.findall(r'\{(\w+)\}', m.group(0)))
        piece = r'\s*-\s*' + val.get(m.group(1), r'.+?') if m.group(1) else r'\s*\(' + fill(m.group(2)) + r'\)' if m.group(2) is not None else val.get(m.group(3), r'.+?')
        out += lit(fmt[pos:m.start()]) + (f'(?:{piece})' if names & need else f'(?:{piece})?')
        pos = m.end()
    return re.compile('^' + out + lit(fmt[pos:]) + '$')


def r_title(c):
    fmt = c.get('titleFormat') or '{type}({scope}): {change} ({task})'
    if title_rx(fmt, c.get('task') or '', c.get('tag') or '', c.get('key') or '', ['repo'] if c.get('repo') else []).match((c.get('title') or '').strip()):
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
    if c.get('marker') and c.get('headMsg') and c['marker'] not in c['headMsg']:   # CI fails a head the repo's commit hook did not mark
        out.append(('COMMITS', f'the head commit lacks repos[].commitMarker "{c["marker"]}" (its commit hook did not run)',
                    'fix the hook setup (core.hooksPath, its deps), git commit --amend --no-edit (the hook runs again; never type the marker), push --force-with-lease'))
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
    redo = 'run the loop, then crafty.ps1 checkpoint -Step loop -Item <task> -Dir <wt> -Evidence "round <n> PASS"'
    if ok is None:
        return [('LOOP', 'no local loop checkpoint for this task', redo)]
    if not ok:
        return [('LOOP', f'the last local loop is not PASS ({c.get("loopEv", "")[:100]})', 'fix and ' + redo)]
    if OWNER_WORD.search(c.get('loopEv') or ''):   # checkpoint -Step loop -Evidence "PASS owner word: <their words>": any head
        return []
    if not head and mr_head and c.get('codeFiles'):
        return [('LOOP', 'the loop PASS checkpoint has no head (written without -Dir): its code state is unknown', redo)]
    if head and mr_head and not mr_head.startswith(head[:7]) and not head.startswith(mr_head[:7]) and since:
        return [('LOOP', f'local loop PASS at {head[:10]}, MR head {mr_head[:10]} changed {", ".join(since[:3])}', 'rerun the loop on this head, checkpoint it')]
    return []


def r_proof(c):
    return [('PROOF', g, 'testing.md "Proof": close the gap (devtools.py cases result)') for g in c.get('proofGaps') or []]


TEST_FILE = re.compile(r'(?i)(^|/)(tests?|specs?|__tests__|e2e|cypress|fixtures?)/|[._-](test|spec)s?\.\w+$|(^|/)test_[^/]+$|Tests?\.\w+$')
TOKEN = re.compile(r""""((?:[^"\\]|\\.)+)"|'((?:[^'\\]|\\.)+)'|((?<![\w.)\]])-?\d+(?:\.\d+)?(?![\w.]))|([A-Za-z_][\w.]*)""")   # string, number (its sign), word
COMMENT = re.compile(r'^\s*(#(?!define|include)|//|/?\*|--(?=\s|$)|<!--|;|$)')
FLAG = re.compile(r'(?i)^(true|false|yes|no|on|off|null|none|nil)$')
TAIL = re.compile(r""""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|(?:^|(?<=\s))(?:#|//)(?=\s|$).*$""")   # a trailing comment outside quotes


def code_of(ln):
    """A line without its trailing comment ('' = a comment or blank line): a value kept only in a comment is not kept."""
    return '' if COMMENT.match(ln) else TAIL.sub(lambda m: m.group(0) if m.group(0)[:1] in '"\'' else '', ln).rstrip()


def default_changes(diff):
    """[(file, old line, lost tokens)] of a `git diff -U0` (diff_u0): a removed line of a code / config file (no test, no doc, no
    comment) with a token (string, number with its sign, word: a name, true, a host) no added code line of the same hunk keeps;
    a line moved whole within its file is kept. `X = "a"` -> `X = env("X") or "a"` keeps every token; `X = "b"`, 30 -> 60,
    true -> false, a dropped or commented-out line, a changed binary and a file whose name the header hides are changed defaults."""
    files, f, hunk = [], None, None
    for ln in diff.replace('\r\n', '\n').split('\n'):
        if ln.startswith('diff --git '):
            f = {'name': '', 'hunks': [], 'binary': False}
            files.append(f)
            hunk = None
        elif f is None:
            continue
        elif hunk is None and ln[:6] in ('--- a/', '+++ b/'):   # a deleted file keeps its a/ name (+++ /dev/null); a path with a space ends in a tab
            f['name'] = ln[6:].rstrip('\t')
        elif hunk is None and ln.startswith('Binary files a/'):   # an old binary replaced or deleted (a new one: /dev/null first)
            f['binary'], f['name'] = True, f['name'] or ln[15:].split(' and ')[0]
        elif ln.startswith('@@'):
            hunk = ([], [])
            f['hunks'].append(hunk)
        elif hunk is not None and ln[:1] in '-+' and ln[:1]:
            hunk[ln[0] == '+'].append(code_of(ln[1:]))
    out = []
    for f in files:
        name = f['name']
        if name and (TEST_FILE.search(name) or DOC_ONLY.search(name)):
            continue
        if f['binary']:
            out.append((name, 'binary file', ['its old content']))
        moved, whole = {a.strip() for h in f['hunks'] for a in h[1] if a.strip()}, '\n'.join(a for h in f['hunks'] for a in h[1])
        has = lambda t, where, num=False: re.search((r'(?<![\w.-])' if num else r'(?<![\w.])') + re.escape(t) + r'(?!\w)' + (r'(?!\.\d)' if num else ''), where)
        for rem, add in f['hunks']:
            new = '\n'.join(add)
            for ln in [r for r in rem if r.strip() and r.strip() not in moved]:
                lost = []
                for m in TOKEN.findall(ln):
                    t = next(x for x in m if x).rstrip('.') if m[3] else next(x for x in m if x)
                    # a string, a number and a flag word stay in their hunk; a name may move into a helper of the same file (its dotted parts)
                    kept = t in new if m[0] or m[1] else has(t, new, bool(m[2])) or bool(m[3] and not FLAG.match(t) and all(re.search(r'(?<!\w)' + re.escape(p) + r'(?!\w)', whole) for p in t.split('.')))
                    lost += [] if kept else [t]
                if lost or not name:
                    out.append((name or '(a file the diff header does not name)', ln.strip()[:80], lost or ['its file name']))
    return out


def diff_u0(gdir, rng):
    """The diff DEFAULTS reads: fixed a/ b/ prefixes, no external diff or textconv (a user's diff.noprefix or diff.external hides files)."""
    return git(gdir, 'diff', '--no-ext-diff', '--no-textconv', '--src-prefix=a/', '--dst-prefix=b/', '-U0', rng)


def r_defaults(c):
    if c.get('kind') != 'dev-env':
        return []
    fix = "keep today's value as the fallback (a new key, or an env / config override whose unset path is the old line); a real change of behaviour is no dev-env change: the normal flow (docs, QA), no --kind dev-env"
    if not c.get('diff'):
        return [('DEFAULTS', 'the diff is not readable: no proof the defaults are unchanged', 'pass --dir <wt> (the branch checked out, origin fetched)')]
    return [('DEFAULTS', f'{f}: "{old}" loses {", ".join(lost[:3])}', fix) for f, old, lost in default_changes(c['diff'])[:5]]


RULES = (r_title, r_sections, r_prose, r_how_tested, r_ui, r_docs, r_tracker, r_links, r_commits, r_eol, r_scope, r_loop, r_proof, r_defaults)
KIND_OFF = {'dev-env': {'DOCS', 'PROOF'}}   # a kind's rules that do not apply (no testing docs, no cases)


def run_rules(c):
    return [x for r in RULES for x in r(c) if x[0] not in KIND_OFF.get(c.get('kind'), ())]


# ---- context: texts from the host or the spec, facts from git and the kit's records
def _std():
    from kitbag import writing_standards, prose_check
    kinds, banned = writing_standards(DT.KIT_DIR)
    return lambda kind, text: prose_check(kind, text, kinds[kind], banned) if kind in kinds else []


def git(gdir, *a):
    """git's stdout; '' when it fails (devtools.py _run mixes stderr in: 'fatal: ...' read as file names)."""
    try:
        r = subprocess.run(['git', '-C', gdir, '-c', 'core.quotepath=false', *a], capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
    except (OSError, subprocess.SubprocessError):
        return ''
    return r.stdout if r.returncode == 0 else ''


def git_facts(gdir, base, head):
    """files, commits (sha, message), eol [(path, raw, real)] between base and head in gdir."""
    files = [ln.strip() for ln in git(gdir, 'diff', '--name-only', f'{base}...{head}').splitlines() if ln.strip()]
    log = git(gdir, 'log', '--no-merges', '--format=%H%x1f%B%x1e', f'{base}..{head}')
    commits = [tuple(x.strip().split('\x1f', 1)) for x in log.split('\x1e') if '\x1f' in x]
    num = lambda *o: {ln.split('\t')[2]: int(ln.split('\t')[0]) + int(ln.split('\t')[1]) for ln in git(gdir, 'diff', '--numstat', *o, f'{base}...{head}').splitlines()
                      if ln.count('\t') >= 2 and ln.split('\t')[0].isdigit()}
    raw, real = num(), num('--ignore-cr-at-eol')
    return files, commits, [(p, n, real.get(p, 0)) for p, n in raw.items()]


def loop_facts(tid):
    ok, ev = DT.local_pass(tid)
    return ok, ev, str((getattr(DT.local_pass, 'last', None) or {}).get('head') or '')


def context(tid, title, body, gdir='', base='', head='', ref='', branch=''):
    prose = _std()
    dk = DT.docs() if DT.gate_how('mrBody') == 'builtin:testingDocs' or DT.gate_how('finish') == 'builtin:testingDocs' else []
    docs = [{'label': d['mrLabel'], 'rx': DT.doc_link_rx(d), 'url': DT._pub_read(f'{tid}:{d["key"]}').get('url') if tid else ''} for d in dk if d['required'] and tid]
    text = counted(body, DT.FOOTER, [DT.doc_label_rx(d) for d in DT.docs()])
    c = {'task': tid, 'title': title, 'body': body, 'titleFormat': DT.CFG.get('mrTitleFormat') or '', 'tag': DT.TAG, 'key': DT.task_key(tid) if tid else '',
         'repo': ref.split('!')[0] if '!' in ref else '', 'sections': list(DT.MR_SECTIONS), 'sectionGaps': DT.doc_section_gaps('mr-body', text), 'docs': docs, 'taskLink': DT.task_link(),
         'prose': {k: f for k, f in (('mr-title', prose('mr-title', title)), ('mr-body', prose('mr-body', text))) if f}}
    if gdir and base and head:
        files, commits, eol = git_facts(gdir, base, head)
        c.update(head=head, uiFiles=[f for f in files if DT.UI_FILES.search(f)], eol=eol, commits=[(s, m, prose('commit', m)) for s, m in commits],
                 codeFiles=[f for f in files if not DOC_ONLY.search(f)])
        rn = ((c['repo'] or '').split('/')[-1] or os.path.basename(os.path.normpath(gdir))).lower()
        c['marker'] = next((r.get('commitMarker') or '' for r in DT.CFG.get('repos') or [] if isinstance(r, dict) and rn in [str(x).lower() for x in [r.get('name'), *(r.get('aliases') or [])]]), '')
        c['headMsg'] = git(gdir, 'log', '-1', '--format=%B', head) if c['marker'] else ''
        c['globs'] = DT.scope_of(gdir, DT.SCOPE, ref)
        c['outside'] = DT.scope_outside(files, c['globs']) if DT.scope_refusal(files, c['globs'], branch, ref, 'precheck') else []   # a recorded scope word passes
    if tid:
        c['loopOk'], c['loopEv'], c['loopHead'] = loop_facts(tid)
        if gdir and c.get('loopHead') and head and git(gdir, 'cat-file', '-t', c['loopHead']).strip() == 'commit':   # another repo's loop head: no comparison
            c['sinceLoop'] = [f for f in git(gdir, 'diff', '--name-only', c['loopHead'], head).splitlines() if f.strip() and not DOC_ONLY.search(f)]
        elif c.get('loopHead'):
            c['loopHead'] = ''   # not this repo's: unknown here, never a false stale-head line
            c.pop('codeFiles', None)
        if 'proof' in DT.VERBS:
            with contextlib.redirect_stdout(io.StringIO()) as o:
                DT.VERBS['proof']([tid])
            c['proofGaps'] = [ln.split(': ', 1)[1] for ln in o.getvalue().splitlines() if ln.startswith('GAP ')]
    return c


def loop_gap(tid, gdir, base, head):
    """The LOOP rule for one MR head; devtools.py merge runs it too (2026-11-26: a merge passed while precheck refused LOOP)."""
    c = {'task': tid, 'head': head}
    c['loopOk'], c['loopEv'], c['loopHead'] = loop_facts(tid)
    if gdir and base and head:
        c['codeFiles'] = [f for f in git(gdir, 'diff', '--name-only', f'{base}...{head}').splitlines() if f.strip() and not DOC_ONLY.search(f)]
    if gdir and c['loopHead'] and head and git(gdir, 'cat-file', '-t', c['loopHead']).strip() == 'commit':
        c['sinceLoop'] = [f for f in git(gdir, 'diff', '--name-only', c['loopHead'], head).splitlines() if f.strip() and not DOC_ONLY.search(f)]
    elif c['loopHead']:
        c['loopHead'] = ''
        c.pop('codeFiles', None)
    return r_loop(c)


def merge_loop_gap(m, proj, iid, worktree):
    """devtools.py merge: NOT_MERGED text when the LOOP rule refuses the MR head; '' when no task, it passes or --override (logged)."""
    if str(DT.NO_DOCS).lower().startswith('dev-env'):   # the claim that passed the docs gate is checked here, never taken on word (no override)
        tgt, ok = f'origin/{m.get("target_branch") or "main"}', bool(worktree and os.path.isdir(worktree))
        if bad := r_defaults({'kind': 'dev-env', 'diff': diff_u0(worktree, f'{tgt}...{m.get("sha") or "HEAD"}') if ok else ''}):
            return f'!{iid}: precheck DEFAULTS: {bad[0][1]} -> {bad[0][2]}\nNOT_MERGED'
    tid = DT._mr_task(m, proj, iid)
    gaps = loop_gap(tid, worktree if worktree and os.path.isdir(worktree) else '', f'origin/{m.get("target_branch") or "main"}', m.get('sha') or '') if tid else []
    for g in [g for g in gaps if 'has no head' in g[1]]:   # SKILL.md's checkpoint lines wrote no head (150 of 343): a warning, never a refusal
        print(f'WARNING !{iid}: precheck LOOP: {g[1]}')
        gaps.remove(g)
    if not gaps:
        return ''
    if DT.OVERRIDE:
        DT.kitlog('calls', 'loop-override', {'task': tid, 'mr': f'{proj}!{iid}', 'reason': DT.OVERRIDE})
        return ''
    return f'!{iid}: precheck LOOP: {gaps[0][1]} -> {gaps[0][2]}; --override "<why>" passes, logged\nNOT_MERGED'


def mr_targets(tid, refs, wt, spec):
    """[(ref, title, body, gdir, base, head, branch)] for each MR to check."""
    host = DT.host_kind(DT.GITLAB_HOST)
    if spec:   # before the MR opens: the rendered texts, the worktree's head
        s = json.load(open(spec, encoding='utf-8'))
        tgt = DT.target_of(wt) or 'main'
        return [(f'spec {os.path.basename(spec)}', DT.render_title(s), DT.render_mr_body(s), wt, f'origin/{tgt}', 'HEAD',
                 git(wt, 'rev-parse', '--abbrev-ref', 'HEAD').strip())]
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
        out.append((f'{r[0]}!{r[1]}', m['title'], str(m.get('description') or m.get('body') or ''), gdir, f'origin/{m.get("target_branch") or "main"}', m.get('sha') or '', m.get('source_branch') or ''))
    return out


# ---- verb: precheck <task> [--mr <ref> ...] [--dir <wt>] [--spec <mr.json>] [--kind dev-env] [--json] | selftest
def precheck_cmd(argv):
    if argv[:1] == ['selftest']:
        return selftest()
    opt = lambda k: argv[argv.index(k) + 1] if k in argv[:-1] else ''
    refs = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == '--mr']
    vals = {opt(k) for k in ('--dir', '--spec', '--scope-ok', '--kind')} | set(refs)
    kind = opt('--kind')
    if kind not in KIND_OFF and '--kind' in argv:
        print(f'precheck: --kind {kind!r} is no kind ({", ".join(KIND_OFF)})', file=sys.stderr)
        return 2
    DT.SCOPE_OK = opt('--scope-ok') or DT.SCOPE_OK   # a person's scope word (decide record -Gate scope)
    tid = next((a for a in argv if not a.startswith('-') and a not in vals), '')
    if not (tid or refs or opt('--dir')) or argv[:1] in (['-h'], ['--help']):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    wt = opt('--dir')
    if wt and not tid:
        tid = DT.task_of_branch(DT._run(['git', '-C', wt, 'rev-parse', '--abbrev-ref', 'HEAD']).strip())
    if not kind and tid and ((DT.read_tracking().get('tasks') or {}).get(tid) or {}).get('onMerged') == ['closed']:
        kind = 'dev-env'   # its track record (track add -OnMerged closed): revy's plain precheck reads the same rules
        print(f'precheck {tid}: kind dev-env from its track record (onMerged closed): DOCS and PROOF off, DEFAULTS on', file=sys.stderr)
    found, todo = [], mr_targets(tid, refs, wt, opt('--spec'))
    if not todo:
        print(f'precheck {tid}: no MR (pass --mr, --dir with an open MR, or --spec mr.json)', file=sys.stderr)
        return 2
    for ref, title, body, gdir, base, head, branch in todo:
        c = context(tid, title, body.replace('\r\n', '\n'), gdir, base, head, ref, branch)
        if kind:
            c.update(kind=kind, diff=diff_u0(gdir, f'{base}...{head}') if gdir and base and head else '')
        for code, problem, fix in run_rules(c):
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
    ex('TITLE: no repo suffix on an MR of a known repo', 'TITLE' in codes({**good, 'repo': 'web', 'title': 'fix: save the order - ORD (CU-T1)'}))
    ex('TITLE: empty {code} and {repo} dropped as fmt_line drops them', not {x[0] for x in r_title({**good, 'title': 'fix: save the order (CU-T1)'})} and not r_title({**good, 'title': 'fix: save the order (CU-T1) (web)'}))
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
    ex('COMMITS: a head without repos[].commitMarker; with it, no marker set, or an unread head: none', 'COMMITS' in codes({**good, 'marker': '☑ hooks', 'headMsg': 'fix: x'}) and 'COMMITS' not in codes({**good, 'marker': '☑ hooks', 'headMsg': 'fix: x\n\n☑ hooks'}) and 'COMMITS' not in codes({**good, 'headMsg': 'fix: x'}) and 'COMMITS' not in codes({**good, 'marker': '☑ hooks', 'headMsg': ''}))
    ex('EOL: 486 lines of which 8 real', 'EOL' in codes({**good, 'eol': [('A.java', 486, 8)]}))
    ex('SCOPE: a file outside the globs', 'SCOPE' in codes({**good, 'globs': ['src/orders/**'], 'outside': ['src/chat/a.ts']}))
    ex('LOOP: none, not PASS, and code changed after the PASS head', all('LOOP' in codes({**good, **x}) for x in ({'loopOk': None}, {'loopOk': False}, {'head': 'def5678', 'sinceLoop': ['src/a.ts']})))
    ex('LOOP: a PASS with no head while code changed; no task: no LOOP', 'LOOP' in codes({**good, 'loopHead': '', 'codeFiles': ['a.ts']}) and 'LOOP' not in codes({**good, 'task': '', 'loopOk': None}))
    ex('LOOP: only docs changed after the PASS head', 'LOOP' not in codes({**good, 'head': 'def5678', 'sinceLoop': []}))
    ex('LOOP: an owner word in the PASS evidence passes a changed head', 'LOOP' not in codes({**good, 'head': 'def5678', 'sinceLoop': ['a.ts'], 'loopEv': 'PASS owner word: ship it'}))
    ex('PROOF: proof gaps', 'PROOF' in codes({**good, 'proofGaps': ["check T1 (ui): no PASS case with UI evidence"]}))
    # --kind dev-env (owner 2026-11-26): no testing docs or cases; the diff keeps every default
    hd = lambda f, old, new: f'diff --git a/{f} b/{f}\n--- a/{f}\n+++ b/{f}\n@@ -1 +1 @@\n' + ''.join(f'-{x}\n' for x in old) + ''.join(f'+{x}\n' for x in new)
    keep = hd('app/config.py', ['    BASE_URL = "https://svc.example"', 'def run_it('], ['    # a lane sets BASE_URL; unset = today', '    BASE_URL = (os.getenv("BASE_URL") or "https://svc.example").rstrip("/")', 'def run_it(*, cmd, **kw):', 'def run_proc('])
    dev = {**good, 'kind': 'dev-env', 'docs': [{'label': 'Testing doc', 'rx': re.compile('never'), 'url': ''}], 'proofGaps': ['no cases'], 'diff': keep}
    ex('dev-env: DOCS and PROOF off, an env override that keeps the old value as its fallback passes; without the kind both fire, no DEFAULTS', run_rules(dev) == [] and {'DOCS', 'PROOF'} <= codes({**dev, 'kind': ''}) and 'DEFAULTS' not in codes({**dev, 'kind': '', 'diff': hd('a.py', ['T = 30'], ['T = 60'])}))
    dc = lambda f, old, new: default_changes(hd(f, old, new))
    lost = [dc('a.py', ['TIMEOUT = 30'], ['TIMEOUT = 60']), dc('conf/app.yml', ['host: db.internal'], ['host: db.lane']), dc('a.py', ['x = "keep"'], []), dc('a.py', ['mode = fast_path(a)'], ['mode = slow_path(a)'])]
    ex('DEFAULTS: a changed number, an unquoted config value, a dropped line and a changed call each lose the old value', all(len(x) == 1 for x in lost) and lost[0][0][2] == ['30'] and lost[1][0][2] == ['db.internal'] and 'DEFAULTS' in codes({**dev, 'diff': hd('a.py', ['TIMEOUT = 30'], ['TIMEOUT = 60'])}))
    # review of 755f8356: each of these passed the first cut of the rule
    rows = (('a.json', '"enabled": true,', '"enabled": false,', 'true'), ('a.py', 'x = cfg.get("debug", False)', 'x = cfg.get("debug", True)', 'False'), ('a.py', 'c = make_client(PROD_HOST, "api")', 'c = make_client(LANE_HOST, "api")', 'PROD_HOST'),
            ('a.py', 'timeout = 30', '# timeout = 30', 'timeout'), ('a.py', 'timeout = 30', 'timeout = 60  # was 30', '30'), ('a.py', 'x = -1', 'x = 1', '-1'), ('a.py', 'x = 1', 'x = -1', '1'), ('pom.xml', '<profile>prod</profile>', '<profile>lane</profile>', 'prod'),
            ('a.js', 'audit.log(event)', '', 'audit.log'), ('A.java', 'throw new ForbiddenException();', '', 'throw'), ('run.sh', '--spring.profiles.active=prod', '--spring.profiles.active=lane', 'prod'), ('a.h', '#define TIMEOUT 30', '#define TIMEOUT 60', '30'), ('a.css', 'color: #fff', 'color: #000', 'fff'))
    miss = [r for r in rows if not any(r[3] in x[2] for x in dc(r[0], [r[1]], [r[2]] if r[2] else []))]
    ex(f'DEFAULTS: a flipped boolean, a swapped name, a commented-out or comment-kept value, a sign, an XML value, a dropped call, a -- flag, a #define and a colour each lose a token ({miss})', not miss)
    same = [dc('tests/test_a.py', ['assert x == 3'], ['assert x == 4']), dc('docs/a.md', ['port 80'], ['port 81']), dc('a.py', ['# was 30'], ['# now 60']), dc('a.py', ['import os'], ['import os, sys']), dc('a.py', ["name = 'a'"], ['name = "a"']),
            dc('a.py', ['T = 30  # seconds'], ['T = int(env("T", 30))  # sec']), default_changes(hd('my notes.md', ['port 80'], ['port 81']).replace('my notes.md\n', 'my notes.md\t\n')),
            default_changes(hd('a.py', ['TIMEOUT = 30'], ['import lane']) + '@@ -9 +9 @@\n+TIMEOUT = 30\n'), default_changes('diff --git a/k.bin b/k.bin\nnew file mode 100644\nBinary files /dev/null and b/k.bin differ\n')]
    ex('DEFAULTS: tests, docs, comments, an added name, a quote-style change, a changed trailing comment, a doc path with a space, a line moved between hunks and a new binary are no default; an unread diff fails closed', same == [[]] * 9 and 'DEFAULTS' in codes({**dev, 'diff': ''}))
    hid = [default_changes('diff --git k.py k.py\n--- k.py\n+++ k.py\n@@ -1 +1 @@\n-TIMEOUT = 30\n+TIMEOUT = 60\n'), default_changes('diff --git a/k.jks b/k.jks\nBinary files a/k.jks and b/k.jks differ\n')]
    ex('DEFAULTS: a diff whose header names no file (diff.noprefix) and a replaced binary fail closed', all(len(x) == 1 for x in hid) and hid[1][0][0] == 'k.jks')
    # devtools.py merge runs the LOOP rule too (2026-11-26: a merge passed while precheck refused LOOP); an owner word passes
    mt, lf, gt, g = DT._mr_task, loop_facts, git, globals()
    try:
        DT._mr_task, g['loop_facts'] = (lambda *a: 'T1'), (lambda t: (None, '', ''))
        none = merge_loop_gap({'sha': 'abc'}, 'g/r', '7', '')
        g['loop_facts'] = lambda t: (True, 'PASS owner word: ship', 'old1234')
        own = merge_loop_gap({'sha': 'abc'}, 'g/r', '7', '')
        g['loop_facts'], g['git'] = (lambda t: (True, 'round 1 PASS', '')), (lambda d, *a: 'a.ts\n')
        with contextlib.redirect_stdout(io.StringIO()) as o:
            headless = merge_loop_gap({'sha': 'abc'}, 'g/r', '7', os.getcwd())
        ex('merge: no loop checkpoint -> NOT_MERGED naming LOOP; an owner word merges; a headless PASS warns, merges', 'precheck LOOP' in none and none.endswith('NOT_MERGED') and own == '' and headless == '' and 'has no head' in o.getvalue())
        nd, DT.NO_DOCS, g['loop_facts'] = getattr(DT, 'NO_DOCS', ''), 'dev-env lane settings', (lambda t: (True, 'PASS owner word: ship', ''))
        g['git'] = lambda d, *a: hd('a.py', ['TIMEOUT = 30'], ['TIMEOUT = 60'])
        chg = merge_loop_gap({'sha': 'abc'}, 'g/r', '7', os.getcwd())
        g['git'] = lambda d, *a: keep
        kept, unread = merge_loop_gap({'sha': 'abc'}, 'g/r', '7', os.getcwd()), merge_loop_gap({'sha': 'abc'}, 'g/r', '7', '')
        DT.NO_DOCS = 'foundation area M'
        g['git'] = lambda d, *a: hd('a.py', ['TIMEOUT = 30'], ['TIMEOUT = 60'])
        fnd, DT.NO_DOCS = merge_loop_gap({'sha': 'abc'}, 'g/r', '7', os.getcwd()), nd
        ex("merge --no-docs 'dev-env ...': a changed default or an unread diff -> NOT_MERGED naming DEFAULTS, kept defaults merge; a foundation reason runs no DEFAULTS", 'precheck DEFAULTS' in chg and chg.endswith('NOT_MERGED') and kept == '' and 'DEFAULTS' in unread and fnd == '')
    finally:
        DT._mr_task, g['loop_facts'], g['git'] = mt, lf, gt
    return 0 if all(res) else 1


# ---- areas: devtools.py render wave-brief refuses a brief's area ids and a split whose areas should be one (tests/task-clock.tests.ps1)
def area_gaps(s):
    """A numbered area-<AREA>[-n] id (owner 2026-11-24: ids say what they cover). The split (owner 2026-11-25: each MR costs pipelines
    and builds; split only into disjoint files that run in parallel, else one item and one MR per repo per task): two areas sharing a
    file glob (repos shared or unnamed; a glob named in `overlaps` = a listed one-line hook), or one waiting on another in the same
    repo and task (never parallel)."""
    from fnmatch import fnmatch
    ags, ov = s.get('agents') or [], set(re.findall(r'[^\s,;`]+', str(s.get('overlaps') or '')))
    num = [str(x.get('id')) for x in ags if re.match(r'^area-[A-Za-z]{2,6}(?:-\d+)?$', str(x.get('id') or ''))]
    if num:
        return [f'numbered area ids {", ".join(num)}: name each by what it covers (<feature>-<topic>: ask-prompts, web-orders), or leave the id to the renderer (agents[].area words)']
    repos = lambda x: {r.strip().lower() for r in re.split(r'[,;\s]+', str(x.get('repos') or '')) if r.strip()}
    near = lambda x, y: not repos(x) or not repos(y) or bool(repos(x) & repos(y))
    stem = lambda g: re.split(r'[*?\[]', g.replace('\\', '/'), 1)[0]
    lit = lambda g: stem(g) == g   # a file, no wildcard
    hit = lambda g, h: g == h or (fnmatch(h, g) if lit(h) else fnmatch(g, h) if lit(g) else
                                  bool(stem(g) and stem(h) and (stem(g).startswith(stem(h)) or stem(h).startswith(stem(g)))))
    out = []
    for i, x in enumerate(ags):
        for y in ags[i + 1:]:
            if near(x, y) and (sh := sorted({g for g in x.get('paths') or [] for h in y.get('paths') or [] if hit(g, h) and g not in ov and h not in ov})):
                out.append(f'areas {x.get("id")} and {y.get("id")} share {", ".join(sh)}: one area (one item, one MR per repo per task), or the one-line hook\'s glob in overlaps')
            for p, c in ((x, y), (y, x)):
                if p.get('id') in (c.get('dependsOn') or []) and (c.get('task') or s.get('task')) == (p.get('task') or s.get('task')) and repos(p) & repos(c):
                    out.append(f'area {c.get("id")} waits on {p.get("id")} in {", ".join(sorted(repos(p) & repos(c)))} for one task: never parallel, one area')
    return out


def register(dt):
    global DT
    DT = dt
    dt.VERBS['precheck'] = precheck_cmd
    dt.area_gaps = area_gaps
    dt.merge_loop_gap = merge_loop_gap
