#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/api-auth.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/api-auth.tests.ps1: cookie + CSRF, refresh token, query key, command signer through pokey.ps1 api (auth none, login: core tests).
# Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/pokey/adapters/api_auth.ps1')   # copied into every New-TestKit kit
$k = New-TestKit qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'
# pokey api: api GET /x binds the method; a second positional otherwise is an error, not a missing -Path (moved from flow.tests: room; before any targets file)
$pa = Px $Q api GET '/x' -Target nosuch 2>&1 | Out-String; $pb = Px $Q api '/x' '/y' -Target nosuch 2>&1 | Out-String
Expect "pokey api: <METHOD> <path> positional (reaches the targets file), a second path refused" ($pa -notmatch 'positional parameter|missing -Path' -and $pa -match 'targets\.local\.json' -and $pb -match "a second positional '/y'")
$api = Start-TestApi; $P = $api.port
# K63h: an OS-picked port per server (two at once differ) and ready on return (no sleep)
$api2 = Start-TestApi; $taUp = $null; try { $taUp = (Invoke-WebRequest "http://127.0.0.1:$($api2.port)/v" -TimeoutSec 5).StatusCode } catch { }; $api2.proc.Kill()
Expect "Start-TestApi: two servers get different free ports, each answers at once ($P / $($api2.port): $taUp)" ($P -ne $api2.port -and $taUp -eq 200)
$T = { param($a) @{ api = "http://127.0.0.1:$P"; auth = $a; users = @{ admin = 'u', 'K9' } } }; $L = @{ path = '/login'; body = @{} }
$two = & $T ($L + @{ type = 'login'; tokenField = 'access_token' }); $two.users = @{ admin = 'u', 'K9'; viewer = 'v', 'K8' }
$twoD = & $T ($L + @{ type = 'login'; tokenField = 'access_token' }); $twoD.users = $two.users; $twoD.defaultUser = 'viewer'
& $J @{ targets = @{ tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tr = & $T ($L + @{ type = 'login'; tokenField = 'access_token'; refreshField = 'refresh_token' }); tq = & $T @{ type = 'query'; param = 'api_key' }
  th = & $T @{ type = 'command'; cmd = 'echo X-Sig: s1' }; tn = & $T ($L + @{ type = 'login' }); tp = & $T ($L + @{ preset = 'oauth2' }); t2 = $two; t2d = $twoD } } (Join-Path $k 'skills/pokey/targets.local.json') 6
