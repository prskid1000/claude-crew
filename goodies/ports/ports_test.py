"""ports_test.py (goody ports): kitbag_ports internals. Usage: python -X utf8 ports_test.py <kitbag.py> <kitbag_ports.py>"""
import ast, asyncio, base64, contextlib, importlib.util, io, json, re, shutil, sys, tempfile, tomllib
from pathlib import Path

def load(name, path, shared=None):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    m.__dict__.update(shared or {})
    spec.loader.exec_module(m)
    return m

kt = load('kitbag', sys.argv[1])
pt = load('kitbag_ports', sys.argv[2], {n: v for n, v in vars(kt).items() if not n.startswith('__')})
tmp = Path(tempfile.mkdtemp())
# TOML / YAML: a quote and a backslash in a description stay valid; LF only
pt.CODEX_AGENTS = tmp / 'c'; pt.GRAVITY_AGENTS = tmp / 'g'; pt.CODEX_AGENTS.mkdir(); pt.GRAVITY_AGENTS.mkdir()
d = 'say "hi" C:\\x'
pt.write_codex('a', {'description': d}, 'body'); pt.write_gravity('a', {'description': d}, 'body')
ok_toml = tomllib.loads((tmp / 'c' / 'a.toml').read_text(encoding='utf-8'))['description'] == d and b'\r\n' not in (tmp / 'c' / 'a.toml').read_bytes()
# port_deploy keeps user files, removes only stale generated ports
kit = tmp / 'ws' / '.claude'
for p in ('.codex/agents/a.toml', '.agents/agents/a.md', 'AGENTS.md', 'GEMINI.md'):
    (kit / p).parent.mkdir(parents=True, exist_ok=True); (kit / p).write_text('x', encoding='utf-8')
ws = kit.parent
for p in ('.codex/config.local.toml', '.codex/agents/old.toml', '.agents/agents/mine.txt'):
    (ws / p).parent.mkdir(parents=True, exist_ok=True); (ws / p).write_text('user', encoding='utf-8')
(ws / '.codex/agents/old.toml').write_text('> Ported note: an old port', encoding='utf-8'); (ws / '.agents/agents/own.md').write_text('mine', encoding='utf-8')
pt.KIT, pt.WORKSPACE = kit, ws
with contextlib.redirect_stdout(io.StringIO()):
    pt.port_deploy()
ok_deploy = (ws / '.codex/config.local.toml').exists() and (ws / '.agents/agents/mine.txt').exists() and (ws / '.agents/agents/own.md').exists() and not (ws / '.codex/agents/old.toml').exists() \
    and (ws / '.codex/agents/a.toml').read_text(encoding='utf-8') == 'x' and pt.deployed_stale() == []
# owner decisions: blocking -> the native tool where it exists (Codex request_user_input in Plan mode, Antigravity ask_question
# only when listed), the text otherwise; FYI -> a numbered list; ported agents say a subagent never asks the user
f = {'name': 'w', 'description': 'd', 'phases': []}
cx, ag = pt.workflow_procedure_doc(f, 'Codex', 'h'), pt.workflow_procedure_doc(f, 'Antigravity', 'h')
pt.write_codex('b', {'description': 'd'}, 'body\n' + pt.AGENT_DECIDE)
ok_ask = all(x in cx for x in ('## Owner decisions', '`request_user_input`', 'Plan mode', '-Ask -Json -Max 3', 'decide list -Fyi', 'decide list -Ask` (question', "payload's `ids` in order", 'missing from `ids`', 'at most 3')) \
    and 'only when `ask_question` is in your tool list' in ag and 'decide list -Fyi' in ag and 'request_user_input' not in ag \
    and 'never asks the user directly' in tomllib.loads((tmp / 'c' / 'b.toml').read_text(encoding='utf-8'))['developer_instructions']
print(f'ports-ask:{ok_ask}')
print(f'ports-escape:{ok_toml}')
print(f'ports-deploy:{ok_deploy}')

# hooks: absolute paths, no double quotes (agy's cmd /c keeps them in the path), Codex cleanup async, agy cleanup detached hidden
cx = tomllib.loads(pt.codex_config_text('D:/w/.claude'))
cmds = [h['command'] for g in cx['hooks']['SessionStart'] + cx['hooks']['PreToolUse'] for h in g['hooks']]
ag = json.loads(pt.gravity_hooks_text('D:/w/.claude', True)); agx = json.loads(pt.gravity_hooks_text('/w/.claude', False))
agc = [h['command'] for h in ag['kit-health']['SessionStart']] + [h['command'] for h in ag['guard']['PreToolUse'][0]['hooks']]
ok_hooks = all('D:/w/.claude/skills/' in c and '"' not in c for c in cmds + agc) and cx['hooks']['SessionStart'][1]['hooks'][0].get('async') is True \
    and cx['shell_environment_policy']['set']['KIT_TOOL'] == 'codex' and agc[1].count('-WindowStyle Hidden') == 2 and agc[1].endswith("'{}'") \
    and agx['kit-health']['SessionStart'][1]['command'].startswith('nohup ') and base64.b64decode(pt.hook_cmd(pt.GUARD, "C:/a b'c/.claude").split()[-1]).decode('utf-16-le') == "& 'C:/a b''c/.claude/skills/crafty/crafty.ps1' guard" \
    and not re.search(r'["&]', pt.hook_cmd(pt.GUARD, "C:/a b'c/.claude")) and not re.search(r'["&]', pt.detached(pt.hook_cmd(pt.CLEANUP, 'C:/a b/.claude'), True))
