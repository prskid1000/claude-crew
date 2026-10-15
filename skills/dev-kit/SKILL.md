---
name: dev-kit
description: "Load when: you write, build, test or ship code in a repo of this workspace: as a dev-agent from a brief, or directly for one small change (router R14). Not when: you coordinate several agents -> orchestrate; you test deployed work -> qa-kit; you audit code without changing it -> tech-audit; you review someone's MRs -> mr-reviewer agent."
---

**Load when** (all must hold): you change code in a repo of this workspace; you are a `dev-agent` working from a brief, or the main
session on router row R14 (one small change).
**Not when:** coordinating agents -> `orchestrate`; testing deployed work -> `qa-kit`; static audit -> `tech-audit`; reviewing
MRs -> `mr-reviewer` agent; emulators -> `android-swarm` (dev agents never start them).
**Hands off to:** the coordinator (your final reply; `track.ps1` promotes the task), `qa-kit` testers through your tester guide
(step 7b), `mr-reviewer` inside a reviewed /dev-wave, `local-env` at step 6b (only when the owner or your brief asks for a local check).
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `LESSONS.md` (+ LESSONS.local.md next to it: org/project lessons, git-ignored, when present) | step 0, before anything else |
| `HISTORY.md` | never read for work (retired lessons) |
| `reference/tracker.md` | step 0b, before your first tracker call |
| `reference/worktrees-and-gate.md` | step 0/1 when board.ps1 or wt.ps1 warns; step 4 when the gate holds a build > 10 min or kills it |
| `reference/migrations.md` | step 4c, before adding or changing a DB migration |
| `reference/shipping.md` | step 7 (§8, before opening MRs), step 7b (§7, the tester guide), on a merge conflict (§8.3) |
| `reference/configuration.md` | setup (S1) and when adding a config key (orchestrate `reference/extending.md`) |
| `kit.example.json` | setup S1: copy to `kit.local.json` |
| `scripts/wt.ps1` | steps 1, 2, 5, 6 (`new`, `sync`, `commit`, `remove`, `status`) |
| `scripts/stack.ps1` | step 3 |
| `scripts/check.ps1`, `scripts/gate.ps1` | step 4 and 6 (every build/test; `gate.ps1 -Cmd` for anything check.ps1 doesn't cover) |
| `scripts/node-spec.mjs` | step 4b: the test command `stack.ps1` / `check.ps1 -Step test` use for a web project with no unit-test target (`*.spec.ts` under node, bundled with the project's esbuild; DOM specs under the project's jsdom, TestBed specs NOT RUN; real `@angular/core` with `check.ps1 -RealAngular`, auto-on for specs importing `@angular/forms`) |
| `scripts/lib/spec-shim.mjs` | library imported by `node-spec.mjs` (jasmine/jest-style describe/it/expect/spyOn); never run by hand |
| `scripts/lbcheck.py` | run by `check.ps1 -Step migrations` (step 4c) |
| `scripts/keepboth.py` | step 6, on an append-only changelog rebase conflict |
| `scripts/devtools.py` | step 7 (`mr`), 7b (`doc`), 8 (`merge`) |
| `scripts/tracker.ps1` | step 0b and 7b/8 (status, comment, attach) |
| `scripts/pipe-wait.ps1` | run by /dev-wave's CI step (MR pipelines before merge) |
| `scripts/deploy-merge.ps1` | coordinator only, after a person approved a deploy: merges the main line into a deploy branch |
| `scripts/guard.ps1` | PreToolUse hook (blocks stash, --no-verify, force-push, adb kill-server, ungated builds) |
| `scripts/kitconfig.ps1`, `scripts/sysinfo.ps1` | libraries dot-sourced by the other scripts (config, OS specifics); never run by hand |
| `scripts/kitpaths.json`, `scripts/kitpaths.ps1`, `scripts/kitpaths.py`, `scripts/kitpaths.mjs` | libraries: the one map of runtime and durable local paths (`Get-KitPath` / `kit_path` / `kitPath`); every script resolves paths through them, never by hand |

## Steps (every dev agent; your **brief** wins where it differs)
Your brief (orchestrate templates WAVE / BUGFIX / RESUME) gives your items, area, repos + target branches, branch, worktree name,
migration range and tracker task. The repo's own `CLAUDE.md` / conventions also apply. Scripts: PowerShell (Linux/macOS: `pwsh`;
`python` hangs in git-bash, use `python3` off Windows). Org settings: `kit.local.json` next to this file.

