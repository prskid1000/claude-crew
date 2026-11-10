#Requires -Version 7
<#
tests-deploy-merge.ps1 (goody deploys, deploy merge): offline, on a throw-away test kit with this goody's files.
Usage: kitbag.py goody test deploys (its tests.ps1 runs this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kitbag.py goody test: the kit's harness; New-TestKit adds this goody's files
$k = New-TestKit deploy-merge; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# deploy merge is a verb of the deploys goody: its adapter from the kit, else nothing to test
$dpa = Join-Path $src 'skills/bossy/adapters/deploys.ps1'
if (-not (Test-Path $dpa)) { 'SKIP deploy merge (needs the goody deploys)'; Remove-TestKit $k; Complete-Tests }
Copy-Item $dpa (Join-Path $k 'skills/bossy/adapters'); $r = Join-Path (Kd) 'git'
$env:CLAUDE_WT_ROOT = "$r/wt"
git init -q --bare "$r/origin.git"; git clone -q "$r/origin.git" "$r/repo" 2>$null
'a' | Set-Content "$r/repo/a.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m init; git -C "$r/repo" branch -M main
git -C "$r/repo" push -q origin main 2>$null; git -C "$r/repo" push -q origin main:staging 2>$null
New-Item -ItemType Directory -Force "$r/repo/.githooks" | Out-Null
[IO.File]::WriteAllText("$r/repo/.githooks/pre-commit", "#!/bin/sh`necho hooked > `"`$(git rev-parse --git-dir)/hook-ran`"`n")
git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m hooks; git -C "$r/repo" config core.hooksPath .githooks
'b' | Set-Content "$r/repo/b.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: b'; git -C "$r/repo" push -q origin main 2>$null
$out = pwsh @np $O deploy merge -Repo "$r/repo" -To staging -From main 2>&1 | Out-String
$wt = if ($out -match 'worktree: (.+)') { $Matches[1].Trim() }
$gd = if ($wt) { (git -C $wt rev-parse --absolute-git-dir).Trim() }
Expect 'deploy merge is a merge commit' ($wt -and @((git -C $wt log -1 --format=%p) -split ' ').Count -eq 2)
Expect 'deploy merge ran the pre-commit hook' ($gd -and (Test-Path (Join-Path $gd 'hook-ran')))
$kl = "$k/skills/crafty/kit.local.json"; @{ repos = @(@{ checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'live'; tag = 'rel-{date}' }) }) } | ConvertTo-Json -Depth 5 | Set-Content $kl
$o1 = pwsh @np $O deploy merge -Repo "$r/repo" -To main 2>&1 | Out-String; $o2 = pwsh @np $O deploy merge -Repo "$r/repo" -To live -Push 2>&1 | Out-String
Expect 'deploy merge: trunk = no merge; tag deploy pushes a tag' ($o1 -match 'trunk' -and $o2 -match 'pushed rel-' -and (git -C "$r/origin.git" tag) -match '^rel-')
@{ repos = @(@{ checkout = "$r/repo"; target = 'other'; deploys = @(@{ target = 'st'; branch = 'main'; from = @('main') }) }) } | ConvertTo-Json -Depth 5 | Set-Content $kl
$o4 = pwsh @np $O deploy merge -Repo "$r/repo" -To st 2>&1 | Out-String
Expect "deploy merge: no -From = deploys[].from before the repo target ($($o4.Trim()))" ($o4 -match 'source branch: main' -and $o4 -match 'trunk')
# a deploy branch: -Push refused (nothing reaches it); -Mr pushes deploy/<env>-<date>, opens the MR (method merge = squash off), merges on green
$stagingTip = "$(git -C "$r/origin.git" rev-parse staging)".Trim(); $hostLog = Join-Path (Kd) 'host.log'; $hostPs = Join-Path (Kd) 'host.ps1'
Set-Content $hostPs @'
$v, $rest = $args; $log = $env:DM_HOST_LOG; $flag = "$log.merged"
switch ($v) {
  'create' { Add-Content $log "create $($rest -join ' | ')"; '{"iid":5,"web_url":"https://h.example/g/shop/-/merge_requests/5"}' }
  'get' { @{ iid = 5; sha = 'abc'; state = $(if (Test-Path $flag) { 'merged' } else { 'opened' }) } | ConvertTo-Json -Compress }
  'merge' { Add-Content $log "merge $($rest -join ' ')"; Set-Content $flag x; '{"iid":5}' }
  'ci' { '{"id":1,"status":"success"}' }
}
'@
$hostCmd = { param($v, $a) "pwsh -NoProfile -File `"$hostPs`" $v $a" }
@{ gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.create' = (& $hostCmd create '{source} {target} {method} "{body}"'); 'mr.get' = (& $hostCmd get '{n}'); 'mr.merge' = (& $hostCmd merge '{n} {method} {sha}') } }; ci = @{ type = 'command'; commands = @{ status = (& $hostCmd ci '{sha}') } }
   repos = @(@{ name = 'shop'; checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'st'; branch = 'staging' }) }) } | ConvertTo-Json -Depth 6 | Set-Content $kl
'c' | Set-Content "$r/repo/c.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: c'; git -C "$r/repo" push -q origin main 2>$null
Get-ChildItem "$r/wt" -Directory -Filter 'deploymerge-*' -ErrorAction SilentlyContinue | ForEach-Object { git -C "$r/repo" worktree remove --force $_.FullName 2>$null }
$o5 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Push 2>&1 | Out-String
Expect "deploy merge -Push to a deploy branch: refused, nothing pushed ($($o5.Trim()))" ($o5 -match 'REFUSED' -and $o5 -match '-Mr' -and "$(git -C "$r/origin.git" rev-parse staging)".Trim() -eq $stagingTip)
$env:DM_HOST_LOG = $hostLog
$o6 = pwsh @np $O deploy merge -Repo "$r/repo" -To st -Mr -Mrs 'shop!12' -Decision 'd-42' -WaitMinutes 1 2>&1 | Out-String
$hl = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { '' }; $depBr = @(git -C "$r/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/deploy/')
Expect "deploy merge -Mr: deploy/st-<date> pushed, MR to staging with method merge and MRs + decision in the body, merged on green, staging never pushed ($($o6.Trim()) | $hl)" ($o6 -match 'merged deploy MR https://h\.example/g/shop/-/merge_requests/5' -and $depBr -match '^deploy/st-\d{12}$' -and $hl -match 'create deploy/st-\d{12} \| staging \| merge \| ' -and $hl -match 'shop!12' -and $hl -match 'Deploy decision: d-42' -and $hl -match 'merge 5 merge abc' -and "$(git -C "$r/origin.git" rev-parse staging)".Trim() -eq $stagingTip)
Remove-Item Env:DM_HOST_LOG
$o3 = pwsh @np $O deploy merge -To staging 2>&1 | Out-String
Expect "deploy merge without -Repo: a clear error, no binding crash ($($o3.Trim()))" ($o3 -match 'deploy merge: -Repo missing' -and $o3 -notmatch 'Cannot bind')
Remove-Item Env:CLAUDE_WT_ROOT
Remove-TestKit $k
Complete-Tests
