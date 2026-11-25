"""ports_test.py: kitbag_ports internals, run by tests/ports.tests.ps1. Usage: python -X utf8 ports_test.py <kitbag.py> <kitbag_ports.py>
Prints one `<case>:<True|False>` line per check. Exit codes: 0 always (ports.tests.ps1 reads the lines)."""
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
pt.local_config = lambda k, f: {}
ok_off = pt.port_targets(pt.ports_conf()) == () and pt.port_targets({'targets': 'bogus'}) == ()   # unset or unknown: off (owner 2026-11-22)
pt.manifest_file().parent.mkdir(parents=True, exist_ok=True); pt.manifest_file().write_text(json.dumps({'files': {'.codex/config.toml': 'x', 'AGENTS.md': 'y'}}), encoding='utf-8')
ok_off = ok_off and pt.port_targets(pt.ports_conf()) == ('codex',)   # unset, deployed before (old default both): kept until set
pt.local_config = lambda k, f: {'ports': {'targets': 'none'}}
ok_off = ok_off and pt.port_targets(pt.ports_conf()) == ()
pt.manifest_file().unlink()
pt.local_config = lambda k, f: {'ports': {'targets': 'both'}}
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
print(f'ports-default-off:{ok_off}')

# hooks: absolute paths, no double quotes (agy's cmd /c keeps them in the path), Codex cleanup async, agy cleanup detached hidden
cx = tomllib.loads(pt.codex_config_text('D:/w/.claude'))
cmds = [h['command'] for g in cx['hooks']['SessionStart'] + cx['hooks']['PreToolUse'] for h in g['hooks']]
ag = json.loads(pt.gravity_hooks_text('D:/w/.claude', True)); agx = json.loads(pt.gravity_hooks_text('/w/.claude', False))
agc = [h['command'] for h in ag['kit-health']['SessionStart']] + [h['command'] for h in ag['guard']['PreToolUse'][0]['hooks']]
# Codex PreToolUse (parity): shell, apply_patch and MCP SQL tools reach the guard; other MCP tools do not
cxm = re.compile(cx['hooks']['PreToolUse'][0]['matcher'])
print(f"ports-codex-mcp:{all(cxm.search(t) for t in ('Bash', 'apply_patch', 'mcp__db__run_sql', 'mcp__pg__query')) and not cxm.search('mcp__docs__search')}")
# parity: both run guard_client.mjs for reads / MCP (Codex: its one PreToolUse; agy: view_file, call_mcp_tool, eager mcp_*), run_command keeps crafty.ps1 guard
agm, gnode = re.compile(ag['guard']['PreToolUse'][1]['matcher']), 'node D:/w/.claude/skills/crafty/guard_client.mjs'
spaced = base64.b64decode(pt.node_hook_cmd(pt.GUARD_NODE, 'C:/a b/.claude').split()[-1]).decode('utf-16-le')
ok_gr = cx['hooks']['PreToolUse'][0]['hooks'][0]['command'] == gnode and ag['guard']['PreToolUse'][0]['matcher'] == 'run_command' \
    and all(agm.fullmatch(t) for t in ('view_file', 'call_mcp_tool', 'mcp_db_run_sql')) and not agm.fullmatch('run_command') \
    and ag['guard']['PreToolUse'][1]['hooks'][0]['command'] == gnode and spaced == "[Console]::In.ReadToEnd() | & node 'C:/a b/.claude/skills/crafty/guard_client.mjs'"