```powershell
$K = '<workspace>/.claude/skills/dev-kit/scripts'; $B = '<workspace>/.claude/skills/orchestrate/scripts/board.ps1'
& $B join -Agent <id> -Run <wave> -Area "<area>" -Items "<ids>" -Claims <worktrees> -Contracts <brief>.contracts.md   # 0. board (keep the SESSION token)
& $K/tracker.ps1 status <task> inProgress                        # 0b. task in progress (read reference/tracker.md first)
& $K/wt.ps1 new -Repo <main checkout> -Branch <branch> -Target <target> -Name <prefix>   # 1. worktree (deps linked)
& $K/wt.ps1 sync -Dir <wt>                                       # 2. rebase onto latest target - before editing
& $K/stack.ps1 -Dir <wt>/<module>                                # 3. this module's build/test commands
& $K/check.ps1 -Dir <wt>/<module>                                # 4. compile + typecheck + lint (gated; "typecheck UNRUN" = say so in the MR)
& $K/check.ps1 -Dir <wt>/<module> -Step test -Tests "<names>"    # 4b. targeted tests only (no test target: node-spec.mjs runs the specs; exit 4 = start Docker for container tests)
& $K/check.ps1 -Dir <wt>/<module> -Step migrations               # 4c. if you touched DB migrations (must print ISSUES 0)
& $K/wt.ps1 commit -Dir <wt> -Message "feat(scope): ..."         # 5. commit with hooks really running
& $K/wt.ps1 sync -Dir <wt>; & $K/check.ps1 -Dir <wt>/<module>    # 6. re-read <brief>.contracts.md, rebase + re-check before push
# 6b. ONLY when the owner/brief asks for a local check: local-env skill steps 1-6 (deploy -Dir <wt>, use, test, promote, release)
git -C <wt> push -u origin <branch>
python $K/devtools.py mr <wt> "<title>" body.md                  # 7. MR/PR (GitLab or GitHub, from the remote)
python $K/devtools.py doc "<title>" <guide.html>                  # 7b. tester guide (complex change) -> link it on the task + MR;
                                                                #     simple change: tracker.ps1 comment <task> with how-to-test steps
python $K/devtools.py merge <wt> <iid>                           # 8. merge-when-green (no CI: at once); last line = MERGED|SCHEDULED|WAIT|... (NOT in a reviewed /dev-wave)
& <workspace>/.claude/skills/orchestrate/scripts/track.ps1 add -Task <task id> -Mrs <repo>!<iid>,...   # 8b. coordinator promotes when all merge
& $B leave -Session <token> -Status done                         # 9. leave the board
```
Setup (S1, once per workspace, coordinator): copy `kit.example.json` to `kit.local.json` (keys: `reference/configuration.md`).

**Rules**
- **Board:** `join` first (DUPLICATE for your id → stop without writing); `beat -Session <t> -Status "<doing>"` before builds and pushes;
  `check -Worktree <wt> -Session <t>` before each commit (another writer → stop, tell the coordinator); `leave` at the end.
- **Worktrees:** one per repo via `wt.ps1 new`; deps-differ warning → `-LinkFrom <checkout of the target branch>`; never install into a
  linked `node_modules`/`.venv` (say what you need instead); remove with `wt.ps1 remove`. `wt.ps1 sync` before editing, before every push, before merging.
- **Gate:** every build/test through `check.ps1` (or `gate.ps1 -Cmd "<cmd>"`), never Maven/Gradle/dotnet/ng/jest/pytest/cargo directly;
  waiting is normal, a killed build is not a code failure (re-run). Targeted tests only. No dev servers by hand (they run in the local env: `local-env`), no emulators, ≤ 1 headless browser.
  A gate still queued when you are told to stop or your turn ends is unrun: never leave commits local. Push, open the MR as Draft with
  `Not run: <gate>` in the MR body (MR_BODY "Verified") and the tracker comment, and report mergeState `NOT_MERGED`.
  Call `check.ps1` / `gate.ps1` with a tool timeout of 600000 ms (or `run_in_background` for builds over 10 min): the 120 s default
  is shorter than a normal Maven test, Android build or first jest run in a fresh worktree plus the gate queue, and a timed-out call leaves the gate unrun.
