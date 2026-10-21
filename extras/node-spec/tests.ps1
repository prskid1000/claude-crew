#Requires -Version 7
<#
tests.ps1 (extra node-spec): spec.mjs without the project's esbuild exits 2 and says why; --help prints its header.
Usage: pwsh -NoProfile -File extras/node-spec/tests.ps1 -Kit <kit> (spec.mjs comes from files/ beside this file).
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
. (Join-Path $Kit 'tests/harness.ps1')
$k = New-TestKit node-spec   # spec.mjs finds kit.example.json two folders up
Copy-Item (Join-Path $PSScriptRoot 'files/skills/dev-kit/spec.mjs') (Join-Path $k 'skills/dev-kit')
$spec = Join-Path $k 'skills/dev-kit/spec.mjs'
$proj = Join-Path ([IO.Path]::GetTempPath()) "node-spec-test-$PID"
New-Item -ItemType Directory -Force (Join-Path $proj 'src') | Out-Null
'{ "name": "p", "devDependencies": { "typescript": "5" } }' | Set-Content (Join-Path $proj 'package.json')
'{ "compilerOptions": {} }' | Set-Content (Join-Path $proj 'tsconfig.json')
"describe('a', () => it('b', () => expect(1).toBe(1)))" | Set-Content (Join-Path $proj 'src/a.spec.ts')
$out = node $spec --dir $proj a.spec 2>&1 | Out-String
Expect 'spec.mjs: no esbuild -> exit 2 with the reason' ($LASTEXITCODE -eq 2 -and $out -match 'no esbuild')
$out = node $spec --help 2>&1 | Out-String
Expect 'spec.mjs --help prints its header' ($LASTEXITCODE -eq 0 -and $out -match 'Exit codes')
Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue; Remove-TestKit $k
Complete-Tests
