"""tools_test.py: kitbag_admin tools (crew allowlists, the kittools filter, MCP lines) and adapter parity, run by tests/tools.tests.ps1.
Usage: python -X utf8 tools_test.py <kitbag.py> <kitbag_admin.py>. Prints one `<case>:<True|False>` line per check. Exit codes: 0 always
(tools.tests.ps1 reads the lines)."""
import importlib.util, io, json, sys, tempfile
from pathlib import Path

def load(name, path, shared=None):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    m.__dict__.update(shared or {})
    spec.loader.exec_module(m)
    return m

kt = load('kitbag', sys.argv[1])
pt = load('kitbag_admin', sys.argv[2], {n: v for n, v in vars(kt).items() if not n.startswith('__')})
tmp = Path(tempfile.mkdtemp())
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
print(f'tools-lines:{ok_t and ok_f and ok_n and ok_m} {ok_t} {ok_f} {ok_n} {ok_m}')

# parity (AGENTS.md "Parity"): the kit has 0 problems; a verb on one adapter only, a stale or unknown gap fail
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
kq = kt.load(kt.KIT_DIR); ln = 'skills/crafty/adapters/tracker-linear.ps1'   # a verb renamed while a nested @{ status = } stays
kq.texts[ln] = kq.texts[ln].replace("'status' = {", "'status-x' = {", 1); p6 = par(kq, man)
kc = kt.load(kt.KIT_DIR); tl = 'skills/crafty/adapters/tracker-local.ps1'   # cells from code: an undeclared adapter, a stub verb, a new called verb
kc.texts[tl] += "\nRegister-KitAdapter 'tracker' 'fakey' @{ 'view' = { 'x' }; 'url' = { param($a) throw 'UNSUPPORTED tracker/fakey/url' } }\nfunction Get-Frob { __TrA 'frobnicate' @{} }\n"
pc = par(kc, man); stale = 'fallback "publish" is used by no adapter'
fb2 = json.loads(json.dumps(man)); fb2['adapters']['report']['fallback'] = {'publish': 'a kept file'}; pf = par(kt.load(kt.KIT_DIR), fb2)
print(f'parity-code:{any("tracker/fakey: registered in code" in x for x in pc)}|{any("tracker/fakey/url: a required verb" in x for x in pc)}'
      f'|{any("tracker/fakey/status: a required verb" in x for x in pc)}|{any("tracker: verb frobnicate is called (skills/crafty/adapters/tracker-local.ps1:" in x for x in pc)}'
      f'|{sum("/frobnicate: an optional verb" in x for x in pc) >= 8}|{any(stale in x for x in pf)}')
print(f'parity-kit:{not p0} {p0[:3]}')
print(f'parity-nested:{any("tracker/linear/status: a required verb" in x for x in p6)}')
print(f'parity-sibling:{any("tracker/github: verb tag-add is in no family list" in x for x in p1) and sum("/tagAdd: an optional verb" in x for x in p2) == 7 and not any("tagAdd" in x for x in p3)}')
print(f'parity-gaps:{any("clickup/view: declared gap" in x for x in p3) and any("nosuch/view" in x for x in p3)}')
# retro tidy-6: a brace in a string ('@\{', "a}b", py '\'{') or a comment is no code: every verb after it is still read
rb = "Register-KitAdapter 'x' 'y' @{ list = { $a -match '@\\{' }   # it's\n  view = { <# it's { #> \"$(\"a}\" + 'b')\" }; edit = { 1 } }"
pb = "ADAPTERS['x']['y'] = {'list': lambda a: re.match('\\'{', a),  # don't\n 'view': lambda a: 1}"
print(f'parity-strings:{sorted(kt._top_keys(kt._braced(rb, 0))) == ["edit", "list", "view"] and sorted(kt._top_keys(kt._braced(pb, 0, True), True)) == ["list", "view"]}')
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