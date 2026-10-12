"""kit-lint: every part of the kit must be reached through an explicit path (router -> skill -> step-bound files).

  python kit-lint.py [<kit .claude dir>] [--summary] [--warn] [--no-flow] [--org-terms <kit.local.json | term,term>] [--json <out>]

Default kit dir: the kit this script lives in (the .claude folder = the kit repo's root). Exit 1 when problems are found (0 with --warn).
--summary   one line (the SessionStart hook uses it); --no-flow skips regenerating <runtime>/cache/kit-flow.html (kit-flow.py)
--org-terms also scans the published kit (README/docs/examples included) for org terms: a JSON file's "orgTerms" list
            (e.g. the workspace kit.local.json) or a comma list. The pre-push hook (.githooks/pre-push) runs it.
Checks (the same graph and rules kit-flow.py draws; both use kitgraph_lib.py):
  ROUTER-MISSING / ROUTER-TARGET / ROUTER-UNROUTED  CLAUDE.md "## Router" table; one target per row; every skill, workflow, agent routed
  OVERLAY-ROUTER  a workspace with rules/*.local.md needs a "## Org router rows" section
  SKILL-DESC      description reads "Load when: ... Not when: ... -> <sibling>" (<= 450 chars)
  SKILL-BLOCK     SKILL.md has the **Load when**, **Not when**, **Hands off to** and **Files** blocks
  SKILL-FUZZY     no "read when you need it" triggers in SKILL.md or reference docs
  FILES-UNLISTED / FILES-MISSING / FILES-UNBOUND  Files index lists every file; entries exist; references/templates name their step,
                  LESSONS.md is read at step 0, HISTORY.md is marked "never"
  WF-WHEN / WF-CLOCK / WF-CRLF  whenToUse is a router row word for word; no Date.now/new Date in code; LF only
  AGENT-SPAWN / AGENT-SKILL  description says "Spawned by" and "Not for"; body names the skill it loads first
  REF-DANGLING    a kit path in Markdown points at nothing (docs/ and examples/ paths too)
  REACH-NONE / REACH-MENTION  unreached file / reached only through a mention
  JUNK            runtime output or reserved-name files among the kit files (outside .claude-runtime)
  RUNTIME-RAW     a script builds a runtime path by hand (.claude-runtime/<sub>, $CLAUDE_RUNTIME, $KitConf.Runtime, ${RT}/):
                  use Get-KitPath / kit_path / kitPath / rp(<name>) with the names in skills/dev-kit/scripts/kitpaths.json
  RUNTIME-MAP     a workflow's `const KP` names differ from kitpaths.json (or kitpaths.json is invalid)
  RUNTIME-DURABLE durable state (learning, tracking, automerge.json, tracker-none) inside the disposable runtime: kit-setup.ps1 -Migrate
  CONFIG-UNDOC    a *.example.json key missing from skills/dev-kit/reference/configuration.md
  ORG-TERM        an org term in a published file (only with --org-terms)
"""
import importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kitgraph_lib as lib  # noqa: E402

args = sys.argv[1:]


def opt(name, has_value=False):
    if name not in args:
        return None
    i = args.index(name)
    args.pop(i)
    return args.pop(i) if has_value else True


SUMMARY, WARN, NOFLOW = opt('--summary'), opt('--warn'), opt('--no-flow')
ORG, JSON_OUT = opt('--org-terms', True), opt('--json', True)
KIT = os.path.abspath(args[0] if args else os.path.join(HERE, '..', '..', '..'))

terms = None
if ORG:
    if os.path.isfile(ORG):
        try:
            terms = json.load(open(ORG, encoding='utf-8')).get('orgTerms') or []
        except ValueError:
            sys.exit(f'kit-lint: {ORG} is not valid JSON')
    else:
        terms = [t for t in ORG.split(',') if t.strip()]

k = lib.load(KIT)
g = lib.graph(k)
problems = lib.lint(k, g, terms)

if not NOFLOW:   # keep the flow page current whenever the lint runs
    try:
        spec = importlib.util.spec_from_file_location('kit_flow', os.path.join(HERE, 'kit-flow.py'))
        kf = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(kf)
        kf.render(KIT, kf.default_out(KIT), quiet=bool(SUMMARY), data=kf.page_data(k, g, problems))
    except Exception as e:  # the page is a convenience; never fail the lint for it
        print(f'kit-lint: kit-flow page not regenerated: {e}', file=sys.stderr)

if JSON_OUT:
    json.dump([{'code': c, 'where': w, 'problem': m} for c, w, m in problems], open(JSON_OUT, 'w', encoding='utf-8'), indent=1)
if SUMMARY:
    if problems:
        c, w, m = problems[0]
        print(f'kit-lint: {len(problems)} problem(s), e.g. {c} {w}: {m} (list: python {os.path.join(HERE, "kit-lint.py")})')
else:
    for c, w, m in problems:
        print(f'{c:15} {w}: {m}')
    print(f'kit-lint: {len(problems)} problem(s) in {KIT} ({len(k.files)} files, {len(k.skills)} skills, '
          f'{len(k.workflows)} workflows, {len(k.agents)} agents)')
sys.exit(1 if problems and not WARN else 0)
