#Requires -Version 7
# tests.ps1 (extra api-auth): cookie + CSRF, refresh token, query key, command signer through qa.ps1 api. Next to <kit>/tests/harness.ps1.
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
$srv = Start-Process node -ArgumentList $sv, $P, $s1 -PassThru -NoNewWindow; Start-Sleep 1
$T = { param($a, $sub) @{ api = "http://127.0.0.1:$P$sub"; auth = $a; users = @{ admin = 'u', 'K9' }; defaultTenant = 'acme' } }; $L = @{ path = '/login'; body = @{} }
& $J @{ targets = @{ tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tr = & $T ($L + @{ type = 'login'; refreshField = 'refresh_token' }); tq = & $T @{ type = 'query'; param = 'api_key' }
  tt = & $T @{ type = 'none' } '/t/{tenant}'; th = & $T @{ type = 'command'; cmd = 'echo X-Sig: s1' } } } (Join-Path $k 'skills/qa-kit/targets.local.json') 6
$ok = foreach ($x in 'tc/c', 'tr/b', 'tq/q', 'tt/x', 'th/h') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
Expect "api auth kinds ($ok)" (@($ok).Count -eq 5 -and (Get-Content "$(Kd)/A1-C1_01_tq.json" -Raw) -match 'api_key=\[redacted\]')
Expect 'api -ContentType is sent' ((Px $Q api -Target tt -Method POST -Path '/ct' -Body 'hi' -ContentType text/plain 2>&1) -match 'HTTP 200')
$srv.Kill()
Remove-TestKit $k
Complete-Tests
