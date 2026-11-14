#Requires -Version 7
<#
crafty-config.tests.ps1: crafty.ps1 stack / check config: -Touched, .claude-stack.json, switches (stack.presets, tests.fallbackRunner, protectedBranchesBase, linkDefaults, guard.heavyPatterns / e2ePatterns).
Usage: pwsh -NoProfile -File <kit>/tests/crafty-config.tests.ps1 (or tests/kit-tests.ps1 -Area crafty-config).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit config; $D = Join-Path $k 'skills/crafty/crafty.ps1'
$dkl = "$k/skills/crafty/kit.local.json"
$tr = Join-Path (Kd) 'touched-repo'; New-Item -ItemType Directory -Force "$tr/src" | Out-Null; '{ "stack": "custom", "commands": { "test": "node -e 0" } }' | Set-Content "$tr/.claude-stack.json"
'x' | Set-Content "$tr/src/Audit.spec.ts"; Save-GitRepo $tr i; 'x' | Set-Content "$tr/src/Audit.ts"
$out = pwsh @np $D check -Dir $tr -Step test -Touched 2>&1 | Out-String
Expect 'check -Touched: Audit.ts is no test (case-sensitive Test suffix); its spec runs' ($out -match '-Touched: 1 test\(s\) for 1 changed file\(s\): src/Audit\.spec\.ts')
$sd = Join-Path (Kd) 'stack-only'; New-Item -ItemType Directory -Force $sd | Out-Null; '{ "stack": "custom", "commands": { "compile": "echo ok" } }' | Set-Content "$sd/.claude-stack.json"
$out = pwsh @np $D stack -Dir $sd 2>&1 | Out-String
Expect 'stack: a .claude-stack.json alone names the stack' ($out -match 'stack: custom' -and $out -notmatch 'FAILED')   # in-process: git's exit code leaks
# config switches: stack.presets, tests.fallbackRunner, protectedBranchesBase (legacy list), linkDefaults, guard.heavyPatterns / e2ePatterns
$gd = Join-Path (Kd) 'go-only'; New-Item -ItemType Directory -Force $gd | Out-Null; 'module x' | Set-Content "$gd/go.mod"
$td = Join-Path (Kd) 'ts-only'; New-Item -ItemType Directory -Force $td | Out-Null; '{ "name": "x", "devDependencies": { "typescript": "5" } }' | Set-Content "$td/package.json"; '{}' | Set-Content "$td/tsconfig.json"
$sw = @'
$env:KIT_TRACKER_TYPE = 'none'; $D, $gd, $td = $args
$st = try { (& $D stack -Dir $gd -Json | ConvertFrom-Json).stack } catch { 'none' }; if (-not $st) { $st = 'none' }
$tt = (& $D stack -Dir $td -Json | ConvertFrom-Json).commands.test
. $D; $kr = Get-KitKeepBranchRx $gd
"stack=$st|spec=$(if (-not $tt) { 'null' } else { $tt })|keep=$('main' -match $kr),$('staging/x' -match $kr),$('critical/a' -match $kr)|links=$(@(Get-DepLinkDefaults | ForEach-Object dir) -join '+')"
'@
$swf = Join-Path (Kd) 'switches.ps1'; Set-Content $swf $sw -Encoding utf8
$spa = "$k/skills/crafty/adapters/stack_presets.ps1"; $spNew = -not (Test-Path $spa); if ($spNew) { New-Item -ItemType Directory -Force (Split-Path $spa) | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/crafty/adapters/stack_presets.ps1') $spa }
$dk1 = if (Test-Path $dkl) { Get-Content $dkl -Raw }
if (Test-Path $dkl) { Remove-Item $dkl }; $s0 = "$(pwsh @np $swf $D $gd $td 2>&1)"
Set-JsonFile $dkl @{ stack = @{ presets = @() }; tests = @{ fallbackRunner = 'none' }; linkDefaults = @(); guard = @{ heavyPatterns = @('\bbazel\s+(build|test)\b'); e2ePatterns = @('\btestcafe\b') }
  protectedBranchesBase = @('main', 'master', 'develop', 'release/*', 'staging', 'staging/*', 'production', 'production/*', 'prod/*', 'hotfix/*', 'critical/*') }
$s1 = "$(pwsh @np $swf $D $gd $td 2>&1)"
$gj = { param($c) @{ tool_name = 'Bash'; cwd = $gd; tool_input = @{ command = $c } } | ConvertTo-Json -Compress }
$hb = (pwsh @np $D guard -Json (& $gj 'bazel build //app') 2>&1) -join '' -match 'memory gate'; $he = (pwsh @np $D guard -Json (& $gj 'npx testcafe chrome t.js') 2>&1) -join '' -match 'e2e runs go through'
Set-JsonFile $dkl @{ stack = @{ presets = @('presets') }; tests = @{ fallbackRunner = 'npx mocha {tests}' } }; $s2 = "$(pwsh @np $swf $D $gd $td 2>&1)"
if ($dk1) { $dk1 | Set-Content $dkl } else { Remove-Item $dkl }
$hn = (pwsh @np $D guard -Json (& $gj 'bazel build //app') 2>&1) -join '' -match 'memory gate'; if ($spNew) { Remove-Item $spa }
Expect "config switches: unset = presets on, spec.mjs, base main/master/develop/release, node_modules+.venv; set = presets off, no fallback, the legacy branch list, no links, guard extras deny ($s0 | $s1 | $s2 | $hb $he $hn)" (
  $s0 -match '^stack=go\|spec=node .*spec\.mjs.* \{tests\}\|keep=True,False,False\|links=node_modules\+\.venv$' -and $s1 -match '^stack=none\|spec=null\|keep=True,True,True\|links=( .*no preset detects|$)' -and
  $s2 -match '^stack=go\|spec=npx mocha \{tests\}' -and $hb -and $he -and -not $hn)
Remove-TestKit $k
Complete-Tests