print(f"ports-guard-reads:{ok_gr}")
# parity: agy agents get the mapped tools list (+ call_mcp_tool); a tool with no agy name (WebFetch) leaves it unset
print(f"ports-agy-tools:{pt.gravity_tools('Read, Grep, Glob, Bash') == ['view_file', 'grep_search', 'find_by_name', 'list_dir', 'run_command', 'call_mcp_tool'] and pt.gravity_tools('Read, WebFetch') is None and pt.gravity_tools('') is None}")
ok_hooks = all('D:/w/.claude/skills/' in c and '"' not in c for c in cmds + agc) and cx['hooks']['SessionStart'][1]['hooks'][0].get('async') is True \
    and cx['hooks']['SessionStart'][2]['hooks'][0].get('async') is True and 'health -Flow -Fetch' in agc[2] and agc[2].count('-WindowStyle Hidden') == 2 \
    and cx['shell_environment_policy']['set']['KIT_TOOL'] == 'codex' and agc[1].count('-WindowStyle Hidden') == 2 and agc[1].endswith("'{}'") \
    and agx['kit-health']['SessionStart'][1]['command'].startswith('nohup ') and base64.b64decode(pt.hook_cmd(pt.GUARD, "C:/a b'c/.claude").split()[-1]).decode('utf-16-le') == "& 'C:/a b''c/.claude/skills/crafty/crafty.ps1' guard" \
    and not re.search(r'["&]', pt.hook_cmd(pt.GUARD, "C:/a b'c/.claude")) and not re.search(r'["&]', pt.detached(pt.hook_cmd(pt.CLEANUP, 'C:/a b/.claude'), True))
print(f'ports-hooks:{ok_hooks}')
# the kit's own copy (relative kit): found from any cwd under the workspace, exit codes kept; outside it: exit 2 (fail-closed)
import subprocess
rk = tmp / 'rw' / '.claude' / 'skills'; (rk / 'bossy').mkdir(parents=True); (rk / 'crafty').mkdir(parents=True); (tmp / 'rw' / 'a' / 'b').mkdir(parents=True); (tmp / 'out').mkdir()
(rk / 'bossy' / 'bossy.ps1').write_text('param([switch]$IfDue, [switch]$Quiet, [Parameter(ValueFromRemainingArguments)]$Rest)\n"bossy $Rest $IfDue $Quiet"\ngit nonexist 2>$null\n', encoding='utf-8')   # a leaked native exit code: still 0, as -File
(rk / 'crafty' / 'crafty.ps1').write_text('"crafty $args " + [Console]::In.ReadToEnd()\nexit 2\n', encoding='utf-8')
(rk / 'crafty' / 'guard_client.mjs').write_text("import { readFileSync } from 'node:fs'\nprocess.stdout.write('node ' + readFileSync(0, 'utf8')); process.exit(2)\n", encoding='utf-8')
hrun = lambda cmd, cwd: subprocess.run(cmd, shell=True, cwd=cwd, input='{"x":1}', capture_output=True, text=True, timeout=60)
deep = tmp / 'rw' / 'a' / 'b'
r1, r2, r3 = hrun(pt.hook_cmd(pt.CLEANUP, '.claude'), deep), hrun(pt.hook_cmd(pt.GUARD, '.claude'), deep), hrun(pt.node_hook_cmd(pt.GUARD_NODE, '.claude'), tmp / 'rw' / '.claude')
r4 = hrun(pt.found_cmd('.claude-zz/skills/crafty/crafty.ps1 guard'), tmp / 'out')   # tmp may sit under a real kit: a name none has
ok_rel = r1.stdout.strip() == 'bossy cleanup True True' and r1.returncode == 0 and (r2.returncode, r2.stdout.strip()) == (2, 'crafty guard {"x":1}') \
    and (r3.returncode, r3.stdout.strip()) == (2, 'node {"x":1}') and r4.returncode == 2 and 'not found' in r4.stderr \
    and all('"' not in c for c in (pt.hook_cmd(pt.GUARD, '.claude'), pt.node_hook_cmd(pt.GUARD_NODE, '.claude')))
print(f'ports-hooks-cwd:{ok_rel}' + ('' if ok_rel else f' {[(r.returncode, r.stdout[-120:], r.stderr[-160:]) for r in (r1, r2, r3, r4)]}'))
# workspace: skill links, org rules (agy always-on, split under 24 KB; Codex AGENTS.override.md), nothing org-only in the kit
kit2 = tmp / 'ws2' / '.claude'; ws2 = kit2.parent
for p2, txt in (('skills/s1/SKILL.md', 'x'), ('AGENTS.md', 'shared'), ('GEMINI.md', 'g'), ('rules/org.local.md', 'r' * 30 + '\n' + ('line\n' * 6000)), ('rules/pub.md', 'p')):
    (kit2 / p2).parent.mkdir(parents=True, exist_ok=True); (kit2 / p2).write_text(txt, encoding='utf-8')
