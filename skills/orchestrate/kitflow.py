"""kitflow.py: the kit-flow page (kittool.py flow / lint import it; it has no command line of its own).
Usage: python -X utf8 skills/orchestrate/kittool.py flow [--open]   (kittool calls model() then html())
Exit codes: none (a library; kittool.py flow exits 0, or 1 on a usage error).
Model: every part INSIDE the kit's files is a node, grouped by file: commands (script verb / sub-verb as invoked), functions,
workflow phases and agent() calls, SKILL steps / table rows / sections, decisions (one edge per outcome), control-flow points
(parallel, wait / gate, timer, retry, event, lock, error, exit, human), shared state (paths.json names, *.json files), config
keys, external CLIs. Edges are references found in the source (regexes per language), each with its reason and file:line.
Parsing is cached per file content hash. Refs that point nowhere, outcomes nothing handles and loops without a bound are the
"unknown behaviour" issues. The page draws it as a force-directed graph (canvas, offline, no CDN).
"""
import hashlib, json, os, re, time
from collections import defaultdict, deque

VER = 4
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
CF = [('parallel', r'\bparallel\(|Promise\.all|\bpipeline\(|-Parallel\b|Start-ThreadJob|Start-Job\b|\bin parallel\b|\bpools?\b'),
      ('wait', r'decide wait|\bWait-\w+|Start-Sleep|time\.sleep|setTimeout|merge-when-green|memory gate|\bgate (?:slot|queue)|holdMerge|'
               r'\blease\b|seat acquire|-MaxMinutes\b|\bwaits? (?:for|until)\b'),
      ('timer', r'-IfDue\b|every \d+ ?min\w*|\bcron\b|heartbeat|IdleHours|minIntervalHours|\bweekly\b|idle grace|\bstale\w*\b'),
      ('retry', r'\bretr(?:y|ies)\b|\bat most \d+ (?:rounds?|times|tries)|\bmax(?:imum)? \d+ rounds?|\battempts?\b|stronger (?:fix|retry|round)|\bre-?test\b'),
      ('error', r'\bcatch\b|\btrap\b|roll(?:ed)?[ -]?back|\bbisect\b|\bfallback\b|\brecover\w*\b'),
      ('event', r'\bnotification\b|\bsignals?\b|\bboard beat\b|\bbeat\b|supervise (?:flag|prints)|\bon SessionStart\b'),
      ('lock', r'\bLocked\b|\blocked\(|\.lock\b|Mutex|O_EXCL|\bclaims?\b'),
      ('exit', r'\bexit [0-3]\b|sys\.exit\(|Exit codes?:'),
      ('human', r"(?:person|owner|tester|human|lead)\s+(?:says|answers|approves|tests|asks|decides)|\bby hand\b|a person's (?:word|yes)")]
CF = [(k, re.compile(p, re.I)) for k, p in CF]
BOUND = re.compile(r'(?:at most|max(?:imum)?|<=|≤|up to)\s*(\d+)\s*(rounds?|times|tries|retries|attempts|min\w*|h(?:ours?)?|s\b|cycles?)|'
                   r'every (\d+) ?(min\w*|h\w*|s\b|days?)|-MaxMinutes (\d+)|(?:minIntervalHours|IdleHours|staleMin)\D{0,6}(\d+)', re.I)
OUTCOMES = ('PASS', 'FAIL', 'BLOCKED', 'NONE', 'NOT_TESTED', 'PASS_WITH_NOTE', 'OUT_OF_SCOPE', 'LIVE', 'REFUSED', 'REJECTED', 'ROLLED BACK',
            'SANDBOX', 'ACT', 'WATCH', 'INFO', 'HEAVY', 'LIGHT', 'MERGED', 'SCHEDULED', 'WAIT', 'CONFLICT', 'PIPELINE_FAILED',
            'closed', 'failedTesting', 'failed testing', 'in test', 'promoted', '[Bug]', 'merged', 'held', 'deferred', 'blocked')
TERMINAL = {'PASS', 'closed', 'merged', 'MERGED', 'promoted', 'in test', 'LIVE', 'INFO', 'OUT_OF_SCOPE', 'NONE', 'PASS_WITH_NOTE'}
OUT_RX = re.compile(r'(?<![\w-])(' + '|'.join(re.escape(o) for o in sorted(OUTCOMES, key=len, reverse=True)) + r')(?![\w-])')
DSUBJ = {'mode', 'trigger', 'status', 'verdict', 'class', 'mclass', 'result', 'outcome', 'kind', 'state', 'level', 'severity', 'defect',
         'cause', 'trtype', '__trtype', 'reports', 'rtype', 'flag', 'decision', 'answer', 'review', 'learn'}
SUBVAR = ('Action', 'Sub', '__v', 'Verb', 'Op')
FLOW = {'calls', 'runs', 'impl', 'next', 'spawns', 'loads', 'routes', 'branch', 'loop', 'writes', 'reads', 'triggers', 'has'}


def short(s, n=44):
    s = re.sub(r'[`*]+', '', re.sub(r'\s+', ' ', s or '')).strip()
    return s if len(s) <= n else s[:n].rsplit(' ', 1)[0] + '…'


def lang(f):
    e = os.path.splitext(f)[1]
    return {'.ps1': 'ps1', '.psm1': 'ps1', '.py': 'py', '.js': 'js', '.mjs': 'js', '.sh': 'sh', '.md': 'md', '.json': 'json'}.get(e, '')


class P:
    """One file's parse: parts [id, label, kind, line, desc] and refs (resolved later against every file)."""
    def __init__(s, f):
        s.f, s.parts, s.refs, s.text = f, [], [], {}

    def part(s, pid, label, kind, ln, desc=''):
        s.parts.append([pid, label, kind, ln, short(desc, 260)])
        return pid

    def ref(s, *r):
        s.refs.append(list(r))


def bound_of(t):
    m = BOUND.search(t or '')
    if not m:
        return ''
    g = [x for x in m.groups() if x]
    return ('every ' if m.group(3) else 'max ') + ' '.join(g[:2])


def scan(p, src, text, ln, code, aliases):
    """Refs in one block of text owned by part src: commands, external CLIs, state, config, names, outcomes."""
    base = os.path.basename(p.f)
    spans = [(0, text)] if code else [(m.start(1), m.group(1)) for m in re.finditer(r'`([^`]+)`', text)]
    for off, t in spans:
        def at(m):
            pos = off + m.start()
            line = text[text.rfind('\n', 0, pos) + 1:pos]
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
                if m.group(1) in GIT_VERBS:
                    p.ref('edge', src, '@ext/git ' + m.group(1), 'calls', f'{base}:{at(m)[0]}', '')
        for m in TOOLS.finditer(t):
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


