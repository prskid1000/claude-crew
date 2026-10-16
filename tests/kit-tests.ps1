#Requires -Version 7
<#
kit-tests.ps1: the kit's offline tests in one file (no real tracker, git host, Drive or services: throw-away kit copies, local
git repos and mocked CLIs). Run after changing a kit script (orchestrate K3, CONTRIBUTING):
  pwsh -NoProfile -File <kit>/tests/kit-tests.ps1 [-Area dev|qa|orch|local|all]
Inputs: the kit next to this folder. Outputs: PASS / FAIL lines and a total. Exit codes: 0 all pass · 1 a check failed · 2 usage error.
#>
param([ValidateSet('dev', 'qa', 'orch', 'local', 'all')][string]$Area = 'all')
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot   # the kit
$script:fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
function New-TestKit([string]$name) {
  $k = Join-Path ([IO.Path]::GetTempPath()) "kit-test-$name-$PID\.claude"
  foreach ($f in 'skills/dev-kit/lib.ps1', 'skills/dev-kit/paths.json', 'skills/dev-kit/dev.ps1', 'skills/dev-kit/devtools.py', 'skills/qa-kit/qa.ps1',
      'skills/orchestrate/orch.ps1', 'skills/orchestrate/kit.ps1', 'skills/local-env/localenv.ps1', 'skills/local-env/migrations.py', 'LESSONS.md') {
    $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path $src $f) $d
  }
  $k
}
function Remove-TestKit($k) { Remove-Item (Split-Path $k) -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # every test kit uses its own runtime and state
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }

# =============================================================== dev: worktrees, deploy merge, git host, tracker, guard, devtools
if ($Area -in 'dev', 'all') {
  "== dev"
  $k = New-TestKit dev; $D = Join-Path $k 'skills/dev-kit/dev.ps1'; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
  $r = Join-Path (Split-Path $k) 'git'; New-Item -ItemType Directory -Force "$r/outer/inner" | Out-Null
  $env:CLAUDE_WT_ROOT = "$r/wt"; foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
  try {
    git -C "$r/outer" init -q; git -C "$r/outer" commit -q --allow-empty -m init
    'x' | Set-Content "$r/outer/stray.txt"; 'y' | Set-Content "$r/outer/inner/a.txt"
    $out = pwsh -NoProfile -File $D wt commit -Dir "$r/outer/inner" -Message m 2>&1 | Out-String
    Expect 'wt commit refuses a plain subfolder' ($LASTEXITCODE -ne 0 -and $out -match 'not the top of a git worktree' -and -not (git -C "$r/outer" diff --cached --name-only))
    'feat: from file' | Set-Content "$r/msg.txt"
    Push-Location "$r/outer"; $null = pwsh -NoProfile -File $D wt commit -MessageFile "$r/msg.txt" 2>&1; $code = $LASTEXITCODE; Pop-Location
    Expect 'wt commit from the current folder with -MessageFile' ($code -eq 0 -and (git -C "$r/outer" log -1 --format=%s) -eq 'feat: from file')
    git init -q --bare "$r/origin.git"; git clone -q "$r/origin.git" "$r/repo" 2>$null
    'a' | Set-Content "$r/repo/a.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m init; git -C "$r/repo" branch -M main
    git -C "$r/repo" push -q origin main 2>$null; git -C "$r/repo" push -q origin main:staging 2>$null
    New-Item -ItemType Directory -Force "$r/repo/.githooks" | Out-Null
    [IO.File]::WriteAllText("$r/repo/.githooks/pre-commit", "#!/bin/sh`necho hooked > `"`$(git rev-parse --git-dir)/hook-ran`"`n")
    git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m hooks; git -C "$r/repo" config core.hooksPath .githooks
    'b' | Set-Content "$r/repo/b.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: b'; git -C "$r/repo" push -q origin main 2>$null
    $out = pwsh -NoProfile -File $O deploy merge -Repo "$r/repo" -To staging -From main 2>&1 | Out-String
    $wt = if ($out -match 'worktree: (.+)') { $Matches[1].Trim() }
    $gd = if ($wt) { (git -C $wt rev-parse --absolute-git-dir).Trim() }
    Expect 'deploy merge is a merge commit' ($wt -and @((git -C $wt log -1 --format=%p) -split ' ').Count -eq 2)
    Expect 'deploy merge ran the pre-commit hook' ($gd -and (Test-Path (Join-Path $gd 'hook-ran')))
  } finally { Remove-Item Env:CLAUDE_WT_ROOT -ErrorAction SilentlyContinue }
  # git host: GitLab passes paths through to glab, GitHub translates them to gh (mocked CLIs, fresh process)
  $gh = @'
$script:calls = [Collections.Generic.List[string]]::new()
function glab { $script:calls.Add("glab $($args -join ' ')"); $global:LASTEXITCODE = 0; '{"iid":5,"state":"merged"}' }
function gh { $script:calls.Add("gh $($args -join ' ')"); $global:LASTEXITCODE = 0; $p = "$($args[1])"
  switch -Regex ($p) {
    'pulls/7/files' { '[{"filename":"a.txt"},{"filename":"b.txt","previous_filename":"old.txt"}]'; break }
    'pulls/7$' { '{"number":7,"title":"feat: x GH-12","state":"open","head":{"ref":"f/x","sha":"abc"},"base":{"ref":"main"},"merged_at":null,"mergeable":false,"mergeable_state":"dirty","auto_merge":null}'; break }
    'pulls/8$' { '{"number":8,"title":"t","state":"closed","merged_at":"2026-10-15T10:00:00Z","head":{"ref":"f/y","sha":"def"},"base":{"ref":"main"},"merge_commit_sha":"m8"}'; break }
    'check-runs' { '{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}'; break }
    'compare/' { '{"merge_base_commit":{"sha":"base1"},"files":[{"filename":"a.txt"}]}'; break }
    'actions/runs\?' { '{"workflow_runs":[{"id":11,"head_sha":"m8","created_at":"2026-10-15T11:00:00Z","conclusion":"success"}]}'; break }
    'actions/runs/11/jobs' { '{"jobs":[{"id":3,"name":"deploy-staging","conclusion":"success","completed_at":"2026-10-15T11:05:00Z"}]}'; break }
    default { '{}' } } }
. $args[0]
$script:HostType = 'gitlab'
$m = Invoke-HostApi 'projects/g%2Fr/merge_requests/5'; "gl-get:$($script:calls[-1] -eq 'glab api projects/g%2Fr/merge_requests/5' -and $m.state -eq 'merged')"
$null = Invoke-HostApi 'projects/g%2Fr/merge_requests/5/merge' -Method PUT -Fields @{ squash = 'true' }; "gl-put:$($script:calls[-1] -eq 'glab api -X PUT projects/g%2Fr/merge_requests/5/merge -f squash=true')"
$script:HostType = 'github'
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/7'; "gh-mr:$($m.iid -eq 7 -and $m.state -eq 'opened' -and $m.source_branch -eq 'f/x' -and $m.has_conflicts -and $m.head_pipeline.status -eq 'failed')"
$m = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'; "gh-merged:$($m.state -eq 'merged' -and $m.merge_commit_sha -eq 'm8')"
$c = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/changes'; "gh-changes:$(@($c.changes).Count -eq 2 -and $c.changes[1].old_path -eq 'old.txt')"
$b = Invoke-HostApi 'projects/o%2Fr/repository/merge_base?refs[]=abc&refs[]=staging'; "gh-base:$($b.id -eq 'base1')"
$p = @(Invoke-HostApi 'projects/o%2Fr/pipelines?ref=staging&per_page=10'); $j = @(Invoke-HostApi "projects/o%2Fr/pipelines/$($p[0].id)/jobs?per_page=100"); "gh-runs:$($p[0].sha -eq 'm8' -and $j[0].name -eq 'deploy-staging' -and $j[0].status -eq 'success')"
$n = $script:calls.Count; $null = Invoke-HostApi 'projects/o%2Fr/merge_requests/8'; "memo:$($script:calls.Count -eq $n)"
$null = Invoke-HostApi 'projects/o%2Fr/merge_requests/7/merge' -Method PUT -Fields @{ merge_when_pipeline_succeeds = 'true' }; "gh-auto:$(@($script:calls | Where-Object { $_ -like 'gh pr merge 7 -R o/r --squash --delete-branch --auto' }).Count -eq 1)"
'@
  $f = Join-Path (Split-Path $k) 'githost-test.ps1'; Set-Content $f $gh
  $res = @(pwsh -NoProfile -File $f (Join-Path $k 'skills/dev-kit/lib.ps1') 2>&1)
  foreach ($x in 'gl-get', 'gl-put', 'gh-mr', 'gh-merged', 'gh-changes', 'gh-base', 'gh-runs', 'memo', 'gh-auto') { Expect "git host: $x" (@($res | Where-Object { "$_" -eq "${x}:True" }).Count -eq 1) }
  # tracker verbs per backend: the CLI / REST call each one builds (-DryRun), and the 'none' store for real
  foreach ($case in @(@('clickup', @('status', '12', 'failedTesting'), 'clickup status set'), @('github', @('list', 'o/r', 'promoted', '-Type', 'github'), 'gh issue list -R o/r'),
      @('gitlab', @('list', 'g/p', 'inTest'), 'labels=status%3Ain'), @('jira', @('list', 'PROJ', 'failedTesting'), 'search/jql'))) {
    $env:KIT_TRACKER_TYPE = $case[0]
    $out = pwsh -NoProfile -File $D tracker @($case[1]) -DryRun 6>&1 2>&1 | Out-String
    Expect "tracker $($case[0]): $($case[1][0]) builds the backend call" ($out -match [regex]::Escape($case[2]) -or $out -match $case[2])
  }
  $env:KIT_TRACKER_TYPE = 'none'
  $t = pwsh -NoProfile -File $D tracker create -List L1 -Name 'T one' -Description 'd' | ConvertFrom-Json
  $null = pwsh -NoProfile -File $D tracker status $t.id failedTesting
  $l = @(pwsh -NoProfile -File $D tracker list L1 failedTesting | ConvertFrom-Json)
  Expect 'tracker none: create, status failedTesting, list' ($t.id -like 'LOCAL-*' -and $l.Count -eq 1 -and $l[0].id -eq $t.id)
  $env:KIT_TRACKER_TYPE = 'clickup'; 'body text' | Set-Content "$r/c.md"
  $out = pwsh -NoProfile -File $D tracker comment 12 -File "$r/c.md" -DryRun 6>&1 2>&1 | Out-String
  $bad = pwsh -NoProfile -File $D tracker comment 12 -Bogus x -DryRun 2>&1 | Out-String; $badCode = $LASTEXITCODE
  Expect 'tracker comment -File sends the file; an unknown option is a usage error' ($out -match 'comment add 12 "body text' -and $badCode -eq 2 -and $bad -match 'unknown option -Bogus')
  Remove-Item Env:KIT_TRACKER_TYPE
  $kv = pwsh -NoProfile -Command ". '$(Join-Path $k 'skills/dev-kit/lib.ps1')'; function T1 { param([string]`$Mode, [string[]]`$Lanes, [switch]`$Cold) ""`$Mode|`$(`$Lanes -join '+')|`$Cold"" }; `$a = @{ Lanes = 'L1'; Mode = 'None'; Cold = `$true }; & { Invoke-KitVerb T1 `$args } @a"
  Expect 'Invoke-KitVerb: a splatted hashtable (-Mode: None) binds like -Mode None' ("$kv".Trim() -eq 'None|L1|True')
  $out = pwsh -NoProfile -File $D guard -SelfTest 2>&1 | Out-String
  Expect 'guard self-test' ($out -match '(\d+)/\1 passed')
  $out = & $py -X utf8 (Join-Path $k 'skills/dev-kit/devtools.py') selftest 2>&1 | Out-String
  Expect 'devtools selftest' ($LASTEXITCODE -eq 0)
  Remove-TestKit $k
}