pt.KIT, pt.WORKSPACE = kit2, ws2
with contextlib.redirect_stdout(io.StringIO()):
    pt.port_deploy()
rules = sorted(p.name for p in (ws2 / '.agents/rules').glob('*.md') if p.name != 'kit-test-logins.md')
ok_ws = (ws2 / '.agents/skills/s1/SKILL.md').read_text(encoding='utf-8') == 'x' and rules == ['org.local-1.md', 'org.local-2.md'] \
    and all(len((ws2 / '.agents/rules' / r).read_bytes()) <= 24000 and 'trigger: always_on' in (ws2 / '.agents/rules' / r).read_text(encoding='utf-8') for r in rules) \
    and (ws2 / 'AGENTS.override.md').read_text(encoding='utf-8').startswith('shared') and 'rrrrrrrrrr' in (ws2 / 'AGENTS.override.md').read_text(encoding='utf-8') \
    and not list(kit2.rglob('AGENTS.override.md')) and pt.deployed_stale() == []
print(f'ports-workspace:{ok_ws}')
# run_workflow bridge: the kit's .js runs under node; its agent() calls become Antigravity agents (type, role, workspace inherit)
wfd = kit2 / 'workflows'; wfd.mkdir(exist_ok=True)
(wfd / 't.js').write_text("export const meta = {\n name: 't',\n}\nphase('P'); log('hi', args.n)\n"
  "const [x, y] = await pipeline([1], (i) => agent('p1', { label: 'a', agentType: 'devy', phase: 'Q' }), async (r, i) => [r, await agent('p2', { label: 'b', model: 'haiku', effort: 'low' })]).then((v) => v[0])\n"
  "return { x, y, z: await agent('boom', { label: 'c' }) }\n", encoding='utf-8')
calls, logs = [], []
async def fake_agent(prompt, schema=None, role=None, type_name='self', workspace='branch', model=None):
    calls.append((role, type_name, workspace, model))
    if prompt == 'boom':
        raise RuntimeError('no finish')
    return {'got': prompt}
RF = {'shim': pt.SHIM, 'description': 'd', 'when': 'w'}
(kit2 / 'skills/bossy').mkdir(parents=True, exist_ok=True); shutil.copy(sys.argv[1], kit2 / 'skills/bossy'); shutil.copytree(Path(sys.argv[1]).parents[1] / 'crafty', kit2 / 'skills/crafty', dirs_exist_ok=True, ignore=lambda d, n: [x for x in n if x != 'kit.example.json'])
src = pt.RUNNER.format(name='t', **RF)
g = {'args': {'n': 7}, 'agent': fake_agent, 'phase': lambda n: logs.append(n), 'log': lambda *a: logs.append(' '.join(map(str, a))), 'WORKSPACES': (str(ws2),)}
out = io.StringIO()
with contextlib.redirect_stdout(out):
    asyncio.run(eval(compile(src, 'wf', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), g))
res = json.loads(out.getvalue().strip().splitlines()[-1]) if shutil.which('node') else None
(wfd / 'u.js').write_text("export const meta = {\n name: 'u',\n}\nconst = \n", encoding='utf-8')
g2 = dict(g, args={})
try:
    with contextlib.redirect_stdout(io.StringIO()):
        asyncio.run(eval(compile(pt.RUNNER.format(name='u', **RF), 'wf2', 'exec', flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), g2))
    bad_ok = False
except RuntimeError as e:
    bad_ok = 'SyntaxError' in str(e) or 'without a result' in str(e)
ok_wf = res is None or bad_ok and (res == {'x': {'got': 'p1'}, 'y': {'got': 'p2\n(Reasoning effort for this step: low.)'}, 'z': None}
    and ('a', 'devy', 'inherit', 'inherit') in calls and ('b', 'self', 'inherit', 'flash') in calls and logs[:2] == ['P', 'hi 7'] and 'Q' in logs)
