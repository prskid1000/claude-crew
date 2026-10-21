"""ports_test.py (extra ports): kittool_ports internals. Usage: python -X utf8 ports_test.py <kittool.py> <kittool_ports.py>"""
import contextlib, importlib.util, io, sys, tempfile, tomllib
from pathlib import Path

def load(name, path, shared=None):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    m.__dict__.update(shared or {})
    spec.loader.exec_module(m)
    return m

kt = load('kittool', sys.argv[1])
pt = load('kittool_ports', sys.argv[2], {n: v for n, v in vars(kt).items() if not n.startswith('__')})
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
print(f'ports-escape:{ok_toml}')
print(f'ports-deploy:{ok_deploy}')
