"""localbench.py: replay recorded real agent steps against a local model and score them (crafty.ps1 local bench).
  build  [-Set s] [-Roles r1,r2] [-N 4] [-Since yyyy-mm-dd] [-Transcripts dir] [-Force | -Add]   replay set from recorded steps, per
         role; an existing set: -Force empties it (results of a changed task are never reused: meta.promptSha), -Add tops each
         run unit up to -N with transcripts the set lacks (a unit with none: "no history")
         -Degrade <set> -Set <new> [-N 3]: a bad-prompt set: per role -N tasks of <set> with their prompt degraded mechanically (modes
         vague: steps cut to 400 chars · noformat: no schema block, no JSON-only line · noisy: numbered steps dropped, log noise added);
         cloud.json / schema.json kept; the answer shape reaches the model only through the run's system contract
  coverage [-Set s,s2] [-Min 3] [-Json]   bench tasks per models.runOn unit and set; a unit under -Min: gap
  runon  [-Write <kit.local.json | kit.example.json>] [-Json]   every run unit (kitbag.py runon_units), its setting and source;
         -Write: missing units added as cloud, models.local.use folded in (its units local) and dropped, unknown units listed
  report ... -WriteRunonEvidence   + each unit's accept rate on this set into kit.local.json models.runOn.<unit>.evidence.<set>
         (never flips its cloud | local)
  run    -Model m [-Set s] [-Ids a,b] [-Roles ..] [-TimeoutSec 600] [-Force]   resumable: skips ids that
         ran (rc 0) on the same prompt + contract; -Ids re-runs them; claude --tools= (none); a ~contract model appends the answer's shape
         (as StructuredOutput's schema is in production) as a system prompt file; loop 1 measured it: the 35B reasoned in the reply, no gain
  score  -Model m [-Set s]        strict / repairable / lenient JSON, schema, outcome per id (fields, list items, text facts)
  judge: score -Judge <model> (or models.local.bench.judge; none: word recall) = free text judged by a cheap claude model, one call per
         text pair, "same facts as the reference, nothing contradicted or invented?"; ids, URLs, counts, statuses, enums stay strict;
         verdict + reason cached in <set>/<model>/judge.json (audit: score -Judge x -Json prints none; read the file)
  contract: -Model <m>~contract runs with the system contract (reply-shape text as a system prompt file), stored apart; a plain -Model runs bare
  report -Model m [-Set s] [-Json]   accept rate over the ids that ran, infra fails apart, median / p90 s per role, cloud tier
  diff   -Model m -Against m2 [-Set s] [-Json]   per role delta and the ids that flip
A role: <agentType>:<step label> (workflow steps, e.g. checky:close, kitty:learn) or <agentType> (ad hoc agents, e.g. watchy).
A task: the step's prompt, every tool call it made with its output (cut), then "answer from these outputs" + the JSON schema
derived from the answer the cloud run returned (cloud.json). Nothing runs tools: run passes --tools "" (claude); a reply that
writes a tool call as text scores tool-call-text. Store: <state>/local-bench/<set>/tasks/<id>/ (set) and
<state>/local-bench/<set>/<model>/ (runs/<id>.json, results.json, score.json); re-running ids overwrites only those ids.
Transcripts: Claude Code subagent transcripts (the transcript adapter's root, */subagents/**). Exit codes: 0 ok · 1 nothing to do / missing set · 2 usage.
Sections: L45 store · L79 runon · L214 reply parsing · L259 outcome · L411 build · L562 contract · L644 run
"""
import argparse, datetime, hashlib, json, os, re, shutil, signal, statistics, subprocess, sys, time
import os.path as osp
sys.path.insert(0, osp.join(osp.dirname(osp.dirname(osp.dirname(osp.abspath(__file__)))), 'bossy'))   # <kit>/skills/bossy
from kitbag import kit_path, local_config, local_config_path, runon_units, runon_unit_of, KIT_DIR  # noqa: E402

CUT_RES, CUT_CMD, CUT_ALL = 2500, 1500, 60000
DEFAULT_ROLES = ['steppy', 'checky:close', 'checky:hold', 'kitty:learn', 'kitty:track', 'devy:track', 'devy:followups', 'checky:audit',
                 'checky:verify', 'checky:test', 'devy:build', 'devy:fix', 'watchy', 'vidy', 'revy', 'briefy', 'rechy', 'opsy', 'checky@lead', 'kitty@']
PREFIX = ('SHADOW TASK. No tools exist in this session: never call a tool, never search for one; every command below has already run.\n'
          'Below: the instructions a workflow step gave an agent, then every tool call that agent made, in order, with its output '
          '(long outputs cut). Your job: write the final answer that step returns, judged from those outputs, as ONE JSON object '
          'matching the schema at the end. Reply with the JSON object only: no prose, no code fence.\n\n=== STEP INSTRUCTIONS (already carried out) ===\n')


# ---- store: models.local config, <state>/local-bench paths, JSON files
def cfg():
    return ((local_config(KIT_DIR, 'kit.local.json').get('models') or {}).get('local') or {})


def bench_dir(st, model=None, create=False):
    p = osp.join(kit_path('local-bench', create=create), re.sub(r'[^\w.-]', '_', st))
    if model:
        p = osp.join(p, re.sub(r'[^\w.-]', '_', model))
    if create:
        os.makedirs(p, exist_ok=True)
    return p