def control(p, src, text, ln):
    """Control-flow points inside a part: one child node per kind, with the bound it states."""
    for kind, rx in CF:
        m = rx.search(text)
        if not m:
            continue
        b = bound_of(text[max(0, m.start() - 120):m.end() + 160])
        cid = p.part(f'{src}~{kind}', short(m.group(0), 28) + (f' ({b})' if b else ''), kind, ln + text.count('\n', 0, m.start()),
                     text[max(0, m.start() - 60):m.end() + 140])
        if kind in ('human', 'event', 'timer'):
            p.ref('edge', cid, src, 'triggers', short(m.group(0), 40), '')
        else:
            p.ref('edge', src, cid, 'has', short(m.group(0), 40), '')
        if kind in ('retry', 'timer'):
            p.ref('edge', cid, cid, 'loop', b or 'no bound', b)


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


def parse_code(p, f, text):
    lg, base = lang(f), os.path.basename(f)
    lines = text.split('\n')
    sp = spans_of(lines, lg)
    own = [None] * len(lines)
    for a, b, name in sorted(sp, key=lambda x: x[1] - x[0], reverse=True):
        pid = p.part(f'{f}#{name}', name + ('()' if lg != 'ps1' else ''), 'fn', a + 1, lines[a].strip())
        for i in range(a, b + 1):
            own[i] = pid
    aliases = {}
    for m in re.finditer(r'(?:const\s+(\w+)\s*=|\$(\w+)\s*=)\s*[^\n;]*?[\\/]([\w-]+\.(?:ps1|py|mjs))', text):
        aliases[m.group(1) or m.group(2)] = m.group(3)
    consts = {m.group(1): m.group(2) for m in re.finditer(r'const\s+(\w+)\s*=.*?(\d+)\s*$', text, re.M)}
    # commands this script implements: dispatch lines (verb -> function) and the sub-verbs that function switches on
    impl = {}
    for i, l in enumerate(lines):
        m = re.search(r"^\s*'([\w-]+)'\s*\{\s*Invoke-KitVerb\s+([\w-]+)|__verb -eq '([\w-]+)'\)\s*\{\s*Invoke-KitVerb\s+([\w-]+)|"
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
        m = re.search(r'else\s*\{\s*Invoke-KitVerb\s+([\w-]+)', l)
        if m:
            impl[m.group(1)] = (f, base)
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
    # decisions: comparisons and switches on a value (outcome per case), enum schemas
    ekeys = set(re.findall(r"(\w+):\s*\{\s*type:\s*'string',\s*enum:", text))
    for i, l in enumerate(lines):
        src = own[i] or f
        for m in re.finditer(r"([\w$.\]\[]+?)\s*(?:===?|!==?|-c?eq|-ne|==|!=)\s*'([^'\n]{1,24})'", l):
            subj, val = m.group(1).lstrip('$').split('.')[-1].strip('[]'), m.group(2)
            if subj in SUBVAR + ('__verb', 'cmd') or not re.match(r'^[\w \[\]-]{1,24}$', val) or not (
                    subj in ekeys or re.match(r'^[A-Z][A-Z_ ]+$', val) or subj.lower() in DSUBJ):
                continue
            decision(p, f, src, subj, val, lines, i, base)
        m = re.match(r'\s*switch\s*(?:-\w+\s*)*\(\s*\$([\w.]+)\s*\)', l)
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
    # workflows: phases, slash entry, agent() calls (with the loop that repeats them), exit
    if f.startswith('workflows/'):
        name = base.rsplit('.', 1)[0]
        wd = re.search(r"whenToUse:\s*'((?:[^'\\]|\\.)*)'", text)
        slash = p.part(f'{f}#/{name}', '/' + name, 'slash', 1, wd.group(1) if wd else '')
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
        scan(p, src, t, bl[0][0], True, aliases)
        p.ref('fn', src, sorted(set(re.findall(r'([A-Za-z_][\w-]*)\s*\(' if lg != 'ps1' else r'(?<![\w$.-])([A-Za-z_][\w-]*)', t))), bl[0][0])
        if src != f:
            control(p, src, t, bl[0][0])


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
        control(p, src, t, bl[0][0]) if src != f else None
        for m in re.finditer(r'\b([\w-]+)(?: SKILL\.md)?\s+(?:steps?\s+(\d+|[A-Z]{1,3}\d+[a-z]?)|([A-Z]{1,3}\d+[a-z]?))\b', t):
            p.ref('step', src, m.group(1), m.group(2) or m.group(3), bl[0][0])
        for m in re.finditer(r'(?<![\w#-])([A-Z]{1,3}\d{1,2}[a-z]?)(?![\w-])', t):
            p.ref('step', src, '', m.group(1), bl[0][0])
        arrows = [a for a in re.split(r'\s[·;]\s|\.\s(?=[A-Z])|\n', t) if re.search(r'->|→', a)]
        for a in arrows:
            left, right = re.split(r'\s*(?:->|→)\s*', a, 1)
            p.ref('arrow', src, short(left.split(':')[-1], 50), right[:300], bl[0][0], len(arrows))


def parse_json(p, f, text):
    try:
        d = json.loads(text)
    except ValueError:
        return
    if f.endswith('paths.json'):
        for sect in ('runtime', 'durable'):
            for k, v in (d.get(sect) or {}).items():
                p.part(f'@state/{k}', k, 'state', 1, f'{sect}: {v}')
    elif os.path.basename(f) == 'settings.json':
        for ev, bl in (d.get('hooks') or {}).items():
            for b in bl:
                eid = p.part(f'{f}#{ev}{" " + b["matcher"] if b.get("matcher") else ""}', ev + (f' ({b["matcher"]})' if b.get('matcher') else ''),
                             'event', 1, 'Claude Code runs these hooks on ' + ev)
                for h in b.get('hooks', []):
                    scan(p, eid, ' '.join([h.get('command', '')] + list(h.get('args', []))).replace('/', ' / '), 1, True, {})
                    scan(p, eid, ' '.join([h.get('command', '')] + [os.path.basename(x) for x in h.get('args', [])]), 1, True, {})
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
        ev = {'pre-commit': 'git commit', 'pre-push': 'git push', 'post-merge': 'git pull / merge'}.get(os.path.basename(f), 'git hook')
        eid = p.part(f'{f}#{ev}', ev, 'event', 1, f'git runs {f} (core.hooksPath)')
        scan(p, eid, text, 1, True, {})
    elif lg in ('ps1', 'py', 'js', 'sh'):
        parse_code(p, f, text)
    elif lg == 'md':
        parse_md(p, f, text)
    elif lg == 'json':
        parse_json(p, f, text)
    return {'parts': p.parts, 'refs': p.refs}


def model(k, problems, cache_path=None):
    """The page data: files, nodes, edges (with back-edge / loop flags), cycles, issues."""
    cache = {}
    if cache_path and os.path.isfile(cache_path):
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
        if f.endswith('.md'):   # the raw file: k.texts expands @imports (CLAUDE.md would repeat AGENTS.md)
            try:
                with open(os.path.join(k.dir, f), encoding='utf-8', errors='replace') as fh:
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
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            with open(cache_path, 'w', encoding='utf-8') as fh:
                json.dump(cache, fh)
        except OSError:
            pass
    return link(k, parsed, problems)


def fkind(f):
    b = os.path.basename(f)
    return ('skill' if b == 'SKILL.md' else 'agent' if f.startswith('agents/') else 'workflow' if f.startswith('workflows/') else
            'script' if f.endswith(CODE) or f.startswith('.githooks/') else 'doc')


def link(k, parsed, problems):
    N, E, issues, grp = {}, {}, [], {}

    def node(i, label, kind, f, ln=0, d=''):
        if i not in N:
            N[i] = [i, label, kind, f, ln, d]
        return i

    for f in k.files:
        lab = f.split('/')[1] if fkind(f) == 'skill' else os.path.basename(f)
        node(f, lab, 'file', f, 1, '')
        for pid, label, kind, ln, d in parsed[f]['parts']:
            node(pid, label, kind, f, ln, d)
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
                edge(src, resolve_fn(r[2], f), 'impl', f'{os.path.basename(f)}:{r[3]}')
            elif kind == 'cmd':
                hit, miss = resolve_cmd(r[2], r[3], r[4])
                if hit and r[6] and hit.split('#')[0] == f:
                    continue   # a script's own usage comment, not a call
                if hit:
                    edge(src, hit, 'calls' if N.get(src, [0, 0, ''])[2] == 'fn' else 'runs', f'{os.path.basename(f)}:{r[5]}')
                elif miss and not r[6] and re.match(r'^[a-z][a-z-]+$', r[3]) and r[3] not in ('and', 'or', 'the', 'to', 'in', 'is', 'with', 'from', 'for', 'then', 'only'):
                    unres[miss].add(f'{f}:{r[5]}')
            elif kind == 'fn':
                for name in r[2]:
                    t = resolve_fn(name, f)
                    if t and t != src and not t.startswith(src + '~'):
                        edge(src, t, 'calls', f'{os.path.basename(f)}:{r[3]}')
            elif kind == 'tok':
                for tok, r3 in r[2]:
                    if tok in skills and not f.startswith(f'skills/{tok}/'):
                        edge(src, skills[tok], 'loads', f'{os.path.basename(f)}:{r3} names {tok}')
                    elif tok in agents and agents[tok] != f:
                        edge(src, agents[tok], 'spawns' if 'spawn' in (N[src][5] or '').lower() or f.startswith('workflows/') else 'loads',
                             f'{os.path.basename(f)}:{r3} names {tok}')
                    elif tok in wfs and not f.startswith('workflows/'):
                        edge(src, wfs[tok], 'loads' if f.startswith('agents/') else 'runs', f'{os.path.basename(f)}:{r3} launches {tok}')
                    elif f.endswith('.md') and re.match(r'^[A-Z][\w]*-[A-Z]\w+$', tok) and tok in fns:
                        edge(src, resolve_fn(tok, f), 'runs', f'{os.path.basename(f)}:{r3} names {tok}')
            elif kind == 'state':
                if r[2] in states:
                    if r[2] == 'runtime':
                        continue
                    edge(*((src, '@state/' + r[2], 'writes') if r[3] == 'w' else ('@state/' + r[2], src, 'reads')), f'{os.path.basename(f)}:{r[4]}')
                else:
                    unres[f'state {r[2]}'].add(f'{f}:{r[4]}')
            elif kind == 'cfg':
                key = r[2]
                while key and key not in cfg:
                    key = key.rsplit('.', 1)[0] if '.' in key else ''
                if key and not re.search(r'\.(ps1|py|m?js|json|md|html|txt|sh|exe)$', r[2]):
                    edge('@config/' + key, src, 'reads', f'{os.path.basename(f)}:{r[3]} reads {r[2]}')
            elif kind == 'step':
                sk, sid = r[2], r[3]
                tf = skills.get(sk) or (f if not sk else None)
                if tf and sid in steps.get(tf, {}):
                    t = steps[tf][sid]
                    if t != src:
                        edge(src, t, 'loads' if tf != f else 'next', f'{os.path.basename(f)}:{r[4]} {sk + " " if sk else ""}{sid}')
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
    # one more pass for enums after every branch edge exists (comparisons may follow the schema in the file)
    for f in k.files:
        for r in parsed[f]['refs']:
            if r[0] == 'enum':
                handled = {e[3][2:] for e in E.values() if e[0] == r[1] and e[2] == 'branch'}
                for v in r[2]:
                    if v not in handled:
                        edge(r[1], '@outcome/' + v, 'branch', f'= {v} (schema)')
                    if v not in handled and v not in TERMINAL:
                        issues.append({'code': 'UNHANDLED', 'node': r[1], 'text': f'{N[r[1]][1]} outcome {v}: no code branches on it ({f})'})
    for miss, where in sorted(unres.items()):
        issues.append({'code': 'UNRESOLVED', 'node': sorted(where)[0].rsplit(':', 1)[0], 'text': f'{miss}: no such command/step ({", ".join(sorted(where)[:3])})'})
    for e in E.values():
        if e[2] == 'loop' and e[0] == e[1] and not e[4] and N[e[0]][2] in ('retry', 'timer'):
            issues.append({'code': 'NO-BOUND', 'node': e[0], 'text': f'{N[e[0]][1]}: a loop with no stated bound ({N[e[0]][3]}:{N[e[0]][4]})'})
    for i, n in N.items():
        if n[2] == 'decision' and (n[3].endswith('.md') or n[3].startswith('workflows/')):
            outs = [e for e in E.values() if e[0] == i and e[2] == 'branch']
            if outs and all(e[1].startswith('@outcome/') and e[1][9:] not in TERMINAL for e in outs):
                issues.append({'code': 'DEAD-END', 'node': i, 'text': f'{n[1]}: outcomes {", ".join(sorted({e[1][9:] for e in outs}))} lead nowhere ({n[3]}:{n[4]})'})
    for c, w, m in problems:
        issues.append({'code': c, 'node': w if w in N else None, 'text': f'{w}: {m}'})
    return pack(k, N, E, issues)


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


def pack(k, N, E, issues):
    ids = list(N)
    ix = {i: n for n, i in enumerate(ids)}
    files = sorted({n[3] for n in N.values()})
    fx = {f: n for n, f in enumerate(files)}
    edges = [[ix[a], ix[b], kind, lab, bnd, 0] for a, b, kind, lab, bnd in E.values()]
    out = defaultdict(list)
    for n, e in enumerate(edges):
        if e[2] in FLOW:
            out[e[0]].append((e[1], n))
    # back edges: iterative DFS from entry points (events, slash commands, commands, rows, humans), then the rest
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
    for n, e in enumerate(edges):   # named loops: each loop edge + the shortest way back
        if e[2] != 'loop' and not (e[5] and e[2] in ('branch', 'next')):
            continue
        if e[0] == e[1] and N[ids[e[0]]][2] in ('retry', 'timer') and not e[4]:
            continue
        path = [e[0]] if e[0] == e[1] else (shortest(out, e[1], e[0]) or [e[1], e[0]])
        if path:
            lab = f"{N[ids[e[0]]][1]} ↻{' ' + e[4] if e[4] else ''}"
            cycles.append({'label': short(lab, 50), 'nodes': path, 'bound': e[4], 'kind': N[ids[e[0]]][2]})
    proc = defaultdict(list)   # cycles of the process (commands, steps, phases, decisions, state), not of helper calls
    for n, e in enumerate(edges):
        if e[2] in FLOW - {'calls', 'loads', 'has'}:
            proc[e[0]].append((e[1], n))
    for comp in tarjan(len(ids), proc):
        if len(comp) >= 2:
            names = sorted(comp, key=lambda n: -len(out[n]))[:3]
            cycles.append({'label': short(' → '.join(N[ids[n]][1] for n in names), 50) + f' ({len(comp)})', 'nodes': comp, 'bound': '', 'kind': 'scc'})
    seen, uniq = set(), []
    rank = {'call': 0, 'phase': 0, 'step': 1, 'cmd': 1, 'row': 1, 'decision': 1, 'scc': 2}
    for c in sorted(cycles, key=lambda c: (rank.get(c['kind'], 3), len(c['nodes']))):
        key = tuple(sorted(c['nodes']))
        if key not in seen:
            seen.add(key)
            uniq.append(c)
    nodes = [[N[i][1], N[i][2], fx[N[i][3]], N[i][4], N[i][5], i] for i in ids]
    fk = [{'id': f, 'kind': fkind(f) if not f.startswith('(') else 'pseudo'} for f in files]
    for it in issues:
        it['node'] = ix.get(it['node']) if it.get('node') in ix else (ix.get(it['node'].split(':')[0]) if it.get('node') else None)
    counts = {'nodes': len(nodes), 'edges': len(edges), 'files': len([f for f in files if not f.startswith('(')]), 'issues': len(issues),
              'cycles': len(uniq)}
    return {'kit': k.dir, 'generated': time.strftime('%Y-%m-%d %H:%M:%S'), 'files': fk, 'nodes': nodes, 'edges': edges,
            'cycles': uniq[:80], 'issues': issues, 'counts': counts}


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


def html(data):
    return PAGE.replace('__DATA__', json.dumps(data, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/'))


PAGE = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Kit flow</title>
<style>:root{--bg:#f8fafc;--fg:#0f172a;--mut:#64748b;--ln:#cbd5e1;--pn:#ffffffee;--hi:#d97706;--bad:#dc2626}
@media (prefers-color-scheme:dark){:root{--bg:#0b1120;--fg:#e2e8f0;--mut:#94a3b8;--ln:#334155;--pn:#111827ee;--hi:#fbbf24;--bad:#f87171}}
html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--fg);font:12px system-ui,sans-serif}
#c{position:fixed;inset:0;width:100%;height:100%;touch-action:none}
.bar{position:fixed;left:8px;right:8px;display:flex;gap:4px;flex-wrap:wrap;align-items:center;pointer-events:none}.bar>*{pointer-events:auto}
#top{top:6px}#chips{top:36px;max-height:80px;overflow:auto}
.p{background:var(--pn);border:1px solid var(--ln);border-radius:11px;padding:2px 7px;cursor:pointer;user-select:none;white-space:nowrap}
.p.off{opacity:.35}.p.bad{border-color:var(--bad);color:var(--bad)}b.p{cursor:default}.p i{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:4px}
input,select{background:var(--pn);color:var(--fg);border:1px solid var(--ln);border-radius:11px;padding:2px 7px;font:inherit}
#pan{position:fixed;right:8px;top:108px;bottom:8px;width:min(380px,calc(100vw - 16px));background:var(--pn);border:1px solid var(--ln);border-radius:8px;display:none;flex-direction:column}
#pan.on{display:flex}#ptabs{display:flex;gap:4px;padding:6px}#pbody{overflow:auto;padding:0 8px 8px;flex:1}
.st{padding:2px 0;border-bottom:1px solid var(--ln);cursor:pointer}.st small{color:var(--mut)}.st.bad{color:var(--bad)}
#tip{position:fixed;max-width:420px;background:var(--pn);border:1px solid var(--ln);border-radius:6px;padding:6px 8px;pointer-events:none;display:none;white-space:pre-wrap}</style></head><body>
<canvas id="c"></canvas>
<div class="bar" id="top"><b class="p">kit flow</b><span class="p" id="cnt"></span><span class="p" id="iss"></span><input id="q" placeholder="search (Enter)" size="16">
<label class="p">depth <input id="dep" type="range" min="1" max="6" value="2" style="width:60px;vertical-align:middle"></label>
<select id="tr"><option value="">trace from…</option></select><span class="p" id="trs">trace selected</span><span class="p" id="fit">fit</span><span class="p" id="pt">panel</span></div>
<div class="bar" id="chips"></div><div id="pan"><div id="ptabs"></div><div id="pbody"></div></div><div id="tip"></div>
<script>
const D = __DATA__, $ = s => document.querySelector(s), cv = $('#c'), X = cv.getContext('2d'), tip = $('#tip');
// node kinds: color, shape, legend; edge kinds: color, arrowhead
const NK = {file: ['#64748b', 'sq', 'file'], cmd: ['#2563eb', 'sq', 'command'], ext: ['#78716c', 'sq', 'external CLI'], slash: ['#ea580c', 'tri', 'slash command'],
  fn: ['#64748b', 'ci', 'function'], phase: ['#ea580c', 'pill', 'workflow phase'], call: ['#0d9488', 'hex', 'agent() call'], section: ['#a8a29e', 'ci', 'section'],
  step: ['#16a34a', 'ci', 'step'], row: ['#15803d', 'pill', 'table row'], event: ['#7c3aed', 'star', 'event / hook'], state: ['#b45309', 'oct', 'state'],
  config: ['#0891b2', 'x', 'config key'], outcome: ['#9ca3af', 'ring', 'outcome'], decision: ['#d97706', 'dia', 'decision'], parallel: ['#8b5cf6', 'para', 'parallel'],
  wait: ['#ca8a04', 'itri', 'wait / gate'], timer: ['#0e7490', 'ring', 'timer'], retry: ['#db2777', 'tri', 'retry'], error: ['#dc2626', 'x', 'error path'],
  lock: ['#57534e', 'sq', 'lock'], exit: ['#991b1b', 'oct', 'exit'], human: ['#e11d48', 'star', 'human']};
const EK = {calls: ['#94a3b8', 'tri'], runs: ['#2563eb', 'tri'], impl: ['#0ea5e9', 'open'], next: ['#16a34a', 'tri'], spawns: ['#0d9488', 'dbl'], loads: ['#a3a3a3', 'open'],
  routes: ['#2563eb', 'tri'], branch: ['#d97706', 'dia'], loop: ['#db2777', 'tri'], writes: ['#b45309', 'dot'], reads: ['#b45309', 'open'], triggers: ['#7c3aed', 'tri'], has: ['#94a3b8', 'none']};
const N = D.nodes.map((a, i) => ({i, l: a[0], k: a[1], g: a[2], ln: a[3], d: a[4], id: a[5], out: [], in: [], x: 0, y: 0, vx: 0, vy: 0, fx: null}));
const E = D.edges.map((a, i) => ({i, s: a[0], t: a[1], k: a[2], l: a[3], b: a[4], back: a[5]}));
E.forEach(e => { N[e.s].out.push(e); N[e.t].in.push(e) });
N.forEach(n => n.r = n.k === 'file' ? 9 : 3 + Math.min(6, Math.sqrt(n.out.length + n.in.length) * .8));
const G = D.files.map((f, i) => ({i, id: f.id, kind: f.kind, m: N.filter(n => n.g === i), x: 0, y: 0}));
G.forEach(g => g.fn = g.m.find(n => n.k === 'file'));
const bad = new Map(); D.issues.forEach(it => it.node != null && bad.set(it.node, it.text));
const nkOn = Object.fromEntries(Object.keys(NK).map(k => [k, true])), ekOn = Object.fromEntries(Object.keys(EK).map(k => [k, true]));
const coll = new Set(), choice = {};
let VN = [], VE = [], focus = null, fE = null, sel = null, trSteps = null, hover = null;
// initial layout: files on a spiral by size, parts scattered inside
let ang = 0, rad = 0;
[...G].sort((a, b) => b.m.length - a.m.length).forEach(g => { const R = 10 * Math.sqrt(g.m.length) + 30; rad += R * .55; ang += 2.4; g.x = Math.cos(ang) * rad; g.y = Math.sin(ang) * rad;
  g.m.forEach(n => { const a = Math.random() * 6.28, d = Math.random() * R * .6; n.x = g.x + Math.cos(a) * d; n.y = g.y + Math.sin(a) * d }) });
const rep = n => coll.has(n.g) && G[n.g].fn ? G[n.g].fn : n;
const vis = n => nkOn[n.k] && (!coll.has(n.g) || n.k === 'file');
function rebuild() {
  VN = N.filter(vis); const seen = new Set(); VE = [];
  for (const e of E) { if (!ekOn[e.k]) continue; const a = rep(N[e.s]), b = rep(N[e.t]); if (!vis(a) || !vis(b) || (a === b && e.s !== e.t)) continue;
    const key = a.i + ',' + b.i + e.k; if (seen.has(key)) continue; seen.add(key); VE.push({a, b, e}) }
  $('#cnt').textContent = `${VN.length} nodes · ${VE.length} edges · ${D.counts.cycles} loops`; heat(.6)
}
// force simulation: grid-binned repulsion + collision, link springs, gravity to the file's centroid, file-vs-file repulsion
let alpha = 1;
const heat = a => { alpha = Math.max(alpha, a); if (!raf) raf = requestAnimationFrame(loop) };
function tick() {
  for (const g of G) { g.cx = g.cy = g.c = 0 }
  for (const n of VN) { const g = G[n.g]; g.cx += n.x; g.cy += n.y; g.c++ }
  for (const g of G) if (g.c) { g.cx /= g.c; g.cy /= g.c; g.R = 9 * Math.sqrt(g.c) + 18; g.sx = g.sy = 0 }
  const C = 46, grid = new Map(), key = (a, b) => a * 73856093 ^ b * 19349663;
  for (const n of VN) { const k = key(Math.floor(n.x / C), Math.floor(n.y / C)); (grid.get(k) || grid.set(k, []).get(k)).push(n) }
  for (const n of VN) { const gx = Math.floor(n.x / C), gy = Math.floor(n.y / C);
    for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) for (const m of grid.get(key(gx + i, gy + j)) || []) {
      if (m.i <= n.i) continue; let dx = n.x - m.x, dy = n.y - m.y, d2 = dx * dx + dy * dy || .01, d = Math.sqrt(d2);
      let f = (n.g === m.g ? 30 : 120) / d2 * alpha; const mn = n.r + m.r + 3; if (d < mn) f += (mn - d) / d * .4;
      n.vx += dx * f; n.vy += dy * f; m.vx -= dx * f; m.vy -= dy * f } }
  for (const {a, b} of VE) { if (a === b) continue; const same = a.g === b.g, L = same ? 20 : 180, s = (same ? .1 : .0015) * alpha;
    const dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy) || 1, f = (d - L) / d * s; a.vx += dx * f; a.vy += dy * f; b.vx -= dx * f; b.vy -= dy * f }
  const GL = G.filter(g => g.c);
  for (let i = 0; i < GL.length; i++) for (let j = i + 1; j < GL.length; j++) { const p = GL[i], q = GL[j], dx = p.cx - q.cx, dy = p.cy - q.cy, d = Math.hypot(dx, dy) || 1, m = p.R + q.R + 30;
    if (d < m) { const f = (m - d) / d * (.03 + .25 * alpha); p.sx += dx * f; p.sy += dy * f; q.sx -= dx * f; q.sy -= dy * f } }
  for (const g of GL) { g.sx -= g.cx * (.003 + .004 * alpha); g.sy -= g.cy * (.003 + .004 * alpha) }
  for (const n of VN) { const g = G[n.g]; n.vx += (g.cx - n.x) * (.01 + .04 * alpha) + g.sx; n.vy += (g.cy - n.y) * (.01 + .04 * alpha) + g.sy;
    if (n.fx != null) { n.x = n.fx; n.y = n.fy; n.vx = n.vy = 0; continue } n.vx *= .55; n.vy *= .55; n.x += n.vx; n.y += n.vy }
  alpha *= .99
}
// view
let tx = innerWidth / 2, ty = innerHeight / 2, sc = .3, raf = 0, dpr = 1;
const size = () => { dpr = devicePixelRatio || 1; cv.width = innerWidth * dpr; cv.height = innerHeight * dpr; draw() };
const w2s = (x, y) => [x * sc + tx, y * sc + ty], s2w = (x, y) => [(x - tx) / sc, (y - ty) / sc];
function hull(P) {
  P = P.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]); if (P.length < 3) return P;
  const cr = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]), lo = [], up = [];
  for (const p of P) { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p) }
  for (const p of P.reverse()) { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p) }
  return lo.slice(0, -1).concat(up.slice(0, -1))
}
function shape(s, x, y, r) {
  X.beginPath();
  const poly = pts => { pts.forEach(([a, b], i) => i ? X.lineTo(x + a * r, y + b * r) : X.moveTo(x + a * r, y + b * r)); X.closePath() };
  if (s === 'ci' || s === 'ring') X.arc(x, y, r, 0, 6.283);
  else if (s === 'sq') X.rect(x - r, y - r, 2 * r, 2 * r);
  else if (s === 'dia') poly([[0, -1.4], [1.4, 0], [0, 1.4], [-1.4, 0]]);
  else if (s === 'tri') poly([[0, -1.3], [1.2, .9], [-1.2, .9]]);
  else if (s === 'itri') poly([[0, 1.3], [1.2, -.9], [-1.2, -.9]]);
  else if (s === 'hex') poly([[1, 0], [.5, .87], [-.5, .87], [-1, 0], [-.5, -.87], [.5, -.87]]);
  else if (s === 'oct') poly([[.4, -1], [1, -.4], [1, .4], [.4, 1], [-.4, 1], [-1, .4], [-1, -.4], [-.4, -1]]);
  else if (s === 'pill') X.roundRect ? X.roundRect(x - 1.6 * r, y - r, 3.2 * r, 2 * r, r) : X.rect(x - 1.6 * r, y - r, 3.2 * r, 2 * r);
  else if (s === 'para') poly([[-.6, -1], [1.4, -1], [.6, 1], [-1.4, 1]]);
  else if (s === 'star') poly([...Array(10)].map((_, i) => { const a = i * .628 - 1.571, q = i % 2 ? .45 : 1.3; return [Math.cos(a) * q, Math.sin(a) * q] }));
  else if (s === 'x') poly([[-1, -.4], [-.4, -1], [0, -.6], [.4, -1], [1, -.4], [.6, 0], [1, .4], [.4, 1], [0, .6], [-.4, 1], [-1, .4], [-.6, 0]]);
}
function curve(a, b, back) {
  const dx = b.x - a.x, dy = b.y - a.y, c = back ? .35 : .1;
  return [a.x, a.y, (a.x + b.x) / 2 - dy * c, (a.y + b.y) / 2 + dx * c, b.x, b.y]
}
function head(kind, x, y, ang, s) {
  const h = EK[kind] ? EK[kind][1] : 'tri'; if (h === 'none') return;
  X.save(); X.translate(x, y); X.rotate(ang); X.beginPath();
  if (h === 'dot') X.arc(-s * .6, 0, s * .45, 0, 6.283);
  else if (h === 'dia') { X.moveTo(0, 0); X.lineTo(-s * .7, -s * .4); X.lineTo(-s * 1.4, 0); X.lineTo(-s * .7, s * .4); X.closePath() }
  else { X.moveTo(0, 0); X.lineTo(-s, -s * .5); X.lineTo(-s, s * .5); X.closePath(); if (h === 'dbl') { X.moveTo(-s * .7, 0); X.lineTo(-s * 1.7, -s * .5); X.lineTo(-s * 1.7, s * .5); X.closePath() } }
  if (h === 'open') { X.stroke() } else X.fill(); X.restore()
}
function draw() {
  raf = 0; const bg = getComputedStyle(document.body).backgroundColor, fg = getComputedStyle(document.body).color, hi = getComputedStyle(document.documentElement).getPropertyValue('--hi');
  X.setTransform(dpr, 0, 0, dpr, 0, 0); X.fillStyle = bg; X.fillRect(0, 0, innerWidth, innerHeight); X.setTransform(dpr * sc, 0, 0, dpr * sc, dpr * tx, dpr * ty);
  const lw = 1 / sc, F = n => !focus || focus.has(n);
  X.lineJoin = 'round';
  for (const g of G) { const m = g.m.filter(n => vis(n)); if (!m.length) continue;
    const h = hull(m.map(n => [n.x, n.y])), col = g.kind === 'pseudo' ? '#94a3b8' : (NK[{skill: 'step', agent: 'call', workflow: 'phase', script: 'cmd'}[g.kind]] || NK.section)[0];
    X.globalAlpha = focus && !m.some(F) ? .03 : .09; X.fillStyle = X.strokeStyle = col; X.lineWidth = 26; X.beginPath();
    h.forEach((p, i) => i ? X.lineTo(p[0], p[1]) : X.moveTo(p[0], p[1])); X.closePath(); X.fill(); X.stroke();
    X.globalAlpha = focus && !m.some(F) ? .2 : .85; X.fillStyle = fg; X.font = `600 ${Math.max(11, 12 / sc * .6)}px system-ui`; X.textAlign = 'center';
    X.fillText(g.id.split('/').slice(-2).join('/') + (coll.has(g.i) ? ' ⊕' : ''), m.reduce((s, n) => s + n.x, 0) / m.length, Math.min(...m.map(n => n.y)) - 16) }
  const arrows = sc > .7, lab = [];
  for (const v of VE) { const {a, b, e} = v, on = fE ? fE.has(v) : !focus || (focus.has(a) && focus.has(b));
    X.globalAlpha = on ? (fE ? .95 : .35) : .04; X.strokeStyle = X.fillStyle = fE && on ? hi : EK[e.k][0]; X.lineWidth = (fE && on ? 2 : e.k === 'loop' || e.back ? 1.3 : .8) * lw;
    X.setLineDash(e.back || e.k === 'loop' ? [5 * lw, 3 * lw] : []); X.beginPath();
    let mx, my, ang;
    if (a === b) { X.arc(a.x + a.r, a.y - a.r, a.r + 4, 0, 6.283); mx = a.x + a.r; my = a.y - 2 * a.r - 6; ang = 0 }
    else { const c = curve(a, b, e.back || e.k === 'loop'); X.moveTo(c[0], c[1]); X.quadraticCurveTo(c[2], c[3], c[4], c[5]);
      mx = (c[0] + 2 * c[2] + c[4]) / 4; my = (c[1] + 2 * c[3] + c[5]) / 4; ang = Math.atan2(c[5] - c[3], c[4] - c[2]) }
    X.stroke(); X.setLineDash([]);
    if (a !== b && (arrows || (fE && on))) { const d = b.r + 1; head(e.k, b.x - Math.cos(ang) * d, b.y - Math.sin(ang) * d, ang, 6 * lw) }
    if ((e.k === 'loop' && on && sc > .5) || ((e.back || e.k === 'loop') && fE && on)) lab.push([mx, my, '↻' + (e.b ? ' ' + e.b : ''), '#db2777']);
    if (fE && on && fE.size < 300) lab.push([mx, my + 11 * lw, e.k + (e.l ? ' · ' + e.l : ''), fg]) }
  X.globalAlpha = 1;
  for (const n of VN) { const [col, s] = NK[n.k] || NK.fn; X.globalAlpha = F(n) ? 1 : .1; shape(s, n.x, n.y, n.r);
    X.fillStyle = s === 'ring' ? bg : col; X.fill(); X.strokeStyle = bad.has(n.i) ? '#dc2626' : n === sel ? hi : col; X.lineWidth = (bad.has(n.i) || n === sel ? 2.4 : 1) * lw; X.stroke();
    if (n.fx != null) { X.fillStyle = fg; X.fillRect(n.x - 1.5 * lw, n.y - n.r - 4 * lw, 3 * lw, 3 * lw) } }
  X.font = `${11 * lw}px system-ui`; X.textAlign = 'left';
  for (const n of VN) { const show = n === sel || n === hover || (focus ? focus.has(n) && (focus.size < 160 || sc > .6) : sc * n.r > 4.5 || (sc > .45 && /slash|phase|event|human|row|file/.test(n.k)));
    if (!show) continue; X.globalAlpha = F(n) ? 1 : .2; X.fillStyle = fg; X.fillText(n.l.slice(0, 48), n.x + n.r + 3 * lw, n.y + 4 * lw) }
  for (const [x, y, t, c] of lab) { X.globalAlpha = 1; X.lineWidth = 3 * lw; X.strokeStyle = bg; X.strokeText(t.slice(0, 60), x, y); X.fillStyle = c; X.fillText(t.slice(0, 60), x, y) }
  X.globalAlpha = 1
}
function loop() { raf = 0; for (let i = 0; i < 2 && alpha > .02; i++) tick(); draw(); if (alpha > .02 || drag) raf = requestAnimationFrame(loop) }
function fit() { const xs = VN.map(n => n.x), ys = VN.map(n => n.y), x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
  sc = Math.min((innerWidth - 40) / (x1 - x0 + 80), (innerHeight - 130) / (y1 - y0 + 80)); tx = innerWidth / 2 - (x0 + x1) / 2 * sc; ty = 110 + (innerHeight - 110) / 2 - (y0 + y1) / 2 * sc; draw() }
