#Requires -Version 7
<#
kit-tests.ps1: offline kit tests (throw-away kit copies, local git repos, mocked CLIs, no real services).
Run after a kit script change (orchestrate K2): pwsh -NoProfile -File <kit>/tests/kit-tests.ps1 [-Area dev|qa|orch|local|all]
Inputs: the kit next to this folder. Outputs: PASS / FAIL lines and a total. Exit codes: 0 pass · 1 a check failed · 2 usage error.
#>
param([ValidateSet('dev', 'qa', 'orch', 'local', 'all')][string]$Area = 'all')
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot   # the kit
$script:fails = 0
function Kd { Split-Path $k }
function Px { $input | pwsh -NoProfile -File @args }
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
# one Expect per key: a "<key>:true" line in $res ('#' in $label = the key); -Show N: N lines on a miss
function Expect-Each($res, [string]$label, [string[]]$keys, [int]$Show = 0) {
  foreach ($x in $keys) { Expect $label.Replace('#', $x) (@($res | Where-Object { "$_" -eq "${x}:true" }).Count -eq 1) }
  if ($Show -and @($res | Where-Object { "$_" -match ':true$' }).Count -ne $keys.Count) { $res | Select-Object -First $Show }
}
# workflow sims: shared fixtures + $js; __BODY__ = the workflow source
$jsLib = @'
const _ck = (id, result, extra = {}) => ({ id, subtask_id: 'T1', screen: 's', result, what_was_done: 'w', observed: `o ${id}`, evidence: [], attempts: 1, ...extra })
const _res = (code, checks) => ({ code, checks, findings: [], setup_changes: [], data_created: [] })
const _rep = (localTest, extra = {}) => ({ mrs: [{ url: 'https://h/g/api/-/merge_requests/1', repo: 'api', merged: false }], worktrees: ['C:/wt/x1'], done: ['A1'], deferred: [], needsDecision: [], needsEnvFix: [], localTest, needsLiveCheck: [], seed: [], foreignHooks: [], summary: 's', testerGuide: 'https://doc', ...extra })
const _merged = (n) => ({ mrs: [{ url: `https://h/g/api/-/merge_requests/${n}`, repo: 'api', merged: true, mergeState: 'MERGED' }] })
const _rec = () => ({ ok: true, output: 'RECORDED' })
const _ok = (output) => ({ ok: true, output, signals: 0, lessonsChanged: [] })
const _err = (e) => console.log('error:' + e)
const _n = () => {}
const run = async (args, agent, log, phase, pipeline, parallel) => { __BODY__ }
const pipeline = async (items, ...stages) => Promise.all(items.map(async (a) => { let x = await stages[0](a); for (const s of stages.slice(1)) x = await s(x, a); return x }))
'@
function Invoke-Js($name, $js, $wf) { $f = Join-Path (Kd) "$name.mjs"; [IO.File]::WriteAllText($f, ($jsLib + "`n" + $js).Replace('__BODY__', $wf)); @(node $f 2>&1) }
function New-TestKit([string]$name) {
  $k = Join-Path ([IO.Path]::GetTempPath()) "kit-test-$name-$PID\.claude"
  foreach ($f in 'skills/dev-kit/lib.ps1', 'skills/dev-kit/kit.example.json', 'skills/dev-kit/dev.ps1', 'skills/dev-kit/devtools.py', 'skills/qa-kit/qa.ps1',
      'skills/orchestrate/orch.ps1', 'skills/local-env/localenv.ps1', 'LESSONS.md') {
    $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path $src $f) $d
  }
  $k
}
function TkPath($tkDir, $tkName, [switch]$Create) { & { . (Join-Path $tkDir 'skills/dev-kit/lib.ps1'); Get-KitPath $tkName -Create:$Create } }
function Remove-TestKit($k) { Remove-Item (Kd) -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # own runtime + state per test kit
$np = '-NoProfile', '-File'   # pwsh @np <script>
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }

# === dev: worktrees, deploy merge, git host, tracker, guard, devtools
if ($Area -in 'dev', 'all') {
  "== dev"
  $k = New-TestKit dev; $D = Join-Path $k 'skills/dev-kit/dev.ps1'; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
  $r = Join-Path (Kd) 'git'; New-Item -ItemType Directory -Force "$r/outer/inner" | Out-Null
  $env:CLAUDE_WT_ROOT = "$r/wt"; foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
  try {
    git -C "$r/outer" init -q; git -C "$r/outer" commit -q --allow-empty -m init
    'x' | Set-Content "$r/outer/stray.txt"; 'y' | Set-Content "$r/outer/inner/a.txt"
    $out = pwsh @np $D wt commit -Dir "$r/outer/inner" -Message m 2>&1 | Out-String
    Expect 'wt commit refuses a plain subfolder' ($LASTEXITCODE -ne 0 -and $out -match 'not the top of a git worktree' -and -not (git -C "$r/outer" diff --cached --name-only))
    'feat: from file' | Set-Content "$r/msg.txt"
    Push-Location "$r/outer"; $null = pwsh @np $D wt commit -MessageFile "$r/msg.txt" 2>&1; $code = $LASTEXITCODE; Pop-Location
    Expect 'wt commit -MessageFile from the current folder' ($code -eq 0 -and (git -C "$r/outer" log -1 --format=%s) -eq 'feat: from file')
    git init -q --bare "$r/origin.git"; git clone -q "$r/origin.git" "$r/repo" 2>$null
    'a' | Set-Content "$r/repo/a.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m init; git -C "$r/repo" branch -M main
    git -C "$r/repo" push -q origin main 2>$null; git -C "$r/repo" push -q origin main:staging 2>$null
    New-Item -ItemType Directory -Force "$r/repo/.githooks" | Out-Null
    [IO.File]::WriteAllText("$r/repo/.githooks/pre-commit", "#!/bin/sh`necho hooked > `"`$(git rev-parse --git-dir)/hook-ran`"`n")
    git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m hooks; git -C "$r/repo" config core.hooksPath .githooks
    'b' | Set-Content "$r/repo/b.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: b'; git -C "$r/repo" push -q origin main 2>$null
    $out = Px $O deploy merge -Repo "$r/repo" -To staging -From main 2>&1 | Out-String
    $wt = if ($out -match 'worktree: (.+)') { $Matches[1].Trim() }
    $gd = if ($wt) { (git -C $wt rev-parse --absolute-git-dir).Trim() }
    Expect 'deploy merge is a merge commit' ($wt -and @((git -C $wt log -1 --format=%p) -split ' ').Count -eq 2)
    Expect 'deploy merge ran the pre-commit hook' ($gd -and (Test-Path (Join-Path $gd 'hook-ran')))
    $kl = "$k/skills/dev-kit/kit.local.json"; @{ repos = @(@{ checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'live'; tag = 'rel-{date}' }) }) } | ConvertTo-Json -Depth 5 | Set-Content $kl
    $dm = { Px $O deploy merge -Repo "$r/repo" @args 2>&1 | Out-String }; $o1 = & $dm -To main; $o2 = & $dm -To live -Push; Remove-Item $kl
    Expect 'deploy merge: trunk = no merge; tag deploy pushes a tag' ($o1 -match 'trunk' -and $o2 -match 'pushed rel-' -and (git -C "$r/origin.git" tag) -match '^rel-')
  } finally { Remove-Item Env:CLAUDE_WT_ROOT -ErrorAction SilentlyContinue }
  # git-host + ci adapters: glab/gh replies, type command, MR URLs
  $gh = @'
$script:calls = [Collections.Generic.List[string]]::new()
function glab { $script:calls.Add("glab $($args -join ' ')"); $global:LASTEXITCODE = 0; '{"iid":5,"state":"merged"}' }
function gh { $script:calls.Add("gh $($args -join ' ')"); $global:LASTEXITCODE = 0; $p = "$($args[1])"
 switch -Regex ($p) {
  'pulls/7/files' { '[{"filename":"a.txt"},{"filename":"b.txt","previous_filename":"old.txt"}]'; break }
  'pulls/7$' { '{"number":7,"state":"open","head":{"ref":"f/x","sha":"abc"},"base":{"ref":"main"},"mergeable":false,"mergeable_state":"dirty"}'; break }
  'pulls/8$' { '{"number":8,"state":"closed","merged_at":"2026-10-15T10:00:00Z","head":{"ref":"f/y"},"base":{"ref":"main"},"merge_commit_sha":"m8"}'; break }
  'pulls\?state' { '[{"number":7,"state":"open","head":{"ref":"f/x"},"base":{"ref":"main"}},{"number":9,"state":"open","head":{"ref":"f/z"},"base":{"ref":"main"}}]'; break }
  'abc/check-runs' { '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/11/job/3"}]}'; break }
  'zzz/status$' { '{"statuses":[{"state":"pending","context":"jenkins"}]}'; break }
  'compare/' { '{"merge_base_commit":{"sha":"base1"},"files":[{"filename":"a.txt"}]}'; break }
  'actions/runs\?' { '{"workflow_runs":[{"id":11,"head_sha":"m8","created_at":"2026-10-15T11:00:00Z","conclusion":"success"}]}'; break }
  'actions/runs/11/jobs' { '{"jobs":[{"id":3,"name":"deploy-staging","conclusion":"success","completed_at":"2026-10-15T11:05:00Z"}]}'; break }
  default { '{}' } } }
