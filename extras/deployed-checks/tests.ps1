#Requires -Version 7
# tests.ps1 (extra deployed-checks): probe cmd / url / tag / regex and the ssh script. Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qa; $Q = Join-Path $k 'skills/qa-kit/qa.ps1'; $np = @('-NoProfile', '-File'); $kl = Join-Path $k 'skills/dev-kit/kit.local.json'
$gr = Join-Path (Kd) 'pr'; git init -q $gr; git -C $gr commit -qm a --allow-empty; git -C $gr tag v1; $s1 = git -C $gr rev-parse HEAD; git -C $gr commit -qm b --allow-empty; $s2 = git -C $gr rev-parse HEAD
$sv = "$(Kd)/s.cjs"; $P = 18000 + $PID % 1000
Set-Content $sv @'
require('http').createServer((q, s) => { let b = ''; q.on('data', (d) => b += d); q.on('end', () => {
  const u = q.url, h = q.headers, j = (o, st = 200, hd = {}) => { s.writeHead(st, { 'content-type': 'application/json', ...hd }); s.end(JSON.stringify(o)) }
  if (u === '/login') return /R1/.test(b) ? j({ access_token: 'A2' }) : j({ access_token: 'A1', refresh_token: 'R1' }, 200, { 'set-cookie': ['sid=1', 'XSRF-TOKEN=x1'] })
  const ok = { '/c': h.cookie && h['x-xsrf-token'] === 'x1', '/b': h.authorization === 'Bearer A2', '/q?api_key=K9': 1, '/t/acme/x': 1, '/t/acme/ct': h['content-type'] === 'text/plain', '/h': h['x-sig'] === 's1' }[u]
  u === '/v' ? j({ v: { sha: process.argv[3] } }) : j({}, ok ? 200 : 401) }) }).listen(+process.argv[2], '127.0.0.1')
'@
$srv = Start-Process node -ArgumentList $sv, $P, $s1 -PassThru -NoNewWindow; Start-Sleep 1   # the probe url target
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
'{"repos":[{"name":"web","deploys":[{"target":"stg","branch":"staging","job":"deploy-*"}]}]}' | Set-Content $kl
$srv = Start-Process node -ArgumentList $sv, $P, $s1 -PassThru -NoNewWindow; Start-Sleep 1   # the url probe's server
$res = @(Px "$(Kd)/dp.ps1" $Q $gr $s1 $s2 "http://127.0.0.1:$P/v" 2>&1); $srv.Kill(); Remove-Item $kl
foreach ($x in 'cmd', 'url', 'tag', 'ssh', 'rx') { Expect "deployed: $x probe" (@($res) -contains "${x}:True") }
Expect 'deployed: a wildcard job matches a matrix job' ("$res" -match 'DEPLOYED\s+web!5')
Remove-TestKit $k
Complete-Tests
