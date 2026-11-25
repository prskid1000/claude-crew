# Deploy batch (bossy E5)
A person says `deploy <env>` (`deploy.trigger: ask` only: supervise DEPLOY ASK -> ask ONCE per env; the env's newest deploy word a no
or a wait (`decide record -Gate deploy -Item <env> -Answer "no ..." | "wait: retry HH:mm"`): one muted held / waiting line, no
ask, until a later yes or an MR the no did not cover (an env-wide no, "all / never / keep ... held", or kit.local.json
`deploy.hold: [<env>]` covers new MRs too); a wait past its time, or a yes after it: DEPLOY RETRY; a no / wait `until run <run>
done` / `until tasks <ids> merged` (or `until all of <run name> is merged`): muted until it holds, then one DEPLOY ASK; a yes: DEPLOY GO; inside
`deploy.minIntervalHours`, per repo and env (`minIntervalScope: env` = per env), say when). The coordinator records the yes (`bossy.ps1 decide record -Gate deploy -Item <env> -Source chat|askuser`) and spawns `opsy` with its id (router R7), which runs these steps at once, end to end, no
question back:
1. `bossy.ps1 deploy plan -Env <env>`: every session's merged-not-deployed MRs for that env.
2. Deploy per the org's deploy rules. A deploy branch changes only through a deploy MR: `deploy merge -Repo <checkout> -To <env> -Mr
   -Mrs <refs> -Decision <id>` pushes `<deploy.branchPrefix, deploy/><env>` (one per env, reused; no date or counter in a ref; tags `deploys[].tag` `{n}` = the head's sha7), opens the MR (`deploy.mergeMethod`, merge: squash off; body: MRs, tasks, decision id), merges on
   green; a call waits `-WaitMinutes` (8), a re-run resumes the open deploy MR; `-Commit <sha>` deploys one commit of the source branch (never a hand-pushed pin branch). Never a push to the deploy branch (`-Push` there is refused, the guard denies it) or a release-job trigger. A
   service restart by hand only through `deploy restart -Env <target>` (busy check re-run on the host right before it;
   REFUSED -> `decide ask`; ssh rows: `ssh.manager` systemd | docker | pm2 | custom restartCmd, `ssh.sudo`; awsStack: `ecsService` (`ecsCluster`):
   a new ECS deployment; laneApk: the app stopped on phones free or leased by -Agent, never another holder's; a row's `command.restart` wins over its kind), never a bare service restart.
   ssh deploys hold `ssh.lockFile` (default `/tmp/kit-deploy-<target>.lock`: the pid) while they run: the plan's DEPLOYING; a CI deploy may write it too.
   Any kind: `deploy run -To <env> -Mrs <refs> -Decision <id>` runs each row's kind `deploy` verb (branch-mr / ci-job / tag: deploy
   merge; command, or any row's `command.deploy`; ssh: `ssh.deployCmd`; awsStack: `template` (repo path) at the deploy head; laneApk: phoney.ps1 build;
   manual: prints `manual`, a person deploys); while it runs the plan says DEPLOYING; UNSUPPORTED / FAILED rows: by hand, then record.
3. `bossy.ps1 deploy record -Env <target>[,<target>..] -Mrs <refs> -By <who>`: each a `repos[].deploys` target name (one per host deployed), never a host group.
4. `bossy.ps1 deploy intest -Apply -Env <target> -Mrs <refs>` once live: those MRs' tasks move when all their MRs are live; no
   -Mrs / -Env: every promoted task, whoever deployed it (supervise -AutoFix runs that sweep while no opsy is live: FIXED lines; a
   deployed state it cannot read: a STATUS WATCH). `PAGE` -> the same command again: a cursor per env goes on where it stopped.
Deploy kinds (`repos[].deploys[].kind`, else from the row keys): ci-job (branch + job), branch-mr, ssh, awsStack, probe, tag, manual, laneApk,
command (`{ isDeployed, lastDeploy, isRunning, restart, deploy }` command lines: `{sha} {target} {branch} {repo} {mr} {service}`). Verbs: pokey adapters/deployed-checks.ps1;
a verb a kind lacks = UNKNOWN. Production = `deploys[].production`, else `deploy.productionPattern` (no default).

## Before an ask
An ask (`decide ask`, AskUserQuestion) about testing, deploying or a task's state: first `pokey.ps1 deployed -Mrs <its MRs>` and
`crafty.ps1 tracker view <id>`, their result in the ask; every MR deployed and the task in test: no ask, route it (R8 `/testy` when it
has a human testing doc and no org row sends it to a person). ENV-FIX and other decisions: as before.