print(f'ports-workflow:{ok_wf}')
# the runner's journal (Runs band, recover): launched, started + result per agent (label, phase), done on success only
jl = sorted((Path(pt.kit_path('port-runs', kit=str(kit2))) / 'antigravity/subagents/workflows').glob('wf_agy-*/journal.jsonl'), key=lambda p: p.stat().st_mtime)
ev = [json.loads(l) for l in jl[0].read_text(encoding='utf-8').splitlines()] if jl else []
ok_jl = not shutil.which('node') or (len(jl) == 2 and ev[0]['type'] == 'launched' and ev[-1]['type'] == 'done'
    and any(e['type'] == 'started' and e['label'] == 'a' and e['phase'] == 'Q' for e in ev) and sum(e['type'] == 'result' for e in ev) == 3
    and '"done"' not in jl[1].read_text(encoding='utf-8') and '"finished"' in jl[1].read_text(encoding='utf-8'))
print(f'ports-journal:{ok_jl}')
# Codex: the engine's gates in each procedure doc, every anchor still in its .js; autonomous config; workspace-write agents; test logins
kroot = Path(sys.argv[2]).resolve().parents[2]
def gdoc(n):
    js = (kroot / 'workflows' / f'{n}.js').read_text(encoding='utf-8')
    g, gone = pt.workflow_gates(n, js)
    return pt.workflow_procedure_doc(pt.workflow_meta(js), 'Codex', 'h', g), gone
(bd, bg), (td, tg), (_, yg) = gdoc('buildy'), gdoc('testy'), gdoc('tidy')
ok_gates = not (bg or tg or yg) and pt.workflow_gates('buildy', '')[1] and all(x in bd for x in ("decide check -Id <id> -Gate 'merge,scope,other'",
    "--no-docs 'foundation", '`holdMerge`', '`args.batch`', 'budget -Run', 'launch -Self -Script buildy.js', 'TASKS REFUSED')) \
    and all(x in td for x in ('`select.tasks` = exactly', 'another product', 'budget -Run', 'finalize -RunDir')) and '## Before any phase' in bd
cfg = tomllib.loads(pt.codex_config_text('D:/w/.claude'))
pt.write_codex('r', {'description': 'd', 'tools': 'Read, Bash'}, 'body'); pt.write_codex('k', {'description': 'd', 'tools': 'Read, Edit, Write'}, 'body')
rv, kv = (tomllib.loads((tmp / 'c' / f'{n}.toml').read_text(encoding='utf-8')) for n in ('r', 'k'))
ok_cx = cfg['approval_policy'] == 'never' and cfg['sandbox_mode'] == 'workspace-write' and cfg['sandbox_workspace_write']['network_access'] is True \
    and cfg['features']['memories'] is False and 'prefix_rule(pattern=["git", ["commit", "push", "merge"], "--no-verify"], decision="forbidden"' in pt.CODEX_RULES_TEXT \
    and 'prefix_rule(pattern=["git", "commit", ["-n",' in pt.CODEX_RULES_TEXT and not re.search(r'"push"[^\n]*"-n"', pt.CODEX_RULES_TEXT) \
    and rv['sandbox_mode'] == kv['sandbox_mode'] == 'workspace-write' and 'edit no file outside' in rv['developer_instructions'] and 'edit no file' not in kv['developer_instructions']
# Codex execpolicy: a literal argv prefix per rule; each command is forbidden or not (live check 26c9bd6d: flags later in argv got past)
cx_rules = [(ast.literal_eval(m.group(1)), m.group(2)) for m in re.finditer(r'prefix_rule\(pattern=(\[.*?\]), decision="(\w+)"', pt.CODEX_RULES_TEXT)]
cx_ds = lambda argv: {d for pat, d in cx_rules if len(argv) >= len(pat) and all(a == p or (isinstance(p, list) and a in p) for a, p in zip(argv, pat))}
cx_hit = lambda argv: next((d for d in ('forbidden', 'allow') if d in cx_ds(argv)), 'none')   # the strictest match wins
cx_cases = {'git commit --no-verify': 'forbidden', 'git commit -a --no-verify': 'forbidden', 'git commit --amend --no-edit --no-verify': 'forbidden',
  'git push origin --no-verify': 'forbidden', 'git push -u origin --no-verify': 'forbidden', 'git commit -n': 'forbidden', 'git stash': 'forbidden',
  'type skills\\pokey\\targets.local.json': 'forbidden', 'Get-Content -Raw ./skills/pokey/targets.local.json': 'forbidden', 'Select-String -Path .claude/skills/pokey/targets.local.json x': 'forbidden',
  'cp skills/pokey/targets.local.json x': 'forbidden', 'git commit -a -m x': 'none', 'git status': 'allow', 'cat skills/pokey/targets.example.json': 'none', 'Get-Content -Raw README.md': 'none'}