. $args[0]
$script:http = [Collections.Generic.List[object]]::new(); $script:gtMerged = $false
$fx = [ordered]@{
 'GET .*bitbucket.*/pullrequests/12$' = '{"id":12,"title":"feat: x","state":"OPEN","source":{"branch":{"name":"f/x"},"commit":{"hash":"abc123def456"}},"destination":{"branch":{"name":"main"}},"merge_commit":null,"updated_on":"2026-10-15T10:00:00.000000+00:00","links":{"html":{"href":"https://bitbucket.org/ws/bbrepo/pull-requests/12"}}}'
 'GET .*bitbucket.*/commit/abc123def456/statuses' = '{"values":[{"state":"INPROGRESS","key":"build","url":"https://bitbucket.org/ws/bbrepo/pipelines/results/41"}]}'
 'GET .*bitbucket.*/pullrequests\?' = '{"values":[{"id":12,"title":"feat: x","state":"OPEN","source":{"branch":{"name":"f/x"},"commit":{"hash":"abc123def456"}},"destination":{"branch":{"name":"main"}}}]}'
 'GET .*bitbucket.*/pipelines\?' = '{"values":[{"uuid":"{p-1}","state":{"name":"COMPLETED","result":{"name":"FAILED"}},"target":{"commit":{"hash":"abc123def456"}},"created_on":"2026-10-15T10:01:00Z","completed_on":"2026-10-15T10:06:00Z"}]}'
 'GET .*bitbucket.*/pipelines/%7Bp-1%7D/steps' = '{"values":[{"uuid":"{s-1}","name":"test","state":{"name":"COMPLETED","result":{"name":"FAILED"}},"completed_on":"2026-10-15T10:06:00Z"}]}'
 'GET .*dev.azure.com/org/proj/_apis/git/repositories/azrepo/pullrequests/5\?' = '{"pullRequestId":5,"title":"t","status":"active","sourceRefName":"refs/heads/f/x","targetRefName":"refs/heads/main","lastMergeSourceCommit":{"commitId":"aaa"},"lastMergeCommit":{"commitId":"mmm"},"creationDate":"2026-10-15T09:00:00Z","isDraft":false,"mergeStatus":"conflicts","autoCompleteSetBy":null,"repository":{"webUrl":"https://dev.azure.com/org/proj/_git/azrepo"}}'
 'GET .*refs/pull/5/merge' = '{"count":1,"value":[{"id":77,"status":"completed","result":"succeeded"}]}'
 'GET .*/org/_apis/connectionData' = '{"authenticatedUser":{"id":"u-1"}}'
 'PATCH .*pullrequests/5\?' = '{"pullRequestId":5,"status":"active","autoCompleteSetBy":{"id":"u-1"},"sourceRefName":"refs/heads/f/x","repository":{"webUrl":"https://dev.azure.com/org/proj/_git/azrepo"}}'
 'GET .*/repos/o/gtrepo/commits/ggg/status' = '{"state":"success","statuses":[{"status":"success","context":"ci"}]}'
 'GET .*/repos/o/gtrepo/compare/main...ggg' = '{"total_commits":0,"commits":[],"files":[]}'
 'GET .*ci.example/job/jkrepo/job/f%252Fx/api/json' = '{"builds":[{"number":9,"result":null,"building":true,"timestamp":1760000000000,"duration":0,"actions":[{},{"lastBuiltRevision":{"SHA1":"jjj"}}]}]}'
}
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) {
 $script:http.Add([pscustomobject]@{ m = $Method; u = $Uri; b = $Body; h = $Headers })
 if ($Uri -match '/repos/o/gtrepo/pulls/3/merge') { $script:gtMerged = $true; return $null }
 if ($Uri -match '/repos/o/gtrepo/pulls/3$') { return ('{"number":3,"title":"t","state":"' + $(if ($script:gtMerged) { 'closed","merged":true,"merged_at":"2026-10-15T12:00:00Z"' } else { 'open","merged":false' }) + ',"head":{"ref":"f/x","sha":"ggg"},"base":{"ref":"main"},"mergeable":true,"html_url":"https://git.example/o/gtrepo/pulls/3"}') | ConvertFrom-Json }
 foreach ($k in $fx.Keys) { if ("$Method $Uri" -match $k) { return ($fx[$k] | ConvertFrom-Json) } }
 $null
}
$script:HostType = 'gitlab'
$m = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; "gl-get:$($script:calls[-1] -eq 'glab api projects/g%2Fr/merge_requests/5' -and $m.state -eq 'merged')"
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5/merge' -Method PUT -Fields @{ squash = 'true' }; "gl-put:$($script:calls[-1] -like 'glab api -X PUT projects/g%2Fr/merge_requests/5/merge -f *squash=true*' -and $script:calls[-1] -like '*should_remove_source_branch=true*')"
$script:HostType = 'github'
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/7'; "gh-mr:$($m.iid -eq 7 -and $m.state -eq 'opened' -and $m.source_branch -eq 'f/x' -and $m.has_conflicts -and $m.head_pipeline.status -eq 'failed' -and $m.head_pipeline.id -eq '11')"
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'; "gh-merged:$($m.state -eq 'merged' -and $m.merge_commit_sha -eq 'm8')"
$c = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/changes'; "gh-changes:$(@($c.changes).Count -eq 2 -and $c.changes[1].old_path -eq 'old.txt')"
$b = Invoke-HostApi 'projects/o%2Fr/repository/merge_base?refs[]=abc&refs[]=staging'; "gh-base:$($b.id -eq 'base1')"
$p = @(Invoke-HostApi 'projects/o%2Fr/pipelines?ref=staging&per_page=10'); $j = @(Invoke-HostApi "projects/o%2Fr/pipelines/$($p[0].id)/jobs?per_page=100"); "gh-runs:$($p[0].sha -eq 'm8' -and $j[0].name -eq 'deploy-staging' -and $j[0].status -eq 'success')"
$n = $script:calls.Count; $null = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'; "memo:$($script:calls.Count -eq $n)"
$null = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/merge' -Method PUT -Fields @{ merge_when_pipeline_succeeds = 'true' }; "gh-auto:$(@($script:calls | ? { $_ -like 'gh pr merge 7 -R o/r --squash --delete-branch --auto' }).Count -eq 1)"
$l = @(Invoke-HostVerb 'mr.list' @{ repo = 'o/r'; state = 'opened'; source_branch = 'f/z' }); "gh-list-head:$($l.Count -eq 1 -and $l[0].iid -eq 9)"
$s = Invoke-HostVerb 'ci.status' @{ repo = 'o/r'; sha = 'zzz' } -NoMemo; "gh-status-external:$($s.status -eq 'pending')"
$u = 'https://h/g/s/r/-/merge_requests/4', 'https://github.com/o/r/pull/5', 'https://h/w/r/pull-requests/6', 'https://h/o/p/_git/r/pullrequest/7' | % { $x = ConvertFrom-MrUrl $_; "$($x.type):$($x.repo)!$($x.n)" }
"mr-urls:$("$u" -eq 'gitlab:g/s/r!4 github:o/r!5 bitbucket:w/r!6 azure:o/p/r!7')"
$m = Invoke-HostVerb 'mr.get' @{ type = 'command'; repo = 'o/cmd'; n = '4' }; "command:$($m.iid -eq 4 -and $m.title -eq 'o/cmd')"
$env:BITBUCKET_TOKEN = 'u:app'
$m = Invoke-HostVerb 'mr.get' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; n = '12' }; "bb-mr:$($m.iid -eq 12 -and $m.state -eq 'opened' -and $m.sha -eq 'abc123def456' -and $m.head_pipeline.status -eq 'running' -and $m.head_pipeline.id -eq '41' -and $script:http[0].h.Authorization -like 'Basic *')"
$l = @(Invoke-HostVerb 'mr.list' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; state = 'opened'; source_branch = 'f/x' }); "bb-list:$($l[0].iid -eq 12 -and @($script:http | ? { $_.u -match 'state=OPEN&q=source.branch.name%3D%22f%2Fx%22' }).Count -eq 1)"
$r = Invoke-HostVerb 'mr.merge' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; n = '12'; sha = 'abc123def456'; auto = $true }; "bb-kit-auto:$($r.auto_merge -eq 'kit' -and (Read-KitTracking).automerge.ContainsKey('ws/bbrepo!12') -and -not @($script:http | ? m -eq 'POST').Count)"
$p = @(Invoke-HostVerb 'ci.runs' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; ref = 'f/x' }); $j = @(Invoke-HostVerb 'ci.jobs' @{ type = 'bitbucket'; repo = 'ws/bbrepo'; id = $p[0].id }); "bb-pipelines:$($p[0].status -eq 'failed' -and $j[0].id -eq '{p-1}/{s-1}' -and $j[0].status -eq 'failed')"
$env:AZURE_DEVOPS_EXT_PAT = 'pat'
$m = Invoke-HostVerb 'mr.get' @{ type = 'azure'; repo = 'org/proj/azrepo'; n = '5' }; "az-mr:$($m.has_conflicts -and $m.source_branch -eq 'f/x' -and $m.sha -eq 'aaa' -and $m.web_url -eq 'https://dev.azure.com/org/proj/_git/azrepo/pullrequest/5' -and $m.head_pipeline.status -eq 'success' -and $m.head_pipeline.id -eq 77)"
$r = Invoke-HostVerb 'mr.merge' @{ type = 'azure'; repo = 'org/proj/azrepo'; n = '5'; sha = 'aaa'; auto = $true }; $pb = @($script:http | ? m -eq 'PATCH')[-1].b; "az-auto:$($r.merge_when_pipeline_succeeds -and $pb.autoCompleteSetBy.id -eq 'u-1' -and $pb.completionOptions.mergeStrategy -eq 'squash' -and -not $pb.status)"
$env:GITEA_TOKEN = 'tok'
$r = Invoke-HostVerb 'mr.merge' @{ type = 'gitea'; repo = 'o/gtrepo'; n = '3'; sha = 'ggg' }; $pb = @($script:http | ? m -eq 'POST')[-1]; "gt-merge:$($r.state -eq 'merged' -and $pb.b.Do -eq 'squash' -and $pb.b.head_commit_id -eq 'ggg' -and $pb.h.Authorization -eq 'token tok' -and $pb.u -eq 'https://git.example/api/v1/repos/o/gtrepo/pulls/3/merge')"
$b = Invoke-HostVerb 'repo.base' @{ type = 'gitea'; repo = 'o/gtrepo'; a = 'ggg'; b = 'main' }; "gt-base:$($b.id -eq 'ggg')"
$s = Invoke-HostVerb 'ci.status' @{ repo = 'jkrepo'; sha = 'jjj'; ref = 'f/x' }; "jk-status:$($s.status -eq 'running' -and $s.id -eq 'f/x#9')"
'@
  $ka = New-TestKit adapters; $cmdf = Join-Path (Split-Path $ka) 'host-cmd.ps1'; Set-Content $cmdf '[ordered]@{ iid = [int]$args[1]; state = ''merged''; title = $args[0] } | ConvertTo-Json -Compress'
  @{ gitHost = 'git.example'; repos = @(@{ name = 'jkrepo'; ci = 'jenkins' }); ci = @{ url = 'https://ci.example'; job = 'job/{repo}' }; gitHostApi = @{ commands = @{ 'mr.get' = "pwsh -NoProfile -File `"$cmdf`" {repo} {n}" } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ka 'skills/dev-kit/kit.local.json')
  $f = Join-Path (Kd) 'githost-test.ps1'; Set-Content $f $gh
  $res = @(pwsh @np $f (Join-Path $ka 'skills/dev-kit/lib.ps1') 2>&1)
  Expect-Each $res 'git host: #' 'gl-get', 'gl-put', 'gh-mr', 'gh-merged', 'gh-changes', 'gh-base', 'gh-runs', 'memo', 'gh-auto', 'gh-list-head', 'gh-status-external', 'bb-mr', 'bb-list', 'bb-kit-auto', 'bb-pipelines', 'az-mr', 'az-auto', 'gt-merge', 'gt-base', 'jk-status', 'mr-urls', 'command'
  Remove-TestKit $ka
  $out = pwsh @np $D tracker list PROJ failedTesting -Type jira -DryRun 6>&1 2>&1 | Out-String
  Expect 'tracker -Type jira -DryRun: list prints the call' ($out -match 'DRYRUN: GET \S+/rest/api/3/search/jql')
  $env:KIT_TRACKER_TYPE = 'none'
  $t = pwsh @np $D tracker create -List L1 -Name 'T one' -Description 'd' | ConvertFrom-Json
  $null = pwsh @np $D tracker status $t.id failedTesting
  $l = @(pwsh @np $D tracker list L1 failedTesting | ConvertFrom-Json)
  Expect 'tracker none: create, status failedTesting, list' ($t.id -like 'LOCAL-*' -and $l.Count -eq 1 -and $l[0].id -eq $t.id)
  $env:KIT_TRACKER_TYPE = 'clickup'; 'body text' | Set-Content "$r/c.md"
  $out = pwsh @np $D tracker comment 12 -File "$r/c.md" -DryRun 6>&1 2>&1 | Out-String
  $bad = pwsh @np $D tracker comment 12 -Bogus x -DryRun 2>&1 | Out-String; $badCode = $LASTEXITCODE
  Expect 'tracker comment -File sends it; unknown option = usage error' ($out -match 'comment add 12 "body text' -and $badCode -eq 2 -and $bad -match 'unknown option -Bogus')
  Remove-Item Env:KIT_TRACKER_TYPE
  # tracker backends on recorded answers (CLIs, Invoke-RestMethod mocked; an unknown call fails)
  $tb = @'
. $args[0]; $global:log = [Collections.Generic.List[string]]::new()
$__cfg = '{"tracker":{"org":"acme","project":"Shop","commands":{"view":"mytr view {id}","status":"mytr status {id} {status}","comment":"mytr comment {id} {text}","create":"mytr create {list} {name}","list":"mytr list {list} {status}"}}}' | ConvertFrom-Json; $__trRepo = 'g/p'
$env:JIRA_BASE_URL = 'https://j.test'; $env:JIRA_EMAIL = 'a@x'; $env:JIRA_API_TOKEN = 't'; $env:JIRA_TOKEN = 'pat'; $env:LINEAR_API_KEY = 'k'; $env:AZURE_DEVOPS_EXT_PAT = 'p'; $env:YOUTRACK_URL = 'https://yt.test'; $env:YOUTRACK_TOKEN = 'y'
function Fx($call) { $global:log.Add($call); foreach ($k in $global:fx.Keys) { if ($call -match $k) { return $global:fx[$k] } }; throw "404 no fixture: $call" }
function Invoke-RestMethod($Method, $Uri, $Headers, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec, $Body, $ContentType, $Form, $InFile) {
 $j = Fx "$Method $Uri $ContentType $($Headers.Authorization) $(if ($Body) { [Text.Encoding]::UTF8.GetString($Body) })"; if ($j) { $j | ConvertFrom-Json } }
foreach ($c in 'clickup', 'gh', 'glab', 'mytr') { Set-Item "function:$c" { $i = [array]::IndexOf($args, '--input'); $global:LASTEXITCODE = 0; Fx "$($args -join ' ') $(if ($i -ge 0) { gc $args[$i + 1] -Raw })" } }
function Run($type, $fx, $id, $list, [scriptblock]$ok) {
 Initialize-KitTracker -Type $type; $global:fx = $fx; $global:log.Clear()
 $r = @{ v = Get-TrackerTask $id; s = Set-TrackerStatus $id inTest; c = Add-TrackerComment $id 'two words'; n = New-TrackerTask -List $list -Name 'New one' -Description 'd' -Parent $id -Assignee 'Ann Lee' -Priority 2; l = @(Get-TrackerTasks $list inTest) }
 "${type}:$(& $ok $r ($global:log -join "`n"))"
}
$v = { param($r, $s, $n) $r.v.name -eq 'Bug' -and $r.v.status -eq 'In Progress' -and $r.v.subtasks[0].name -eq 'Sub' -and $r.n.id -eq $n -and $r.l[0].name -eq 'A' -and $r.l[0].assignees[0].id -eq $s }
Run clickup ([ordered]@{ 'task view C1' = '{"id":"C1","name":"Bug","status":{"status":"In Progress"},"list":{"id":"L9"},"subtasks":[{"id":"C2","name":"Sub","status":{"status":"open"}}]}'
 'status set in test C1' = 'Status set'; 'comment add C1 two words' = '{"id":"90"}'; 'member list' = '[{"id":7,"username":"Ann Lee"}]'
 'task create --list-id L9 .*--assignee 7 --parent C1' = '{"id":"C5"}'; 'task list --list-id L9 --status in test --page 0' = '[{"id":"C3","name":"A","assignees":[{"id":7,"username":"ann"}]}]' }) C1 L9 { param($r, $l) (& $v $r 7 C5) -and $l -match '--priority 2' }
Run github ([ordered]@{ 'assignees,body' = '{"number":5,"title":"Bug","state":"OPEN","labels":[{"name":"status:In Progress"}],"body":"Part of #1\n- [ ] #6"}'
 'view 6 ' = '{"number":6,"title":"Sub","state":"CLOSED","labels":[]}'; 'view 5 .*state,labels' = '{"state":"OPEN","labels":[{"name":"status:In Progress"}]}'; 'view 5 .*json body' = '{"body":"x"}'
 '^label create' = ''; 'edit 5 -R o/r --remove-label status:In Progress --add-label status:in test' = 'ok'; 'comment 5 -R o/r --body-file' = 'https://github.com/o/r/issues/5#c1'
 'create -R o/r --title New one --assignee Ann Lee --label priority:high' = 'https://github.com/o/r/issues/9'; '^issue edit 5 -R o/r --body-file' = 'ok'; 'list -R o/r .*--label status:in test' = '[{"number":7,"title":"A","assignees":[{"login":"ann"}]}]' }) 'o/r#5' o/r { param($r, $l) (& $v $r ann 9) -and $r.v.parent -eq '1' -and $r.v.subtasks[0].status -eq 'closed' }
Run gitlab ([ordered]@{ 'PUT projects/g%2Fp/issues/5 .*status:in test' = '{"iid":5}'; 'POST projects/g%2Fp/issues/5/notes .*two words' = '{"id":1}'; 'GET projects/g%2Fp/issues/5 ' = '{"iid":5,"title":"Bug","state":"opened","labels":["status:In Progress"],"description":"- [ ] #6"}'
 'GET projects/g%2Fp/issues/6' = '{"iid":6,"title":"Sub","state":"closed","labels":[]}'; 'users\?username=Ann' = '[{"id":3}]'; 'POST projects/g%2Fp/issues .*"assignee_ids":\[3\]' = '{"iid":12}'; 'PUT projects/g%2Fp/issues/5 .*#12' = '{"iid":5}'
 'issues\?state=opened&labels=status%3Ain%20test' = '[{"iid":7,"title":"A","assignees":[{"id":3,"username":"ann"}]}]' }) 'g/p#5' g/p { param($r, $l) & $v $r 3 12 }
$jf = { param($ver, $doc, $who, $srch) [ordered]@{ "GET https://j.test/rest/api/$ver/issue/P-1\?" = '{"key":"P-1","fields":{"summary":"Bug","status":{"name":"In Progress"},"parent":{"key":"P-0"},"subtasks":[{"key":"P-2","fields":{"summary":"Sub","status":{"name":"To Do"}}}],"description":' + $doc + '}}'
 'transitions  ' = '{"transitions":[{"id":"31","name":"QA","to":{"name":"In Test"}}]}'; 'transitions application/json .*"31"' = ''; "P-1/comment .*$(if ($ver -eq 3) { '"type":"doc"' } else { '"body":"two words"' })" = '{"id":"9"}'
 "POST .*/issue .*$who" = '{"key":"P-7"}'; "$srch\?jql=project" = '{"issues":[{"key":"P-3","fields":{"summary":"A","assignee":{"accountId":"u1","name":"u1","displayName":"Ann"}}}]}' } }
Run jira (& $jf 3 '{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Steps"}]}]}' '"accountId":"Ann Lee"' 'search/jql') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Basic .*"Subtask"' }
Run jira-server (& $jf 2 '"Steps"' '"name":"Ann Lee"' 'api/2/search') P-1 P { param($r, $l) (& $v $r u1 P-7) -and $r.v.description -eq 'Steps' -and $l -match 'Bearer pat' -and $l -notmatch 'api/3' }
Run linear ([ordered]@{ 'identifier title url description' = '{"data":{"issue":{"identifier":"E-1","title":"Bug","state":{"name":"In Progress"},"team":{"key":"E"},"children":{"nodes":[{"identifier":"E-2","title":"Sub","state":{"name":"Todo"}}]}}}}'
 'team \{ states' = '{"data":{"issue":{"team":{"states":{"nodes":[{"id":"s1","name":"Backlog"},{"id":"s2","name":"In Test"}]}}}}}'; '"stateId":"s2"' = '{"data":{"issueUpdate":{"success":true}}}'
 '"b":"two words"' = '{"data":{"commentCreate":{"success":true}}}'; 'teams\(filter' = '{"data":{"teams":{"nodes":[{"id":"t1"}]}}}'; 'issue\(id: \$id\) \{ id' = '{"data":{"issue":{"id":"uuid-1"}}}'
 'users\(filter' = '{"data":{"users":{"nodes":[{"id":"u1"}]}}}'; '"parentId":"uuid-1"' = '{"data":{"issueCreate":{"issue":{"identifier":"E-9"}}}}'
 '"eqIgnoreCase":"in test"' = '{"data":{"issues":{"nodes":[{"identifier":"E-3","title":"A","assignee":{"id":"u1","name":"Ann"}}]}}}' }) E-1 E { param($r, $l) & $v $r u1 E-9 }
Run azure ([ordered]@{ 'GET .*/acme/Shop/_apis/wit/workitems/42\?\$expand' = '{"id":42,"fields":{"System.Title":"Bug","System.State":"In Progress","System.Description":"<div>a<br>b</div>"},"relations":[{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/acme/_apis/wit/workItems/43"}]}'
 'ids=43&' = '{"value":[{"id":43,"fields":{"System.Title":"Sub","System.State":"New"}}]}'; 'PATCH .*workitems/42.*json-patch\+json Basic .*System.State' = '{"id":42}'; 'comments\?api-version=7.1-preview.4 .*two words' = '{"id":1}'
 'POST .*workitems/\$Task.*Hierarchy-Reverse' = '{"id":50}'; 'wiql.*in test' = '{"workItems":[{"id":44}]}'; 'ids=44&' = '{"value":[{"id":44,"fields":{"System.Title":"A","System.AssignedTo":{"uniqueName":"ann@x","displayName":"Ann"}}}]}' }) 42 '' { param($r, $l) (& $v $r ann@x 50) -and $l -match '"value":"in test"' -and $r.v.description -eq "a`nb" }
Run youtrack ([ordered]@{ 'GET https://yt.test/api/issues/D-1\?' = '{"idReadable":"D-1","summary":"Bug","subtasks":{"issues":[{"idReadable":"D-2","summary":"Sub","customFields":[]}]},"customFields":[{"name":"State","value":{"name":"In Progress"}}]}'
 'commands .*State \{in test\}' = '{}'; 'D-1/comments.*two words' = '{"id":"c"}'; 'admin/projects' = '[{"id":"0-1","shortName":"OPS"},{"id":"0-2","shortName":"D"}]'; 'POST .*issues\?fields.*"0-2"' = '{"idReadable":"D-9"}'
 'commands .*subtask of D-1 for Ann Lee Priority Major' = '{}'; 'GET .*issues\?query=project%3A%20%7BD%7D' = '[{"idReadable":"D-3","summary":"A","customFields":[{"name":"Assignee","value":{"login":"ann"}}]}]' }) D-1 D { param($r, $l) (& $v $r ann D-9) -and $l -match 'Bearer y' }
Run command ([ordered]@{ '^view T1' = '{"id":"T1","name":"Bug","status":"In Progress","subtasks":[{"name":"Sub"}]}'; '^status T1 in test' = 'ok'; '^comment T1 two words' = 'ok'; '^create B New one' = '{"id":"T9"}'
 '^list B in test' = '[{"id":"T3","name":"A","assignees":[{"id":"ann"}]}]' }) T1 B { param($r, $l) & $v $r ann T9 }
'@
  $f = Join-Path (Kd) 'tracker-test.ps1'; Set-Content $f $tb
  $res = @(pwsh @np $f (Join-Path $k 'skills/dev-kit/lib.ps1') 2>&1)
  Expect-Each $res 'tracker #: view, status, comment, create, list on recorded answers' 'clickup', 'github', 'gitlab', 'jira', 'jira-server', 'linear', 'azure', 'youtrack', 'command'
  $kv = pwsh -NoProfile -Command ". '$(Join-Path $k 'skills/dev-kit/lib.ps1')'; function T1 { param([string]`$Mode, [string[]]`$Lanes, [switch]`$Cold) ""`$Mode|`$(`$Lanes -join '+')|`$Cold"" }; `$a = @{ Lanes = 'L1'; Mode = 'None'; Cold = `$true }; & { Invoke-KitVerb T1 `$args } @a"
  Expect 'Invoke-KitVerb: splatted Mode=None binds like -Mode None' ("$kv".Trim() -eq 'None|L1|True')
  $out = pwsh @np $D guard -SelfTest 2>&1 | Out-String
  Expect 'guard self-test' ($out -match '(\d+)/\1 passed')
  $out = & $py -X utf8 (Join-Path $k 'skills/dev-kit/devtools.py') selftest 2>&1 | Out-String
  Expect 'devtools selftest' ($LASTEXITCODE -eq 0)
  $DT = Join-Path $k 'skills/dev-kit/devtools.py'
  $th = & $py -X utf8 $DT task --help 2>&1 | Out-String; $thc = $LASTEXITCODE; $null = & $py -X utf8 $DT task --bogus 2>&1; $tbc = $LASTEXITCODE; $null = & $py -X utf8 $DT status T1 2>&1; $tmc = $LASTEXITCODE
  $fk = Join-Path (Kd) 'flaky.py'; [IO.File]::WriteAllText($fk, "import sys, subprocess as sp; sys.path.insert(0, sys.argv[1]); import devtools as d`nn = []; hang = [0]`ndef fake(cmd, **kw):`n    n.append(cmd)`n    if hang[0]: raise sp.TimeoutExpired(cmd, 1)`n    return sp.CompletedProcess(cmd, 1 if len(n) == 1 else 0, 'connection reset' if len(n) == 1 else 'ok', '')`nd.subprocess.run = fake`nr = d._tracker('view', 'T1'); a = len(n); n.clear()`ntry: d._tracker('create', 'x')`nexcept SystemExit: pass`nw = len(n); n.clear(); hang[0] = 1; d._run(['glab', 'api', 'x']); print(r, a, w, len(n))`n")
  $rt = & $py -X utf8 $fk (Split-Path $DT) 2>&1 | Out-String
  Expect "devtools: --help 0, bad args 2, reads retried, writes never, hung read once ($thc $tbc $tmc $($rt.Trim()))" ($thc -eq 0 -and $th -match 'devtools\.py task <taskId>' -and $th -notmatch 'subtasks' -and $tbc -eq 2 -and $tmc -eq 2 -and $rt.Trim() -eq 'ok 2 1 2')
  # pipes: busy only with a head pipeline
  $pt = @'
. $args[0]
$ast = [Management.Automation.Language.Parser]::ParseFile($args[1], [ref]$null, [ref]$null)
$fn = $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Invoke-Pipes' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
 if ($Verb -eq 'mr.get') { if ($A.n -ne '9') { [pscustomobject]@{ state = 'opened'; head_pipeline = $null; target_branch = 'main' } } }
 elseif ($Verb -eq 'ci.config') { if ($A.repo -match 'nocirepo') { $false } else { $null } }   # no CI file / a failed call
}
$a = Invoke-Pipes -Mrs 'https://h.example/g/nocirepo/-/merge_requests/1' -MaxMinutes 0 | ConvertFrom-Json
$b = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/2' -MaxMinutes 0 | ConvertFrom-Json
$c = Invoke-Pipes -Mrs 'https://h.example/g/cirepo/-/merge_requests/9' -MaxMinutes 0 | ConvertFrom-Json
"no-ci:$($a.done -and $a.mrs[0].status -eq 'no-ci')"
"no-pipeline:$(-not $b.done -and $b.mrs[0].status -eq 'no-pipeline')"
"unknown:$(-not $c.done -and $c.mrs[0].status -eq 'unknown')"
'@
  $f = Join-Path (Kd) 'pipes-test.ps1'; Set-Content $f $pt
  $res = @(pwsh @np $f (Join-Path $k 'skills/dev-kit/lib.ps1') $D 2>&1)
  Expect-Each $res 'pipes: #' 'no-ci', 'no-pipeline', 'unknown'
  # > 200 baseline errors = UNRUN
  $ud = Join-Path (Kd) 'unrun-repo'; New-Item -ItemType Directory -Force $ud | Out-Null
  '{ "name": "x" }' | Set-Content "$ud/package.json"; '{ "stack": "custom", "commands": { "typecheck": "node tsc.js" } }' | Set-Content "$ud/.claude-stack.json"
  'for (let i = 0; i < 250; i++) console.log(`src/old${i}.ts(1,1): error TS2322: x`); process.exit(2)' | Set-Content "$ud/tsc.js"
  git -C $ud init -q; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m init
  $out = pwsh @np $D check -Dir $ud -Step typecheck 2>&1 | Out-String
  Expect 'check: a typecheck UNRUN exits 5' ($LASTEXITCODE -eq 5 -and $out -match 'UNRUN')
  New-Item -ItemType Directory -Force "$ud/db/migrate" | Out-Null; 'def change; end' | Set-Content "$ud/db/migrate/20240101000000_x.rb"; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m rb
  $out = pwsh -NoProfile -File $D check -Dir $ud -Step migrations 2>&1 | Out-String
  Expect 'check: migrations of a tool with no kit check are UNRUN (exit 5)' ($LASTEXITCODE -eq 5 -and $out -match 'UNRUN: rails')
  # guard: a non-JSON payload denies (logged); empty stdin allows
  $gbad = '{not json' | Px $D guard | Out-String
  $gnone = '' | Px $D guard | Out-String
  Expect 'guard: malformed hook input denies, empty input allows' ($gbad -match '"permissionDecision":"deny"' -and -not $gnone.Trim())
  $mk = Join-Path (Kd) 'main kit'; New-Item -ItemType Directory -Force "$mk/skills/dev-kit" | Out-Null
  Copy-Item (Join-Path $k 'skills/dev-kit/lib.ps1'), (Join-Path $k 'skills/dev-kit/kit.example.json') "$mk/skills/dev-kit/"
  git -C $mk init -q; git -C $mk add -A; git -C $mk -c user.name=t -c user.email=t@t commit -q -m init
  @{ tracker = @{ type = 'jira' } } | ConvertTo-Json | Set-Content "$mk/skills/dev-kit/kit.local.json"
  $lw = Join-Path (Kd) 'wt kit'; git -C $mk worktree add -q --detach $lw 2>$null
  $tt = pwsh -NoProfile -Command ". '$lw/skills/dev-kit/lib.ps1'; Get-KitSetting 'tracker.type' 'none'; Invoke-GitFetch -Dir '$lw' -TimeoutSec 20" 2>&1 | Out-String
  Expect 'lib: a linked worktree reads the main clone''s kit.local.json; fetch in a path with spaces runs (no origin: warning, $false)' ($tt -match '(?m)^jira' -and $tt -match 'git fetch in .*wt kit failed' -and $tt -match '(?m)^False')
  $KP = Join-Path $k 'skills/orchestrate/orch.ps1'
  $null = pwsh @np $KP --help; $h0 = $LASTEXITCODE; $null = pwsh @np $KP bogus-verb; $h2 = $LASTEXITCODE
  $mk = Join-Path (Kd) 'kit main'; New-Item -ItemType Directory -Force "$mk/skills/dev-kit", "$mk/skills/orchestrate" | Out-Null
  Copy-Item (Join-Path $k 'skills/dev-kit/lib.ps1'), (Join-Path $k 'skills/dev-kit/kit.example.json') "$mk/skills/dev-kit/"; Copy-Item $KP "$mk/skills/orchestrate/"
  'readme' | Set-Content "$mk/README.md"
  git -C $mk init -q; git -C $mk add -A; git -C $mk -c user.name=t -c user.email=t@t commit -q -m init
  @{ localOnly = @('secret.txt') } | ConvertTo-Json | Set-Content "$mk/skills/dev-kit/kit.local.json"
  $lw = Join-Path (Kd) 'kit wt'; git -C $mk worktree add -q --detach $lw 2>$null
  'edited' | Set-Content "$lw/README.md"
  $kx = (pwsh @np "$lw/skills/orchestrate/orch.ps1" setup -Exclude 2>&1 | Out-String) + (pwsh -NoProfile -Command ". '$lw/skills/orchestrate/orch.ps1'; 'unstaged:' + (Test-UnstagedEdits '$lw' 'README.md')" 2>&1 | Out-String)
  Expect 'orch.ps1: --help 0, bad verb 2; worktree: excludes to main clone, no memory, unstaged README seen' ($h0 -eq 0 -and $h2 -eq 2 -and
    (Get-Content "$mk/.git/info/exclude" -Raw) -match '/secret\.txt' -and $kx -match 'linked kit worktree' -and -not (Test-Path "$lw/memory") -and $kx -match 'unstaged:True')
  # buildy local loop: BLOCKED = FAIL; still FAIL -> ONE stronger round; ENV-FIX waits
  $wfd = [IO.File]::ReadAllText((Join-Path $src 'workflows/buildy.js')) -replace '^export const meta', 'const meta'
  $jsd = @'
const lt = (status, extra = {}) => ({ status, env: 'shop r1', rounds: 3, failing: status === 'PASS' ? [] : ['G1 still 500'], goalsDoc: 'g.md', ...extra })
const rep = (status, extra = {}) => _rep(lt(status), extra)
const mk = (envfix) => { const calls = []; return { calls, agent: async (prompt, o) => {
 calls.push({ label: o.label, model: o.model, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^build:/.test(o.label)) return envfix ? rep('FAIL', { done: [], needsEnvFix: [{ item: 'A1', envFixId: 'e-20260101000000-x1', need: 'refresh the release' }] }) : rep('BLOCKED', { localTest: lt('BLOCKED', { blockedReason: 'local DB missing a table' }) })
 if (/^local:/.test(o.label)) return rep('FAIL')
 if (/^envfix:/.test(o.label)) return { ok: true, output: 'ANSWERED e-20260101000000-x1: done: refreshed r2' }
 if (/^(local-strong|envfix-resume):/.test(o.label)) return rep('PASS')
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ci:/.test(o.label)) return { done: true, mrs: [{ mr: '1', status: 'success' }] }
 if (/^ship:/.test(o.label)) return rep('PASS', _merged(1))
 return _ok('[]') } } }
const args = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1', area: 'a' }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
const a = mk(false), b = mk(true)
run(args, a.agent, _n, _n, pipeline).then((oa) => run(args, b.agent, _n, _n, pipeline).then((ob) => {
 const s = a.calls.find((c) => c.label === 'local-strong:X1')
 console.log(`blocked-is-fail:${a.calls.some((c) => c.label === 'local:X1') && !oa.blocked.length}`)
 console.log(`strong-round:${!!s && s.model === 'opus' && /STRONGER FIX ROUND/.test(s.prompt) && a.calls.some((c) => c.label === 'ship:X1')}`)
 console.log(`envfix:${b.calls.some((c) => c.label === 'envfix:X1' && /decide wait -Id e-20260101000000-x1/.test(c.prompt)) && b.calls.some((c) => c.label === 'envfix-resume:X1' && /done: refreshed r2/.test(c.prompt)) && ob.envFixes.length === 1 && b.calls.some((c) => c.label === 'ship:X1')}`)
 console.log(`flow-text:${/decide ask -Kind envfix/.test(a.calls.find((c) => c.label === 'build:X1').prompt)}`)
})).catch(_err)
'@
  Expect-Each (Invoke-Js dw-local $jsd $wfd) 'buildy local loop: #' 'blocked-is-fail', 'strong-round', 'envfix', 'flow-text' -Show 5
  # buildy: blocking finding -> fix -> ONE re-review; deferred item holds promotion
  $jsr = @'
const lt = { status: 'PASS', env: 'shop r1', rounds: 1, failing: [], goalsDoc: 'g.md' }
const rep = (extra = {}) => _rep(lt, extra)
const calls = []
let reviews = 0
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^build:/.test(o.label)) return rep({ deferred: [{ id: 'A2', reason: 'needs data' }] })
 if (/^review:/.test(o.label)) return { findings: reviews++ ? [] : [{ mr: '1', file: 'a.ts', line: 3, severity: 'blocking', problem: 'null check missing', fix: 'add it' }] }
 if (/^fix:/.test(o.label)) return rep()
 if (/^ci:/.test(o.label)) return { done: true, mrs: [{ mr: '1', status: 'success' }] }
 if (/^ship:/.test(o.label)) return rep(_merged(1))
 return _ok('[]')
}
const args = { brief: 'C:/b/wave-x.md', agents: [{ id: 'X1', items: 'A1, A2', area: 'a' }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
run(args, agent, _n, _n, pipeline).then(() => {
 const rv = calls.filter((c) => c.label === 'review:X1'), ti = calls.findIndex((c) => c.label === 'track:X1'), si = calls.findIndex((c) => c.label === 'ship:X1')
 console.log(`re-review:${rv.length === 2 && /RE-REVIEW after the fix round/.test(rv[1].prompt) && /null check missing/.test(rv[1].prompt) && si > calls.indexOf(rv[1])}`)
 console.log(`hold:${ti >= 0 && /-HoldPromotion 'deferred items: A2'/.test(calls[ti].prompt)}`)
 const m = /-Run '([^']+)'/.exec(calls.find((c) => c.label === 'record-args').prompt)
 console.log(`run:${m ? m[1] : 'none'}`)
}).catch(_err)
'@
  $res = Invoke-Js dw-review $jsr $wfd
  $want = & { . $O; Get-LaunchRunName ([pscustomobject]@{ brief = 'C:/b/wave-x.md' }) }
  Expect-Each $res 'buildy: #' 're-review', 'hold' -Show 5
  Expect 'buildy: default run name = orch.ps1 Get-LaunchRunName' (@($res | Where-Object { "$_" -eq "run:$want" }).Count -eq 1 -and $want -match '^wave-x-[0-9a-f]{4}$')
  # buildy duel: 2 POCs, compare, debate, owner judges, winner ships
  $jsu = @'
