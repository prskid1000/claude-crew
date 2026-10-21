#Requires -Version 7
<#
tests.ps1 (extra kit-admin): recover --fix keeps unmerged worktrees; release tags SemVer; budget raise steps x1.1 only over the
cap; cost lists every crew agent.
Usage: pwsh -NoProfile -File extras/kit-admin/tests.ps1 -Kit <kit>   (the plugin comes from files/ beside this file)
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
$ErrorActionPreference = 'Stop'
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$script:fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
$root = Join-Path ([IO.Path]::GetTempPath()) "kit-admin-$PID"; $kc = Join-Path $root '.claude'; New-Item -ItemType Directory -Force $kc | Out-Null
foreach ($f in @(git -C $Kit ls-files)) { $s1 = Join-Path $Kit $f; if (Test-Path $s1) { $d = Join-Path $kc (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $s1 $d -Force } }
Copy-Item (Join-Path $PSScriptRoot 'files/skills/orchestrate/kittool_admin.py') (Join-Path $kc 'skills/orchestrate')
'/skills/orchestrate/kittool_admin.py' | Add-Content (Join-Path $kc '.gitignore')
$gt = { git -C $args[0] -c user.name=t -c user.email=t@t @($args | Select-Object -Skip 1) }
git -C $kc init -q -b main; git -C $kc add -A; & $gt $kc commit -q -m 'feat: base'
$og = Join-Path $root 'origin.git'; git init -q --bare $og; git -C $kc remote add origin $og; git -C $kc push -q origin main 2>&1 | Out-Null; git -C $kc fetch -q origin
$KT = Join-Path $kc 'skills/orchestrate/kittool.py'
# recover --fix never removes a detached worktree holding commits not on origin/main
$wt = Join-Path $root 'wt-detached'; git -C $kc worktree add -q --detach $wt 2>&1 | Out-Null
'work' | Set-Content (Join-Path $wt 'unmerged.txt'); git -C $wt add unmerged.txt; & $gt $wt commit -q -m 'feat: unmerged work'
Get-ChildItem $wt -Force | ForEach-Object { $_.LastWriteTime = (Get-Date).AddHours(-5) }   # idle, like a forgotten worktree
$out = & $py -X utf8 $KT audit recover --fix --kit $kc 2>&1 | Out-String
Expect 'kit-admin: recover --fix keeps a detached worktree with unmerged commits (listed as RECOVER-HALF)' ((Test-Path (Join-Path $wt 'unmerged.txt')) -and $out -match 'RECOVER-HALF')
git -C $kc worktree remove --force $wt 2>&1 | Out-Null
# release: the next SemVer from Conventional Commits
$rel = & $py -X utf8 $KT release 2>&1 | Out-String
Expect 'kit-admin: release prints the next SemVer and its notes' ($rel -match '^# v\d+\.\d+\.\d+')
# cost: one start row per crew agent
$cost = & $py -X utf8 $KT cost --json 2>$null | Out-String | ConvertFrom-Json
Expect 'kit-admin: cost has a start row per crew agent' (@($cost | Where-Object { $_.agent -match '\(start\)$' }).Count -ge 1 -and @($cost | Where-Object { $_.total -le 0 }).Count -eq 0)
# budget raise: steps of x1.1 from 200000, refused under the cap
$bj = Join-Path $kc 'skills/dev-kit/kit.example.json'; $bt = { & $py -X utf8 $KT budget raise -Reason x 2>&1 | Out-String }
$capTo = { param($v) (Get-Content $bj -Raw) -replace '("totalTokens":\s*)\d+', "`${1}$v" | Set-Content $bj -NoNewline; & $gt $kc commit -qam cap }
& $capTo 518000; $b1 = & $bt; $c1 = $LASTEXITCODE   # a cap step above the kit: refused
('x' * 1000000) | Set-Content (Join-Path $kc 'pad.dat'); git -C $kc add pad.dat   # not a text file: lint does not scan it
& $capTo 200000
$b2 = & $bt; $c2 = (Get-Content $bj -Raw) -match '"totalTokens": 220000'
Expect 'kit-admin: budget raise refused under the cap, x1.1 over it' ($c1 -eq 1 -and $b1 -match 'fits the cap' -and $b2 -match '200000 -> 220000' -and $c2)
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
"$script:fails failure(s)"
exit [int]($script:fails -gt 0)
