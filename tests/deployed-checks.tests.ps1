#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/deployed-checks.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests.ps1 (goody deployed-checks): probe cmd / url / tag / regex and the ssh script. Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/deploy_merge.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/deploys.md', 'skills/pokey/adapters/deployed_checks.ps1')   # copied into every New-TestKit kit
$k = New-TestKit qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $kl = Join-Path $k 'skills/crafty/kit.local.json'
$gr = Join-Path (Kd) 'pr'; git init -q $gr; git -C $gr commit -qm a --allow-empty; git -C $gr tag v1; $s1 = git -C $gr rev-parse HEAD; git -C $gr commit -qm b --allow-empty; $s2 = git -C $gr rev-parse HEAD
$api = Start-TestApi $s1; $P = $api.port   # the probe url target
Set-Content "$(Kd)/dp.ps1" @'
. $args[0]; $ast = (Get-Command Invoke-Deployed).ScriptBlock.Ast
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$g, $a, $b = $args[1..3]; $r = @{ checkout = $g }; $memo = @{}; function ssh { $script:sh = $args[-1] }
"cmd:$((Probe @{ probe = "git -C $g rev-parse HEAD" } $r) -eq $b)"; "url:$((Probe @{ probe = $args[4]; probeField = 'v.sha' } $r) -eq $a)"
$v = Probe @{ tag = '^v\d' } $r; "tag:$($v -eq 'v1' -and (LocalAncestor $g $a $v) -and -not (LocalAncestor $g $b $v))"
$null = SshState @{ sudo = $false } 'x'; $x = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($sh -split ' ')[1])); "ssh:$($x -match 'shasum -a 256' -and $x -notmatch 'sudo -n')"; "logs:$($x -match "X=\('\*\.log' '\*\.log\.\*'\)")"
"rx:$((Probe @{ probe = 'echo 1234567 rev dead123'; probeRegex = 'rev (\w+)' } $r) -eq 'dead123')"
function ssh { $script:n++; "HEAD=$($b.Substring(0, 7)) 2026-01-02"; 'ANC=yes'; 'RC=0'; 'FILES=1' }; $s3 = SshState @{ host = 'h2' } $a; $s4 = SshState @{ host = 'h2' } $b
function ssh { $script:m++ }; $null = SshState @{ host = 'h3' } $a; $null = SshState @{ host = 'h3' } $b   # no answer: asked once
"host:$($n -eq 1 -and $s3.anc -and $s4.anc -and $m -eq 1)"
if ($KitIsWindows) { Remove-Item function:ssh; $sd = Join-Path $args[5] 'sshbin'; $null = New-Item -ItemType Directory -Force $sd; '@ping -n 8 127.0.0.1 >nul' | Set-Content "$sd/ssh.cmd"; $env:PATH = "$sd;$env:PATH"
  $t0 = Get-Date; $o = Invoke-BoundedSsh @('h') 1; "bound:$(-not $o.Count -and ((Get-Date) - $t0).TotalSeconds -lt 5)" } else { 'bound:True' }