print(f'ports-hooks:{ok_hooks}')
# workspace: skill links, org rules (agy always-on, split under 24 KB; Codex AGENTS.override.md), nothing org-only in the kit
kit2 = tmp / 'ws2' / '.claude'; ws2 = kit2.parent
for p2, txt in (('skills/s1/SKILL.md', 'x'), ('AGENTS.md', 'shared'), ('GEMINI.md', 'g'), ('rules/org.local.md', 'r' * 30 + '\n' + ('line\n' * 6000)), ('rules/pub.md', 'p')):
    (kit2 / p2).parent.mkdir(parents=True, exist_ok=True); (kit2 / p2).write_text(txt, encoding='utf-8')
pt.KIT, pt.WORKSPACE = kit2, ws2
with contextlib.redirect_stdout(io.StringIO()):
    pt.port_deploy()
rules = sorted(p.name for p in (ws2 / '.agents/rules').glob('*.md'))
ok_ws = (ws2 / '.agents/skills/s1/SKILL.md').read_text(encoding='utf-8') == 'x' and rules == ['org.local-1.md', 'org.local-2.md'] \
    and all(len((ws2 / '.agents/rules' / r).read_bytes()) <= 24000 and 'trigger: always_on' in (ws2 / '.agents/rules' / r).read_text(encoding='utf-8') for r in rules) \
    and (ws2 / 'AGENTS.override.md').read_text(encoding='utf-8').startswith('shared') and 'rrrrrrrrrr' in (ws2 / 'AGENTS.override.md').read_text(encoding='utf-8') \
    and not list(kit2.rglob('AGENTS.override.md')) and pt.deployed_stale() == []
print(f'ports-workspace:{ok_ws}')
# run_workflow bridge: the kit's .js runs under node; its agent() calls become Antigravity agents (type, role, workspace inherit)
wfd = kit2 / 'workflows'; wfd.mkdir(exist_ok=True)
(wfd / 't.js').write_text("export const meta = {\n name: 't',\n}\nphase('P'); log('hi', args.n)\n"
  "const [x, y] = await pipeline([1], (i) => agent('p1', { label: 'a', agentType: 'devy' }), async (r, i) => [r, await agent('p2', { label: 'b', model: 'haiku' })]).then((v) => v[0])\n"
  "return { x, y, z: await agent('boom', { label: 'c' }) }\n", encoding='utf-8')
calls, logs = [], []
async def fake_agent(prompt, schema=None, role=None, type_name='self', workspace='branch', model=None):
    calls.append((role, type_name, workspace, model))
    if prompt == 'boom':
        raise RuntimeError('no finish')
    return {'got': prompt}
src = pt.RUNNER.format(name='t', shim=pt.SHIM, description='d', when='w')
g = {'args': {'n': 7}, 'agent': fake_agent, 'phase': lambda n: logs.append(n), 'log': lambda *a: logs.append(' '.join(map(str, a))), 'WORKSPACES': (str(ws2),)}
out = io.StringIO()
with contextlib.redirect_stdout(out):
    asyncio.run(eval(compile(src, 'wf', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), g))
res = json.loads(out.getvalue().strip().splitlines()[-1]) if shutil.which('node') else None
(wfd / 'u.js').write_text("export const meta = {\n name: 'u',\n}\nconst = \n", encoding='utf-8')
g2 = dict(g, args={})
try:
    with contextlib.redirect_stdout(io.StringIO()):
        asyncio.run(eval(compile(pt.RUNNER.format(name='u', shim=pt.SHIM, description='d', when='w'), 'wf2', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), g2))
    bad_ok = False
except RuntimeError as e:
    bad_ok = 'SyntaxError' in str(e) or 'without a result' in str(e)
ok_wf = res is None or bad_ok and (res == {'x': {'got': 'p1'}, 'y': {'got': 'p2'}, 'z': None} and ('a', 'devy', 'inherit', 'inherit') in calls
    and ('b', 'self', 'inherit', 'flash') in calls and logs[:2] == ['P', 'hi 7'])
print(f'ports-workflow:{ok_wf}')

