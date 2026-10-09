# Workspace instructions (template — edit for your org)

This file is loaded into every Claude Code session started in this workspace. Keep it short: global rules here,
everything long goes into skills (loaded on demand) or path-scoped rules (`rules\*.md`).
**Never put passwords, tokens or API keys here** — test logins live only in `skills\qa-kit\targets.local.json` (git-ignored).

## Multi-agent work (any repo, any stack)
See `.claude\rules\multi-agent.md` (always loaded). Playbook: the `orchestrate` skill. Workflows: `/dev-wave`, `/test-and-close`,
`/kit-retro`. Subagent types: `dev-agent`, `mr-reviewer`, `qa-tester`, `qa-verifier`.
Org settings the scripts read (git host, GitLab group, repos root, tracker repos, protected branches) go in
`skills\dev-kit\kit.local.json` (copy `kit.example.json`).

## CLIs

- **Always check auth before using** (never log in headlessly):

| CLI | Purpose | Auth check |
|-----|---------|------------|
| `glab` (or `gh`) | GitLab (GitHub) — clone, push branches, open MRs/PRs | `glab auth status` / `gh auth status` |
| `clickup` | Tracker: read tasks, post comments, set statuses (replace with your tracker's CLI) | `clickup task view <id> --json` |
| `gws` | Google Workspace — publish tester guides and QA reports as Google Docs | resolve with `shutil.which()` on Windows |
| `<your-cli>` | <purpose, e.g. cloud logs / observability queries> | `<auth check command>` |

- **Windows note:** resolve shims (`gws`, `clickup`, `npx`, ...) with `shutil.which()` before `subprocess`.

## Tracker workflow (example — adapt the status names to your board)
1. **Start:** set the task to `in progress` and write the problem in the task description.
2. **Open MRs:** put the task link and a short solution summary in each MR description, then set the task to `in review`.
3. **Comment on the task:** the solution and the MR links (`skills\orchestrate\templates\TASK_SOLUTION.md`).
4. **Testing instructions:** a comment for a simple change; a tester guide (`skills\qa-kit\templates\tester-guide.html`,
   published as a Google Doc anyone with the link can view) for a complex one.
5. **After the MRs merge:** `promoted` (the coordinator's `track.ps1` does this automatically).
6. **After deployment:** `in test` — set by a person, never before deployment.

## Shipping code
- **Branch:** feature → `f/CU-<task-id>-<slug>` (a tracker id prefix lets the tracker link the branch), bugfix → `fix/...`, refactor → `refactor/...`.
- **Commit** in Conventional Commits: `feat(scope):` / `fix(scope):` / `refactor(scope):`.
- **MRs:** one per repo; cross-link MRs when a task spans repos; always include the task URL.
- **New tracker task?** Set its owner/assignee to the person who asked you to create it.

## Testing evidence
- UI changes → screenshots; backend-only changes → API request/response JSON (`skills\qa-kit\scripts\api.ps1 -Save`).
- Large files (payloads, logs) → upload to Drive and share links only.
- Collect everything in one Google Doc (anyone with the link can view) and attach it to the task.
- Rules and naming: `skills\qa-kit\reference\evidence-standard.md`.

## Command labels (suggested convention)
Descriptions shown for tool calls (Bash/PowerShell `description`) are short and a little fun: one fitting emoji + 3-7 plain words, e.g. `🛰️ Supervisor sweep with auto-fixes`, `🧪 Test the new checker`, `🚀 Push the kit to GitHub`. Never emoji-only, never vague.

## Org specifics (fill in)
- Products / repos and what each one is: `<repo> — <one line>`.
- Test environments (names only; URLs and logins go in `targets.local.json`): `<my-staging>`.
- Code conventions: add path-scoped rules to `rules\` (examples in the repo's `examples/rules/`).
- On-demand references (database access, observability queries, ...): add them as skills under `skills\<name>\SKILL.md`.