cx_bad = [c for c, want in cx_cases.items() if cx_hit(c.split()) != want]
print(f'ports-codex-policy:{not cx_bad} {cx_bad}')
lg = (ws2 / '.agents/rules/kit-test-logins.md').read_text(encoding='utf-8')
ok_logins = lg.startswith('---\ntrigger: always_on\n---\n') and 'targets.local.json' in lg \
    and all(f'prefix_rule(pattern=["{c}", ["skills/pokey/targets.local.json"' in pt.CODEX_RULES_TEXT for c in ('cat', 'type', 'Get-Content')) and 'decision="forbidden"' in pt.CODEX_RULES_TEXT
# port --check: a gate whose anchor left the .js, or whose phase is not in meta.phases, is stale
kit4 = tmp / 'kit4'; (kit4 / 'workflows').mkdir(parents=True)
(kit4 / 'workflows' / 'tidy.js').write_text("export const meta = {\n name: 'tidy',\n description: 'd',\n phases: [\n  { title: 'Prep', detail: 'p' },\n ],\n}\n", encoding='utf-8')
pt.KIT = kit4
for n4, r4 in (('CODEX_AGENTS', '.codex/agents'), ('GRAVITY_AGENTS', '.agents/agents'), ('CODEX_CONFIG', '.codex/config.toml'), ('CODEX_RULES', '.codex/rules/kit.rules'),
               ('GRAVITY_HOOKS', '.agents/hooks.json'), ('GRAVITY_SKILLS', '.agents/skills.json'), ('CODEX_WORKFLOWS', '.codex/workflows'), ('GRAVITY_WORKFLOWS', '.agents/kit-workflows')):
    setattr(pt, n4, kit4 / r4)
with contextlib.redirect_stdout(io.StringIO()):
    st4 = pt.check_stale()
ok_gates = ok_gates and any('tidy.js gate anchor gone: launch' in x for x in st4) and 'tidy.js gate phase unknown: Judge' in st4 \
    and all("-Plan '" in d and '-Fnv' in d for d in (bd, td))
print(f'ports-codex:{bool(ok_gates and ok_cx and ok_logins)} {bool(ok_gates)} {ok_cx} {ok_logins}')

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
(ws3 / '.agents' / 'mine.toml').write_text('hand: exported notes, an imported note, an exported procedure', encoding='utf-8')
out_nf = deploy('none')
ok_folders = not (ws3 / '.codex').exists() and (ws3 / '.agents' / 'mine.toml').read_text(encoding='utf-8').startswith('hand') \
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
# crew tool allowlists (owner 2026-11-24): toolSets expand, grants only in an installed kit, the filter strips them, MCP coverage line
tk = tmp / 'tw' / '.claude'; (tk / 'skills' / 'crafty').mkdir(parents=True); (tk / 'agents').mkdir()
(tk / 'skills' / 'crafty' / 'kit.example.json').write_text(json.dumps({'_manifest': {'toolSets': {'crew': 'Read, Bash'}, 'agents': {
    'da': {'tools': 'crew, Agent'}, 'rv': {'tools': 'Read, Grep'}}}}), encoding='utf-8')
grants = {'tools': {'roles': {'da': ['mcp__db', 'Read']}, 'mainOnly': ['quiet']}}
kt.local_config = lambda k, f: grants
src_t = '---\r\nname: da\r\ndescription: "d"\r\ndisallowedTools: Skill, Workflow\r\nmodel: sonnet\r\n---\r\nspawn `vidy` with it\r\n'
live = kt.set_tools_line(src_t, kt.role_tools('da', str(tk), True))
ok_t = kt.role_tools('da', str(tk)) == 'Read, Bash, Agent' and live == src_t.replace('disallowedTools: Skill, Workflow', 'tools: Read, Bash, Agent, mcp__db') \
    and kt.role_tools('nope', str(tk)) is None and kt.tools_live(str(tk)) and not kt.tools_live(str(tmp / 'tw' / 'x-.claude')) \
    and kt.set_tools_line('---\nname: rv\n---\nb', 'Read') == '---\nname: rv\ntools: Read\n---\nb'
