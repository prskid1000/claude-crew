#Requires -Version 7
<#
lint-arch.tests.ps1: kitbag.py lint ARCH-* rules (lint-vocab.json): DEFAULT, ENUM, VENDOR-API, PLATFORM, LESSON, DEAD-KEY; a hit and a
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
Set-Content (Join-Path $kc 'skills/crafty/zz_gitlab.ps1') "#Requires -Version 7`n`$a = Get-KitSetting 'zz.vendor' 'gitlab'" -Encoding utf8
Add-Content (Join-Path $kc 'LESSONS.md') "`n## zz`n- a migration fails -> run liquibase status first (it hides the lock)" -Encoding utf8
$null = New-Item -ItemType Directory -Force (Join-Path $kc 'rules'); Set-Content (Join-Path $kc 'rules/zz.local.md') "# zz`nliquibase lock: release it" -Encoding utf8
# an org-only rule (kit.local.json localOnly + .git/info/exclude) may name its stack; a published one may not
foreach ($zr in 'zz-org', 'zz-pub') { Set-Content (Join-Path $kc "rules/$zr.md") "# $zr`nspring beans: inject by constructor" -Encoding utf8 }
& $J @{ localOnly = @('rules/zz-org.md') } (Join-Path $kc 'skills/crafty/kit.local.json'); Add-Content (git -C $kc rev-parse --path-format=absolute --git-path info/exclude) '/rules/zz-org.md'
$ex = Join-Path $kc 'skills/crafty/kit.example.json'; $t = [IO.File]::ReadAllText($ex)
[IO.File]::WriteAllText($ex, ($t -replace '(?s)^\{', "{`n `"zzDeadKey`": 1, `"zzLiveKey`": 2,"))
$l1 = & $py -X utf8 $KT3 lint --no-flow 2>&1 | Out-String
$cnt = { param($rx) @([regex]::Matches($l1, $rx)).Count }
Expect "ARCH-DEFAULT: a vendor default is a problem with file:line; neutral, arch-ok, legacy block and vendor-named files pass" ($l1 -match '(?m)^ARCH-DEFAULT\s+skills/crafty/zz_arch\.ps1:2: zz\.hit: default names gitlab' -and
  $l1 -match '(?m)^ARCH-DEFAULT\s+skills/crafty/zz_arch\.py:3: zzTag: default names CU-' -and (& $cnt 'ARCH-DEFAULT\s+skills/crafty/zz_arch\.ps1') -eq 1 -and $l1 -notmatch 'ARCH-DEFAULT\s+skills/crafty/zz_gitlab')
Expect 'ARCH-ENUM: web/api/app in one file = WARN; a registry: comment and adapters/ pass' ($l1 -match 'WARN ARCH-ENUM\s+skills/crafty/zz_arch\.ps1:5: 3 lanes values' -and
  $l1 -notmatch 'deployKinds values \(awsStack:6' -and $l1 -notmatch 'ARCH-ENUM\s+skills/crafty/adapters/zz_arch')
Expect 'ARCH-VENDOR-API: glab api in core = a problem; adapters/ and a py docstring pass' ($l1 -match '(?m)^ARCH-VENDOR-API\s+skills/crafty/zz_arch\.ps1:7: vendor call "glab api' -and
  $l1 -notmatch 'ARCH-VENDOR-API\s+skills/crafty/(adapters/zz_arch|zz_arch\.py)')
Expect 'ARCH-PLATFORM: Get-CimInstance / os.startfile unguarded = a problem; inside if ($KitIsWindows) / os.name and a docstring pass' ($l1 -match '(?m)^ARCH-PLATFORM\s+skills/crafty/zz_arch\.ps1:8:' -and
  $l1 -notmatch 'ARCH-PLATFORM\s+skills/crafty/zz_arch\.ps1:10:' -and $l1 -match 'ARCH-PLATFORM\s+skills/crafty/zz_arch\.py:7:' -and $l1 -notmatch 'ARCH-PLATFORM\s+skills/crafty/zz_arch\.py:[26]:')
Expect 'ARCH-LESSON: liquibase in tracked LESSONS.md = a problem; a rules/*.local.md and a localOnly / excluded rule pass, a published rule fails' ($l1 -match '(?m)^ARCH-LESSON\s+LESSONS\.md:\d+: names liquibase' -and
  $l1 -notmatch 'ARCH-LESSON\s+rules/zz\.local\.md' -and $l1 -notmatch 'ARCH-LESSON\s+rules/zz-org\.md' -and $l1 -match '(?m)^ARCH-LESSON\s+rules/zz-pub\.md:\d+: names spring')
Expect "ARCH-DEAD-KEY: a documented key no script reads is a counted problem (exit $LASTEXITCODE); a read key passes" ($LASTEXITCODE -eq 1 -and
  $l1 -match '(?m)^ARCH-DEAD-KEY\s+skills/crafty/kit\.example\.json: "zzDeadKey"' -and $l1 -notmatch 'ARCH-DEAD-KEY.*zzLiveKey')
Remove-Item (Join-Path $kc 'skills/bossy/lint-vocab.json')
$l2 = & $py -X utf8 $KT3 lint --no-flow 2>&1 | Out-String
Expect 'ARCH-VOCAB: a missing lint-vocab.json is a counted problem' ($l2 -match '(?m)^ARCH-VOCAB\s+skills/bossy/lint-vocab\.json: missing')
Remove-Item (Split-Path $kc) -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