- **Specs:** a change to pure logic (helper, formatter, gate/status set, bucket/zero-fill) or a template-only placement fix ships a
  committed spec in the same MR (no unit-test target: `check.ps1 -Step test` runs it through node-spec.mjs); a template change with no
  spec attaches a 1366x768 screenshot. A throwaway node check does not count.
- **Commits:** Conventional Commits ending with a blank line + the attribution trailer your harness/org asks for; `wt.ps1 commit` only;
  never `--no-verify`, never type a hook's marker, never change shared git config, never `git stash` (WIP commit instead).
- **Scope:** only your items, no sweeps of similar code, never remove features or inputs; changes are additive (optional fields, new
  endpoints/params, flags); DTOs not entities in APIs; foreign files only as one-line hooks you list in your reply; decisions in the brief are final (new decision needed → defer with a reason).
- **Shared code:** before you change a shared helper, hook, service, exception translator, formatter, validator, default or global
  style, grep every caller, writer and consumer. Make overrides opt-in, key shared formatters/styles by field or selector (fix a
  variant in the component's own style, not with an `!important` global) and add a round-trip test. In the MR body and in
  `needsLiveCheck`, list each caller or endpoint the change reaches and the main-path flow that needs a live check before merge.
- **Text files:** write code, briefs, guides and MR bodies with the Write tool and change files with Edit, then pass the file path
  (`devtools.py doc <file>`, MR body from a file). Never Bash heredocs, sed or python string-replace for text with backslashes,
  quotes or CRLF line endings (Git Bash turns `\b` into a backspace, apostrophes give "unexpected EOF", replace misses CRLF).
- **Migrations (4c):** only your assigned range; never edit a merged migration; per-tool rules in `reference/migrations.md`.
- **Ship (6-8):** re-read `<brief>.contracts.md` and the brief's bottom (rule changes are appended there mid-wave) before pushing
  (append-only if you write to it); one MR per repo, title with `<tag><task>` in it (e.g. `feat: <summary> - <CODE> (<tag><task>) (<Repo>)`, or the brief's format), body from `orchestrate/templates/MR_BODY.md`; in a reviewed `/dev-wave` don't
  schedule merges (the workflow does after review); producers (DB/API) merge before consumers; force-push only your own branch (`--force-with-lease`).
- **Tracker:** always `scripts/tracker.ps1` (never a tracker CLI): `inProgress` → `review` once MRs are open and the testing instructions (7b) posted → `promoted` when all merged; never `inTest`.
- **Testing instructions (mandatory, step 7b):** every change that a tester can check gets them before the task moves to `review`.
  `python devtools.py guide-mode` prints `always` (config `reports.guide`): then every change gets the published guide below,
  with its screenshots, and the task comment links it. Otherwise: simple (one screen / one endpoint): a how-to-test comment on the task. Complex (several screens or flows, more than one repo,
  migrations, roles/permissions, reports): a tester guide from `qa-kit/templates/tester-guide.html` (check ids, environment, accounts,
  data to prepare, steps and a concrete Expected per check; include "unchanged" checks for what must not change; always name the
  feature switches: the settings or roles that switch the feature on, checked ON, in "Before you start / Feature switches"; a
  how-to-test comment names them too), published with
  `devtools.py doc "<title>" <file>` (a `.md` guide is converted to HTML, tables kept) and linked on the task and in the MR. Report the link as `testerGuide`.
- **Evidence:** UI → screenshots, backend → `qa-kit/scripts/api.ps1 -Save` JSON; never production; a 404/405 on an endpoint that exists on the target branch = stale deploy, not a code bug.

**Final reply (≤ 200 words):** MRs + merge state · tester guide / how-to-test link · done / deferred ids with reasons · settings/data to seed · what needs a live check ·
hooks left in other areas · dependencies you needed but didn't install.

**Learn:** something cost time, failed or worked unusually well → one line:
`& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill dev-kit -Kind <kind> -Text "<what + fix>"`. The guard hook's
message names the right command when it blocks something.
