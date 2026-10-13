"""Regenerate Codex (.codex/agents/*.toml) and Antigravity (.agents/agents/*.md)
agent definitions, and their hook wiring, from the single source of truth:
.claude/agents/*.md and .claude/settings.json.

Run after editing any .claude/agents/*.md file or settings.json hooks block:
    python -X utf8 .claude/skills/orchestrate/scripts/port-kit.py

This is the ONLY place that knows the per-tool field names (Claude frontmatter ->
Codex TOML -> Antigravity YAML). Edit agents only in .claude/agents/*.md; never
hand-edit the generated .codex/ or .agents/ files, or the next run overwrites them.
"""
import json
import re
import shutil
from pathlib import Path

WORKSPACE = Path(__file__).resolve().parents[4]  # .../<workspace> (holds .claude; usually NOT a git repo itself)
KIT = WORKSPACE / ".claude"                       # the kit repo (origin = claude-crew); canonical + pushable
CLAUDE_AGENTS = KIT / "agents"
CLAUDE_WORKFLOWS = KIT / "workflows"
CLAUDE_SETTINGS = KIT / "settings.json"

# Canonical copies live inside the kit repo so `git push` carries them. Codex/Antigravity don't
# walk into .claude for .codex//.agents -- confirmed live: `agy`/`codex` resolve them from the
# session's cwd (workspaceDirs=[<workspace>] in agy's own log), i.e. WORKSPACE, not KIT. So
# port_agents()/port_hooks()/port_workflows() write under KIT, then deploy() mirrors the result
# out to WORKSPACE/.codex and WORKSPACE/.agents (untracked there, same as this kit being cloned
# into WORKSPACE/.claude in the first place -- the deployed copy is not itself version control).
CODEX_AGENTS = KIT / ".codex" / "agents"
GRAVITY_AGENTS = KIT / ".agents" / "agents"
CODEX_CONFIG = KIT / ".codex" / "config.toml"
GRAVITY_HOOKS = KIT / ".agents" / "hooks.json"
CODEX_WORKFLOWS = KIT / ".codex" / "workflows"
GRAVITY_WORKFLOWS = KIT / ".agents" / "workflows"

FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n(.*)$", re.DOTALL)
META_RE = re.compile(r"export const meta\s*=\s*\{(.*?)\n\}", re.DOTALL)
STRING_FIELD_RE = re.compile(r"(\w+):\s*'((?:[^'\\]|\\.)*)'")
PHASES_RE = re.compile(r"phases:\s*\[(.*?)\n\s*\],", re.DOTALL)
PHASE_ENTRY_RE = re.compile(r"\{\s*title:\s*'([^']*)'\s*,\s*detail:\s*'((?:[^'\\]|\\.)*)'\s*\}")


def parse_frontmatter(text):
    m = FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError("no frontmatter")
    raw, body = m.group(1), m.group(2).lstrip("\n")
    fields = {}
    key, buf = None, []
    for line in raw.split("\n"):
        kv = re.match(r"^(\w+):\s*(.*)$", line)
        if kv:
            if key:
                fields[key] = "\n".join(buf).strip()
            key, buf = kv.group(1), [kv.group(2)]
        elif key:
            buf.append(line)
    if key:
        fields[key] = "\n".join(buf).strip()
    for k, v in list(fields.items()):
        if v.startswith('"') and v.endswith('"'):
            fields[k] = v[1:-1]
    return fields, body


def toml_escape(s):
    return s.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')


def write_codex(name, fields, body):
    # Verified against learn.chatgpt.com/docs/agent-configuration/subagents (2026-10-13):
    # required fields are name/description/developer_instructions; no "tools" array exists.
    # A Claude agent whose frontmatter restricts tools to read-only ones (Read/Grep/Glob/Bash
    # with no Edit/Write) is the closest match to sandbox_mode = "read-only".
    sandbox_line = ""
    if fields.get("tools") and "Edit" not in fields["tools"] and "Write" not in fields["tools"]:
        sandbox_line = 'sandbox_mode = "read-only"\n'
    content = (
        f'name = "{name}"\n'
        f'description = "{fields["description"]}"\n'
        f"{sandbox_line}"
        f'developer_instructions = """\n{toml_escape(body)}\n"""\n'
    )
    (CODEX_AGENTS / f"{name}.toml").write_text(content, encoding="utf-8")


