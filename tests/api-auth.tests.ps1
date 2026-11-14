#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/api-auth.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/api-auth.tests.ps1: cookie + CSRF, refresh token, query key, command signer through pokey.ps1 api (auth none, login: core tests).
# Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/pokey/adapters/api_auth.ps1')   # copied into every New-TestKit kit
$k = New-TestKit qa; $Q = Join-Path $k 'skills/pokey/pokey.ps1'
$api = Start-TestApi; $P = $api.port
$T = { param($a) @{ api = "http://127.0.0.1:$P"; auth = $a; users = @{ admin = 'u', 'K9' } } }; $L = @{ path = '/login'; body = @{} }
& $J @{ targets = @{ tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tr = & $T ($L + @{ type = 'login'; refreshField = 'refresh_token' }); tq = & $T @{ type = 'query'; param = 'api_key' }
  th = & $T @{ type = 'command'; cmd = 'echo X-Sig: s1' } } } (Join-Path $k 'skills/pokey/targets.local.json') 6
$ok = foreach ($x in 'tc/c', 'tr/b', 'tq/q', 'th/h') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
Expect "api auth kinds ($ok)" (@($ok).Count -eq 4 -and (Get-Content "$(Kd)/A1-C1_01_tq.json" -Raw) -match 'api_key=\[redacted\]')
$nu = Px $Q api -Target tq -As ghost -Path '/q' 2>&1 | Out-String; $nuc = $LASTEXITCODE
Expect 'api (api_auth.ps1 auth kind): a user missing from the target exits 2 NO-USER, no stack trace' ($nuc -eq 2 -and $nu -match "NO-USER 'ghost' in target tq" -and $nu -notmatch 'Exception|at line')
$api.proc.Kill()
Remove-TestKit $k
Complete-Tests