# =============================================================== qa: the result rule (finalize), deploy detection
if ($Area -in 'qa', 'all') {
  "== qa"
  $k = New-TestKit qa; $Q = Join-Path $k 'skills/qa-kit/qa.ps1'; $store = Join-Path $k '.state/tracker-none'
  $env:KIT_TRACKER_TYPE = 'none'; $env:KIT_REPORT_TYPE = 'markdown'
  function New-Run($name, $items) {
    $d = Join-Path (Split-Path $k) "runs/$name"; New-Item -ItemType Directory -Force $d | Out-Null
    @{ title = "Run $name"; target = 't'; tracker = @{ list = 'L1'; parent = 'P1' }; items = @($items | ForEach-Object { @{ code = $_.code; title = $_.code; subtasks = @(@{ id = $_.task; name = "Task $($_.task)" }) } }) } | ConvertTo-Json -Depth 8 | Set-Content "$d/run.json"
    foreach ($it in $items) {
      New-Item -ItemType Directory -Force "$d/$($it.code)" | Out-Null
      @{ code = $it.code; checks = @($it.checks | ForEach-Object { $c = @{ id = $_[0]; subtask_id = $it.task; screen = 's'; result = $_[1]; what_was_done = 'w'; observed = "o $($_[0])"; evidence = @() }; if ($_.Count -gt 2) { $c.defect = $_[2] }; $c }); findings = @(); setup_changes = @(); data_created = @() } | ConvertTo-Json -Depth 8 | Set-Content "$d/$($it.code)/results.json"
    }
    $d
  }
  function Fin($d, $c) { pwsh -NoProfile -File $Q finalize -RunDir $d -Code $c 2>&1 | Out-String }
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
  # deploy detection: a squash-merged deploy MR counts as deployed (canned git-host answers)
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
  $f = Join-Path (Split-Path $k) 'deployed-test.ps1'; Set-Content $f $t
  $res = @(pwsh -NoProfile -File $f $Q 2>&1)
  Expect 'deployed: a squash-merged deploy MR counts as deployed' (@($res | Where-Object { "$_" -eq 'squash:True' }).Count -eq 1)
  Expect 'deployed: a deploy MR without the commit does not' (@($res | Where-Object { "$_" -eq 'other:True' }).Count -eq 1)
  # test-and-close: a check still NOT_TESTED gets one stronger retry (models.retest, opus) before the result rule (mocked agents)
  $wf = [IO.File]::ReadAllText((Join-Path $src 'workflows/test-and-close.js')) -replace '^export const meta', 'const meta'
  $js = @'
const calls = []
const ck = (id, result, extra = {}) => ({ id, subtask_id: 'T1', screen: 's', result, what_was_done: 'w', observed: `o ${id}`, evidence: [], attempts: 1, ...extra })
async function agent(prompt, o) {
  calls.push({ label: o.label, model: o.model, prompt })
  if (/^record-args/.test(o.label)) return { ok: true, output: 'RECORDED' }
  if (/^(test|retest):/.test(o.label)) return { code: 'A1', checks: [ck('C1', 'NOT_TESTED', { cause: 'env-data' }), ck('C2', 'PASS'), ck('C3', 'PASS')], findings: [], setup_changes: [], data_created: [] }
  if (/^retest-strong:/.test(o.label)) return { code: 'A1', checks: [ck('C1', 'PASS')], findings: [], setup_changes: [], data_created: [] }
  if (/^close/.test(o.label)) return { ok: true, output: 'published' }
  return { ok: true, output: '', signals: 0, lessonsChanged: [] }
}
const args = { runDir: 'C:/runs/R1', kitDir: 'C:/kit', learn: false, items: [{ code: 'A1', title: 'A one', guideFile: 'g.md', lane: 'web', subtasks: [{ id: 'T1' }] }] }
const run = async (args, agent, log, phase, pipeline) => { __BODY__ }
run(args, agent, () => {}, () => {}, null).then(() => {
  const s = calls.find((c) => c.label === 'retest-strong:A1'), cl = calls.find((c) => c.label === 'close:A1')
  console.log(`strong:${!!s && s.model === 'opus' && /blocked by env-data/.test(s.prompt) && /ONLY these checks: C1/.test(s.prompt)}`)
  console.log(`closed-pass:${!!cl && /"id":"C1"[^}]*"result":"PASS"/.test(cl.prompt)}`)
}).catch((e) => console.log('error:' + e))
'@
  $jf = Join-Path (Split-Path $k) 'tc-retry.mjs'; [IO.File]::WriteAllText($jf, $js.Replace('__BODY__', $wf))
  $res = @(node $jf 2>&1)
  Expect 'test-and-close: NOT_TESTED gets one stronger retry, told its blocker' (@($res | Where-Object { "$_" -eq 'strong:true' }).Count -eq 1)
  Expect 'test-and-close: the retry''s PASS is what gets published' (@($res | Where-Object { "$_" -eq 'closed-pass:true' }).Count -eq 1)
  # test-and-close select: Prepare builds the run (qa-kit L1), the resume record holds the runDir, an item's own target pins its testers
  $js2 = @'
const calls = []
async function agent(prompt, o) {
  calls.push({ label: o.label, prompt })
  if (o.label === 'prepare') return { runDir: 'C:/rt/work/qa-runs/2026-01-01-local', items: 1, left: [{ id: 'T9', reason: 'not live' }], summary: 's' }
  if (/^load-run/.test(o.label)) return { json: JSON.stringify({ target: 'local-a', items: [{ code: 'A1', title: 'A', guideFile: 'g.md', lane: 'api', target: 'local-b', subtasks: [{ id: 'T1' }] }] }) }
  if (/^record-args/.test(o.label)) return { ok: true, output: 'RECORDED' }
  if (/^test:/.test(o.label)) return { code: 'A1', checks: [{ id: 'C1', subtask_id: 'T1', screen: 's', result: 'PASS', what_was_done: 'w', observed: 'o', evidence: [], attempts: 1 }], findings: [], setup_changes: [], data_created: [] }
  return { ok: true, output: '', signals: 0, lessonsChanged: [] }
}
const args = { select: { statuses: ['promoted', 'inTest'], exclude: ['T7'] }, target: 'local', kitDir: 'C:/kit', learn: false }
const run = async (args, agent, log, phase, pipeline) => { __BODY__ }
const logs = []
run(args, agent, (m) => logs.push(m), () => {}, null).then(() => {
  const p = calls.find((c) => c.label === 'prepare'), rec = calls.find((c) => c.label === 'record-args'), t = calls.find((c) => c.label === 'test:A1')
  console.log(`prepare:${!!p && /"statuses":\["promoted","inTest"\]/.test(p.prompt) && /"target":"local"/.test(p.prompt) && /"exclude":\["T7"\]/.test(p.prompt) && /qa-runs\/<yyyy-MM-dd>-local-promoted-intest/.test(p.prompt)}`)
  console.log(`record:${!!rec && /"runDir":"C:\/rt\/work\/qa-runs\/2026-01-01-local"/.test(rec.prompt) && !/"select"/.test(rec.prompt)}`)
  console.log(`item-target:${!!t && /KIT_QA_TARGETS='local-b'/.test(t.prompt) && logs.some((l) => /left out T9: not live/.test(l))}`)
}).catch((e) => console.log('error:' + e))
'@
  $jf = Join-Path (Split-Path $k) 'tc-select.mjs'; [IO.File]::WriteAllText($jf, $js2.Replace('__BODY__', $wf))
  $res = @(node $jf 2>&1)
  foreach ($x in 'prepare', 'record', 'item-target') { Expect "test-and-close select: $x" (@($res | Where-Object { "$_" -eq "${x}:true" }).Count -eq 1) }
  if (-not (@($res | Where-Object { "$_" -match ':true$' }).Count -eq 3)) { $res | Select-Object -First 5 }
  Remove-Item Env:KIT_TRACKER_TYPE, Env:KIT_REPORT_TYPE
  Remove-TestKit $k
}