const lt = { status: 'PASS', env: 'shop r1', rounds: 1, failing: [], goalsDoc: 'g.md' }
const rep = (id) => _rep(lt, { mrs: [{ url: `https://h/g/api/-/merge_requests/${id === 'D2' ? 2 : 1}`, repo: 'api', merged: false }], worktrees: [`C:/wt/${id}`] })
const calls = []
async function agent(prompt, o) {
 calls.push({ label: o.label, agentType: o.agentType, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^duel:/.test(o.label)) return { approach: o.label.endsWith('D1') ? 'cache' : 'index', summary: 'poc', evidence: ['run.json'], worktrees: [`C:/wt/${o.label.slice(5)}`], branch: 'f/x-poc', localTest: 'PASS' }
 if (/^debate:/.test(o.label)) return { points: [{ claim: 'faster', evidence: '120 ms vs 300 ms' }], concede: [], rest: true }
 if (o.label === 'duel-compare' || o.label === 'duel-moderate') return { record: '| correctness | a | b |', unsupported: [], recommend: 'B' }
 if (o.label === 'duel-ask') return { ok: true, output: 'DECISION d-20261016000000-duel-ab12 pending' }
 if (o.label === 'duel-verdict') return { ok: true, output: 'ANSWERED d-20261016000000-duel-ab12: B, the index wins' }
 if (/^build:/.test(o.label)) return rep(o.label.slice(6))
 if (/^review:/.test(o.label)) return { findings: [] }
 if (/^ci:/.test(o.label)) return { done: true, mrs: [{ mr: '2', status: 'success' }] }
 if (/^ship:/.test(o.label)) return { ...rep('D2'), ..._merged(2) }
 return _ok('[]')
}
const parallel = async (fns) => Promise.all(fns.map((f) => f()))
const args = { brief: 'C:/b/duel.md', mode: 'duel', duel: { question: 'cache or index?', rounds: 2 }, agents: [{ id: 'D1', items: 'A1', area: 'q' }, { id: 'D2', items: 'A1', area: 'q' }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
run(args, agent, _n, _n, pipeline, parallel).then((o) => {
 const deb = calls.filter((c) => /^debate:/.test(c.label))
 console.log(`duel-pocs:${calls.filter((c) => /^duel:D[12]$/.test(c.label) && c.agentType === 'devy').length === 2 && calls.some((c) => c.label === 'duel-compare' && c.agentType === 'revy')}`)
 console.log(`duel-debate:${deb.length === 2 && deb.every((c) => /board msg/.test(c.prompt))}`)
 console.log(`duel-judge:${o.duel && o.duel.winner === 'D2' && calls.some((c) => c.label === 'duel-ask' && /-Recommend B/.test(c.prompt)) && calls.some((c) => c.label === 'duel-close:D1')}`)
 console.log(`duel-ships-winner:${calls.some((c) => c.label === 'build:D2' && /DUEL WON/.test(c.prompt)) && !calls.some((c) => c.label === 'build:D1') && calls.some((c) => c.label === 'ship:D2')}`)
 console.log(`crew-only:${calls.every((c) => ['devy', 'revy', 'checky', 'kitty'].includes(c.agentType))}`)
}).catch(_err)
'@
  Expect-Each (Invoke-Js dw-duel $jsu $wfd) 'buildy duel: #' 'duel-pocs', 'duel-debate', 'duel-judge', 'duel-ships-winner', 'crew-only' -Show 5
  Remove-TestKit $k
}

# === qa: result rule (finalize), deploy detection
if ($Area -in 'qa', 'all') {
  "== qa"
  $k = New-TestKit qa; $Q = Join-Path $k 'skills/qa-kit/qa.ps1'; $store = Join-Path $k '.state/tracker-none'
  $env:KIT_TRACKER_TYPE = 'none'; $env:KIT_REPORT_TYPE = 'markdown'
  function New-Run($name, $items) {
    $d = Join-Path (Kd) "runs/$name"; New-Item -ItemType Directory -Force $d | Out-Null
    @{ title = "Run $name"; target = 't'; tracker = @{ list = 'L1'; parent = 'P1' }; items = @($items | ForEach-Object { @{ code = $_.code; title = $_.code; subtasks = @(@{ id = $_.task; name = "Task $($_.task)" }) } }) } | ConvertTo-Json -Depth 8 | Set-Content "$d/run.json"
    foreach ($it in $items) {
      New-Item -ItemType Directory -Force "$d/$($it.code)" | Out-Null
      @{ code = $it.code; checks = @($it.checks | ForEach-Object { $c = @{ id = $_[0]; subtask_id = $it.task; screen = 's'; result = $_[1]; what_was_done = 'w'; observed = "o $($_[0])"; evidence = @() }; if ($_.Count -gt 2) { $c.defect = $_[2] }; $c }); findings = @(); setup_changes = @(); data_created = @() } | ConvertTo-Json -Depth 8 | Set-Content "$d/$($it.code)/results.json"
    }
    $d
  }
  function Fin($d, $c) { Px $Q finalize -RunDir $d -Code $c 2>&1 | Out-String }
  function Rec($d, $c) { (Get-Content "$d/$c/finalize.json" -Raw | ConvertFrom-Json).subtasks[0] }
  function Task($id) { Get-Content (Join-Path $store "$id.json") -Raw | ConvertFrom-Json }
  function Bugs { @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.name -like '`[Bug`]*' }) }
  New-Item -ItemType Directory -Force $store | Out-Null
  foreach ($x in @(@('PA', 'Ask A', $null), @('PQ', 'Ask Q', $null), @('TA', 'Task A', 'PA'), @('TQ', 'Task Q', 'PQ'), @('TA2', 'Task A2', 'PA'))) {
    @{ id = $x[0]; name = $x[1]; status = 'open'; parent = $x[2]; list = 'L1'; assignees = @(); description = ''; comments = @() } | ConvertTo-Json | Set-Content (Join-Path $store "$($x[0]).json")
  }
  $a = New-Run 'A' @(@{ code = 'A1'; task = 'T1'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
  $out = Fin $a 'A1'
  Expect 'NOT_TESTED -> failedTesting' ((Rec $a 'A1').failedTesting -and -not (Rec $a 'A1').closed -and (Task 'T1').status -eq 'failed testing')
  Expect 'the comment lists the untested check' (@((Task 'T1').comments | Where-Object { $_.text -match '## Untested checks' -and $_.text -match '### C2' }).Count -eq 1)
  Expect 'no task created for untested checks' (-not @(Get-ChildItem $store -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count)
  $lo = New-Run 'LO' @(@{ code = 'L1'; task = 'TL'; checks = @(@('C1', 'PASS'), @('C2', 'NOT_TESTED')) })
  $rj = Get-Content "$lo/run.json" -Raw | ConvertFrom-Json; $rj | Add-Member localEnv 'shop'; $rj | ConvertTo-Json -Depth 8 | Set-Content "$lo/run.json"
  $null = Fin $lo 'L1'; $rl = Rec $lo 'L1'
  Expect 'local env: NOT_TESTED keeps the task open, not failedTesting' (-not $rl.failedTesting -and -not $rl.closed -and $rl.keptOpen -match 'ENV-FIX' -and (Task 'TL').status -ne 'failed testing')
  $b = New-Run 'B' @(@{ code = 'B1'; task = 'T2'; checks = @(@('C1', 'PASS'), @('C2', 'FAIL')) })
  $null = Fin $b 'B1'
  Expect 'own FAIL -> failedTesting, no [Bug]' ((Rec $b 'B1').failedTesting -and (Rec $b 'B1').fail -eq 1 -and -not (Bugs).Count)
  Expect 'failed check in the bug-brief format' (@((Task 'T2').comments | Where-Object { $_.text -match '### C2 — s' -and $_.text -match '\*\*Saw:\*\* o C2' }).Count -eq 1)
  $c = New-Run 'C' @(@{ code = 'C1'; task = 'T4'; checks = @(@('C1', 'PASS'), @('C2', 'OUT_OF_SCOPE')) })
  $null = Fin $c 'C1'
  Expect 'all pass (+ OUT_OF_SCOPE) -> closed' ((Rec $c 'C1').closed -and (Rec $c 'C1').outOfScope -eq 1 -and (Get-Content "$c/C1/report.md" -Raw) -match 'OUT OF SCOPE 1')
  $m = New-Run 'M' @(@{ code = 'M1'; task = 'TA'; checks = @(@('C1', 'PASS'), @('X1', 'FAIL')) }, @{ code = 'M2'; task = 'TA2'; checks = , @('C1', 'FAIL', 'new') }, @{ code = 'M3'; task = 'TQ'; checks = , @('X1', 'FAIL') })
  $null = Fin $m 'M1'; $null = Fin $m 'M2'; $null = Fin $m 'M3'
  $bA = @(Bugs | Where-Object { $_.parent -eq 'PA' }); $bQ = @(Bugs | Where-Object { $_.parent -eq 'PQ' })
  Expect 'one [Bug] per ask, under the ask, named with the count' ($bA.Count -eq 1 -and $bQ.Count -eq 1 -and $bA[0].name -eq '[Bug] Ask A — new defects (2)')
  Expect 'a task with only a new defect closes' ((Rec $m 'M1').closed -and (Rec $m 'M2').closed)
  $n = New-Run 'N' @(@{ code = 'N1'; task = 'TA2'; checks = , @('X1', 'FAIL') })
  $null = Fin $n 'N1'
  Expect 'a later run appends to the open [Bug]' (@(Bugs | Where-Object { $_.parent -eq 'PA' }).Count -eq 1 -and @(Bugs | Where-Object { $_.parent -eq 'PA' })[0].name -eq '[Bug] Ask A — new defects (3)')
  $null = Fin $c 'C1'
  Expect 'a re-run posts no second results comment' (@((Task 'T4').comments | Where-Object { $_.text -match 'Test results' }).Count -eq 1)
  $h = New-Run 'H' @(@{ code = 'H1'; task = 'T10'; checks = , @('C1', 'PASS') }, @{ code = 'H2'; task = 'T10'; checks = , @('C2', 'FAIL') })
  $null = Fin $h 'H1'; $w = Rec $h 'H1'; $null = Fin $h 'H2'
  Expect 'shared task waits for its sibling, then failedTesting' ($w.waitingFor -contains 'H2' -and (Rec $h 'H2').failedTesting)
  # deploy detection: a squash-merged deploy MR counts
  $t = @'
. $args[0]
$ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
function Canned($deployMrs) {
  $script:memo = @{}; $p = 'g%2Fweb'
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=stg"] = [pscustomobject]@{ id = 'OLD' }
  $memo["projects/$p/repository/commits/stg"] = [pscustomobject]@{ committed_date = '2026-01-02T08:00:00Z' }
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=main"] = [pscustomobject]@{ id = 'F' }
  $memo["projects/$p/merge_requests/5/changes?access_raw_diffs=true"] = [pscustomobject]@{ changes = @([pscustomobject]@{ new_path = 'a.ts'; old_path = 'a.ts' }) }
  $memo["projects/$p/repository/compare?from=stg&to=main&straight=true"] = [pscustomobject]@{ diffs = @([pscustomobject]@{ new_path = 'a.ts'; old_path = 'a.ts' }) }
  $memo["projects/$p/merge_requests?state=merged&target_branch=stg&updated_after=2026-01-02T07:00:00Z&per_page=50"] = $deployMrs
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=S"] = [pscustomobject]@{ id = 'F' }
  $memo["projects/$p/repository/merge_base?refs[]=L&refs[]=stg"] = [pscustomobject]@{ id = 'L' }
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=S0"] = [pscustomobject]@{ id = 'X' }
  $p
}
$mr = [pscustomobject]@{ iid = 5; merged_at = '2026-01-02T07:00:00Z'; target_branch = 'main' }
$p = Canned @([pscustomobject]@{ iid = 9; sha = 'S'; squash_commit_sha = 'L'; merge_commit_sha = $null }); "squash:$(OnRef $p $mr 'F' 'stg')"
$p = Canned @([pscustomobject]@{ iid = 8; sha = 'S0'; squash_commit_sha = 'L'; merge_commit_sha = $null }); "other:$(-not (OnRef $p $mr 'F' 'stg'))"
'@
  $f = Join-Path (Kd) 'deployed-test.ps1'; Set-Content $f $t
  $res = @(pwsh @np $f $Q 2>&1)
  Expect 'deployed: a squash-merged deploy MR counts as deployed' (@($res | Where-Object { "$_" -eq 'squash:True' }).Count -eq 1)
  Expect 'deployed: a deploy MR without the commit does not' (@($res | Where-Object { "$_" -eq 'other:True' }).Count -eq 1)
  $wf = [IO.File]::ReadAllText((Join-Path $src 'workflows/testy.js')) -replace '^export const meta', 'const meta'
  $js = @'
const calls = []
const ck = _ck
async function agent(prompt, o) {
 calls.push({ label: o.label, model: o.model, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^(test|retest):/.test(o.label)) return _res('A1', [ck('C1', 'NOT_TESTED', { cause: 'env-data' }), ck('C2', 'PASS'), ck('C3', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('A1', [ck('C1', 'PASS')])
 if (/^close/.test(o.label)) return { ok: true, output: 'published' }
 return _ok('')
}
const args = { runDir: 'C:/runs/R1', kitDir: 'C:/kit', learn: false, items: [{ code: 'A1', title: 'A one', guideFile: 'g.md', lane: 'web', subtasks: [{ id: 'T1' }] }] }
run(args, agent, _n, _n, null).then(() => {
 const s = calls.find((c) => c.label === 'retest-strong:A1'), cl = calls.find((c) => c.label === 'close:A1')
 console.log(`strong:${!!s && s.model === 'opus' && /blocked by env-data/.test(s.prompt) && /ONLY these checks: C1/.test(s.prompt)}`)
 console.log(`closed-pass:${!!cl && /"id":"C1"[^}]*"result":"PASS"/.test(cl.prompt)}`)
}).catch(_err)
'@
  $res = Invoke-Js tc-retry $js $wf
  Expect 'testy: NOT_TESTED gets one stronger retry, told its blocker' (@($res | Where-Object { "$_" -eq 'strong:true' }).Count -eq 1)
  Expect 'testy: the retry''s PASS is what gets published' (@($res | Where-Object { "$_" -eq 'closed-pass:true' }).Count -eq 1)
  # testy local: NOT_TESTED -> ENV-FIX + retest; 2 cycles: held
  $js3 = @'
const ck = _ck
const mk = (fixWorks) => { const calls = []; return { calls, agent: async (prompt, o) => {
 calls.push({ label: o.label, model: o.model, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^(test|retest|retest-strong):/.test(o.label)) return _res('A1', [ck('C1', 'NOT_TESTED', { cause: 'undeployed', env_fix: 'refresh the release' }), ...(/^retest-strong/.test(o.label) ? [] : [ck('C2', 'PASS'), ck('C3', 'PASS'), ck('C4', 'PASS')])])
 if (/^envfix-ask:/.test(o.label)) return { ok: true, output: `ENV-FIX e-20260101000000-qa-a1 pending` }
 if (/^envfix-wait:/.test(o.label)) return { ok: true, output: 'ANSWERED e-20260101000000-qa-a1: done: refreshed' }
 if (/^envfix-retest:/.test(o.label)) return _res('A1', [ck('C1', fixWorks ? 'PASS' : 'NOT_TESTED', { cause: 'env-data' })])
 return _ok('') } } }
const args = { runDir: 'C:/runs/R1', kitDir: 'C:/kit', learn: false, localEnv: 'shop', items: [{ code: 'A1', title: 'A one', guideFile: 'g.md', lane: 'api', subtasks: [{ id: 'T1' }] }] }
const a = mk(true), b = mk(false)
run(args, a.agent, _n, _n, null).then(() => run(args, b.agent, _n, _n, null)).then((out) => {
 const ask = a.calls.find((c) => c.label === 'envfix-ask:A1'), cl = a.calls.find((c) => c.label === 'close:A1')
 console.log(`envfix-ask:${!!ask && /decide ask -Kind envfix/.test(ask.prompt) && /refresh the release/.test(ask.prompt)}`)
 console.log(`envfix-pass:${!!cl && /"id":"C1"[^}]*"result":"PASS"/.test(cl.prompt) && /LOCAL ENV "shop"/.test(a.calls.find((c) => c.label === 'test:A1').prompt)}`)
 console.log(`envfix-held:${b.calls.filter((c) => c.label === 'envfix-ask:A1').length === 2 && !b.calls.some((c) => /^close/.test(c.label)) && b.calls.some((c) => c.label === 'hold:A1' && /ENV-FIX/.test(c.prompt)) && out.envFixOpen.includes('A1')}`)
}).catch(_err)
'@
  $res = Invoke-Js tc-envfix $js3 $wf
  Expect-Each $res 'testy local: #' 'envfix-ask', 'envfix-pass', 'envfix-held' -Show 5
  # testy retries per check: fewer checks keep the first FAIL; a duplicate (C5b) retries as C5
  $js4 = @'
const calls = []
const ck = _ck
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^test:/.test(o.label)) return _res('A1', [ck('C1', 'FAIL', { defect: 'own' }), ck('C2', 'NOT_TESTED'), ck('C3', 'NOT_TESTED'), ck('C4', 'PASS'), ck('C5', 'PASS'), ck('C5', 'NOT_TESTED')])
 if (/^retest:/.test(o.label)) return _res('A1', [ck('C2', 'PASS'), ck('C3', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('A1', [ck('C5', 'PASS')])
 if (/^verify:/.test(o.label)) return { verdicts: [{ id: 'C1', outcome: 'confirmed', confirmed: true, attempts: 1, observed: 'again', evidence: [], basis: 'none' }] }
 return _ok('published')
}
const args = { runDir: 'C:/runs/R4', kitDir: 'C:/kit', learn: false, items: [{ code: 'A1', title: 'A', guideFile: 'g.md', lane: 'api', subtasks: [{ id: 'T1' }] }] }
run(args, agent, _n, _n, null).then(() => {
 const cl = calls.find((c) => c.label === 'close:A1'), s = calls.find((c) => c.label === 'retest-strong:A1')
 console.log(`keeps-fail:${!!cl && /"id":"C1"[^}]*"result":"FAIL"/.test(cl.prompt) && /"id":"C3"[^}]*"result":"PASS"/.test(cl.prompt)}`)
 console.log(`guide-id:${!!s && /ONLY these checks: C5\./.test(s.prompt) && /"id":"C5b"[^}]*"result":"PASS"/.test(cl.prompt)}`)
}).catch(_err)
'@
  $res = Invoke-Js tc-merge $js4 $wf
  Expect-Each $res 'testy retries: #' 'keeps-fail', 'guide-id' -Show 5
  $js2 = @'
const calls = []
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (o.label === 'prepare') return { runDir: 'C:/rt/work/qa-runs/2026-01-01-local', items: 1, left: [{ id: 'T9', reason: 'not live' }], summary: 's' }
 if (/^load-run/.test(o.label)) return { json: JSON.stringify({ target: 'local-a', items: [{ code: 'A1', title: 'A', guideFile: 'g.md', lane: 'api', target: 'local-b', subtasks: [{ id: 'T1' }] }] }) }
 if (/^record-args/.test(o.label)) return _rec()
 if (/^test:/.test(o.label)) return _res('A1', [{ id: 'C1', subtask_id: 'T1', screen: 's', result: 'PASS', what_was_done: 'w', observed: 'o', evidence: [], attempts: 1 }])
 return _ok('')
}
const args = { select: { statuses: ['promoted', 'inTest'], exclude: ['T7'] }, target: 'local', kitDir: 'C:/kit', learn: false }
const logs = []
run(args, agent, (m) => logs.push(m), () => {}, null).then(() => {
 const p = calls.find((c) => c.label === 'prepare'), t = calls.find((c) => c.label === 'test:A1'), recs = calls.filter((c) => c.label === 'record-args'), orig = JSON.stringify(args)
 // the launch record == the original args (before Prepare), then the same args + the resolved runDir
 const rec = recs.length === 2 && calls.indexOf(recs[0]) < calls.indexOf(p) && recs.every((r) => r.prompt.includes(`<<<ARGS\n${orig}\nARGS>>>`) && /-Run 'select-local'/.test(r.prompt)) &&
  !/-RunDir/.test(recs[0].prompt) && recs[1].prompt.includes("-RunDir 'C:/rt/work/qa-runs/2026-01-01-local'")
 console.log(`prepare:${!!p && /"statuses":\["promoted","inTest"\]/.test(p.prompt) && /"target":"local"/.test(p.prompt) && /"exclude":\["T7"\]/.test(p.prompt) && /qa-runs\/<yyyy-MM-dd>-local-promoted-intest/.test(p.prompt)}`)
 console.log(`record:${rec}`)
 console.log(`item-target:${!!t && /KIT_QA_TARGETS='local-b'/.test(t.prompt) && logs.some((l) => /left out T9: not live/.test(l))}`)
}).catch(_err)
'@
  $res = Invoke-Js tc-select $js2 $wf
  Expect-Each $res 'testy select: #' 'prepare', 'record', 'item-target' -Show 5
  # ---- review batch 2: qa.ps1, testy, browser.mjs
  $sd = TkPath $k qa-seats; New-Item -ItemType Directory -Force "$sd/claims" | Out-Null
  $crd = Join-Path (Kd) 'runs/CL'; New-Item -ItemType Directory -Force $crd | Out-Null
  $me = Get-Process -Id $PID
  @{ run = 'CL'; code = 'C1'; owner = 'w9'; since = (Get-Date).AddHours(-7).ToString('s'); holderPid = $PID; holderStart = $me.StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content "$sd/claims/CL__C1.json"
  @{ run = 'CL'; code = 'C2'; owner = 'w9'; since = (Get-Date).AddHours(-7).ToString('s') } | ConvertTo-Json | Set-Content "$sd/claims/CL__C2.json"
  $o1 = pwsh @np $Q seat acquire -Agent test:C1 -Kind api -RunDir $crd -Code C1 -Owner w1 -KeepFreeGB 0.1 -WaitMinutes 0 | Out-String; $c1 = $LASTEXITCODE
  $o2 = pwsh @np $Q seat acquire -Agent test:C2 -Kind api -RunDir $crd -Code C2 -Owner w1 -KeepFreeGB 0.1 -WaitMinutes 0 | Out-String
  $null = pwsh @np $Q seat release -Agent test:C2
  $null = pwsh @np $Q seat acquire -Agent test:C3 -Kind api -KeepFreeGB 100000 -WaitMinutes 0; $c3 = $LASTEXITCODE
  $null = pwsh @np $Q seat release -Agent test:C3
  Expect 'seat: a live holder keeps its claim past 6 h; an unknown holder''s old claim is free; still waiting exits 4' ($c1 -eq 3 -and $o1 -match 'ALREADY' -and $o2 -notmatch 'ALREADY' -and $c3 -eq 4)
  $sr = New-Run 'SR' @(@{ code = 'S1'; task = 'TS'; checks = , @('C1', 'PASS') }, @{ code = 'S2'; task = 'TS'; checks = , @('C2', 'PASS') })
  $ps = @('S1', 'S2' | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile', '-File', "`"$Q`"", 'finalize', '-RunDir', "`"$sr`"", '-Code', $_ -PassThru -WindowStyle Hidden })
  $ps | Wait-Process -Timeout 180
  Expect 'finalize: parallel siblings of a shared task close it' (((Rec $sr 'S1').closed -or (Rec $sr 'S2').closed) -and (Task 'TS').status -eq 'closed')
  $ex = New-Run 'EX' @(@{ code = 'E1'; task = 'TE'; checks = @(@('C1', 'PASS'), @('C2', 'PASS')) })
  $eo = pwsh @np $Q finalize -RunDir $ex -Code E1 -ExpectChecks 5 2>&1 | Out-String
  $null = pwsh @np $Q finalize -RunDir $ex -Code E1 -Check -ExpectChecks 5 2>&1; $ec = $LASTEXITCODE
  $null = pwsh @np $Q finalize -RunDir $ex -Code E1 -Check -ExpectChecks 2 2>&1; $eok = $LASTEXITCODE
  $er = pwsh @np $Q finalize -RunDir $ex -Code E1 -Results results-retry.json 2>&1 | Out-String
  Expect 'finalize: -ExpectChecks refuses a truncated copy; -Results needs -Check' ($eo -match 'truncated copy' -and -not (Test-Path "$ex/E1/finalize.json") -and $ec -eq 1 -and $eok -eq 0 -and $er -match 'only with -Check')
  New-Item -ItemType Directory -Force "$ex/E1/shots" | Out-Null; 'x' | Set-Content "$ex/E1/shots/retryshot.png"; 'y' | Set-Content "$ex/E1/shots/othershot.png"
  @{ code = 'E1'; checks = @(@{ id = 'C2'; subtask_id = 'TE'; screen = 's'; result = 'PASS'; what_was_done = 'w'; observed = 'o'; evidence = @('retryshot.png') }); findings = @(); setup_changes = @(); data_created = @() } | ConvertTo-Json -Depth 6 | Set-Content "$ex/E1/results-retry.json"
  $before = Get-Content "$ex/E1/results.json" -Raw
  $null = pwsh @np $Q finalize -RunDir $ex -Code E1 -Check -FixNames -Results results-retry.json 2>&1
  Expect 'finalize -Results: a scoped retry renames only its own files' (-not (Test-Path "$ex/E1/shots/retryshot.png") -and (Test-Path "$ex/E1/shots/othershot.png") -and (Get-Content "$ex/E1/results-retry.json" -Raw) -match 'E1-C2_' -and (Get-Content "$ex/E1/results.json" -Raw) -eq $before)
  Remove-Item "$ex/E1/shots" -Recurse -Force; Remove-Item "$ex/E1/results-retry.json" -Force
  $cf = New-Run 'CF' @(@{ code = 'F1'; task = 'TF'; checks = , @('C1', 'PASS') })
  @{ id = 'TF'; name = 'Task F'; status = 'in test'; parent = $null; list = 'L1'; assignees = @(); description = ''; comments = @() } | ConvertTo-Json | Set-Content (Join-Path $store 'TF.json')
  (Get-Item (Join-Path $store 'TF.json')).IsReadOnly = $true
  $null = Fin $cf 'F1'; $r1 = Rec $cf 'F1'
  (Get-Item (Join-Path $store 'TF.json')).IsReadOnly = $false
  $null = Fin $cf 'F1'; $r2 = Rec $cf 'F1'
  Expect 'finalize: failed results comment keeps the task open; next run posts + closes' ($r1.commentFailed -and -not $r1.closed -and $r2.closed -and @((Task 'TF').comments | Where-Object { $_.text -match 'Test results' }).Count -eq 1)
  $here0 = (Get-Location).Path
  $wd = pwsh -NoProfile -Command "Set-Location '$($env:TEMP)'; . '$Q'; `$null = Invoke-Finalize -RunDir '$ex' -Code E1 -NoTracker *>&1; (Get-Location).Path" | Select-Object -Last 1
  Expect 'finalize: the caller''s directory is restored' ($wd.TrimEnd('\') -eq $env:TEMP.TrimEnd('\') -and (Get-Location).Path -eq $here0)
  $gb = Join-Path (Kd) 'fakebin'; New-Item -ItemType Directory -Force $gb | Out-Null; $glog = Join-Path $gb 'gws.log'
  "@echo off`r`necho %* >> `"$glog`"`r`necho %* | findstr /c:`"permissions`" >nul && (echo 403 forbidden & exit /b 1)`r`necho {`"id`":`"D1`",`"webViewLink`":`"https://x.example/D1`"}" | Set-Content (Join-Path $gb 'gws.cmd') -Encoding ascii
  $gd = New-Run 'GD' @(@{ code = 'G1'; task = 'TG'; checks = , @('C1', 'PASS') }, @{ code = 'G2'; task = 'TG'; checks = , @('C2', 'PASS') })
  $oldPath = $env:PATH; $env:PATH = "$gb;$env:PATH"
  $g1 = pwsh @np $Q finalize -RunDir $gd -Code G1 -Report gdocs 2>&1 | Out-String
  $docs1 = @(Get-Content $glog | Where-Object { $_ -match 'google-apps.document' }).Count
  $null = pwsh @np $Q finalize -RunDir $gd -Code G1 -Report gdocs 2>&1
  $docs2 = @(Get-Content $glog | Where-Object { $_ -match 'google-apps.document' }).Count
  $env:PATH = $oldPath
  Expect 'finalize gdocs: re-run reuses the doc; failed share warns' ($docs1 -eq 1 -and $docs2 -eq 1 -and $g1 -match 'uploaded but not shared \(anyone\)' -and (Rec $gd 'G1').waitingFor -contains 'G2')
  $rt = New-Run 'RT' @(@{ code = 'Z1'; task = 'TZ'; checks = , @('C1', 'FAIL') })
  @{ id = 'TZ'; name = 'Task Z'; status = 'open'; parent = $null; list = 'L1'; assignees = @(); description = '### C1 — s'; comments = @() } | ConvertTo-Json | Set-Content (Join-Path $store 'TZ.json')
  $null = Fin $rt 'Z1'
  $ro = pwsh @np $Q retest -RunDir $rt -Task TZ -Code Z1 -Mrs 'api!1' 2>&1 | Out-String
  $arc = @(Get-ChildItem "$rt/Z1" -Directory -Filter 'archive-*')
  Expect 'retest: a reused code archives the earlier round' ($arc.Count -eq 1 -and (Test-Path "$($arc[0].FullName)/finalize.json") -and -not (Test-Path "$rt/Z1/finalize.json") -and $ro -match 'archived the earlier round')
  # deployed: an unanswered git host is UNKNOWN, not NOT-DEPLOYED
  $t2 = @'
. $args[0]
function Invoke-HostApi { $null }
$ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$script:memo = @{}
$d = [pscustomobject]@{ target = 'stg'; branch = 'staging' }
"down:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state)"
$memo['projects/g%2Fweb/repository/commits/staging'] = [pscustomobject]@{ id = 'abc' }
"up:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state)"
'@
  $f2 = Join-Path (Kd) 'deployed-null.ps1'; Set-Content $f2 $t2
  $res = @(pwsh @np $f2 $Q 2>&1)
  Expect 'deployed: no answer from the git host = UNKNOWN; an answer = NOT-DEPLOYED' ((@($res) -contains 'down:UNKNOWN') -and (@($res) -contains 'up:NOT-DEPLOYED'))
  @{ targets = @{ tq = @{ api = 'http://127.0.0.1:9'; auth = @{ type = 'none' } } } } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $k 'skills/qa-kit/targets.local.json')
  $ao = Px $Q api -Target tq -Path '/x' -TimeoutSec 5 2>&1 | Out-String; $ac = $LASTEXITCODE
  $null = Px $Q ui bogus 2>&1; $uc = $LASTEXITCODE
  Expect 'api: no answer exits 1 (status printed); ui unknown action exits 2' ($ac -eq 1 -and $ao -match 'HTTP 0' -and $uc -eq 2)
  $gr = Join-Path (Kd) 'pr'; git init -q $gr; git -C $gr commit -qm a --allow-empty; git -C $gr tag v1; $s1 = git -C $gr rev-parse HEAD; git -C $gr commit -qm b --allow-empty; $s2 = git -C $gr rev-parse HEAD
  $sv = "$(Kd)/s.cjs"; $P = 18000 + $PID % 1000
  Set-Content $sv @'
require('http').createServer((q, s) => { let b = ''; q.on('data', (d) => b += d); q.on('end', () => {
  const u = q.url, h = q.headers, j = (o, st = 200, hd = {}) => { s.writeHead(st, { 'content-type': 'application/json', ...hd }); s.end(JSON.stringify(o)) }
  if (u === '/login') return /R1/.test(b) ? j({ access_token: 'A2' }) : j({ access_token: 'A1', refresh_token: 'R1' }, 200, { 'set-cookie': ['sid=1', 'XSRF-TOKEN=x1'] })
  const ok = { '/c': h.cookie && h['x-xsrf-token'] === 'x1', '/b': h.authorization === 'Bearer A2', '/q?api_key=K9': 1, '/t/acme/x': 1, '/h': h['x-sig'] === 's1' }[u]
  u === '/v' ? j({ v: { sha: process.argv[3] } }) : j({}, ok ? 200 : 401) }) }).listen(+process.argv[2], '127.0.0.1')
'@
  $srv = Start-Process node -ArgumentList $sv, $P, $s1 -PassThru -NoNewWindow; Start-Sleep 1
  $T = { param($a, $sub) @{ api = "http://127.0.0.1:$P$sub"; auth = $a; users = @{ admin = 'u', 'K9' }; defaultTenant = 'acme' } }; $L = @{ path = '/login'; body = @{} }
  @{ targets = @{ tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tr = & $T ($L + @{ type = 'login'; refreshField = 'refresh_token' }); tq = & $T @{ type = 'query'; param = 'api_key' }
    tt = & $T @{ type = 'none' } '/t/{tenant}'; th = & $T @{ type = 'command'; cmd = 'echo X-Sig: s1' } } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $k 'skills/qa-kit/targets.local.json')
  $ok = foreach ($x in 'tc/c', 'tr/b', 'tq/q', 'tt/x', 'th/h') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
  Expect "api auth kinds ($ok)" (@($ok).Count -eq 5 -and (Get-Content "$(Kd)/A1-C1_01_tq.json" -Raw) -match 'api_key=\[redacted\]')
  Set-Content "$(Kd)/dp.ps1" @'
. $args[0]; $ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$g, $a, $b = $args[1..3]; $r = @{ checkout = $g }; $memo = @{}; function ssh { $script:sh = $args[-1] }
"cmd:$((Probe @{ probe = "git -C $g rev-parse HEAD" } $r) -eq $b)"; "url:$((Probe @{ probe = $args[4]; probeField = 'v.sha' } $r) -eq $a)"
$v = Probe @{ tag = '^v\d' } $r; "tag:$($v -eq 'v1' -and (LocalAncestor $g $a $v) -and -not (LocalAncestor $g $b $v))"
$null = SshState @{ sudo = $false } 'x'; $x = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($sh -split ' ')[1])); "ssh:$($x -match 'shasum -a 256' -and $x -notmatch 'sudo -n')"
'@
  $res = @(Px "$(Kd)/dp.ps1" $Q $gr $s1 $s2 "http://127.0.0.1:$P/v" 2>&1); $srv.Kill()
  foreach ($x in 'cmd', 'url', 'tag', 'ssh') { Expect "deployed: $x probe" (@($res) -contains "${x}:True") }
  # browser.mjs: mocks, then local fixture servers
  $nm = "$src/skills/qa-kit/node_modules"; $qk = "$k/skills/qa-kit"
  if (Test-Path "$nm/puppeteer-core") {
    Copy-Item "$src/skills/qa-kit/browser.mjs" $qk
    New-Item -ItemType Junction -Path "$qk/node_modules" -Value (Resolve-Path $nm).Path | Out-Null
    function NodeT($n, $js) { $f = Join-Path (Kd) "$n.mjs"; [IO.File]::WriteAllText($f, "const BM = 'file:///$("$qk/browser.mjs" -replace '\\', '/')', m = await import(BM)`n$js"); @(node $f @args 2>&1) }
    $res = NodeT pick ("const pg = (els) => ({ waitForSelector: async () => {}, `$`$: async () => els }), e = (p) => m.pick(p, '.x', 0, 'x').catch((x) => x.message)`n" +
      "console.log(/has 0 match\(es\), no index 0/.test(await e(pg([]))), /has no box/.test(await e(pg([{ scrollIntoView: async () => {}, boundingBox: async () => null }]))))")
    Expect 'browser.mjs pick: bad nth / hidden element errors' ("$res" -eq 'true true')
    $res = NodeT ports @'
import { rmSync, existsSync } from 'node:fs'
const P = m.sessionPort, a = await P('s', 't', 'a'), seen = [], job = (n) => m.withLock('l', async () => { seen.push(n); await new Promise((r) => setTimeout(r, 150)); seen.push(n) })
await Promise.all([job(1), job(2)]); const uniq = new Set([a, await P('s', 't', 'v'), await P('p', 't', 'a')]).size === 3
rmSync(m.kitPath('browser-ports')); console.log(a === await P('s', 't', 'a') && uniq, /^(\d),\1,/.test(seen.join(',')), existsSync(m.kitPath('browser-ports')))
'@
    Expect 'browser.mjs: stable port per user key, locked logins' ("$res" -eq 'true true true')
    # tab cap: 9 concurrent openers -> 8 tabs, the 9th waits; a full browser fails clearly; dead / left holders are swept
    $res = NodeT tabs @'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
const { openTab, closeTab, kitPath, sweepAll } = m
let n = 0, max = 0; const tabs = [], K = 'k|t|a'
const mk = () => { const id = 'T' + (++n), p = { url: () => 'https://app/x', close: async () => { tabs.splice(tabs.indexOf(p), 1) },
  createCDPSession: async () => ({ send: async () => ({ targetInfo: { targetId: id } }), detach: async () => {} }) }; return p }
const browser = { pages: async () => [...tabs], newPage: async () => { await new Promise((r) => setTimeout(r, 20)); const p = mk(); tabs.push(p); max = Math.max(max, tabs.length); return p } }
let done = 0; const all = Array.from({ length: 9 }, () => openTab(browser, K, { agent: 'A' }).then((p) => { done++; return p }))
await new Promise((r) => setTimeout(r, 5000))
console.log('waits:' + (tabs.length === 8 && max === 8 && done === 8))
await closeTab(tabs[0], K); const got = await Promise.all(all)
console.log('ninth:' + (got.every(Boolean) && tabs.length === 8 && max === 8))
const e = await openTab(browser, K, { agent: 'A', waitMs: 1200 }).catch((x) => x.message)
console.log('fails:' + /all 8 tabs of k\|t\|a stayed busy for 1 s/.test(e))
const f = `${kitPath('sessions')}/tabs-k__t__a.json`, reg = JSON.parse(readFileSync(f, 'utf8'))
reg[tabs[1].__tid].pid = 999999; reg[tabs[2].__tid].agent = 'Z'; reg[tabs[1].__tid].at = reg[tabs[2].__tid].at = reg[tabs[1].__tid].seen = reg[tabs[2].__tid].seen = 0; reg[tabs[3].__tid].pid = 999999; writeFileSync(f, JSON.stringify(reg))
mkdirSync(kitPath('board'), { recursive: true }); writeFileSync(`${kitPath('board')}/z.json`, JSON.stringify({ agent: 'Z', status: 'left' }))
const dead = tabs[1], left = tabs[2], grace = tabs[3], t = await openTab(browser, K, { agent: 'A', waitMs: 1200 }).catch(() => null)
console.log('orphans:' + (!!t && !tabs.includes(dead) && !tabs.includes(left) && tabs.includes(grace) && tabs.length === 7))
const S = kitPath('sessions'); writeFileSync(kitPath('browser-ports'), JSON.stringify({ 'k|t|a': 9, 'u__v|t|a': 9 }))
writeFileSync(`${S}/tabs-u____v__t__a.json`, JSON.stringify({ _key: 'u__v|t|a' })); writeFileSync(`${S}/tabs-gone.json`, JSON.stringify({ _key: 'gone' }))
await sweepAll(); console.log('sweep:' + (existsSync(f) && existsSync(`${S}/tabs-u____v__t__a.json`) && !existsSync(`${S}/tabs-gone.json`)))
'@
    foreach ($x in 'waits', 'ninth', 'fails', 'orphans', 'sweep') { Expect "browser.mjs tabs: $x" (@($res) -contains "${x}:true") }
    Expect 'browser.mjs: never logs out' ((Get-Content "$qk/browser.mjs" -Raw) -notmatch '(?i)localStorage\.clear|sessionStorage\.clear|logout|8 \* 3600')
    # fixture app + IdP: form, TOTP, relogin (Chrome); sso-steps, shared cookie (Playwright)
    $pwm = $env:KIT_PLAYWRIGHT ?? "$(& $py -c 'import os, playwright; print(os.path.dirname(playwright.__file__))' 2>$null)/driver/package"; $nopw = -not (Test-Path "$pwm/index.mjs")
    $res = NodeT auth @'
import http from 'node:http'
import { writeFileSync } from 'node:fs'
const [TF, PW] = process.argv.slice(2), U = { admin: ['qa', '', 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'] }, F = { '#u': '{user}', '#c': '{totp}' }
let posts = 0, gen = 1
const form = (to) => `<html><form method="post" action="${to}"><input id="u" name="u"><input id="c" name="c"><button>Go</button>`
const app = http.createServer((q, s) => {
  const go = (l, c) => { s.writeHead(302, { location: l, ...(c && { 'set-cookie': `sid=${gen}; HttpOnly` }) }); s.end() }
  if (q.method === 'POST') { posts++; let d = ''; q.on('data', (x) => (d += x)); return q.on('end', () => (/u=qa&c=\d{6}/.test(d) ? go(web + '/', 1) : go(q.url))) }
  if (/^\/(login|idp)$/.test(q.url)) return s.end(form(q.url === '/idp' ? web + '/sso' : '/login'))
  if (q.headers.cookie === `sid=${gen}`) return s.end('<html>home')
  go(q.url === '/sso-app' ? web.replace('127.0.0.1', 'localhost') + '/idp' : '/login')
})
await new Promise((r) => app.listen(0, r))
const web = `http://127.0.0.1:${app.address().port}`, steps = [{ goto: '/sso-app' }, { fill: F }, { click: 'button', waitUrl: '/$' }]
writeFileSync(TF, JSON.stringify({ targets: { form: { web, webLogin: { path: '/login', fields: F, submit: 'button' }, users: U },
  sso: { web, browser: { engine: 'chromium' }, webLogin: { type: 'sso-steps', steps }, users: U }, ff: { web, browser: { engine: 'firefox' }, webLogin: {}, users: U } } }))
const b = await import(BM + '?a'), home = async (s) => (await b.text(s.page)).includes('home'), out = async (k, f) => console.log(k + ':' + await f().catch((e) => e.message))
console.log('totp:' + (b.totp(U.admin[2], 59000) === '287082'))
process.env.KIT_QA_TARGETS = 'x'; await out('pin', () => b.session({ target: 'form' }).then(() => false, (e) => /QA run's target/.test(e.message))); delete process.env.KIT_QA_TARGETS
await out('chrome', async () => { const s = await b.session({ target: 'form', tenant: 'a' }), r = await home(s) && posts === 1; gen++; await b.go(s.page, '/'); const r2 = r && await home(s) && posts === 2; await s.done(); await b.killSession(s.port); return r2 })
PW && (process.env.KIT_PLAYWRIGHT = PW)
for (const k of ['sso', 'shared']) await out(k, async () => { const s = await b.session({ target: 'sso', tenant: 'b' }), r = s.engine === 'chromium' && await home(s) && posts === 3; await s.done(); return r })
await out('hint', () => b.session({ target: 'ff' }).then(() => false, (e) => /playwright install firefox/.test(e.message)))
process.exit(0)
'@ "$qk/targets.local.json" $(if (-not $nopw) { $pwm })
    foreach ($x in 'totp', 'pin', 'chrome', 'sso', 'shared', 'hint') { Expect "browser.mjs login: $x" ((@($res) -contains "${x}:true") -or ($nopw -and $x -in 'sso', 'shared', 'hint')) }
    [IO.Directory]::Delete("$qk/node_modules")   # the junction only
  } else { 'SKIP browser.mjs (no puppeteer-core in skills/qa-kit)' }
  # testy: web testers share the per-user Chrome; scoped retries -> results-retry.json; publish -ExpectChecks
  $js5 = @'
const ports = []
const ck = (id, result) => ({ id, subtask_id: 'T1', screen: 's', result, what_was_done: 'w', observed: 'o', evidence: [], attempts: 1 })
const mk = () => { const calls = []; return { calls, agent: async (prompt, o) => {
 calls.push({ label: o.label, prompt })
 if (/^test:/.test(o.label)) ports.push(/SHARED logged-in Chrome/.test(prompt) && /relogin\(s\)/.test(prompt) && !/killSession\(\)/.test(prompt) && !/session\(\{ port/.test(prompt))
 if (/^record-args/.test(o.label)) return _rec()
 if (o.label === 'test:W0') return _res('W0', [ck('C1', 'NOT_TESTED'), ck('C2', 'PASS'), ck('C3', 'PASS'), ck('C4', 'PASS')])
 if (/^(test|retest):/.test(o.label)) return _res('x', [ck('C1', 'PASS')])
 if (/^retest-strong:/.test(o.label)) return _res('W0', [ck('C1', 'PASS')])
 return _ok('published') } } }
const items = Array.from({ length: 45 }, (_, i) => ({ code: `W${i}`, title: 't', guideFile: 'g.md', lane: 'web', subtasks: [{ id: 'T1' }] }))
const a = mk(), b = mk()
run({ runDir: 'C:/runs/P1', kitDir: 'C:/kit', learn: false, items }, a.agent, _n, _n, null)
 .then(() => run({ runDir: 'C:/runs/P1', kitDir: 'C:/kit', learn: false, instance: 'w1', items }, b.agent, _n, _n, null)).then(() => {
 console.log(`ports:${ports.length === 90 && ports.every(Boolean)}`)   // shared per-user Chrome (owner 2026-10-16): no per-run ports
 const s = a.calls.find((c) => c.label === 'retest-strong:W0'), cl = a.calls.find((c) => c.label === 'close:W0')
 console.log(`retry-file:${!!s && /results-retry\.json/.test(s.prompt) && /-Results results-retry\.json/.test(s.prompt) && /Never write/.test(s.prompt)}`)
 console.log(`expect:${!!cl && /-ExpectChecks 4/.test(cl.prompt) && /exit 4 = still waiting/.test(a.calls.find((c) => c.label === 'test:W0').prompt)}`)
}).catch(_err)
'@
  $res = Invoke-Js tc-ports $js5 $wf
  Expect-Each $res 'testy: #' 'ports', 'retry-file', 'expect' -Show 5
  # a FAIL with evidence one re-test misses stays FAIL; without evidence it may pass
  $js6 = @'
const calls = []
const ck = _ck
async function agent(prompt, o) {
 calls.push({ label: o.label, prompt })
 if (/^record-args/.test(o.label)) return _rec()
 if (/^test:/.test(o.label)) return _res('A1', [ck('C1', 'FAIL', { defect: 'own', evidence: ['A1-C1_01_500.json'] }), ck('C2', 'FAIL', { defect: 'own' }), ck('C3', 'PASS')])
 if (/^verify:/.test(o.label)) return { verdicts: ['C1', 'C2'].map((id) => ({ id, outcome: 'refuted', confirmed: false, attempts: 1, observed: 'fine now', evidence: [`A1-${id}_verify_01_ok.json`], basis: 'saved _verify files' })) }
 return _ok('published')
}
const args = { runDir: 'C:/runs/R6', kitDir: 'C:/kit', learn: false, items: [{ code: 'A1', title: 'A', guideFile: 'g.md', lane: 'api', subtasks: [{ id: 'T1' }] }] }
run(args, agent, _n, _n, null).then(() => {
 const cl = calls.find((c) => c.label === 'close:A1')
 console.log(`flaky:${!!cl && /"id":"C1"[^}]*"result":"FAIL"[^}]*"verify":"not reproduced \(flaky\)","flaky":true/.test(cl.prompt)}`)
 console.log(`no-evidence:${!!cl && /"id":"C2"[^}]*"result":"PASS_WITH_NOTE"/.test(cl.prompt)}`)
}).catch(_err)
'@
  $res = Invoke-Js tc-flaky $js6 $wf
  Expect-Each $res 'testy verify: #' 'flaky', 'no-evidence' -Show 5
  $fk = New-Run 'FK' @(@{ code = 'K1'; task = 'TQ'; checks = , @('X1', 'FAIL', 'new') })
  $rk = Get-Content "$fk/K1/results.json" -Raw | ConvertFrom-Json; $rk.checks[0] | Add-Member flaky $true; $rk | ConvertTo-Json -Depth 8 | Set-Content "$fk/K1/results.json"
  $null = Fin $fk 'K1'
  Expect 'finalize: flaky new defect -> [Bug] task, tagged flaky' (@(Bugs | Where-Object { $_.parent -eq 'PQ' -and $_.name -match '\[flaky\]' -and $_.description -match '### X1 — s \(flaky\)' }).Count -eq 1)
  Remove-Item Env:KIT_TRACKER_TYPE, Env:KIT_REPORT_TYPE
  Remove-TestKit $k
}

# === orch: track, decisions, deploy batching, lessons
if ($Area -in 'orch', 'all') {
  "== orch"
  $k = New-TestKit orch; $O = Join-Path $k 'skills/orchestrate/orch.ps1'; $tf = Join-Path $k '.state/tracking.json'
  $env:KIT_TRACKER_TYPE = 'clickup'   # tag CU-
  $out = pwsh @np $O track add -Task 0 -Mrs 'web!1' 2>&1 | Out-String
  Expect "track: placeholder task '0' refused" ($LASTEXITCODE -ne 0 -and $out -match 'needs a real -Task id')
  $out = pwsh @np $O track add -Task 'CU-abc123' -Mrs 'web!1,web!2' -MergeAfter 'web!2>api!7' 2>&1 | Out-String
  $tasks = (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks
  Expect 'track: tag stripped, merge order echoed' ($tasks.ContainsKey('abc123') -and $out -match 'merge-after: web!2>api!7')
  $null = pwsh @np $O track remove -Task abc123 -Mrs 'web!2' 2>&1
  $tasks = (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks
  Expect 'track: remove drops the MR and its pair' ((@($tasks.abc123.mrs) -join ',') -eq 'web!1' -and -not @($tasks.abc123.mergeAfter).Count)
  Remove-Item Env:KIT_TRACKER_TYPE
  $cf = Join-Path (Kd) 'brief.contracts.md'; '# contracts' | Set-Content $cf
  $out = pwsh @np $O decide ask -Run w1 -Agent X1 -Item A2 -Question 'Keep the old total?' -Options 'A: keep','B: recompute' -Recommend A -Contracts $cf | Out-String
  $id = if ($out -match 'DECISION (\S+) pending') { $Matches[1] }
  $pend = @(pwsh @np $O decide list -Pending -Json | ConvertFrom-Json)
  Expect 'decide ask: pending + contracts note' ($id -and $pend.Count -eq 1 -and (Get-Content $cf -Raw) -match "DECISION NEEDED $id")
  $null = pwsh @np $O decide answer -Id $id -Answer 'A, keep it'
  $w = pwsh @np $O decide wait -Id $id -MaxMinutes 1 | Out-String
  Expect 'decide answer: wait returns it, contracts carry it, none pending' ($w -match 'ANSWERED' -and $w -match 'keep it' -and (Get-Content $cf -Raw) -match "$id ANSWERED" -and -not @(pwsh @np $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_ }).Count)
  $out = pwsh @np $O decide ask -Kind envfix -Run w1 -Agent X1 -Item A3 -Question 'refresh the release' -Contracts $cf | Out-String
  $eid = if ($out -match 'ENV-FIX (e-\S+) pending') { $Matches[1] }
  $pend = @(Px $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_ })
  $null = Px $O decide answer -Id $eid -By coordinator -Answer 'done: refreshed'
  $w = Px $O decide wait -Id $eid -MaxMinutes 1 | Out-String
  Expect 'decide envfix: pending for the coordinator, contracts note, answer returned' ($eid -and $pend.Count -eq 1 -and $pend[0].kind -eq 'envfix' -and (Get-Content $cf -Raw) -match "ENV-FIX NEEDED $eid" -and $w -match 'done: refreshed')
  $i1, $i2 = 'A1', 'A2' | ForEach-Object { (Px $O decide ask -Run w1 -Agent X9 -Item $_ -Question "q$_" -Options 'A: a','B: b' | Out-String) -replace '(?s).*DECISION (\S+) pending.*', '$1' }
  $null = Px $O board check -Session s1 2>&1; $bc = $LASTEXITCODE
  $hp = Px (Join-Path $k 'skills/orchestrate/orch.ps1') setup --help 2>&1 | Out-String; $hc = $LASTEXITCODE
  Expect 'decide ids unique within a second; board check without -Worktree exit 2; orch.ps1 setup --help prints usage, exit 0' ($i1 -ne $i2 -and $bc -eq 2 -and $hc -eq 0 -and $hp -match 'commands in one file' -and $hp -notmatch 'setup:')
  # deploy batching
  $cfgF = Join-Path $k 'skills/dev-kit/kit.local.json'; $J = { param($o, $f) $o | ConvertTo-Json -Depth 6 | Set-Content $f }; $dep = { Px $O deploy @args }
  & $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }, @{ target = 'prod'; branch = 'production'; job = 'deploy' }, @{ target = 'live'; production = $true }, @{ target = 'preprod'; production = $false }) }); deploy = @{ trigger = 'ask'; minIntervalHours = @{ default = 4 } } } $cfgF
  $null = New-Item -ItemType Directory -Force (Split-Path $tf); & $J @{ tasks = @{ t1 = @{ task = 't1'; mrs = @('api!1'); done = $true; doneAt = (Get-Date).ToString('s') }; t2 = @{ task = 't2'; mrs = @('api!2'); done = $false } }; automerge = @{} } $tf
  $fx = Join-Path (Kd) 'deploy-fixture.json'
  & $J @{ mrs = @{ 'api!1' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) }; 'api!2' = @{ rows = @(@{ target = 'stage'; state = 'DEPLOYED'; detail = 'live' }) }; 'api!3' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) } }; lastCi = @{ stage = (Get-Date).AddHours(-6).ToString('s') } } $fx
  $plan = { @(& $dep plan -Offline $fx -Json | ConvertFrom-Json) }; $p = & $plan
  Expect 'deploy plan: production by name / flag / false; one ASK batch for stage' (($p.target -join ',') -eq 'stage,preprod' -and $p[0].target -eq 'stage' -and $p[0].status -eq 'ASK' -and (@($p[0].mrs.mr) -join ',') -eq 'api!1')
  $null = & $dep request -Mrs 'https://git.example.com/g/api/-/merge_requests/3' -Run w2 -Offline $fx; $p = & $plan
  Expect 'deploy request: another session''s MR joins the same batch' ((@($p[0].mrs.mr | Sort-Object) -join ',') -eq 'api!1,api!3')
  $null = & $dep record -Env stage -Mrs 'api!1','api!3' -By tester; $p = & $plan
  Expect 'deploy record: WAIT in the window, the request cleared' ($p[0].status -eq 'WAIT' -and -not @($p[0].pending).Count)
  & $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }, @{ name = 'py'; deploys = @(@{ target = 'pystage' }) }) } $cfgF
  $fx2 = Join-Path (Kd) 'deploy-fixture2.json'; & $J @{ mrs = @{ 'api!5' = @{ rows = @(@{ target = 'stage'; state = 'UNKNOWN'; detail = 'cannot reach the host' }) } } } $fx2
  $dr = & $dep request -Mrs 'api!5' -Run w4 -Offline $fx2 | Out-String
  Expect 'deploy request: only the MR repo''s deploys; UNKNOWN names the deploy and why' ($dr -match 'DEPLOY stage: UNKNOWN: the deploy check failed: api!5: cannot reach the host' -and $dr -notmatch 'pystage')
  $null = & $dep record -Env stage -Mrs 'api!5' -By tester
  & $J @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }) } $cfgF
  $null = & $dep request -Mrs 'api!3' -Run w3 -Offline $fx; $p = & $plan
  Expect 'deploy plan: trigger owner -> READY in the window, never ASK / WAIT' ($p[0].status -eq 'READY' -and $p[0].trigger -eq 'owner')
  $sup = (Get-Command (Join-Path $k 'skills/orchestrate/orch.ps1')).ScriptBlock.Ast.Extent.Text -match "deploy\.trigger' 'owner'\)\)\.ToLower\(\) -eq 'ask'"
  Expect 'supervise: DEPLOY ASK only under trigger ask' $sup
  $ld = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath launches }; New-Item -ItemType Directory -Force $ld | Out-Null
  $full = '{"brief":"C:/b/wave-x.md","agents":[{"id":"X1","items":"A1"}],"mandate":["do it"]}'
  $af = Join-Path (Kd) 'args.json'; [IO.File]::WriteAllText($af, $full)
  $h = & { . $O; Get-KitFnv $full }
  $bad = pwsh @np $O launch -Self -Script buildy.js -Run wave-x -ArgsFile $af -Fnv 00000000 | Out-String; $badCode = $LASTEXITCODE
  $ok = pwsh @np $O launch -Self -Script buildy.js -Run wave-x -ArgsFile $af -Fnv $h | Out-String
  Expect 'launch -Self: wrong hash MISMATCH (exit 1), right one RECORDED' ($badCode -eq 1 -and $bad -match 'MISMATCH' -and $ok -match 'RECORDED')
  $null = pwsh @np $O launch -RunId wf_t1 -Script (Join-Path $k 'workflows/buildy.js') -ArgsJson '{"brief":"C:/b/wave-x.md"}' 2>&1
  $rj = Get-Content (Join-Path $ld 'wf_t1.json') -Raw | ConvertFrom-Json; $rj.holderPid = 999999; $rj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $ld 'wf_t1.json')   # its session is gone
  $l = pwsh @np $O launch -List -Brief | Out-String
  $rc = pwsh @np $O recover | Out-String
  Expect 'launch -List / recover: stopped run resumes with exact args' ($l -match 'wf_t1' -and $l -match 'self-buildy-wave-x' -and $rc -match "resumeFromRunId: 'wf_t1'" -and $rc -match 'written by the workflow: exact' -and (Test-Path (Join-Path $ld 'wf_t1.resume.md')))
  Expect 'recover: RESUME line has the recorded args byte for byte' ($rc.Contains("resumeFromRunId: 'wf_t1', args: $full })"))
  $sa = '{"select":{"statuses":["inTest"]},"target":"stg","kitDir":"C:/k"}'; $saf = Join-Path (Kd) 'args-sel.json'; [IO.File]::WriteAllText($saf, $sa)
  $null = pwsh @np $O launch -Self -Script testy.js -Run select-stg -ArgsFile $saf -Fnv (& { . $O; Get-KitFnv $sa }) -RunDir 'C:/rt/qa-runs/d-stg'
  $sr = Get-ChildItem $ld -Filter 'self-testy-select-stg-*.json' | Get-Content -Raw | ConvertFrom-Json
  Expect 'launch -Self testy: original args + runDir as extra field' ($sr.argsRaw -eq $sa -and $sr.runDir -eq 'C:/rt/qa-runs/d-stg' -and -not $sr.args.runDir -and (& { . $O; Get-LaunchRunName ($sa | ConvertFrom-Json) }) -eq 'select-stg')
  $sl0 = pwsh @np $O launch -List -Brief | Out-String; $sf = Get-ChildItem $ld -Filter 'self-testy-select-stg-*.json' | Select-Object -First 1
  $sr | Add-Member -Force completed (Get-Date).ToString('o'); $sr | ConvertTo-Json -Depth 10 | Set-Content $sf.FullName
  $sl1 = pwsh @np $O launch -List -Brief | Out-String
  Expect 'launch -List: a completed self record (owner-stopped run) is no stopped run' ($sl0 -match 'select-stg' -and $sl1 -notmatch 'select-stg')
  # orch batch 2: board TAKEOVER under lock; self records per args hash; promotion hold; passed statuses
  # never re-applied; "All MRs merged" once; deploy plan UNKNOWN on a failed check; supervise step-aside;
  # LESSONS.md lock freed on a failed -Bump; top-level --help; MergedTip on a submodule
  $bwt = Join-Path (Kd) 'bwt'
  $j1 = pwsh @np $O board join -Agent BX -Run rb -Claims $bwt | Out-String; $s1 = if ($j1 -match 'SESSION (\S+)') { $Matches[1] }
  $j2 = pwsh @np $O board join -Agent BX -Run rb -Claims $bwt -Resume | Out-String
  $bt = pwsh @np $O board beat -Session $s1 | Out-String; $btc = $LASTEXITCODE
  $bd = TkPath $k board
  Expect 'board: beat after TAKEOVER exit 1, no lock left' ($j2 -match 'TAKEOVER' -and $btc -eq 1 -and $bt -match 'TAKEN OVER' -and -not @(Get-ChildItem $bd -Filter '*.lock').Count)
  $a2 = '{"brief":"C:/b/wave-y.md","agents":[{"id":"Y1","items":"B1"}]}'; $af2 = Join-Path (Kd) 'args2.json'; [IO.File]::WriteAllText($af2, $a2)
  $h2 = & { . $O; Get-KitFnv $a2 }
  $null = pwsh @np $O launch -Self -Script buildy.js -Run wave-x -ArgsFile $af2 -Fnv $h2
  Expect 'launch -Self: 2 launches, one run name: 2 records' (@(Get-ChildItem $ld -Filter 'self-buildy-wave-x-*.json').Count -eq 2)
  '{"kitDir":"C:/k","runDir":"C:/r"}' | Set-Content (Join-Path $ld 'args-testy-r.json'); '{"script":"","at":"bad"}' | Set-Content (Join-Path $ld 'broken.json')
  $ll = pwsh @np $O launch -List 2>&1 | Out-String; $cl = pwsh @np $O cleanup -IfDue -Quiet 2>&1 | Out-String; $clc = $LASTEXITCODE
  Expect 'launch records: args dumps / broken records skipped; SessionStart hook shows no error' ($ll -notmatch 'Exception|Cannot bind' -and $cl -notmatch 'Exception|Cannot bind' -and $clc -eq 0)
  $rn = & { . $O; Get-LaunchRunName ([pscustomobject]@{ brief = 'C:/b/wave-x.md' }) }
  Expect 'launch: a brief-named run + 4 hex of the brief path' ($rn -match '^wave-x-[0-9a-f]{4}$')
  $tt = @'
