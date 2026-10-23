"""kittool extra flow-map: the interactive kit-flow page and the FLOW-* lint checks (loop bounds, unresolved commands).

  python -X utf8 skills/orchestrate/kittool.py flow [<kit>] [--out <file.html>] [--readme] [--open] [--public]
  python -X utf8 skills/orchestrate/kittool.py lint ...   # adds FLOW-* problems; refreshes the page unless --no-flow

Installed by `kittool.py extra add flow-map`; kittool.py loads it and shares its own names (read, load, graph, lint, kit_path).
Sections: L17 rules · L72 parts · L157 control · L330 parse · L624 link · L853 cycles · L929 pack · L1056 page · L1386 command
Exit codes: 0 ok · 2 usage error.
"""
import hashlib, json, os, re, subprocess, sys, time
import os.path as osp
from collections import defaultdict, deque

ARGS = {'flow': ({'--readme', '--open', '--public'}, {'--out'}, True)}

# ==== the flow model
# ---- rules: patterns for refs, control flow, loops, outcomes
# Nodes: kit parts per file (commands, functions, phases, agent() calls, steps, rows, decisions, control flow, state, config, CLIs).
# Edges: regex refs (reason + file:line, cached per content hash). Issues: dangling refs, unhandled outcomes, unbounded loops.
VER = 11
CODE = ('.ps1', '.psm1', '.py', '.js', '.mjs', '.sh')
STR = re.compile(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"")
FN = {'ps1': re.compile(r'^\s*function\s+([\w-]+)'),
 'js': re.compile(r'^\s*(?:export\s+)?(?:async\s+)?(?:function\s+(\w+)|const\s+(\w+)\s*=\s*(?:async\s*)?(?:\([^)]*\)|\w+)\s*=>)')}
GIT_VERBS = set('add am apply bisect branch checkout cherry-pick clean clone commit config diff fetch for-each-ref init log ls-files '
    'ls-remote merge merge-base mv pull push rebase remote reset restore rev-list rev-parse revert rm show stash status '
    'switch tag update-index worktree'.split())
EXT = [re.compile(r'\bgit(?:\.exe)?\s+(?:-C\s+\S+\s+|-c\s+\S+\s+)*([a-z][a-z-]+)'),
 re.compile(r"""['"]git['"]\s*,\s*(?:['"]-C['"]\s*,\s*[^,\]]+,\s*)?['"]([a-z][a-z-]+)['"]""")]
TOOLS = re.compile(r'\b(glab|gh)\s+(api|mr|pr|ci|run|auth|issue|repo|release)\b|\b(clickup|gws|aws|nr1|adb|emulator|avdmanager)\b'
    r'(?:\s+(?:-s\s+\S+\s+)?([a-z][\w:-]*))?|\b(npm|npx|yarn|pnpm)\s+([a-z][\w-]*)|\b(mvn|mvnw|gradlew?|dotnet|cargo)\b')
CMD = re.compile(r'\b([\w-]+\.(?:ps1|py|mjs))[\'"`]?[ \t]+([a-z_][\w-]*)(?:[ \t]+([a-z][\w-]*))?')
ALIAS_CALL = re.compile(r'(?:\$KitCmd\.(\w+)|\$\{(\w+)\}|&\s*\$(\w+))[\'"`]?[ \t]+([a-z_][\w-]*)(?:[ \t]+([a-z][\w-]*))?')
STATE = re.compile(r"(?:Get-KitPath\s+['\"]?|kit_path\(\s*['\"]|\brp\(\s*['\"]|kitPath\(\s*['\"])([\w-]+)")
JSONF = re.compile(r'(?<![\w/.-])((?:[\w-]+\.)?(?:run|results|launch|contracts|report|tracking|board|seed|decisions?|leases?|state|'
    r'checks|verdicts?|plan|history|outbox|deploys?|signals|learning)\.jsonl?)\b')
WRITE = re.compile(r'Set-Content|Out-File|Add-Content|WriteAll|AppendAll|Export-|New-Item|Move-Item|Copy-Item|Remove-Item|-Create\b|'
    r'write_text|json\.dump|open\([^)]*[\'"][wa]|writeFileSync|appendFileSync|mkdirSync|\b(?:write|append|record|save|update)s?\b', re.I)
# control flow: code on STRIPPED text (comments, strings blanked), docs on steps
CODE_CF = [('parallel', r'\bparallel\(|Promise\.all(?:Settled)?\(|\bpipeline\(|-Parallel\b|Start-ThreadJob|Start-Job\b|ThreadPoolExecutor'),
  ('wait', r'\bStart-Sleep\b|\btime\.sleep\(|\bsetTimeout\(|\bWait-(?:Job|Process|Event)\b|\.wait\(|\bWaitForExit\('),
  ('error', r'\bcatch\b|\btrap\b|\bexcept\b|\.catch\('),
  ('lock', r'\bLocked\b|\blocked\(|O_EXCL|\bMutex\b|\bflock\('),
  ('exit', r'\bexit\s+[0-9]\b|\bsys\.exit\(|\bprocess\.exit\(')]
DOC_CF = [('parallel', r'\bin parallel\b|\bparallel\(|\bpools?\b|\blanes?\b'),
  ('wait', r'\bdecide wait\b|\bwaits? (?:for|until)\b|merge-when-green|memory gate|\bholdMerge\b|\blease\b|seat acquire'),
  ('error', r'roll(?:ed)?[ -]?back|\bbisect\b|\bfallback\b|\brecover\w*\b'),
  ('event', r'\bnotification\b|\bsupervise (?:flag|prints)\b|\bon SessionStart\b'),
  ('human', r"(?:person|owner|tester|human|lead)\s+(?:says|answers|approves|tests|asks|decides)|\bby hand\b|a person's (?:word|yes)")]
CODE_CF = [(k, re.compile(x)) for k, x in CODE_CF]
DOC_CF = [(k, re.compile(x, re.I)) for k, x in DOC_CF]
LOOP_HEAD = {'ps1': re.compile(r'\b(foreach|for|while|until)\s*\(|\bdo\s*\{|\bForEach-Object\b|(?<![\w-])%\s*\{'),
   'js': re.compile(r'\b(for|while)\s*\(|\bdo\s*\{|\.forEach\('),
   'py': re.compile(r'^\s*(for|while)\b(.*):\s*(?:#.*)?$', re.M), 'sh': re.compile(r'\b(for|while|until)\b\s')}
LIMIT = r'(?:max|Max|MAX|cap\b|len\(|limit|Limit|round|Round|tries|Tries|TRIES|attempt|Attempt|timeout|Timeout|deadline|Deadline|budget|Budget|' \
  r'end|End|until|Until|Get-Date|Date\.now|time\.time|monotonic|elapsed|Elapsed|count|Count|length|Length|\$i\b|\bi\b|\bn\b|\d)'
CMP = r'(?:-lt|-le|-gt|-ge|<=?|>=?)'
CRON = re.compile(r"""['"`]([\d*/,-]+ [\d*/,-]+ [\d*/,-]+ [\d*/,-]+ [\d*/,-]+)['"`]""")
DOC_LOOP = re.compile(r'\b(repeat\w*|re-?run\w*|loop(?:s|ing)?)\b|\b(?:at most|max(?:imum)?|up to)\s+\d+\s+(?:rounds?|times|tries|attempts|cycles?)\b', re.I)
DOC_BOUND = re.compile(r'(?:at most|max(?:imum)?|up to|<=|≤)\s*(\d+)\s*(\w+)|(\d+)\s+(rounds?|times|tries|retries|attempts|cycles?)\b|'
     r'every\s+(\d+)\s*(\w+)|\b(weekly|daily|hourly|once|twice)\b', re.I)
OUTCOMES = ('PASS', 'FAIL', 'BLOCKED', 'NONE', 'NOT_TESTED', 'PASS_WITH_NOTE', 'OUT_OF_SCOPE', 'LIVE', 'REFUSED', 'REJECTED', 'ROLLED BACK',
   'NOTICE', 'ACT', 'WATCH', 'INFO', 'MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED',
   'closed', 'failedTesting', 'failed testing', 'in test', 'promoted', '[Bug]', 'merged', 'held', 'deferred', 'blocked')
TERMINAL = {'PASS', 'closed', 'merged', 'MERGED', 'promoted', 'in test', 'LIVE', 'INFO', 'OUT_OF_SCOPE', 'NONE', 'PASS_WITH_NOTE'}
OUT_RX = re.compile(r'(?<![\w-])(' + '|'.join(re.escape(o) for o in sorted(OUTCOMES, key=len, reverse=True)) + r')(?![\w-])')
DSUBJ = {'mode', 'trigger', 'status', 'verdict', 'class', 'mclass', 'result', 'outcome', 'kind', 'state', 'level', 'severity', 'defect',
  'cause', 'trtype', '__trtype', 'reports', 'rtype', 'flag', 'decision', 'answer', 'review', 'learn'}
SUBVAR = ('Action', 'Sub', '__v', 'Verb', 'Op')
FLOW = {'calls', 'runs', 'impl', 'next', 'spawns', 'loads', 'routes', 'branch', 'loop', 'writes', 'reads', 'triggers', 'has'}

# ---- parts: the part model, text helpers
def short(s, n=44):
    s = re.sub(r'[`*]+', '', re.sub(r'\s+', ' ', s or '')).strip()
    return s if len(s) <= n else s[:n].rsplit(' ', 1)[0] + '…'

def lang(f):
    e = osp.splitext(f)[1]
    return {'.ps1': 'ps1', '.psm1': 'ps1', '.py': 'py', '.js': 'js', '.mjs': 'js', '.sh': 'sh', '.md': 'md', '.json': 'json'}.get(e, '')

class P:
    """One file's parse: parts [id, label, kind, line, desc] and refs (resolved later against every file)."""
    def __init__(s, f):
        s.f, s.parts, s.refs, s.text = f, [], [], {}

    def part(s, pid, label, kind, ln, desc='', end=0):
        s.parts.append([pid, label, kind, ln, short(desc, 260), end])
        return pid

    def ref(s, *r):
        s.refs.append(list(r))

def doc_bound(t):
    m = DOC_BOUND.search(t or '')
    if not m:
        return ''
    if m.group(7):
        return m.group(7).lower()
    if m.group(5):
        return f'every {m.group(5)} {m.group(6)}'
    return f'max {m.group(1) or m.group(3)} {m.group(2) or m.group(4)}'

def strip_code(text, lg, keep_tpl=False, keep_str=False):
    """text with comments and string literals blanked (same length, newlines kept), so keyword checks see only code."""
    out, i, n = list(text), 0, len(text)

    def blank(a, b):
        for j in range(a, min(b, n)):
            if out[j] != '\n':
                out[j] = ' '

    def close(q, a, esc):
        j = a
        while j < n and text[j] != q and not (text[j] == '\n' and lg in ('js', 'py')):
            j += 2 if text[j] == esc else 1
        return j + 1
    while i < n:
        c, two = text[i], text[i:i + 2]
        if lg == 'ps1' and two == '<#':
            j = text.find('#>', i)
            j = n if j < 0 else j + 2
        elif lg == 'ps1' and two in ("@'", '@"') and text[i + 2:i + 3] in ('\n', '\r'):
            j = text.find('\n' + two[1] + '@', i)
            j = n if j < 0 else j + 3
        elif (lg in ('ps1', 'py', 'sh') and c == '#') or (lg == 'js' and two == '//'):
            j = text.find('\n', i)
            j = n if j < 0 else j
        elif lg == 'js' and two == '/*':
            j = text.find('*/', i)
            j = n if j < 0 else j + 2
        elif lg == 'py' and text[i:i + 3] in ('"""', "'''"):
            j = text.find(text[i:i + 3], i + 3)
            j = n if j < 0 else j + 3
        elif lg == 'js' and c == '`':
            j, depth = i + 1, 0
            while j < n and not (text[j] == '`' and depth == 0):
                depth += text[j:j + 2] == '${'
                depth -= depth > 0 and text[j] == '}'
                j += 2 if text[j] == '\\' else 1
            j += 1
            if keep_tpl:
                i = j
                continue
        elif c in ('"', "'"):
            j = close(c, i + 1, '`' if lg == 'ps1' else '\\')
            if lg == 'ps1' and c == "'":
                while j < n and text[j] == "'":   # '' is an escaped quote
                    j = close("'", j + 1, '\0')
        else:
            i += 1
            continue
        if not (keep_str and (text[i] in '"\'`' or text[i:i + 2] in ('@"', "@'"))):
            blank(i, j)
        i = max(j, i + 1)
    return ''.join(out)

# ---- control: control flow and refs in code and docs
def code_control(p, src, raw, live, ln, lg, fname='', lns=None):
    """Control-flow points in one code block: loops with their bound (or none), schedules, parallel, waits, errors, locks, exits."""
    def at(pos):
        k = live.count('\n', 0, pos)
        return lns[min(k, len(lns) - 1)] if lns else ln + k
    for kind, rx in CODE_CF:
        m = rx.search(live)
        if m:
            cid = p.part(f'{src}~{kind}', m.group(0).strip('(. '), kind, at(m.start()), raw[max(0, m.start() - 40):m.end() + 120])
            p.ref('edge', src, cid, 'has', m.group(0).strip('(. '), '')
    loops = []
    rx = LOOP_HEAD.get(lg)
    for m in (rx.finditer(live) if rx else []):
        kw = (m.group(1) if m.groups() and m.group(1) else m.group(0)).strip('(.{ ')
        if kw in ('while', 'until') and re.search(r'\}\s*$', live[max(0, m.start() - 40):m.start()]):
            continue   # do { } while tail: the do loop carries it
        if lg == 'py':
            head = m.group(2)
        elif m.group(0).rstrip().endswith('('):
            j, d = m.end(), 1
            while j < len(live) and d:
                d += {'(': 1, ')': -1}.get(live[j], 0)
                j += 1
            head = live[m.end():j - 1]
        else:
            k = re.search(r'\}\s*(while|until)\s*\(([^\n]*)\)', live[m.end():m.end() + 6000])
            head = k.group(2) if k else ''
        body = live[m.end():m.end() + 2500]
        if kw.lower() in ('foreach', 'foreach-object', '%', 'map', 'filter', 'reduce', 'some', 'every') or \
          (lg == 'py' and kw == 'for') or (kw == 'for' and re.search(r'\b(of|in)\b', head) and ';' not in head):
            bound = 'collection'
        elif kw == 'for' and ';' in head:
            bound = 'counter' if re.search(CMP, head) else ''
        elif re.search(CMP, head):
            bound = 'condition'
        elif re.search(r'^\s*\$?\w+\.(?:Count|length)\s*$|^\s*\w+\s*$', head) and not re.search(r'^\s*\$?(true|True|1)\s*$', head):
            bound = 'drain' if re.search(r'Count|length|queue|stack|todo|work|^\s*\w*q\w*\s*$', head) else ''
        else:
            bound = ''
        if not bound and re.search(r'\b(if|elif|elseif)\b[^\n]*' + LIMIT + r'.{0,700}?\b(break|throw|return|raise|exit)\b', body, re.S):
            bound = 'guarded exit'
        if not bound and re.search(r'Split-Path|\.[Pp]arent\b|dirname|rsplit|(\w+)\s*=\s*\w+\[\s*\$?\1\s*\]|\w+\[\w+\[-1\]\]', body[:600] + head):
            bound = 'walk'
        if not bound and re.search(r'\.pop\(|\.shift\(|Dequeue|\+\+|\+=\s*1\b', raw[m.end():m.end() + 600]):
            bound = 'drain / counter'
        loops.append((kw, bound, at(m.start()), raw[m.start():m.start() + 160]))
    if fname and lg in ('ps1', 'py', 'js') and re.search(r'(?<![\w-])' + re.escape(fname) + r'\s*[\s(]', live.split('\n', 1)[-1]):
        loops.append(('recursion', 'structural', ln, fname))
    for m in CRON.finditer(raw):
        mm = re.match(r'\*/(\d+)', m.group(1))
        cid = p.part(f'{src}~timer', f'cron {m.group(1)}', 'timer', at(m.start()), m.group(1))
        p.ref('edge', cid, src, 'triggers', f'cron {m.group(1)}', '')
        p.ref('edge', cid, cid, 'loop', f'every {mm.group(1)} min' if mm else m.group(1), f'every {mm.group(1)} min' if mm else m.group(1))
    m = re.search(r'-IfDue\b|\beveryDays\b|IntervalHours\b|IdleHours\b', live)
    if m:
        cid = p.part(f'{src}~timer', m.group(0), 'timer', at(m.start()), raw[max(0, m.start() - 40):m.end() + 120])
        p.ref('edge', cid, src, 'triggers', m.group(0), '')
        p.ref('edge', cid, cid, 'loop', 'interval: ' + m.group(0).strip('-'), 'interval')
    if loops:
        free = [x for x in loops if not x[1]]
        lab = ', '.join(sorted({x[0] for x in loops}))
        cid = p.part(f'{src}~retry', f'loop: {lab}' + (' (no bound)' if free else ''), 'retry', (free or loops)[0][2],
           '; '.join(f'{k} [{b or "NO BOUND"}] :{l} {short(t, 60)}' for k, b, l, t in loops[:6]))
        p.ref('edge', src, cid, 'has', lab, '')
        b = '' if free else ', '.join(sorted({x[1] for x in loops}))
        p.ref('edge', cid, cid, 'loop', b or 'no bound', b)
        if free:
            p.ref('nobound', cid, f'{p.f}:{free[0][2]}', short(free[0][3], 80))

