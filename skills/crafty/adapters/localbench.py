"""localbench.py: replay recorded real agent steps against a local model and score them (crafty.ps1 local bench).
  build  [-Set s] [-Roles r1,r2] [-N 4] [-Since yyyy-mm-dd] [-Transcripts dir] [-Force]   replay set from recorded steps, per
         role; an existing set: -Force empties it (results of a changed task are never reused: meta.promptSha)
  run    -Model m [-Set s] [-Ids a,b] [-Roles ..] [-Runner claude|codex] [-TimeoutSec 600] [-Force]   resumable: skips ids that
         ran (rc 0) on the same prompt; -Ids re-runs them; claude: --tools= (none), codex: --sandbox read-only
  score  -Model m [-Set s]        strict / repairable / lenient JSON, schema, outcome per id (none comparable: unscored)
  report -Model m [-Set s] [-Json]   accept rate over the ids that ran, infra fails apart, median / p90 s per role, cloud tier
  diff   -Model m -Against m2 [-Set s] [-Json]   per role delta and the ids that flip
A role: <agentType>:<step label> (workflow steps, e.g. checky:close, kitty:learn) or <agentType> (ad hoc agents, e.g. watchy).
A task: the step's prompt, every tool call it made with its output (cut), then "answer from these outputs" + the JSON schema
derived from the answer the cloud run returned (cloud.json). Nothing runs tools: run passes --tools "" (claude); a reply that
writes a tool call as text scores tool-call-text. Store: <state>/local-bench/<set>/tasks/<id>/ (set) and
<state>/local-bench/<set>/<model>/ (runs/<id>.json, results.json, score.json); re-running ids overwrites only those ids.
Transcripts: Claude Code subagent transcripts (~/.claude/projects/<workspace>/*/subagents/**); Codex / Antigravity sessions:
no reader (README parity row). Exit codes: 0 ok · 1 nothing to do / missing set · 2 usage.
Sections: L32 store · L66 reply parsing · L111 outcome · L151 build · L267 run
"""
import argparse, datetime, hashlib, json, os, re, shutil, signal, statistics, subprocess, sys, time
import os.path as osp
sys.path.insert(0, osp.join(osp.dirname(osp.dirname(osp.dirname(osp.abspath(__file__)))), 'bossy'))   # <kit>/skills/bossy
from kitbag import kit_path, local_config, KIT_DIR  # noqa: E402

CUT_RES, CUT_CMD, CUT_ALL = 2500, 1500, 60000
DEFAULT_ROLES = ['steppy', 'checky:close', 'checky:hold', 'kitty:learn', 'kitty:track', 'devy:track', 'devy:followups',
                 'checky:audit', 'checky:verify', 'checky:test', 'watchy', 'vidy']
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


def short_fields(o):
    out = {}
    for k, v in (o or {}).items():
        if isinstance(v, (bool, int, float)):
            out[k] = v
        elif isinstance(v, str) and len(v) <= 24:
            out[k] = v.strip().lower()
        elif isinstance(v, list):
            out[k + '#len'] = len(v)
    return out


def outcome(loc, cloud):
    if set(cloud) == {'ok', 'output'}:   # a step's {ok, output}: same ok, the output's URLs, counts and status word
        if loc.get('ok') != cloud.get('ok'):
            return False, f"ok {loc.get('ok')} vs {cloud.get('ok')}"
        cf = facts(cloud.get('output', ''))
        hit = {f for f in cf if f in str(loc.get('output', ''))}
        if not cf:
            return None, 'unscored: no URL, count or status word to compare'
        return len(hit) / len(cf) >= 0.8, f'facts {len(hit)}/{len(cf)}' + (f' missing {sorted(cf - hit)[:4]}' if cf - hit else '')
    if 'reclassify' in cloud and 'newDefects' in cloud:   # a note audit: the same defect / notExercised ids, the same new defect count
        ids = lambda o, k: sorted(str(x.get('id')) for x in o.get('reclassify') or [] if isinstance(x, dict) and x.get(k))
        same = ids(loc, 'defect') == ids(cloud, 'defect') and ids(loc, 'notExercised') == ids(cloud, 'notExercised') and len(loc.get('newDefects') or []) == len(cloud.get('newDefects') or [])
        return same, f"defect {ids(loc, 'defect')} vs {ids(cloud, 'defect')}; newDefects {len(loc.get('newDefects') or [])} vs {len(cloud.get('newDefects') or [])}"
    cf, lf = short_fields(cloud), short_fields(loc)   # any other answer: >= 80% of its short fields (flags, statuses, counts, list sizes) equal
    same = [k for k in cf if lf.get(k) == cf[k]]
    if not cf:
        return None, 'unscored: no short field to compare'
    return len(same) / len(cf) >= 0.8, f'fields {len(same)}/{len(cf)}' + (f" diff {sorted(set(cf) - set(same))[:4]}" if len(same) < len(cf) else '')


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


