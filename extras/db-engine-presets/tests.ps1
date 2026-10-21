#Requires -Version 7
<#
tests.ps1 (extra db-engine-presets): db.engine aliases + presets fill unset hooks.
Usage: kittool.py extra test db-engine-presets (needs the extra local-env installed). Exit codes: 0 pass · 1 fail.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kittool.py extra test: the kit's harness; New-TestKit adds this extra's files
$k2 = New-TestKit le2; $L2 = Join-Path $k2 'skills/local-env/localenv.ps1'
# localenv.ps1 is the extra local-env: from the kit, else nothing to test
if (-not (Test-Path (Join-Path $src 'skills/local-env/localenv.ps1'))) { 'SKIP db-engine-presets (needs the extra local-env)'; Remove-TestKit $k2; Complete-Tests }
Copy-Item (Join-Path $src 'skills/local-env/localenv.ps1') (Split-Path $L2)
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ engine = 'PostgreSQL'; name = 'shop'; user = 'u' } } } } } (Join-Path $k2 'skills/dev-kit/kit.local.json') 6
Expect 'localenv: db.engine aliases + presets fill unset hooks' ((& { . $L2; "$($script:LE.envs.shop.db.engine) $($script:LE.envs.shop.db.snapshot)" }) -match '^postgres pg_dump -Fc -h 127\.0\.0\.1 -p 5432 -U u -f .+\.dump\" shop$')
Remove-TestKit $k2
Complete-Tests
