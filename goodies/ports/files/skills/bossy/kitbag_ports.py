"""kitbag goody ports: Codex / Antigravity ports of the kit's agents, hooks and workflows.

  python -X utf8 skills/bossy/kitbag.py port [--check]

Writes .codex/ and .agents/ (agents, hook wiring, a manual procedure per workflow) and GEMINI.md inside the kit, then copies
them to the workspace root, where codex / agy look. --check compares a fresh generation with the files (bossy.ps1 health,
prepush, kitty audit) and also writes each agent's Character block from the manifest. kitbag.py loads this file and shares
its names (frontmatter, manifest, SCHEMAS, CHAR_RX, ...).
Exit codes: 0 ok · 1 stale or missing ports (--check).
Sections: L29 characters · L64 agents · L111 hooks · L129 workflows · L186 deploy · L268 command
"""
import contextlib, io, json, re, shutil, tempfile
from pathlib import Path

# Ports are written under KIT (this file's kit, pushed); port_deploy copies them to WORKSPACE, where codex / agy look.
KIT = Path(__file__).resolve().parents[2]
WORKSPACE = KIT.parent
CODEX_AGENTS = KIT / ".codex" / "agents"
GRAVITY_AGENTS = KIT / ".agents" / "agents"
CODEX_CONFIG = KIT / ".codex" / "config.toml"
GRAVITY_HOOKS = KIT / ".agents" / "hooks.json"
CODEX_WORKFLOWS = KIT / ".codex" / "workflows"
GRAVITY_WORKFLOWS = KIT / ".agents" / "workflows"
GEMINI_MD = "@AGENTS.md\n"
PWSH = "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .claude/skills/"
GUARD = (PWSH + "crafty/crafty.ps1 guard", 10)
SESSION_START = [(PWSH + "bossy/bossy.ps1 health", 15), (PWSH + "bossy/bossy.ps1 cleanup -IfDue -Quiet", 600)]

# ---- characters: Character blocks from the manifest
def character_block(ch, width=128):
    """The Character paragraph port writes into agents/<name>.md from the manifest (one fixed shape for every agent)."""
    words = f'**Character:** traits: {ch["traits"]} · bias: {ch["bias"]} · catchphrase: "{ch["catchphrase"]}" · never: {ch["never"]}.'.split(' ')
    lines, cur = [], ''
    for w in words:
        if cur and len(cur) + 1 + len(w) > width:
            lines.append(cur)
            cur = w
        else:
            cur = f'{cur} {w}' if cur else w
    return '\n'.join(lines + [cur])

def write_characters(kit=None):
    """port: every agent's Character block from the manifest (one shape, one source)."""
    kd = kit or KIT_DIR
    n = 0
    for a, m in (manifest(kd).get('agents') or {}).items():
        p = osp.join(kd, 'agents', f'{a}.md')
        ch = m.get('character') or {}
        if not osp.isfile(p) or schema_errors(ch, SCHEMAS['character']) or TODO in json.dumps(ch):
            continue
        with open(p, encoding='utf-8', newline='') as fh:
            raw = fh.read()
        eol = '\r\n' if '\r\n' in raw else '\n'
        t = raw.replace('\r\n', '\n')
        blk = character_block(ch)
        t2 = CHAR_RX.sub(lambda _: blk, t, count=1) if CHAR_RX.search(t) else t
        if t2 != t:
            with open(p, 'w', encoding='utf-8', newline='') as fh:
                fh.write(t2.replace('\n', eol))
            n += 1
    if n:
        print(f'Character blocks written from the manifest: {n}')

# ---- agents: Codex / Antigravity agent files
def write_port(path, text):
    path.write_text(text, encoding="utf-8", newline="\n")

def agent_parts(text):
    """(front matter fields, body) of an agent file."""
    m = re.match(r"^---\n.*?\n---\n(.*)$", text, re.S)
    if not m:
        raise ValueError("no frontmatter")
    return frontmatter(text), m.group(1).lstrip("\n")

def write_codex(name, fields, body):
    # Codex has no tools list: an agent without Edit / Write runs read-only
    tools = fields.get("tools", "")
    sandbox = 'sandbox_mode = "read-only"\n' if tools and "Edit" not in tools and "Write" not in tools else ""
    body = body.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')
    write_port(CODEX_AGENTS / f"{name}.toml", f'name = "{name}"\ndescription = {json.dumps(fields["description"], ensure_ascii=False)}\n'
      f'{sandbox}developer_instructions = """\n{body}\n"""\n')