$env:KIT_TRACKER_TYPE = 'none'
. $args[0]
$global:sets = @(); $global:cmts = @()
$global:q = 0; function Invoke-HostApi([string]$Path, [string]$Method = 'GET', [hashtable]$Fields = @{}, [switch]$NoMemo) { if ($Path -match 'search=') { $global:q++ }; [pscustomobject]@{ state = 'merged' } }
function Get-TrackerTask($id) { [pscustomobject]@{ status = 'promoted'; subtasks = @() } }
function Set-TrackerStatus($id, $s) { $global:sets += "$id=$s" }
function Add-TrackerComment($id, $text) { $global:cmts += [pscustomobject]@{ id = $id; text = $text } }
function Get-TrackerComments($id) { @($global:cmts | Where-Object { $_.id -eq $id }) }
function Start-Process { }   # no background cleanup from a test
$null = Invoke-Track add -Task t5 -Mrs 'g/web!9' -OnMerged 'review,promoted'
$null = Invoke-Track run -Detail
Update-KitTracking { param($t) $t.tasks['t5'].done = $false }
$null = Invoke-Track run -Detail
"skip:$(-not @($global:sets | Where-Object { $_ -like 't5=*' }).Count)"
"once:$(@($global:cmts | Where-Object { $_.id -eq 't5' -and $_.text -match '^All MRs merged' }).Count -eq 1)"
$h = Invoke-Track add -Task t6 -Mrs 'g/web!8' -HoldPromotion 'deferred A2' | Out-String
$r1 = Invoke-Track run -Detail | Out-String
$c1 = @($global:cmts | Where-Object id -eq 't6').Count
$null = Invoke-Track add -Task t6 -HoldPromotion ''
$null = Invoke-Track run -Detail
"hold:$($h -match 'promotion HELD' -and $r1 -match 'HOLD t6: promotion held' -and $c1 -eq 0 -and @($global:cmts | Where-Object id -eq 't6').Count -eq 1)"
$KitConf.TrackerRepos = @('g/web'); $KitConf.TrackerTag = 'CU-'; $null = Invoke-Track add -Task t7 -Discover -Mrs 'g/web!7'; $global:q = 0
$null = Invoke-Track run; $q1 = $global:q; $null = Invoke-Track run
"throttle:$($q1 -ge 1 -and $global:q -eq $q1 -and (Read-KitTracking).tasks['t7'].checkedAt)"
function Invoke-KitExe([string]$Exe, [string[]]$A, [int]$TimeoutSec = 60) { [pscustomobject]@{ code = 2; out = 'qa.ps1: usage error'; err = ''; timedOut = $false } }
$p = @(Invoke-Deploy plan -Json | ConvertFrom-Json)
"unknown:$(@($p | Where-Object status -eq 'UNKNOWN').Count -ge 1 -and -not @($p | Where-Object status -eq 'NOTHING').Count)"
'@
  $ttf = Join-Path (Kd) 'track-test.ps1'; Set-Content $ttf $tt
  $res = @(pwsh @np $ttf $O 2>&1)
  foreach ($x in 'skip', 'once', 'hold', 'unknown', 'throttle') { Expect "track/deploy: $x (throttle: the MR search once per 30 min, tasks rotate by checkedAt)" (@($res | Where-Object { "$_" -eq "${x}:True" }).Count -eq 1) }
  if (@($res | Where-Object { "$_" -match ':True$' }).Count -ne 4) { $res | Select-Object -Last 8 }
  $lkf = Join-Path (TkPath $k cache -Create) 'supervise.lock'
  @{ session = 'other'; at = (Get-Date).ToString('s'); pid = 1 } | ConvertTo-Json | Set-Content $lkf
  $sv = pwsh @np $O supervise -Brief -Session me | Out-String
  Expect 'supervise: another session''s fresh lock -> steps aside, lock file kept, no .lock left' ($sv -match 'steps aside' -and (Get-Content $lkf -Raw) -match 'other' -and -not (Test-Path "$lkf.lock"))
  $null = pwsh @np $O learn -Skill revy -Bump 'no such lesson words'; $bc2 = $LASTEXITCODE
  Expect 'learn -Bump miss: exit 1, LESSONS.md lock released' ($bc2 -eq 1 -and -not (Test-Path (Join-Path $k 'LESSONS.md.lock')))
  $hlp = pwsh @np $O --help | Out-String; $hc2 = $LASTEXITCODE; $null = pwsh @np $O nope; $nc = $LASTEXITCODE
  Expect 'orch.ps1 --help: header only, exit 0; bad verb exit 2' ($hc2 -eq 0 -and $hlp -match '^\s*orch\.ps1: the coordinator' -and $hlp -notmatch '__verb|#>' -and $nc -eq 2)
  $hx = foreach ($sc in 'skills/dev-kit/dev.ps1', 'skills/qa-kit/qa.ps1', 'skills/android-swarm/swarm.ps1') { $null = Px (Join-Path $src $sc) --help 2>&1; "$LASTEXITCODE" }
  Expect "dev.ps1 / qa.ps1 / swarm.ps1 --help exit 0 ($($hx -join ','))" (($hx -join ',') -eq '0,0,0')
  $sm = Join-Path (Kd) 'subm'; New-Item -ItemType Directory -Force $sm | Out-Null
  git init -q "$sm/sub"; git -C "$sm/sub" commit -q --allow-empty -m s; git init -q "$sm/super"; git -C "$sm/super" commit -q --allow-empty -m s
  git -C "$sm/super" -c protocol.file.allow=always submodule add -q "$sm/sub" m 2>$null; git -C "$sm/super/m" remote set-url origin 'https://git.example.com/g/subrepo.git'
  git -C "$sm/super" remote add origin 'https://git.example.com/g/superrepo.git'
  $gd = "$(git -C "$sm/super/m" rev-parse --path-format=absolute --git-common-dir)".Trim()
  $mt = & { . $O; $fa = (Get-Command Invoke-Cleanup).ScriptBlock.Ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'MergedTip' }, $true) | Select-Object -First 1; . ([scriptblock]::Create($fa.Extent.Text)); $global:seen = @(); function Invoke-HostVerb([string]$Verb, [hashtable]$A) { $global:seen += $A.repo; @() }; $null = MergedTip $gd 'f/x'; $global:seen -join ' ' }
  Expect 'cleanup: MergedTip on a submodule''s git dir asks the submodule''s project, not the superproject' ($mt -match 'g/subrepo' -and $mt -notmatch 'superrepo')
  $nt = @'