def doc_control(p, src, text, ln):
    """Control-flow points a doc step states: loops (repeat / rounds / retry, with their bound), schedules, waits, humans ..."""
    for kind, rx in DOC_CF:
        m = rx.search(text)
        if m:
            cid = p.part(f'{src}~{kind}', short(m.group(0), 28), kind, ln + text.count('\n', 0, m.start()), text[max(0, m.start() - 60):m.end() + 140])
            p.ref('edge', *((cid, src, 'triggers') if kind in ('human', 'event') else (src, cid, 'has')), short(m.group(0), 40), '')
    m = re.search(r'every\s+\d+\s*(?:min\w*|h\w*|days?)\b|\b(?:weekly|daily|hourly)\b|\bcron\b[^.\n]*\d', text, re.I)
    if m:
        b = doc_bound(text[m.start():m.end() + 40]) or short(m.group(0), 30)
        cid = p.part(f'{src}~timer', short(m.group(0), 28), 'timer', ln + text.count('\n', 0, m.start()), text[max(0, m.start() - 60):m.end() + 140])
        p.ref('edge', cid, src, 'triggers', short(m.group(0), 40), '')
        p.ref('edge', src, cid, 'has', 'arms ' + short(m.group(0), 30), '')
        p.ref('edge', cid, cid, 'loop', b, b)
    m = DOC_LOOP.search(text)
    if m:
        b = doc_bound(text[max(0, m.start() - 160):m.end() + 200])
        cid = p.part(f'{src}~retry', short(m.group(0), 20) + (f' ({b})' if b else ' (no bound)'), 'retry', ln + text.count('\n', 0, m.start()),
           text[max(0, m.start() - 60):m.end() + 160])
        p.ref('edge', src, cid, 'has', short(m.group(0), 40), '')
        p.ref('edge', cid, cid, 'loop', b or 'no bound', b)
        if not b and re.search(r'(?i)\b(?:repeat\w*|loop\w*)\b[^.\n]{0,80}\buntil\b', text):
            p.ref('nobound', cid, f'{p.f}:{ln + text.count(chr(10), 0, m.start())}', short(text[max(0, m.start() - 40):m.end() + 60], 80))

def scan(p, src, text, ln, code, aliases, mask=None):
    """Refs in one block of text owned by part src: commands, external CLIs, state, config, names, outcomes."""
    base = osp.basename(p.f)
    spans = [(0, text)] if code else [(m.start(1), m.group(1)) for m in re.finditer(r'`([^`]+)`', text)]
    for off, t in spans:
        def at(m):
            pos = off + m.start()
            line = text[text.rfind('\n', 0, pos) + 1:pos]
            if mask is not None:
                return ln + text.count('\n', 0, pos), bool(code and pos < len(mask) and mask[pos] != text[pos])
            return ln + text.count('\n', 0, pos), bool(code and re.search(r'(^|\s)(#|//|\*)', line))
        for m in CMD.finditer(t):
            p.ref('cmd', src, m.group(1), m.group(2), m.group(3) or '', *at(m))
        for m in ALIAS_CALL.finditer(t):
            key = m.group(1) or m.group(2) or m.group(3)
            b = aliases.get(key) or ('kc:' + key if m.group(1) else None)
            if b:
                p.ref('cmd', src, b, m.group(4), m.group(5) or '', *at(m))
        for rx in EXT:
            for m in rx.finditer(t):
                if m.group(1) in GIT_VERBS and not at(m)[1]:
                    p.ref('edge', src, '@ext/git ' + m.group(1), 'calls', f'{base}:{at(m)[0]}', '')
        for m in TOOLS.finditer(t):
            if at(m)[1]:
                continue   # a CLI named in a message / comment is no call
            tool = m.group(1) or m.group(3) or m.group(5) or m.group(7)
            verb = m.group(2) or (m.group(4) if code else '') or m.group(6) or ''
            p.ref('edge', src, '@ext/' + (tool + ' ' + verb).strip(), 'calls', f'{base}:{at(m)[0]}', '')
        for m in re.finditer(r'[\'"`]([a-zA-Z]\w*(?:\.[\w<>-]+)+)[\'"`]|Get-KitSetting\s+[\'"]?([\w.]+)', t if code else '`' + t + '`'):
            p.ref('cfg', src, m.group(1) or m.group(2), at(m)[0])
    for m in STATE.finditer(text):
        p.ref('state', src, m.group(1), 'w' if WRITE.search(text[m.start():m.start() + 240]) else 'r', ln + text.count('\n', 0, m.start()))
    for m in JSONF.finditer(text):
        seg = text[max(0, m.start() - 80):m.end() + 80]
        p.ref('edge', *((src, '@file/' + m.group(1), 'writes') if WRITE.search(seg) else ('@file/' + m.group(1), src, 'reads')),
         f'{base}:{ln + text.count(chr(10), 0, m.start())}', '')
    toks, n, last = {}, ln, 0
    for m in re.finditer(r'(?<![\w$.-])/?[A-Za-z_][\w-]*', text):
        n += text.count('\n', last, m.start())
        last = m.start()
        toks.setdefault(m.group(0), n)
    p.ref('tok', src, sorted(toks.items()), ln)
    for m in re.finditer(r'(?<![\w/.-])((?:[\w-]+/)*[\w.-]+\.md)\b', text):
        p.ref('mdfile', src, m.group(1), ln + text.count('\n', 0, m.start()))
    if code:
        for m in re.finditer(r'\b(orchestrate|dev-kit|qa-kit|local-env|android-swarm)\s+(?:steps?\s+)?([A-Z]{1,3}\d+[a-z]?|\d+)\b', text):
            p.ref('step', src, m.group(1), m.group(2), ln + text.count('\n', 0, m.start()))

def spans_of(lines, lg):
    out = []
    if lg == 'py':
        for i, l in enumerate(lines):
            m = re.match(r'(\s*)(?:async\s+)?def\s+(\w+)', l)
            if m:
                ind, j = len(m.group(1)), i + 1
                while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) > ind):
                    j += 1
                out.append((i, j - 1, m.group(2)))
        return out
    rx = FN.get(lg)
    for i, l in enumerate(lines if rx else []):
        m = rx.match(l)
        if not m:
            continue
        depth, seen, j = 0, False, i
        while j < len(lines):
            s = STR.sub('', lines[j])
            s = s.split('#')[0] if lg == 'ps1' else s
            for ch in s:
                if ch == '{':
                    depth, seen = depth + 1, True
                elif ch == '}':
                    depth -= 1
            if (seen and depth <= 0) or (not seen and j == i and '=>' in l):
                break
            j += 1
        out.append((i, min(j, len(lines) - 1), next(g for g in m.groups() if g)))
    return out

# ---- parse: parts per file kind
def parse_code(p, f, text):
    lg, base = lang(f), osp.basename(f)
    lines = text.split('\n')
    live = strip_code(text, lg).split('\n')
    tlive = strip_code(text, lg, keep_tpl=True).split('\n') if lg == 'js' else live
    sp = spans_of(lines, lg)
    own = [None] * len(lines)
    for a, b, name in sorted(sp, key=lambda x: x[1] - x[0], reverse=True):
        pid = p.part(f'{f}#{name}', name + ('()' if lg != 'ps1' else ''), 'fn', a + 1, lines[a].strip(), b + 1)
        for i in range(a, b + 1):
            own[i] = pid
    aliases = {}
    for m in re.finditer(r'(?:const\s+(\w+)\s*=|\$(\w+)\s*=)\s*[^\n;]*?[\\/]([\w-]+\.(?:ps1|py|mjs))', text):
        aliases[m.group(1) or m.group(2)] = m.group(3)
    consts = {m.group(1): m.group(2) for m in re.finditer(r'const\s+(\w+)\s*=.*?(\d+)\s*$', text, re.M)}
    # commands: dispatch lines (verb -> function) + its sub-verbs
    impl = {}
    for i, l in enumerate(lines):
        m = re.search(r"^\s*'([\w-]+)'\s*\{\s*(?:try\s*\{\s*)?Invoke-KitVerb\s+([\w-]+)|__verb -eq '([\w-]+)'\)\s*\{\s*Invoke-KitVerb\s+([\w-]+)|"
           r"\bcmd\s*==\s*'([\w-]+)'\s*:|'([\w-]+)':\s*lambda[^:]*:\s*(\w+)\(", l)
        if m:
            verb = m.group(1) or m.group(3) or m.group(5) or m.group(6)
            fn = m.group(2) or m.group(4) or m.group(7)
            if not fn and i + 1 < len(lines):
                fn = next((x for x in re.findall(r'(\w+)\(', lines[i + 1]) if x not in ('exit', 'print', 'len', 'str', 'int')), None)
            pre = (own[i].split('#')[-1].replace('_main', '').replace('cmd_', '') + ' ') if m.group(6) and own[i] else ''
            cid = p.part(f'{f}#>{pre}{verb}', f'{base} {pre}{verb}', 'cmd', i + 1, l.strip())
            if fn:
                p.ref('impl', cid, fn, i + 1)
                impl[fn] = (cid, f'{base} {pre}{verb}')
        m = re.search(r"\$_\s+-in\s+((?:'[\w-]+'\s*,?\s*)+)\}\s*\{\s*Invoke-KitVerb\s+([\w-]+)|choices=\[([^\]]+)\]", l)
        for v in re.findall(r"'([\w-]+)'", (m.group(1) or m.group(3)) if m else ''):
            cid = p.part(f'{f}#>{v}', f'{base} {v}', 'cmd', i + 1, l.strip())
            if m.group(2):
                p.ref('impl', cid, m.group(2), i + 1)
                impl.setdefault(m.group(2), (f, base))
        m = re.search(r'Invoke-KitVerb\s+([\w-]+)\s+@\(\$args\)', l)   # args passed on: the function's verbs are the script's
        if m:
            impl[m.group(1)] = (f, base)
        m = re.match(r"\s*(COMMANDS|[A-Z_]*VERBS|[A-Z_]*EXTRA[A-Z_]*)\s*=\s*\{", l) if lg == 'py' else None   # verb tables: COMMANDS (verb: fn), EXTRA_OF (verb: 'extra')
        tbl = ''
        for j in range(i, min(len(lines), i + 12)) if m else ():
            tbl += live[j] + '\n'
            if tbl.count('{') <= tbl.count('}'):
                break
        for v, fn, ex in re.findall(r"'([\w -]+)':\s*(?:([a-z_]\w*)\s*(?=[,}])|'([\w-]+)')", '\n'.join(lines[i:i + tbl.count('\n')]) if m else ''):
            if fn and not any(nm == fn for _, _, nm in sp) or ex and 'EXTRA' not in m.group(1):
                continue
            cid = p.part(f'{f}#>{v}', f'{base} {v}', 'cmd', i + 1, l.strip() if fn else f'extra {ex}: {l.strip()}')
            if fn:
                p.ref('impl', cid, fn, i + 1)
                impl.setdefault(fn, (cid, f'{base} {v}'))
    # ps1 dispatch: each case of `switch ($__verb)` is a verb (`'v' {` or `{ $_ -in 'a', 'b' } {`); its function = the case's first Invoke-KitVerb
    for i, l in enumerate(lines):
        if lg != 'ps1' or not re.match(r'\s*switch\s*\(\s*\$__verb\s*\)\s*\{', l):
            continue
        cases = []
        for j in range(i + 1, len(lines)):
            mm = re.match(r"^(\s*)(?:'([\w-]+)'|\{\s*\$_\s+-in\s+((?:'[\w-]+'\s*,?\s*)+)\})\s*\{", lines[j])
            if mm and (not cases or len(mm.group(1)) == cases[0][1]):
                cases.append((j, len(mm.group(1)), [mm.group(2)] if mm.group(2) else re.findall(r"'([\w-]+)'", mm.group(3))))
            elif re.match(r'\s*default\s*\{', lines[j]) and (not cases or len(lines[j]) - len(lines[j].lstrip()) == cases[0][1]) or len(lines[j]) - len(lines[j].lstrip()) <= len(l) - len(l.lstrip()) and lines[j].strip() == '}':
                cases.append((j, -1, []))
                break
        for (j, _, vs), (nxt, _, _) in zip(cases, cases[1:]):
            fn = re.search(r'Invoke-KitVerb\s+(Invoke-[\w-]+)', '\n'.join(live[j:nxt]))
            for v in vs:
                if v.startswith('-') or v == 'help':
                    continue
                cid = p.part(f'{f}#>{v}', f'{base} {v}', 'cmd', j + 1, lines[j].strip())
                if fn:
                    p.ref('impl', cid, fn.group(1), j + 1)
                    impl.setdefault(fn.group(1), (cid, f'{base} {v}'))
    for a, b, name in sp:
        if name not in impl:
            continue
        cid, label = impl[name]
        vs = re.search(r"ValidateSet\(([^)]*)\)\]\s*\[string\]\s*\$(?:%s)\b" % '|'.join(SUBVAR), '\n'.join(lines[a:a + 6]))
        for sv in re.findall(r"'([\w-]+)'", vs.group(1) if vs else ''):
            sid = p.part(f'{f}#>{label.split(" ", 1)[-1] if label != base else ""} {sv}'.replace('> ', '>'), f'{label} {sv}', 'cmd', a + 1, lines[a].strip()[:200])
            p.ref('edge', sid, f'{f}#{name}', 'impl', f'{base}:{a + 1}', '')
            if cid != f:
                p.ref('edge', cid, sid, 'next', 'sub-verb', '')
        for i in range(a, b + 1):
            m = re.search(r"\$(?:%s)\s+-(?:c?eq|in)\s+'([\w-]+)'(?:\s*,\s*'([\w-]+)')*|^\s*'([\w-]+)'\s*(?:,\s*'[\w-]+'\s*)*\{" % '|'.join(SUBVAR), lines[i])
            if m and (m.group(1) or (m.group(3) and any(re.search(r'switch\s*\(\s*\$(?:%s)\s*\)' % '|'.join(SUBVAR), lines[j]) for j in range(max(a, i - 400), i)))):
                sv = m.group(1) or m.group(3)
                sid = p.part(f'{f}#>{label.split(" ", 1)[-1] if label != base else ""} {sv}'.replace('> ', '>'), f'{label} {sv}', 'cmd', i + 1, lines[i].strip())
                p.ref('edge', sid, f'{f}#{name}', 'impl', f'{base}:{i + 1}', '')
                if cid != f:
                    p.ref('edge', cid, sid, 'next', 'sub-verb', '')
    # decisions: comparisons, switches (outcome per case), enums
    ekeys = set(re.findall(r"(\w+):\s*\{\s*type:\s*'string',\s*enum:", text))
    for i, l in enumerate(lines):
        src = own[i] or f
        for m in re.finditer(r"([\w$.\]\[]+?)\s*(?:===?|!==?|-c?eq|-ne|==|!=)\s*'([^'\n]{1,24})'", l):
            if live[i][m.start():m.start() + 1] in (' ', ''):
                continue   # inside a comment or a string
            subj, val = m.group(1).lstrip('$').split('.')[-1].strip('[]'), m.group(2)
            if subj in SUBVAR + ('__verb', 'cmd') or not re.match(r'^[\w \[\]-]{1,24}$', val) or not (
              subj in ekeys or re.match(r'^[A-Z][A-Z_ ]+$', val) or subj.lower() in DSUBJ):
                continue
            decision(p, f, src, subj, val, lines, i, base)
        m = re.match(r'\s*switch\s*(?:-\w+\s*)*\(\s*\$([\w.]+)\s*\)', live[i])
        if m and m.group(1).split('.')[-1] not in SUBVAR + ('__verb',):
            ind = None
            for j in range(i + 1, min(len(lines), i + 200)):
                mm = re.match(r"^(\s*)'([^']+)'\s*\{", lines[j])
                if mm and (ind is None or len(mm.group(1)) == ind) and re.match(r'^[\w -]{1,24}$', mm.group(2)):
                    ind = len(mm.group(1))
                    decision(p, f, own[i] or f, m.group(1).split('.')[-1], mm.group(2), lines, j, base)
                elif ind is not None and lines[j].strip() == '}' and len(lines[j]) - len(lines[j].lstrip()) < ind:
                    break
    for m in re.finditer(r"(\w+):\s*\{\s*type:\s*'string',\s*enum:\s*\[([^\]]+)\]", text):
        did = f'{f}#?{m.group(1)}'
        p.part(did, m.group(1) + ' ?', 'decision', text.count('\n', 0, m.start()) + 1, m.group(0))
        p.ref('enum', did, re.findall(r"'([^']+)'", m.group(2)))
    # workflows: phases, slash entry, agent() calls + loops, exit
    if f.startswith('workflows/'):
        name = base.rsplit('.', 1)[0]
        wd = re.search(r"whenToUse:\s*'((?:[^'\\]|\\.)*)'", text)
        slash = p.part(f'{f}#/{name}', '/' + name, 'slash', 1, wd.group(1) if wd else '')
        p.ref('edge', slash, f, 'runs', 'top-level code', '')
        phases = re.findall(r"\{\s*title:\s*'([^']+)',\s*detail:\s*'((?:[^'\\]|\\.)*)'", text)
        prev = slash
        for t, d in phases:
            pid = p.part(f'{f}#phase:{t}', t, 'phase', 1, d)
            p.ref('edge', prev, pid, 'next', 'then', '')
            prev = pid
        ex = p.part(f'{f}#exit', 'return report', 'exit', len(lines), 'the workflow returns its report to the coordinator')
        p.ref('edge', prev, ex, 'next', 'done', '')
        calls, last_phase = [], None
        for m in re.finditer(r"\bphase\('(\w+)'\)|\bawait\s+agent\(", text):
            if m.group(1):
                last_phase = m.group(1)
                continue
            ln = text.count('\n', 0, m.start()) + 1
            end = text.find('})', text.find('label', m.start()))
            reg = text[m.start():end if end > 0 else m.start() + 3000]
            lab = re.search(r"label(?::\s*[`']([\w-]+))?", reg)
            cname = (lab.group(1) if lab and lab.group(1) else f'agent@{ln}').rstrip('-:')
            ph = re.search(r"phase:\s*'(\w+)'", reg)
            cid = p.part(f'{f}#call:{cname}', 'agent ' + cname, 'call', ln, reg[:400])
            p.ref('edge', own[ln - 1] or f, cid, 'calls', f'{base}:{ln}', '')
            phn = ph.group(1) if ph else last_phase
            if phn:
                p.ref('edge', f'{f}#phase:{phn}', cid, 'runs', f'phase {phn}', '')
            at = re.search(r"agentType:\s*'([\w-]+)'", reg)
            if at:
                p.ref('edge', cid, f'agents/{at.group(1)}.md', 'spawns', f'agentType {at.group(1)}', '')
            pf = re.match(r'await\s+agent\(\s*(\w+)\(', reg)
            if pf:
                p.ref('fn', cid, [pf.group(1)], ln)
            scan(p, cid, reg, ln, True, aliases)
            back = '\n'.join(lines[max(0, ln - 7):ln])
            lm = re.search(r'for\s*\(let\s+\w+\s*=\s*0;\s*\w+\s*<\s*([\w.]+)', back)
            if lm:
                b = consts.get(lm.group(1), lm.group(1))
                p.ref('edge', cid, cid, 'loop', f'repeat, max {b}', f'max {b}')
            if re.search(r'retry|retest|strong|resume|again', cname) and calls:
                p.ref('edge', cid, calls[-1], 'loop', cname, '')
            calls.append(cid)
    # per-line refs, then control flow per part
    blocks = defaultdict(list)
    for i, l in enumerate(lines):
        blocks[own[i] or f].append((i + 1, l))
    for src, bl in blocks.items():
        t = '\n'.join(l for _, l in bl)
        scan(p, src, t, bl[0][0], True, aliases, '\n'.join(tlive[n - 1] for n, _ in bl))
        p.ref('fn', src, sorted(set(re.findall(r'([A-Za-z_][\w-]*)\s*\(' if lg != 'ps1' else r'(?<![\w$.-])([A-Za-z_][\w-]*)', t))), bl[0][0])
        if src != f:
            code_control(p, src, t, '\n'.join(live[n - 1] for n, _ in bl), bl[0][0], lg, src.split('#')[-1] if '#' in src else '', [n for n, _ in bl])