$ok = foreach ($x in 'tc/c', 'tr/b', 'tq/q', 'th/h') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
Expect "api auth kinds ($ok)" (@($ok).Count -eq 4 -and (Get-Content "$(Kd)/A1-C1_01_tq.json" -Raw) -match 'api_key=\[redacted\]')
# token field: no vendor fallback; auth.tokenField, auth.preset or kit api.tokenFields
$tn1 = Px $Q api -Target tn -Path '/l' 2>&1 | Out-String; $tp1 = Px $Q api -Target tp -Path '/l' 2>&1 | Out-String
$kl = Join-Path $k 'skills/crafty/kit.local.json'; '{"api":{"tokenFields":["id_token","access_token"]}}' | Set-Content $kl
$tn2 = Px $Q api -Target tn -Path '/l' 2>&1 | Out-String; Remove-Item $kl
Expect 'api login: no token field configured -> refused naming tokenField / preset; auth.preset oauth2 and kit api.tokenFields (in order) find it' ($tn1 -match 'no token field is set' -and $tn1 -match 'answer fields: access_token' -and $tp1 -match 'HTTP 200' -and $tn2 -match 'HTTP 200')
# default user: no 'admin' default; several users and none chosen -> exit 2; targets.<t>.defaultUser or one user picks it
$du1 = Px $Q api -Target t2 -Path '/l' 2>&1 | Out-String; $du1c = $LASTEXITCODE; $du2 = Px $Q api -Target t2d -Path '/l' 2>&1 | Out-String
$tokFiles = @(Get-ChildItem (TkPath $k tokens) -Filter 't2d-*' -ErrorAction SilentlyContinue).Name
Expect "api user: several users, none chosen -> exit 2 naming defaultUser; target defaultUser used ($du1c $tokFiles $($du1 -replace '\s+', ' '))" ($du1c -eq 2 -and $du1 -match 'several users and none is chosen' -and $du1 -match 'defaultUser' -and $du2 -match 'HTTP 200' -and "$tokFiles" -match 'viewer')
# -Anonymous: no user picked, no login (t2 has several users: no NO-USER stop); with -As refused
$an1 = Px $Q api -Target t2 -Path '/l' -Anonymous 2>&1 | Out-String; $an2 = Px $Q api -Target t2 -Path '/l' -Anonymous -As admin 2>&1 | Out-String
Expect "api -Anonymous: sent without a login (the test API answers 401); -As with it refused ($($an1.Trim() -replace '\s+', ' '))" ($an1 -match 'HTTP 401' -and $an1 -notmatch 'NO-USER|LOGIN' -and $an2 -match 'drop -As')
# a local auth kind: an adapters/*.local.ps1 registers api-auth <type> (verb invoke); an unregistered type is refused
$tjf = Join-Path $k 'skills/pokey/targets.local.json'; $tj = Get-Content $tjf -Raw | ConvertFrom-Json -AsHashtable; $tj.targets.tx = & $T @{ type = 'vendorx' }; & $J $tj $tjf 6
$xo1 = Px $Q api -Target tx -Path '/l' 2>&1 | Out-String
Set-Content (Join-Path $k 'skills/pokey/adapters/x.local.ps1') "Register-KitAdapter api-auth vendorx @{ invoke = { param(`$a) `"VX `$(`$a.Target) `$(`$a.As) `$(`$a.Path)`" } }"
$xo2 = Px $Q api -Target tx -Path '/l' 2>&1 | Out-String
Expect "api: a local api-auth adapter handles its auth.type; none registered -> refused naming the kinds ($($xo2.Trim()))" ($xo1 -match "auth.type 'vendorx' unknown" -and $xo2.Trim() -eq 'VX tx admin /l')
$api.proc.Kill()
# user create (owner 2026-11-21): a qa.userRecipes recipe templated per role, password generated + stored, never printed; idempotent; api -As uses its tenant; deactivate
$us = Join-Path (Kd) 'us.cjs'; $usLog = Join-Path (Kd) 'us.log'; Set-Content $us @'
const fs = require('fs'), log = process.argv[3], emps = {}
require('http').createServer((q, s) => { let b = ''; q.on('data', (d) => b += d); q.on('end', () => {
  const j = (o, st = 200) => { s.writeHead(st, { 'content-type': 'application/json' }); s.end(JSON.stringify(o)) }, u = q.url
  fs.appendFileSync(log, JSON.stringify({ m: q.method, u, b }) + '\n')
  if (u === '/login') return j({ access_token: 'T-' + JSON.parse(b).t })
  if (u === '/admin/auth') return JSON.parse(b).t === 'adm' ? j({ sa_token: 'S-1' }) : j({ error: 'wrong tenant' }, 401)
  if (u === '/me' && q.headers.authorization === 'Bearer S-1') return j({ superAdmin: true })
  if (u.startsWith('/emp?login=')) return j(Object.values(emps).filter((e) => e.user.login === decodeURIComponent(u.slice(11))))
  if (u === '/emp' && q.method === 'POST' && /qa-bad/.test(b)) return j({ error: 'rejected ' + b }, 400)
  if (u === '/emp' && q.method === 'POST') { const x = JSON.parse(b); emps[x.login] = { id: 7, user: { login: x.login }, active: true }; return j({ id: 7 }, 201) }
  if (u === '/emp/7') return j(Object.values(emps)[0])
  if (u === '/emp' && q.method === 'PUT') return j(JSON.parse(b))
  j({}, u === '/me' ? 200 : 404) }) }).listen(+process.argv[2], '127.0.0.1')
'@
$uFp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $uFp.Start(); $uPort = $uFp.LocalEndpoint.Port; $uFp.Stop()
$uProc = Start-Process node -ArgumentList $us, $uPort, $usLog -PassThru -NoNewWindow; for ($ui = 0; $ui -lt 100; $ui++) { $uTc = [Net.Sockets.TcpClient]::new(); try { if ($uTc.ConnectAsync('127.0.0.1', $uPort).Wait(200) -and $uTc.Connected) { break } } catch { } finally { $uTc.Dispose() }; Start-Sleep -Milliseconds 100 }
$tjf = Join-Path $k 'skills/pokey/targets.local.json'
& $J @{ targets = @{ tu = @{ api = "http://127.0.0.1:$uPort"; defaultTenant = 'acme'; auth = @{ type = 'login'; path = '/login'; body = @{ u = '{user}'; p = '{pass}'; t = '{tenant}' }; tokenField = 'access_token' }; users = @{ admin = 'a', 'K9' } } } } $tjf 6
& $J @{ qa = @{ userRecipes = @{ r1 = @{ targets = '^tu$'; check = '/me'; roles = @{ driver = @{ roles = @('R_DRIVER') } }
  find = @{ path = '/emp?login={login}'; match = 'user.login'; save = @{ empId = 'id' } }
  create = @(@{ method = 'POST'; path = '/emp'; body = @{ login = '{login}'; password = '{password}'; roles = '{roles}'; email = '{email}'; note = 'for {tenant}' }; save = @{ empId = 'id' } })
  deactivate = @(@{ path = '/emp/{empId}'; name = 'e' }, @{ method = 'PUT'; path = '/emp'; from = 'e'; set = @{ active = $false } }) } } } } (Join-Path $k 'skills/crafty/kit.local.json') 8
$uc1 = Px $Q user create -Target tu -Name qa-drv -Role driver -As admin -Tenant t2 -Run r9 2>&1 | Out-String; $ucc = $LASTEXITCODE
$uRow = (Get-Content $tjf -Raw | ConvertFrom-Json).targets.tu; $uPw = [string]$uRow.users.'qa-drv'[1]
$uPost = @(Get-Content $usLog | ConvertFrom-Json | Where-Object { $_.m -eq 'POST' -and $_.u -eq '/emp' }); $uB = $uPost[0].b | ConvertFrom-Json
Expect "user create: CREATED, password generated (20, upper/lower/digit), stored, never printed; body templated (roles array, email, tenant); created.<login> keeps tenant, run, ids ($ucc)" ($ucc -eq 0 -and $uc1 -match 'CREATED qa-drv' -and $uc1 -match 'login check HTTP 200' -and $uc1 -match 'SETUP_CHANGE' -and $uPw.Length -eq 20 -and $uPw -match '^[A-Za-z]' -and $uPw -cmatch '[A-Z]' -and $uPw -cmatch '[a-z]' -and $uPw -match '\d' -and $uc1 -notmatch [regex]::Escape($uPw) -and $uB.password -eq $uPw -and @($uB.roles) -join ',' -eq 'R_DRIVER' -and $uB.email -eq 'qa-drv@example.invalid' -and $uB.note -eq 'for t2' -and $uRow.created.'qa-drv'.tenant -eq 't2' -and $uRow.created.'qa-drv'.run -eq 'r9' -and $uRow.created.'qa-drv'.ids.empId -eq 7)
$uc2 = Px $Q user create -Target tu -Name qa-drv -Role driver -As admin 2>&1 | Out-String; $uPw2 = [string](Get-Content $tjf -Raw | ConvertFrom-Json).targets.tu.users.'qa-drv'[1]
$uRole = Px $Q user create -Target tu -Name qa-x -Role boss -As admin 2>&1 | Out-String; $urc = $LASTEXITCODE
$uMe = Px $Q api -Target tu -As qa-drv -Path '/me' 2>&1 | Out-String; $uLs = Px $Q user list -Target tu 2>&1 | Out-String
$uLogin = @(Get-Content $usLog | ConvertFrom-Json | Where-Object { $_.u -eq '/login' } | ForEach-Object { ($_.b | ConvertFrom-Json).t })
Expect "user create again: EXISTS, one POST, same password; unknown role exit 2 naming roles; api -As uses the login's tenant; list names no password ($urc)" ($uc2 -match 'EXISTS qa-drv' -and @(Get-Content $usLog | Where-Object { $_ -match '"POST","u":"/emp"' }).Count -eq 1 -and $uPw2 -eq $uPw -and $urc -eq 2 -and $uRole -match 'driver' -and $uMe -match 'HTTP 200' -and $uLogin[-1] -eq 't2' -and $uLs -match 'qa-drv · created .* tenant t2 · role driver · run r9' -and $uLs -notmatch [regex]::Escape($uPw))
# retro 2026-11-23: user list on a lane name (<target>-<bird>) lists the base target's logins
$uLane = Px $Q user list -Target tu-kestrel 2>&1 | Out-String
Expect "user list -Target tu-kestrel: the base target's logins ($($uLane.Trim()))" ($uLane -match 'qa-drv · created .* tenant t2' -and $uLane -notmatch 'Unknown target')
# revy: a refused create (answer echoes the body) shows the error redacted and keeps no login; unknown -As names NO-USER; a login user create did not make is never deactivated
$uBad = Px $Q user create -Target tu -Name qa-bad -Role driver -As admin 2>&1 | Out-String; $ubc = $LASTEXITCODE; $uBadRow = (Get-Content $tjf -Raw | ConvertFrom-Json).targets.tu
$uNo = Px $Q user create -Target tu -Name qa-y -Role driver -As nosuch 2>&1 | Out-String; $uAd = Px $Q user deactivate -Target tu -Name admin -As admin 2>&1 | Out-String; $uadc = $LASTEXITCODE
Expect "user create refused: exit 1, HTTP 400 with the password [redacted], no users / created entry left; -As nosuch prints NO-USER; deactivate of a shared login REFUSED exit 2 ($ubc $uadc)" ($ubc -eq 1 -and $uBad -match 'HTTP 400' -and $uBad -match '\[redacted\]' -and $uBad -notmatch '"password":"[^\[]' -and -not $uBadRow.users.'qa-bad' -and -not $uBadRow.created.'qa-bad' -and $uNo -match "NO-USER 'nosuch'" -and $uadc -eq 2 -and $uAd -match 'REFUSED' -and $uBadRow.users.admin)
$ud1 = Px $Q user deactivate -Target tu -Name qa-drv -As admin 2>&1 | Out-String; $uPut = @(Get-Content $usLog | ConvertFrom-Json | Where-Object { $_.m -eq 'PUT' })[0].b | ConvertFrom-Json
$uRow2 = (Get-Content $tjf -Raw | ConvertFrom-Json).targets.tu
Expect "user deactivate: steps reuse the saved id (GET /emp/7, PUT from it + set), login removed from users, created.<login>.deactivated set" ($ud1 -match 'DEACTIVATED qa-drv' -and $uPut.active -eq $false -and $uPut.id -eq 7 -and -not $uRow2.users.'qa-drv' -and $uRow2.created.'qa-drv'.deactivated)
# userAuth.<user> (2026-11-21: a super admin logs in at its own endpoint + tenant): its fields over auth, its tenant; other users keep auth
$saTj = Get-Content $tjf -Raw | ConvertFrom-Json -AsHashtable; $saTj.targets.tu.users.sa = @('root', 'SaPw7'); $saTj.targets.tu.userAuth = @{ sa = @{ path = '/admin/auth'; tenant = 'adm'; tokenField = 'sa_token' } }; & $J $saTj $tjf 6
$saMe = Px $Q api -Target tu -As sa -Path '/me' -Save 'A1-C1_01_sa' -OutDir (Kd) 2>&1 | Out-String; $saAd = Px $Q api -Target tu -As admin -Path '/me' 2>&1 | Out-String
$saPost = @(Get-Content $usLog | ConvertFrom-Json | Where-Object { $_.u -eq '/admin/auth' })
Expect "api userAuth: the super admin logs in at its endpoint with its tenant (token field its own), the admin still at auth.path; no password printed" ($saMe -match 'HTTP 200' -and (Get-Content "$(Kd)/A1-C1_01_sa.json" -Raw) -match 'superAdmin' -and $saPost.Count -eq 1 -and ($saPost[0].b | ConvertFrom-Json).t -eq 'adm' -and $saAd -match 'HTTP 200' -and "$saMe$saAd" -notmatch 'SaPw7')
# login profiles: profiles.<name> = login + secret (a secrets.store name) + opaque fields (tenant one of them); not in users
$pfTj = Get-Content $tjf -Raw | ConvertFrom-Json -AsHashtable; $pfTj.targets.tu.users.p1 = @('p1', 'PfPw3'); $pfTj.targets.tu.profiles = @{ ops = @{ login = 'p1'; secret = 'targets/tu/p1/password'; fields = @{ tenant = 'zeta' } } }; & $J $pfTj $tjf 6
$pfMe = Px $Q api -Target tu -As ops -Path '/me' 2>&1 | Out-String
$pfLog = @(Get-Content $usLog | ConvertFrom-Json | Where-Object { $_.u -eq '/login' } | ForEach-Object { $_.b | ConvertFrom-Json } | Where-Object { $_.u -eq 'p1' })
Expect "api login profile: login + secret from the store + tenant field; no password printed ($($pfMe.Trim() -replace '\s+', ' '))" ($pfMe -match 'HTTP 200' -and $pfLog.Count -eq 1 -and $pfLog[0].p -eq 'PfPw3' -and $pfLog[0].t -eq 'zeta' -and $pfMe -notmatch 'PfPw3')
$uProc.Kill()
Remove-TestKit $k
Complete-Tests
