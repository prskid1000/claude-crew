# tracker-gitlab
- What: GitLab issues as the kit tracker (glab api): status = a `<statusLabelPrefix><name>` label, closed = closed issue; parent and subtasks as on github.
- Config: `tracker.type: "gitlab"`, `tracker.repo` (group/project), `tracker.statusLabelPrefix`; glab authenticated.
Needed when: `tracker.type` = `gitlab`
- Wiring: `skills/dev-kit/adapters/tracker_gitlab.ps1`, dot-sourced by lib.ps1 before the tracker type is resolved. Tests: `tests.ps1` here.
