---
name: kit-audit
description: "Load when: you are the kit-auditor agent: the weekly kit audit is due (SessionStart nudge), or the owner asks to audit, review, recover or repair the whole kit, set it up or fix missing config. Not when: one kit script or rule failed -> orchestrate (Change the kit, HEAL); a retrospective of learning signals -> /kit-retro; auditing product code -> tech-audit."
argument-hint: "[focus: setup | config | recover | audit | all]"
---

**Load when** (all must hold): you are the `kit-auditor` agent (router R1b, orchestrate E21); the task is the whole kit, not one
script.
**Not when:** one failing script, hook or rule -> `orchestrate` K1-K6 (HEAL in the session that hit it); signals ->
`/kit-retro`; a product module -> `tech-audit`; coordinating waves -> `orchestrate`.
**Hands off to:** the lead (main session): merges your pushed `kit/audit-<date>` branch, answers the ASK list, approves the
proposals; follow-up fixes too big for the audit go to a kit change (`orchestrate` "Change the kit").
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `LESSONS.md` (+ LESSONS.local.md next to it: org lessons, git-ignored, when present) | step 0, before anything |
| `HISTORY.md` | never read for work (retired lessons; step 7 checks it for regressions) |
| `reference/audit-checklist.md` | step 4, before reading the first area; steps 5-6 use its §3-§4 |
| `templates/AUDIT_REPORT.md` | step 9, filled into `<runtime>/logs/kit-audits/audit-<date>.md` |
| `scripts/kit-audit.py` | steps 1-3 (`setup`, `config`, `recover` on the live clone), steps 4 and 8 (`scan` on your worktree), step 9 (`stamp`); `due` any time |

## Steps
`<kit>` = the live clone `<workspace>/.claude` (never edit its files: runs execute them); `<wt>` = your audit worktree.
`$A = 'python -X utf8 <wt>/skills/kit-audit/scripts/kit-audit.py'` (from pwsh). `<O>` = `<kit>/skills/orchestrate/scripts`.

0. **Start:** read `LESSONS.md`. `& <O>/board.ps1 join -Agent kit-auditor -Run kit-audit -Area kit` (DUPLICATE -> stop, report).
   Worktree: `git -C <kit> fetch`; `& <kit>/skills/dev-kit/scripts/wt.ps1 new -Repo <kit> -Branch kit/audit-<yyyy-MM-dd> -Target main
   -Name kit-audit`. Busy check: `launch-record.ps1 -List -Brief` + `board.ps1 show`: anything running -> no `--fix` that touches
   worktrees, board or cleanup (list them instead).
1. **Setup:** `$A setup` (install state: clone, pre-push gate, `localOnly` excludes, runtime folders, hooks run clean and fast,
   ports, `<workspace>/AGENTS.md`, CLIs and their auth, check only: never log in). `$A setup --fix` runs `kit-setup.ps1` (idempotent).
2. **Missing config:** `$A config` compares `kit.local.json`, `targets.local.json`, `swarm.config.json` with their examples,
   `configuration.md` and the keys scripts read. `--fill` writes only documented defaults (backup next to the file). Org values
   no default can supply (hosts, ids, credentials, `orgTerms`) are ASK lines: list them for the lead as `<file> <key>: why`.
   Never guess them, never print or copy a value from a local file (they hold secrets).
3. **Recover:** `$A recover` (live clone): uncommitted changes, behind/ahead, kit worktrees (prunable, merged, half-merged),
   merged local kit branches, tracked local-only files, launch records of dead runs, stale board entries, orphan product
   worktrees, cleanup.ps1 dry run, runtime size. `$A recover --fix` (only when step 0 found nothing running) repairs the safe
   ones; unmerged work is never deleted: list it with its exact command for the lead.
4. **Deep audit:** read `reference/audit-checklist.md`, then EVERY tracked file (`git -C <wt> ls-files`). Large: fan out up to
   6 read-only Explore agents, one per §1 area group, each told to return `file:line` + evidence; verify each yourself.
   `$A scan` (on `<wt>`) adds candidates (DOC-FLAG, PS-CASE, PS-FILE-ARRAY, CONFIG-*, ...). Keep only proven findings.
5. **Generic:** checklist §3 (org terms, hard-coded business values, absolute paths) -> config key with today's default.
6. **Consistency:** checklist §4 (Files indexes, configuration.md both ways, Router vs parts, agent tools, ports, LESSONS caps).
7. **Improve:** `& <O>/learn.ps1 -Stats` and `-Show -Last 300` (signals since the last audit), every `LESSONS.md` (2×+ lines),
   the newest `<runtime>/logs/retros/*.md`, `<runtime>/logs/guard.log`; a `HISTORY.md` "(fixed in kit)" problem seen again =
   regression finding. Each pattern -> the smallest durable change (script check or default > rule > lesson).
8. **Fix in `<wt>`:** blocking and should-fix findings with a small, safe fix (same behaviour for every other case); bigger
   ones and anything a still-open kit branch also changes -> proposed with the exact edit. New parts follow
   `orchestrate/reference/extending.md`. Then in `<wt>`: `python -X utf8 skills/orchestrate/scripts/kit-lint.py` (0 problems),
   `python -X utf8 skills/orchestrate/scripts/port-kit.py`, then `port-kit.py --check`, parse every touched .ps1, `py_compile`
   touched .py, `node --check` touched .mjs / wrapped workflows (CONTRIBUTING), `kit-cost.ps1 -Steps` after a workflow change,
   `kit-lint.py --org-terms <kit>/skills/dev-kit/kit.local.json`, `$A scan` again (no new ACT).
9. **Ship:** commit with `wt.ps1 commit` (Conventional Commits, the org's author rules), `git -C <wt> push -u origin
   kit/audit-<date>`; never push `main`, never merge. Report from `templates/AUDIT_REPORT.md` to
   `<runtime>/logs/kit-audits/audit-<date>.md`. `learn.ps1 -Skill <s> -Fixed "<words>"` only after the lead merged (say which).
   `$A stamp` (resets the weekly nudge, even when nothing was found); `board.ps1 leave`.

**Rules**
- The live clone is read-only for you except `kit-audit.py --fix / --fill`; every tracked change goes through `<wt>` and a push.
- Evidence or it is not a finding: `file:line`, the input that breaks it, what happens. Unproven -> "candidate" in the report.
- Keep the kit generic: org values go to the report's "kit.local.json additions", never into tracked files.
- Final reply ≤ 200 words: branch + commits, counts fixed / proposed / ASK, the report path, what the lead must do.
- Learn: `& <O>/learn.ps1 -Skill kit-audit -Kind <kind> -Text "<what + fix>"`.