. $args[0]
$env:KIT_NET_TRIES = '1'; Initialize-KitTracker -Type clickup
function clickup { $global:LASTEXITCODE = 1; 'Error: dial tcp: lookup api.clickup.com: no such host' }
$q = Set-TrackerStatus 'T9' 'inTest' 3>$null; "queued:$("$q" -match '^QUEUED' -and (Test-Path (Get-KitPath outbox)))"
function clickup { $global:LASTEXITCODE = 0; "status set: $($args[2])" }
$s = @(Invoke-KitOutbox); "sent:$("$s" -match '^SENT status T9' -and -not (Test-Path (Get-KitPath outbox)))"
function clickup { $global:LASTEXITCODE = 1; 'Error: task not found' }
try { $null = Set-TrackerStatus 'T9' 'inTest'; 'real:False' } catch { "real:$(-not (Test-Path (Get-KitPath outbox)))" }
'@
  $nf = Join-Path (Kd) 'outbox-test.ps1'; Set-Content $nf $nt
  $res = @(pwsh @np $nf (Join-Path $k 'skills/dev-kit/lib.ps1') 2>&1)
  Expect-Each $res 'outbox: #' 'queued', 'sent', 'real'
  $sd = TkPath $k qa-seats; New-Item -ItemType Directory -Force "$sd/seats", "$sd/claims" | Out-Null
  @{ agent = 'test:D1'; kind = 'web'; need = 1.5; since = (Get-Date).ToString('s'); holderPid = 999999 } | ConvertTo-Json | Set-Content "$sd/seats/test_D1.json"
  $rd = Join-Path (Kd) 'runs/S'; New-Item -ItemType Directory -Force $rd | Out-Null
  @{ run = 'S'; code = 'S1'; owner = 'w9'; since = (Get-Date).ToString('s'); holderPid = 999999 } | ConvertTo-Json | Set-Content "$sd/claims/S__S1.json"
  $null = pwsh @np (Join-Path $k 'skills/qa-kit/qa.ps1') seat status
  $cl = pwsh @np (Join-Path $k 'skills/qa-kit/qa.ps1') seat acquire -Agent test:S1 -Kind api -RunDir $rd -Code S1 -Owner w1 -KeepFreeGB 0.1 -WaitMinutes 0 | Out-String
  Expect 'seats: a dead holder''s seat is freed, its claim taken over' (-not (Test-Path "$sd/seats/test_D1.json") -and $cl -notmatch 'ALREADY' -and (Get-Content "$sd/claims/S__S1.json" -Raw | ConvertFrom-Json).owner -eq 'w1')
  $out = "Merge branch 'feature/long-branch-name-for-testing' into deploy/staging-longer-name" | python -X utf8 (Join-Path $src 'skills/orchestrate/kittool.py') prose --kind merge-commit - | Out-String
  Expect 'prose: merge-commit kind (no conv, no 72-char subject)' ($LASTEXITCODE -eq 0)
  @{ orgTerms = @('Acmecorp') } | ConvertTo-Json | Set-Content (Join-Path $k 'skills/dev-kit/kit.local.json')
  $null = pwsh @np $O learn -Skill revy -Lesson '(2×) a generic lesson'
  $null = pwsh @np $O learn -Skill revy -Lesson 'an Acmecorp lesson'
  $r1 = pwsh @np $O learn -Read -Skill revy | Out-String
  Expect 'learn: generic -> LESSONS.md, org term -> LESSONS.local.md' ($r1 -match 'a generic lesson' -and $r1 -match '\(local\)' -and (Get-Content (Join-Path $k 'LESSONS.local.md') -Raw) -match 'Acmecorp' -and (Get-Content (Join-Path $k 'LESSONS.md') -Raw) -notmatch 'Acmecorp')
  $null = pwsh @np $O learn -Skill revy -Fixed 'a generic lesson'
  $hi = pwsh @np $O learn -History -Grep 'a generic lesson' | Out-String
  Expect 'learn -Fixed: line leaves LESSONS.md, shown by -History' ((Get-Content (Join-Path $k 'LESSONS.md') -Raw) -notmatch 'a generic lesson' -and $hi -match '\(fixed in kit\) \(2×\) a generic lesson')
  $KT = Join-Path $src 'skills/orchestrate/kittool.py'; $pf = Join-Path $k 'mr.md'
  "## Summary`nhttps://t.example.com/T-1 — keep the offset`n## Changes`n- ISO dates`n## How tested`n- tests ``ExportTest```n## Risks`n- none`n## Links`n- doc" | Set-Content $pf
  $null = python -X utf8 $KT prose --kind mr-body $pf; Expect 'prose: a template-shaped MR body passes' ($LASTEXITCODE -eq 0)
  "Hi, I hope this is basically fine`n## Changes`n- a`n- b`n- c`n- d" | Set-Content $pf
  $out = python -X utf8 $KT prose --kind mr-body $pf | Out-String
  Expect 'prose: filler, missing sections, a 4th bullet are findings' ($LASTEXITCODE -eq 1 -and $out -match 'filler: "basically"' -and $out -match 'missing sections' -and $out -match '4 bullets')
  $out = 'updated stuff' | python -X utf8 $KT prose --kind commit - | Out-String
  Expect 'prose: a non-conventional commit subject is a finding' ($LASTEXITCODE -eq 1 -and $out -match 'conv')
  $wc = python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kittool as k; k.load_json = lambda p: ({'commitStyle': 'free'}, 0); print(k.words('日本 wörd ok'), k.commit_rx())"
  Expect 'prose: CJK per char, any script''s words; commitStyle free' ("$wc" -eq '4 \S')
  $rj = Join-Path $k 'results.json'; '{"checks":[{"id":"T1","note":"ok"},{"id":"T2","note":"' + ('word ' * 45) + '"}]}' | Set-Content $rj
  $out = python -X utf8 $KT prose --kind result-note $rj | Out-String
  Expect 'prose: a results.json note over 40 words is a finding' ($LASTEXITCODE -eq 1 -and $out -match '45 words')
  Push-Location $k; $null = python -X utf8 $KT lint --help; $h = $LASTEXITCODE; $null = python -X utf8 $KT flow --bogus 2>&1; $u = $LASTEXITCODE
  $null = python -X utf8 $KT lint (Join-Path $k 'skills') 2>&1; $nk = $LASTEXITCODE; Pop-Location
  Expect 'kittool: --help 0, writes nothing; bad flag / non-kit dir 2' ($h -eq 0 -and $u -eq 2 -and $nk -eq 2 -and -not (Test-Path (Join-Path $k '--help')))
  $eol = git -C $src check-attr eol -- .codex/config.toml .agents/hooks.json .codex/agents/x.toml .agents/workflows/x.md GEMINI.md
  Expect 'port: generated ports are eol=lf (an autocrlf clone shows no line-ending-only diffs)' (@($eol | Where-Object { $_ -match ': eol: lf$' }).Count -eq 5)
  # kittool internals (python)
  $ktt = @'