def cmd_build(a):
    root = transcript_root(a.transcripts)
    if not osp.isdir(root):
        print(f'build: no transcripts at {root} (-Transcripts <dir>)'); return 1
    want = [r for r in (a.roles or DEFAULT_ROLES)]
    since = datetime.datetime.strptime(a.since, '%Y-%m-%d').timestamp() if a.since else time.time() - 14 * 86400
    sd, made, seen = bench_dir(a.set, create=True), {}, set()
    old = osp.join(sd, 'tasks')
    if osp.isdir(old) and os.listdir(old):
        if not a.force:
            print(f'build: set {a.set} has tasks ({old}): -Force rebuilds it, or name a new -Set'); return 1
        shutil.rmtree(old)   # results of a changed id never match again: run compares meta.promptSha
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
        hit = next((w for w in want if role == w or (':' not in w and role.split(':')[0] == w)), None)   # a bare type: all its steps
        if not hit or made.get(hit, 0) >= a.n:
            continue
        prompt, seq, final, model = read_transcript(js)
        if not isinstance(final, dict) or not final or not seq or prompt[:3000] in seen:
            continue
        seen.add(prompt[:3000])
        made[hit] = made.get(hit, 0) + 1
        tid = f"{re.sub(r'[^a-z0-9]+', '-', hit.lower()).strip('-')}-{made[hit]}"
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
    missing = [w for w in want if not made.get(w)]
    print(f"build {a.set}: {sum(made.values())} task(s) in {sd}: " + ', '.join(f'{k} {v}' for k, v in made.items()) + (f' · no samples: {", ".join(missing)}' if missing else ''))
    return 0 if made else 1


def tasks_of(a):
    td = osp.join(bench_dir(a.set), 'tasks')
    ids = sorted(os.listdir(td)) if osp.isdir(td) else []
    if a.ids:
        ids = [i for i in ids if i in a.ids]
    if a.roles:
        ids = [i for i in ids if (rjson(osp.join(td, i, 'meta.json'), {}) or {}).get('role') in a.roles]
    return td, ids


# ---- run: each task through crafty.ps1 local <client> (the launcher's checks, seat and env), no tools, one id at a time
def cmd_run(a):
    td, ids = tasks_of(a)
    if not ids:
        print(f'run: no tasks in set {a.set} (local bench build first)'); return 1
    md = bench_dir(a.set, a.model, create=True)
    res_p = osp.join(md, 'results.json')
    res = rjson(res_p, {}) or {}
    env = dict(os.environ)
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
        if not a.force and (res.get(tid) or {}).get('rc') == '0' and res[tid].get('promptSha') == psha:
            continue   # ran on this prompt; a launcher refusal or a timeout runs again
        # --tools= (not --tools ''): a .cmd shim drops an empty argument; codex: no writes
        rest = ['--', '--tools=', '--strict-mcp-config', '--no-session-persistence'] if a.client == 'claude' else ['--', '--sandbox', 'read-only']
        argv = [pwsh, '-NoProfile', '-File', crafty, 'local', a.client, '-Model', a.model, '-Agent', a.agent, '-WaitMinutes', '0', '-PromptFile', osp.join(td, tid, 'prompt.md')] + rest
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
        res[tid] = {'id': tid, 'rc': str(rc), 'sec': round(time.time() - t0, 1), 'at': datetime.datetime.now().isoformat(timespec='seconds'), 'client': a.client, 'promptSha': psha}
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
    return raw   # codex exec: the reply is stdout


def cmd_score(a):
    td, ids = tasks_of(a)
    md = bench_dir(a.set, a.model)
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
        unscored = sum(s['outcome'] is None and s['rc'] in ('0', 'timeout') for s in ss)
        rated = len(ss) - infra - unscored   # the rate counts only ids the model answered and a rule could judge
        rows.append({'role': role, 'tier': '/'.join(sorted({s.get('tier') or '?' for s in ss})), 'n': len(ss), 'accepted': sum(s['accepted'] for s in ss),
                     'rate': round(100 * sum(s['accepted'] for s in ss) / rated) if rated else None, 'infra': infra, 'unscored': unscored,
                     'badJson': sum(not s['strict'] for s in ss if s['rc'] == '0'),
                     'repairable': sum(s['repairable'] and not s['strict'] for s in ss), 'toolText': sum(s['toolText'] for s in ss),
                     'timeouts': sum(s['rc'] == 'timeout' for s in ss), 'p50': statistics.median(secs) if secs else None,
                     'p90': secs[min(len(secs) - 1, round(0.9 * (len(secs) - 1)))] if secs else None})
    return rows


