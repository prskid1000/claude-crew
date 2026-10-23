# gitlab
- What: GitLab / self-hosted GitLab through the glab CLI: git host (MRs, merge, auto-merge, `branch.protect`), CI (pipelines,
  jobs, logs, `.gitlab-ci.yml` detection) and tracker (issues; status = a `<statusLabelPrefix><name>` label, closed = closed
  issue; parent and subtasks as on github). A self-hosted `gitHost` sets `GITLAB_HOST` for glab.
- Config: `gitHostType: "gitlab"` (also the type of an origin host the kit does not recognise), `gitHost`, `gitlabGroup`;
  tracker: `tracker.type: "gitlab"`, `tracker.repo` (group/project), `tracker.statusLabelPrefix`; glab authenticated.
Needed when: `gitHostType` = `gitlab`, `gitHost` ~ `gitlab`, `tracker.type` = `gitlab`, `ci.type` = `gitlab`, `repos.*.ci` = `gitlab`, origin ~ `gitlab` (the kit's or a repo's origin URL)
- Wiring: `skills/dev-kit/adapters/gitlab.ps1` registers git-host/gitlab, ci/gitlab and tracker/gitlab (lib.ps1 loads
  adapters/*.ps1); without it a gitlab host stops with `git-host gitlab is an extra: run kittool.py extra add gitlab`.
- Tests: `tests.ps1` here.