class Pipe:
    def __init__(self, b=b''):
        self.buffer = io.BytesIO(b)
def run_filter(mode, text):
    old, pt.KIT_DIR = (sys.stdin, sys.stdout, pt.KIT_DIR), str(tk)
    sys.stdin, sys.stdout = Pipe(text.encode('utf-8')), Pipe()
    try:
        pt.tools_filter(mode, 'agents/da.md')
        return sys.stdout.buffer.getvalue().decode('utf-8')
    finally:
        sys.stdin, sys.stdout, pt.KIT_DIR = old
ok_f = run_filter('clean', live) == src_t.replace('disallowedTools: Skill, Workflow', 'tools: Read, Bash, Agent') and run_filter('smudge', src_t) == live \
    and run_filter('clean', 'no front matter\n') == 'no front matter\n'
broken, pt.role_tools = pt.role_tools, lambda *x: 1 / 0   # a failing clean still drops the mcp__ grants (fail closed)
ok_f = ok_f and run_filter('clean', live) == live.replace(', mcp__db', '') and run_filter('smudge', live) == live
pt.role_tools = broken
grants['tools']['roles']['da'].append('x\r\ntools: Bash')   # a grant with a line break: dropped
ok_f = ok_f and kt.role_tools('da', str(tk), True) == 'Read, Bash, Agent, mcp__db'
ok_n = kt.tools_named('spawn `vidy` (R19)') == ['Agent'] and kt.tools_named('a vidy that cannot spawn reads') == [] \
    and kt.tools_named('WebSearch then the Edit tool, mcp__db__run_sql') == ['Edit', 'WebSearch', 'mcp__db__run_sql'] and kt.tools_named('Monitoring the env') == [] \
    and kt.tools_named('tools: WebFetch') == []
home = tmp / 'home'; (home / '.claude' / 'plugins' / 'cache' / 'p1' / '.claude-plugin').mkdir(parents=True)
(home / '.claude.json').write_text(json.dumps({'mcpServers': {'db': {}, 'heavy': {}, 'quiet': {}}, 'projects': {str(tk.parent).replace('\\', '/'): {
    'mcpServers': {'local1': {}}, 'disabledMcpServers': ['heavy', 'plugin:off:srv']}}}), encoding='utf-8')
(home / '.claude' / 'settings.json').write_text(json.dumps({'enabledPlugins': {'browse@m': True, 'off@m': True, 'unused@m': False}}), encoding='utf-8')
(home / '.claude' / 'plugins' / 'cache' / 'p1' / '.claude-plugin' / 'plugin.json').write_text(json.dumps({'mcpServers': {'devtools': {}}}), encoding='utf-8')
(home / 'p2' / '.claude-plugin').mkdir(parents=True); (home / 'p2' / '.claude-plugin' / 'plugin.json').write_text(json.dumps({'mcpServers': './.mcp.json'}), encoding='utf-8')
(home / '.claude' / 'settings.json').write_text(json.dumps({'enabledPlugins': {'browse@m': True, 'off@m': True, 'unused@m': False, 'str@m': True}}), encoding='utf-8')
(home / '.claude' / 'plugins' / 'installed_plugins.json').write_text(json.dumps({'plugins': {'browse@m': [{'installPath': str(home / '.claude' / 'plugins' / 'cache' / 'p1')}],
    'off@m': [{'installPath': str(home / 'none')}], 'str@m': [{'installPath': str(home / 'p2')}]}}), encoding='utf-8')
(tk.parent / '.mcp.json').write_text(json.dumps({'mcpServers': {'shared': {}}}), encoding='utf-8')
pt.KIT_DIR, pt.local_config = str(tk), kt.local_config
srv =pt.mcp_servers(home, tk.parent)
line = pt.mcp_line(home, tk.parent)
ok_m = srv == ['db', 'local1', 'plugin_browse_devtools', 'quiet', 'shared'] \
    and all(s in line for s in ('local1', 'plugin_browse_devtools', 'shared')) and 'quiet' not in line and ' db' not in line
