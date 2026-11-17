#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/api-auth.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/api-auth.tests.ps1: cookie + CSRF, refresh token, query key, command signer through pokey.ps1 api (auth none, login: core tests).
# Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/pokey/adapters/api_auth.ps1')   # copied into every New-TestKit kit
$k = New-TestKit qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'
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
# a local auth kind: an adapters/*.local.ps1 registers api-auth <type> (verb invoke); an unregistered type is refused
$tjf = Join-Path $k 'skills/pokey/targets.local.json'; $tj = Get-Content $tjf -Raw | ConvertFrom-Json -AsHashtable; $tj.targets.tx = & $T @{ type = 'vendorx' }; & $J $tj $tjf 6
$xo1 = Px $Q api -Target tx -Path '/l' 2>&1 | Out-String
Set-Content (Join-Path $k 'skills/pokey/adapters/x.local.ps1') "Register-KitAdapter api-auth vendorx @{ invoke = { param(`$a) `"VX `$(`$a.Target) `$(`$a.As) `$(`$a.Path)`" } }"
$xo2 = Px $Q api -Target tx -Path '/l' 2>&1 | Out-String
Expect "api: a local api-auth adapter handles its auth.type; none registered -> refused naming the kinds ($($xo2.Trim()))" ($xo1 -match "auth.type 'vendorx' unknown" -and $xo2.Trim() -eq 'VX tx admin /l')
$api.proc.Kill()
Remove-TestKit $k
Complete-Tests
