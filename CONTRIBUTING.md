# Contributing to claude-crew

Thanks for helping. A few rules keep the kit useful for everyone:

1. **Keep it generic.** No organisation names, hostnames, repo names, paths, people or credentials in the kit. Anything
   specific goes in a git-ignored `*.local.json`, in `CLAUDE.md`, or in your own skills. Examples use `example.com`,
   `com.example.app`, `qa-user-1`, `<your-gitlab-group>`.
2. **No hard-coded paths.** The repo root is the kit (a workspace's `.claude` folder). Scripts derive the kit from their own
   location (`$PSScriptRoot` / `kitconfig.ps1`), the workspace is the parent of the kit, and every runtime or local-state path
   is a name in `skills/dev-kit/scripts/kitpaths.json` resolved with `Get-KitPath` / `kit_path` / `kitPath` / `rp()`
   (`docs/runtime.md`; kit-lint `RUNTIME-RAW` fails on hand-built paths).
   Scripts run on Windows, Linux and macOS (pwsh 7): build paths with `Join-Path` (a `"$dir\file"` argument to a native
   command breaks off Windows, and `& "$K\x.ps1"` is parsed as module\command there), and use `dev-kit/scripts/sysinfo.ps1`
   for RAM, processes, directory links, temp folder, Python and the Android SDK instead of CIM, `%TEMP%` or `cmd /c`.
3. **Keep the docs true.** When a script's behaviour changes, update its `SKILL.md`, the orchestrate playbook, the agent
   definitions and `skills/dev-kit/reference/configuration.md` in the same change. Generic lessons go in the skill's `LESSONS.md`
   (active rules only, ≤ 40 lines: add with `learn.ps1 -Lesson`, retire with `learn.ps1 -Fixed`; moved lines live in `HISTORY.md`).
4. **Check before you open a PR** (from the kit root):
   ```powershell
   # every PowerShell script parses (pwsh 7 on Windows, Linux or macOS)
   Get-ChildItem skills, .githooks -Recurse -Filter *.ps1 | ForEach-Object { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e); if ($e) { "$($_.Name): $($e[0].Message)" } }
   node --check skills/qa-kit/scripts/web/browser.mjs
   python -m py_compile skills/dev-kit/scripts/devtools.py   # and the other .py files
   ```
   Workflow files (`workflows/*.js`) run inside Claude Code's workflow runtime: to syntax-check one, wrap it in
   `async function __wf(){ ... }`, replace `export const meta` with `const meta`, and run `node --check` on the result.
   They must keep LF line endings (`.gitattributes` enforces it).
   `python skills/orchestrate/scripts/kit-lint.py` must print 0 problems: every skill, workflow and agent routed in
   `CLAUDE.md`, every file in its skill's Files index with a step, no fuzzy triggers or dangling paths (how to add each kind of part:
   `skills/orchestrate/reference/extending.md`). It also regenerates `<runtime>/cache/kit-flow.html`.
   `pwsh -File skills/orchestrate/scripts/kit-cost.ps1 -Steps` runs every workflow with mock agents (a full syntax and
   flow check) and lists each step's label, agent type and model: diff it before/after a workflow change. `kit-cost.ps1 -Baseline
   docs/kit-cost.before.json` shows the token budget per agent type; keep SKILL.md steps ≤ 60 lines (plus the Files index) and LESSONS.md ≤ 40.
   Run `kit-setup.ps1` once in your clone: the pre-push hook then blocks org terms (`orgTerms` in your `kit.local.json`)
   and git-ignored / local-only files on every push.
5. **Safety first.** Changes must not weaken the guard hook, the memory gate, the "never production" rule or secret redaction
   without a clear reason in the PR.

Use Conventional Commits (`feat(dev-kit): ...`, `fix(qa-kit): ...`). By contributing you agree your work is released under the MIT license.