def write_gravity(name, fields, body):
    # Antigravity names its tools differently (a mismapped one hangs): leave tools unset and say so
    head = [f"name: {name}", f'description: {json.dumps(fields["description"], ensure_ascii=False)}', "subagent: true",
      "mainAgent: false", "model: inherit", "commandExecutionPolicy: auto"]
    note = (f"\n> Ported note: the Claude Code definition restricts tools to `{fields['tools']}`; map them to Antigravity's tool "
      "names by hand if you need the same restriction.\n") if fields.get("tools") else ""
    write_port(GRAVITY_AGENTS / f"{name}.md", "---\n" + "\n".join(head) + "\n---\n" + note + "\n" + body.strip() + "\n")

def prune(folder, suffix, keep):
    """Drop a port the kit no longer generates (a removed or renamed agent / workflow)."""
    for p in folder.glob('*' + suffix) if folder.exists() else []:
        if p.stem not in keep:
            p.unlink()

def port_agents():
    CODEX_AGENTS.mkdir(parents=True, exist_ok=True)
    GRAVITY_AGENTS.mkdir(parents=True, exist_ok=True)
    made = set()
    for src in sorted((KIT / "agents").glob("*.md")):
        fields, body = agent_parts(src.read_text(encoding="utf-8").replace("\r\n", "\n"))
        name = fields.get("name", src.stem)
        write_codex(name, fields, body.rstrip("\n") + "\n" + AGENT_DECIDE)
        write_gravity(name, fields, body.rstrip("\n") + "\n" + AGENT_DECIDE)
        made.add(name)
    prune(CODEX_AGENTS, '.toml', made)
    prune(GRAVITY_AGENTS, '.md', made)
    print(f"ported {len(made)} agent(s) -> .codex/agents/*.toml, .agents/agents/*.md")

# ---- hooks: hook wiring
def port_hooks():
    """Each tool's hook config runs the same scripts as settings.json (no SendMessage guard: no such tool there)."""
    CODEX_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    toml = ["# Generated by kitbag.py port from settings.json; the logic lives in crafty.ps1 / bossy.ps1.", "",
      "[[hooks.PreToolUse]]", 'matcher = "^(Bash|apply_patch)$"', "", "[[hooks.PreToolUse.hooks]]", 'type = "command"',
      f"command = '''{GUARD[0]}'''", f"timeout = {GUARD[1]}"]
    for cmd, timeout in SESSION_START:
        toml += ["", "[[hooks.SessionStart]]", 'matcher = "*"', "", "[[hooks.SessionStart.hooks]]", 'type = "command"',
          f"command = '''{cmd}'''", f"timeout = {timeout}"]
    write_port(CODEX_CONFIG, "\n".join(toml) + "\n")
    GRAVITY_HOOKS.parent.mkdir(parents=True, exist_ok=True)
    hook = lambda cmd, timeout: {"type": "command", "command": cmd, "timeout": timeout}
    write_port(GRAVITY_HOOKS, json.dumps({
      "guard": {"enabled": True, "PreToolUse": [{"matcher": "run_command", "hooks": [hook(*GUARD)]}]},
      "kit-health": {"enabled": True, "SessionStart": [hook(*x) for x in SESSION_START]}}, indent=2) + "\n")
    print("hook wiring written -> .claude/.codex/config.toml, .claude/.agents/hooks.json")

# ---- workflows: a manual procedure per workflow
def workflow_meta(text):
    """name, description, whenToUse and phases [(title, detail)] of a workflow's `export const meta`."""
    m = re.search(r"export const meta\s*=\s*\{(.*?)\n\}", text, re.S)
    if not m:
        return None
    fields = dict(re.findall(r"(\w+):\s*'((?:[^'\\]|\\.)*)'", m.group(1)))
    phases = re.search(r"phases:\s*\[(.*?)\n\s*\],", m.group(1), re.S)
    fields["phases"] = re.findall(r"\{\s*title:\s*'([^']*)'\s*,\s*detail:\s*'((?:[^'\\]|\\.)*)'\s*\}", phases.group(1)) if phases else []
    return fields