import importlib.util, json, os, sys, tempfile, tomllib
from pathlib import Path
spec = importlib.util.spec_from_file_location('kittool', sys.argv[1]); kt = importlib.util.module_from_spec(spec); spec.loader.exec_module(kt)
tmp = Path(tempfile.mkdtemp())
# TOML / YAML: a quote and a backslash in a description stay valid
kt.CODEX_AGENTS = tmp / 'c'; kt.GRAVITY_AGENTS = tmp / 'g'; kt.CODEX_AGENTS.mkdir(); kt.GRAVITY_AGENTS.mkdir()
d = 'say "hi" C:\\x'
kt.write_codex('a', {'description': d}, 'body'); kt.write_gravity('a', {'description': d}, 'body')
ok_toml = tomllib.loads((tmp / 'c' / 'a.toml').read_text(encoding='utf-8'))['description'] == d
ok_lf = b'\r\n' not in (tmp / 'c' / 'a.toml').read_bytes()
# port_deploy keeps user files, removes only stale generated ports
kit = tmp / 'ws' / '.claude'
for p in ('.codex/agents/a.toml', '.agents/agents/a.md', 'AGENTS.md', 'GEMINI.md'):
    (kit / p).parent.mkdir(parents=True, exist_ok=True); (kit / p).write_text('x', encoding='utf-8')
ws = kit.parent
for p in ('.codex/config.local.toml', '.codex/agents/old.toml', '.agents/agents/mine.txt'):
    (ws / p).parent.mkdir(parents=True, exist_ok=True); (ws / p).write_text('user', encoding='utf-8')
kt.KIT, kt.WORKSPACE = kit, ws
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    kt.port_deploy()
ok_deploy = (ws / '.codex/config.local.toml').exists() and (ws / '.agents/agents/mine.txt').exists() and not (ws / '.codex/agents/old.toml').exists() \
    and (ws / '.codex/agents/a.toml').read_text(encoding='utf-8') == 'x' and kt.deployed_stale() == []
# a linked worktree reads localOnly from the main clone; a non-repo folder is its own main clone
ok_main = kt.main_clone(str(tmp)) == str(tmp)
# lint measures PROSE against the linted kit's templates.md (k.dir), not the script's kit
src = open(sys.argv[1], encoding='utf-8').read()
ok_prose = 'writing_standards(k.dir)' in src and 'writing_standards(KIT)' not in src \
    and "kit_path('cache', create=True, kit=kit), osp.basename(loc_rel)" in src and "render timed out" in src