def write_gravity(name, fields, body):
    # Verified against antigravity.google/docs/subagents (2026-10-13). "tools" takes
    # Antigravity's own tool names (view_file, run_command, ...), not Claude's (Read,
    # Bash, ...); the docs warn a mismapped name can hang the subagent, so we deliberately
    # don't guess a translation here -- leave tools unset (default: all) and say so in the body
    # when the Claude definition restricted tools, so a human maps it once by hand.
    frontmatter = [
        f"name: {name}",
        f'description: "{fields["description"]}"',
        "subagent: true",
        "mainAgent: false",
        "model: inherit",
        "commandExecutionPolicy: auto",
    ]
    note = ""
    if fields.get("tools"):
        note = (
            f"\n> Ported note: the Claude Code definition restricts tools to `{fields['tools']}`. "
            "Antigravity's `tools:` field uses its own tool names (view_file, run_command, ...); "
            "map this by hand if you need the same restriction here.\n"
        )
    content = "---\n" + "\n".join(frontmatter) + "\n---\n" + note + "\n" + body.strip() + "\n"
    (GRAVITY_AGENTS / f"{name}.md").write_text(content, encoding="utf-8")


def port_agents():
    CODEX_AGENTS.mkdir(parents=True, exist_ok=True)
    GRAVITY_AGENTS.mkdir(parents=True, exist_ok=True)
    count = 0
    for src in sorted(CLAUDE_AGENTS.glob("*.md")):
        fields, body = parse_frontmatter(src.read_text(encoding="utf-8"))
        name = fields.get("name", src.stem)
        write_codex(name, fields, body)
        write_gravity(name, fields, body)
        count += 1
    print(f"ported {count} agent(s) -> .codex/agents/*.toml, .agents/agents/*.md")


def port_hooks():
    """Guard + SessionStart hook logic already lives in .claude/skills/dev-kit/scripts/guard.ps1,
    .../orchestrate/scripts/{retro-nudge,kit-health,cleanup}.ps1. We don't copy the logic; we
    point each tool's own hook config at the SAME scripts, so there is one implementation and
    three thin wire-ups. NOT ported: the `SendMessage` guard (orchestrate/scripts/guard-sendmessage.ps1)
    -- `SendMessage` is a Claude Code tool name with no Codex/Antigravity equivalent to matcher
    against, so there is nothing to wire it to; this stays Claude-only."""
    session_start_cmds = [
        "retro-nudge.ps1",
        "kit-health.ps1",
    ]
    CODEX_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    pretool = (
        "[[hooks.PreToolUse]]\n"
        'matcher = "^(Bash|apply_patch)$"\n\n'
        "[[hooks.PreToolUse.hooks]]\n"
        'type = "command"\n'
        "command = '''pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .claude/skills/dev-kit/scripts/guard.ps1'''\n"
        'statusMessage = "Guard check (git stash / --no-verify / force-push / heavy build gate)"\n'
        "timeout = 10\n"
    )
    session_start = ""
    for script in session_start_cmds:
        session_start += (
            "\n[[hooks.SessionStart]]\n"
            'matcher = "*"\n\n'
            "[[hooks.SessionStart.hooks]]\n"
            'type = "command"\n'
            f"command = '''pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .claude/skills/orchestrate/scripts/{script}'''\n"
            "timeout = 30\n"
        )
    CODEX_CONFIG.write_text(
        "# Generated by port-kit.py - do not hand-edit the [hooks] section below.\n"
        "# Schema verified against learn.chatgpt.com/docs/hooks (2026-10-13).\n"
        "# Logic lives in .claude/skills/dev-kit/scripts/guard.ps1 and orchestrate/scripts/*.ps1 (shared with Claude Code).\n"
        "# Not ported: the SendMessage guard -- no Codex tool named SendMessage to matcher against.\n\n"
        + pretool + session_start,
        encoding="utf-8",
    )

    GRAVITY_HOOKS.parent.mkdir(parents=True, exist_ok=True)
    GRAVITY_HOOKS.write_text(
        json.dumps(
            {
                "guard": {
                    "enabled": True,
                    "PreToolUse": [
                        {
                            "matcher": "run_command",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass "
                                    "-File .claude/skills/dev-kit/scripts/guard.ps1",
                                    "timeout": 10,
                                }
                            ],
                        }
                    ],
                },
                "kit-health": {
                    "enabled": True,
                    "SessionStart": [
                        {
                            "matcher": "*",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass "
                                    f"-File .claude/skills/orchestrate/scripts/{script}",
                                    "timeout": 30,
                                }
                                for script in session_start_cmds
                            ],
                        }
                    ],
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print("hook wiring written -> .claude/.codex/config.toml, .claude/.agents/hooks.json")


def parse_workflow_meta(text):
    m = META_RE.search(text)
    if not m:
        return None
    block = m.group(1)
    fields = dict(STRING_FIELD_RE.findall(block))
    pm = PHASES_RE.search(block)
    phases = PHASE_ENTRY_RE.findall(pm.group(1)) if pm else []
    fields["phases"] = phases
    return fields


