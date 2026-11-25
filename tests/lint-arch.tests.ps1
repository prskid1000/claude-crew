#Requires -Version 7
<#
lint-arch.tests.ps1: kitbag.py lint ARCH-* rules (lint-vocab.json): DEFAULT, ENUM, VENDOR-API, PLATFORM, LESSON, DEAD-KEY, SBLOG (+ pwsh's own check, Get-KitMember / Get-KitProps / Get-KitHash); a hit and a
pass each, on a throw-away git copy of the kit (fixture scripts, a lesson, example keys).
Usage: pwsh -NoProfile -File <kit>/tests/lint-arch.tests.ps1 (or tests/kit-tests.ps1 -Area lint-arch).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$kc = New-GitKitCopy (Join-Path ([IO.Path]::GetTempPath()) "kit-arch-$PID"); $KT3 = Join-Path $kc 'skills/bossy/kitbag.py'
# fixture lines: the line number is the comment-free position in each here-string
$fx = @'
#Requires -Version 7
$a = Get-KitSetting 'zz.hit' 'gitlab'
$b = Get-KitSetting 'zz.pass' 'none'
$c = Get-KitSetting 'zz.kept' 'jira'   # arch-ok: fixture
$l = @('web', 'api', 'app')
$r = @('awsStack', 'laneApk', 'manual')   # registry: deploy-kind adapters
$v = glab api projects/1
$x = Get-CimInstance Win32_OperatingSystem
if ($KitIsWindows) {
  $y = Get-CimInstance Win32_OperatingSystem
}
# legacy-defaults:start
$z = Get-KitSetting 'zz.old' 'clickup'
# legacy-defaults:end
$live = Get-KitSetting 'zzLiveKey' $null
'@
Set-Content (Join-Path $kc 'skills/crafty/zz_arch.ps1') $fx -Encoding utf8
$fy = @'
import os
"""usage: glab api projects/1, os.startfile(x)"""
TAG = CFG.get('zzTag') or 'CU-'
def run(p):
    if os.name == 'nt':
        os.startfile(p)
    os.startfile(p)
'@
Set-Content (Join-Path $kc 'skills/crafty/zz_arch.py') $fy -Encoding utf8
Set-Content (Join-Path $kc 'skills/crafty/adapters/zz_arch.ps1') "#Requires -Version 7`n`$v = glab api projects/1`n`$l = @('web', 'api', 'app')" -Encoding utf8
# ARCH-SBLOG fixtures: a flagged word (a comment counts) and a computed member name; a quoted literal member and the exempt flagged.ps1 pass
Set-Content (Join-Path $kc 'skills/crafty/zz_sb.ps1') "#Requires -Version 7`n# loop the PSObject.Properties`n`$x = `$o.`$k`n`$y = `$o.'lit'" -Encoding utf8
# PS-MATH-INT (K57): an int literal first and a double side; a .Length side, a double literal, an [int] side and a comment pass
Set-Content (Join-Path $kc 'skills/crafty/zz_math.ps1') "#Requires -Version 7`n`$s = 'x@'`n`$a = [math]::Max(0, (`$t - `$u).TotalMinutes)`n`$b = [math]::Min(80, `$s.Length)`n`$c = [math]::Max(0.0, `$x / 2)`n`$d = [math]::Max(1, [int](`$x / 2))`n`$v = '@y'`n`$e = [math]::Max(0, [math]::Round(`$x))`n`$f = [math]::Max(0, [math]::Round(`$x, 1))`n# [math]::Max(0, 1.5)" -Encoding utf8
# inline pwsh text in a .py (a literal and a named constant) and a cdxml cmdlet are counted; a git -c pair passes
$sbPy = "import subprocess`nPS_ZZ = '''`$a = 1`n`$b = [Runtime.InteropServices.Marshal]'''`nsubprocess.run(['pwsh', '-EncodedCommand', PS_ZZ])`nsubprocess.run(['pwsh', '-Command', 'Get-NetTCPConnection'])`nsubprocess.run(['git', '-c', 'x.GetField=1'])`nsubprocess.run(['pwsh', '-Command', f'& {{ Add-Type {PS_ZZ} }}'])"
Set-Content (Join-Path $kc 'skills/crafty/zz_sbi.py') $sbPy -Encoding utf8
Set-Content (Join-Path $kc 'skills/crafty/zz_gitlab.ps1') "#Requires -Version 7`n`$a = Get-KitSetting 'zz.vendor' 'gitlab'" -Encoding utf8
Add-Content (Join-Path $kc 'LESSONS.md') "`n## zz`n- a migration fails -> run liquibase status first (it hides the lock)`n- shop-staging logins expire -> reseat (stale)`n- an Acme deploy waits -> ask (slow)`n- a kit lock is stale -> clear it (crash)`n- a non-prod lane waits -> retry (slow)" -Encoding utf8
$null = New-Item -ItemType Directory -Force (Join-Path $kc 'rules'); Set-Content (Join-Path $kc 'rules/zz.local.md') "# zz`nliquibase lock: release it" -Encoding utf8
# an org-only rule (kit.local.json localOnly + .git/info/exclude) may name its stack; a published one may not
foreach ($zr in 'zz-org', 'zz-pub') { Set-Content (Join-Path $kc "rules/$zr.md") "# $zr`nspring beans: inject by constructor" -Encoding utf8 }
& $J @{ localOnly = @('rules/zz-org.md'); orgTerms = @('Acme') } (Join-Path $kc 'skills/crafty/kit.local.json'); Add-Content (git -C $kc rev-parse --path-format=absolute --git-path info/exclude) '/rules/zz-org.md'
# ARCH-TEMP fixtures: OS temp in pwsh / python / node = a hit; Get-KitTemp, arch-ok, a guard self-test row, python importing kitbag pass
$ftp = @'
#Requires -Version 7
$a = [IO.Path]::GetTempPath()
$b = Get-KitTemp   # never $env:TEMP
$c = $env:TEMP   # arch-ok: an external tool's file
  @('B', 'cp body.md /tmp/w1-run/body.md', $false)
'@
Set-Content (Join-Path $kc 'skills/crafty/zz_tmp.ps1') $ftp -Encoding utf8
Set-Content (Join-Path $kc 'skills/crafty/zz_tmp.py') "import tempfile`nd = tempfile.mkdtemp()" -Encoding utf8
Set-Content (Join-Path $kc 'skills/crafty/zz_tmpk.py') "from kitbag import kit_path`nimport tempfile`nd = tempfile.mkdtemp()" -Encoding utf8
Set-Content (Join-Path $kc 'skills/crafty/zz_tmp.mjs') "import { tmpdir } from 'node:os'`nconst d = tmpdir()" -Encoding utf8
Set-Content (Join-Path $kc 'skills/crafty/zz_num.ps1') "`$a = New-KitId dec `$d`n`$b = New-KitId stale -Number   # NAME-NUMBER: a tie`n# New-KitId x in a comment" -Encoding utf8
$ex = Join-Path $kc 'skills/crafty/kit.example.json'; $t = [IO.File]::ReadAllText($ex)
[IO.File]::WriteAllText($ex, ($t -replace '(?s)^\{', "{`n `"zzDeadKey`": 1, `"zzLiveKey`": 2,"))
$l1 = & $py -X utf8 $KT3 lint --no-flow --warn 2>&1 | Out-String
$l0 = & $py -X utf8 $KT3 lint --no-flow 2>&1 | Out-String
Expect 'lint: standing warnings are one count line unless --warn lists them' ($l0 -notmatch 'WARN ARCH-ENUM' -and $l0 -match 'warning\(s\) not counted \(--warn lists them\)' -and $l1 -match 'WARN ARCH-ENUM')
$cnt = { param($rx) @([regex]::Matches($l1, $rx)).Count }
Expect "ARCH-DEFAULT: a vendor default is a problem with file:line; neutral, arch-ok, legacy block and vendor-named files pass" ($l1 -match '(?m)^ARCH-DEFAULT\s+skills/crafty/zz_arch\.ps1:2: zz\.hit: default names gitlab' -and
  $l1 -match '(?m)^ARCH-DEFAULT\s+skills/crafty/zz_arch\.py:3: zzTag: default names CU-' -and (& $cnt 'ARCH-DEFAULT\s+skills/crafty/zz_arch\.ps1') -eq 1 -and $l1 -notmatch 'ARCH-DEFAULT\s+skills/crafty/zz_gitlab')
Expect 'ARCH-ENUM: web/api/app in one file = WARN; a registry: comment and adapters/ pass' ($l1 -match 'WARN ARCH-ENUM\s+skills/crafty/zz_arch\.ps1:5: 3 lanes values' -and
  $l1 -notmatch 'deployKinds values \(awsStack:6' -and $l1 -notmatch 'ARCH-ENUM\s+skills/crafty/adapters/zz_arch')
Expect 'ARCH-VENDOR-API: glab api in core = a problem; adapters/ and a py docstring pass' ($l1 -match '(?m)^ARCH-VENDOR-API\s+skills/crafty/zz_arch\.ps1:7: vendor call "glab api' -and
  $l1 -notmatch 'ARCH-VENDOR-API\s+skills/crafty/(adapters/zz_arch|zz_arch\.py)')
Expect 'ARCH-PLATFORM: Get-CimInstance / os.startfile unguarded = a problem; inside if ($KitIsWindows) / os.name and a docstring pass' ($l1 -match '(?m)^ARCH-PLATFORM\s+skills/crafty/zz_arch\.ps1:8:' -and
  $l1 -notmatch 'ARCH-PLATFORM\s+skills/crafty/zz_arch\.ps1:10:' -and $l1 -match 'ARCH-PLATFORM\s+skills/crafty/zz_arch\.py:7:' -and $l1 -notmatch 'ARCH-PLATFORM\s+skills/crafty/zz_arch\.py:[26]:')
Expect 'ARCH-TEMP: GetTempPath / python tempfile without kitbag / node tmpdir() = a problem; Get-KitTemp, a comment, arch-ok, a guard self-test row, a kitbag importer pass' (
  $l1 -match '(?m)^ARCH-TEMP\s+skills/crafty/zz_tmp\.ps1:2: OS temp' -and $l1 -match '(?m)^ARCH-TEMP\s+skills/crafty/zz_tmp\.py:2:' -and $l1 -match '(?m)^ARCH-TEMP\s+skills/crafty/zz_tmp\.mjs:2:' -and
  (& $cnt 'ARCH-TEMP\s+skills/crafty/zz_tmp\.ps1') -eq 1 -and $l1 -notmatch 'ARCH-TEMP\s+skills/crafty/zz_tmpk\.py' -and (& $cnt '(?m)^ARCH-TEMP\s') -eq 3)
Expect 'LESSONS-ORG: a stack word, an env-shaped name and an orgTerm in LESSONS.md = 3 problems, the term never quoted; a kit lesson passes; ARCH-LESSON: a rules/*.local.md and a localOnly / excluded rule pass, a published rule fails' ((& $cnt '(?m)^LESSONS-ORG\s+LESSONS\.md:\d+') -eq 3 -and $l1 -notmatch 'LESSONS-ORG.*Acme' -and $l1 -notmatch 'ARCH-LESSON\s+LESSONS\.md' -and
  $l1 -notmatch 'ARCH-LESSON\s+rules/zz\.local\.md' -and $l1 -notmatch 'ARCH-LESSON\s+rules/zz-org\.md' -and $l1 -match '(?m)^ARCH-LESSON\s+rules/zz-pub\.md:\d+: names spring')
Expect "ARCH-DEAD-KEY: a documented key no script reads is a counted problem (exit $LASTEXITCODE); a read key passes" ($LASTEXITCODE -eq 1 -and
  $l1 -match '(?m)^ARCH-DEAD-KEY\s+skills/crafty/kit\.example\.json: "zzDeadKey"' -and $l1 -notmatch 'ARCH-DEAD-KEY.*zzLiveKey')
Expect 'ARCH-SBLOG: a flagged word (in a comment too) and $o.$k in skills/ are counted problems with file:line; a literal member and the exempt flagged.ps1 pass' ($l1 -match '(?m)^ARCH-SBLOG\s+skills/crafty/zz_sb\.ps1:2: "Properties"' -and
  $l1 -match '(?m)^ARCH-SBLOG\s+skills/crafty/zz_sb\.ps1:3: \$o\.\$k' -and (& $cnt 'ARCH-SBLOG\s+skills/crafty/zz_sb\.ps1') -eq 2 -and $l1 -notmatch 'ARCH-SBLOG\s+skills/crafty/flagged\.ps1')
Expect 'PS-MATH-INT: [math]::Max(0, <a double>) and Round(x, 1) are problems at their lines (between ''x@'' and ''@y'' strings); .Length, 0.0, [int], Round(x) and a comment pass' ($l1 -match '(?m)^PS-MATH-INT\s+skills/crafty/zz_math\.ps1:3:' -and $l1 -match '(?m)^PS-MATH-INT\s+skills/crafty/zz_math\.ps1:9:' -and (& $cnt 'PS-MATH-INT\s+skills/crafty/zz_math\.ps1') -eq 2)
Expect 'ARCH-SBLOG: inline -Command / -EncodedCommand text in a .py (literal or constant, at its line) and a cdxml cmdlet count; git -c passes' ($l1 -match '(?m)^ARCH-SBLOG\s+skills/crafty/zz_sbi\.py:3: "InteropServices"' -and
  $l1 -match '(?m)^ARCH-SBLOG\s+skills/crafty/zz_sbi\.py:5: "Get-NetTCPConnection": a cdxml' -and $l1 -match '(?m)^ARCH-SBLOG\s+skills/crafty/zz_sbi\.py:7: "Add-Type"' -and (& $cnt 'ARCH-SBLOG\s+skills/crafty/zz_sbi\.py') -eq 4)
# pwsh's own check (internal; absent on another version: SKIP): no lint-scoped kit script is logged on load
$sbCheck = [System.Management.Automation.ScriptBlock].GetMethod('CheckSuspiciousContent', [System.Reflection.BindingFlags]'NonPublic,Static')
$sbVoc = (Get-Content -Raw (Join-Path $PSScriptRoot '../skills/bossy/lint-vocab.json') | ConvertFrom-Json).sbLog
$sbHot = @(git -C (Join-Path $PSScriptRoot '..') ls-files 'skills/*.ps1' | Where-Object { $sf = $_; -not @($sbVoc.exempt | Where-Object { $sf.StartsWith($_) }).Count })
if ($sbCheck) {
  $sbHit = @(foreach ($sf in $sbHot) { $sa = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "../$sf"), [ref]$null, [ref]$null); if ($sh = $sbCheck.Invoke($null, @($sa))) { "$sf <- $(($sh -split "`n")[0])" } })
  Expect "pwsh script-block logging: none of the $($sbHot.Count) lint-scoped skills/ scripts is flagged ($($sbHit -join '; '))" ($sbHot.Count -gt 20 -and -not $sbHit.Count)
  $sbPyDir = Join-Path $PSScriptRoot '../skills/bossy'; $sbPyFiles = @(git -C (Join-Path $PSScriptRoot '..') ls-files 'skills/*.py' | ForEach-Object { Join-Path $PSScriptRoot "../$_" })
  $sbInline = @(& $py -X utf8 -c "import sys, json; sys.path.insert(0, sys.argv[1]); import kitbag; print(json.dumps([s for f in sys.argv[2:] for _, s in kitbag.sblog_inline(open(f, encoding='utf-8').read())]))" $sbPyDir @sbPyFiles | ConvertFrom-Json)
  $sbInHit = @(foreach ($st in $sbInline) { $sa = [System.Management.Automation.Language.Parser]::ParseInput($st, [ref]$null, [ref]$null); if ($sh = $sbCheck.Invoke($null, @($sa))) { "$($st.Substring(0, [Math]::Min(30, $st.Length))) <- $sh" } })
  Expect "pwsh script-block logging: none of the $($sbInline.Count) inline -Command texts in skills/*.py is flagged ($($sbInHit -join '; '))" (@($sbInline | Where-Object { $_.Length -gt 40 }).Count -ge 2 -and -not $sbInHit.Count)
} else { 'SKIP pwsh script-block check (no CheckSuspiciousContent on this pwsh)' }
# the helpers that replace $o.$k / .PSObject.Properties / inline hashing keep the old results
. (Join-Path $PSScriptRoot '../skills/crafty/lib.ps1')
$sbJ = '{"a":1,"b":[1,2],"c":[5],"d":[],"e":null,"arr":[{"x":1},{"y":2},{"x":3}]}' | ConvertFrom-Json; $sbH = @{ k = @(1) }; $sbArr = @([pscustomobject]@{ a = @(1, 2) }, [pscustomobject]@{ b = 1 }, [pscustomobject]@{ a = 7 })
$sbSame = @(foreach ($sc in @(@($sbJ, 'a'), @($sbJ, 'b'), @($sbJ, 'c'), @($sbJ, 'd'), @($sbJ, 'e'), @($sbJ, 'zz'), @($sbJ.arr, 'x'), @($sbArr, 'a'), @($sbH, 'k'), @($sbH, 'Count'), @($null, 'a'))) {
  $sn = $sc[1]; (ConvertTo-Json -InputObject @($sc[0].$sn) -Compress) -eq (ConvertTo-Json -InputObject @((Get-KitMember $sc[0] $sn)) -Compress) })
$sbP = [pscustomobject]@{ v = 1 }; Set-KitMember $sbP 'v' 5
Expect 'Get-KitMember = $o.$k (scalars, arrays, empty, null, member enumeration one level flat, hashtables); Set-KitMember; Get-KitProps = PSObject property order; Get-KitHash = SHA256 hex' (-not @($sbSame | Where-Object { -not $_ }).Count -and
  $sbP.v -eq 5 -and (@(Get-KitProps $sbJ).Name -join ',') -eq 'a,b,c,d,e,arr' -and -not @(Get-KitProps $null).Count -and (Get-KitHash 'abc') -eq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD' -and (Get-KitHash 'abc' MD5) -eq '900150983CD24FB0D6963F7D28E17F72')
Expect 'NAME-NUMBER: a counter name (New-KitId) is a problem at its line; a NAME-NUMBER: <why> line and a comment pass' ($l1 -match '(?m)^NAME-NUMBER\s+skills/crafty/zz_num\.ps1:1:' -and $l1 -notmatch 'zz_num\.ps1:[23]:')
# the one name normaliser, owner examples (2026-11-25): '<role>-<topic> · <plain words>'; jams split, a tie only on a clash, codes give way to topic words
$nrmIn = @(@('run', 'fix-ask-012', 'SHOP-ASK-012 cancel SO reason', ''), @('run', 'fix-ask011', 'ask catalogue create-only prompt', ''), @('run', 'aiedit-b', 'AI edit lost fields other types', ''),
  @('run', 'v2-wave3', 'Website v2 wave 3: payments, my account, events, fix round', 'buildy'), @('agent', 'devy-only-prompt', 'ask catalogue create-only prompt', ''), @('agent', 'devy-askimg', '-', ''), @('agent', 'devy-cartpick', '-', ''))
$nrm = @($nrmIn | ForEach-Object { "$(& $py -X utf8 $KT3 naming norm $_[0] $_[1] --topic $_[2] @(if ($_[3]) { '--role', $_[3] }) 2>&1)".Trim() }); $nTie = "$(& $py -X utf8 $KT3 naming norm run aiedit-b --live aiedit-a,aiedit-b 2>&1)".Trim()
$nWant = @('cancel-reason', 'ask-catalogue · create-only prompt', 'ai-edit · lost fields other types', 'buildy-payments · website my account, events, fix round',
  'devy-only-prompt · ask catalogue create', 'devy-ask-img', 'devy-cart-pick')   # the text never repeats a word of the id
$nChk = @(@('run', 'aiedit-b'), @('run', 'fix-ask011'), @('run', 'kitty-48'), @('agent', 'datay-5'), @('run', 'buildy-ask'), @('run', 'testy-retest-2'), @('desc', 'Website v2 wave 3: payments'), @('desc', 'ask catalogue create-only prompt')) | ForEach-Object { $null = & $py -X utf8 $KT3 naming check $_[0] $_[1] 2>&1; $LASTEXITCODE }
$nDir = Join-Path $kc 'zz-names'; $nPair = @(1, 2 | ForEach-Object { "$(& $py -X utf8 $KT3 naming next name dec 'Merge the cart change now or wait?' --dir $nDir --cap 16 2>&1)".Trim() })   # no file yet: the hold breaks the tie
$nBad = @(@(if (($nPair -join ',') -ne 'dec-merge-cart,dec-merge-cart-2') { "held tie: $($nPair -join ',')" }) + @(0..($nWant.Count - 1) | Where-Object { $nrm[$_] -ne $nWant[$_] } | ForEach-Object { "$($nrmIn[$_][1]) -> $($nrm[$_])" }))
Expect "naming norm: owner examples ($($nBad -join ' | ')); a clash keeps the tie ($nTie); check flags jam / tie letter / number / code text ($($nChk -join ','))" (-not $nBad.Count -and $nTie -eq 'ai-edit-b' -and ($nChk -join ',') -eq '1,1,1,1,0,0,1,0')
Remove-Item (Join-Path $kc 'skills/bossy/lint-vocab.json')
$l2 = & $py -X utf8 $KT3 lint --no-flow 2>&1 | Out-String
Expect 'ARCH-VOCAB: a missing lint-vocab.json is a counted problem' ($l2 -match '(?m)^ARCH-VOCAB\s+skills/bossy/lint-vocab\.json: missing')
Remove-Item (Split-Path $kc) -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