print(f'kittool-ports:{ok_toml and ok_lf}')
print(f'kittool-deploy:{ok_deploy}')
print(f'kittool-misc:{ok_main and ok_prose}')
'@
  $kf = Join-Path ([IO.Path]::GetTempPath()) "kt-test-$PID.py"; Set-Content $kf $ktt -Encoding utf8
  $res = @(& $py -X utf8 $kf (Join-Path $src 'skills/orchestrate/kittool.py') 2>&1); Remove-Item $kf -Force
  Expect-Each $res 'kittool: #' 'kittool-ports', 'kittool-deploy', 'kittool-misc'
  $j1 = pwsh @np $O board join -Type devy -Agent X7 -Run w7 -Items 'A1' -Claims 'C:/wt/x7' | Out-String
  $j2 = pwsh @np $O board join -Type revy -Agent R7 -Run w7 | Out-String
  $null = pwsh @np $O board msg -Agent R7 -To X7 -Text 'I need a.ts'
  $ib = pwsh @np $O board inbox -Agent X7 | Out-String
  $dp = pwsh @np $O board dispute -Agent X7 -With R7 -Item A1 -Claim 'no null check needed' -Evidence 'a.ts:3' -Propose 'drop it' | Out-String
  $did = if ($dp -match 'DISPUTE (p-\S+) open') { $Matches[1] }
  $null = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'b.ts:9'
  $null = pwsh @np $O board dispute -Id $did -Agent X7 -Claim 'b.ts is dead' -Evidence 'git grep: no caller'
  $esc = pwsh @np $O board dispute -Id $did -Agent R7 -Answer disagree -Evidence 'router.ts:12' | Out-String
  $dl = pwsh @np $O decide list -Pending | Out-String
  Expect 'board: join -Type shown; msg in inbox; dispute split after 2 rounds -> decision' ($j2 -match 'X7\s+devy' -and
    $ib -match 'from R7: I need a\.ts' -and $did -and $esc -match 'escalated: DECISION d-' -and $dl -match "Dispute $did")
  $dp2 = pwsh @np $O board dispute -Agent X7 -With R7 -Item A2 -Claim 'cache is safe' -Evidence 'c.ts:4' -Propose 'keep' | Out-String
  $did2 = if ($dp2 -match 'DISPUTE (p-\S+) open') { $Matches[1] }; $df2 = Join-Path (TkPath $k disputes) "$did2.json"
  (Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3)
  $ex = & { . $O; Invoke-DisputeExpiry } | Out-String
  (Get-Item $df2).LastWriteTime = (Get-Date).AddHours(-3); $ex2 = & { . $O; Invoke-DisputeExpiry } | Out-String
  Expect 'board: dispute silent 2 h escalates once (re-read under lock)' (-not $ex2.Trim() -and $ex -match "dispute $did2 .*escalated, DECISION d-" -and (Get-Content $df2 -Raw | ConvertFrom-Json).status -eq 'escalated' -and (pwsh @np $O decide list -Pending | Out-String) -match "Dispute $did2")
  $sd = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath qa-seats -Create) 'seats' }; New-Item -ItemType Directory -Force $sd | Out-Null
  '{"agent":"test:Q1","kind":"web","need":2,"since":"2026-10-16T10:00:00"}' | Set-Content "$sd/q1.json"
  '{"leases":{"devy-A1":{"services":["api"],"repos":[],"until":"2026-10-16T12:00:00"}}}' | Set-Content (Join-Path (& { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath localenv -Create }) 'shop.json')
  $bs = pwsh @np $O board show | Out-String
  Expect 'board show: lists QA seats and local-env leases' ($bs -match 'seat: test:Q1 web 2 GB' -and $bs -match 'lease: shop devy-A1 on api')
  $km = New-TestKit mig; $Om = Join-Path $km 'skills/orchestrate/orch.ps1'
  $oldWf = 'dev' + '-wave'; $oldSk = 'tech' + '-audit'   # built: no old name in the kit (lint OLD-NAME)
  $ldm = TkPath $km launches -Create
  [IO.File]::WriteAllText((Join-Path $ldm 'm1.json'), "{`"script`": `"C:/kit/workflows/$oldWf.js`", `"completed`": `"2026-10-16T10:00:00`"}")
  Add-Content (TkPath $km signals -Create) "{`"at`":`"2026-10-16T10:00:00`",`"skill`":`"$oldSk`",`"kind`":`"idea`",`"text`":`"x`"}" -Encoding utf8
  $oa = Join-Path (TkPath $km logs -Create) ('kit' + '-audits'); New-Item -ItemType Directory -Force $oa | Out-Null; 'r' | Set-Content "$oa/audit-1.md"
  '2026-10-01' | Set-Content (Join-Path $km ".state/$('kit' + '-audit').stamp")
  $hm = '{}' | pwsh @np $Om health 2>&1 | Out-String
  Expect 'health: state under a renamed name nudges setup -Migrate' ($hm -match 'renamed state under its old name')
  $mg = pwsh @np $Om setup -Migrate 2>&1 | Out-String
  Expect 'setup -Migrate: launch records, signals follow renames' ((Get-Content (Join-Path $ldm 'm1.json') -Raw) -match 'workflows/buildy\.js' -and
    (Get-Content (TkPath $km signals) -Raw) -match '"skill":"revy"')
  Expect 'setup -Migrate: renamed runtime / state paths move' (-not (Test-Path $oa) -and (Test-Path (Join-Path (TkPath $km kitty-audits) 'audit-1.md')) -and (Test-Path (TkPath $km last-kitty-audit)))
  Remove-TestKit $km
  $kc = Join-Path ([IO.Path]::GetTempPath()) "kit-reg-$PID\.claude"; New-Item -ItemType Directory -Force $kc | Out-Null
  foreach ($f in @(git -C $src ls-files) + @('agents/devy.md', 'agents/revy.md', 'agents/checky.md', 'agents/kitty.md')) { $s1 = Join-Path $src $f; if (Test-Path $s1) { $d = Join-Path $kc (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $s1 $d -Force } }
  git -C $kc init -q; git -C $kc add -A; git -C $kc -c user.name=t -c user.email=t@t commit -q -m 'feat: base'
  $KT2 = Join-Path $kc 'skills/orchestrate/kittool.py'
  $n1 = & $py -X utf8 $KT2 new agent zappy --skill dev-kit 2>&1 | Out-String
  $l1 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
  $mf = { (Get-Content (Join-Path $kc 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._manifest }
  $okNew = (Test-Path (Join-Path $kc 'agents/zappy.md')) -and (& $mf).agents.zappy -and (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -match '\| R\d+ \| TODO\(new\).*`zappy` agent' -and $l1 -match 'TODO-STUB'
  $tpl = Join-Path $kc 'skills/dev-kit/templates.md'; Add-Content $tpl "`nsee last-zappys and zappy-stamp" -Encoding utf8
  $r1 = & $py -X utf8 $KT2 rename agent zappy zippy 2>&1 | Out-String
  $okRen = (Test-Path (Join-Path $kc 'agents/zippy.md')) -and -not (Test-Path (Join-Path $kc 'agents/zappy.md')) -and (& $mf).renamed.zappy -eq 'zippy' -and
    (Get-Content $tpl -Raw) -match 'see last-zippys and zippy-stamp' -and
    (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -match '`zippy` agent' -and (Test-Path (Join-Path $kc '.codex/agents/zippy.toml')) -and -not (Test-Path (Join-Path $kc '.codex/agents/zappy.toml'))
  $x1 = & $py -X utf8 $KT2 remove agent zippy 2>&1 | Out-String
  $okRem = -not (Test-Path (Join-Path $kc 'agents/zippy.md')) -and -not (& $mf).agents.zippy -and (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -notmatch 'zippy'
  $klj = Join-Path $kc 'skills/dev-kit/kit.local.json'; '{ "net": { "timeoutSec": 5 } }' | Set-Content $klj -Encoding utf8
  $null = & $py -X utf8 $KT2 rename event E14 E15 2>&1; $rnw = & $py -X utf8 $KT2 rename config-key net.timeoutSec net.waitSec 2>&1 | Out-String
  $null = & $py -X utf8 $KT2 new adr Budget per agent 2>&1
  $sk = Get-Content (Join-Path $kc 'skills/orchestrate/SKILL.md') -Raw
  $okId = $rnw -match 'WARN nested read\? skills/local-env/localenv\.ps1' -and (& $mf).events -contains 'E15' -and -not ((& $mf).events -contains 'E14') -and $sk -match '\|\s*E15\s*\|' -and $sk -notmatch '\bE14\b' -and
    (Get-Content (Join-Path $kc 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json).net.waitSec -eq 60 -and (Get-Content $klj -Raw | ConvertFrom-Json).net.waitSec -eq 5 -and
    -not (git -C $kc grep -l 'net\.timeoutSec' -- . ':!.codex' ':!.agents') -and (Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -match '## Decisions\r?\n(?:.*\r?\n)*- \d{4}-\d\d-\d\d Budget per agent: context TODO\(new\)'
  Expect "kittool rename event + config-key, new adr ($okId)" $okId
  $wfp = Join-Path $kc 'workflows/tidy.js'; Add-Content $wfp "`nawait agent('x', { label: 'gp' })" -Encoding utf8; Add-Content (Join-Path $kc 'README.md') "`nsee $oldWf" -Encoding utf8; Add-Content (Join-Path $kc 'skills/dev-kit/templates.md') "`nsee last-${oldSk}s" -Encoding utf8
  $l2 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
  $rel = & $py -X utf8 $KT2 release 2>&1 | Out-String
  Expect "kittool new / rename / remove (new $okNew, rename $okRen, remove $okRem)" ($okNew -and $okRen -and $okRem)
  Expect 'kittool lint: AGENT-TYPE, OLD-NAME (also last-<old>s); release: SemVer tag' ($l2 -match 'AGENT-TYPE\s+workflows/tidy\.js' -and $l2 -match "OLD-NAME\s+README\.md.*$oldWf" -and $l2 -match "OLD-NAME\s+skills/dev-kit/templates\.md.*$oldSk" -and $rel -match '^# v\d+\.\d+\.\d+')
  $bj = Join-Path $kc 'skills/dev-kit/kit.example.json'; $bt = { & $py -X utf8 $KT2 budget raise -Reason x 2>&1 | Out-String }
  $b1 = & $bt; $c1 = $LASTEXITCODE
  foreach ($p in $bj, $KT2) { (Get-Content $p -Raw) -replace '(totalTokens[''"]:\s*)\d+', '${1}360000' | Set-Content $p -NoNewline }; git -C $kc commit -qam cap
  $b2 = & $bt; $c2 = (Get-Content $bj -Raw) -match '"totalTokens": 396000'
  (Get-Content $bj -Raw) -replace '"totalTokens": \d+', '"totalTokens": 999000' | Set-Content $bj -NoNewline; $l3 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
  Expect 'budget raise: refused under the cap, x1.1 over it; a manual cap edit = BUDGET-CAP' ($c1 -eq 1 -and $b1 -match 'fits the cap' -and $b2 -match '360000 -> 396000' -and $c2 -and $l3 -match 'BUDGET-CAP')
  Remove-Item (Split-Path $kc) -Recurse -Force -ErrorAction SilentlyContinue
  $bj = { param([string[]]$a) Px $O budget @a -Json | ConvertFrom-Json }
  $cx = Join-Path (Kd) 'codex'; New-Item -ItemType Directory -Force $cx | Out-Null
  '{"models":[{"slug":"gpt-5.5","context_window":272000,"effective_context_window_percent":95}]}' | Set-Content "$cx/models_cache.json"; 'model = "gpt-5.5"' | Set-Content "$cx/config.toml"
  $b1 = & $bj '-Tool', 'claude', '-Model', 'claude-opus-5-5'; $b2 = & $bj '-Tool', 'claude', '-Model', 'claude-sonnet-4-6'; $b5 = & $bj '-Tool', 'unknown'
  $env:CODEX_HOME = $cx; $b3 = & $bj '-Tool', 'codex'; "model = ""gpt-5.5""`nmodel_auto_compact_token_limit = 200000" | Set-Content "$cx/config.toml"; $b4 = & $bj '-Tool', 'codex'; Remove-Item Env:CODEX_HOME
  $bp = & $bj '-Tool', 'claude', '-Plan', 'devy/claude-opus-5-5:1,revy/claude-sonnet-4-6:1'
  Expect "budget: per-tool defaults and the plan cap (sum)" ("$($b1.budget)/$($b1.handoff) $($b2.budget)/$($b2.handoff) $($b3.budget)/$($b3.handoff) $($b4.budget)/$($b4.handoff) $($b5.budget)/$($b5.handoff) $($bp.cap)" -eq '967000/773600 167000/133600 232560/186048 200000/160000 160000/128000 1134000')
  $env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx'; New-Item -ItemType Directory -Force $env:KIT_TRANSCRIPTS | Out-Null
  $hj = pwsh @np $O board join -Agent H1 -Run hr -Model claude-opus-5-5 | Out-String; $ht = if ($hj -match 'SESSION (\S+)') { $Matches[1] }
  @("{""type"":""user"",""text"":""SESSION $ht""}", '{"message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":799999,"output_tokens":0}}}') | Set-Content (Join-Path $env:KIT_TRANSCRIPTS 'agent-h1.jsonl')
  $hb = Px $O board beat -Session $ht | Out-String; $hf = if ($hb -match 'leave -Session \S+ -Handoff (\S+),') { $Matches[1] }
  $null = Px $O board leave -Session $ht -Handoff $hf; $hr = Px $O recover | Out-String
  $h2 = Px $O board join -Agent H1 -Run hr | Out-String; Remove-Item Env:KIT_TRANSCRIPTS
  Expect 'budget: join shows it, a beat at 80% = HANDOFF, recover lists the brief, a fresh join continues' ($hj -match 'budget: claude claude-opus-5-5 967000 tokens, handoff at 773600' -and $hb -match 'HANDOFF: spend 800000 >= 773600' -and $hf -and $hr -match "== HANDOFF H1 \(hr\).*$([regex]::Escape($hf))" -and $h2 -match "CONTINUE: .*$([regex]::Escape($hf))" -and $h2 -notmatch 'DUPLICATE')
  $rd = @{ agents = @(@{ type = 'checky'; name = 'W1'; mode = 'test'; spend = 50000; prevSpend = 30000 }, @{ type = 'checky'; name = 'J1'; mode = 'env-fix'; wait = $true }, @{ type = 'devy'; name = 'P1'; mode = 'build'; spend = 10000; prevSpend = 0 })
    mem = @{ TotalGB = 64; AvailGB = 16 }; ram = @{ kit = 5; browsers = 4; apps = 3; servers = 1; vms = 2; windows = 13; unknown = 20 }; unknown = @('foo 0.6'); top = @(@{ name = 'Teams'; gb = 2.4; mark = '💤' }); keepFree = 8; avgFree = 15; disk = 'D: 100 GB free'; info = @('deploy ready: stage (2 MR(s))')
    resources = @(@{ name = '🟢 rm · api'; type = 'local env'; by = 'W1'; gb = 3 }, @{ name = '🌐 rm·acme·admin'; type = 'test browser'; by = 'W1'; gb = 2 }, @{ name = '🔴 hm · api'; type = 'local env'; by = 'down: memory'; gb = 0 })
    flags = @(@{ level = 'ASK'; what = 'Teams 2.4 GB 💤 — close it?'; action = 'ask' }, @{ level = 'ACT'; what = 'ENV-FIX e-1 waiting 240 min'; action = 'fix it' }); detailFile = 'r.md' }
  $r1 = (& { . $O; Format-KitReport $rd -Width 160 -Agents }) -join "`n"; $rd.mem.AvailGB = 6; $r2 = (& { . $O; Format-KitReport $rd -Ascii -Width 80 }) -join "`n"
  $want1 = @('| Agent | Doing |', '|---|---|', '| 🛠️ 1 × devy (+10kT) | build 1 (P1) |', '| 🧪 2 × checky (+20kT) | ⏸ env-fix 1 (J1) · test 1 (W1) |', '',
    "🖥️ **RAM** $('🟦' * 2)🟨🟧🟪$('🟫' * 4)$('⬛' * 6)$('⬜' * 5) **48 / 64 GB**", '🟦 Kit 5 · 🟨 Your browsers 4 · 🟧 Your apps 3 · 🟩 Servers 1', '🟪 WSL 2 · 🟫 Windows 13 · ⬛ Unknown 20 (foo 0.6) · ⬜ Free 16 · 🛡️ Floor 8', 'top apps: Teams 2.4 💤 (💤 idle · 📈 +1 GB)', '',
    '| Resource | Used by | RAM | Resource | Used by | RAM |', '|---|---|---|---|---|---|', '| 🟢 rm · api | W1 | 3 | 🔴 hm · api | down: memory | — |', '| 🌐 rm·acme·admin | W1 | 2 |  | |  |', '',
    '🚩 **Flags**', '- **ACT** ENV-FIX e-1 waiting 240 min -> fix it', '- ❓ **ASK** · Teams 2.4 GB 💤 — close it? -> ask', '- **INFO** deploy ready: stage (2 MR(s))') -join "`n"
  Expect 'supervise report snapshot (-Agents, wide)' ($r1 -eq $want1)
  Expect 'supervise report: below the floor red, -Ascii, narrow, no agents by default' ($r2 -match '\*\*RAM\*\* \[KKBBAVW{5}U{7}\.\.\] \*\*58 / 64 GB\*\*' -and $r2 -match '\| Resource \| Used by \| RAM \|\r?\n\|---\|---\|---\|\r?\n\| rm - api \| W1 \| 3 \|' -and (& { . $O; Format-KitReport $rd }) -join '' -match '(🟥){2}' -and ((& { . $O; Format-KitReport $rd }) -join '') -notmatch 'Agent')
  $an = & { . $O; $n = Get-Date; $c = @{ usedGB = 40; cpu = 95; runs = @(@{ id = 'wf1'; at = $n.AddMinutes(-25).ToString('o'); path = 'j.jsonl' }); trains = @(@{ env = 'shop'; key = 't1 build' })
      logs = @(@{ path = 'api.log'; errors = 2; first = 'ERROR boom' }); restarts = @(@{ env = 'shop'; svc = 'api'; n = 3 }); outbox = 4; toolErrors = 2; errorRun = 'wf1'; lint = '2 problem(s)'
      adopted = @(@{ env = 'shop'; svc = 'web'; port = 4200 }); stray = @('junk.txt') }
    $p = @{ usedGB = 36; outbox = 1; toolErrors = 1; cpuHighSince = $n.AddMinutes(-11).ToString('o'); trains = @{ shop = @{ key = 't1 build'; since = $n.AddMinutes(-21).ToString('o') } } }
    "$((Get-KitAnomalies $c $p $n).flags.what -join "`n")`n$((Get-KitAnomalies @{ usedGB = 1; cpu = 5 } @{} $n).flags.Count)" }
  $want = 'STALL: run wf1', 'STALL: shop train', 'ERROR SPIKE: 2', 'RESTART LOOP: shop api', 'RAM \+4', 'CPU 95%', 'outbox grew to 4', '1 new agent', 'main lint red', 'shop web port 4200', 'UNKNOWN: junk.txt', '\n0$'
  Expect "supervise anomalies: every flag from its fixture, none on a quiet round" (-not @($want | Where-Object { $an -notmatch $_ }).Count)
  $lg = Join-Path (Split-Path $k) 'an.log'; 'ok' | Set-Content $lg; $s1 = @(& { . $O; Get-KitLogErrors @($lg) @{} }); Add-Content $lg "ERROR one`nTraceback (most recent call last)`nfine"
  $s2 = @(& { . $O; Get-KitLogErrors @($lg) @{ (Resolve-Path $lg).Path = $s1[0].size } })
  $oc = & { . $O; $o = (Get-Date).AddMinutes(-40); $mk = { param($i, $pp, $n, $c) [pscustomobject]@{ Id = $i; ParentId = $pp; Name = $n; Cpu = $c; Created = $o } }
    $pr = @((& $mk 10 1 'cmd.exe' 1), (& $mk 11 10 'conhost.exe' 1), (& $mk 12 99 'pwsh.exe' 5), (& $mk 13 98 'pwsh.exe' 1), (& $mk 14 97 'python.exe' 1), (& $mk 99 0 'x' 1), (& $mk 98 0 'claude' 1), (& $mk 97 0 'y' 1))
    @(Get-KitOrphanConsoles $pr @{ 10 = 1; 11 = 1; 12 = 1; 13 = 1 } @{ '10' = 1; '11' = 1; '12' = 1; '13' = 1; '14' = 1 } 10 @{ 13 = 1 }).Id -join ',' }
  Expect "supervise: orphan kit consoles = parent gone / idle, never busy, tool-shell or owner ones ($oc)" ($oc -eq '10')
  Expect 'supervise anomalies: only new log error lines count' ($s1[0].errors -eq 0 -and $s2[0].errors -eq 2)
  $wsim = @'
import { readFileSync } from 'node:fs'
const mk = (out, spent, handoff) => { const calls = []; return { calls, agent: async (p, o) => { calls.push({ label: o.label, prompt: p })
  if (/^record-args/.test(o.label)) return { ok: true, output: `RECORDED x\nBUDGET ${out}` }
  if (o.label === 'budget') return { ok: true, output: JSON.stringify({ spent }) }
  if (/^(build|handoff):/.test(o.label)) return { mrs: [], worktrees: [], done: ['A1'], deferred: [], needsDecision: [], needsEnvFix: [], localTest: { status: 'PASS', env: 'e', rounds: 1, failing: [], goalsDoc: 'g' }, needsLiveCheck: [], seed: [], foreignHooks: [], summary: 's', testerGuide: 'd', handoff: o.label.startsWith('build') ? handoff : '' }
  if (/^(test|handoff|retest)/.test(o.label)) return { code: o.label.split(':')[1], checks: [{ id: 'C1', subtask_id: 't', screen: 's', result: 'PASS', what_was_done: 'x', observed: 'y', evidence: [], attempts: 1 }], findings: [], setup_changes: [], data_created: [], handoff: '' }
  return { ok: true, output: '[]', signals: 0, lessonsChanged: [], json: '' } } } }
const pipeline = async (items, ...st) => Promise.all(items.map(async (a) => { let x = await st[0](a); for (const s of st.slice(1)) x = await s(x, a); return x }))
const run = (src, args, m) => new Function('args', 'agent', 'pipeline', 'parallel', 'log', 'phase', `return (async () => {\n${src}\n})()`)(args, m.agent, pipeline, async (f) => Promise.all(f.map((g) => g())), () => {}, () => {})
const B = readFileSync(process.argv[2], 'utf8'), T = readFileSync(process.argv[3], 'utf8')
const ba = { brief: 'C:/b/w.md', agents: [{ id: 'X1', items: 'A1' }, { id: 'X2', items: 'A2' }], mandate: ['m'], kitDir: 'C:/kit', learn: false }
const m1 = mk('{"cap":100000,"estimate":500000,"stopAt":0.8}'); const o1 = await run(B, ba, m1)
console.log(`refuse:${o1.refused === true && o1.batch === 1 && o1.next.args.batch === 1 && !m1.calls.some((c) => /^build:/.test(c.label))}`)
const m2 = mk('{"cap":10000000,"estimate":100000,"stopAt":0.8}', 0, 'C:/b/handoff-X1.md'); const o2 = await run(B, { ...ba, agents: [ba.agents[0]] }, m2)
console.log(`handoff:${m2.calls.some((c) => c.label === 'handoff:X1' && /resume brief C:\/b\/handoff-X1\.md/.test(c.prompt)) && !o2.next}`)
const items = ['W1', 'W2', 'W3'].map((c) => ({ code: c, title: c, guideFile: 'g', lane: 'web', subtasks: [{ id: 't' }], skipClose: true }))
const m3 = mk('{"cap":1000000,"estimate":750000,"stopAt":0.8}', 900000); const o3 = await run(T, { runDir: 'C:/r/run1', kitDir: 'C:/kit', items, webParallel: 1, mandate: ['m'], learn: false, verify: false }, m3)
console.log(`stop-next:${o3.next && o3.next.args.only.join(',') === 'W2,W3' && m3.calls.some((c) => c.label === 'budget') && !m3.calls.some((c) => c.label === 'test:W2')}`)
'@
  $wsf = Join-Path (Kd) 'wf-budget.mjs'; [IO.File]::WriteAllText($wsf, $wsim)
  $strip = { param($n) [IO.File]::ReadAllText((Join-Path $src "workflows/$n")) -replace '(?m)^export const meta', 'const meta' }
  $bsf = Join-Path (Kd) 'b.js'; $tsf = Join-Path (Kd) 't.js'; [IO.File]::WriteAllText($bsf, (& $strip 'buildy.js')); [IO.File]::WriteAllText($tsf, (& $strip 'testy.js'))
  $res = @(node $wsf $bsf $tsf 2>&1)
  foreach ($x in 'refuse', 'handoff', 'stop-next') { Expect "workflow budget: $x" (@($res) -contains "${x}:true") }
  if (@($res | Where-Object { "$_" -match ':true$' }).Count -ne 3) { $res | Select-Object -First 5 }
  Remove-TestKit $k
}

# === local: LIGHT/HEAVY migration wiring, devtools.py migrations
if ($Area -in 'local', 'all') {
  "== local"
  $k = New-TestKit local; $L = Join-Path $k 'skills/local-env/localenv.ps1'
  $t = @'
$ErrorActionPreference = 'Stop'
. $args[0]
$tmp = $args[1]; New-Item -ItemType Directory -Force $tmp | Out-Null
$repo = Join-Path $tmp 'repo'; $cl = 'api/src/main/resources/config/liquibase/changelog'
git init -q -b main $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
$x = { param($body) "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<databaseChangeLog xmlns=`"http://www.liquibase.org/xml/ns/dbchangelog`">`n$body</databaseChangeLog>`n" }
$put = { param($rel, $text) $p = Join-Path $repo $rel; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; [IO.File]::WriteAllText($p, $text) }
& $put "$cl/20260101000000_base.xml" (& $x '<changeSet id="b-1" author="dev"><createTable tableName="orders"><column name="id" type="BIGINT"/></createTable></changeSet>')
git -C $repo add -A; git -C $repo commit -q -m base; git -C $repo update-ref refs/remotes/origin/main main
$branch = { param($name, $file, $body) git -C $repo checkout -q -b $name main; & $put "$cl/$file" (& $x $body); git -C $repo add -A; git -C $repo commit -q -m $name; $s = "$(git -C $repo rev-parse HEAD)".Trim(); git -C $repo checkout -q main; $s }
$light = & $branch 'light' '20260201000000_light.xml' ('<changeSet id="l-0" author="dev"><tagDatabase tag="l"/></changeSet>' +
  '<changeSet id="l-1" author="dev"><addColumn tableName="orders"><column name="note" type="VARCHAR(80)"/></addColumn><rollback><dropColumn tableName="orders" columnName="note"/></rollback></changeSet>' +
  '<changeSet id="l-2" author="dev"><createTable tableName="order_status"><column name="id" type="INT"/></createTable></changeSet>')
$heavy = & $branch 'heavy' '20260301000000_heavy.xml' '<changeSet id="h-1" author="dev"><dropColumn tableName="orders" columnName="id"/><rollback><addColumn tableName="orders"><column name="id" type="BIGINT"/></addColumn></rollback></changeSet>'
$fake = Join-Path $tmp 'fake-db.ps1'
Set-Content $fake @"
param([string]`$Action, [string]`$Manifest, [string]`$SearchPath, [string]`$Changelog, [int]`$Count, [string]`$Branch, [string]`$Out)
if (`$Action -eq 'rollback') { "`$Count|`$Branch|`$Changelog|`$(Test-Path (Join-Path `$SearchPath `$Changelog))" | Set-Content `$Out; exit 0 }
if (`$Action -eq 'applied' -and (Test-Path "`$Out.still")) { (Get-Content `$Manifest -Raw | ConvertFrom-Json).revert | ForEach-Object { "schema1 `$(`$_.file)::`$(`$_.id)::`$(`$_.author)" } }
"@
$outF = Join-Path $tmp 'rollback.out'; $hook = "pwsh -NoProfile -File `"$fake`" -Out `"$outF`""
$script:LE = [pscustomobject]@{ envs = [pscustomobject]@{ t = [pscustomobject]@{ services = @(); db = [pscustomobject]@{
  rollback = "$hook -Action rollback -Manifest `"{manifest}`" -SearchPath `"{searchPath}`" -Changelog {changelog} -Count {count} -Branch {branch}"
  applied = "$hook -Action applied -Manifest `"{manifest}`"" } } } }
$r = [pscustomobject]@{ name = 'api'; cfg = [pscustomobject]@{ checkout = $repo }; target = 'main' }
$mc = Get-MigClass 't' $r $light; "light:$($mc.effective -eq 'light' -and $mc.count -eq 3)"
$mh = Get-MigClass 't' $r $heavy; "heavy:$($mh.effective -eq 'heavy' -and "$($mh.why)" -match 'h-1 drop-data')"
$layer = @{ branch = 'light'; sha = $light; migrations = $true; mclass = $mc }
$p = Get-MigRevertPlan 't' 'api' @($layer) @() '' 'test1'; "plan:$($p.count -eq 3 -and (@($p.revert.id) -join ',') -eq 'l-2,l-1,l-0')"
"revert:$($null -eq (Invoke-MigRevertPlan 't' $p) -and (Get-Content $outF) -eq '3|light|localenv-revert.xml|True')"
New-Item -ItemType File "$outF.still" | Out-Null; "applied:$("$(Invoke-MigRevertPlan 't' $p)" -match 'still lists')"
$script:LE.envs.t.db = [pscustomobject]@{}; $m2 = Get-MigClass 't' $r $light; "nohook:$($m2.class -eq 'light' -and $m2.effective -eq 'heavy')"
git -C $repo checkout -q -b tool main; & $put 'db/m/00002_b.sql' "-- +goose Up`nCREATE TABLE b (id INT);`n-- +goose Down`nDROP TABLE b;`n"; git -C $repo add -A; git -C $repo commit -q -m tool; $tl = "$(git -C $repo rev-parse HEAD)".Trim(); git -C $repo checkout -q main
$mt = Get-MigClass 't' $r $tl; $pt = Get-MigRevertPlan 't' 'api' @(@{ branch = 'tool'; sha = $tl; migrations = $true; mclass = $mt }) @() '' 'test2'; "tool:$($mt.effective -eq 'light' -and $pt.cmd -match 'goose -dir ""db/m"" down-to 0$')"
"missing-sha:$(HasMigrations $repo 'main' 'deadbeef')"
Remove-Item (MigRoot 't') -Recurse -Force -ErrorAction SilentlyContinue
'@
  $f = Join-Path (Kd) 'revert-test.ps1'; Set-Content $f $t
  $res = @(Px $f $L (Join-Path (Kd) 'le') 2>&1)
  foreach ($x in 'light', 'heavy', 'plan', 'revert', 'applied', 'nohook', 'tool', 'missing-sha') { Expect "local env: $x" ($res -contains "${x}:True") }
  $out = & $py -X utf8 (Join-Path $k 'skills/dev-kit/devtools.py') migrations selftest 2>&1 | Out-String
  Expect 'devtools.py migrations selftest' ($LASTEXITCODE -eq 0)
  # localenv usage errors exit 2; a start-lock timeout throws, never runs unlocked
  $k2 = New-TestKit le2; $L2 = Join-Path $k2 'skills/local-env/localenv.ps1'
  @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ engine = 'postgres'; name = 'shop'; user = 'u' } } } } } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $k2 'skills/dev-kit/kit.local.json')
  Expect 'localenv: db.engine presets fill unset hooks' ((& { . $L2; $script:LE.envs.shop.db.snapshot }) -match '^pg_dump -Fc -h 127\.0\.0\.1 -p 5432 -U u -f .+\.dump\" shop$')
  $null = Px $L2 bogus 2>&1; $c1 = $LASTEXITCODE
  $null = Px $L2 status -Env nope 2>&1; $c2 = $LASTEXITCODE
  $null = Px $L2 drop -Env shop 2>&1; $c3 = $LASTEXITCODE
  $pr = & { . $L2; $o = (Get-Date).AddMinutes(-11).ToString('o'); $u = (Get-Date).AddHours(1).ToString('o')
    $st = @{ leases = @{ dead = @{ until = $u; holderPid = 999999; seen = $o }; grace = @{ until = $u; holderPid = 999999; seen = (Get-Date).AddMinutes(-3).ToString('o') }; live = @{ until = $u; holderPid = $PID } }
      holds = @{ own = @{ owner = $true; until = (Get-Date).AddMinutes(5).ToString('o') }; old = @{ owner = $true; until = $o }; co = @{ agent = 'main'; seen = $o } }; requests = @() }
    Prune $st; "$(($st.leases.Keys | Sort-Object) -join ',')|$(($st.holds.Keys | Sort-Object) -join ',')|$($st.leases.grace.graceLeft)" }
  Expect "leases: no live holder -> kept for the grace, then gone; owner holds keep their minutes; a coordinator hold needs a heartbeat ($pr)" ($pr -eq 'grace,live|own|7')
  $lv = & { . $L2; $b = Get-KitPath board -Create; @{ agent = 'B1'; session = 'B1-s'; status = 'working'; beat = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content "$b/B1-s.json"
    @{ at = (Get-Date).ToString('o'); running = @('build:R1'); labels = @('build:R1', 'local:X1') } | ConvertTo-Json | Set-Content (Get-KitPath live-steps -Create)
    "$(Test-KitLive @{ session = 'B1-s'; holderPid = 999999 })$(Test-KitLive @{ agent = 'R1' })$(Test-KitLive @{ agent = 'X1'; holderPid = $PID })" }
  Expect "leases: live by a board beat or a running workflow step; a finished step is not ($lv)" ($lv -eq 'TrueTrueFalse')
  $lf = & { . (Join-Path $k2 'skills/dev-kit/lib.ps1'); Join-Path (Get-KitPath localenv -Create) 'shop.json' }; '{"holds":{"main":{"services":["api"],"agent":"main"}}}' | Set-Content $lf
  $u1 = Px $L2 up -Env shop 2>&1 | Out-String; $c4 = $LASTEXITCODE; $null = Px $L2 unhold -Env shop -Agent main 2>&1
  Expect "localenv: up refuses without -Services; unhold ends a hold" ($c4 -eq 1 -and $u1 -match 'up needs -Services' -and -not @((Get-Content $lf -Raw | ConvertFrom-Json).holds.PSObject.Properties).Count)
  Expect 'localenv: usage errors exit 2; a start-lock timeout throws' ($c1 -eq 2 -and $c2 -eq 2 -and $c3 -eq 2 -and (Get-Content $L2 -Raw) -match 'if \(-not \$got\) \{ \$mx\.Dispose\(\); throw')
  Remove-TestKit $k2
  # swarm: -Reverse 8080,8081 = 2 ports, whole lease; release holds '__stopping__' until down ends; ios serial = udid; avd; build command
  $swt = @'
$ErrorActionPreference = 'Stop'
$tmp = $args[1]; New-Item -ItemType Directory -Force $tmp | Out-Null; Set-Item Env:CLAUDE_RUNTIME "$tmp/rt"; . $args[0]
$adb = "$tmp/adb.cmd"; Set-Content $adb "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& echo emulator-5560	device)`r`nexit /b 0" -Encoding ascii
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'L1'; port = 5560 }); adb = $adb; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
$P = Get-KitPath phones -Create; $lf = "$P/L1.json"
@{ agent = 'B'; lane = 'L1'; serial = 'emulator-5560'; since = (Get-Date).AddMinutes(-20).ToString('s'); seen = (Get-Date).AddMinutes(-11).ToString('o'); holderPid = 999999 } | ConvertTo-Json | Set-Content $lf
$rc = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A') *>&1 | Out-String
"reclaim:$($rc -match 'reclaimed L1 from B' -and (Get-Content $lf -Raw | ConvertFrom-Json).agent -eq 'A')"
@{ agent = 'A'; lane = 'L1'; serial = 'emulator-5560'; since = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $lf
$j = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A', '-Reverse', '8080,8081') | Select-Object -Last 1 | ConvertFrom-Json
"reverse:$((@($j.reverse) -join ',') -eq '8080,8081' -and (@((Get-Content $lf -Raw | ConvertFrom-Json).reverse) -join ',') -eq '8080,8081' -and -not @(Get-ChildItem $P -Filter '*.tmp').Count)"
Set-Content "$tmp/d.ps1" "(Get-Content '$lf' -Raw | ConvertFrom-Json).agent > '$tmp/during.txt'"; $KitCmd.swarm = "$tmp/d.ps1"
$null = Invoke-KitVerb Invoke-Phone @('release', '-Agent', 'A')
"release:$((Get-Content "$tmp/during.txt" -Raw).Trim() -eq '__stopping__' -and -not (Test-Path $lf))"
Set-Content "$tmp/xcrun.cmd" "@echo off`r`necho iPhone (U1) (Booted)" -Encoding ascii; $env:PATH = "$tmp;$env:PATH"
$script:SwarmCfg = [pscustomobject]@{ kind = 'ios'; lanes = @([pscustomobject]@{ name = 'I1'; udid = 'U1' }); apkDir = $tmp; app = [pscustomobject]@{ package = 'x' } }
$j = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'B', '-Reverse', '8080') | Select-Object -Last 1 | ConvertFrom-Json
$s = "$tmp/sdk"; New-Item -ItemType Directory -Force "$s/platform-tools", "$s/system-images/a35/g/arm64-v8a", "$tmp/a" | Out-Null; Copy-Item $adb "$s/platform-tools"
$script:SwarmCfg = [pscustomobject]@{ lanes = @([pscustomobject]@{ name = 'A1'; port = 5570 }); adb = "$s/platform-tools/adb.cmd"; avdDir = "$tmp/avd"; apkDir = $tmp; out = $tmp; appFile = "$tmp/app.apk"
  avd = [pscustomobject]@{ abi = 'arm64-v8a'; api = 'a35'; device = 'p8'; tag = 'g' }; app = [pscustomobject]@{ buildTask = 'b'; appDir = "$tmp/a"; buildCmd = 'fb'; artifact = 'o/*.apk' } }
$null = Invoke-KitVerb Invoke-Avd @('create', '-Lanes', 'A1', '-NoBoot'); $ini = Get-Content "$tmp/avd/A1.avd/config.ini" -Raw
Set-Content "$tmp/gate.ps1" 'param($v, $Dir, $Cmd, $WaitMinutes) New-Item -ItemType Directory -Force "$Dir/o" | Out-Null; Set-Content "$Dir/o/x.apk" $Cmd'; $KitCmd.dev = "$tmp/gate.ps1"
git -C "$tmp/a" init -q; git -C "$tmp/a" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i; $null = Invoke-KitVerb Invoke-Build @('-NoUpdate')
"kinds:$($j.serial -eq 'U1' -and -not @($j.reverse).Count) $($ini -match 'arch=arm64\s[\s\S]*a35\\g\\arm64-v8a' -and $ini -match 'PlayStore.enabled=false') $((Get-Content "$tmp/app.apk" -Raw) -match 'fb')"
'@
  $sf = "$([IO.Path]::GetTempPath())swarm-test-$PID"; Set-Content "$sf.ps1" $swt
  $res = @(Px "$sf.ps1" (Join-Path $src 'skills/android-swarm/swarm.ps1') $sf 2>&1)
  foreach ($x in 'reclaim:True', 'reverse:True', 'release:True', 'kinds:True True True') { Expect "swarm: $x" ($res -contains $x) }
  Remove-Item "$sf.ps1", $sf -Recurse -Force -ErrorAction SilentlyContinue
  # lanes 0..N on demand: 3 requests, RAM for 2 boots: 2 boot, the 3rd waits, takes lane 1 when A releases it; no 3rd emulator ever starts
  $lsc = @'
$tmp = $args[1]; Set-Item Env:CLAUDE_RUNTIME "$tmp/rt"; . $args[0]
$dev = Join-Path $tmp 'devices.txt'; $adb = Join-Path $tmp 'adb.cmd'
Set-Content $adb "@echo off`r`nif `"%1`"==`"devices`" (echo List of devices attached& type `"$dev`" 2>nul)`r`nexit /b 0" -Encoding ascii
$script:SwarmCfg = [pscustomobject]@{ lanes = @(1..3 | ForEach-Object { [pscustomobject]@{ name = "L$_"; port = 5560 + 2 * $_ } }); adb = $adb; app = [pscustomobject]@{ package = 'x'; localReverse = @(); permissions = @() }; apkDir = $tmp; out = $tmp }
Set-Content "$tmp/mock.ps1" @"
param([Parameter(Position = 0)]`$Verb, `$Lanes, `$Mode, [switch]`$ColdBoot, [switch]`$KeepBrowsers)
`$port = 5560 + 2 * [int]("`$Lanes" -replace '\D')
if (`$Verb -eq 'up') { if (Test-Path '$tmp/full') { Start-Sleep 2; Write-Warning "`$Lanes not started: no memory turn"; return }; Add-Content '$dev' "emulator-`$port``tdevice"; Add-Content '$tmp/boots.txt' `$Lanes }
if (`$Verb -eq 'down') { Set-Content '$dev' @(Get-Content '$dev' | Where-Object { `$_ -notmatch "-`$port\s" }) }
"@
$KitCmd.swarm = "$tmp/mock.ps1"
if ($args[2] -eq 'C') { Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'C', '-NoInstall', '-WaitMinutes', '2') | Select-Object -Last 1; return }
New-Item -ItemType File -Force $dev | Out-Null
$a = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'A', '-NoInstall') | Select-Object -Last 1 | ConvertFrom-Json
$b = Invoke-KitVerb Invoke-Phone @('acquire', '-Agent', 'B', '-NoInstall') | Select-Object -Last 1 | ConvertFrom-Json
New-Item -ItemType File "$tmp/full" | Out-Null
$cp = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $PSCommandPath, $args[0], $tmp, 'C' -PassThru -WindowStyle Hidden -RedirectStandardOutput "$tmp/c.out"
for ($i = 0; $i -lt 60 -and -not (Test-Path (Join-Path (Get-KitPath phones) 'L3.json')); $i++) { Start-Sleep -Milliseconds 500 }
$null = Invoke-KitVerb Invoke-Phone @('release', '-Agent', 'A'); $null = $cp.WaitForExit(120000)
$cj = @(Get-Content "$tmp/c.out" | Where-Object { $_ -match '^\{' })[-1] | ConvertFrom-Json
"scale:$($a.lane -eq 'L1' -and $b.lane -eq 'L2' -and $cj.lane -eq 'L1' -and (@(Get-Content "$tmp/boots.txt") -join ',') -eq 'L1,L2')"
'@
  $lf2 = "$([IO.Path]::GetTempPath())lanes-test-$PID"; New-Item -ItemType Directory -Force $lf2 | Out-Null; Set-Content "$lf2.ps1" $lsc
  $res = @(Px "$lf2.ps1" (Join-Path $src 'skills/android-swarm/swarm.ps1') $lf2 2>&1)
  Expect "swarm: lanes on demand, a waiting request takes a lane freed meanwhile, no extra boot ($(@($res | Where-Object { "$_" -match '^scale:' })))" ($res -contains 'scale:True')
  Remove-Item "$lf2.ps1", $lf2 -Recurse -Force -ErrorAction SilentlyContinue
  Remove-TestKit $k
}

  # kit-flow: loop words in strings / comments / one-liners are no loops; unbounded ones are (kittool.py 2b)
  $fx = @'
import re, sys, types, collections
sys.path.insert(0, sys.argv[1])
import kittool
T = {'fp.ps1': '''function Active { All | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $staleMin } }
function Hint { "== heartbeat: arm ONE: CronCreate (cron */10 * * * *), prompt: run supervise and retry when stale" }
function Keep($x, $rm) { $x.m = @(@($x.m) | Where-Object { $p = "$_" -split '>', 2; $p[0] -notin $rm }) }
function Label { $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }; $v }
function Bounded { for ($i = 0; $i -lt 3; $i++) { Start-Sleep 1 }; foreach ($x in @(1, 2)) { $x }; while ((Get-Date) -lt $end) { Start-Sleep 5 } }
''', 'fp.py': 'def port():\n    print("kittool port: GEMINI.md stale or missing; retry later")\n',
     'fp.mjs': 'export function login(page, L) {\n  if (!page.url().includes(L.path)) {   // logged in as someone else: clear and retry\n    return 1\n  }\n}\n',
     'real.ps1': 'function Poll($f) {\n  while ($true) { Start-Sleep 5; if (Test-Path $f) { break } }\n}\n',
     'real.mjs': 'export async function waitDone(poll) {\n  let done = false\n  while (!done) { done = await poll() }\n}\n',
     'marked.ps1': 'function Watch($f) {\n  while ($true) { Start-Sleep 5 }   # flow: unbounded on purpose - watch until Ctrl+C\n}\n'}
k = types.SimpleNamespace(files=list(T), texts=T, dir=sys.argv[2], skills=[], agents={}, workflows={})
d = kittool.model(k, [])
c = collections.Counter(m.group(0) for i in d['issues'] for m in [re.search(r'(fp|real|marked)\.\w+', i['text'])] if m)
print(' '.join(f'{f}={c.get(f, 0)}' for f in T), 'deliberate=' + str(sum(1 for i in d['deliberate'] if 'marked.ps1' in i['text'])))
'@
  $fxf = Join-Path ([IO.Path]::GetTempPath()) "kit-flow-fixture-$PID.py"; Set-Content $fxf $fx -Encoding utf8
  $res = "$(& $py -X utf8 $fxf (Join-Path $src 'skills/orchestrate') ([IO.Path]::GetTempPath()) 2>&1)"
  Expect "kit-flow: no false loop issues ($res)" ($res -match 'fp\.ps1=0 fp\.py=0 fp\.mjs=0')
  Expect 'kit-flow: real unbounded loops flagged once each' ($res -match 'real\.ps1=1 real\.mjs=1')
  Expect 'kit-flow: a loop marked `flow: <reason>` is listed as deliberate, not counted' ($res -match 'marked\.ps1=0' -and $res -match 'deliberate=1')

"$script:fails failure(s)"; exit [int]($script:fails -gt 0)