const center = n => { tx = innerWidth / 2 - n.x * sc; ty = innerHeight / 2 - n.y * sc; draw() };
// focus: neighbourhood (both directions, depth slider), a cycle, a search, a trace
function hood(n) {
  const d = +$('#dep').value, f = new Set([n]), es = new Set(); let fr = [n];
  for (let k = 0; k < d; k++) { const nx = []; for (const v of VE) for (const [p, q] of [[v.a, v.b], [v.b, v.a]]) if (fr.includes(p)) { es.add(v); if (!f.has(q)) { f.add(q); nx.push(q) } } fr = nx }
  focus = f; fE = es; draw()
}
function setFocus(nodes) { focus = new Set(nodes.map(rep)); fE = new Set(VE.filter(v => focus.has(v.a) && focus.has(v.b))); draw() }
function pick(n) { sel = n; trSteps = null; n ? hood(n) : (focus = fE = null, draw()) }
// trace: ordered walk from an entry (agent, event, row, slash command ...); decisions follow the chosen outcome; loops shown once
const PRI = {routes: 0, runs: 1, impl: 1, spawns: 2, branch: 3, triggers: 4, has: 5, calls: 6, writes: 7, loads: 8, next: 9, loop: 10};
function trace(start) {
  const steps = [], seen = new Set(), maxD = +$('#dep').value + 5;
  const COST = {calls: 2, has: 2, loads: 2, writes: 2};
  (function go(n, dep, via) {
    if (steps.length > 400) return; seen.add(n); steps.push({n, dep, via}); if (dep >= maxD) return;
    let outs = n.out.filter(e => PRI[e.k] != null).sort((a, b) => PRI[a.k] - PRI[b.k] || N[a.t].ln - N[b.t].ln);
    const br = outs.filter(e => e.k === 'branch');
    if (n.k === 'decision' && br.length) outs = outs.filter(e => e.k !== 'branch').concat([br[Math.min(choice[n.i] || 0, br.length - 1)]]);
    for (const e of outs) { const t = N[e.t]; if (seen.has(t)) { if (e.back || e.k === 'loop') steps.push({n: t, dep: dep + 1, via: e, loop: 1}); continue } go(t, dep + (COST[e.k] || 1), e) }
  })(start, 0, null);
  trSteps = steps; sel = start; setFocus(steps.map(s => s.n)); fE = new Set(VE.filter(v => steps.some(s => s.via && rep(N[s.via.s]) === v.a && rep(N[s.via.t]) === v.b))); draw(); panel('trace')
}
const fl = n => `${D.files[n.g].id}${n.ln ? ':' + n.ln : ''}`;
function panel(tab) {
  $('#pan').classList.add('on'); $('#ptabs').innerHTML = ''; const body = $('#pbody'); body.innerHTML = '';
  for (const t of ['trace', 'loops', 'issues']) { const b = document.createElement('span'); b.className = 'p' + (t === tab ? '' : ' off'); b.textContent = t; b.onclick = () => panel(t); $('#ptabs').append(b) }
  const row = (html, cls, fn) => { const d = document.createElement('div'); d.className = 'st ' + (cls || ''); d.innerHTML = html; d.onclick = fn; body.append(d); return d };
  const esc = s => String(s).replace(/[&<>]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;'})[c]);
  if (tab === 'trace') {
    if (!trSteps) return row('pick an entry in "trace from…", or select a node and press "trace selected"');
    trSteps.forEach((s, i) => { const n = s.n, d = row(`<span style="padding-left:${s.dep * 8}px"></span><b>${i + 1}</b> ${s.loop ? '↻ back to' : ''} <i style="color:${NK[n.k][0]}">${n.k}</i> ${esc(n.l)}${s.via && s.via.l && !s.loop ? ` <small>(${esc(s.via.k)}: ${esc(s.via.l.slice(0, 50))})</small>` : ''} <small>${esc(fl(n))}</small>`,
      bad.has(n.i) ? 'bad' : '', () => { center(n); sel = n; draw() });
      const br = n.out.filter(e => e.k === 'branch');
      if (n.k === 'decision' && br.length > 1 && !s.loop) { const se = document.createElement('select'); br.forEach((e, j) => se.add(new Option(`${e.l} → ${N[e.t].l}`.slice(0, 60), j)));
        se.value = choice[n.i] || 0; se.onclick = ev => ev.stopPropagation(); se.onchange = () => { choice[n.i] = +se.value; trace(trSteps[0].n) }; d.append(se) } })
  } else if (tab === 'loops') D.cycles.forEach(c => row(`<i style="color:${(NK[c.kind] || ['#db2777'])[0]}">${c.kind}</i> ${esc(c.label)} <small>${c.nodes.length} nodes</small>`, '', () => { sel = null; setFocus(c.nodes.map(i => N[i])); center(N[c.nodes[0]]) }));
  else D.issues.forEach(it => row(`<b>${esc(it.code)}</b> ${esc(it.text)}`, 'bad', () => { if (it.node != null) { const n = rep(N[it.node]); pick(n); center(n) } }))
}
// chips: node kinds and edge kinds (toggle), with counts
const chips = $('#chips');
for (const [map, on, key] of [[NK, nkOn, 'k'], [EK, ekOn, 'k']]) for (const k in map) { const c = (map === NK ? N : E).filter(x => x.k === k).length; if (!c) continue;
  const b = document.createElement('span'); b.className = 'p'; b.innerHTML = `<i style="background:${map[k][0]};${map === EK ? 'height:3px' : ''}"></i>${map === NK ? map[k][2] : '→ ' + k} ${c}`;
  b.title = map === NK ? 'node kind: click to hide / show' : 'edge kind (arrowhead: ' + map[k][1] + '): click to hide / show';
  b.onclick = () => { on[k] = !on[k]; b.classList.toggle('off'); rebuild() }; chips.append(b) }
$('#iss').textContent = `${D.counts.issues} unknown`; $('#iss').title = 'unresolved refs, unhandled outcomes, loops without a bound, dead ends, lint problems';
if (D.counts.issues) $('#iss').classList.add('bad'); $('#iss').onclick = () => panel('issues');
$('#pt').onclick = () => $('#pan').classList.contains('on') ? $('#pan').classList.remove('on') : panel(trSteps ? 'trace' : 'loops');
const tsel = $('#tr'), ent = N.filter(n => /slash|event|human|timer|row/.test(n.k) || (n.k === 'file' && /^agents\/|orchestrate\/SKILL/.test(n.id)));
ent.sort((a, b) => a.k.localeCompare(b.k) || a.l.localeCompare(b.l)).forEach(n => tsel.add(new Option(`${n.k === 'file' ? (n.id.startsWith('agents/') ? 'agent' : 'coordinator') : n.k}: ${n.l}`.slice(0, 70), n.i)));
tsel.onchange = () => tsel.value && trace(N[+tsel.value]);
$('#trs').onclick = () => sel && trace(sel); $('#fit').onclick = fit; $('#dep').oninput = () => trSteps ? trace(trSteps[0].n) : sel && hood(sel);
$('#q').oninput = () => { const q = $('#q').value.trim().toLowerCase(); sel = null; trSteps = null; if (!q) { focus = fE = null; return draw() }
  focus = new Set(VN.filter(n => (n.l + ' ' + n.id + ' ' + n.d).toLowerCase().includes(q))); fE = null; draw() };
$('#q').onkeydown = e => { if (e.key === 'Enter' && focus && focus.size) { const n = [...focus][0]; pick(n); center(n) } };
// pointer: pan, drag a node (pins it; right-click unpins), click selects, double-click collapses / expands its file
let drag = null;
const hit = (sx, sy) => { const [x, y] = s2w(sx, sy); let best = null, bd = 1e9; for (const n of VN) { const d = Math.hypot(n.x - x, n.y - y); if (d < n.r + 5 / sc && d < bd) { bd = d; best = n } } return best };
cv.addEventListener('pointerdown', e => { const n = hit(e.clientX, e.clientY); drag = {n, x: e.clientX, y: e.clientY, tx, ty, moved: false}; cv.setPointerCapture(e.pointerId) });
cv.addEventListener('pointermove', e => {
  if (!drag) { const n = hit(e.clientX, e.clientY); if (n !== hover) { hover = n; draw() }
    if (n) { tip.style.display = 'block'; tip.style.left = Math.min(e.clientX + 14, innerWidth - 430) + 'px'; tip.style.top = e.clientY + 14 + 'px';
      tip.textContent = `${n.l}  [${NK[n.k][2]}]\n${fl(n)}${n.d ? '\n' + n.d : ''}${bad.has(n.i) ? '\n⚠ ' + bad.get(n.i) : ''}\n${n.out.length} out · ${n.in.length} in` } else tip.style.display = 'none'; return }
  const dx = e.clientX - drag.x, dy = e.clientY - drag.y; if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true; if (!drag.moved) return;
  if (drag.n) { const [x, y] = s2w(e.clientX, e.clientY); drag.n.fx = x; drag.n.fy = y; heat(.3) } else { tx = drag.tx + dx; ty = drag.ty + dy; draw() } });
cv.addEventListener('pointerup', () => { if (drag && !drag.moved) pick(drag.n && drag.n !== sel ? drag.n : null); drag = null });
cv.addEventListener('dblclick', e => { const n = hit(e.clientX, e.clientY); if (!n || !G[n.g].fn) return; coll.has(n.g) ? coll.delete(n.g) : coll.add(n.g); sel = null; focus = fE = null; rebuild() });
cv.addEventListener('contextmenu', e => { const n = hit(e.clientX, e.clientY); if (n) { e.preventDefault(); n.fx = n.fy = null; heat(.2) } });
cv.addEventListener('wheel', e => { e.preventDefault(); const f = Math.exp(-e.deltaY * .0015); tx = e.clientX - (e.clientX - tx) * f; ty = e.clientY - (e.clientY - ty) * f; sc *= f; draw() }, {passive: false});
addEventListener('keydown', e => { if (e.key === 'Escape') { sel = null; trSteps = null; focus = fE = null; $('#q').value = ''; draw() } });
addEventListener('resize', size);
rebuild(); for (let i = 0; i < 420; i++) tick(); size(); fit(); heat(.05);
window.KF = {N, G, trace, pick, center, hood, setFocus, fit, panel, coll, rebuild, get sc() { return sc }, set sc(v) { sc = v }};
</script></body></html>
'''