def decision(p, f, src, subj, val, lines, i, base):
    did = f'{f}#?{subj}'
    if not any(x[0] == did for x in p.parts):
        p.part(did, subj + ' ?', 'decision', i + 1, lines[i].strip())
        p.ref('edge', src, did, 'calls', f'{base}:{i + 1} decides on {subj}', '')
    near = '\n'.join(lines[i:i + 8])
    lab = re.search(r"label:\s*[`']([\w-]+)", near)
    if lab:
        p.ref('edge', did, f'{f}#call:{lab.group(1).rstrip("-:")}', 'branch', f'= {val}', '')
        return
    p.ref('branch', did, val, near[:500], i + 1)

def parse_md(p, f, text):
    sec, cur, prev_step, buf, intable, tdec, fence = f, f, None, defaultdict(list), False, None, False
    cbuf, lines = defaultdict(list), text.split('\n')
    aliases = {m.group(1): m.group(2) for m in re.finditer(r"\$(\w+)\s*=\s*'[^'\n]*?([\w-]+\.(?:ps1|py|mjs))'", text)}
    for i, l in enumerate(lines):
        ln = i + 1
        if l.startswith('```'):
            fence = False if fence else ('skip' if 'mermaid' in l else True)
            continue
        im = re.match(r'^@([\w./-]+\.md)\s*$', l)
        if im:
            p.ref('edge', f, im.group(1), 'loads', 'import', '')
        if fence == 'skip':
            continue
        h = re.match(r'^(#{1,3})\s+(.+)', l) if not fence else None
        if h:
            p.ref('edge', sec, f'{f}#§{short(h.group(2), 40)}', 'next', 'then' if sec != f else 'first', '')
            sec = cur = p.part(f'{f}#§{short(h.group(2), 40)}', short(h.group(2), 40), 'section', ln, h.group(2))
            prev_step, intable = None, False
            continue
        st = re.match(r'^\s{0,2}(?:[-*]\s+)?\**([A-Z]{1,3}\d+[a-z]?)\.\**\s+(.*)|^(\d+)\.\s+(.*)', l)
        row = re.match(r'^\|\s*\**([A-Z]{1,3}\d+[a-z]?)\**\s*\|(.*)', l)
        if l.startswith('|') and not intable and i + 1 < len(lines) and re.match(r'^\|[\s:|-]+\|?$', lines[i + 1]):
            intable, tdec = True, None
            continue
        if not l.startswith('|'):
            intable = False
        if row:
            cells = [c.strip() for c in row.group(2).strip().strip('|').split('|')]
            if not tdec:
                tdec = p.part(f'{sec}?', short(sec.split('#§')[-1], 30) + ' ?', 'decision', ln, 'first matching row wins')
                p.ref('edge', sec, tdec, 'next', 'which row?', '')
            cur = p.part(f'{f}#{row.group(1)}', f'{row.group(1)} {short(cells[0], 34)}', 'row', ln, ' | '.join(cells))
            p.ref('edge', tdec, cur, 'branch', short(cells[0], 60), '')
            buf[cur].append((ln, ' '.join(cells[1:]) + ' ' + cells[0]))
            continue
        fs = re.search(r'#\s+(\d+[a-z]?)\.\s+(\S.*)$', l) if fence else None
        if fs:
            st = re.match(r'(?P<a>)?(?P<b>)?(\d+[a-z]?)\.\s+(.*)', fs.group(1) + '. ' + fs.group(2))
        if st and (not fence or fs):
            sid = st.group(1) or (short(sec.split('#§')[-1], 18) + '/' + st.group(3))
            cur = p.part(f'{f}#{sid}', f'{st.group(1) or st.group(3)}. {short(st.group(2) or st.group(4), 34)}', 'step', ln, st.group(2) or st.group(4))
            if prev_step:
                p.ref('edge', prev_step, cur, 'next', 'then', '')
            else:
                p.ref('edge', sec, cur, 'next', 'first', '')
            prev_step = cur
        elif not l.strip() and not fence:
            cur = sec
        (cbuf if fence else buf)[cur].append((ln, l))
    for src, bl in cbuf.items():
        scan(p, src, '\n'.join(l for _, l in bl), bl[0][0], True, aliases)
    for src, bl in buf.items():
        t = '\n'.join(l for _, l in bl)
        scan(p, src, t, bl[0][0], False, {})
        doc_control(p, src, t, bl[0][0]) if src != f else None
        for m in re.finditer(r'\b([\w-]+)(?: SKILL\.md)?\s+(?:steps?\s+(\d+|[A-Z]{1,3}\d+[a-z]?)|([A-Z]{1,3}\d+[a-z]?))\b', t):
            p.ref('step', src, m.group(1), m.group(2) or m.group(3), bl[0][0])
        for m in re.finditer(r'(?<![\w#-])([A-Z]{1,3}\d{1,2}[a-z]?)(?![\w-])', t):
            p.ref('step', src, '', m.group(1), bl[0][0])
        arrows = [a for a in re.split(r'\s[·;]\s|\.\s(?=[A-Z])|\n', t) if re.search(r'->|→', a)]
        for a in arrows:
            left, right = re.split(r'\s*(?:->|→)\s*', a, maxsplit=1)
            p.ref('arrow', src, short(left.split(':')[-1], 50), right[:300], bl[0][0], len(arrows))

def parse_json(p, f, text):
    try:
        d = json.loads(text)
    except ValueError:
        return
    if '.example.' in f and isinstance(d.get('_paths'), dict):
        for sect in ('runtime', 'durable'):
            for k, v in (d['_paths'].get(sect) or {}).items():
                p.part(f'@state/{k}', k, 'state', 1, f'{sect}: {v}')
    if osp.basename(f) == 'settings.json':
        for ev, bl in (d.get('hooks') or {}).items():
            for b in bl:
                eid = p.part(f'{f}#{ev}{" " + b["matcher"] if b.get("matcher") else ""}', ev + (f' ({b["matcher"]})' if b.get('matcher') else ''),
                   'event', 1, 'Claude Code runs these hooks on ' + ev)
                for h in b.get('hooks', []):
                    scan(p, eid, ' '.join([h.get('command', '')] + list(h.get('args', []))).replace('/', ' / '), 1, True, {})
                    scan(p, eid, ' '.join([h.get('command', '')] + [osp.basename(x) for x in h.get('args', [])]), 1, True, {})
    elif '.example.' in f:
        def walk(o, pre, depth):
            for k, v in o.items():
                if k.startswith('_') or k.startswith('<'):
                    continue
                key = pre + k
                p.part(f'@config/{key}', key, 'config', 1, json.dumps(v)[:200] if not isinstance(v, dict) else (v.get('_readme') or ''))
                if isinstance(v, dict) and depth < 2:
                    walk(v, key + '.', depth + 1)
        walk(d, '', 0)

def parse(f, text):
    p = P(f)
    lg = lang(f)
    if f.startswith('.githooks/'):
        ev = {'pre-commit': 'git commit', 'pre-push': 'git push', 'post-merge': 'git pull / merge'}.get(osp.basename(f), 'git hook')
        eid = p.part(f'{f}#{ev}', ev, 'event', 1, f'git runs {f} (core.hooksPath)')
        scan(p, eid, text, 1, True, {})
    elif lg in ('ps1', 'py', 'js', 'sh'):
        parse_code(p, f, text)
    elif lg == 'md':
        parse_md(p, f, text)
    elif lg == 'json':
        parse_json(p, f, text)
    return {'parts': p.parts, 'refs': p.refs}

# ---- link: the model, edges, issues
def model(k, problems, cache_path=None):
    """The page data: files, nodes, edges (with back-edge / loop flags), cycles, issues."""
    cache = {}
    if cache_path and osp.isfile(cache_path):
        try:
            with open(cache_path, encoding='utf-8') as fh:
                cache = json.load(fh)
        except (OSError, ValueError):
            cache = {}
    if cache.get('v') != VER:
        cache = {'v': VER, 'files': {}}
    parsed = {}
    for f in k.files:
        t = k.texts.get(f, '')
        if f.endswith('.md'):   # raw file (k.texts expands @imports)
            try:
                with open(osp.join(k.dir, f), encoding='utf-8', errors='replace') as fh:
                    t = fh.read().replace('\r\n', '\n')
            except OSError:
                pass
        h = hashlib.sha1(t.encode('utf-8', 'replace')).hexdigest()
        c = cache['files'].get(f)
        if not c or c['h'] != h:
            c = cache['files'][f] = {'h': h, 'p': parse(f, t)}
        parsed[f] = c['p']
    cache['files'] = {f: v for f, v in cache['files'].items() if f in parsed}
    if cache_path:
        try:
            os.makedirs(osp.dirname(cache_path), exist_ok=True)
            with open(cache_path, 'w', encoding='utf-8') as fh:
                json.dump(cache, fh)
        except OSError:
            pass
    return link(k, parsed, problems)

def fkind(f):
    b = osp.basename(f)
    return ('skill' if b == 'SKILL.md' else 'agent' if f.startswith('agents/') else 'workflow' if f.startswith('workflows/') else
      'script' if f.endswith(CODE) or f.startswith('.githooks/') else 'doc')

