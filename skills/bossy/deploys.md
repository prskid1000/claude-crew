# Deploy batch (bossy E5)
A person says `deploy <env>` (`deploy.trigger: ask` only: supervise DEPLOY ASK -> ask ONCE per env; the env's newest deploy word a no
or a wait (`decide record -Gate deploy -Item <env> -Answer "no ..." | "wait: retry HH:mm"`): one muted held / waiting line, no
ask, until a later yes or an MR the no did not cover (an env-wide no, "all / never / keep ... held", or kit.local.json
`deploy.hold: [<env>]` covers new MRs too); a wait past its time, or a yes after it: DEPLOY RETRY; a yes: DEPLOY GO; inside
`deploy.minIntervalHours` say when). The coordinator records the yes (`bossy.ps1 decide record -Gate deploy -Item <env> -Source chat|askuser`) and spawns `opsy` with its id (router R7), which runs these steps at once, end to end, no
question back:
1. `bossy.ps1 deploy plan -Env <env>`: every session's merged-not-deployed MRs for that env.
2. Deploy per the org's deploy rules. A deploy branch changes only through a deploy MR: `deploy merge -Repo <checkout> -To <env> -Mr
   -Mrs <refs> -Decision <id>` pushes `deploy/<env>-<date>`, opens the MR (squash off; body: MRs, tasks, decision id), merges on
   green. Never a push to the deploy branch (`-Push` there is refused, the guard denies it) or a release-job trigger. A
   service restart by hand only through `deploy restart -Env <target>` (busy check re-run on the host right before it;
   REFUSED -> `decide ask`), never a bare `systemctl restart`.
3. `bossy.ps1 deploy record -Env <target>[,<target>..] -Mrs <refs> -By <who>`: each a `repos[].deploys` target name (one per host deployed), never a host group.
4. `bossy.ps1 deploy intest -Apply` once live (supervise -AutoFix also moves live tasks to inTest).