def workflow_procedure_doc(fields, tool_label, agent_note):
    lines = [
        f"# {fields['name']} (ported procedure, not a native {tool_label} workflow)",
        "",
        f"> {fields['description']}",
        "",
        f"**When to run it:** {fields.get('whenToUse', '(see .claude/workflows source)')}",
        "",
        f"{tool_label} has no pipeline/phase scripting engine equivalent to Claude Code's "
        "Workflow tool, so this is a manual run procedure, not an automated script. Drive it "
        f"yourself as the coordinator: {agent_note}",
        "",
        "## Phases",
        "",
    ]
    for i, (title, detail) in enumerate(fields.get("phases", []), 1):
        lines.append(f"{i}. **{title}** -- {detail}")
    lines.append("")
    lines.append(
        "Full argument shape and step-by-step mechanics: the canonical source is "
        f"`.claude/workflows/{fields['name']}.js` (read its header comment and the `orchestrate` "
        "skill before running this by hand)."
    )
    return "\n".join(lines) + "\n"


def port_workflows():
    CODEX_WORKFLOWS.mkdir(parents=True, exist_ok=True)
    GRAVITY_WORKFLOWS.mkdir(parents=True, exist_ok=True)
    count = 0
    for src in sorted(CLAUDE_WORKFLOWS.glob("*.js")):
        fields = parse_workflow_meta(src.read_text(encoding="utf-8"))
        if not fields or "name" not in fields:
            continue
        (CODEX_WORKFLOWS / f"{fields['name']}.md").write_text(
            workflow_procedure_doc(
                fields, "Codex",
                "spawn each phase's agents from `.codex/agents/*.toml` yourself with "
                "`spawn_agent` (one call per agent in that phase, up to the session's "
                "concurrency limit), `wait_agent` for them to finish, then move to the next "
                "phase, in the order below. Verified against the installed CLI "
                "(`codex features list`: hooks/multi_agent stable) on 2026-10-13 -- "
                "`spawn_agents_on_csv` does not exist; don't use it.",
            ),
            encoding="utf-8",
        )
        (GRAVITY_WORKFLOWS / f"{fields['name']}.md").write_text(
            workflow_procedure_doc(
                fields, "Antigravity",
                "delegate each phase to the matching subagent in `.agents/agents/*.md` "
                "yourself, in the phase order below.",
            ),
            encoding="utf-8",
        )
        count += 1
    print(f"ported {count} workflow procedure doc(s) -> .codex/workflows/*.md, .agents/workflows/*.md")


def deploy():
    """Mirror the canonical .claude/.codex and .claude/.agents out to the workspace root,
    where the real Codex/Antigravity CLIs actually look (confirmed live: `codex`/`agy` resolve
    .codex//.agents from the session cwd, not from inside .claude). The workspace root usually
    isn't a git repo itself, so this copy is a deploy target, not a second source of truth --
    same relationship as the kit repo itself being cloned into <workspace>/.claude."""
    for src_dir, dst_dir in ((KIT / ".codex", WORKSPACE / ".codex"), (KIT / ".agents", WORKSPACE / ".agents")):
        if dst_dir.exists():
            shutil.rmtree(dst_dir)
        shutil.copytree(src_dir, dst_dir)
    # AGENTS.md/GEMINI.md: Codex/Antigravity search upward from the session cwd (usually
    # WORKSPACE), never down into .claude, so the canonical file in .claude needs a copy here too.
    for name in ("AGENTS.md", "GEMINI.md"):
        shutil.copyfile(KIT / name, WORKSPACE / name)
    print(f"deployed -> {WORKSPACE / '.codex'}, {WORKSPACE / '.agents'}, {WORKSPACE / 'AGENTS.md'}, {WORKSPACE / 'GEMINI.md'}")


def check_stale():
    """--check: exit 1 if .codex/.agents would change, without writing. Wired into
    kit-health.ps1 (SessionStart) so drift between .claude/agents and the ported
    copies surfaces the same way any other kit-health nudge does."""
    stale = []
    for src in sorted(CLAUDE_AGENTS.glob("*.md")):
        fields, _ = parse_frontmatter(src.read_text(encoding="utf-8"))
        name = fields.get("name", src.stem)
        for path in (CODEX_AGENTS / f"{name}.toml", GRAVITY_AGENTS / f"{name}.md"):
            if not path.exists():
                stale.append(name)
    for src in sorted(CLAUDE_WORKFLOWS.glob("*.js")):
        wfields = parse_workflow_meta(src.read_text(encoding="utf-8"))
        if not wfields or "name" not in wfields:
            continue
        for path in (CODEX_WORKFLOWS / f"{wfields['name']}.md", GRAVITY_WORKFLOWS / f"{wfields['name']}.md"):
            if not path.exists():
                stale.append(wfields["name"])
    if stale:
        print(f"port-kit: stale or missing ports for {sorted(set(stale))}; run "
              f"'python -X utf8 skills/orchestrate/scripts/port-kit.py'")
        return 1
    return 0


if __name__ == "__main__":
    import sys
    if "--check" in sys.argv[1:]:
        sys.exit(check_stale())
    port_agents()
    port_hooks()
    port_workflows()
    deploy()