def link(k, parsed, problems):
    N, E, issues, grp = {}, {}, [], {}

    def node(i, label, kind, f, ln=0, d='', end=0):
        if i not in N:
            N[i] = [i, label, kind, f, ln, d, end]
        return i

    for f in k.files:
        lab = f.split('/')[1] if fkind(f) == 'skill' else osp.basename(f)
        node(f, lab, 'file', f, 1, '')
        for pid, label, kind, ln, d, *end in parsed[f]['parts']:
            node(pid, label, kind, f, ln, d, (end or [0])[0])
    node('@session', 'every session', 'event', '(events)', 0, 'the harness loads CLAUDE.md (+ imports) and the always-on rules')
    PSEUDO = {'ext': '(external CLIs)', 'file': '(shared files)', 'outcome': '(outcomes)', 'state': '(state)', 'config': '(config)'}

    def ensure(i):
        if i in N:
            return True
        m = re.match(r'@(\w+)/(.+)$', i)
        if m and m.group(1) in ('ext', 'file', 'outcome'):
            node(i, m.group(2), {'file': 'state'}.get(m.group(1), m.group(1)), PSEUDO[m.group(1)], 0, '')
            return True
        return False

    def edge(a, b, kind, label='', bound=''):
        if a and b and ensure(a) and ensure(b) and (a != b or kind == 'loop'):
            key = (a, b, kind)
            if key not in E:
                E[key] = [a, b, kind, (label or '')[:140], bound or '']

    fns = defaultdict(list)
    cmds = defaultdict(dict)
    steps = defaultdict(dict)
    for i, n in N.items():
        if n[2] == 'fn':
            fns[n[1].rstrip('()')].append(i)
        elif n[2] == 'cmd':
            parts = n[1].split(' ', 1)
            cmds[parts[0]][parts[1] if len(parts) > 1 else ''] = i
        elif n[2] in ('step', 'row'):
            steps[n[3]].setdefault(i.split('#', 1)[1].split('/')[-1], i)
    kc = {m.group(1): m.group(2) for m in re.finditer(r'^\s*(\w+)\s*=\s*Join-Path \$KitConf\.Kit \'[^\']*?([\w-]+\.\w+)\'', k.texts.get('skills/dev-kit/lib.ps1', ''), re.M)}
    skills = {s: f'skills/{s}/SKILL.md' for s in k.skills}
    agents = dict(k.agents)
    wfs = {'/' + w: f'{p}#/{w}' for w, p in k.workflows.items()}
    cfg = {n[1] for n in N.values() if n[2] == 'config'}
    states = {n[1] for n in N.values() if n[2] == 'state' and n[0].startswith('@state/')} | {'runtime'}

    def resolve_fn(name, f):
        c = fns.get(name, [])
        same = [x for x in c if x.startswith(f + '#')]
        lib = [x for x in c if x.startswith('skills/dev-kit/lib.ps1#')] if f.endswith('.ps1') else []
        c = [x for x in c if lang(x.split('#')[0]) == lang(f) or (lang(f) == 'md' and lang(x.split('#')[0]) == 'ps1')]
        return (same or lib or (c if len(c) == 1 else []) or [None])[0]

    def resolve_cmd(base, verb, sub):
        base = kc.get(base[3:], base) if base.startswith('kc:') else base
        if base not in cmds:
            return None, None
        if verb in ('-File', 'File'):
            return None, None
        c = cmds[base]
        hit = c.get(f'{verb} {sub}'.strip()) or c.get(verb)
        return hit, (None if hit or not c or verb in ('-', '') else f'{base} {verb}')

    for f in k.files:
        if f == 'CLAUDE.md' or re.match(r'rules/[^/]+\.md$', f) and 'paths:' not in k.texts.get(f, '')[:300]:
            E[('@session', f, 'triggers')] = ['@session', f, 'triggers', 'always loaded', '']
    unres = defaultdict(set)
    for f in k.files:
        for r in parsed[f]['refs']:
            kind, src = r[0], r[1]
            if kind == 'edge':
                edge(r[1], r[2], r[3], r[4], r[5])
            elif kind == 'impl':
                edge(src, resolve_fn(r[2], f), 'impl', f'{osp.basename(f)}:{r[3]}')
            elif kind == 'cmd':
                hit, miss = resolve_cmd(r[2], r[3], r[4])
                if hit and r[6] and hit.split('#')[0] == f:
                    continue   # own usage comment, not a call
                if hit:
                    edge(src, hit, 'calls' if N.get(src, [0, 0, ''])[2] == 'fn' else 'runs', f'{osp.basename(f)}:{r[5]}')
                elif miss and not r[6] and re.match(r'^[a-z][a-z-]+$', r[3]) and r[3] not in ('and', 'or', 'the', 'to', 'in', 'is', 'with', 'from', 'for', 'then', 'only'):
                    unres[miss].add(f'{f}:{r[5]}')
            elif kind == 'fn':
                for name in r[2]:
                    t = resolve_fn(name, f)
                    if t and t != src and not t.startswith(src + '~'):
                        edge(src, t, 'calls', f'{osp.basename(f)}:{r[3]}')
            elif kind == 'tok':
                for tok, r3 in r[2]:
                    if tok in skills and not f.startswith(f'skills/{tok}/'):
                        edge(src, skills[tok], 'loads', f'{osp.basename(f)}:{r3} names {tok}')
                    elif tok in agents and agents[tok] != f:
                        edge(src, agents[tok], 'spawns' if 'spawn' in (N[src][5] or '').lower() or f.startswith('workflows/') else 'loads',
                         f'{osp.basename(f)}:{r3} names {tok}')
                    elif tok in wfs and not f.startswith('workflows/'):
                        edge(src, wfs[tok], 'loads' if f.startswith('agents/') else 'runs', f'{osp.basename(f)}:{r3} launches {tok}')
                    elif f.endswith('.md') and re.match(r'^[A-Z][\w]*-[A-Z]\w+$', tok) and tok in fns:
                        edge(src, resolve_fn(tok, f), 'runs', f'{osp.basename(f)}:{r3} names {tok}')
            elif kind == 'state':
                if r[2] in states:
                    if r[2] == 'runtime':
                        continue
                    edge(*((src, '@state/' + r[2], 'writes') if r[3] == 'w' else ('@state/' + r[2], src, 'reads')), f'{osp.basename(f)}:{r[4]}')
                else:
                    unres[f'state {r[2]}'].add(f'{f}:{r[4]}')
            elif kind == 'cfg':
                key = r[2]
                while key and key not in cfg:
                    key = key.rsplit('.', 1)[0] if '.' in key else ''
                if key and not re.search(r'\.(ps1|py|m?js|json|md|html|txt|sh|exe)$', r[2]):
                    edge('@config/' + key, src, 'reads', f'{osp.basename(f)}:{r[3]} reads {r[2]}')
            elif kind == 'step':
                sk, sid = r[2], r[3]
                tf = skills.get(sk) or (f if not sk else None)
                if tf and sid in steps.get(tf, {}):
                    t = steps[tf][sid]
                    if t != src:
                        edge(src, t, 'loads' if tf != f else 'next', f'{osp.basename(f)}:{r[4]} {sk + " " if sk else ""}{sid}')
                elif sk in skills:
                    unres[f'{sk} step {sid}'].add(f'{f}:{r[4]}')
            elif kind == 'branch':
                tgt = branch_target(r[3], f, cmds, kc, N)
                edge(src, tgt or '@outcome/' + r[2], 'branch', f'= {r[2]}')
            elif kind == 'arrow':
                tgt = branch_target(r[3], f, cmds, kc, N, steps.get(f, {}), skills, wfs)
                if tgt:
                    s2 = src
                    if r[5] >= 2:
                        s2 = node(src + '?', short(N[src][1], 24) + ' ?', 'decision', f, N[src][4], N[src][5])
                        edge(src, s2, 'next', 'decides')
                    edge(s2, tgt, 'branch', r[2])
            elif kind == 'enum':
                pass
            elif kind == 'mdfile':
                hit = [x for x in k.files if x == r[2] or x.endswith('/' + r[2])]
                if len(hit) == 1 and hit[0] != f:
                    edge(src, hit[0], 'reads', f'{osp.basename(f)}:{r[3]} names {r[2]}')
    # handled = any branch, case, map key or row in the kit names it (code: outside comments)
    alltext = '\n'.join(strip_code(k.texts.get(f, ''), lang(f), keep_str=True) if lang(f) in ('ps1', 'py', 'js') else k.texts.get(f, '')
         for f in k.files)

    def handled(v):
        q = re.escape(v)
        return bool(re.search(r"(?:===?|!==?|==|!=|-c?eq|-c?ne|-c?in|-notin|\bin\b|includes\(|\bcase|has\()\s*[\[(]?\s*['\"]" + q + r"['\"]|"
             r"['\"]" + q + r"['\"]\s*(?::|=>|\)\s*\{|\s*\{)|^\|\s*`?" + q + r"`?\s*\||(?<![\w-])" + q + r"(?![\w-])[^\n]{0,40}?(?:->|→)", alltext, re.M))
    for f in k.files:
        for r in parsed[f]['refs']:
            if r[0] == 'enum':
                br = {e[3][2:] for e in E.values() if e[0] == r[1] and e[2] == 'branch'}
                for v in r[2]:
                    if v not in br:
                        edge(r[1], '@outcome/' + v, 'branch', f'= {v} (schema)')
                    if v not in br and v not in TERMINAL and not handled(v):
                        issues.append({'code': 'UNHANDLED', 'node': r[1], 'text': f'{N[r[1]][1]} outcome {v}: nothing branches on it ({f}:{N[r[1]][4]})'})
            elif r[0] == 'nobound':
                issues.append({'code': 'NO-BOUND', 'node': r[1], 'text': f'{r[2]}: loop with no bound ({r[3]})'})
    for miss, where in sorted(unres.items()):
        issues.append({'code': 'UNRESOLVED', 'node': sorted(where)[0].rsplit(':', 1)[0], 'text': f'{miss}: no such command/step ({", ".join(sorted(where)[:3])})'})
    for i, n in N.items():
        if n[2] == 'decision' and (n[3].endswith('.md') or n[3].startswith('workflows/')):
            outs = [e for e in E.values() if e[0] == i and e[2] == 'branch']
            vals = {e[1][9:] for e in outs}
            if outs and all(e[1].startswith('@outcome/') for e in outs) and not any(v in TERMINAL or handled(v) for v in vals):
                issues.append({'code': 'DEAD-END', 'node': i, 'text': f'{n[1]}: outcomes {", ".join(sorted(vals))} lead nowhere ({n[3]}:{n[4]})'})
    for i, n in list(N.items()):
        if not i.startswith('@outcome/'):
            continue
        rx = re.compile(r'(?<![\w-])' + re.escape(n[1]) + r'(?![\w-])')
        for j, r in N.items():
            if r[2] == 'row' and r[3].endswith('.md') and rx.search((r[5] or '').split(' | ')[0]):
                edge(i, j, 'triggers', 'handled by ' + r[1])
    named = named_cycles(N, E, issues)
    for it in issues:   # a deliberate one carries a `flow: <reason>` marker at its source line (or the line above): listed, not counted
        it['flow'] = True
        m = re.search(r'([\w./-]+\.(?:ps1|py|js|mjs|md)):(\d+)', it['text'])
        if m and m.group(1) in k.texts:
            ls = k.texts[m.group(1)].split('\n')
            near = ' '.join(ls[max(0, int(m.group(2)) - 2):int(m.group(2))])
            mk = re.search(r'flow:\s*([^\n]+?)\s*(?:#>|-->|\*/)?\s*$', near)
            if mk:
                it['deliberate'] = mk.group(1)
    for c, w, m in problems:
        issues.append({'code': c, 'node': w if w in N else None, 'text': f'{w}: {m}'})
    return pack(k, N, E, issues, named)

# ---- cycles: named flows, hops, branch targets
# the crew's named cycles: each hop (<= 4 edges) must exist; a missing hop is a GAP, never drawn
NAMED = [('heartbeat', [('timer', r'(?i)^cron |every \d+ ?min'), ('cmd', r'orch\.ps1 supervise$'), ('outcome|decision', r'^ACT\b'),
      ('row', r'^E\d+'), ('timer', r'(?i)^cron |every \d+ ?min')]),
  ('learn -> retro -> lessons', [('cmd', r'orch\.ps1 learn$'), ('state', r'^signals$'), ('slash', r'^/tidy$'),
          ('file', r'^LESSONS\.md$'), ('step', r'^0\. .*learn'), ('cmd', r'orch\.ps1 learn$')]),
  ('failedTesting -> dev -> deploy -> QA', [('outcome', r'^failedTesting$'), ('slash', r'^/buildy$'), ('row', r'^E5\b'),   # merged work waits for `deploy <env>`
            ('slash', r'^/testy$'), ('outcome', r'^failedTesting$')])]

def named_cycles(N, E, issues):
    out = defaultdict(list)
    for a, b, kind, _, _ in E.values():
        if kind in FLOW:
            out[a].append(b)
    found = []
    for name, hops in NAMED:
        sets = [[i for i, n in N.items() if re.fullmatch(k, n[2]) and re.search(rx, n[1])] for k, rx in hops]
        nodes, gaps = [], []
        for (ka, ra), (kb, rb), A, B in zip(hops, hops[1:], sets, sets[1:]):
            path = hop(out, A, set(B)) if A and B else None
            if path:
                nodes += path
            else:
                gaps.append(f'{ra} -> {rb}' + ('' if A and B else ' (no such node)'))
        for g in gaps:
            issues.append({'code': 'GAP', 'node': (sets[0] or [None])[0], 'text': f'cycle "{name}": no edge {g} (the source never states it)'})
        found.append({'label': name + (f' ({len(gaps)} gap{"s" if len(gaps) > 1 else ""})' if gaps else ''), 'ids': list(dict.fromkeys(nodes)),
           'bound': '', 'kind': 'named', 'gaps': gaps})
    return found

def hop(out, A, B, depth=8):
    prev = {a: None for a in A}
    fr = list(A)
    for _ in range(depth):
        nx = []
        for u in fr:
            for v in out[u]:
                if v not in prev:
                    prev[v] = u
                    if v in B:
                        path = [v]
                        while prev[path[-1]] is not None:
                            path.append(prev[path[-1]])
                        return path[::-1]
                    nx.append(v)
        fr = nx
    return None

def branch_target(text, f, cmds, kc, N, steps=None, skills=None, wfs=None):
    for m in re.finditer(r"label:\s*[`']([\w-]+)", text):
        t = f'{f}#call:{m.group(1).rstrip("-:")}'
        if t in N:
            return t
    for m in CMD.finditer(text):
        c = cmds.get(m.group(1), {})
        t = c.get(f'{m.group(2)} {m.group(3) or ""}'.strip()) or c.get(m.group(2))
        if t:
            return t
    for m in ALIAS_CALL.finditer(text):
        base = kc.get(m.group(1) or '', '') or {'ORCH': 'orch.ps1', 'DEV': 'dev.ps1', 'DT': 'devtools.py'}.get(m.group(2) or m.group(3) or '', '')
        c = cmds.get(base, {})
        t = c.get(f'{m.group(4)} {m.group(5) or ""}'.strip()) or c.get(m.group(4))
        if t:
            return t
    for m in re.finditer(r'(?<![\w#-])([A-Z]{1,3}\d{1,2}[a-z]?)(?![\w-])', text):
        if steps and m.group(1) in steps:
            return steps[m.group(1)]
    for w, t in (wfs or {}).items():
        if re.search(r'(?<![\w-])' + re.escape(w) + r'(?![\w-])', text):
            return t
    for s, t in (skills or {}).items():
        if re.search(r'(?<![\w/-])' + re.escape(s) + r'(?![\w-])', text):
            return t
    m = OUT_RX.search(text[:80])
    return '@outcome/' + m.group(1) if m else None

