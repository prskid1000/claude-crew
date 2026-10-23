# Deploy batch (orchestrate E5, extra deploys)
A person says `deploy <env>` (`deploy.trigger: ask` only: supervise DEPLOY ASK -> ask ONCE per env; inside
`deploy.minIntervalHours` say when). Then at once, end to end, no question back:
1. `orch.ps1 deploy plan -Env <env>`: every session's merged-not-deployed MRs for that env.
2. Deploy per the org's deploy rules (`deploy merge` for a deploy branch).
3. `orch.ps1 deploy record -Env <env> -Mrs <refs> -By <who>`.
4. `orch.ps1 deploy intest -Apply` once live (supervise -AutoFix also moves live tasks to inTest).