# ports.targets: every transition keeps the chosen target's copies and removes only the kit-written rest
kit3 = tmp / 'ws3' / '.claude'; ws3 = kit3.parent
for p3, txt in (('skills/s1/SKILL.md', 'x'), ('AGENTS.md', 'shared'), ('GEMINI.md', 'g'), ('.codex/agents/a.toml', 'c'), ('.agents/agents/a.md', 'ag')):
    (kit3 / p3).parent.mkdir(parents=True, exist_ok=True); (kit3 / p3).write_text(txt, encoding='utf-8')
pt.KIT, pt.WORKSPACE = kit3, ws3
conf3 = {}
pt.local_config = lambda k, f: {'ports': dict(conf3)}
def deploy(t, **extra):
    conf3.clear(); conf3.update(targets=t, **extra)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        pt.port_deploy()
    return out.getvalue()
WANT = {'both': {'AGENTS.md', 'AGENTS.override.md', 'GEMINI.md', '.codex/agents/a.toml', '.agents/agents/a.md', '.agents/skills/s1'},
  'codex': {'AGENTS.md', 'AGENTS.override.md', '.codex/agents/a.toml', '.agents/skills/s1'},
  'antigravity': {'AGENTS.md', 'GEMINI.md', '.agents/agents/a.md'}, 'none': set()}
ALL = set().union(*WANT.values())
bad_tr = []
for a, b in (('both', 'none'), ('both', 'codex'), ('both', 'antigravity'), ('codex', 'both'), ('antigravity', 'both'), ('none', 'both'),
             ('codex', 'antigravity'), ('antigravity', 'codex'), ('codex', 'none'), ('antigravity', 'none')):
    deploy(a); deploy(b)
    have = {r for r in ALL if (ws3 / r).exists()}
    if have != WANT[b] or pt.deployed_stale() != [] or (b == 'none' and ((ws3 / '.codex').exists() or (ws3 / '.agents').exists())):
        bad_tr.append(f'{a}->{b}: {sorted(have ^ WANT[b])} {pt.deployed_stale()}')
print(f'ports-targets:{not bad_tr} {bad_tr}')
# a deselected folder: empty -> gone; clutter only -> gone; an authored file -> folder kept, file kept and listed
deploy('both')
for c in ('Thumbs.db', 'x.swp', 'a~', 'n.bak', 'm.orig', 'r.log', 'q.tmp', 'q.temp', 'tmp/a', 'temp/b', 'cache/c', 'log/d', 'logs/e', 'sessions/s.jsonl', 'history.jsonl', 'empty.toml'):
    (ws3 / '.codex' / c).parent.mkdir(parents=True, exist_ok=True); (ws3 / '.codex' / c).write_text('' if c == 'empty.toml' else 'z', encoding='utf-8')
(ws3 / '.agents' / 'mine.toml').write_text('hand', encoding='utf-8')
out_nf = deploy('none')
ok_folders = not (ws3 / '.codex').exists() and (ws3 / '.agents' / 'mine.toml').read_text(encoding='utf-8') == 'hand' \
    and not (ws3 / '.agents' / 'agents').exists() and '.agents/mine.toml' in out_nf and 'removed:' in out_nf and pt.deployed_stale() == []
(ws3 / '.agents' / 'mine.toml').unlink()
deploy('none')
ok_folders = ok_folders and not (ws3 / '.agents').exists()
# ports.clutter replaces the default list
deploy('both'); (ws3 / '.codex' / 'x.keep').write_text('z', encoding='utf-8'); (ws3 / '.codex' / 'Thumbs.db').write_text('z', encoding='utf-8')
out_cl = deploy('none', clutter=['*.keep'])
ok_clutter = (ws3 / '.codex' / 'Thumbs.db').exists() and '.codex/Thumbs.db' in out_cl and '.codex/x.keep' not in out_cl \
    and all(pt.is_clutter(c, 1, pt.CLUTTER) for c in ('a/Thumbs.db', 'a/x.swp', 'a/b~', 'a/n.bak', 'a/r.log', 'a/tmp/x.toml', 'a/history/h.md')) \
    and not any(pt.is_clutter(c, 1, pt.CLUTTER) for c in ('a/mine.toml', 'a/notes.md', 'a/k.rules', 'a/run.py', 'a/c.json'))
shutil.rmtree(ws3 / '.codex', ignore_errors=True)
# a copy an older kit wrote (no header, other bytes): the manifest of the last deploy marks it kit-written
deploy('both'); (kit3 / '.agents/agents/a.md').write_text('ag v2', encoding='utf-8')
deploy('codex')
ok_manifest = not (ws3 / '.agents/agents/a.md').exists() and (ws3 / '.agents/skills/s1').exists()
print(f'ports-folders:{ok_folders and ok_clutter and ok_manifest} {ok_folders} {ok_clutter} {ok_manifest}')