function Invoke-HostApi($p) { switch -Wildcard ($p) { '*requests/5' { @{ iid = 5; state = 'merged'; sha = 'F'; merged_at = '2026-01-02' } } '*merge_base*' { @{ id = 'F' } } '*ref=staging*' { , @(@{ id = 1; created_at = '2026-01-03'; sha = 'F' }) } '*jobs*' { , @(@{ name = 'deploy-eu'; status = 'success' }) } } }
Invoke-Deployed -Mrs 'web!5' -Detail
'@
'{"repos":[{"name":"web","deploys":[{"target":"stg","branch":"staging","job":"deploy-*"},{"target":"phones","laneApk":true}]}]}' | Set-Content $kl
$res = @(Px "$(Kd)/dp.ps1" $Q $gr $s1 $s2 "http://127.0.0.1:$P/v" (Kd) 2>&1); $api.proc.Kill()
$dl = @(Px $Q deployed -Mrs 'nope,zz!1' -Lines 2>&1); $dlc = $LASTEXITCODE
$dt = @(Px $Q deployed -Mrs 'nope,zz!1' -Json -TimeoutSec 0 2>&1 | Out-String | ConvertFrom-Json); Remove-Item $kl
Expect 'deployed -TimeoutSec: past the deadline the MRs left are UNKNOWN, the first is checked' ($dt.Count -eq 2 -and $dt[0].state -eq 'BAD-REF' -and $dt[1].state -eq 'UNKNOWN' -and $dt[1].detail -match 'TimeoutSec 0 reached')
# prepare calls Invoke-Deployed in-process: its -Json returns, so prepare (pwsh -File, as testy runs it) still writes run.json and prints RUN
$env:KIT_TRACKER_TYPE = 'none'; $craftyQ = Join-Path $k 'skills/crafty/crafty.ps1'
$tPrep = (pwsh -NoProfile -File $craftyQ tracker create -Name '[Bug] Sort' -Description "**Testing doc (human):** [open](https://docs.example/h1)`n`nMR: https://git.example/g/nope/-/merge_requests/1" -NewTask fixture 2>$null | ConvertFrom-Json).id
$null = pwsh -NoProfile -File $craftyQ tracker status $tPrep 'in test' 2>&1
$prepJob = @{ runFolder = "$(Kd)/qa-runs/<yyyy-MM-dd>-dep"; tasks = @($tPrep); target = 'stg'; kitDir = $k } | ConvertTo-Json -Compress
$prepOut = @(pwsh -NoProfile -File $Q prepare -Job $prepJob 2>&1); $prepCode = $LASTEXITCODE; $env:KIT_TRACKER_TYPE = $null
$prepRun = try { "$($prepOut[-1])" -replace '^RUN ' | ConvertFrom-Json } catch { $null }
Expect "prepare with the deploys goody: exit 0, RUN line, run.json; the not-live task left out ($prepCode $($prepOut[-2]))" ($prepCode -eq 0 -and $prepRun -and (Test-Path "$($prepRun.runDir)/run.json") -and $prepRun.left[0].reason -match 'not live on stg: nope!1 BAD-REF')
$dj = @($dl | ForEach-Object { try { "$_" | ConvertFrom-Json } catch {} } | Where-Object state -eq 'BAD-REF')
Expect "deployed -Lines: one JSON row per line, exit 1 when not all deployed ($dlc $($dl.Count))" ($dlc -eq 1 -and $dl.Count -eq 2 -and $dj.Count -eq 2 -and $dj[1].mr -eq 'zz!1')
foreach ($x in 'cmd', 'url', 'tag', 'ssh', 'logs', 'rx') { Expect "deployed: $x probe" (@($res) -contains "${x}:True") }
Expect "deployed ssh: one ssh per host, a later MR's ancestry read locally; a hung ssh ends at deploy.sshTimeoutSeconds ($($res -match '^(host|bound):'))" (@($res) -contains 'host:True' -and @($res) -contains 'bound:True')
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
function Invoke-HostApi { $null }   # only the canned answers
$p = Canned @([pscustomobject]@{ iid = 9; sha = 'S'; squash_commit_sha = 'L'; merge_commit_sha = $null }); "squash:$(OnRef $p $mr 'F' 'stg')"
$p = Canned @([pscustomobject]@{ iid = 8; sha = 'S0'; squash_commit_sha = 'L'; merge_commit_sha = $null }); "other:$(-not (OnRef $p $mr 'F' 'stg'))"
$script:memo = @{}; $d = [pscustomobject]@{ target = 'stg'; branch = 'staging' }
"down:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state -eq 'UNKNOWN')"
$memo['projects/g%2Fweb/repository/commits/staging'] = [pscustomobject]@{ id = 'abc' }
"up:$((NotLiveRow 'g%2Fweb' 'web!5' $d 'not on staging yet').state -eq 'NOT-DEPLOYED')"
# the local checkout answers ancestry and same content without host calls; a capped host compare proves nothing
$lr = Join-Path $env:TEMP "dc-local-$PID"; git init -q $lr; Set-Content "$lr/a.ts" 1; git -C $lr add a.ts; git -C $lr commit -qm a; $ca = git -C $lr rev-parse HEAD
Set-Content "$lr/b.ts" 1; git -C $lr add b.ts; git -C $lr commit -qm b; $cb = git -C $lr rev-parse HEAD; Set-Content "$lr/a.ts" 2; git -C $lr commit -qam c; $cc = git -C $lr rev-parse HEAD
$script:calls = @(); function Invoke-HostApi($path) { $script:calls += $path; $null }
$r = @{ checkout = $lr }; $script:memo = @{ 'projects/g%2Fweb/repository/commits/stg' = [pscustomobject]@{ id = $cb } }
"local:$((IsAncestor 'g%2Fweb' $ca 'stg') -and -not (IsAncestor 'g%2Fweb' $cc 'stg') -and -not @($calls -match 'merge_base').Count)"
"same:$((LocalSame $lr $ca $cb @('a.ts')) -and -not (LocalSame $lr $ca $cc @('a.ts')) -and $null -eq (LocalSame $lr $ca ('0' * 40) @('a.ts')))"
$r = @{}; $p = Canned @(); $memo["projects/$p/repository/compare?from=stg&to=main&straight=true"] = [pscustomobject]@{ diffs = @(); compare_timeout = $true }
"capped:$(-not (ContentOn $p $mr 'F' 'stg'))"
'@
Expect-Each (Invoke-PsTest 'deployed-refs' $t @($Q)) 'deployed: # (squash deploy MR, other deploy MR, git host down, host up, local checkout ancestry, local same content, capped compare)' 'squash', 'other', 'down', 'up', 'local', 'same', 'capped'
# a monorepo target (paths, else ssh.subdir) is N/A for an MR outside it: no ssh, not NOT-DEPLOYED, exit 0
& $J @{ repos = @(@{ name = 'py'; deploys = @(@{ target = 'mc'; ssh = @{ host = 'h1'; subdir = 'mcp/' } }, @{ target = 'pm'; ssh = @{ host = 'h2'; subdir = 'pm' } }, @{ target = 'px'; paths = @('pm/*.py'); ssh = @{ host = 'h3' } }) }) } $kl
Set-Content "$(Kd)/na.ps1" @'
. $args[0]; $global:hosts = @(); function ssh { $global:hosts += $args[-2]; 'HEAD=abc1234 2026-01-02'; 'ANC=yes'; 'RC=0'; 'FILES=1' }
function Invoke-HostApi($p) { switch -Wildcard ($p) { '*requests/5' { @{ iid = 5; state = 'merged'; sha = 'F'; merged_at = '2026-01-02'; target_branch = 'main' } } '*requests/5/changes*' { @{ changes = @(@{ new_path = 'pm/a.py'; old_path = 'pm/a.py' }); overflow = [bool]$env:NA_OVF } } } }
"glob:$((Test-DeployTouched @{ paths = @('b/**') } @('b/x/y.ts')) -and -not (Test-DeployTouched @{ ssh = @{ subdir = 'mcp' } } @('mcpx/a.py')) -and (Test-DeployTouched @{ } @('z')))"
Invoke-Deployed -Mrs 'py!5' -Json -Target "$env:NA_TGT"   # exits
'@
$na = Px "$(Kd)/na.ps1" $Q 2>&1 | Out-String; $nac = $LASTEXITCODE; $nr = @(($na -replace '(?s)^.*?(\[.*\]).*$', '$1') | ConvertFrom-Json)
Expect "deployed: an MR outside a target's paths / ssh.subdir is N/A there (no ssh), exit 0 ($nac)" ($na -match 'glob:True' -and $nac -eq 0 -and ($nr | Where-Object target -eq 'mc').state -eq 'N/A' -and
  ($nr | Where-Object target -eq 'mc').detail -match 'n/a for mc: changes nothing under mcp/\*\*' -and ($nr | Where-Object target -eq 'pm').state -eq 'DEPLOYED' -and ($nr | Where-Object target -eq 'px').state -eq 'DEPLOYED')