def rjson(p, default=None):
    try:
        with open(p, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def sha(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()[:16]


def wjson(p, v):
    os.makedirs(osp.dirname(p), exist_ok=True)
    tmp = p + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(v, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, p)


# ---- runon: models.runOn units, edited in place in a config file (its layout kept: only the runOn object is rewritten)
def bench_unit(meta, units):
    """The run unit of a bench task (its role and step label); None: no unit (an ad hoc kind the manifest lacks)."""
    role, label = str(meta.get('role') or ''), str(meta.get('label') or '')
    t = re.split(r'[:@]', role)[0]
    if '@' in role:
        return role if role in units else None
    if ':' in role or t == 'steppy':
        lab = label if t == 'steppy' else role.split(':', 1)[1]
        for u in (runon_unit_of(t, lab, units), runon_unit_of('steppy', lab, units)):   # a step whose steppy was unknown ran as another type
            if u in units:
                return u
        return None
    return t if t in units else None


def members(text, start):
    """{key: (key start, value start, value end)} of the JSON object whose { is at text[start] (its own keys only)."""
    dec, gap, i, out = json.JSONDecoder(strict=False), re.compile(r'[\s,]*'), start + 1, {}
    while True:
        i = gap.match(text, i).end()
        if text[i] == '}':
            return out
        k, j = dec.raw_decode(text, i)
        vs = re.compile(r'\s*:\s*').match(text, j).end()
        _, ve = dec.raw_decode(text, vs)
        out[k], i = (i, vs, ve), ve


def runon_text(ro, ind, nl):
    parts, line, out = [f'{json.dumps(u)}: {json.dumps(v, ensure_ascii=False, separators=(", ", ": "))}' for u, v in ro.items()], '', []
    for p in parts:
        if line and len(line) + len(p) > 150:
            out.append(line.rstrip(', '))
            line = ''
        line += p + ', '
    out.append(line.rstrip(', '))
    return '"runOn": {' + nl + (',' + nl).join(ind + x for x in out) + ' }'


def write_runon(path, ro, drop_use=False):
    """Replace (or add) models.runOn in a config file; drop_use: remove models.local.use. The rest of the file is untouched."""
    with open(path, 'rb') as fh:
        bom = fh.read(3) == b'\xef\xbb\xbf'
    with open(path, encoding='utf-8-sig', newline='') as fh:
        text = fh.read()
    nl = '\r\n' if '\r\n' in text else '\n'   # the file's own line ends and BOM are kept
    top = lambda: members(text, text.index('{'))
    if 'models' not in top():
        text = text[:text.rindex('}')].rstrip() + f',{nl} "models": {{}} }}{nl}'
    mo = top()['models'][1]
    if drop_use:
        lm = members(text, mo).get('local')
        us = lm and members(text, lm[1]).get('use')
        if us:
            after = re.compile(r'\s*,\s*').match(text, us[2])
            text = text[:us[0]] + text[after.end():] if after else re.sub(r',\s*$', '', text[:us[0]]) + text[us[2]:]
    mm = members(text, mo)
    ks = top()['models'][0]
    new = runon_text(ro, ' ' * (len(text[:ks]) - len(text[:ks].rstrip(' ')) + 2), nl)
    if 'runOn' in mm:
        text = text[:mm['runOn'][0]] + new + text[mm['runOn'][2]:]
    elif 'mode' in mm:   # next to the override that wins over it
        text = text[:mm['mode'][2]] + ', ' + new + text[mm['mode'][2]:]
    else:
        text = text[:mo + 1] + ' ' + new + (',' if mm else ' ') + text[mo + 1:]
    json.loads(text)   # never leave a broken config
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8', newline='') as fh:
        fh.write(('\ufeff' if bom else '') + text)
    os.replace(tmp, path)


def cmd_runon(a):
    units = runon_units()
    src = a.write or local_config_path(KIT_DIR, 'kit.local.json')
    conf = rjson(src, {}) if src else {}
    mo = conf.get('models') or {}
    have, use = mo.get('runOn') or {}, ((mo.get('local') or {}).get('use')) or []
    unknown = [u for u in have if u not in units]
    if a.write:
        ro = {u: have.get(u, 'cloud') for u in units}
        for w in use:   # the retired list: '<type>' = all its units, '<type>:<label prefix>' = its steps
            for u in units:
                if not units[u]['boot'] and (u == w or u.startswith(w + ':') or u.startswith(w + '@') or (':' in w and u.startswith(w))):
                    ro[u] = {**ro[u], 'on': 'local'} if isinstance(ro[u], dict) else 'local'
        ro.update({u: have[u] for u in unknown})   # never dropped silently: listed below, the owner removes them
        write_runon(a.write, ro, drop_use=bool(use))
        have = ro
    on = lambda v: (v.get('on') if isinstance(v, dict) else v) or 'cloud'
    rows = [{'unit': u, 'on': on(have.get(u, 'cloud')), 'set': u in have, 'by': units[u]['by'], 'boot': units[u]['boot']} for u in units]
    if a.json:
        print(json.dumps({'file': src, 'units': rows, 'unknown': unknown, 'use': use})); return 0
    nl = sum(r['on'] == 'local' for r in rows)
    print(f'{len(rows)} run units in {src or "(no kit.local.json)"}: {nl} local, {len(rows) - nl} cloud, {sum(not r["set"] for r in rows)} not set (cloud)'
          + (f'; models.local.use folded in: {", ".join(use)}' if a.write and use else ''))
    for r in rows:
        print(f'  {r["unit"]:28} {r["on"]:6} {r["by"]}{" (before CONFIG: always cloud)" if r["boot"] else ""}{"" if r["set"] else " · not set"}')
    for u in unknown:
        print(f'  UNKNOWN {u}: no such run unit (a typo or a retired step): remove it')
    if use and not a.write:
        print('  models.local.use is retired: crafty.ps1 local bench runon -Write <kit.local.json> folds it into models.runOn')
    return 1 if unknown else 0


def set_names(a):
    root = kit_path('local-bench')
    return a.sets or (sorted(d for d in os.listdir(root) if osp.isdir(osp.join(root, d, 'tasks'))) if osp.isdir(root) else [])


def cmd_coverage(a):
    units, sets = runon_units(), set_names(a)
    cnt, unmapped = {u: {s: 0 for s in sets} for u in units}, {}
    for s in sets:
        td = osp.join(bench_dir(s), 'tasks')
        for tid in sorted(os.listdir(td)) if osp.isdir(td) else []:
            m = rjson(osp.join(td, tid, 'meta.json'), {}) or {}
            u = bench_unit(m, units)
            if u:
                cnt[u][s] += 1
            else:
                unmapped[str(m.get('role'))] = unmapped.get(str(m.get('role')), 0) + 1
    rows = [{'unit': u, 'by': units[u]['by'], 'sets': cnt[u], 'total': sum(cnt[u].values()), 'gap': sum(cnt[u].values()) < a.min} for u in units]
    tot = sum(r['total'] for r in rows) + sum(unmapped.values())
    if a.json:
        print(json.dumps({'sets': sets, 'min': a.min, 'tasks': tot, 'units': rows, 'unmapped': unmapped})); return 0
    print(f'coverage: {sum(not r["gap"] for r in rows)}/{len(rows)} units with {a.min}+ tasks · {tot} tasks in {", ".join(sets) or "no set"}'
          + ''.join(f' · {s} {sum(r["sets"][s] for r in rows)}' for s in sets))
    for r in rows:
        print(f'  {r["unit"]:28} {r["total"]:3}  {" ".join(f"{s} {n}" for s, n in r["sets"].items())}{"  GAP" if r["gap"] else ""}')
    if unmapped:
        print('  no unit (an ad hoc kind the manifest lacks): ' + ', '.join(f'{k} {v}' for k, v in sorted(unmapped.items())))
    return 0


# ---- reply parsing: strict (the whole reply), repairable (fence / raw newlines), lenient (the longest object anywhere)
def json_object(t):
    dec, best, span = json.JSONDecoder(strict=False), None, -1
    for m in re.finditer(r'\{', t or ''):
        try:
            v, end = dec.raw_decode(t, m.start())
        except ValueError:
            continue
        if isinstance(v, dict) and v and end - m.start() > span:
            best, span = v, end - m.start()
    return best


def parse_reply(t):
    t = (t or '').strip()
    tool_rx = r'<tool_call>|<function=|"tool_calls"|"name"\s*:\s*"(Bash|PowerShell|Read|Grep|Glob|Edit|Write|ToolSearch|shell)"'
    out = {'strict': None, 'repairable': None, 'lenient': None, 'toolText': bool(re.search(tool_rx, t))}
    try:
        out['strict'] = json.loads(t)
    except ValueError:
        pass
    body = re.sub(r'^```(?:json)?\s*|\s*```$', '', t)
    try:
        out['repairable'] = json.loads(body, strict=False)
    except ValueError:
        pass
    out['lenient'] = json_object(t)
    return out


def valid(v, s):
    t = s.get('type')
    if t == 'object':
        return isinstance(v, dict) and all(k in v for k in s.get('required', [])) and all(valid(v[k], ps) for k, ps in (s.get('properties') or {}).items() if k in v)
    if t == 'array':
        return isinstance(v, list) and all(valid(x, s.get('items') or {}) for x in v)
    return {'string': lambda: isinstance(v, str), 'boolean': lambda: isinstance(v, bool),
            'number': lambda: isinstance(v, (int, float)) and not isinstance(v, bool)}.get(t, lambda: True)()


def derive_schema(v):
    names = {bool: 'boolean', int: 'number', float: 'number', str: 'string', list: 'array', dict: 'object'}
    return {'type': 'object', 'properties': {k: ({'type': names[type(x)]} if type(x) in names else {}) for k, x in v.items()}, 'required': list(v)}   # null: any type


# ---- outcome: the same decision as the cloud answer, by the answer's shape
def facts(text):
    t = str(text)
    fs = set(re.findall(r'https?://\S+?(?=[\s)\]`\'",;]|$)', t)) | set(re.findall(r'\b\d+/\d+\b', t))
    lead = re.match(r'\s*([A-Z][A-Z_]{3,})\b', t)   # a step's status word (RECORDED, READY, OVERFLOW)
    return {f.rstrip('.') for f in fs | ({lead.group(1)} if lead else set())}


ITEM_KEYS = ('id', 'code', 'file', 'path', 'check', 'ref', 'name', 'title', 'key', 'task')


def salient(text):
    """Words that carry the facts: identifiers, paths, numbers, words of 5+ letters."""
    ws = (w.rstrip('.:!-') for w in re.findall(r'[\w./:#!-]+', str(text).lower()))
    return {w for w in ws if len(w) >= 5 or re.search(r'\d|[._/:#!]', w)}


def recall(c, l):
    """Share of the cloud text's facts in the local text; a local text 4x longer than needed is an echo, not an answer."""
    cs, ls = salient(c), salient(l)
    if not cs:
        return float(' '.join(str(c).lower().split()) == ' '.join(str(l).lower().split()))
    return 0.0 if len(ls) > 4 * max(4, len(cs)) else len(cs & ls) / len(cs)


def enum(s):
    """A status, id, path, URL or name (compared exactly): one word; prose is compared by its words, or judged."""
    return len(s) <= 300 and not re.search(r'\s', s.strip())


def item_key(x):
    return next((str(x[k]).strip().lower() for k in ITEM_KEYS if isinstance(x, dict) and x.get(k) not in (None, '')), None)


JUDGE = None   # set by score: (reference, candidate) -> bool | None (None: no verdict, word recall decides)


def text_same(c, l):
    if not str(l or '').strip():
        return False
    r = recall(c, l)
    if r >= 0.8 or JUDGE is None:
        return r >= 0.5
    v = JUDGE(str(c), str(l))
    return r >= 0.5 if v is None else v


def make_judge(model, path):
    """One claude call per text pair (cached by content): the verdict and its reason are kept in judge.json for audit."""
    cache = rjson(path, {}) or {}
    exe = shutil.which('claude') or 'claude'
    ask = ('Reference text:\n<<<\n%s\n>>>\n\nCandidate text:\n<<<\n%s\n>>>\n\nDoes the candidate state the same facts as the reference, with no '
           'contradiction and nothing invented? Wording, order and level of detail may differ; a missing minor detail is fine; a missing or '
           'wrong key fact (id, number, name, decision, state) is not. Reply with ONE JSON object only: {"same": true or false, "reason": "<one sentence>"}')

    def judge(c, l):
        key = sha(c + '\0' + l)
        if key in cache:
            return cache[key]['same']
        try:
            pr = subprocess.run([exe, '-p', '--model', model, '--tools=', '--strict-mcp-config', '--no-session-persistence'], input=ask % (c[:3000], l[:3000]),
                                capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180, env={**os.environ, 'ANTHROPIC_CUSTOM_HEADERS': 'User-Agent: kit-local-bench-judge'})
            d = json_object(pr.stdout)
        except (OSError, subprocess.SubprocessError):
            d = None
        if not isinstance(d, dict) or not isinstance(d.get('same'), bool):
            return None
        cache[key] = {'same': d['same'], 'reason': str(d.get('reason', ''))[:300], 'judge': model, 'ref': c[:240], 'cand': l[:240]}
        wjson(path, cache)
        return d['same']
    return judge


def same_value(c, l):
    """One field: flags, numbers and short strings equal; long text by its salient words; lists item by item; objects field by field."""
    if isinstance(c, bool):
        return l is c or str(l).lower() == str(c).lower()
    if isinstance(c, (int, float)):
        try:
            return not isinstance(l, bool) and float(l) == c
        except (TypeError, ValueError):
            return False
    if c is None:
        return l in (None, '', [], {})
    if isinstance(c, str):
        return c.strip().lower() == str(l if l is not None else '').strip().lower() if enum(c) else text_same(c, l)
    if isinstance(c, dict):
        return isinstance(l, dict) and compare(c, l)[0]
    if isinstance(c, list):
        return list_match(c, l if isinstance(l, list) else [])[0]
    return c == l


def list_match(c, l):
    """Each cloud item finds its local item (same id / file / name..., else most of its words) with the same short fields."""
    if not c:
        return not l, f'items: {len(l)} where none'
    vals = lambda x: ' '.join(map(str, x.values())) if isinstance(x, dict) else str(x)   # an item's words, not its key names
    used, hit = set(), 0
    for ci in c:
        k = item_key(ci)
        if isinstance(ci, dict):
            cands = [j for j, li in enumerate(l) if j not in used and isinstance(li, dict) and (item_key(li) == k if k is not None else recall(vals(ci), vals(li)) >= 0.5)]
            j = max(cands, key=lambda j: sum(same_value(v, l[j].get(f)) for f, v in ci.items()), default=None)   # the closest of equal keys
            ok = j is not None and compare(ci, l[j])[0]
        else:
            j = next((j for j, li in enumerate(l) if j not in used and same_value(ci, li)), None)
            ok = j is not None
        if j is not None and ok:
            used.add(j)
            hit += 1
    extra = len(l) - len(used)
    return hit / len(c) >= 0.6 and extra <= max(1, len(c) // 2), f'items {hit}/{len(c)}' + (f' +{extra} extra' if extra else '')


def compare(cloud, loc):
    """Every flag and status / id field the same (the decision), and >= 70% of the rest."""
    if not cloud:
        return not loc, 'fields 0/0'
    loc = loc if isinstance(loc, dict) else {}
    bad = [k for k, v in cloud.items() if not same_value(v, loc.get(k))]
    gate = [k for k in bad if isinstance(cloud[k], bool) or (isinstance(cloud[k], str) and enum(cloud[k]))]
    return not gate and (len(cloud) - len(bad)) / len(cloud) >= 0.7, f'fields {len(cloud) - len(bad)}/{len(cloud)}' + (f' differ {bad[:5]}' if bad else '')


def outcome(loc, cloud):
    if set(cloud) == {'ok', 'output'}:   # a step's {ok, output}: same ok, the output's URLs, counts and status word
        if loc.get('ok') != cloud.get('ok'):
            return False, f"ok {loc.get('ok')} vs {cloud.get('ok')}"
        cf = facts(cloud.get('output', ''))
        hit = {f for f in cf if f in str(loc.get('output', ''))}
        if not cf:
            return True, 'ok same; no URL, count or status word to compare'
        return len(hit) / len(cf) >= 0.8, f'facts {len(hit)}/{len(cf)}' + (f' missing {sorted(cf - hit)[:4]}' if cf - hit else '')
    if 'reclassify' in cloud and 'newDefects' in cloud:   # a note audit: the same defect / notExercised ids, the same new defect count
        ids = lambda o, k: sorted(str(x.get('id')) for x in o.get('reclassify') or [] if isinstance(x, dict) and x.get(k))
        same = ids(loc, 'defect') == ids(cloud, 'defect') and ids(loc, 'notExercised') == ids(cloud, 'notExercised') and len(loc.get('newDefects') or []) == len(cloud.get('newDefects') or [])
        return same, f"defect {ids(loc, 'defect')} vs {ids(cloud, 'defect')}; newDefects {len(loc.get('newDefects') or [])} vs {len(cloud.get('newDefects') or [])}"
    if set(cloud) == {'commit'}:   # a ship text (the commit, or an MR spec that renders it): same type, subject <= 72 chars, its facts
        if 'commit' in loc:
            subj, body = str(loc['commit']).strip().split('\n')[0], str(loc['commit'])
            ltype = re.split(r'[(:!]', subj)[0]
        else:
            subj = f"{loc.get('type')}({loc.get('scope')}): {loc.get('change')}"
            body = subj + ' ' + ' '.join(f"{c.get('text', '')} {c.get('technical', '')}" for c in loc.get('changes') or [] if isinstance(c, dict))
            ltype = loc.get('type')
        ctype = re.split(r'[(:!]', cloud['commit'].strip())[0]
        rc = recall(cloud['commit'], body)
        return ltype == ctype and len(subj) <= 72 and (rc >= 0.4 or (JUDGE is not None and text_same(cloud['commit'], body))), f"type {ltype} vs {ctype}; subject {len(subj)} ch; facts {round(rc * 100)}%"
    return compare(cloud, loc)   # any other answer: >= 70% of its fields the same (see same_value)


# ---- build: recorded subagent transcripts -> tasks
def transcript_root(arg):
    if arg:
        return arg
    ws = osp.dirname(KIT_DIR)   # the workspace: the kit is its .claude folder
    return osp.join(osp.expanduser('~'), '.claude', 'projects', re.sub(r'[^A-Za-z0-9]', '-', ws))


def read_transcript(path):
    pend, seq, final, model, prompt, last_text = {}, [], None, '', '', ''
    with open(path, encoding='utf-8', errors='replace') as fh:
        for ln in fh:
            if not model:
                mm = re.search(r'exact model ID is (?:claude-)?([a-z]+)', ln)
                model = mm.group(1) if mm else ''
            try:
                e = json.loads(ln)
            except ValueError:
                continue
            c = (e.get('message') or {}).get('content')
            if e.get('type') == 'user' and not prompt:
                prompt = c if isinstance(c, str) else ''.join(x.get('text', '') for x in c or [] if isinstance(x, dict) and x.get('type') == 'text')
            for x in c if isinstance(c, list) else []:
                if x.get('type') == 'text' and e.get('type') == 'assistant' and x.get('text', '').strip():
                    last_text = x['text']
                elif x.get('type') == 'tool_use':
                    if x.get('name') == 'StructuredOutput':
                        final = x.get('input')
                    else:
                        pend[x['id']] = (x.get('name'), x.get('input'))
                elif x.get('type') == 'tool_result' and x.get('tool_use_id') in pend:
                    cc = x.get('content')
                    s = cc if isinstance(cc, str) else '\n'.join(str(y.get('text', '')) for y in cc if isinstance(y, dict)) if isinstance(cc, list) else str(cc)
                    nm, inp = pend.pop(x['tool_use_id'])
                    seq.append((nm, inp, s))
    if final is None:
        final = json_object(last_text)   # an ad hoc agent: its final report's JSON
    return prompt, seq, final, model


def cut(s, n):
    return s if len(s) <= n else s[:n // 2] + f'\n[... {len(s) - n} chars cut ...]\n' + s[-n // 2:]


def replay(seq):
    parts = [f'[{i}] {nm}: {cut(str(inp.get("command") if isinstance(inp, dict) and "command" in inp else json.dumps(inp, ensure_ascii=False)), CUT_CMD)}\noutput:\n{cut(res, CUT_RES)}\n'
             for i, (nm, inp, res) in enumerate(seq, 1)]
    while len('\n'.join(parts)) > CUT_ALL and len(parts) > 3:   # keep the first call and the latest ones
        parts.pop(1)
    return '\n'.join(parts)


def role_of(meta, path):
    t = meta.get('agentType') or ''
    if os.sep + 'workflows' + os.sep in path or '/workflows/' in path.replace('\\', '/'):
        return f"{t}:{re.split(r'[:@ ]', meta.get('description') or '')[0]}"
    return t


def kind_of(prompt):
    """An ad hoc agent's kind from its brief: 'role lead', else 'Kind mr' / 'kind: plan'."""
    head = prompt[:1500]
    if re.search(r'\brole[: ]+lead\b', head, re.I):
        return 'lead'
    for m in re.finditer(r'(?im)(?:^|[.,;]\s*)kind[: ]+([a-z][\w-]*)\b(?!\s*/)', head):   # 'Kind mr.', 'role test, kind task'; not 'kind window / sweep'
        if m.group(1).lower() not in ('of', 'the', 'a', 'an', 'this', 'that'):
            return m.group(1).lower()
    return ''


def wanted(want, role):
    """A wanted role matches itself, a bare type all its steps and kinds (checky), type@ its ad hoc runs only, type@kind its kind."""
    if want.endswith('@'):
        return ':' not in role and role.split('@')[0] == want[:-1]
    return role == want or role.split(':')[0].split('@')[0] == want or role.startswith(want + '@')


def cmd_build(a):
    root = transcript_root(a.transcripts)
    if not osp.isdir(root):
        print(f'build: no transcripts at {root} (-Transcripts <dir>)'); return 1
    want = list(a.roles or ([u for u, e in runon_units().items() if not e['boot'] and ('@' in u or ':' in u)] if a.add else DEFAULT_ROLES))   # -Add: every run unit
    since = datetime.datetime.strptime(a.since, '%Y-%m-%d').timestamp() if a.since else time.time() - 14 * 86400
    sd, made, seen = bench_dir(a.set, create=True), {}, set()
    old = osp.join(sd, 'tasks')
    units, have, used = runon_units(), {}, set()   # -Add: tasks per unit already in the set; transcripts any set holds
    if a.add:
        for s in set_names(argparse.Namespace(sets=[])):
            sd2 = osp.join(bench_dir(s), 'tasks')
            for tid in os.listdir(sd2):
                om = rjson(osp.join(sd2, tid, 'meta.json'), {}) or {}
                used.add(om.get('transcript'))
                if s == a.set:
                    ou = bench_unit(om, units) or om.get('role')
                    have[ou] = have.get(ou, 0) + 1
    elif osp.isdir(old) and os.listdir(old):
        if not a.force:
            print(f'build: set {a.set} has tasks ({old}): -Force rebuilds it, -Add tops it up, or name a new -Set'); return 1
        for e in os.listdir(sd):   # tasks and every model's runs and scores: ids are reused
            shutil.rmtree(osp.join(sd, e)) if osp.isdir(osp.join(sd, e)) else os.remove(osp.join(sd, e))
    metas = []
    for dp, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.meta.json'):
                p = osp.join(dp, f)
                js = p[:-len('.meta.json')] + '.jsonl'
                if osp.exists(js) and osp.getmtime(js) >= since:
                    metas.append((osp.getmtime(js), p, js))
    for _, p, js in sorted(metas, reverse=True):   # newest first
        m = rjson(p, {})
        role = role_of(m, js)
        if not any(wanted(re.split(r'[@:]', w)[0], role) for w in want):   # a unit (steppy:release) by its type; matched below
            continue
        prompt, seq, final, model = read_transcript(js)
        if ':' not in role and kind_of(prompt):
            role = f'{role}@{kind_of(prompt)}'   # ad hoc: per kind (revy@mr, revy@plan, checky@lead)
        hit = role if any(wanted(w, role) or bench_unit({'role': role, 'label': m.get('description')}, units) == w for w in want) else None
        key = (bench_unit({'role': hit, 'label': m.get('description')}, units) or hit) if a.add and hit else hit   # -Add caps per unit
        if not hit or have.get(key, 0) + made.get(key, 0) >= a.n or js in used or not isinstance(final, dict) or not final or not seq or prompt[:3000] in seen:
            continue
        seen.add(prompt[:3000])
        made[key] = made.get(key, 0) + 1
        slug, nr = re.sub(r'[^a-z0-9]+', '-', hit.lower()).strip('-'), made[key]
        while a.add and osp.exists(osp.join(sd, 'tasks', f'{slug}-{nr}')):
            nr += 1
        tid = f'{slug}-{nr}'
        sch = derive_schema(final)
        body = PREFIX + prompt[:20000] + '\n\n=== TOOL CALLS ALREADY RUN (in order) ===\n' + replay(seq)
        body += f'\n\n=== JSON SCHEMA OF THE ANSWER (reply with the JSON object only) ===\n{json.dumps(sch)}\n'
        td = osp.join(sd, 'tasks', tid)
        os.makedirs(td, exist_ok=True)
        with open(osp.join(td, 'prompt.md'), 'w', encoding='utf-8') as fh:
            fh.write(body)
        wjson(osp.join(td, 'schema.json'), sch)
        wjson(osp.join(td, 'cloud.json'), final)
        wjson(osp.join(td, 'meta.json'), {'id': tid, 'role': hit, 'tier': model, 'label': m.get('description'), 'transcript': js, 'calls': len(seq), 'promptSha': sha(body)})
    missing = [w for w in want if not any(wanted(w, r) or r == w for r in made) and not (a.add and have.get(w, 0) >= a.n)]
    print(f"build {a.set}: {sum(made.values())} task(s) in {sd}: " + ', '.join(f'{k} {v}' for k, v in made.items()) + (f' · no history: {", ".join(missing)}' if missing else ''))
    return 0 if made or a.add else 1


def tasks_of(a):
    td = osp.join(bench_dir(a.set), 'tasks')
    ids = sorted(os.listdir(td)) if osp.isdir(td) else []
    if a.ids:
        ids = [i for i in ids if i in a.ids]
    if a.roles:
        ids = [i for i in ids if (rjson(osp.join(td, i, 'meta.json'), {}) or {}).get('role') in a.roles]
    return td, ids


# ---- contract: what a production agent already has as system text (AGENTS.md "Final answer", StructuredOutput's schema)
def final_rule():
    try:
        with open(osp.join(KIT_DIR, 'AGENTS.md'), encoding='utf-8') as fh:
            m = re.search(r'^- \*\*Final answer\*\*.*?(?=^- \*\*|^## |\Z)', fh.read(), re.S | re.M)
    except OSError:
        m = None
    return re.sub(r'\s+', ' ', m.group(0)).strip() if m else 'End with ONE StructuredOutput call: every required key, values copied from the tool outputs.'


def deep_schema(v):
    """The answer's shape with the keys of list items and nested objects (the production schema names them; a type-only one hides them)."""
    names = {bool: 'boolean', int: 'number', float: 'number', str: 'string'}
    if isinstance(v, dict):
        return {'type': 'object', 'properties': {k: deep_schema(x) for k, x in v.items()}, 'required': list(v)}
    if isinstance(v, list):
        d = next((x for x in v if isinstance(x, dict)), None)
        return {'type': 'array', 'items': deep_schema(d)} if d else {'type': 'array'}
    return {'type': names[type(v)]} if type(v) in names else {}


def contract_of(td, tid):
    cloud = rjson(osp.join(td, tid, 'cloud.json'), {}) or {}
    return ('Your whole reply is ONE JSON object: no analysis, no reasoning, no prose before or after, no code fence. Shape of the answer '
            '(every key required, values copied from the tool outputs, list items with the keys shown):\n' + json.dumps(deep_schema(cloud), ensure_ascii=False) + '\n')


MODES = ('vague', 'noformat', 'noisy')
NOISE = ['2026-01-01T00:00:00Z INFO heartbeat ok', 'WARN retry 1/3 after timeout (ignored)', 'DEBUG cache hit ratio 0.93', 'INFO gc pause 12ms']
STEPS_AT, CALLS_AT, SCHEMA_AT = '=== STEP INSTRUCTIONS (already carried out) ===\n', '\n\n=== TOOL CALLS ALREADY RUN (in order) ===\n', '\n\n=== JSON SCHEMA OF THE ANSWER'


def degrade(body, mode):
    """A real task prompt made worse on purpose, mechanically: the same tool outputs; scoring keeps schema.json and cloud.json."""
    pre, rest = body.split(STEPS_AT, 1)
    steps, rest = rest.split(CALLS_AT, 1)
    calls, _, schema = rest.partition(SCHEMA_AT)
    pre = pre.replace('as ONE JSON object matching the schema at the end. Reply with the JSON object only: no prose, no code fence.', 'as JSON.')
    if mode == 'vague':
        steps = steps[:400]
    elif mode == 'noisy':
        steps = '\n'.join(ln for ln in steps.splitlines() if not re.match(r'\s*(\d+[.)]|[-*]) ', ln))
        calls = '\n'.join(NOISE) + '\n' + calls + '\n' + '\n'.join(reversed(NOISE))
    out = pre + STEPS_AT + steps + CALLS_AT + calls + '\n'
    return out if mode == 'noformat' else out + SCHEMA_AT + schema


def cmd_degrade(a):
    src, dst = osp.join(bench_dir(a.degrade), 'tasks'), osp.join(bench_dir(a.set, create=True), 'tasks')
    if not osp.isdir(src):
        print(f'build: no set {a.degrade} to degrade'); return 1
    if a.set == a.degrade:
        print('build: -Set must name a new set, not the source'); return 2
    if osp.isdir(dst) and os.listdir(dst) and not a.force:
        print(f'build: set {a.set} has tasks: -Force rebuilds it'); return 1
    shutil.rmtree(dst, ignore_errors=True)
    per, made = {}, 0
    for tid in sorted(os.listdir(src)):
        m = rjson(osp.join(src, tid, 'meta.json'), {}) or {}
        role = m.get('role') or tid
        if (a.roles and role not in a.roles) or per.get(role, 0) >= min(a.n, 3):
            continue
        try:
            with open(osp.join(src, tid, 'prompt.md'), encoding='utf-8') as fh:
                text = fh.read()
            mode = MODES[per.get(role, 0) % 3]
            body = degrade(text, mode)
        except (OSError, ValueError):
            continue
        per[role] = per.get(role, 0) + 1
        nid = f'{tid}-{mode}'
        os.makedirs(osp.join(dst, nid), exist_ok=True)
        with open(osp.join(dst, nid, 'prompt.md'), 'w', encoding='utf-8') as fh:
            fh.write(body)
        for f in ('schema.json', 'cloud.json'):
            shutil.copy(osp.join(src, tid, f), osp.join(dst, nid, f))
        wjson(osp.join(dst, nid, 'meta.json'), dict(m, id=nid, degrade=mode, source=f'{a.degrade}/{tid}', promptSha=sha(body)))
        made += 1
    print(f"build {a.set}: {made} degraded task(s) from {a.degrade}: " + ', '.join(f'{k} {v}' for k, v in per.items()))
    return 0 if made else 1


# ---- run: each task through crafty.ps1 local claude (the launcher's checks, seat and env), no tools, one id at a time
def cmd_run(a):
    td, ids = tasks_of(a)
    if not ids:
        print(f'run: no tasks in set {a.set} (local bench build first)'); return 1
    md = bench_dir(a.set, a.model, create=True)
    res_p = osp.join(md, 'results.json')
    res = rjson(res_p, {}) or {}
    env = dict(os.environ)
    real, bare = a.model.split('~')[0], not a.model.endswith('~contract')
    benv = (cfg().get('bench') or {}).get('env')
    for k, v in (benv if isinstance(benv, dict) else {'ANTHROPIC_CUSTOM_HEADERS': 'User-Agent: kit-local-bench'}).items():   # a proxy's own client profile (tool split, managed tools) stays out of the replay
        if v is None:
            env.pop(k, None)
        else:
            env[k] = str(v)
    crafty = osp.join(KIT_DIR, 'skills', 'crafty', 'crafty.ps1')
    pwsh = 'pwsh'
    for tid in ids:
        psha = (rjson(osp.join(td, tid, 'meta.json'), {}) or {}).get('promptSha')
        con = '' if bare else contract_of(td, tid)
        csha = sha(con)
        if not a.force and (res.get(tid) or {}).get('rc') == '0' and res[tid].get('promptSha') == psha and res[tid].get('contract') == csha:
            continue   # ran on this prompt; a launcher refusal or a timeout runs again
        # --tools= (not --tools ''): a .cmd shim drops an empty argument
        os.makedirs(osp.join(md, 'runs'), exist_ok=True)
        cp = osp.join(md, 'runs', tid + '.system.md')
        if not bare:
            with open(cp, 'w', encoding='utf-8') as fh:
                fh.write(con)
        rest = ['--', '--tools=', '--strict-mcp-config', '--no-session-persistence'] + ([] if bare else ['--append-system-prompt-file', cp])
        argv = [pwsh, '-NoProfile', '-File', crafty, 'local', 'claude', '-Model', real, '-Agent', a.agent, '-WaitMinutes', '0', '-PromptFile', osp.join(td, tid, 'prompt.md')] + rest
        t0 = time.time()
        pr = subprocess.Popen(argv, cwd=osp.join(td, tid), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=os.name != 'nt')
        try:
            out, err = pr.communicate(timeout=a.timeoutsec)
            rc = pr.returncode
        except subprocess.TimeoutExpired:
            if os.name == 'nt':   # the client is a grandchild: end the whole tree
                subprocess.run(['taskkill', '/T', '/F', '/PID', str(pr.pid)], capture_output=True)
            else:
                os.killpg(pr.pid, signal.SIGKILL)
            try:
                out, err = pr.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                out, err = b'', b''
            rc = 'timeout'
        os.makedirs(osp.join(md, 'runs'), exist_ok=True)
        with open(osp.join(md, 'runs', tid + '.json'), 'wb') as fh:
            fh.write(out or b'')
        with open(osp.join(md, 'runs', tid + '.err'), 'wb') as fh:
            fh.write(err or b'')
        res[tid] = {'id': tid, 'rc': str(rc), 'sec': round(time.time() - t0, 1), 'at': datetime.datetime.now().isoformat(timespec='seconds'), 'client': 'claude', 'promptSha': psha, 'contract': csha}
        wjson(res_p, res)
        print(f"run {tid}: rc {rc}, {res[tid]['sec']} s", flush=True)
    return 0


def reply_of(path):
    raw = open(path, encoding='utf-8', errors='replace').read().strip() if osp.exists(path) else ''
    for ln in reversed(raw.splitlines()):
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        if isinstance(d, dict) and 'result' in d:
            return str(d.get('result') or '')
    return raw   # no JSON result line: the whole stdout


def cmd_score(a):
    global JUDGE
    td, ids = tasks_of(a)
    md = bench_dir(a.set, a.model)
    jm = a.judge or str((cfg().get('bench') or {}).get('judge') or '')
    JUDGE = make_judge(jm, osp.join(md, 'judge.json')) if jm and jm != 'off' else None
    res = rjson(osp.join(md, 'results.json'), {}) or {}
    sc_p = osp.join(md, 'score.json')
    sc = {k: v for k, v in (rjson(sc_p, {}) or {}).items() if osp.isdir(osp.join(td, k))}   # ids of a rebuilt set drop out
    for tid in ids:
        r = res.get(tid)
        if not r or r.get('promptSha') != (rjson(osp.join(td, tid, 'meta.json'), {}) or {}).get('promptSha'):
            sc.pop(tid, None)   # never run, or run on an older prompt
            continue
        meta, schema, cloud = (rjson(osp.join(td, tid, f), {}) for f in ('meta.json', 'schema.json', 'cloud.json'))
        rp = parse_reply(reply_of(osp.join(md, 'runs', tid + '.json')))
        best = next((rp[k] for k in ('strict', 'repairable', 'lenient') if isinstance(rp[k], dict)), None)
        sv = best is not None and valid(best, schema)
        oc, why = outcome(best, cloud) if sv else (False, 'tool-call-text' if rp['toolText'] else 'no schema-valid JSON')
        if r['rc'] not in ('0', 'timeout'):
            oc, why = None, f"infra: rc {r['rc']} (launcher refusal or client error; {open(osp.join(md, 'runs', tid + '.err'), encoding='utf-8', errors='replace').read()[-160:].strip() if osp.exists(osp.join(md, 'runs', tid + '.err')) else ''})"
        sc[tid] = {'id': tid, 'role': meta.get('role'), 'tier': meta.get('tier'), 'rc': r['rc'], 'sec': r['sec'], 'strict': isinstance(rp['strict'], dict),
                   'repairable': isinstance(rp['repairable'], dict), 'lenient': isinstance(rp['lenient'], dict), 'toolText': rp['toolText'],
                   'schema': sv, 'outcome': oc, 'accepted': bool(isinstance(rp['strict'], dict) and sv and oc), 'why': why}
    JUDGE = None
    wjson(sc_p, sc)
    print(f'score {a.set}/{a.model}: {len(sc)} scored, {sum(s["accepted"] for s in sc.values())} accepted ({sc_p})')
    return 0


def summary(sc):
    roles = {}
    for s in sc.values():
        roles.setdefault(s['role'], []).append(s)
    rows = []
    for role, ss in sorted(roles.items()):
        secs = sorted(s['sec'] for s in ss if s['rc'] == '0')
        infra = sum(s['rc'] not in ('0', 'timeout') for s in ss)
        rated = len(ss) - infra   # the rate counts only ids the model answered
        rows.append({'role': role, 'tier': '/'.join(sorted({s.get('tier') or '?' for s in ss})), 'n': len(ss), 'accepted': sum(s['accepted'] for s in ss),
                     'rate': round(100 * sum(s['accepted'] for s in ss) / rated) if rated else None, 'infra': infra,
                     'badJson': sum(not s['strict'] for s in ss if s['rc'] == '0'),
                     'repairable': sum(s['repairable'] and not s['strict'] for s in ss), 'toolText': sum(s['toolText'] for s in ss),
                     'timeouts': sum(s['rc'] == 'timeout' for s in ss), 'p50': round(statistics.median(secs), 1) if secs else None,
                     'p90': secs[min(len(secs) - 1, round(0.9 * (len(secs) - 1)))] if secs else None})
    return rows


def pct(rate):
    return '-' if rate is None else f'{rate}%'


def write_evidence(a, sc):
    """models.runOn.<unit>.evidence.<set> = this model's accepted / answered tasks of that unit; the unit's cloud | local stays."""
    p, units = local_config_path(KIT_DIR, 'kit.local.json'), runon_units()
    if not p:
        print('report: no kit.local.json: evidence not written'); return
    td = osp.join(bench_dir(a.set), 'tasks')
    per = {}
    for tid, s in sc.items():
        u = bench_unit(rjson(osp.join(td, tid, 'meta.json'), {}) or {'role': s.get('role')}, units)
        if u and s['rc'] in ('0', 'timeout'):   # infra fails are no evidence
            e = per.setdefault(u, [0, 0])
            e[0] += bool(s['accepted'])
            e[1] += 1
    ro = dict(((rjson(p, {}) or {}).get('models') or {}).get('runOn') or {})
    for u, (acc, n) in per.items():
        v = ro.get(u, 'cloud')
        v = dict(v) if isinstance(v, dict) else {'on': v}
        v['evidence'] = {**(v.get('evidence') or {}), a.set: {'model': a.model, 'accepted': acc, 'n': n, 'rate': round(100 * acc / n), 'at': datetime.date.today().isoformat()}}
        ro[u] = v
    write_runon(p, ro)
    print(f'report: evidence for {len(per)} unit(s) written to {p} (models.runOn.<unit>.evidence.{a.set}; settings unchanged)')


def cmd_report(a):
    sc = rjson(osp.join(bench_dir(a.set, a.model), 'score.json'), {}) or {}
    if not sc:
        print(f'report: no score for {a.set}/{a.model} (local bench score first)'); return 1
    rows = summary(sc)
    if a.evidence:
        write_evidence(a, sc)
    if a.json:
        print(json.dumps(rows)); return 0
    print(f'{a.set} on {a.model}: {sum(r["accepted"] for r in rows)}/{sum(r["n"] - r["infra"] for r in rows)} accepted ({sum(r["infra"] for r in rows)} infra)')
    print(f'{"role":22} {"tier":10} {"n":>3} {"accept":>7} {"p50 s":>7} {"p90 s":>7} {"badJSON":>8} {"repair":>7} {"toolTxt":>8} {"timeout":>8} {"infra":>6}')
    for r in rows:
        print(f'{r["role"]:22} {r["tier"]:10} {r["n"]:3} {pct(r["rate"]):>7} {str(r["p50"]):>7} {str(r["p90"]):>7} {r["badJson"]:8} {r["repairable"]:7} {r["toolText"]:8} {r["timeouts"]:8} {r["infra"]:6}')
    return 0


def cmd_diff(a):
    s1, s2 = (rjson(osp.join(bench_dir(a.set, m), 'score.json'), {}) or {} for m in (a.model, a.against))
    if not s1 or not s2:
        print(f'diff: a score is missing ({a.model}: {len(s1)}, {a.against}: {len(s2)})'); return 1
    both = sorted(set(s1) & set(s2))
    r1 = {r['role']: r for r in summary({i: s1[i] for i in both})}
    r2 = {r['role']: r for r in summary({i: s2[i] for i in both})}
    judged = lambda s: s['outcome'] is not None and s['rc'] in ('0', 'timeout')   # an infra fail never flips
    flips = [(i, s1[i]['accepted'], s2[i]['accepted']) for i in both if judged(s1[i]) and judged(s2[i]) and s1[i]['accepted'] != s2[i]['accepted']]
    if a.json:
        print(json.dumps({'roles': [{'role': k, a.model: r1[k], a.against: r2.get(k)} for k in r1], 'flips': flips})); return 0
    print(f'{"role":22} {"tier":10} {a.model[:18]:>18} {a.against[:18]:>18}   (accept %, p50 s; {len(both)} common ids)')
    for k in r1:
        x, y = r1[k], r2.get(k) or {}
        print(f'{k:22} {x["tier"]:10} {pct(x["rate"]) + " " + str(x["p50"]):>18} {pct(y.get("rate")) + " " + str(y.get("p50")):>18}')
    for i, x, y in flips:
        print(f'  flip {i}: {a.model} {"accepted" if x else "rejected"}, {a.against} {"accepted" if y else "rejected"}')
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog='crafty.ps1 local bench', add_help=True)
    ap.add_argument('verb', choices=['build', 'run', 'score', 'report', 'diff', 'coverage', 'runon'])
    ap.add_argument('-Set', '--set', dest='set', default='default')
    ap.add_argument('-Add', '--add', dest='add', action='store_true')
    ap.add_argument('-Min', '--min', dest='min', type=int, default=3)
    ap.add_argument('-Write', '--write', dest='write', default='')
    ap.add_argument('-WriteRunonEvidence', '--write-runon-evidence', dest='evidence', action='store_true')
    ap.add_argument('-Model', '--model', dest='model', default='')
    ap.add_argument('-Against', '--against', dest='against', default='')
    ap.add_argument('-Roles', '--roles', dest='roles', default='')
    ap.add_argument('-Ids', '--ids', dest='ids', default='')
    ap.add_argument('-N', '--n', dest='n', type=int, default=4)
    ap.add_argument('-Since', '--since', dest='since', default='')
    ap.add_argument('-Transcripts', '--transcripts', dest='transcripts', default='')
    ap.add_argument('-Agent', '--agent', dest='agent', default=os.environ.get('CLAUDE_AGENT') or 'main')
    ap.add_argument('-TimeoutSec', '--timeoutsec', dest='timeoutsec', type=int, default=600)
    ap.add_argument('-Judge', '--judge', dest='judge', default='')
    ap.add_argument('-Degrade', '--degrade', dest='degrade', default='')
    ap.add_argument('-Force', '--force', dest='force', action='store_true')
    ap.add_argument('-Json', '--json', dest='json', action='store_true')
    a = ap.parse_args(argv)
    a.roles = [x for x in re.split(r'[,\s]+', a.roles) if x]
    a.ids = [x for x in re.split(r'[,\s]+', a.ids) if x]
    a.sets = [x for x in re.split(r'[,\s]+', a.set) if x] if a.verb == 'coverage' and a.set != 'default' else []
    if a.verb in ('run', 'score', 'report', 'diff') and not a.model:
        a.model = str(cfg().get('defaultModel') or '')
        if not a.model:
            print(f'{a.verb}: -Model <served id> or models.local.defaultModel'); return 2
    if a.verb == 'diff' and not a.against:
        print('diff: -Against <model>'); return 2
    if a.ids and a.verb == 'run':
        a.force = True   # named ids: a repro re-runs them
    if a.verb == 'build' and a.degrade:
        return cmd_degrade(a)
    return {'build': cmd_build, 'run': cmd_run, 'score': cmd_score, 'report': cmd_report, 'diff': cmd_diff, 'coverage': cmd_coverage, 'runon': cmd_runon}[a.verb](a)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