# =============================================================== orch: track, decisions, deploy batching, lessons
if ($Area -in 'orch', 'all') {
  "== orch"
  $k = New-TestKit orch; $O = Join-Path $k 'skills/orchestrate/orch.ps1'; $tf = Join-Path $k '.state/tracking.json'
  $env:KIT_TRACKER_TYPE = 'clickup'   # tag CU-
  $out = pwsh -NoProfile -File $O track add -Task 0 -Mrs 'web!1' 2>&1 | Out-String
  Expect "track: placeholder task '0' refused" ($LASTEXITCODE -ne 0 -and $out -match 'needs a real -Task id')
  $out = pwsh -NoProfile -File $O track add -Task 'CU-abc123' -Mrs 'web!1,web!2' -MergeAfter 'web!2>api!7' 2>&1 | Out-String
  $tasks = (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks
  Expect 'track: tag stripped, merge order echoed' ($tasks.ContainsKey('abc123') -and $out -match 'merge-after: web!2>api!7')
  $null = pwsh -NoProfile -File $O track remove -Task abc123 -Mrs 'web!2' 2>&1
  $tasks = (Get-Content $tf -Raw | ConvertFrom-Json -AsHashtable).tasks
  Expect 'track: remove drops the MR and its pair' ((@($tasks.abc123.mrs) -join ',') -eq 'web!1' -and -not @($tasks.abc123.mergeAfter).Count)
  Remove-Item Env:KIT_TRACKER_TYPE
  # decisions: ask -> pending (contracts note) -> answer -> wait returns the answer
  $cf = Join-Path (Split-Path $k) 'brief.contracts.md'; '# contracts' | Set-Content $cf
  $out = pwsh -NoProfile -File $O decide ask -Run w1 -Agent X1 -Item A2 -Question 'Keep the old total?' -Options 'A: keep','B: recompute' -Recommend A -Contracts $cf | Out-String
  $id = if ($out -match 'DECISION (\S+) pending') { $Matches[1] }
  $pend = @(pwsh -NoProfile -File $O decide list -Pending -Json | ConvertFrom-Json)
  Expect 'decide: ask records a pending decision and notes it in the contracts file' ($id -and $pend.Count -eq 1 -and (Get-Content $cf -Raw) -match "DECISION NEEDED $id")
  $null = pwsh -NoProfile -File $O decide answer -Id $id -Answer 'A, keep it'
  $w = pwsh -NoProfile -File $O decide wait -Id $id -MaxMinutes 1 | Out-String
  Expect 'decide: answer -> wait returns it, contracts carry it, none pending' ($w -match 'ANSWERED' -and $w -match 'keep it' -and (Get-Content $cf -Raw) -match "$id ANSWERED" -and -not @(pwsh -NoProfile -File $O decide list -Pending -Json | ConvertFrom-Json | Where-Object { $_ }).Count)
  # deploy batching (offline fixture): one batch per env from every tracked task; the window holds a second deploy
  $cfgF = Join-Path $k 'skills/dev-kit/kit.local.json'
  @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }, @{ target = 'prod'; branch = 'production'; job = 'deploy' }) }); deploy = @{ trigger = 'ask'; minIntervalHours = @{ default = 4 } } } | ConvertTo-Json -Depth 6 | Set-Content $cfgF
  $null = New-Item -ItemType Directory -Force (Split-Path $tf); @{ tasks = @{ t1 = @{ task = 't1'; mrs = @('api!1'); done = $true; doneAt = (Get-Date).ToString('s') }; t2 = @{ task = 't2'; mrs = @('api!2'); done = $false } }; automerge = @{} } | ConvertTo-Json -Depth 6 | Set-Content $tf
  $fx = Join-Path (Split-Path $k) 'deploy-fixture.json'
  @{ mrs = @{ 'api!1' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'not on staging yet' }) }; 'api!2' = @{ rows = @(@{ target = 'stage'; state = 'DEPLOYED'; detail = 'live' }) }; 'api!3' = @{ rows = @(@{ target = 'stage'; state = 'NOT-DEPLOYED'; detail = 'x' }) } }; lastCi = @{ stage = (Get-Date).AddHours(-6).ToString('s') } } | ConvertTo-Json -Depth 6 | Set-Content $fx
  $p = @(pwsh -NoProfile -File $O deploy plan -Offline $fx -Json | ConvertFrom-Json)
  Expect 'deploy plan: prod never a candidate; one ASK batch for stage with the undeployed MR only' ($p.Count -eq 1 -and $p[0].target -eq 'stage' -and $p[0].status -eq 'ASK' -and (@($p[0].mrs.mr) -join ',') -eq 'api!1')
  $null = pwsh -NoProfile -File $O deploy request -Mrs 'api!3' -Run w2 -Offline $fx
  $p = @(pwsh -NoProfile -File $O deploy plan -Offline $fx -Json | ConvertFrom-Json)
  Expect 'deploy request: another session''s MR joins the same batch' ((@($p[0].mrs.mr | Sort-Object) -join ',') -eq 'api!1,api!3')
  $null = pwsh -NoProfile -File $O deploy record -Env stage -Mrs 'api!1','api!3' -By tester
  $p = @(pwsh -NoProfile -File $O deploy plan -Offline $fx -Json | ConvertFrom-Json)
  Expect 'deploy record: the window holds the next ask (WAIT), the pending request is cleared' ($p[0].status -eq 'WAIT' -and -not @($p[0].pending).Count)
  # deploy.trigger owner (the default): merged work is READY and waits for a person's "deploy <env>"; supervise never asks
  @{ repos = @(@{ name = 'api'; deploys = @(@{ target = 'stage'; branch = 'staging'; job = 'deploy' }) }) } | ConvertTo-Json -Depth 6 | Set-Content $cfgF
  $null = pwsh -NoProfile -File $O deploy request -Mrs 'api!3' -Run w3 -Offline $fx
  $p = @(pwsh -NoProfile -File $O deploy plan -Offline $fx -Json | ConvertFrom-Json)
  Expect 'deploy plan: trigger owner (default) -> READY inside the window, never ASK / WAIT' ($p[0].status -eq 'READY' -and $p[0].trigger -eq 'owner')
  $sup = (Get-Command (Join-Path $k 'skills/orchestrate/orch.ps1')).ScriptBlock.Ast.Extent.Text -match "deploy\.trigger' 'owner'\)\)\.ToLower\(\) -eq 'ask'"
  Expect 'supervise: DEPLOY ASK only under trigger ask' $sup
  # crash recovery: the workflow's own args record (FNV-checked) wins over a short typed record; recover prints the resume call
  $ld = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath launches }; New-Item -ItemType Directory -Force $ld | Out-Null
  $full = '{"brief":"C:/b/wave-x.md","agents":[{"id":"X1","items":"A1"}],"mandate":["do it"]}'
  $af = Join-Path (Split-Path $k) 'args.json'; [IO.File]::WriteAllText($af, $full)
  $h = & { . $O; Get-KitFnv $full }
  $bad = pwsh -NoProfile -File $O launch -Self -Script dev-wave.js -Run wave-x -ArgsFile $af -Fnv 00000000 | Out-String; $badCode = $LASTEXITCODE
  $ok = pwsh -NoProfile -File $O launch -Self -Script dev-wave.js -Run wave-x -ArgsFile $af -Fnv $h | Out-String
  Expect 'launch -Self: a wrong hash is MISMATCH (exit 1), the right one RECORDED' ($badCode -eq 1 -and $bad -match 'MISMATCH' -and $ok -match 'RECORDED')
  $null = pwsh -NoProfile -File $O launch -RunId wf_t1 -Script (Join-Path $k 'workflows/dev-wave.js') -ArgsJson '{"brief":"C:/b/wave-x.md"}' 2>&1
  $rj = Get-Content (Join-Path $ld 'wf_t1.json') -Raw | ConvertFrom-Json; $rj.holderPid = 999999; $rj | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $ld 'wf_t1.json')   # its session is gone
  $l = pwsh -NoProfile -File $O launch -List -Brief | Out-String
  $rc = pwsh -NoProfile -File $O recover | Out-String
  Expect 'launch -List / recover: the stopped run resumes with the workflow''s exact args' ($l -match 'wf_t1' -and $l -match 'self-dev-wave-wave-x' -and $rc -match "resumeFromRunId: 'wf_t1'" -and $rc -match 'written by the workflow: exact' -and (Test-Path (Join-Path $ld 'wf_t1.resume.md')))
  # network loss: a tracker write that fails on the network is queued in the outbox, replayed once the network is back
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
  $nf = Join-Path (Split-Path $k) 'outbox-test.ps1'; Set-Content $nf $nt
  $res = @(pwsh -NoProfile -File $nf (Join-Path $k 'skills/dev-kit/lib.ps1') 2>&1)
  foreach ($x in 'queued', 'sent', 'real') { Expect "outbox: $x" (@($res | Where-Object { "$_" -eq "${x}:True" }).Count -eq 1) }
  # a seat / claim whose session process is gone never blocks (a dead tester's seat once blocked setup -Migrate)
  $sd = & { . (Join-Path $k 'skills/dev-kit/lib.ps1'); Get-KitPath qa-seats }; New-Item -ItemType Directory -Force "$sd/seats", "$sd/claims" | Out-Null
  @{ agent = 'test:D1'; kind = 'web'; need = 1.5; since = (Get-Date).ToString('s'); holderPid = 999999 } | ConvertTo-Json | Set-Content "$sd/seats/test_D1.json"
  $rd = Join-Path (Split-Path $k) 'runs/S'; New-Item -ItemType Directory -Force $rd | Out-Null
  @{ run = 'S'; code = 'S1'; owner = 'w9'; since = (Get-Date).ToString('s'); holderPid = 999999 } | ConvertTo-Json | Set-Content "$sd/claims/S__S1.json"
  $null = pwsh -NoProfile -File (Join-Path $k 'skills/qa-kit/qa.ps1') seat status
  $cl = pwsh -NoProfile -File (Join-Path $k 'skills/qa-kit/qa.ps1') seat acquire -Agent test:S1 -Kind api -RunDir $rd -Code S1 -Owner w1 -KeepFreeGB 0.1 -WaitMinutes 0 | Out-String
  Expect 'seats: a dead holder''s seat is freed, its claim taken over' (-not (Test-Path "$sd/seats/test_D1.json") -and $cl -notmatch 'ALREADY' -and (Get-Content "$sd/claims/S__S1.json" -Raw | ConvertFrom-Json).owner -eq 'w1')
  $out = "Merge branch 'feature/long-branch-name-for-testing' into deploy/staging-longer-name" | python -X utf8 (Join-Path $src 'skills/orchestrate/kittool.py') prose --kind merge-commit - | Out-String
  Expect 'prose: a merge commit is its own kind (no conv, no 72-char subject)' ($LASTEXITCODE -eq 0)
  # lessons: one LESSONS.md, a section per skill; an org term routes a lesson to LESSONS.local.md
  @{ orgTerms = @('Acmecorp') } | ConvertTo-Json | Set-Content (Join-Path $k 'skills/dev-kit/kit.local.json')
  $null = pwsh -NoProfile -File $O learn -Skill tech-audit -Lesson '(2×) a generic lesson'
  $null = pwsh -NoProfile -File $O learn -Skill tech-audit -Lesson 'an Acmecorp lesson'
  $r1 = pwsh -NoProfile -File $O learn -Read -Skill tech-audit | Out-String
  Expect 'learn: generic lesson in LESSONS.md, org-term lesson in LESSONS.local.md' ($r1 -match 'a generic lesson' -and $r1 -match '\(local\)' -and (Get-Content (Join-Path $k 'LESSONS.local.md') -Raw) -match 'Acmecorp' -and (Get-Content (Join-Path $k 'LESSONS.md') -Raw) -notmatch 'Acmecorp')
  $null = pwsh -NoProfile -File $O learn -Skill tech-audit -Fixed 'a generic lesson'
  Expect 'learn: -Fixed moves the line to ## History' ((Get-Content (Join-Path $k 'LESSONS.md') -Raw) -match '(?s)## History.*\(fixed in kit\) \(2×\) a generic lesson')
  # prose: templates.md "Writing standards" measured by kittool.py prose
  $KT = Join-Path $src 'skills/orchestrate/kittool.py'; $pf = Join-Path $k 'mr.md'
  "## Summary`nhttps://t.example.com/T-1 — keep the offset`n## Changes`n- ISO dates`n## How tested`n- tests ``ExportTest```n## Risks`n- none`n## Links`n- doc" | Set-Content $pf
  $null = python -X utf8 $KT prose --kind mr-body $pf; Expect 'prose: a template-shaped MR body passes' ($LASTEXITCODE -eq 0)
  "Hi, I hope this is basically fine`n## Changes`n- a`n- b`n- c`n- d" | Set-Content $pf
  $out = python -X utf8 $KT prose --kind mr-body $pf | Out-String
  Expect 'prose: filler, missing sections and a 4th bullet are findings' ($LASTEXITCODE -eq 1 -and $out -match 'filler: "basically"' -and $out -match 'missing sections' -and $out -match '4 bullets')
  $out = 'updated stuff' | python -X utf8 $KT prose --kind commit - | Out-String
  Expect 'prose: a non-conventional commit subject is a finding' ($LASTEXITCODE -eq 1 -and $out -match 'conv')
  $rj = Join-Path $k 'results.json'; '{"checks":[{"id":"T1","note":"ok"},{"id":"T2","note":"' + ('word ' * 45) + '"}]}' | Set-Content $rj
  $out = python -X utf8 $KT prose --kind result-note $rj | Out-String
  Expect 'prose: a results.json note over 40 words is a finding' ($LASTEXITCODE -eq 1 -and $out -match '45 words')
  Remove-TestKit $k
}

# =============================================================== local: LIGHT/HEAVY migration wiring, migrations.py
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
"missing-sha:$(HasMigrations $repo 'main' 'deadbeef')"
Remove-Item (MigRoot 't') -Recurse -Force -ErrorAction SilentlyContinue
'@
  $f = Join-Path (Split-Path $k) 'revert-test.ps1'; Set-Content $f $t
  $res = @(pwsh -NoProfile -File $f $L (Join-Path (Split-Path $k) 'le') 2>&1)
  foreach ($x in 'light', 'heavy', 'plan', 'revert', 'applied', 'nohook', 'missing-sha') { Expect "local env: $x" (@($res | Where-Object { "$_" -eq "${x}:True" }).Count -eq 1) }
  $out = & $py -X utf8 (Join-Path $k 'skills/local-env/migrations.py') selftest 2>&1 | Out-String
  Expect 'migrations.py selftest' ($LASTEXITCODE -eq 0)
  Remove-TestKit $k
}

"$script:fails failure(s)"; exit [int]($script:fails -gt 0)