def cmd_report(a):
    sc = rjson(osp.join(bench_dir(a.set, a.model), 'score.json'), {}) or {}
    if not sc:
        print(f'report: no score for {a.set}/{a.model} (local bench score first)'); return 1
    rows = summary(sc)
    if a.json:
        print(json.dumps(rows)); return 0
    print(f'{a.set} on {a.model}: {sum(r["accepted"] for r in rows)}/{sum(r["n"] for r in rows)} accepted')
    print(f'{"role":22} {"tier":10} {"n":>3} {"accept":>7} {"p50 s":>7} {"p90 s":>7} {"badJSON":>8} {"repair":>7} {"toolTxt":>8} {"timeout":>8} {"infra":>6} {"unscored":>9}')
    for r in rows:
        print(f'{r["role"]:22} {r["tier"]:10} {r["n"]:3} {str(r["rate"]) + "%":>7} {str(r["p50"]):>7} {str(r["p90"]):>7} {r["badJson"]:8} {r["repairable"]:7} {r["toolText"]:8} {r["timeouts"]:8} {r["infra"]:6} {r["unscored"]:9}')
    return 0


def cmd_diff(a):
    s1, s2 = (rjson(osp.join(bench_dir(a.set, m), 'score.json'), {}) or {} for m in (a.model, a.against))
    if not s1 or not s2:
        print(f'diff: a score is missing ({a.model}: {len(s1)}, {a.against}: {len(s2)})'); return 1
    both = sorted(set(s1) & set(s2))
    r1 = {r['role']: r for r in summary({i: s1[i] for i in both})}
    r2 = {r['role']: r for r in summary({i: s2[i] for i in both})}
    flips = [(i, s1[i]['accepted'], s2[i]['accepted']) for i in both if s1[i]['accepted'] != s2[i]['accepted']]
    if a.json:
        print(json.dumps({'roles': [{'role': k, a.model: r1[k], a.against: r2.get(k)} for k in r1], 'flips': flips})); return 0
    print(f'{"role":22} {a.model[:18]:>18} {a.against[:18]:>18}   (accept %, p50 s; {len(both)} common ids)')
    for k in r1:
        x, y = r1[k], r2.get(k) or {}
        print(f'{k:22} {str(x["rate"]) + "% " + str(x["p50"]):>18} {str(y.get("rate")) + "% " + str(y.get("p50")):>18}')
    for i, x, y in flips:
        print(f'  flip {i}: {a.model} {"accepted" if x else "rejected"}, {a.against} {"accepted" if y else "rejected"}')
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog='crafty.ps1 local bench', add_help=True)
    ap.add_argument('verb', choices=['build', 'run', 'score', 'report', 'diff'])
    ap.add_argument('-Set', '--set', dest='set', default='default')
    ap.add_argument('-Model', '--model', dest='model', default='')
    ap.add_argument('-Against', '--against', dest='against', default='')
    ap.add_argument('-Roles', '--roles', dest='roles', default='')
    ap.add_argument('-Ids', '--ids', dest='ids', default='')
    ap.add_argument('-N', '--n', dest='n', type=int, default=4)
    ap.add_argument('-Since', '--since', dest='since', default='')
    ap.add_argument('-Transcripts', '--transcripts', dest='transcripts', default='')
    ap.add_argument('-Runner', '-Client', '--client', dest='client', choices=['claude', 'codex'], default='claude')
    ap.add_argument('-Agent', '--agent', dest='agent', default=os.environ.get('CLAUDE_AGENT') or 'main')
    ap.add_argument('-TimeoutSec', '--timeoutsec', dest='timeoutsec', type=int, default=600)
    ap.add_argument('-Force', '--force', dest='force', action='store_true')
    ap.add_argument('-Json', '--json', dest='json', action='store_true')
    a = ap.parse_args(argv)
    a.roles = [x for x in re.split(r'[,\s]+', a.roles) if x]
    a.ids = [x for x in re.split(r'[,\s]+', a.ids) if x]
    if a.verb in ('run', 'score', 'report', 'diff') and not a.model:
        a.model = str(cfg().get('defaultModel') or '')
        if not a.model:
            print(f'{a.verb}: -Model <served id> or models.local.defaultModel'); return 2
    if a.verb == 'diff' and not a.against:
        print('diff: -Against <model>'); return 2
    if a.ids and a.verb == 'run':
        a.force = True   # named ids: a repro re-runs them
    return {'build': cmd_build, 'run': cmd_run, 'score': cmd_score, 'report': cmd_report, 'diff': cmd_diff}[a.verb](a)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
