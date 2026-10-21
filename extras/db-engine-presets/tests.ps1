#Requires -Version 7
<#
tests.ps1 (extra db-engine-presets): db.engine aliases + presets fill unset hooks.
Usage: next to <kit>/tests/harness.ps1 after kittool.py extra add local-env db-engine-presets; pwsh -File it. Exit codes: 0 pass · 1 fail.
#>
param([string]$Kit)   # kittool.py extra test passes the kit; else this file sits next to <kit>/tests/harness.ps1
. $(if ($Kit) { Join-Path $Kit 'tests/harness.ps1' } else { Join-Path $PSScriptRoot 'harness.ps1' })
$k2 = New-TestKit le2; $L2 = Join-Path $k2 'skills/local-env/localenv.ps1'
# localenv.ps1 (extra local-env) and this adapter are not in the core test kit: copy them in
$ad = New-Item -ItemType Directory -Force (Join-Path $k2 'skills/local-env/adapters'); Copy-Item (Join-Path $src 'skills/local-env/localenv.ps1') (Split-Path $ad); Copy-Item (Join-Path $src 'skills/local-env/adapters/db_presets.ps1') $ad
& $J @{ localEnv = @{ envs = @{ shop = @{ services = @(); db = @{ engine = 'PostgreSQL'; name = 'shop'; user = 'u' } } } } } (Join-Path $k2 'skills/dev-kit/kit.local.json') 6
Expect 'localenv: db.engine aliases + presets fill unset hooks' ((& { . $L2; "$($script:LE.envs.shop.db.engine) $($script:LE.envs.shop.db.snapshot)" }) -match '^postgres pg_dump -Fc -h 127\.0\.0\.1 -p 5432 -U u -f .+\.dump\" shop$')
Remove-TestKit $k2
Complete-Tests