# ---- pack: page data, shortest paths, loops
def pack(k, N, E, issues, named=()):
    ids = list(N)
    ix = {i: n for n, i in enumerate(ids)}
    files = sorted({n[3] for n in N.values()})
    fx = {f: n for n, f in enumerate(files)}
    edges = [[ix[a], ix[b], kind, lab, bnd, 0] for a, b, kind, lab, bnd in E.values()]
    out = defaultdict(list)
    for n, e in enumerate(edges):
        if e[2] in FLOW:
            out[e[0]].append((e[1], n))
    # back edges: iterative DFS from entry points, then the rest
    kinds = [N[i][2] for i in ids]
    order = sorted(range(len(ids)), key=lambda n: (kinds[n] not in ('event', 'slash', 'human', 'timer', 'row', 'cmd'), n))
    state = [0] * len(ids)
    for r in order:
        if state[r]:
            continue
        stack = [(r, iter(out[r]))]
        state[r] = 1
        while stack:
            u, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                state[u] = 2
                stack.pop()
                continue
            v, en = nxt
            if state[v] == 1:
                edges[en][5] = 1
            elif not state[v]:
                state[v] = 1
                stack.append((v, iter(out[v])))
    cycles = []
    for n, e in enumerate(edges):   # named loops: loop edge + shortest way back
        if e[2] != 'loop' and not (e[5] and e[2] in ('branch', 'next')):
            continue
        if e[0] == e[1] and N[ids[e[0]]][2] in ('retry', 'timer') and (not e[4] or (N[ids[e[0]]][2] == 'retry' and not N[ids[e[0]]][3].endswith('.md'))):
            continue   # bounded code loops: nodes, not chips
        path = [e[0]] if e[0] == e[1] else (shortest(out, e[1], e[0]) or [e[1], e[0]])
        if path:
            lab = f"{N[ids[e[0]]][1]} ↻{' ' + e[4] if e[4] else ''}"
            cycles.append({'label': short(lab, 50), 'nodes': path, 'bound': e[4], 'kind': N[ids[e[0]]][2]})
    proc = defaultdict(list)   # process cycles, not helper calls
    for n, e in enumerate(edges):
        if e[2] in FLOW - {'calls', 'loads', 'has'}:
            proc[e[0]].append((e[1], n))
    for comp in tarjan(len(ids), proc):
        if len(comp) >= 2:
            names = sorted(comp, key=lambda n: -len(out[n]))[:3]
            cycles.append({'label': short(' → '.join(N[ids[n]][1] for n in names), 50) + f' ({len(comp)})', 'nodes': comp, 'bound': '', 'kind': 'scc'})
    for c in named:
        cycles.append({'label': c['label'], 'nodes': [ix[i] for i in c['ids']], 'bound': '', 'kind': 'named', 'gaps': c['gaps']})
    seen, uniq = set(), []
    rank = {'named': -1, 'call': 0, 'phase': 0, 'step': 1, 'cmd': 1, 'row': 1, 'decision': 1, 'scc': 2}
    for c in sorted(cycles, key=lambda c: (rank.get(c['kind'], 3), len(c['nodes']))):
        key = tuple(sorted(c['nodes']))
        if key not in seen:
            seen.add(key)
            uniq.append(c)
    nodes = [[N[i][1], N[i][2], fx[N[i][3]], N[i][4], N[i][5], i, N[i][6] if len(N[i]) > 6 else 0] for i in ids]
    fk = [{'id': f, 'kind': fkind(f) if not f.startswith('(') else 'pseudo'} for f in files]
    for it in issues:
        it['node'] = ix.get(it['node']) if it.get('node') in ix else (ix.get(it['node'].split(':')[0]) if it.get('node') else None)
    deliberate = [it for it in issues if it.get('deliberate')]
    counted = [it for it in issues if not it.get('deliberate')]
    counts = {'nodes': len(nodes), 'edges': len(edges), 'files': len([f for f in files if not f.startswith('(')]), 'issues': len(counted),
      'deliberate': len(deliberate), 'cycles': len(uniq)}
    dirty = bool(subprocess.run(['git', '-C', k.dir, 'status', '--porcelain'], capture_output=True, text=True).stdout.strip()) if osp.isdir(k.dir) else False
    return {'kit': k.dir, 'generated': time.strftime('%Y-%m-%d %H:%M:%S'), 'files': fk, 'nodes': nodes, 'edges': edges,
      'cycles': uniq[:80], 'issues': counted, 'deliberate': deliberate, 'dirty': dirty, 'counts': counts}

def shortest(out, a, b, cap=4000):
    prev, q = {a: None}, deque([a])
    while q and len(prev) < cap:
        u = q.popleft()
        if u == b:
            path = []
            while u is not None:
                path.append(u)
                u = prev[u]
            return path[::-1]
        for v, _ in out[u]:
            if v not in prev:
                prev[v] = u
                q.append(v)
    return None

def tarjan(n, out):
    index, low, on, st, comps, c = [None] * n, [0] * n, [False] * n, [], [], [0]
    for r in range(n):
        if index[r] is not None:
            continue
        work = [(r, iter(out[r]))]
        index[r] = low[r] = c[0]
        c[0] += 1
        st.append(r)
        on[r] = True
        while work:
            u, it = work[-1]
            nxt = next(it, None)
            if nxt is not None:
                v = nxt[0]
                if index[v] is None:
                    index[v] = low[v] = c[0]
                    c[0] += 1
                    st.append(v)
                    on[v] = True
                    work.append((v, iter(out[v])))
                elif on[v]:
                    low[u] = min(low[u], index[v])
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[u])
            if low[u] == index[u]:
                comp = []
                while True:
                    w = st.pop()
                    on[w] = False
                    comp.append(w)
                    if w == u:
                        break
                if len(comp) > 1:
                    comps.append(comp)
    return comps