# a server that fails to connect (claude mcp list ✗) is named; connected ones and no CLI output: no line
ml = 'Checking MCP server health…\n\nplugin:dev-mcp:devtools: npx dev-mcp@1 - ✗ Failed to connect\ndb: py db.py - ✔ Connected\n'
fl = pt.mcp_failed(lambda: ml)
ok_m = ok_m and 'plugin:dev-mcp:devtools failed to connect' in fl and ' db' not in fl \
    and pt.mcp_failed(lambda: 'db: x - ✔ Connected\n') == '' and pt.mcp_failed(lambda: '') == ''
print(f'ports-tools:{ok_t and ok_f and ok_n and ok_m} {ok_t} {ok_f} {ok_n} {ok_m}')

# parity (AGENTS.md "Parity"): the kit has 0 problems; a verb on one adapter only, a stale or unknown gap, an unported hook fail
kp = kt.load(kt.KIT_DIR); man = kt.manifest(kp.dir)
def par(k, m):
    probs = []
    kt.adapter_lint(k, m, lambda *x: probs.append(x[2]))
    return probs
p0 = par(kp, man)
gh = 'skills/crafty/adapters/github.ps1'; kp.texts[gh] = kp.texts[gh].replace("Register-KitAdapter 'tracker' 'github' @{", "Register-KitAdapter 'tracker' 'github' @{ 'tag-add' = { 'x' }\n", 1)
p1 = par(kp, man)
fam = json.loads(json.dumps(man)); fam['adapters']['tracker']['caps'] += ' tagAdd'
p2 = par(kp, fam)
fam['adapters']['tracker']['fallback']['tagAdd'] = 'a Tags line'; fam['adapters']['tracker']['gaps'] = {'clickup/view': 'x', 'nosuch/view': 'y'}
p3 = par(kp, fam)
st = json.loads(kp.texts['settings.json']); st['hooks']['Stop'] = [{'hooks': [{'type': 'command', 'command': 'pwsh', 'args': ['-File', 'x/bossy.ps1', 'stop-check']}]}]
kp.texts['settings.json'] = json.dumps(st); p4 = [x for x in par(kp, man) if 'Stop' in x]
reg = json.loads(kp.texts[kt.PARITY_JSON]); reg['harness']['hooks']['Stop bossy.ps1 stop-check'] = {'codex': 'gap: no Stop hook', 'antigravity': 'fallback: board beat'}
kp.texts[kt.PARITY_JSON] = json.dumps(reg); p5 = [x for x in par(kp, man) if 'Stop' in x]
kq = kt.load(kt.KIT_DIR); ln = 'skills/crafty/adapters/tracker-linear.ps1'   # a verb renamed while a nested @{ status = } stays
kq.texts[ln] = kq.texts[ln].replace("'status' = {", "'status-x' = {", 1); p6 = par(kq, man)
for rel in ('.codex/config.toml', '.agents/hooks.json'):   # the plain health hook gone, health -Flow -Fetch kept
    kq.texts[rel] = kt.ktext(kq, rel).replace(pt.hook_cmd(pt.HEALTH, '.claude'), pt.hook_cmd(('bossy/bossy.ps1', 'healthz', 15), '.claude'))
p7 = [x for x in par(kq, man) if x.startswith('hook SessionStart bossy.ps1 health:')]
kc = kt.load(kt.KIT_DIR); tl = 'skills/crafty/adapters/tracker-local.ps1'   # cells from code: an undeclared adapter, a stub verb, a new called verb
kc.texts[tl] += "\nRegister-KitAdapter 'tracker' 'fakey' @{ 'view' = { 'x' }; 'url' = { param($a) throw 'UNSUPPORTED tracker/fakey/url' } }\nfunction Get-Frob { __TrA 'frobnicate' @{} }\n"
pc = par(kc, man); stale = 'fallback "publish" is used by no adapter'
fb2 = json.loads(json.dumps(man)); fb2['adapters']['report']['fallback'] = {'publish': 'a kept file'}; pf = par(kt.load(kt.KIT_DIR), fb2)
print(f'parity-code:{any("tracker/fakey: registered in code" in x for x in pc)}|{any("tracker/fakey/url: a required verb" in x for x in pc)}'
      f'|{any("tracker/fakey/status: a required verb" in x for x in pc)}|{any("tracker: verb frobnicate is called (skills/crafty/adapters/tracker-local.ps1:" in x for x in pc)}'
      f'|{sum("/frobnicate: an optional verb" in x for x in pc) >= 8}|{any(stale in x for x in pf)}')