# owner decisions (bossy E4): `decide ask` records {key, label, description, recommended} + blocking; blocking ones go to the
# tool's native question tool where it has one, else the text; FYI ones are always a numbered list in the report
ASK_NATIVE = {
  "Codex": "in Plan mode, as the root thread: ONE `request_user_input` call from `bossy.ps1 decide list -Ask -Json -Max 3` "
    "(per question: header, question, options = label + description, recommended first, at most 3: name a 4th in the question; "
    "the client adds \"Other\")",
  "Antigravity": "only when `ask_question` is in your tool list (its schema is not published): one `ask_question` per question of "
    "`bossy.ps1 decide list -Ask -Json`, options = the labels, recommended first (it shows its own write-in field)"}
AGENT_DECIDE = ("\n> Ported note: owner decisions go only through `bossy.ps1 decide ask` (blocking by default, `-Fyi` when nothing "
  "waits); a subagent never asks the user directly: the coordinator relays it.\n")

def decisions_section(tool):
    return ["## Owner decisions", "",
      f"- **Blocking** (an item waits): {ASK_NATIVE[tool]}; the questions map to the payload's `ids` in order. No tool, or a pending "
      "id missing from `ids` (fewer than 2 options): the text of `bossy.ps1 decide list -Ask` (question, options table, "
      "recommendation first). Then `decide answer -Id <id> -Answer '<choice>'` per pick.",
      "- **FYI** (nothing waits): a numbered list in your report (`decide list -Fyi`); map the owner's \"1 A, 2 B\" back with "
      "`decide answer -Id <id>` per number.", ""]

def workflow_procedure_doc(fields, tool, how):
    lines = [f"# {fields['name']} (ported procedure, not a native {tool} workflow)", "", f"> {fields['description']}", "",
      f"**When to run it:** {fields.get('whenToUse', '(see the workflow source)')}", "",
      f"{tool} has no workflow engine: you are the coordinator. {how}", "", "## Phases", ""]
    lines += [f"{i}. **{title}** -- {detail}" for i, (title, detail) in enumerate(fields["phases"], 1)]
    lines += [""] + decisions_section(tool)
    lines += [f"Arguments and step details: `.claude/workflows/{fields['name']}.js` (its header comment) and the `bossy` skill."]
    return "\n".join(lines) + "\n"

def port_workflows():
    CODEX_WORKFLOWS.mkdir(parents=True, exist_ok=True)
    GRAVITY_WORKFLOWS.mkdir(parents=True, exist_ok=True)
    made = set()
    for src in sorted((KIT / "workflows").glob("*.js")):
        fields = workflow_meta(src.read_text(encoding="utf-8"))
        if not fields or "name" not in fields:
            continue
        write_port(CODEX_WORKFLOWS / f"{fields['name']}.md", workflow_procedure_doc(fields, "Codex",
          "Per phase, in order: `spawn_agent` each of its agents from `.codex/agents/*.toml` (up to the session's concurrency "
          "limit), `wait_agent` for them, then the next phase."))
        write_port(GRAVITY_WORKFLOWS / f"{fields['name']}.md", workflow_procedure_doc(fields, "Antigravity",
          "Per phase, in order: delegate it to the matching subagent in `.agents/agents/*.md`."))
        made.add(fields['name'])
    prune(CODEX_WORKFLOWS, '.md', made)
    prune(GRAVITY_WORKFLOWS, '.md', made)
    print(f"ported {len(made)} workflow procedure doc(s) -> .codex/workflows/*.md, .agents/workflows/*.md")

