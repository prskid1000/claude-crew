"""ports_test.py (goody ports): kitbag_ports internals. Usage: python -X utf8 ports_test.py <kitbag.py> <kitbag_ports.py>"""
import contextlib, importlib.util, io, sys, tempfile, tomllib
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
pt.KIT, pt.WORKSPACE = kit, ws
with contextlib.redirect_stdout(io.StringIO()):
    pt.port_deploy()
ok_deploy = (ws / '.codex/config.local.toml').exists() and (ws / '.agents/agents/mine.txt').exists() and not (ws / '.codex/agents/old.toml').exists() \
    and (ws / '.codex/agents/a.toml').read_text(encoding='utf-8') == 'x' and pt.deployed_stale() == []
# owner decisions: blocking -> the native tool where it exists (Codex request_user_input in Plan mode, Antigravity ask_question
# only when listed), the text otherwise; FYI -> a numbered list; ported agents say a subagent never asks the user
f = {'name': 'w', 'description': 'd', 'phases': []}
cx, ag = pt.workflow_procedure_doc(f, 'Codex', 'h'), pt.workflow_procedure_doc(f, 'Antigravity', 'h')
pt.write_codex('b', {'description': 'd'}, 'body\n' + pt.AGENT_DECIDE)
ok_ask = all(x in cx for x in ('## Owner decisions', '`request_user_input`', 'Plan mode', '-Ask -Json -Max 3', 'decide list -Fyi', 'decide list -Ask` (question')) \
    and 'only when `ask_question` is in your tool list' in ag and 'decide list -Fyi' in ag and 'request_user_input' not in ag \
    and 'never asks the user directly' in tomllib.loads((tmp / 'c' / 'b.toml').read_text(encoding='utf-8'))['developer_instructions']
print(f'ports-ask:{ok_ask}')
print(f'ports-escape:{ok_toml}')
print(f'ports-deploy:{ok_deploy}')
