#Requires -Version 7
# tests.ps1 (goody api-auth): cookie + CSRF, refresh token, query key, command signer through pokey.ps1 api (auth none, login: core tests).
# Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'
$api = Start-TestApi; $P = $api.port
$T = { param($a) @{ api = "http://127.0.0.1:$P"; auth = $a; users = @{ admin = 'u', 'K9' } } }; $L = @{ path = '/login'; body = @{} }
& $J @{ targets = @{ tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tr = & $T ($L + @{ type = 'login'; refreshField = 'refresh_token' }); tq = & $T @{ type = 'query'; param = 'api_key' }
  th = & $T @{ type = 'command'; cmd = 'echo X-Sig: s1' } } } (Join-Path $k 'skills/pokey/targets.local.json') 6
$ok = foreach ($x in 'tc/c', 'tr/b', 'tq/q', 'th/h') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
Expect "api auth kinds ($ok)" (@($ok).Count -eq 4 -and (Get-Content "$(Kd)/A1-C1_01_tq.json" -Raw) -match 'api_key=\[redacted\]')
$api.proc.Kill()
Remove-TestKit $k
Complete-Tests