# ---- deploy: copy to the workspace root, staleness
def port_deploy():
    """Copy .codex, .agents, AGENTS.md and GEMINI.md to the workspace root (the CLIs read the session cwd, never .claude)."""
    if KIT.name != '.claude':
        print(f"not deployed: {KIT} is not a workspace's .claude folder (the ports inside the kit are updated)")
        return
    deployed = []
    for name in (".codex", ".agents"):
        src_dir, dst_dir = KIT / name, WORKSPACE / name
        for p in stale_generated(src_dir, dst_dir):
            p.unlink()
        for p in src_dir.rglob('*'):
            if p.is_file():
                t = dst_dir / p.relative_to(src_dir)
                t.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, t)
        deployed.append(dst_dir)
    for name in ("AGENTS.md", "GEMINI.md"):
        shutil.copyfile(KIT / name, WORKSPACE / name)
        deployed.append(WORKSPACE / name)
    for base in (WORKSPACE / ".agents", KIT):   # forwarders: .claude/skills/... resolves when the cwd is .agents
        for script in ("crafty/crafty.ps1", "bossy/bossy.ps1"):
            fwd = base / ".claude" / "skills" / script
            fwd.parent.mkdir(parents=True, exist_ok=True)
            fwd.write_text(f"& '{(KIT / 'skills' / script).as_posix()}' @args\n", encoding="utf-8")
    print(f"deployed -> {', '.join(str(p) for p in deployed)}")

def stale_generated(src, dst):
    """Workspace ports in dst/agents or dst/workflows with no kit counterpart (a removed agent / workflow)."""
    if not dst.exists():
        return []
    have = {p.relative_to(src).as_posix() for p in src.rglob('*') if p.is_file()} if src.exists() else set()
    return [p for p in dst.rglob('*') if p.is_file() and p.relative_to(dst).parts[0] in ('agents', 'workflows')
      and p.suffix in ('.toml', '.md') and p.relative_to(dst).as_posix() not in have]

def deployed_stale():
    """Workspace copies that differ from the kit; [] when the kit is no installed <workspace>/.claude."""
    if KIT.name != '.claude':
        return []
    bad = []
    for name in ('.codex', '.agents'):
        src, dst = KIT / name, WORKSPACE / name
        a = {p.relative_to(src).as_posix(): p.read_bytes() for p in src.rglob('*') if p.is_file()} if src.exists() else {}
        b = {r: (dst / r).read_bytes() for r in a if (dst / r).is_file()}
        if a != b or stale_generated(src, dst):
            bad.append(name + '/')
    for name in ('AGENTS.md', 'GEMINI.md'):
        if not (WORKSPACE / name).exists() or (WORKSPACE / name).read_bytes() != (KIT / name).read_bytes():
            bad.append(name)
    return bad

def check_stale():
    """Stale port paths: every port is generated into a temp copy and compared by content."""
    g = globals()
    outs = ("CODEX_AGENTS", "GRAVITY_AGENTS", "CODEX_CONFIG", "GRAVITY_HOOKS", "CODEX_WORKFLOWS", "GRAVITY_WORKFLOWS")
    real = {name: g[name] for name in outs}
    stale = []
    with tempfile.TemporaryDirectory() as tmp:
        g.update({name: Path(tmp) / real[name].relative_to(KIT) for name in outs})
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                port_agents()
                port_hooks()
                port_workflows()
        finally:
            g.update(real)
        made = set()
        for f in Path(tmp).rglob("*"):
            if f.is_file():
                rel = f.relative_to(tmp).as_posix()
                made.add(rel)
                if not (KIT / rel).exists() or (KIT / rel).read_text(encoding="utf-8") != f.read_text(encoding="utf-8"):
                    stale.append(rel)
        for d in (CODEX_AGENTS, GRAVITY_AGENTS, CODEX_WORKFLOWS, GRAVITY_WORKFLOWS):
            stale += [p.relative_to(KIT).as_posix() + ' (no source)' for p in (d.glob('*') if d.exists() else [])
              if p.is_file() and p.relative_to(KIT).as_posix() not in made]
    gm = KIT / 'GEMINI.md'
    if not gm.exists() or gm.read_text(encoding='utf-8') != GEMINI_MD:
        stale.append('GEMINI.md')
    stale += [f'{x} (workspace copy)' for x in deployed_stale()]
    return sorted(set(stale))

# ---- command: port [--check]
def cmd_port(a):
    if '--check' in a:
        stale = check_stale()
        if stale:
            print(f"kitbag port: stale or missing ports: {stale}; run 'python -X utf8 skills/bossy/kitbag.py port'")
        return 1 if stale else 0
    write_characters(str(KIT))
    port_agents()
    port_hooks()
    port_workflows()
    write_port(KIT / 'GEMINI.md', GEMINI_MD)
    port_deploy()
    return 0

COMMANDS = {'port': cmd_port}
ARGS = {'port': ({'--check'}, set(), False)}