# ---- page: the HTML page and its sidecar
def html(data, src_name=''):
    data = dict(data, src=src_name)
    return PAGE.replace('__DATA__', json.dumps(data, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/'))

def write(out, data, texts):
    """The page plus its sidecar (<page>-src.js: every file's text, loaded only when a node's code is first shown)."""
    side = out[:-5] + '-src.js' if out.endswith('.html') else out + '-src.js'
    with open(side, 'w', encoding='utf-8') as fh:
        fh.write('window.KF_SRC=' + json.dumps(texts, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/') + ';')
    with open(out, 'w', encoding='utf-8') as fh:
        fh.write(html(data, osp.basename(side)))

PAGE = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,interactive-widget=resizes-content"><title>Kit flow</title>
<style>:root{--bg:#f8fafc;--fg:#0f172a;--mut:#64748b;--ln:#e2e8f0;--pn:#ffffff;--pn2:#f1f5f9;--hi:#d97706;--bad:#dc2626;--sel:#2563eb22;
--kw:#7c3aed;--st:#047857;--cm:#94a3b8;--nu:#c2410c;--va:#0369a1;--mono:ui-monospace,SFMono-Regular,Consolas,monospace}
@media (prefers-color-scheme:dark){:root{--bg:#0b1120;--fg:#e2e8f0;--mut:#94a3b8;--ln:#1e293b;--pn:#0f172a;--pn2:#111c33;--hi:#fbbf24;--bad:#f87171;--sel:#60a5fa22;
--kw:#c4b5fd;--st:#6ee7b7;--cm:#64748b;--nu:#fdba74;--va:#7dd3fc}}
*{box-sizing:border-box}html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--fg);font:12px system-ui,sans-serif}
#app{display:flex;height:100%}#main{position:relative;flex:1;min-width:0}#c{position:absolute;inset:0;width:100%;height:100%;touch-action:none}
#top{position:absolute;top:8px;left:8px;right:8px;display:flex;gap:6px;align-items:center;flex-wrap:wrap;pointer-events:none}#top>*{pointer-events:auto}
.b{background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:4px 9px;cursor:pointer;user-select:none;white-space:nowrap;color:var(--fg);font:inherit}
.b.on{background:var(--fg);color:var(--bg)}.seg{display:inline-flex}.seg .b{border-radius:0;margin-left:-1px}.seg .b:first-child{border-radius:8px 0 0 8px}.seg .b:last-child{border-radius:0 8px 8px 0}
input.b{cursor:text;width:180px}.dd{position:relative}.dd>.menu{display:none;position:absolute;top:30px;left:0;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:6px;min-width:220px;z-index:5;box-shadow:0 8px 24px #0003}
.dd.open>.menu{display:block}.menu label{display:flex;gap:6px;align-items:center;padding:3px 4px;border-radius:5px;cursor:pointer}.menu label:hover{background:var(--pn2)}.menu small{margin-left:auto;color:var(--mut)}
#legb{position:absolute;left:10px;bottom:10px;width:34px;height:34px;border-radius:50%;display:grid;place-items:center}
#leg{display:none;position:absolute;left:10px;bottom:52px;background:var(--pn);border:1px solid var(--ln);border-radius:10px;padding:10px;box-shadow:0 8px 24px #0003;max-width:min(640px,calc(100% - 20px))}
#leg.open{display:block}#leg .g{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:4px 14px}#leg .it{display:flex;gap:6px;align-items:center;white-space:nowrap;overflow:hidden}
#leg h4{margin:8px 0 4px;font-size:11px;color:var(--mut);font-weight:600}
#side{width:0;transition:width .18s ease;background:var(--pn);border-left:1px solid var(--ln);display:flex;flex-direction:column;position:relative;overflow:hidden}
#side.drag{transition:none}#grip{position:absolute;left:0;top:0;bottom:0;width:6px;cursor:col-resize;z-index:2}#grip:hover{background:var(--sel)}
#rail{width:44px;background:var(--pn2);border-left:1px solid var(--ln);display:flex;flex-direction:column;align-items:center;padding-top:8px;gap:4px}
.ri{position:relative;width:34px;height:34px;border-radius:8px;display:grid;place-items:center;cursor:pointer;color:var(--mut)}.ri:hover,.ri.on{background:var(--pn);color:var(--fg)}
.ri.on::before{content:'';position:absolute;left:-5px;top:7px;bottom:7px;width:3px;border-radius:2px;background:var(--fg)}
.badge{position:absolute;right:-2px;top:-2px;min-width:16px;height:16px;border-radius:8px;background:var(--bad);color:#fff;font-size:10px;display:grid;place-items:center;padding:0 3px}
#sh{padding:10px 12px 8px 14px;border-bottom:1px solid var(--ln);font-weight:600;display:flex;align-items:center;gap:8px;min-height:40px}
#sb{flex:1;overflow:auto;padding:0 0 12px 6px}.sticky{position:sticky;top:0;background:var(--pn);padding:8px 8px 6px 6px;z-index:1;display:flex;gap:6px;flex-wrap:wrap}
.li{display:flex;gap:8px;align-items:flex-start;padding:5px 8px;border-radius:6px;cursor:pointer}.li:hover{background:var(--pn2)}.li.on{background:var(--sel)}
.li .t{flex:1;min-width:0}.li .f{display:block;font:11px var(--mono);color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.li.bad .t{color:var(--bad)}
.num{font:600 10px var(--mono);color:var(--mut);min-width:20px;text-align:right;padding-top:2px}.grp{font-size:11px;color:var(--mut);font-weight:600;padding:8px 8px 2px}
.empty{color:var(--mut);padding:16px 10px;line-height:1.5}.ico{flex:none}
pre{margin:0;font:12px/1.55 var(--mono);tab-size:2}.cl{display:flex}.cl .n{color:var(--mut);min-width:44px;text-align:right;padding-right:10px;user-select:none}.cl .x{white-space:pre;flex:1}
.cl.me{background:var(--sel)}.kw{color:var(--kw)}.st{color:var(--st)}.cm{color:var(--cm);font-style:italic}.nu{color:var(--nu)}.va{color:var(--va)}
#meta{padding:8px 14px;border-bottom:1px solid var(--ln);color:var(--mut);line-height:1.5}#meta .f{font:11px var(--mono)}#meta a,.lnk{color:var(--va);cursor:pointer;margin-right:12px;text-decoration:none}
#tip{position:fixed;max-width:380px;background:var(--pn);border:1px solid var(--ln);border-radius:6px;padding:6px 8px;pointer-events:none;display:none;white-space:pre-wrap;box-shadow:0 4px 14px #0002;z-index:9}
select.b{max-width:100%}#sx,#howto{display:none}
@media (pointer:coarse),(max-width:640px){.b,.menu label,.li{min-height:44px}.b{display:inline-flex;align-items:center}.seg .b{padding:4px 12px}
#rail{width:52px}.ri,#legb{width:44px;height:44px}input.b,select.b{font-size:16px}}
@media (max-width:640px){input#q{flex:1 1 120px;width:auto;min-width:0}.dd>.menu{position:fixed;top:auto;left:8px;right:60px;max-height:60dvh;overflow:auto}
#side{position:fixed;left:0;right:52px;bottom:0;height:62vh;height:62dvh;width:auto!important;display:none;border:1px solid var(--ln);border-radius:14px 14px 0 0;z-index:8;box-shadow:0 -8px 24px #0003}
#side.open{display:flex}#grip{display:none}#sh{padding-right:56px}#sx{display:inline-flex;position:absolute;right:6px;top:4px;z-index:3}#howto{display:block;margin-bottom:8px;line-height:1.5}
#leg .g{grid-template-columns:repeat(2,minmax(0,1fr))}#leg{max-height:70dvh;overflow:auto}}</style></head><body>
<div id="app"><div id="main"><canvas id="c"></canvas>
<div id="top"><b class="b" id="ttl" title="How to read: icons = kinds (key, bottom-left); zoom in for more detail; click a node = its neighbours + its code; click a highlighted neighbour to extend; dashed arc = loop / back edge; double-click = collapse a file; drag = pin">kit flow</b>
<input class="b" id="q" placeholder="search…"><span class="seg" id="lv"></span><span class="dd" id="ddS"><span class="b">Show ▾</span><div class="menu"></div></span><span class="dd" id="ddE"><span class="b">Edges ▾</span><div class="menu"></div></span><span class="b" id="fit">fit</span></div>
<span class="b" id="legb" title="key"></span><div id="leg"></div></div>
<div id="side"><div id="grip" title="drag to resize · double-click to reset"></div><span class="b" id="sx" title="close">✕</span><div id="sh"></div><div id="meta" style="display:none"></div><div id="sb"></div></div>
<div id="rail"></div></div><div id="tip"></div>
<script>
const D = __DATA__, $ = s => document.querySelector(s), cv = $('#c'), X = cv.getContext('2d'), tip = $('#tip');
const LS = {get(k, d) { try { const v = localStorage.getItem('kf.' + k); return v == null ? d : JSON.parse(v) } catch (e) { return d } }, set(k, v) { try { localStorage.setItem('kf.' + k, JSON.stringify(v)) } catch (e) {} }};
const IC = {bolt: 'M13 2L4 14h7l-1 8 9-12h-7z', person: 'M12 4a4 4 0 1 0 0 8a4 4 0 1 0 0-8M4 21c1-5 15-5 16 0', clock: 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M12 7v5l3 2',
 table: 'M3 5h18v14H3zM3 10h18M9 5v14', slash: 'M15 4l-6 16', puzzle: 'M4 7h4a2 2 0 1 1 4 0h4v4a2 2 0 1 1 0 4v4h-4a2 2 0 1 0-4 0H4v-4a2 2 0 1 0 0-4z',
 robot: 'M6 8h12v11H6zM12 4v4M9.5 13h.01M14.5 13h.01M9 16h6M4 12v3M20 12v3', flow: 'M4 5h5v5H4zM15 14h5v5h-5zM9 7.5h3a3 3 0 0 1 3 3v3.5',
 term: 'M4 4h16v16H4zM8 9l3 3-3 3M13 15h3', fn: 'M15 4c-3 0-3 2-4 8s-1 8-4 8M8 10h7', globe: 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18',
 git: 'M6 3v12M18 6a3 3 0 1 0 0 .01M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6M18 9c0 5-5 6-9 8', doc: 'M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6',
 list: 'M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01', diamond: 'M12 3l9 9-9 9-9-9zM9 12h6', hour: 'M6 3h12M6 21h12M7 3c0 6 10 6 10 9s-10 3-10 9M17 3c0 6-10 6-10 9s10 3 10 9',
 loop: 'M4 12a8 8 0 0 1 14-5.3M20 4v4h-4M20 12a8 8 0 0 1-14 5.3M4 20v-4h4', par: 'M7 4v16M12 4v16M17 4v16', lock: 'M6 11h12v10H6zM8 11V7a4 4 0 0 1 8 0v4',
 warn: 'M12 3l10 18H2zM12 10v5M12 18h.01', door: 'M13 3H5v18h8M9 12h12M18 9l3 3-3 3', flag: 'M5 21V4h12l-2 4 2 4H5', db: 'M4 6c0-3 16-3 16 0v12c0 3-16 3-16 0zM4 6c0 3 16 3 16 0M4 12c0 3 16 3 16 0',
 gear: 'M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2', code: 'M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16',
 route: 'M6 19a2 2 0 1 0 0-4a2 2 0 1 0 0 4M18 9a2 2 0 1 0 0-4a2 2 0 1 0 0 4M6 15V9a4 4 0 0 1 4-4h6M18 9v6a4 4 0 0 1-4 4H8', key: 'M8 15a4 4 0 1 0 0-8a4 4 0 1 0 0 8M12 11h9M18 11v3M15 11v2'};
const P2 = Object.fromEntries(Object.entries(IC).map(([k, d]) => [k, new Path2D(d)]));
const FAM = {trig: ['Triggers', '#8b5cf6'], crew: ['Crew', '#0d9488'], code: ['Commands & code', '#3b82f6'], docs: ['Docs', '#16a34a'], ctrl: ['Control flow', '#d97706'], data: ['Data', '#ea580c']};
const KD = {event: ['trig', 'bolt', 'event / hook'], human: ['trig', 'person', 'human'], timer: ['trig', 'clock', 'timer / schedule'], row: ['trig', 'table', 'table row'],
 slash: ['crew', 'slash', 'slash command'], 'file-skill': ['crew', 'puzzle', 'skill'], 'file-agent': ['crew', 'robot', 'agent'], 'file-workflow': ['crew', 'flow', 'workflow'],
 call: ['crew', 'robot', 'agent() call'], phase: ['crew', 'flow', 'phase'], cmd: ['code', 'term', 'command'], 'file-script': ['code', 'term', 'script'], fn: ['code', 'fn', 'function'],
 ext: ['code', 'globe', 'external CLI'], 'file-doc': ['docs', 'doc', 'doc file'], section: ['docs', 'doc', 'section'], step: ['docs', 'list', 'step'],
 decision: ['ctrl', 'diamond', 'decision'], wait: ['ctrl', 'hour', 'wait / gate'], retry: ['ctrl', 'loop', 'loop / retry'], parallel: ['ctrl', 'par', 'parallel'], lock: ['ctrl', 'lock', 'lock'],
 error: ['ctrl', 'warn', 'error path'], exit: ['ctrl', 'door', 'exit'], outcome: ['ctrl', 'flag', 'outcome'], state: ['data', 'db', 'state'], config: ['data', 'gear', 'config key'], 'file-pseudo': ['data', 'db', 'group']};
const EK = {calls: ['#94a3b8', 'solid'], runs: ['#3b82f6', 'solid'], impl: ['#0ea5e9', 'solid'], next: ['#16a34a', 'solid'], spawns: ['#0d9488', 'solid'], loads: ['#a3a3a3', 'dot'],
 routes: ['#8b5cf6', 'solid'], branch: ['#d97706', 'solid'], loop: ['#db2777', 'dash'], writes: ['#ea580c', 'solid'], reads: ['#ea580c', 'dot'], triggers: ['#8b5cf6', 'dash'], has: ['#94a3b8', 'dot']};
const N = D.nodes.map((a, i) => ({i, l: a[0], k: a[1], g: a[2], ln: a[3], d: a[4], id: a[5], end: a[6] || 0, out: [], in: [], x: 0, y: 0, vx: 0, vy: 0, fx: null}));
const E = D.edges.map((a, i) => ({i, s: a[0], t: a[1], k: a[2], l: a[3], b: a[4], back: a[5]}));
E.forEach(e => { N[e.s].out.push(e); N[e.t].in.push(e) });
const G = D.files.map((f, i) => ({i, id: f.id, kind: f.kind, m: N.filter(n => n.g === i)}));
G.forEach(g => g.fn = g.m.find(n => n.k === 'file'));
N.forEach(n => { n.kk = n.k === 'file' ? 'file-' + (G[n.g].kind || 'doc') : n.k; if (!KD[n.kk]) n.kk = 'file-doc'; n.fam = KD[n.kk][0]; n.col = FAM[n.fam][1];
 n.r = n.k === 'file' ? 11 : 5 + Math.min(7, Math.sqrt(n.out.length + n.in.length)) });
const LV0 = n => (n.k === 'file' && n.fam === 'crew') || n.k === 'event' || /^AGENTS\.md#§Router\?$/.test(n.id);
const lvOf = n => LV0(n) ? 0 : n.k === 'decision' ? (/\.md#|^workflows\//.test(n.id) ? 1 : 2) : (n.k === 'file' || /slash|phase|call|step|section|cmd|timer|human|row/.test(n.k)) ? 1 : 2;
N.forEach(n => n.lv = lvOf(n));
const bad = new Map(); D.issues.forEach(it => it.node != null && bad.set(it.node, (bad.get(it.node) || []).concat(it)));
const famOn = Object.fromEntries(Object.keys(FAM).map(k => [k, true])), ekOn = Object.fromEntries(Object.keys(EK).map(k => [k, k !== 'has']));
const coll = new Set();
let LVL = 0, VN = [], VE = [], focus = null, fE = null, sel = null, force = new Set(), trace = null, tIdx = -1, hover = null, fitSc = 1;
let ang = 0, rad = 0;
[...G].sort((a, b) => b.m.length - a.m.length).forEach(g => { const R = 10 * Math.sqrt(g.m.length) + 30; rad += R * .55; ang += 2.4; const gx = Math.cos(ang) * rad, gy = Math.sin(ang) * rad;
 g.m.forEach(n => { const a = Math.random() * 6.28, d = Math.random() * R * .6; n.x = gx + Math.cos(a) * d; n.y = gy + Math.sin(a) * d }) });
function vis(n) { if (!famOn[n.fam]) return false; if (force.has(n)) return true; if (coll.has(n.g)) return n.k === 'file'; return n.lv <= LVL }
function rep(n) { if (vis(n)) return n; if (n.par && vis(n.par)) return n.par; const f = G[n.g].fn; return f && f !== n && vis(f) ? f : null }
N.forEach(n => { const b = n.in.find(e => e.k === 'branch' && N[e.s].k === 'decision'); if (n.k === 'row' && b) n.par = N[b.s] });
function rebuild() {
 VN = N.filter(vis); const seen = new Map(); VE = [];
 for (const e of E) { if (!ekOn[e.k]) continue; const a = rep(N[e.s]), b = rep(N[e.t]); if (!a || !b || (a === b && e.s !== e.t)) continue;
  const key = a.i + ',' + b.i + ',' + e.k; if (seen.has(key)) { seen.get(key).n++; continue } const v = {a, b, e, n: 1}; seen.set(key, v); VE.push(v) }
 $('#lv').querySelectorAll('.b').forEach((b, i) => b.classList.toggle('on', i === LVL)); heat(.15)
}
let alpha = 1, raf = 0;
const heat = a => { alpha = Math.max(alpha, a); if (!raf) raf = requestAnimationFrame(frame) };
function tick() {
 for (const g of G) { g.cx = g.cy = g.c = 0 }
 for (const n of N) { if (n.k === 'file' && G[n.g].m.length > 1) continue; const g = G[n.g]; g.cx += n.x; g.cy += n.y; g.c++ }
 for (const g of G) if (g.c) { g.cx /= g.c; g.cy /= g.c; g.R = 9 * Math.sqrt(g.c) + 18; g.sx = g.sy = 0 }
 const C = 46, grid = new Map(), key = (a, b) => a * 73856093 ^ b * 19349663;
 for (const n of N) { const k = key(Math.floor(n.x / C), Math.floor(n.y / C)); (grid.get(k) || grid.set(k, []).get(k)).push(n) }
 for (const n of N) { const gx = Math.floor(n.x / C), gy = Math.floor(n.y / C);
  for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) for (const m of grid.get(key(gx + i, gy + j)) || []) {
   if (m.i <= n.i) continue; const dx = n.x - m.x, dy = n.y - m.y, d2 = dx * dx + dy * dy || .01, d = Math.sqrt(d2);
   let f = (n.g === m.g ? 30 : 120) / d2 * alpha; const mn = n.r + m.r + 4; if (d < mn) f += (mn - d) / d * .4;
   n.vx += dx * f; n.vy += dy * f; m.vx -= dx * f; m.vy -= dy * f } }
 for (const e of E) { const a = N[e.s], b = N[e.t]; if (a === b) continue; const same = a.g === b.g, L = same ? 22 : 180, s = (same ? .1 : .0015) * alpha;
  const dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy) || 1, f = (d - L) / d * s; a.vx += dx * f; a.vy += dy * f; b.vx -= dx * f; b.vy -= dy * f }
 const GL = G.filter(g => g.c);
 for (let i = 0; i < GL.length; i++) for (let j = i + 1; j < GL.length; j++) { const p = GL[i], q = GL[j], dx = p.cx - q.cx, dy = p.cy - q.cy, d = Math.hypot(dx, dy) || 1, m = p.R + q.R + 40;
  if (d < m) { const f = (m - d) / d * (.03 + .25 * alpha); p.sx += dx * f; p.sy += dy * f; q.sx -= dx * f; q.sy -= dy * f } }
 for (const g of GL) { g.sx -= g.cx * (.003 + .004 * alpha); g.sy -= g.cy * (.003 + .004 * alpha) }
 for (const n of N) { const g = G[n.g];
  if (n.k === 'file' && g.m.length > 1) { n.x = g.cx; n.y = g.cy; n.vx = n.vy = 0; continue }
  n.vx += (g.cx - n.x) * (.01 + .04 * alpha) + g.sx; n.vy += (g.cy - n.y) * (.01 + .04 * alpha) + g.sy;
  if (n.fx != null) { n.x = n.fx; n.y = n.fy; n.vx = n.vy = 0; continue } n.vx *= .55; n.vy *= .55; n.x += n.vx; n.y += n.vy }
 alpha *= .99
}
let tx = 0, ty = 0, sc = .3, W = 0, H = 0, dpr = 1;
const size = () => { const r = $('#main').getBoundingClientRect(), ow = W; W = r.width; H = r.height; dpr = devicePixelRatio || 1; cv.width = W * dpr; cv.height = H * dpr; if (ow) tx += (W - ow) / 2; draw() };
const s2w = (x, y) => [(x - tx) / sc, (y - ty) / sc];
function zoomLevel() { const z = sc / fitSc, L = z < 1.8 ? 0 : z < 4 ? 1 : 2; if (L !== LVL) { LVL = L; rebuild() } }
function hull(P) {
 P = P.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]); if (P.length < 3) return P;
 const cr = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]), lo = [], up = [];
 for (const p of P) { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p) }
 for (const p of P.reverse()) { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p) }
 return lo.slice(0, -1).concat(up.slice(0, -1))
}
function icon(name, x, y, s, col, lw) { X.save(); X.translate(x - s / 2, y - s / 2); X.scale(s / 24, s / 24); X.strokeStyle = col; X.lineWidth = lw * 24 / s; X.lineCap = X.lineJoin = 'round'; X.stroke(P2[name]); X.restore() }
function draw() {
 raf = 0; const cs = getComputedStyle(document.documentElement), bg = cs.getPropertyValue('--bg'), fg = cs.getPropertyValue('--fg'), hi = cs.getPropertyValue('--hi'), pn = cs.getPropertyValue('--pn');
 X.setTransform(dpr, 0, 0, dpr, 0, 0); X.fillStyle = bg; X.fillRect(0, 0, W, H); X.setTransform(dpr * sc, 0, 0, dpr * sc, dpr * tx, dpr * ty);
 const lw = 1 / sc, F = n => !focus || focus.has(n), x0 = -tx / sc, y0 = -ty / sc, x1 = x0 + W / sc, y1 = y0 + H / sc, on = n => n.x > x0 - 50 && n.x < x1 + 50 && n.y > y0 - 50 && n.y < y1 + 50;
 if (LVL > 0) for (const g of G) { if (!g.fn || coll.has(g.i)) continue; const m = g.m.filter(n => n.k !== 'file' && vis(n)); if (m.length < 2) continue;
  const h = hull(m.map(n => [n.x, n.y])); X.globalAlpha = focus && !m.some(F) ? .03 : .07; X.fillStyle = X.strokeStyle = g.fn.col; X.lineWidth = 34; X.lineJoin = 'round';
  X.beginPath(); h.forEach((p, i) => i ? X.lineTo(p[0], p[1]) : X.moveTo(p[0], p[1])); X.closePath(); X.fill(); X.stroke() }
 const lab = [];
 for (const v of VE) { const {a, b, e} = v; if (!on(a) && !on(b)) continue; const hl = fE ? fE.has(v) : false, dim = focus && !hl;
  const loopy = e.back || e.k === 'loop'; X.globalAlpha = hl ? .95 : dim ? .04 : LVL === 0 ? .45 : LVL === 1 ? .25 : .14;
  X.strokeStyle = X.fillStyle = hl ? hi : EK[e.k][0]; X.lineWidth = (hl ? 2 : loopy ? 1.4 : 1) * lw * (LVL === 0 ? 1.4 : 1);
  X.setLineDash(loopy || EK[e.k][1] === 'dash' ? [6 * lw, 4 * lw] : EK[e.k][1] === 'dot' ? [1.5 * lw, 3 * lw] : []); X.beginPath();
  let mx, my, ang;
  if (a === b) { X.arc(a.x + a.r, a.y - a.r, a.r + 4, 0, 6.283); mx = a.x + a.r; my = a.y - 2 * a.r - 6; ang = 0 }
  else { const dx = b.x - a.x, dy = b.y - a.y, c = loopy ? .35 : .1, cx = (a.x + b.x) / 2 - dy * c, cy = (a.y + b.y) / 2 + dx * c;
   X.moveTo(a.x, a.y); X.quadraticCurveTo(cx, cy, b.x, b.y); mx = (a.x + 2 * cx + b.x) / 4; my = (a.y + 2 * cy + b.y) / 4; ang = Math.atan2(b.y - cy, b.x - cx) }
  X.stroke(); X.setLineDash([]);
  if (a !== b && (hl || sc > .8 || LVL === 0)) { const d = b.r + 2, s = 6 * lw, hx = b.x - Math.cos(ang) * d, hy = b.y - Math.sin(ang) * d;
   X.beginPath(); X.moveTo(hx, hy); X.lineTo(hx - Math.cos(ang - .45) * s, hy - Math.sin(ang - .45) * s); X.lineTo(hx - Math.cos(ang + .45) * s, hy - Math.sin(ang + .45) * s); X.fill() }
  if (loopy && (hl || (e.k === 'loop' && LVL === 0 && !focus))) lab.push([mx, my, '↻' + (e.b ? ' ' + e.b : ''), '#db2777']);
  if (hl && fE.size < 120) lab.push([mx, my + 12 * lw, e.k + (e.l ? ' · ' + e.l : '') + (v.n > 1 ? ` (×${v.n})` : ''), fg]) }
 const big = sc * 8 > 3;
 for (const n of VN) { if (!on(n)) continue; const r = LVL === 0 ? (n.k === 'file' ? 16 : 11) : n.r; X.globalAlpha = F(n) ? 1 : .12;
  X.beginPath(); X.arc(n.x, n.y, r, 0, 6.283); X.fillStyle = pn; X.fill(); X.globalAlpha *= .22; X.fillStyle = n.col; X.fill(); X.globalAlpha = F(n) ? 1 : .12;
  const ring = bad.has(n.i) && (sel === n || (focus && focus.has(n))) ? '#dc2626' : n === sel ? hi : n.col; X.strokeStyle = ring; X.lineWidth = (n === sel || ring === '#dc2626' ? 2.5 : 1.2) * lw; X.stroke();
  if (r * sc > 5) icon(KD[n.kk][1], n.x, n.y, r * 1.15, n.col, Math.max(1.2 * lw, r * .12));
  if (n.fx != null) { X.fillStyle = fg; X.beginPath(); X.arc(n.x + r * .8, n.y - r * .8, 2.2 * lw, 0, 6.283); X.fill() } }
 X.textAlign = 'center';
 for (const n of VN) { if (!on(n)) continue; const r = LVL === 0 ? (n.k === 'file' ? 16 : 11) : n.r, show = n === sel || n === hover || (focus ? focus.has(n) && (focus.size < 150 || r * sc > 6) : (n.lv === LVL || n.k === 'file') && r * sc > 4.5 && big);
  if (!show) continue; X.globalAlpha = F(n) ? 1 : .2; X.font = `${n.k === 'file' ? 600 : 400} ${(n.k === 'file' ? 12 : 11) * lw}px system-ui`;
  X.lineWidth = 3 * lw; X.strokeStyle = bg; const t = n.l.slice(0, 40); X.strokeText(t, n.x, n.y + r + 12 * lw); X.fillStyle = fg; X.fillText(t, n.x, n.y + r + 12 * lw) }
 for (const [x, y, t, c] of lab) { X.globalAlpha = 1; X.font = `${10.5 * lw}px system-ui`; X.lineWidth = 3 * lw; X.strokeStyle = bg; X.strokeText(t.slice(0, 64), x, y); X.fillStyle = c; X.fillText(t.slice(0, 64), x, y) }
 if (trace) { X.font = `600 ${10 * lw}px system-ui`; const done = new Set();
  trace.forEach((s, i) => { const n = rep(s.n); if (!n || done.has(n)) return; done.add(n); const t = String(i + 1), w = (t.length * 6 + 8) * lw, bx = n.x + n.r * .7, by = n.y - n.r - 9 * lw;
   X.globalAlpha = 1; X.fillStyle = i === tIdx ? hi : n.col; X.beginPath(); X.roundRect ? X.roundRect(bx - w / 2, by - 7 * lw, w, 14 * lw, 7 * lw) : X.rect(bx - w / 2, by - 7 * lw, w, 14 * lw); X.fill();
   X.fillStyle = '#fff'; X.fillText(t, bx, by + 3.5 * lw) }) }
 X.globalAlpha = 1
}
function frame() { raf = 0; for (let i = 0; i < 2 && alpha > .02; i++) tick(); draw(); if (alpha > .02 || drag) raf = requestAnimationFrame(frame) }
function fitTo(ns) { ns = ns && ns.length ? ns : VN; if (!ns.length) return; const xs = ns.map(n => n.x), ys = ns.map(n => n.y), a = Math.min(...xs), b = Math.max(...xs), c = Math.min(...ys), d = Math.max(...ys);
 sc = Math.min((W - 60) / (b - a + 120), (H - 90) / (d - c + 120), 2.5); tx = W / 2 - (a + b) / 2 * sc; ty = 30 + (H - 30) / 2 - (c + d) / 2 * sc; draw() }
const center = n => { tx = W / 2 - n.x * sc; ty = H / 2 - n.y * sc; draw() };
function setLevel(L) { const cx = (W / 2 - tx) / sc, cy = (H / 2 - ty) / sc; sc = fitSc * [1, 2.4, 5][L]; tx = W / 2 - cx * sc; ty = H / 2 - cy * sc; LVL = L; rebuild() }
function neigh(n, extend) {
 if (!extend || !focus) { focus = new Set([n]); fE = new Set() }
 if (!fE) fE = new Set()
 focus.add(n); for (const v of VE) if (v.a === n || v.b === n) { fE.add(v); focus.add(v.a); focus.add(v.b) } draw()
}
function select(n, extend) { sel = n; if (n) { neigh(n, extend); openSide('code') } else { focus = fE = null; draw() } }
function show(nodes, edgesToo) { force = new Set(nodes); rebuild(); focus = new Set(nodes.map(rep).filter(Boolean)); fE = new Set(VE.filter(v => focus.has(v.a) && focus.has(v.b))); draw() }
const PRI = {routes: 0, runs: 1, impl: 1, spawns: 2, branch: 3, triggers: 4, has: 5, calls: 6, writes: 7, loads: 8, next: 9, loop: 10}, COST = {calls: 2, has: 2, loads: 2, writes: 2}, choice = {};
function walk(start) {
 const steps = [], seen = new Set();
 (function go(n, dep, via) {
  if (steps.length > 300) return; seen.add(n); steps.push({n, dep, via}); if (dep >= 7) return;
  let outs = n.out.filter(e => PRI[e.k] != null && !(n.k === 'fn' && (e.k === 'has' || (e.k === 'calls' && N[e.t].k === 'fn')))).sort((a, b) => PRI[a.k] - PRI[b.k] || N[a.t].ln - N[b.t].ln);
  const br = outs.filter(e => e.k === 'branch'); if (n.k === 'decision' && br.length) outs = outs.filter(e => e.k !== 'branch').concat([br[Math.min(choice[n.i] || 0, br.length - 1)]]);
  for (const e of outs) { const t = N[e.t]; if (seen.has(t)) { if (e.back || e.k === 'loop') steps.push({n: t, dep: dep + 1, via: e, loop: 1}); continue } go(t, dep + (COST[e.k] || 1), e) }
 })(start, 0, null);
 return steps
}
function runTrace(start) { trace = walk(start); tIdx = 0; show(trace.map(s => s.n)); const ids = new Set(trace.map(s => s.via).filter(Boolean)); fE = new Set(VE.filter(v => [...ids].some(e => rep(N[e.s]) === v.a && rep(N[e.t]) === v.b)));
 fitTo([...focus]); tab('trace') }
function stepTo(i) { if (!trace) return; tIdx = Math.max(0, Math.min(trace.length - 1, i)); sel = trace[tIdx].n; center(rep(sel) || sel); if (curTab === 'trace') tab('trace'); else draw() }
const side = $('#side'), sb = $('#sb'), esc = s => String(s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'})[c]);
const svgI = (name, col, s = 16) => `<svg class="ico" width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="${col || 'currentColor'}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="${IC[name]}"/></svg>`;
const TABS = {code: ['code', 'Code'], trace: ['route', 'Trace'], loops: ['loop', 'Loops'], issues: ['warn', 'Issues']};
let curTab = LS.get('tab', 'code'), sideW = LS.get('w', 420), sideOpen = false;
if (!D.issues.length) { delete TABS.issues; if (curTab === 'issues') curTab = 'code' }
for (const t in TABS) { const d = document.createElement('div'); d.className = 'ri'; d.dataset.t = t; d.title = TABS[t][1] + (t === 'issues' ? (D.dirty ? ' (uncommitted work: commit is blocked until 0)' : '') : ''); d.innerHTML = svgI(TABS[t][0], null, 20) + (t === 'issues' && D.issues.length ? `<span class="badge">${D.issues.length}</span>` : t === 'loops' ? `<span class="badge" style="background:#db2777">${D.cycles.length}</span>` : '');
 d.onclick = () => sideOpen && curTab === t ? closeSide() : openSide(t); $('#rail').append(d) }
const narrow = () => matchMedia('(max-width:640px)').matches;   // phones: the side panel is a bottom sheet over the graph
function openSide(t) { curTab = t; LS.set('tab', t); if (!sideOpen) { sideOpen = true; side.style.width = sideW + 'px'; side.classList.add('open'); LS.set('open', true) } tab(t); setTimeout(size, 200) }
function closeSide() { sideOpen = false; side.style.width = '0'; side.classList.remove('open'); LS.set('open', false); document.querySelectorAll('.ri').forEach(r => r.classList.remove('on')); setTimeout(size, 200) }
const fl = n => D.files[n.g].id + (n.ln ? ':' + n.ln : '');
const row = (n, title, extra, cls, fn) => { const d = document.createElement('div'); d.className = 'li ' + (cls || ''); d.innerHTML = (extra || '') + (n ? svgI(KD[n.kk][1], n.col) : '') + `<span class="t">${title}<span class="f">${n ? esc(fl(n)) : ''}</span></span>`; d.onclick = fn; return d };
function filterBox(ph, onq) { const s = document.createElement('div'); s.className = 'sticky'; const i = document.createElement('input'); i.className = 'b'; i.placeholder = ph; i.style.width = '100%'; i.oninput = () => onq(i.value.toLowerCase()); s.append(i); sb.append(s); return s }
function tab(t) {
 document.querySelectorAll('.ri').forEach(r => r.classList.toggle('on', r.dataset.t === t)); $('#sh').innerHTML = svgI(TABS[t][0], null, 16) + TABS[t][1]; sb.innerHTML = ''; $('#meta').style.display = 'none';
 if (t === 'code') return code(sel);
 if (t === 'trace') {
  const st = document.createElement('div'); st.className = 'sticky'; const se = document.createElement('select'); se.className = 'b'; se.style.flex = '1'; se.add(new Option('trace from… (agent, trigger, row, command)', ''));
  const ent = N.filter(n => /slash|event|human|timer|row/.test(n.k) || (n.k === 'file' && n.fam === 'crew'));
  ent.sort((a, b) => a.kk.localeCompare(b.kk) || a.l.localeCompare(b.l)).forEach(n => se.add(new Option(`${KD[n.kk][2]}: ${n.l}`.slice(0, 80), n.i)));
  se.value = trace ? trace[0].n.i : ''; se.onchange = () => se.value && runTrace(N[+se.value]); st.append(se);
  for (const [lab, d] of [['‹ prev', -1], ['next ›', 1]]) { const b = document.createElement('span'); b.className = 'b'; b.textContent = lab; b.onclick = () => stepTo(tIdx + d); st.append(b) }
  const b2 = document.createElement('span'); b2.className = 'b'; b2.textContent = 'from selected'; b2.onclick = () => sel && runTrace(sel); st.append(b2); sb.append(st);
  if (!trace) { sb.insertAdjacentHTML('beforeend', '<div class="empty">Pick an entry above (an agent, a trigger, a router row …) or select a node and press "from selected". The path is numbered on the graph; prev / next walk it; a decision step lets you switch the outcome.</div>'); return }
  trace.forEach((s, i) => { const n = s.n, d = row(n, `${s.loop ? '↻ back to ' : ''}${esc(n.l)}${s.via && !s.loop ? ` <small style="color:var(--mut)">${esc(s.via.k)}</small>` : ''}`,
   `<span class="num" style="padding-left:${Math.min(s.dep, 8) * 6}px">${i + 1}</span>`, (i === tIdx ? 'on ' : '') + (bad.has(n.i) ? 'bad' : ''), () => { stepTo(i); openSide('code') });
   const br = n.out.filter(e => e.k === 'branch');
   if (n.k === 'decision' && br.length > 1 && !s.loop) { const x = document.createElement('select'); x.className = 'b'; br.forEach((e, j) => x.add(new Option(`${e.l} → ${N[e.t].l}`.slice(0, 60), j)));
    x.value = choice[n.i] || 0; x.onclick = ev => ev.stopPropagation(); x.onchange = () => { choice[n.i] = +x.value; runTrace(trace[0].n) }; d.querySelector('.t').append(x) }
   sb.append(d) }); return
 }
 const list = document.createElement('div');
 const fill = q => { list.innerHTML = '';
  if (t === 'loops') { if (!D.cycles.length) list.innerHTML = '<div class="empty">No loops or cycles found.</div>';
   D.cycles.filter(c => !q || c.label.toLowerCase().includes(q)).forEach(c => { const n = N[c.nodes[0]];
    list.append(row(n, esc(c.label) + ` <small style="color:var(--mut)">${c.kind} · ${c.nodes.length} nodes${c.gaps && c.gaps.length ? ' · gaps: ' + esc(c.gaps.join('; ')) : ''}</small>`, '', c.gaps && c.gaps.length ? 'bad' : '',
     () => { trace = null; sel = n; show(c.nodes.map(i => N[i])); fitTo([...focus]) })) })
   if ((D.deliberate || []).length) { list.insertAdjacentHTML('beforeend', `<div class="grp">deliberate (marked flow:) · ${D.deliberate.length}</div>`);
    D.deliberate.filter(it => !q || (it.code + ' ' + it.text + ' ' + it.deliberate).toLowerCase().includes(q)).forEach(it => list.insertAdjacentHTML('beforeend',
     `<div class="empty" style="text-align:left">${esc(it.code)} ${esc(it.text)} <small style="color:var(--mut)">— ${esc(it.deliberate)}</small></div>`)) } }
  else { if (!D.issues.length) list.innerHTML = '<div class="empty">No unknown behaviour: every reference resolves, every outcome is handled, every loop has a bound.</div>';
   const by = {}; D.issues.filter(it => !q || (it.code + ' ' + it.text).toLowerCase().includes(q)).forEach(it => (by[it.code] = by[it.code] || []).push(it));
   for (const c in by) { list.insertAdjacentHTML('beforeend', `<div class="grp">${esc(c)} · ${by[c].length}</div>`);
    by[c].forEach(it => { const n = it.node != null ? N[it.node] : null; list.append(row(n, esc(it.text), '', 'bad', () => { if (n) { trace = null; show([n]); sel = n; neigh(n, true); center(n); openSide('code') } })) }) } } };
 filterBox(t === 'loops' ? 'filter loops…' : 'filter issues…', fill); sb.append(list); fill('')
}
const HL = {ps1: [/#.*$/, /\b(function|param|if|elseif|else|foreach|for|while|do|until|switch|return|break|continue|throw|try|catch|finally|exit|in)\b/, /\$[\w:]+/],
 py: [/#.*$/, /\b(def|class|if|elif|else|for|while|return|break|continue|raise|try|except|finally|with|as|import|from|in|not|and|or|lambda|yield|None|True|False)\b/, /\bself\b/],
 js: [/\/\/.*$/, /\b(const|let|var|function|async|await|if|else|for|while|do|return|break|continue|throw|try|catch|new|of|in|export|import|from|true|false|null)\b/, /\$\{[^}]*\}/],
 md: [/<!--.*-->/, /^#{1,6} .*|\*\*[^*]+\*\*/, /`[^`]+`/], json: [/$^/, /\b(true|false|null)\b/, /"[\w.-]+"(?=\s*:)/]};
function hl(line, lg) { const h = HL[lg] || HL.md, rx = new RegExp(`(${h[0].source})|('(?:[^'\\\\]|\\\\.)*'|"(?:[^"\\\\]|\\\\.)*")|(${h[1].source})|(${h[2].source})|(\\b\\d+(?:\\.\\d+)?\\b)`, 'g');
 let out = '', last = 0; line.replace(rx, (m, c, s, k, v, nu, off) => { out += esc(line.slice(last, off)) + `<span class="${c ? 'cm' : s ? 'st' : k ? 'kw' : v ? 'va' : 'nu'}">${esc(m)}</span>`; last = off + m.length; return m });
 return out + esc(line.slice(last)) }
let srcWanted = null, more = 0;
function code(n) {
 if (!n) { sb.innerHTML = '<div class="empty">Click a node on the graph: its source span shows here, with its line marked.</div>'; return }
 const f = D.files[n.g].id, real = !f.startsWith('('), abs = (D.kit + '/' + f).replace(/\\/g, '/'), ln = n.ln || 1;
 $('#sh').innerHTML = svgI(KD[n.kk][1], n.col, 18) + `<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(n.l)}</span><small style="color:var(--mut);font-weight:400">${esc(KD[n.kk][2])}</small>`;
 const m = $('#meta'); m.style.display = 'block'; const iss = bad.get(n.i) || [];
 m.innerHTML = `<div class="f">${esc(f)}${n.ln ? ':' + n.ln : ''}</div>${n.d ? `<div>${esc(n.d)}</div>` : ''}${iss.map(it => `<div style="color:var(--bad)">⚠ ${esc(it.code)}: ${esc(it.text)}</div>`).join('')}
  <div>${n.out.length} out · ${n.in.length} in${real ? ` · ${D.kit ? `<a href="vscode://file/${encodeURI(abs)}:${ln}">open in editor</a>` : ''}${D.repoUrl ? `<a target="_blank" rel="noopener" href="${D.repoUrl}/${encodeURI(f)}#L${ln}">view on GitHub</a>` : ''}<span class="lnk" id="cp">copy path:line</span>` : ''}</div>`;
 if (real) $('#cp').onclick = () => { const t = `${f}:${ln}`; (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).catch(() => { const a = document.createElement('textarea'); a.value = t; document.body.append(a); a.select(); document.execCommand('copy'); a.remove() }); $('#cp').textContent = 'copied' };
 if (!real) { sb.innerHTML = '<div class="empty">A shared node (state, config, outcome or external CLI): no single source span. Its edges on the graph show who reads, writes or calls it.</div>'; return }
 if (!window.KF_SRC) { sb.innerHTML = '<div class="empty">loading source…</div>'; if (!srcWanted && D.src) { srcWanted = document.createElement('script'); srcWanted.src = D.src; srcWanted.onload = () => curTab === 'code' && code(sel); srcWanted.onerror = () => sb.innerHTML = '<div class="empty">Source sidecar not found next to this page.</div>'; document.head.append(srcWanted) } return }
 const lines = (window.KF_SRC[f] || '').split('\n'), lg = {ps1: 'ps1', psm1: 'ps1', py: 'py', js: 'js', mjs: 'js', md: 'md', json: 'json', sh: 'py'}[f.split('.').pop()] || 'md';
 let end = n.end; if (!end) { const nx = G[n.g].m.filter(o => o.ln > ln && o.k !== 'file').map(o => o.ln); end = nx.length ? Math.min(...nx) - 1 : lines.length }
 if (n.k === 'file') end = lines.length; const a = Math.max(1, ln - (n.k === 'file' ? 0 : 2)), cap = a + 80 + more;
 sb.innerHTML = ''; const pre = document.createElement('pre'); pre.style.padding = '8px 0';
 pre.innerHTML = lines.slice(a - 1, Math.min(end, cap)).map((l, i) => `<div class="cl${a + i === ln ? ' me' : ''}"><span class="n">${a + i}</span><span class="x">${hl(l, lg)}</span></div>`).join('');
 sb.append(pre); if (end > cap) { const b = document.createElement('div'); b.className = 'empty'; b.innerHTML = `<span class="lnk">show more (${end - cap} lines)</span>`; b.onclick = () => { more += 80; code(n) }; sb.append(b) }
 const me = pre.querySelector('.me'); if (me) me.scrollIntoView({block: 'center'})
}
$('#grip').onpointerdown = e => { e.preventDefault(); side.classList.add('drag'); const mv = ev => { sideW = Math.max(280, Math.min(innerWidth * .7, innerWidth - 44 - ev.clientX)); side.style.width = sideW + 'px'; size(); if (sel) center(rep(sel) || sel) };
 const up = () => { side.classList.remove('drag'); LS.set('w', sideW); removeEventListener('pointermove', mv); removeEventListener('pointerup', up) }; addEventListener('pointermove', mv); addEventListener('pointerup', up) };
$('#grip').ondblclick = () => { sideW = 420; side.style.width = sideW + 'px'; LS.set('w', sideW); setTimeout(size, 200) };
['Overview', 'Detail', 'Everything'].forEach((t, i) => { const b = document.createElement('span'); b.className = 'b'; b.textContent = t; b.onclick = () => setLevel(i); $('#lv').append(b) });
function menu(id, items, state, label) { const dd = $(id), m = dd.querySelector('.menu'); dd.firstElementChild.onclick = e => { e.stopPropagation(); document.querySelectorAll('.dd').forEach(x => x !== dd && x.classList.remove('open')); dd.classList.toggle('open') };
 m.onclick = e => e.stopPropagation();
 for (const [k, html, c] of items) { const l = document.createElement('label'); l.innerHTML = `<input type="checkbox" ${state[k] ? 'checked' : ''}>${html}<small>${c}</small>`; l.firstChild.onchange = ev => { state[k] = ev.target.checked; rebuild() }; m.append(l) } }
menu('#ddS', Object.keys(FAM).map(f => [f, `${svgI(Object.values(KD).find(k => k[0] === f)[1], FAM[f][1])} ${FAM[f][0]}`, N.filter(n => n.fam === f).length]), famOn);
menu('#ddE', Object.keys(EK).filter(k => E.some(e => e.k === k)).map(k => [k, `<svg width="26" height="8"><line x1="1" y1="4" x2="25" y2="4" stroke="${EK[k][0]}" stroke-width="2" ${EK[k][1] === 'dash' ? 'stroke-dasharray="6 4"' : EK[k][1] === 'dot' ? 'stroke-dasharray="1.5 3"' : ''}/></svg> ${k}`, E.filter(e => e.k === k).length]), ekOn);
const leg = $('#leg'), cnt = k => N.filter(n => n.kk === k).length;
$('#sx').onclick = closeSide;
leg.innerHTML = `<div id="howto">${esc($('#ttl').title.replace('; double-click = collapse a file', '').replace(/click/g, 'tap').replace('zoom in', 'pinch to zoom in'))}</div>` + '<h4 style="margin-top:0">Nodes</h4><div class="g">' + Object.keys(KD).filter(cnt).map(k => `<span class="it">${svgI(KD[k][1], FAM[KD[k][0]][1])}${esc(KD[k][2])} <small style="color:var(--mut)">${cnt(k)}</small></span>`).join('') +
 '</div><h4>Edges</h4><div class="g">' + Object.keys(EK).filter(k => E.some(e => e.k === k)).map(k => `<span class="it"><svg width="22" height="8"><line x1="1" y1="4" x2="21" y2="4" stroke="${EK[k][0]}" stroke-width="2" ${EK[k][1] === 'dash' ? 'stroke-dasharray="5 3"' : EK[k][1] === 'dot' ? 'stroke-dasharray="1.5 3"' : ''}/></svg>${k}</span>`).join('') +
 '</div><h4>Families</h4><div class="g">' + Object.values(FAM).map(f => `<span class="it"><svg width="10" height="10"><circle cx="5" cy="5" r="4" fill="${f[1]}"/></svg>${f[0]}</span>`).join('') + '</div>';
$('#legb').innerHTML = svgI('key', null, 18); $('#legb').onclick = e => { e.stopPropagation(); leg.classList.toggle('open') }; $('#legb').onmouseenter = () => { if (matchMedia('(hover:hover)').matches) leg.classList.add('open') }; leg.onclick = e => e.stopPropagation();
$('#ttl').onclick = e => { if (narrow()) { e.stopPropagation(); leg.classList.toggle('open') } };   // no hover on phones: the how-to sits in the key
addEventListener('click', () => { leg.classList.remove('open'); document.querySelectorAll('.dd').forEach(x => x.classList.remove('open')) });
$('#q').oninput = () => { const q = $('#q').value.trim().toLowerCase(); trace = null; if (!q) { force = new Set(); focus = fE = null; return rebuild() } show(N.filter(n => (n.l + ' ' + n.id).toLowerCase().includes(q)).slice(0, 300)) };
$('#q').onkeydown = e => { if (e.key === 'Enter' && focus && focus.size) { const n = [...focus][0]; select(n); center(n) } };
$('#fit').onclick = () => { fitTo(); fitSc = sc; LVL = 0; rebuild() };
let drag = null, pinch = null;
const ptrs = new Map();   // touch: one finger pans / drags, two pinch-zoom; a touch hit reaches 22 px (a 44 px target)
const hit = (sx, sy, slop = 4) => { const [x, y] = s2w(sx, sy); let best = null, bd = 1e9; for (const n of VN) { const r = LVL === 0 ? (n.k === 'file' ? 16 : 11) : n.r, d = Math.hypot(n.x - x, n.y - y); if (d < Math.max(r + 4 / sc, slop / sc) && d < bd) { bd = d; best = n } } return best };
const pt = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top] };
const two = () => { const [a, b] = [...ptrs.values()]; return [Math.hypot(a[0] - b[0], a[1] - b[1]) || 1, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2] };
cv.addEventListener('pointerdown', e => { const [x, y] = pt(e); ptrs.set(e.pointerId, [x, y]); cv.setPointerCapture(e.pointerId);
 if (ptrs.size === 2) { const [d, mx, my] = two(); pinch = {d, mx, my, sc, tx, ty}; drag = null; tip.style.display = 'none'; return }
 const n = hit(x, y, e.pointerType === 'touch' ? 22 : 4); drag = ptrs.size === 1 ? {n, x, y, tx, ty, moved: false, thr: e.pointerType === 'touch' ? 8 : 3} : null });
const lift = e => { ptrs.delete(e.pointerId); if (pinch && ptrs.size < 2) { pinch = null; drag = null } };
cv.addEventListener('pointercancel', e => { lift(e); drag = null });
cv.addEventListener('pointermove', e => { const [x, y] = pt(e); if (ptrs.has(e.pointerId)) ptrs.set(e.pointerId, [x, y]);
 if (pinch && ptrs.size >= 2) { const [d, mx, my] = two(), f = d / pinch.d; sc = pinch.sc * f; tx = mx - (pinch.mx - pinch.tx) * f; ty = my - (pinch.my - pinch.ty) * f; zoomLevel(); draw(); return }
 if (!drag) { if (e.pointerType === 'touch') return; const n = hit(x, y); if (n !== hover) { hover = n; draw() }
  if (n) { tip.style.display = 'block'; tip.style.left = Math.min(e.clientX + 14, innerWidth - 390) + 'px'; tip.style.top = e.clientY + 14 + 'px'; tip.textContent = `${n.l}\n${KD[n.kk][2]} · ${fl(n)}${bad.has(n.i) ? '\n⚠ ' + bad.get(n.i)[0].code : ''}` } else tip.style.display = 'none'; return }
 const dx = x - drag.x, dy = y - drag.y; if (Math.abs(dx) + Math.abs(dy) > drag.thr) drag.moved = true; if (!drag.moved) return;
 if (drag.n) { const [wx, wy] = s2w(x, y); drag.n.fx = wx; drag.n.fy = wy; heat(.2) } else { tx = drag.tx + dx; ty = drag.ty + dy; draw() } });
cv.addEventListener('pointerup', e => { lift(e); if (drag && !drag.moved) { const n = drag.n; if (!n) { sel = null; focus = fE = null; trace = null; force = new Set(); rebuild() } else select(n, e.shiftKey || (focus && focus.has(n) && n !== sel)) } drag = null });
cv.addEventListener('dblclick', e => { const n = hit(...pt(e)); if (!n || !G[n.g].fn) return; coll.has(n.g) ? coll.delete(n.g) : coll.add(n.g); rebuild() });
cv.addEventListener('contextmenu', e => { const n = hit(...pt(e)); if (n) { e.preventDefault(); n.fx = n.fy = null; heat(.2) } });
cv.addEventListener('wheel', e => { e.preventDefault(); const [x, y] = pt(e), f = Math.exp(-e.deltaY * .0015); tx = x - (x - tx) * f; ty = y - (y - ty) * f; sc *= f; zoomLevel(); draw() }, {passive: false});
addEventListener('keydown', e => { if (e.key === 'Escape') { leg.classList.remove('open'); sel = null; trace = null; focus = fE = null; force = new Set(); $('#q').value = ''; rebuild() }
 if (trace && (e.key === 'ArrowRight' || e.key === 'ArrowLeft') && document.activeElement.tagName !== 'INPUT') stepTo(tIdx + (e.key === 'ArrowRight' ? 1 : -1)) });
new ResizeObserver(size).observe($('#main'));
rebuild(); for (let i = 0; i < 420; i++) tick(); size(); fitTo(); fitSc = sc; draw(); if (LS.get('open', false) && !narrow()) openSide(curTab);
window.KF = {N, G, D, select, runTrace, stepTo, setLevel, openSide, closeSide, show, fitTo, center, get sc() { return sc }};
</script></body></html>
'''


# ==== the page command and the lint hook
# ---- command: flow, its output path, the lint hook
def live_root(kit):
    """The live clone (main worktree): a worktree's lint refreshes the page the owner opens."""
    main = main_clone(kit)
    return main if osp.isfile(osp.join(main, PATHS_JSON)) else kit

def default_out(kit):
    return kit_path('kit-flow', kit=live_root(kit))

def page_data(k, problems, kit=None):
    """Page model: the parts inside every file, the edges between them, loops, issues."""
    live = live_root(kit or k.dir)
    data = model(k, problems, kit_path('kit-flow-cache', kit=live))
    data['kit'], data['_texts'] = live.replace('\\', '/'), {f: k.texts.get(f, '') for f in k.files}
    return data

def public_only(k):
    """--public (the published page): drop every local-only file."""
    keep = [f for f in k.files if not is_overlay(k, f)]
    k.files, k.fileset = keep, set(keep)
    k.texts = {f: t for f, t in k.texts.items() if f in k.fileset}
    k.skills = [x for x in k.skills if f'skills/{x}/SKILL.md' in k.fileset]
    k.agents = {n: f for n, f in k.agents.items() if f in k.fileset}
    k.workflows = {n: f for n, f in k.workflows.items() if f in k.fileset}
    return k

def build(kit, public=False):
    k = load(kit)
    if public:
        k = public_only(k)
    data = page_data(k, lint(k))
    if public:   # no local paths; code links go to the CI repo host
        repo, sha = os.environ.get('GITHUB_REPOSITORY'), os.environ.get('GITHUB_SHA')
        data['kit'], data['repoUrl'] = '', (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/blob/{sha}" if repo and sha else '')
    return data

def render(kit, out, quiet=False, data=None, public=False):
    data = data or build(kit, public)
    os.makedirs(osp.dirname(out), exist_ok=True)
    write(out, data, data.pop('_texts', {}))
    c = data['counts']
    if not quiet:
        print(f"kit-flow: {out}  ({c['files']} files, {c['nodes']} nodes, {c['edges']} edges, {c['cycles']} loops, {c['issues']} issues)")
    return data

def cmd_flow(a):
    flags, rest = parse_opts(a, {'--out'})
    kit = osp.abspath(rest[0] if rest else KIT_DIR)
    out = osp.abspath(flags.get('--out') or default_out(kit))
    if '--readme' in flags:
        write_readme(kit)
    render(kit, out, public='--public' in flags)
    if '--open' in flags:
        if sys.platform.startswith('win'):
            os.startfile(out)  # type: ignore[attr-defined]  # noqa
        else:
            subprocess.run(['open' if sys.platform == 'darwin' else 'xdg-open', out], check=False)
    return 0

def lint_hook(k, problems, flags):
    """The flow graph's own issues gate the commit too (a `flow: <reason>` marker at the source line makes one deliberate)."""
    if '--warn' in flags and '--no-flow' in flags:
        return   # report-only callers (SessionStart, pre-push, audit scan): stay fast
    try:
        data = page_data(k, problems)
        problems += [('FLOW-' + it['code'], 'flow', it['text']) for it in data['issues'] if it.get('flow')]
    except Exception as e:  # noqa - a model crash is itself a problem
        problems.append(('FLOW-MODEL', 'kittool_flow.py', f'the flow model failed: {e}'))
        return
    if '--no-flow' not in flags:   # keep the page current
        try:
            render(k.dir, default_out(k.dir), quiet='--summary' in flags, data=data)
        except Exception as e:  # a convenience: never fail the lint
            print(f'kittool lint: flow page not regenerated: {e}', file=sys.stderr)

COMMANDS = {'flow': cmd_flow}
