#Requires -Version 7
# Tests of the extra ts-typecheck: a huge tsc baseline is UNRUN, an error in a changed file fails. Run: kittool.py extra test ts-typecheck
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit ts; $D = Join-Path $k 'skills/dev-kit/dev.ps1'
$ud = Join-Path (Kd) 'ts-repo'; New-Item -ItemType Directory -Force "$ud/src" | Out-Null
'{ "name": "x" }' | Set-Content "$ud/package.json"; '{ "stack": "custom", "commands": { "typecheck": "node tsc.js" } }' | Set-Content "$ud/.claude-stack.json"
'for (let i = 0; i < 250; i++) console.log(`src/old${i}.ts(1,1): error TS2322: x`); if (require("fs").existsSync("src/new.ts")) console.log("src/new.ts(2,3): error TS2304: y"); process.exit(2)' | Set-Content "$ud/tsc.js"
git -C $ud init -q; git -C $ud add -A; git -C $ud -c user.name=t -c user.email=t@t commit -q -m init
$out = pwsh @np $D check -Dir $ud -Step typecheck 2>&1 | Out-String; $c1 = $LASTEXITCODE
'let a = b' | Set-Content "$ud/src/new.ts"
$out2 = pwsh @np $D check -Dir $ud -Step typecheck 2>&1 | Out-String; $c2 = $LASTEXITCODE
Expect "ts-typecheck: > 200 baseline errors = UNRUN, exit 5 ($c1)" ($c1 -eq 5 -and $out -match 'UNRUN' -and $out -match 'BASELINE: 250 errors')
Expect "ts-typecheck: an error in a changed file fails, the baseline does not ($c2)" ($c2 -eq 1 -and $out2 -match 'src/new\.ts\(2,3\)' -and $out2 -match '1 errors in your changed files')
Remove-TestKit $k
Complete-Tests
