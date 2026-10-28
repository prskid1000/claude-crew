# github
- What: GitHub / GitHub Enterprise through the gh CLI: git host (PRs, merge, auto-merge), CI (Actions runs and jobs, check runs +
  commit statuses of an external CI) and tracker (issues; status = a `<tracker.statusLabelPrefix><name>` label, closed = closed issue).
Needed when: `gitHostType` = `github`, `gitHost` ~ `github`, `tracker.type` = `github`, `ci.type` = `github`, `repos.*.ci` = `github`, origin ~ `github` (the kit's or a repo's origin URL)
- Wiring: `skills/crafty/adapters/github.ps1` registers tracker/github, git-host/github and ci/github (lib.ps1 loads
  adapters/*.ps1); a github origin found without config stops with `git-host github is a goody: run kitbag.py goody add github`.
- Tracker config example: `{ "type": "github", "repo": "owner/name", "branchTag": "GH-", "statuses": { "failedTesting": "failed-testing" } }`.
- Tests: `tests.ps1` here.
