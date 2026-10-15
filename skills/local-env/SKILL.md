---
name: local-env
description: "Load when: you start, stop, deploy to, test or debug on a local environment (the one shared running instance of an app on this machine, from kit.local.json localEnv), build an APK or run a task from it, or a dev-kit step sends you here before merging. Not when: no localEnv is configured -> dev-kit; testing a deployed test environment -> qa-kit; emulator lanes -> android-swarm."
---

**Load when** (all must hold): `kit.local.json` has `localEnv.envs`; you are a dev agent at dev-kit step 6b (pre-staging check of
your branch), a tester or the main session checking or debugging something locally, or the coordinator starting, stopping or
refreshing an env.
**Not when:** no `localEnv` is configured -> `dev-kit` as before; a deployed test environment -> `qa-kit`; emulators and phone
lanes -> `android-swarm`; coordinating agents -> `orchestrate`.
**Hands off to:** `dev-kit` step 7 (MRs) once your branch is promoted locally; `qa-kit` tools (`browser.mjs`, `api.ps1`) for the
checks themselves; `android-swarm` lanes for an APK built from the env.
**Files** (every file in this folder; read or run each only at its step):

| File | Read / run at |
|---|---|
| `LESSONS.md` (+ LESSONS.local.md next to it: org/project lessons, git-ignored, when present) | step 0, before anything else |
| `scripts/localenv.ps1` | steps 1-6 (`envs`, `status`, `deploy`, `use`, `logs`, `promote`, `release`, `task`); coordinator: `up`, `down`, `refresh`, `drop` |

## What it is
Flow: **dev** (each agent's worktree and branch) -> **local** (this env, pre-staging) -> **test environments** -> **production**.
Each env (`localEnv.envs.<env>`, independent of the others) runs exactly one instance of its services (API, web dev server,
workers, Metro, infra) from its own worktrees `localenv-<env>-<repo>`: the repo's target branch with every deployed agent branch
merged on top as a **layer**. Any stack: a service is a start command in a folder (default from `dev-kit/scripts/stack.ps1` `run`).
Deploys queue (one writer at a time, first come first served); tests hold short **leases** that a deploy waits for. Builds go
through the memory gate; service starts wait for RAM and CPU room (emulators and builds included). Dependencies are linked from
the main checkouts (`wt.ps1`), never installed again. Secrets live only in the env's dotenv file (`<kit>/localenv.local/<env>.env`).

## Steps
```powershell
$L = '<workspace>/.claude/skills/local-env/scripts/localenv.ps1'
& $L envs; & $L status -Env <env>                                     # 1. which env runs your repo; what is live
& $L deploy -Env <env> -Agent <id> -Dir <your worktree>               # 2. after wt.ps1 commit: your branch becomes a layer (one call per repo)
& $L use -Env <env> -Agent <id> -Note "<checks>"                      # 3. lease (15 min; call again to renew) - then test
& $L logs -Env <env> -Service <s> -Tail 120                           # 4. debug: server output (fix -> commit -> deploy again)
& $L promote -Env <env> -Branch <branch> -Agent <id> -Note "<passed>" # 5. pre-staging passed with the other layers live
& $L release -Env <env> -Agent <id>                                   # 6. always, also when you stop early
& $L task -Env <env> -Task <name> -Agent <id>                         # (as needed) a configured one-shot task, e.g. an APK from the env
```
0. Read `LESSONS.md`.
1. Pick the env whose services run your repo (`envs`). `status` shows services, layers (`testing` / `PROMOTED`, `MIGRATIONS`),
   leases and the deploy queue.
2. **Deploy** only committed work (`wt.ps1 commit` first). `deploy` waits its turn, merges your branch on the target + the other
   layers, builds (gated), restarts only the services of the changed repos (hot services reload) and waits for their health checks.
   **Refused** (conflict) -> `wt.ps1 sync`, resolve on your branch, deploy again. **Rolled back** (build or health failed) -> read
   the printed log tail / `logs`, fix, deploy again. The other agents' layers stay as they were.
3. **Test** under a lease, against the service URLs from `status` (web: `qa-kit/scripts/web/browser.mjs`, API: `qa-kit/scripts/api.ps1`
   with a `targets.local.json` entry for the env), headless as always. Use your own test data (prefix it with your agent id); an
   unexpected change may be another layer's (check `status` before calling it a defect of yours).
4. Redeploying the same branch replaces your layer (and clears its promotion).
5. **Promote** when your checks passed: the pre-staging stamp the dev-kit ship steps and the coordinator look for. Put it in your
   final reply and the MR body ("Locally promoted on <env> v<n>").
6. **Release** your lease. After your MR merges, your layer drops itself at the next deploy or refresh.

**Rules**
- Never start dev servers by hand (`ng serve`, `spring-boot:run`, `dotnet run`, `npm start`, ...): the guard blocks them while
  `localEnv` is configured. Never edit files in the env worktrees, never push `localenv/*` (blocked), never install dependencies there.
- One lease at a time per agent, as short as the checks; a deploy waits at most `drainMinutes` (default 10) for open leases.
- A layer flagged `MIGRATIONS` changes the shared local database for every layer: say so in your reply; dropping it does not undo it.
- `up`, `down`, `refresh`, `drop` are the coordinator's (or the owner's); a dev agent deploys, uses, promotes and releases only.
- Out of RAM: the start waits (prints the biggest users) and fails after `roomWaitMinutes`; report it, do not kill other processes.
- Learn: `& <workspace>/.claude/skills/orchestrate/scripts/learn.ps1 -Skill local-env -Kind <kind> -Text "<what + fix>"`.
