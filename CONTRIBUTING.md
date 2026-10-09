# Contributing to claude-crew

Thanks for helping. A few rules keep the kit useful for everyone:

1. **Keep it generic.** No organisation names, hostnames, repo names, paths, people or credentials in the kit. Anything
   specific goes in a git-ignored `*.local.json`, in `CLAUDE.md`, or in your own skills. Examples use `example.com`,
   `com.example.app`, `qa-user-1`, `<your-gitlab-group>`.
2. **No hard-coded paths.** Scripts derive the kit from their own location (`$PSScriptRoot` / `kitconfig.ps1`), the
   workspace is the parent of `.claude`, runtime output goes to `$env:CLAUDE_RUNTIME` or `<workspace>/.claude-runtime`.
   Scripts run on Windows, Linux and macOS (pwsh 7): build paths with `Join-Path` (a `"$dir\file"` argument to a native
   command breaks off Windows, and `& "$K\x.ps1"` is parsed as module\command there), and use `dev-kit/scripts/sysinfo.ps1`
   for RAM, processes, directory links, temp folder, Python and the Android SDK instead of CIM, `%TEMP%` or `cmd /c`.
3. **Keep the docs true.** When a script's behaviour changes, update its `SKILL.md`, the orchestrate playbook, the agent
   definitions and `docs/configuration.md` in the same change. Generic lessons go in the skill's `LESSONS.md`.
4. **Check before you open a PR:**
   ```powershell
   # every PowerShell script parses (pwsh 7 on Windows, Linux or macOS)
   Get-ChildItem .claude -Recurse -Filter *.ps1 | ForEach-Object { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e); if ($e) { "$($_.Name): $($e[0].Message)" } }
   node --check .claude/skills/qa-kit/scripts/web/browser.mjs
   python -m py_compile .claude/skills/dev-kit/scripts/devtools.py   # and the other .py files
   ```
   Workflow files (`.claude/workflows/*.js`) run inside Claude Code's workflow runtime: to syntax-check one, wrap it in
   `async function __wf(){ ... }`, replace `export const meta` with `const meta`, and run `node --check` on the result.
   They must keep LF line endings (`.gitattributes` enforces it).
5. **Safety first.** Changes must not weaken the guard hook, the memory gate, the "never production" rule or secret redaction
   without a clear reason in the PR.

Use Conventional Commits (`feat(dev-kit): ...`, `fix(qa-kit): ...`). By contributing you agree your work is released under the MIT license.