$env:NA_OVF = '1'; $no = Px "$(Kd)/na.ps1" $Q 2>&1 | Out-String; Remove-Item Env:NA_OVF; $nor = @(($no -replace '(?s)^.*?(\[.*\]).*$', '$1') | ConvertFrom-Json)
Expect 'deployed: a partial change list (overflow) never makes a target N/A' (($nor | Where-Object target -eq 'mc').state -eq 'DEPLOYED')
Expect 'deployed: every row carries the MR target branch (deploy plan: no feeds lookup per MR)' (@($nr).Count -ge 3 -and -not @($nr | Where-Object branch -ne 'main').Count)
$env:NA_TGT = 'mc,px'; $nt = Px "$(Kd)/na.ps1" $Q 2>&1 | Out-String; Remove-Item Env:NA_TGT; $ntr = @(($nt -replace '(?s)^.*?(\[.*\]).*$', '$1') | ConvertFrom-Json)
$dcs = Get-Content (Join-Path $k 'skills/pokey/adapters/deployed_checks.ps1') -Raw; $chU = @([regex]::Matches($dcs, 'merge_requests/\$\(?[\w.]+\)?/changes[^"]*') | ForEach-Object { $_.Value -replace '\$\(?[\w.]+\)?', 'I' } | Select-Object -Unique)
Expect "deployed: -Target takes a list (deploy plan: one run per repo); the paths filter and the content check share one change-list call ($(@($ntr.target) -join ',') | $($chU -join ' '))" ((@($ntr.target) -join ',') -eq 'mc,px' -and $chU.Count -eq 1)
# deploys[].serves: an app env's check (-Target <app env>) covers the service hosts that back it; none -> NO-TARGET names serves
& $J @{ repos = @(@{ name = 'py'; deploys = @(@{ target = 'mc'; ssh = @{ host = 'h1'; subdir = 'mcp/' } }, @{ target = 'pm'; serves = @('app-stg'); ssh = @{ host = 'h2'; subdir = 'pm' } }) }) } $kl
$env:NA_TGT = 'app-stg'; $sv = Px "$(Kd)/na.ps1" $Q 2>&1 | Out-String; $env:NA_TGT = 'nope'; $sn = Px "$(Kd)/na.ps1" $Q 2>&1 | Out-String; Remove-Item Env:NA_TGT
$svr = @(($sv -replace '(?s)^.*?(\[.*\]|\{.*\}).*$', '$1') | ConvertFrom-Json); $snr = @(($sn -replace '(?s)^.*?(\[.*\]|\{.*\}).*$', '$1') | ConvertFrom-Json)   # one row: an object
Expect "deployed: -Target <app env> checks the deploys[] entries that serve it; none -> NO-TARGET naming deploys[].serves ($(@($svr.target) -join ','))" ((@($svr.target) -join ',') -eq 'pm' -and $svr[0].state -eq 'DEPLOYED' -and $snr[0].state -eq 'NO-TARGET' -and $snr[0].detail -match 'no deploys\[\] entry of py has target or serves nope.*deploys\[\]\.serves')
# ssh.shaFile (a CI deploy's record of the commit it installed): live = the merge is its ancestor, even when the host checkout is unreadable
& $J @{ repos = @(@{ name = 'py'; deploys = @(@{ target = 'sf'; branch = 'stage/py'; ssh = @{ host = 'h1'; shaFile = '/opt/a/deployed.sha' } }, @{ target = 'fx'; from = @('release'); ssh = @{ host = 'h2' } }) }) } $kl
Set-Content "$(Kd)/sf.ps1" @'
. $args[0]; function ssh { $x = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($args[-1] -split ' ')[1])); if ($x -match "cat '/opt/a/deployed\.sha'") { "DSHA=$env:SF_SHA" }; 'HEAD= '; 'ANC=no'; 'RC=2'; 'DIFF=cannot cd' }
function Invoke-HostApi($p) { switch -Wildcard ($p) { '*requests/5' { @{ iid = 5; state = 'merged'; sha = 'f' * 40; merged_at = '2026-01-02'; target_branch = 'main' } } '*requests/5/changes*' { @{ changes = @() } } '*commits/stage%2Fpy' { @{ id = 'b' * 40 } } '*merge_base*' { @{ id = $(if ($p -match 'refs\[\]=d{7}') { 'f' * 40 } elseif ($p -notmatch 'c{40}') { 'x' }) } } } }
Invoke-Deployed -Mrs 'py!5' -Json
'@
$all = foreach ($v in ('d' * 40), ('e' * 40), '', 'ddddddd main', ('c' * 40)) { $env:SF_SHA = $v; $o = Px "$(Kd)/sf.ps1" $Q 2>&1 | Out-String; , @(($o -replace '(?s)^.*?(\[.*\]).*$', '$1') | ConvertFrom-Json) }; Remove-Item Env:SF_SHA
$sf = @($all | ForEach-Object { @($_ | Where-Object target -eq 'sf')[0] }); $fx = @($all[0] | Where-Object target -eq 'fx')[0]
Expect "deployed ssh.shaFile: holds the merge (branch ahead: pending), lacks it, none, a short sha + text, host silent = UNKNOWN ($(@($sf.state) -join ','))" ((@($sf.state) -join ',') -eq 'DEPLOYED,NOT-DEPLOYED,UNKNOWN,DEPLOYED,UNKNOWN' -and $sf[4].detail -match 'git host did not answer' -and
  $sf[0].detail -match 'deployed commit dddddddd \(/opt/a/deployed\.sha\) holds ffffffff; stage/py is at bbbbbbbb: a deploy pending or failed' -and $sf[2].detail -match 'no commit in /opt/a/deployed\.sha on h1')
Expect "deployed: a target whose from lacks the MR's branch is N/A before any probe ($($fx.state): $($fx.detail))" ($fx.state -eq 'N/A' -and $fx.detail -match 'merged into main, not release')
Remove-TestKit $k
Complete-Tests
