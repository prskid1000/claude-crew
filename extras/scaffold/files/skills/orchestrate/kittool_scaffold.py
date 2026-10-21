"""kittool extra scaffold: add, rename or remove a kit part with its registry entry, Router / Events row and a test stub.

  python -X utf8 skills/orchestrate/kittool.py new agent|skill|workflow|rule|event|config-key <name> [--crew <agent>] [--skill <skill>]
  python -X utf8 skills/orchestrate/kittool.py new adapter <kind> <name> · new adr <title>
  python -X utf8 skills/orchestrate/kittool.py rename agent|skill|workflow|rule|event|config-key <old> <new> · remove <kind> <name>

Installed by `kittool.py extra add scaffold`; kittool.py loads it and shares its own names (read, manifest, section, port).
Exit codes: 0 ok · 1 references left after rename / remove · 2 usage error.
"""
import contextlib, datetime, io, json, os, re, shutil, subprocess, sys
import os.path as osp

TODO = 'TODO(new)'

def _git(kit, *a):
    return subprocess.run(['git', '-C', kit, *a], capture_output=True, text=True, encoding='utf-8', errors='replace')

def _edit_manifest(kit, change):
    p = osp.join(kit, PATHS_JSON)
    raw = read(p)
    old = json.loads(raw).get('_manifest') or {}
    new = json.loads(json.dumps(old))
    change(new)
    at = raw.index('"_manifest": {')
    for key in [x for x in new if new[x] != old.get(x)]:   # changed keys only, one line each: the hand layout stays
        m = re.compile(r'\n(\s*)"' + re.escape(key) + r'": ').search(raw, at)
        if m:
            end = json.JSONDecoder().raw_decode(raw, m.end())[1]
            raw = raw[:m.end()] + json.dumps(new[key], ensure_ascii=False) + raw[end:]
        else:
            m = re.compile(r'\n(\s*)"renamed": ').search(raw, at)
            raw = raw[:m.start()] + f'\n{m.group(1)}"{key}": {json.dumps(new[key], ensure_ascii=False)},' + raw[m.start():]
    with open(p, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(raw)

def _write_new(kit, rel, text):
    p = osp.join(kit, rel)
    if osp.exists(p):
        sys.exit(f'kittool new: {rel} already exists')
    os.makedirs(osp.dirname(p), exist_ok=True)
    with open(p, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)
    print(f'wrote {rel}')

def _router_stub(kit, target, cond):
    """A Router row stub before the last row (the catch-all 'direct' row keeps its place); returns its id."""
    rid = {}

    def fn(t):
        sec = section(t, 'Router') or ''
        rows = [l for l in sec.split('\n') if re.match(r'^\|\s*R\d+\s*\|', l)]
        n = max(int(re.match(r'^\|\s*R(\d+)', l).group(1)) for l in rows) + 1
        rid['id'] = f'R{n}'
        new = f'| R{n} | {cond} | {target} | — |'
        return t.replace(rows[-1], new + '\n' + rows[-1], 1)
    _sub_file(kit, 'AGENTS.md', fn)
    _edit_manifest(kit, lambda m: m.setdefault('router', []).insert(len(m.get('router', [])) - 1, rid['id']))
    return rid['id']

TEST_MARK = '# ---- scaffolded parts (kittool.py new appends a test stub per part here; replace each with a real check)'

def _test_stub(kit, what):
    def fn(t):
        line = f"  Expect '{what}: {TODO} a real check' ($false)   # {TODO}\n"
        if TEST_MARK in t:
            return t.replace(TEST_MARK + '\n', TEST_MARK + '\n' + line, 1)
        return t.rstrip('\n') + '\n' + TEST_MARK + '\n' + line
    _sub_file(kit, 'tests/kit-tests.ps1', fn)

def cmd_new(a):
    """kittool.py new agent|skill|workflow|rule|event|config-key <name> [--crew <agent>] [--skill <skill>] | new adapter <kind> <name> | new adr <title>"""
    kit = KIT_DIR
    if len(a) < 2:
        print(cmd_new.__doc__, file=sys.stderr)
        return 2
    kind, name = a[0], a[1]
    if kind == 'adr':   # a decision record: one LESSONS.md "## Decisions" line, the title is free text
        title = ' '.join(a[1:]).strip()
        line = f'- {datetime.date.today():%Y-%m-%d} {title}: context {TODO} · decision {TODO} · consequences {TODO}'

        def fn(t):
            if not re.search(r'^## Decisions\s*$', t, re.M):
                return t.rstrip('\n') + '\n\n## Decisions\n' + line + '\n'
            return re.sub(r'(^## Decisions\s*\n(?:(?!## ).*\n)*)', lambda m: m.group(1).rstrip('\n') + '\n' + line + '\n', t, count=1, flags=re.M)
        _sub_file(kit, 'LESSONS.md', fn)
        print(f'LESSONS.md Decisions: {title}: fill every {TODO}')
        return 0
    opt = lambda n, d='': a[a.index(n) + 1] if n in a and a.index(n) + 1 < len(a) else d
    if not re.match(r'^[a-z][a-z0-9-]*(\.[a-zA-Z0-9]+)*$', name):
        sys.exit(f'kittool new: "{name}" is not a kebab-case name')
    if kind == 'agent':
        skill = opt('--skill', 'dev-kit')
        _write_new(kit, f'agents/{name}.md', f'''---
name: {name}
description: "{TODO}: what it does. Spawned by {TODO}: which workflow or the coordinator. Precondition: {TODO}. Loads {skill} first. Not for: {TODO}."
model: sonnet
---

`<kit>` = the workspace's `.claude` folder (the directory the session started in holds it).

**Character:** traits: {TODO} · bias: {TODO} · catchphrase: "{TODO}" · never: {TODO}.

**Kind** (the prompt names it): {TODO}.

**Load first:** `<kit>/skills/{skill}/SKILL.md` and follow its steps (step 0 prints your lessons).

Non-negotiables:
- Board first (`orch.ps1 board join -Type {name} ...`; it lists every live agent on this machine); a file, task, env or seat someone
  else holds -> `board msg` the holder; a disagreement -> `orch.ps1 board dispute`; `leave` at the end.
- {TODO}: the limits of this job.
- A prompt that starts with `STEP:` is one mechanical workflow step: do exactly that; skip Load first, the board and the report shape.

Finish with the report your task asks for (dev-kit templates.md "Final reports").

**Self-improvement:**
`& <kit>/skills/orchestrate/orch.ps1 learn -Skill {name} -Kind <kind> -Text "<what happened + what fixed it>" [-Ref <id>]`
''')
        ch = {'traits': TODO, 'bias': TODO, 'catchphrase': TODO, 'never': TODO}
        _edit_manifest(kit, lambda m: m.setdefault('agents', {}).__setitem__(name, {'job': TODO, 'kinds': [], 'roles': [], 'skill': skill, 'tools': 'all', 'usedIn': [], 'cant': TODO, 'character': ch}))
        rid = _router_stub(kit, f'`{name}` agent', f'{TODO}: the conditions that route to {name}')
        _test_stub(kit, f'agent {name}')
    elif kind == 'skill':
        _write_new(kit, f'skills/{name}/SKILL.md', f'''---
name: {name}
description: "Load when: {TODO}. Not when: {TODO} -> <sibling skill>."
---

**Load when** (all must hold): {TODO}.
**Not when:** {TODO} -> `<sibling>`.
**Hands off to:** {TODO}.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `<kit>/LESSONS.md` | step 0: `orch.ps1 learn -Read -Skill {name}` |

## Steps
0. `orch.ps1 learn -Read -Skill {name}`.
1. **{TODO}:** action -> result.

**Rules**
- {TODO}

**Learn:** `orch.ps1 learn -Skill {name} -Kind <kind> -Text "<what + fix>"`.
''')
        _edit_manifest(kit, lambda m: m.setdefault('skills', []).append(name) or m['skills'].sort())
        rid = _router_stub(kit, f'`{name}`', f'{TODO}: the conditions that load {name}')
        _test_stub(kit, f'skill {name}')
    elif kind == 'workflow':
        crew = opt('--crew', 'devy')
        cond = f'{TODO}: the conditions that launch /{name}'
        _write_new(kit, f'workflows/{name}.js', f'''export const meta = {{
  name: '{name}',
  description: '{TODO}: what the run does',
  whenToUse: '{cond}',
  phases: [
    {{ title: 'Run', detail: '{TODO}: what the phase does' }},
  ],
}}

/*
args = {{ kitDir: '<abs path of .claude>', mandate: ['<the owner words, verbatim>'] }}   // every arg with its default ({TODO})
Returns {{ ok, summary }}.
*/
const A = args || {{}}
const KIT = (A.kitDir || '.claude').replace(/[\\\\/]+$/, '')
const PATHS = '\\nPowerShell commands (& <script>.ps1) need pwsh 7: the PowerShell tool, else Bash: pwsh -NoProfile -Command "<command>".'
const OK_SCHEMA = {{ type: 'object', properties: {{ ok: {{ type: 'boolean' }}, summary: {{ type: 'string' }} }}, required: ['ok', 'summary'] }}
phase('Run')
const r = await agent(`{TODO}: the prompt (kit: ${{KIT}}).${{PATHS}}`, {{ label: 'run', phase: 'Run', schema: OK_SCHEMA, agentType: '{crew}' }})
return r || {{ ok: false, summary: 'the agent returned nothing' }}
''')
        rid = _router_stub(kit, f'`/{name}`', cond)
        _edit_manifest(kit, lambda m: m.setdefault('workflows', {}).__setitem__(name, {'covers': TODO, 'crew': [crew], 'router': rid}))
        _test_stub(kit, f'workflow {name}')
    elif kind == 'rule':
        _write_new(kit, f'rules/{name}.md', f'---\npaths: ["{TODO}: the files this rule is for"]\n---\n# {name}\n- {TODO}: one short hard rule per line\n')
        _test_stub(kit, f'rule {name}')
    elif kind == 'event':
        ids = {}

        def fn(t):
            rows = re.findall(r'^\|\s*E(\d+)\s*\|.*$', section(t, 'Events') or '', re.M)
            n = max(int(x) for x in rows) + 1
            ids['id'] = f'E{n}'
            last = [l for l in t.split('\n') if re.match(r'^\|\s*E\d+\s*\|', l)][-1]
            return t.replace(last, last + f'\n| E{n} | {TODO}: {name} | {TODO}: the action |', 1)
        _sub_file(kit, 'skills/orchestrate/SKILL.md', fn)
        _edit_manifest(kit, lambda m: m.setdefault('events', []).append(ids['id']))
        _test_stub(kit, f'event {ids["id"]} {name}')
    elif kind == 'config-key':
        def addkey(d):
            cur = d
            parts = name.split('.')
            for x in parts[:-1]:
                cur = cur.setdefault(x, {})
                if not isinstance(cur, dict):
                    sys.exit(f'kittool new: {x} in {name} is not an object')
            if parts[-1] in cur:
                sys.exit(f'kittool new: {name} already exists (its default stays)')
            cur[parts[-1]] = f'{TODO}: the default'
        p = osp.join(kit, PATHS_JSON)
        d = json.loads(read(p))
        addkey(d)
        man, pth = d.pop('_manifest', None), d.pop('_paths', None)
        d['_manifest'], d['_paths'] = man, pth
        with open(p, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')

        def fn(t):
            sec = section(t, 'Configuration') or ''
            last = [l for l in sec.split('\n') if l.startswith('| `')][-1]
            return t.replace(last, last + f'\n| `{name}` | {TODO} | {TODO}: what it changes (today\'s behaviour is the default) |', 1)
        _sub_file(kit, 'README.md', fn)
        _test_stub(kit, f'config key {name}')
    elif kind == 'adapter':   # new adapter <kind> <name>: every verb stubbed, before adapter-end:<kind>
        ak, name, man = name, (a[2] if len(a) > 2 else ''), manifest(kit).get('adapters') or {}
        ad = man.get(ak)
        if not ad or not re.match(r'^[a-z][a-z0-9-]*$', name):
            sys.exit(f'kittool new adapter <kind> <name>: kinds {sorted(x for x in man if x[0] != "_")}')
        py, end = ad['file'].endswith('.py'), f'# adapter-end:{ak}'
        body = '\n'.join((f"  '{v}': lambda a: _todo('{v}')," if py else f"  '{v}' = {{ param($a) throw '{TODO}: {v}' }}") for v in ad['verbs'].split())
        blk = f"# adapter:{ak}/{name}: {TODO} what it talks to\n" + (f"ADAPTERS.setdefault('{ak}', {{}})['{name}'] = {{" if py else f"Register-KitAdapter '{ak}' '{name}' @{{") + f"\n{body}\n}}\n"
        _sub_file(kit, ad['file'], lambda t: t.replace(end, blk + end, 1) if end in t else t.rstrip('\n') + '\n' + blk)
        _edit_manifest(kit, lambda m: m['adapters'][ak].__setitem__('names', f"{m['adapters'][ak]['names']} {name}"))
        _test_stub(kit, f'adapter {ak}/{name} against a recorded API fixture')
    else:
        print(cmd_new.__doc__, file=sys.stderr)
        return 2
    _regen(kit)
    print(f'{kind} {name}: fill every {TODO}, then kittool.py port, lint (0 problems), tests/kit-tests.ps1')
    return 0

def _regen(kit):
    """After new / rename / remove: the ports and README's generated sections follow the registry at once."""
    with contextlib.redirect_stdout(io.StringIO()):
        PLUGINS.get('port', lambda a: 0)([])   # the ports extra, when installed
    k2 = load(kit)
    p = osp.join(kit, 'README.md')
    old = read(p)
    new = update_readme(old, readme_sections(k2, graph(k2)))
    if new != old:
        with open(p, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(new)

def _references(kit, word, skip=()):
    rx = old_name_rx(word)
    hits = []
    for f in _git(kit, 'ls-files').stdout.splitlines():
        if f.startswith(GENERATED) or f in skip or not (f.lower().endswith(TEXT_EXT) or '.' not in osp.basename(f)):
            continue
        t = read(osp.join(kit, f))
        if f == PATHS_JSON:
            t = re.sub(r'"renamed":\s*\{[^}]*\}', '', t)
        for m in rx.finditer(t):
            hits.append(f'{f}:{t.count(chr(10), 0, m.start()) + 1}')
    return hits

PART_PATH = {'agent': 'agents/{}.md', 'skill': 'skills/{}', 'workflow': 'workflows/{}.js', 'rule': 'rules/{}.md'}

def _rename_id(kit, kind, old, new):
    """rename event E<n> E<m> | config-key a.b.old a.b.new (same parent): the row / key, the registry and every reference."""
    if kind == 'event':
        if not (re.fullmatch(r'E\d+', old) and re.fullmatch(r'E\d+', new)):
            sys.exit('kittool rename event: ids look like E5')
        man = manifest(kit) or {}
        if old not in man.get('events', []) or new in man.get('events', []):
            sys.exit(f'kittool rename event: {old} must be registered and {new} free')
        _edit_manifest(kit, lambda m: m.__setitem__('events', [new if x == old else x for x in m.get('events', [])]))
    else:
        po, pn = old.split('.'), new.split('.')
        if po[:-1] != pn[:-1]:
            sys.exit('kittool rename config-key: same parent only (a.b.old -> a.b.new)')

        def leaf(path):   # parse + rename in memory; both files parse before either is written
            d = json.loads(read(path))
            cur = d
            for x in po[:-1]:
                cur = cur.get(x) if isinstance(cur, dict) else None
            if not isinstance(cur, dict) or po[-1] not in cur or pn[-1] in cur:
                return None
            items = [(pn[-1] if x == po[-1] else x, v) for x, v in cur.items()]   # same place in the file
            cur.clear()
            cur.update(items)
            return d
        ex, loc = osp.join(kit, PATHS_JSON), osp.join(kit, PATHS_JSON.replace('example', 'local'))
        done = [(p, leaf(p)) for p in (ex, loc) if osp.exists(p)]
        if not done or done[0][1] is None:
            sys.exit(f'kittool rename config-key: {old} must exist in {PATHS_JSON} and {new} must not')
        for p, d in done:
            if d is not None:
                with open(p, 'w', encoding='utf-8', newline='\n') as fh:
                    fh.write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
                if p == loc:
                    print(f'migrated {osp.basename(loc)}: {old} -> {new}')
        for ln in _git(kit, 'grep', '-n', '-w', po[-1], '--', '*.ps1', '*.py', '*.js', '*.mjs').stdout.splitlines()[:20]:
            if old not in ln:
                print(f'WARN nested read? {ln[:160]} (renamed only dotted {old}: check by hand)')
    rx = re.compile(r'(?<![\w.-])' + re.escape(old) + r'(?![\w-]|\.\w)')
    for f in _git(kit, 'ls-files').stdout.splitlines():
        p = osp.join(kit, f)
        if f.startswith(GENERATED) or f == PATHS_JSON or not f.lower().endswith(TEXT_EXT) or not osp.isfile(p):
            continue
        with open(p, encoding='utf-8', errors='replace', newline='') as fh:
            raw = fh.read()
        t2 = rx.sub(new, raw)
        if t2 != raw:
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(t2)
            print(f'updated {f}')
    _regen(kit)
    print(f'renamed {kind} {old} -> {new}')
    return 0

NAME_RX = re.compile(r'^[A-Za-z0-9][\w.-]*$')   # an empty or path-like name would match whole folders (remove skill '')

def bad_names(names):
    return [n for n in names if not NAME_RX.match(n)]

def cmd_rename(a):
    """kittool.py rename agent|skill|workflow|rule|event|config-key <old> <new>: moves the part, rewrites every reference, updates
    the manifest (a part's old -> new joins _manifest.renamed; a config key also moves in kit.local.json), regenerates the ports."""
    kit = KIT_DIR
    if bad_names(a[1:3]):
        sys.exit(f'kittool rename: not a part name: {bad_names(a[1:3])}')
    if len(a) >= 3 and a[0] in ('event', 'config-key'):
        return _rename_id(kit, *a[:3])
    if len(a) < 3 or a[0] not in PART_PATH:
        print(cmd_rename.__doc__, file=sys.stderr)
        return 2
    kind, old, new = a[0], a[1], a[2]
    src, dst = PART_PATH[kind].format(old), PART_PATH[kind].format(new)
    if not osp.exists(osp.join(kit, src)) or osp.exists(osp.join(kit, dst)):
        sys.exit(f'kittool rename: {src} must exist and {dst} must not')
    r = _git(kit, 'mv', src, dst)
    if r.returncode:   # a part not committed yet (just made by new): a plain move
        try:
            shutil.move(osp.join(kit, src), osp.join(kit, dst))
        except OSError as x:
            sys.exit(f'kittool rename: {src} -> {dst} failed: {r.stderr.strip()} / {x}')
    rx = old_name_rx(old)
    for f in _git(kit, 'ls-files').stdout.splitlines():
        if f.startswith(GENERATED) or not (f.lower().endswith(TEXT_EXT) or '.' not in osp.basename(f)) or not osp.isfile(osp.join(kit, f)):
            continue
        if f == PATHS_JSON:
            continue   # manifest edited below (renamed map keeps the old name)
        p = osp.join(kit, f)
        with open(p, encoding='utf-8', errors='replace', newline='') as fh:
            raw = fh.read()
        t2 = rx.sub(lambda mt: mt.group(1) + new + mt.group(2), raw)   # keep joined prefix / suffix (last-<old>, <old>s)
        if t2 != raw:
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(t2)
            print(f'updated {f}')

    def m(man):
        sect = {'agent': 'agents', 'workflow': 'workflows'}.get(kind)
        if sect and old in (man.get(sect) or {}):
            man[sect] = {(new if x == old else x): v for x, v in man[sect].items()}
        if kind == 'skill':
            man['skills'] = sorted(new if x == old else x for x in man.get('skills', []))
        for w in (man.get('workflows') or {}).values():
            w['crew'] = [new if x == old else x for x in w.get('crew', [])]
        for ag in (man.get('agents') or {}).values():
            if ag.get('skill') == old:
                ag['skill'] = new
            ag['usedIn'] = [(f'/{new}' if x == f'/{old}' else x) for x in ag.get('usedIn', [])]
        ren = man.setdefault('renamed', {})
        for x, y in list(ren.items()):
            if y == old:
                ren[x] = new
        ren[old] = new
    _edit_manifest(kit, m)
    if kind == 'agent':
        _sub_file(kit, dst, lambda t: re.sub(r'^name: .*$', f'name: {new}', t, count=1, flags=re.M))
    _regen(kit)
    left = _references(kit, old)
    print(f'renamed {kind} {old} -> {new}' + (f'; references left: {", ".join(left[:10])}' if left else '; no reference left'))
    return 1 if left else 0

def cmd_remove(a):
    """kittool.py remove agent|skill|workflow|rule|event|config-key <name>: deletes the part, its registry entry and its Router /
    Events row; lists every reference left (exit 1 until none)."""
    kit = KIT_DIR
    if len(a) < 2:
        print(cmd_remove.__doc__, file=sys.stderr)
        return 2
    if bad_names(a[1:2]):
        sys.exit(f'kittool remove: not a part name: {bad_names(a[1:2])}')
    kind, name = a[0], a[1]
    if kind in PART_PATH:
        r = _git(kit, 'rm', '-rqf', PART_PATH[kind].format(name))
        if r.returncode:   # not committed yet: delete it from disk
            p = osp.join(kit, PART_PATH[kind].format(name))
            if not osp.exists(p):
                sys.exit(f'kittool remove: {r.stderr.strip()}')
            shutil.rmtree(p) if osp.isdir(p) else os.remove(p)
        target = {'agent': f'`{name}`', 'skill': f'`{name}`', 'workflow': f'`/{name}`', 'rule': None}[kind]
        gone = []
        if target:
            def fn(t):
                for l in t.split('\n'):
                    if re.match(r'^\|\s*R\d+\s*\|', l) and target in l.split('|')[3]:
                        gone.append(l.split('|')[1].strip())
                        t = t.replace(l + '\n', '', 1)
                return t
            _sub_file(kit, 'AGENTS.md', fn)

        def m(man):
            man.get('agents', {}).pop(name, None) if kind == 'agent' else None
            man.get('workflows', {}).pop(name, None) if kind == 'workflow' else None
            if kind == 'skill':
                man['skills'] = [x for x in man.get('skills', []) if x != name]
            man['router'] = [x for x in man.get('router', []) if x not in gone]
        _edit_manifest(kit, m)
    elif kind == 'event':
        _sub_file(kit, 'skills/orchestrate/SKILL.md', lambda t: re.sub(r'^\|\s*' + re.escape(name) + r'\s*\|.*\n', '', t, count=1, flags=re.M))
        _edit_manifest(kit, lambda man: man.__setitem__('events', [x for x in man.get('events', []) if x != name]))
    elif kind == 'config-key':
        p = osp.join(kit, PATHS_JSON)
        d = json.loads(read(p))
        cur = d
        for x in name.split('.')[:-1]:
            cur = cur.get(x) if isinstance(cur, dict) else None
        if not isinstance(cur, dict) or name.split('.')[-1] not in cur:
            sys.exit(f'kittool remove: no config key {name} in {PATHS_JSON}')
        cur.pop(name.split('.')[-1])
        with open(p, 'w', encoding='utf-8', newline='\n') as fh:
            fh.write(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
        _sub_file(kit, 'README.md', lambda t: re.sub(r'^\| `' + re.escape(name) + r'` \|.*\n', '', t, count=1, flags=re.M))
    else:
        print(cmd_remove.__doc__, file=sys.stderr)
        return 2
    _regen(kit)
    left = _references(kit, name.split('.')[-1] if kind == 'config-key' else name)
    print(f'removed {kind} {name}' + (f'; references left (fix them): {", ".join(left[:12])}' if left else '; no reference left'))
    return 1 if left else 0


COMMANDS = {'new': cmd_new, 'rename': cmd_rename, 'remove': cmd_remove}
ARGS = {'new': (set(), {'--crew', '--skill'}, False), 'rename': (set(), set(), False), 'remove': (set(), set(), False)}
