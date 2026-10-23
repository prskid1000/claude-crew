#Requires -Version 7
# tests.ps1 (goody deployed-checks): probe cmd / url / tag / regex and the ssh script. Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $kl = Join-Path $k 'skills/crafty/kit.local.json'
$gr = Join-Path (Kd) 'pr'; git init -q $gr; git -C $gr commit -qm a --allow-empty; git -C $gr tag v1; $s1 = git -C $gr rev-parse HEAD; git -C $gr commit -qm b --allow-empty; $s2 = git -C $gr rev-parse HEAD
$api = Start-TestApi $s1; $P = $api.port   # the probe url target
Set-Content "$(Kd)/dp.ps1" @'
. $args[0]; $ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$g, $a, $b = $args[1..3]; $r = @{ checkout = $g }; $memo = @{}; function ssh { $script:sh = $args[-1] }
"cmd:$((Probe @{ probe = "git -C $g rev-parse HEAD" } $r) -eq $b)"; "url:$((Probe @{ probe = $args[4]; probeField = 'v.sha' } $r) -eq $a)"
$v = Probe @{ tag = '^v\d' } $r; "tag:$($v -eq 'v1' -and (LocalAncestor $g $a $v) -and -not (LocalAncestor $g $b $v))"
$null = SshState @{ sudo = $false } 'x'; $x = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($sh -split ' ')[1])); "ssh:$($x -match 'shasum -a 256' -and $x -notmatch 'sudo -n')"
"rx:$((Probe @{ probe = 'echo 1234567 rev dead123'; probeRegex = 'rev (\w+)' } $r) -eq 'dead123')"
function Invoke-HostApi($p) { switch -Wildcard ($p) { '*requests/5' { @{ iid = 5; state = 'merged'; sha = 'F'; merged_at = '2026-01-02' } } '*merge_base*' { @{ id = 'F' } } '*ref=staging*' { , @(@{ id = 1; created_at = '2026-01-03'; sha = 'F' }) } '*jobs*' { , @(@{ name = 'deploy-eu'; status = 'success' }) } } }
Invoke-Deployed -Mrs 'web!5' -Detail
'@
'{"repos":[{"name":"web","deploys":[{"target":"stg","branch":"staging","job":"deploy-*"},{"target":"phones","laneApk":true}]}]}' | Set-Content $kl
$res = @(Px "$(Kd)/dp.ps1" $Q $gr $s1 $s2 "http://127.0.0.1:$P/v" 2>&1); $api.proc.Kill(); Remove-Item $kl
foreach ($x in 'cmd', 'url', 'tag', 'ssh', 'rx') { Expect "deployed: $x probe" (@($res) -contains "${x}:True") }
Expect 'deployed: a wildcard job matches a matrix job' ("$res" -match 'DEPLOYED\s+web!5')
Expect 'deployed: a laneApk deploy without the goody android-swarm is UNKNOWN with the goody line' ("$res" -match 'UNKNOWN\s+web!5\s+phones\s+deploys\[\] laneApk is a goody: run kitbag\.py goody add android-swarm')
# a squash-merged deploy MR counts; an unanswered git host is UNKNOWN, not NOT-DEPLOYED
$t = @'
. $args[0]; $ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
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
function Invoke-HostApi { $null }
$script:memo = @{}; $d = [pscustomobject]@{ target = 'stg'; branch = 'staging' }
"down:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state -eq 'UNKNOWN')"
$memo['projects/g%2Fweb/repository/commits/staging'] = [pscustomobject]@{ id = 'abc' }
"up:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state -eq 'NOT-DEPLOYED')"
'@
Expect-Each (Invoke-PsTest 'deployed-refs' $t @($Q)) 'deployed: # (squash deploy MR, other deploy MR, git host down, host up)' 'squash', 'other', 'down', 'up'
Remove-TestKit $k
Complete-Tests