print(f'parity-kit:{not p0} {p0[:3]}')
print(f'parity-nested:{any("tracker/linear/status: a required verb" in x for x in p6) and len(p7) == 2}')
print(f'parity-sibling:{any("tracker/github: verb tag-add is in no family list" in x for x in p1) and sum("/tagAdd: an optional verb" in x for x in p2) == 7 and not any("tagAdd" in x for x in p3)}')
print(f'parity-gaps:{any("clickup/view: declared gap" in x for x in p3) and any("nosuch/view" in x for x in p3)}')
# retro tidy-6: a brace in a string ('@\{', "a}b", py '\'{') or a comment is no code: every verb after it is still read
rb = "Register-KitAdapter 'x' 'y' @{ list = { $a -match '@\\{' }   # it's\n  view = { <# it's { #> \"$(\"a}\" + 'b')\" }; edit = { 1 } }"
pb = "ADAPTERS['x']['y'] = {'list': lambda a: re.match('\\'{', a),  # don't\n 'view': lambda a: 1}"
print(f'parity-strings:{sorted(kt._top_keys(kt._braced(rb, 0))) == ["edit", "list", "view"] and sorted(kt._top_keys(kt._braced(pb, 0, True), True)) == ["list", "view"]}')
print(f'parity-harness:{len(p4) == 2 and all("not in the" in x for x in p4) and not p5}')
# parity next (owner 2026-11-24): the org's adapters first, then code uses, then native siblings; native / config / none cells and
# `no such feature: <link>` gaps left out; a no-such-feature gap without its link fails lint
kn = kt.load(kt.KIT_DIR); m0 = json.loads(json.dumps(man))
for a in m0['adapters'].values():   # the registry's own gaps and accepted cells out: every fallback cell open
    if isinstance(a, dict):
        a.pop('accepted', None); a['gaps'] = {g: w for g, w in (a.get('gaps') or {}).items() if not g.endswith('/checklist')}
nx = kt.parity_next(kn, m0, {'tracker': {'type': 'linear'}})
cells = [(f, n, v) for _, f, n, v, s, _ in nx]
fn = json.loads(json.dumps(m0)); fn['adapters']['tracker']['gaps'] = {'jira/checklist': 'no such feature: https://example.org/doc no checklist API'}
fn['adapters']['tracker']['accepted'] = {'youtrack/checklist': 'description markdown is its checklist'}; nf = [(f, n, v) for _, f, n, v, s, _ in kt.parity_next(kn, fn, {})]
fn['adapters']['tracker']['gaps'] = {'jira/checklist': 'no such feature (no link)'}; fn['adapters']['tracker']['accepted'] = {'clickup/checklist': 'x', 'linear/checklist': ' '}; p8 = par(kn, fn)
nLin = sum(1 for f, n, v in cells if (f, n) == ("tracker", "linear"))   # every org cell first (checklist, tagPrune), none later
print(f'parity-next:{nLin > 0 and all(c[:2] == ("tracker", "linear") for c in cells[:nLin])}'
      f'|{not [c for c in cells if c[1] == "none"]}|{all(s in ("fallback", "gap") for *_, s, _ in nx)}'
      f'|{("tracker", "jira", "checklist") in cells and ("tracker", "jira", "checklist") not in nf}'
      f'|{("tracker", "youtrack", "checklist") in cells and ("tracker", "youtrack", "checklist") not in nf and ("tracker", "linear", "checklist") in nf}'
      f'|{any("says no such feature without its doc link" in x for x in p8)}'
      f'|{any("accepted \"clickup/checklist\": clickup/checklist is native" in x for x in p8) and any("accepted \"linear/checklist\" has no reason" in x for x in p8)}')