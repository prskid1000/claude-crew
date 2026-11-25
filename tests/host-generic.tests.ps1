#Requires -Version 7
<#
tests/host-generic.tests.ps1: the kit on a non-GitLab stack: a Gitea host on its own hostname, a kubectl-like `command` deploy kind,
an ssh deploy managed by docker, an unregistered kind, and no host configured at all. Offline (Invoke-KitHttp, ssh, glab, gh mocked).
Usage: pwsh -NoProfile -File tests/host-generic.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/pokey/adapters/deployed-checks.ps1', 'skills/crafty/adapters/gitea.ps1', 'skills/crafty/adapters/gitlab.ps1', 'skills/crafty/adapters/github.ps1')
$k = New-TestKit host-generic; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $kl = Join-Path $k 'skills/crafty/kit.local.json'
foreach ($f in $TestKitFiles) { $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) $f) $d }
$env:HG_HTTP = Join-Path (Kd) 'http.log'; $env:HG_SSH = Join-Path (Kd) 'ssh.log'; $env:HG_CLI = Join-Path (Kd) 'cli.log'

# 1. Gitea on code.acme.internal: deployed check over a command kind, an ssh/docker row and an unknown kind
& $J @{ gitHost = 'code.acme.internal'; gitHostType = 'gitea'; repos = @(@{ name = 'shop'; deploys = @(
      @{ target = 'k8s-stg'; command = @{ isDeployed = "`"$pwshExe`" -NoProfile -Command Write-Output DEPLOYED-{sha}" } },
      @{ target = 'box-stg'; ssh = @{ host = 'u@box'; manager = 'docker'; service = 'shop-web'; repoDir = '/srv/shop'; appDir = '/srv/shop/app' } },
      @{ target = 'helm-stg'; kind = 'helm' }) }) } $kl
$s1 = @'
. $args[0]
function glab { Add-Content $env:HG_CLI "glab $args" }; function gh { Add-Content $env:HG_CLI "gh $args" }
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) {
  Add-Content $env:HG_HTTP "$Method $Uri"
  if ($Uri -match '/repos/shop/pulls/3$') { return ('{"number":3,"title":"t","state":"closed","merged":true,"merged_at":"2026-10-15T12:00:00Z","merge_commit_sha":"' + ('a' * 40) + '","head":{"ref":"f/x","sha":"' + ('b' * 40) + '"},"base":{"ref":"main"}}' | ConvertFrom-Json) }
  if ($Uri -match '/pulls/3/files') { return , @() }
  $null
}
function ssh { Add-Content $env:HG_SSH ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(("$($args[-1])" -split ' ')[1]))); 'HEAD=abc1234 2026-01-02'; 'ANC=yes'; 'RC=0'; 'FILES=1' }
$p = Invoke-HostVerb 'mr.parseRef' @{ ref = 'shop!3' }; "parse:$($p.repo -eq 'shop' -and $p.n -eq '3')"
"unknownverb:$($null -eq (Invoke-HostVerb 'mr.rebase' @{ repo = 'shop'; n = 3 } 3>$null))"
"lacks:$($null -eq (Invoke-KitDeployKind ([pscustomobject]@{ target = 'm'; manual = $true }) 'lastDeploy'))"
Invoke-Deployed -Mrs 'shop!3' -Json
'@
$o1 = Invoke-PsTest 'hg-gitea' $s1 @($Q) | Out-String
$rows = @(($o1 -replace '(?s)^.*?(\[.*\]).*$', '$1') | ConvertFrom-Json)
$http = @(Get-Content $env:HG_HTTP -ErrorAction SilentlyContinue); $sh = Get-Content $env:HG_SSH -Raw -ErrorAction SilentlyContinue
Expect "generic host: every call goes to the configured Gitea host, no GitLab path, no glab / gh ($($http -join ' | '))" ($http.Count -ge 1 -and -not @($http | Where-Object { $_ -notmatch '^\w+ https://code\.acme\.internal/api/v1/' }).Count -and -not @($http -match 'merge_requests|/api/v4|projects/|pipelines').Count -and -not (Test-Path $env:HG_CLI))
Expect "generic host: mr.parseRef from the kit's ref rules; an unknown verb = null; a kind's missing verb = null ($($o1 -replace '(?s)\[.*', '' -replace '\s+', ' '))" ($o1 -match 'parse:True' -and $o1 -match 'unknownverb:True' -and $o1 -match 'lacks:True')
Expect "deploy kind command: its isDeployed line answers ($(($rows | Where-Object target -eq 'k8s-stg').detail))" (($rows | Where-Object target -eq 'k8s-stg').state -eq 'DEPLOYED')
Expect "deploy kind ssh, manager docker: docker inspect, no systemctl, no sudo ($(($rows | Where-Object target -eq 'box-stg').state))" (($rows | Where-Object target -eq 'box-stg').state -eq 'DEPLOYED' -and $sh -match 'docker inspect' -and $sh -notmatch 'systemctl|sudo -n')
Expect "deploy kind unregistered (helm): UNKNOWN naming the registry ($(($rows | Where-Object target -eq 'helm-stg').detail))" (($rows | Where-Object target -eq 'helm-stg').state -eq 'UNKNOWN' -and ($rows | Where-Object target -eq 'helm-stg').detail -match 'helm has no isDeployed')

# 1b. GitLab natives (parity next, recorded glab replies, no account): ci.failure lists failed jobs only (scope[]=failed), the job
# that fails the pipeline before an allowed failure, its reason + log excerpt; mr.parseRef reads !<n> in the given repo, URLs as core
& $J @{ gitHost = 'git.example'; gitHostType = 'gitlab'; gitHostGroup = 'grp'; repos = @(@{ name = 'shop' }) } $kl
$sGl = @'
. $args[0]; $global:glp = @()
function __Cli { $global:glp += "$($args[1])"
  if ("$($args[1])" -match '/jobs\?scope\[\]=failed') { @([pscustomobject]@{ id = 11; name = 'lint'; status = 'failed'; allow_failure = $true; failure_reason = 'script_failure'; web_url = 'https://g/j/11' },
      [pscustomobject]@{ id = 12; name = 'unit'; status = 'failed'; allow_failure = $false; failure_reason = 'runner_system_failure'; web_url = 'https://g/j/12' }) }
  elseif ("$($args[1])" -match '/jobs/12/trace$') { "2026-01-01T00:00:00Z 01O ok`n2026-01-01T00:00:01Z 01O ERROR: boom" } }
$f = Invoke-HostVerb 'ci.failure' @{ repo = 'grp/shop'; id = 5 }
"fail:$($f.job)|$($f.id)|$($f.reason)|$($f.excerpt)|$(@($global:glp | Where-Object { $_ -match '/jobs\?' -and $_ -notmatch 'scope' }).Count)"
$p1 = Invoke-HostVerb 'mr.parseRef' @{ ref = '!7'; repo = 'shop' }; $p2 = Invoke-HostVerb 'mr.parseRef' @{ ref = 'https://git.example/grp/shop/-/merge_requests/9' }
"parse:$($p1.repo)|$($p1.n)|$($p1.type)|$($null -eq (Invoke-HostVerb 'mr.parseRef' @{ ref = '!7' }))|$($p2.repo)|$($p2.n)|$($p2.type)|$((Invoke-HostVerb 'mr.parseRef' @{ ref = '!8'; repo = 'other/shop' }).repo)"
'@
$oGl = Invoke-PsTest 'hg-gitlab' $sGl @($Q) | Out-String
Expect "gitlab ci.failure native: failed jobs only, the failing job before an allowed one, infra reason, log excerpt, no all-jobs call ($($oGl -replace '\s+', ' '))" ($oGl -match 'fail:unit\|12\|infra\|ERROR: boom\|0')
Expect "gitlab mr.parseRef native: !7 in repo shop = grp/shop!7, no repo = none, a GitLab URL as core, a group path kept ($($oGl -replace '\s+', ' '))" ($oGl -match 'parse:grp/shop\|7\|gitlab\|True\|grp/shop\|9\|gitlab\|other/shop')

# 2. no host configured (no gitHost, gitHostType or checkout): verbs UNKNOWN, no vendor CLI, no gitlab.com default
& $J @{ repos = @(@{ name = 'shop' }) } $kl
Remove-Item $env:HG_CLI -ErrorAction SilentlyContinue
$s2 = @'
. $args[0]
function glab { Add-Content $env:HG_CLI "glab $args" }; function gh { Add-Content $env:HG_CLI "gh $args" }
$script:KitHostWarned = $false; $m = Invoke-HostVerb 'mr.get' @{ repo = 'shop'; n = 1 } 3>&1; $w = @($m | Where-Object { $_ -is [Management.Automation.WarningRecord] })
"none:$(-not @($m | Where-Object { $_ -and $_ -isnot [Management.Automation.WarningRecord] }).Count -and "$w" -match 'unknown git host: set gitHostType')"
"user:$((Get-KitHostUser 3>$null) -eq '')"
"nodefault:$($KitConf.GitHost -eq '')"
'@
$o2 = Invoke-PsTest 'hg-none' $s2 @($Q) | Out-String
Expect "no git host: verbs return nothing with one hint, whoami '', no vendor CLI, no gitlab.com default ($($o2 -replace '\s+', ' '))" ($o2 -match 'none:True' -and $o2 -match 'user:True' -and $o2 -match 'nodefault:True' -and -not (Test-Path $env:HG_CLI))

Remove-Item Env:HG_HTTP, Env:HG_SSH, Env:HG_CLI
# area scope (incident 2026-11-14: a spec-only area merged product files): the globs rule (= devtools.py selftest), the post-hoc WATCH, wt commit + the scope word
$sc = Invoke-PsTest scope @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $ErrorActionPreference = 'Stop'
$g = @('rm/api/cypress/**', 'rm/api/package.json'); $d = @('rm/api/cypress/e2e/a.cy.js', 'rm/api/package.json', 'rm/api/src/Inv.java', 'rm/api/cypress.config.js')
"globs:$("$(Get-KitScopeOutside $d $g)" -eq 'rm/api/src/Inv.java rm/api/cypress.config.js' -and -not @(Get-KitScopeOutside $d @()).Count -and "$(Get-KitScopeOutside 'a/x.ts', 'a/b/x.ts', 'A/x.ts' 'a/*.ts')" -eq 'a/b/x.ts A/x.ts' -and "$(Get-KitScopeOutside 's/a.ts', 's/b/c.html', 's/d.css' 's/**/*.{ts,html}')" -eq 's/d.css')"
# K65: a spec merge leaves the stored spec as read and keeps entries without a key
$o0 = [ordered]@{ items = @([ordered]@{ code = 'A1'; desc = 'old' }) }; $mg = Merge-KitTaskSpec $o0 ([ordered]@{ items = @([ordered]@{ code = 'A1'; desc = 'new' }, [ordered]@{ desc = 'no code' }) })
"spec:$($o0.items[0].desc -eq 'old' -and $mg.items[0].desc -eq 'new' -and @($mg.items).Count -eq 2 -and $mg.items[1].desc -eq 'no code')"
function Get-HostProject($r) { "g/$r" }; $global:calls = 0
function Invoke-HostVerb($v, $a) { $global:calls++; $p = "x/$($a.n)$(if ($v -eq 'mr.changes') { '/changes' })"; if ($p -match '/changes$') { @{ changes = @(@{ new_path = 'rm/api/cypress/e2e/a.cy.js' }, @{ new_path = 'rm/api/src/Inv.java'; old_path = 'rm/api/src/Inv.java' }) } } else { @{ state = $(if ($p -match '/7$') { 'opened' } else { 'merged' }); merged_at = (Get-Date).ToString('o') } } }
foreach ($m in 'java!5', 'java!6', 'java!7') { Write-KitLog scope-log area @{ mr = $m; branch = "b$($m[-1])"; globs = $(if ($m -eq 'java!6') { @('rm/**') } else { $g }) } }
$f1 = Invoke-Scope; $n1 = $global:calls; $f2 = Invoke-Scope; $n2 = $global:calls; $pj = Invoke-Scope -Mrs 'https://h/g/java/-/merge_requests/5,java!9' -Json | ConvertFrom-Json
"flag:$($f1 -match '^WATCH OUT-OF-AREA merged: java!5 \(1 file\(s\) outside .*rm/api/src/Inv\.java\) \| Tell the owner' -and $f1 -notmatch 'java!6|java!7' -and $f2 -eq $f1 -and $n2 -eq $n1)"
$pf = Join-Path (Get-KitPath cache) 'scope-probes.json'; @{ 'java!7' = (Get-Date).AddMinutes(-31).ToString('o') } | ConvertTo-Json | Set-Content $pf; $n3 = $global:calls; $null = Invoke-Scope
"reask:$($global:calls -eq $n3 + 1)"   # an open MR: asked again after 30 min, not every sweep
function Get-TrackerTask($i) { if ($i -eq 'b') { throw 'down' }; @{ status = "st $i" } }; "statuses:$((@(Invoke-Tracker statuses 'a,b,c') -replace ' \d{4}-\d\d-\d\dT\S+ ', ' ' -join '|') -eq 'a st a|c st c')"
"plan:$("$($pj[0].mr) $($pj[0].files) $($pj[0].source) $($pj[0].test) $($pj[0].outside)" -eq 'java!5 2 rm/api/src/Inv.java 1 rm/api/src/Inv.java' -and -not @($pj[1].outside).Count)"
Write-KitState (Join-Path (Get-KitPath decisions -Create) 'd-1.json') @{ id = 'd-1'; gate = 'scope'; status = 'answered'; item = 'b5'; mrs = @() }
"word:$((Invoke-Scope) -notmatch 'WATCH' -and -not @((Invoke-Scope -Mrs 'java!5' -Json | ConvertFrom-Json).outside).Count)"
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
Expect "crafty.ps1 scope: globs as devtools.py; WATCH names an MR merged outside its area (checked once; open, in-area ones not; an open one asked again after 30 min); -Mrs: source / test / OUT-OF-AREA per MR; a scope word lifts both ($sc)" ("$sc" -match 'globs:True' -and "$sc" -match 'flag:True' -and "$sc" -match 'reask:True' -and "$sc" -match 'statuses:True' -and "$sc" -match 'plan:True' -and "$sc" -match 'word:True' -and "$sc" -match 'spec:True')
# K73: devtools merge takes a scope word recorded for the branch (d-1, item b5) without --scope-ok; another branch is refused
& { . (Lib); Write-KitState (Join-Path (Get-KitPath decisions -Create) 'd-73.json') @{ id = 'd-73'; gate = 'scope'; status = 'answered'; item = 'b7'; mrs = @(); by = 'owner'; source = 'chat'; answeredAt = (Get-Date).ToString('o') } }
$k73 = Join-Path (Kd) 'k73.py'; Set-Content $k73 "import sys`nsys.path.insert(0, r'$k/skills/crafty')`nimport devtools`nprint(devtools.scope_refusal(['x/y.ts'], ['a/**'], 'b7', what='merge') == '' and 'refused' in devtools.scope_refusal(['x/y.ts'], ['a/**'], 'b6', what='merge'))"
$k73o = "$(& $py -X utf8 $k73 2>$null | Where-Object { $_ -match '^(True|False)$' } | Select-Object -Last 1)"
Expect "devtools scope: a recorded scope word for the branch lifts the refusal without --scope-ok; another branch still refused ($k73o)" ($k73o -eq 'True')
# tracker outbox on any tracker adapter (from bossy.tests.ps1: its token cap)
$nt = @'
. $args[0]
$env:KIT_NET_TRIES = '1'   # a tracker CLI failing per $global:trFails: network, then fine, then a real error
Register-KitAdapter 'tracker' 'fake' @{ status = { param($a) if ($global:trFails) { throw $global:trFails }; 'ok' } }; Initialize-KitTracker -Type fake
$global:trFails = 'dial tcp: lookup api.example: no such host'
$q = Set-TrackerStatus 'o/r#9' 'inTest' 3>$null; "queued:$("$q" -match '^QUEUED' -and (Test-Path (Get-KitPath outbox)))"
$global:trFails = ''
$s = @(Invoke-KitOutbox); "sent:$("$s" -match '^SENT status o/r#9' -and -not (Test-Path (Get-KitPath outbox)))"
$global:trFails = 'no issue 9 in o/r (HTTP 404)'
try { $null = Set-TrackerStatus 'o/r#9' 'inTest'; 'real:False' } catch { "real:$(-not (Test-Path (Get-KitPath outbox)))" }
'@
$res = Invoke-PsTest 'outbox-test' $nt @(Lib)
Expect-Each $res 'outbox: #' @('queued', 'sent', 'real')
# supervise untracked-MR WATCH: CI-only MRs need no task (from supervise-generic.tests.ps1: its token cap)
$O = Join-Path $k 'skills/bossy/bossy.ps1'
$uc = Invoke-PsTest ulci @'
. $args[0]; $n = Get-Date; $mrd = (Get-Date).ToUniversalTime().ToString('o'); function Get-HostProject($r, [switch]$Raw) { $r }
$mk = { param($i, $t) [pscustomobject]@{ iid = $i; title = $t; source_branch = "b$i"; target_branch = 'main'; author = @{ username = 'u' }; merged_at = $mrd } }
function Invoke-HostVerb($v, $p) { if ($v -eq 'mr.list') { @((& $mk 1 'ci: runner'), (& $mk 2 'chore: pipeline'), (& $mk 3 'feat: y')) } elseif ($v -eq 'mr.changes') { @{ changes = @(@{ new_path = $(if ($p.n -eq 2) { '.gitlab-ci.yml' } else { 'src/a.ts' }) }) } } }
$KitConf.TrackerRepos = @('a'); $s = @{ hostUser = @{ at = "$n"; v = 'u' } }; $f = Get-KitUntrackedMrFlag $s $n
"uc:$("$($f.what)" -match 'a!3' -and "$($f.what)" -notmatch 'a!1 |a!2 ')"
'@ @($O)
Expect "supervise: CI-only MRs (title ci:, or only CI config files) need no task: no untracked WATCH for them ($uc)" (@($uc | Where-Object { "$_" -eq 'uc:True' }).Count -eq 1)
# RT2 (retro 1508): pipes -Repo -Branch reads the branch's newest pipeline (a deploy branch) and names its failed job; -Branch alone = usage
$pb = Invoke-PsTest hg-pipes @'
. $args[0]; function Get-HostProject([string]$Repo, [switch]$Raw) { $Repo }
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) { [Console]::Error.WriteLine("CALL $Verb $($A.repo) $($A.ref)")
  switch ($Verb) { 'ci.runs' { , @([pscustomobject]@{ id = 6; sha = 'aaa111'; state = 'success' }, [pscustomobject]@{ id = 7; sha = 'bbb222'; state = 'failed' }) } 'ci.jobs' { , @([pscustomobject]@{ id = 9; name = 'deploy-stg'; status = 'failed' }) } 'ci.log' { "ok`nERROR: rollout timed out" } } }
Invoke-Pipes -Repo shop -Branch staging -Sha bbb -MaxMinutes 1   # the older run of another commit answers first: skipped
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
$pu = @(pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') pipes -Branch staging 2>&1) -join ' '
Expect "pipes -Repo -Branch: the branch's newest pipeline, its failed job and error; -Branch without -Repo = usage ($pb | $pu)" ("$pb" -match '"done":true' -and "$pb" -match '"mr":"branch:shop@staging","status":"failed","job":"deploy-stg","error":"ERROR: rollout timed out"' -and "$pb" -match 'CALL ci\.runs shop staging' -and $pu -match '-Branch needs -Repo')
# a failed host call says why on stderr (devtools.py mr printed "MR not created: null", retro 2026-11-25)
$hfPs = Join-Path (Kd) 'hf.ps1'; Set-Content $hfPs "[Console]::Error.WriteLine('409 branch already has an MR'); exit 3"
$hlPs = Join-Path (Kd) 'hl.ps1'; Set-Content $hlPs "'[{`"iid`":1}]'"
& $J @{ gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.create' = "`"$pwshExe`" -NoProfile -File `"$hfPs`""; 'mr.list' = "`"$pwshExe`" -NoProfile -File `"$hlPs`"" } } } $kl
$hf = pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') host mr.create '{"repo":"shop","source":"f/x","target":"main","title":"t","body":"b"}' 2>&1 | Out-String
$hl1 = "$(pwsh @np (Join-Path $k 'skills/crafty/crafty.ps1') host mr.list '{"repo":"shop","state":"opened"}' 2>$null)".Trim()
Expect "host: a failed call prints null plus the host's own error; a one-MR list stays a list ($($hf.Trim()) | $hl1)" ($hf -match '(?m)^null' -and $hf -match 'host mr\.create failed: mr\.create exit 3: .*409 branch already has an MR' -and $hl1 -match '^\[\{"iid":1\}\]$')
Remove-TestKit $k
Complete-Tests
