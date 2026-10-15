# githost.ps1 with mocked CLIs (no network): GitLab passes paths through to glab, GitHub translates them to gh and reshapes the answers.
#   pwsh -NoProfile -File <kit>/skills/dev-kit/tests/test-githost.ps1      exit 0 = all pass, 1 = a check failed
$ErrorActionPreference = 'Stop'
$fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
$script:calls = [Collections.Generic.List[string]]::new()
function glab { $script:calls.Add("glab $($args -join ' ')"); $global:LASTEXITCODE = 0; '{"iid":5,"state":"merged"}' }
function gh {
  $script:calls.Add("gh $($args -join ' ')"); $global:LASTEXITCODE = 0
  $p = "$($args[1])"
  switch -Regex ($p) {
    'pulls/7/files' { '[{"filename":"a.txt"},{"filename":"b.txt","previous_filename":"old.txt"}]'; break }
    'pulls/7$' { '{"number":7,"title":"feat: x GH-12","state":"open","head":{"ref":"f/x","sha":"abc"},"base":{"ref":"main"},"merge_commit_sha":null,"merged_at":null,"draft":false,"mergeable":false,"mergeable_state":"dirty","auto_merge":null,"html_url":"https://github.com/o/r/pull/7"}'; break }
    'pulls/8$' { '{"number":8,"title":"t","state":"closed","merged_at":"2026-10-15T10:00:00Z","head":{"ref":"f/y","sha":"def"},"base":{"ref":"main"},"merge_commit_sha":"m8"}'; break }
    'check-runs' { '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}'; break }
    'compare/' { '{"merge_base_commit":{"sha":"base1"},"files":[{"filename":"a.txt"}]}'; break }
    'actions/runs\?' { '{"workflow_runs":[{"id":11,"head_sha":"m8","created_at":"2026-10-15T11:00:00Z","conclusion":"success"}]}'; break }
    'actions/runs/11/jobs' { '{"jobs":[{"id":3,"name":"deploy-staging","conclusion":"success","completed_at":"2026-10-15T11:05:00Z"}]}'; break }
    default { '{}' }
  }
}
$lib = Join-Path (Split-Path $PSScriptRoot) 'scripts/githost.ps1'
. $lib
$script:HostType = 'gitlab'
$m = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'
Expect 'gitlab: path passed to glab api unchanged' ($script:calls[-1] -eq 'glab api projects/g%2Fr/merge_requests/5' -and $m.state -eq 'merged')
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5/merge' -Method PUT -Fields @{ squash = 'true' }
Expect 'gitlab: PUT with fields' ($script:calls[-1] -eq 'glab api -X PUT projects/g%2Fr/merge_requests/5/merge -f squash=true')
$script:HostType = 'github'
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/7'
Expect 'github: PR reshaped to MR fields' ($m.iid -eq 7 -and $m.state -eq 'opened' -and $m.source_branch -eq 'f/x' -and $m.has_conflicts -and $m.detailed_merge_status -eq 'conflict')
Expect 'github: failed check run -> pipeline failed' ($m.head_pipeline.status -eq 'failed')
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'
Expect 'github: merged PR' ($m.state -eq 'merged' -and $m.merge_commit_sha -eq 'm8')
$c = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/changes'
Expect 'github: changes with renames' (@($c.changes).Count -eq 2 -and $c.changes[1].old_path -eq 'old.txt')
$b = Invoke-HostApi 'projects/o%2Fr/repository/merge_base?refs[]=abc&refs[]=staging'
Expect 'github: merge base via compare' ($b.id -eq 'base1')
$p = @(Invoke-HostApi 'projects/o%2Fr/pipelines?ref=staging&per_page=10')
$j = @(Invoke-HostApi "projects/o%2Fr/pipelines/$($p[0].id)/jobs?per_page=100")
Expect 'github: workflow runs + jobs as pipelines' ($p[0].sha -eq 'm8' -and $j[0].name -eq 'deploy-staging' -and $j[0].status -eq 'success')
$null = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/merge' -Method PUT -Fields @{ merge_when_pipeline_succeeds = 'true' }
Expect 'github: merge-when-green -> gh pr merge --auto' (@($script:calls | Where-Object { $_ -like 'gh pr merge 7 -R o/r --squash --delete-branch --auto' }).Count -eq 1)
Expect 'github: unknown path -> null' ($null -eq (Invoke-HostApi 'projects/o%2Fr/wiki' 3>$null))
"$fails failure(s)"; exit [int]($fails -gt 0)
