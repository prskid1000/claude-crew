#Requires -Version 7
<#
tests.ps1 (extra kit-admin): recover --fix keeps unmerged worktrees; release tags SemVer; budget raise steps x1.1 only over the
cap; cost lists every crew agent; learn lesson tools (-Lesson, -Bump, -Fixed, -History, -Stats; core tests the line without it).
Usage: kittool.py extra test kit-admin (the plugin comes from files/ beside this file)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kittool.py extra test: the kit's harness
$root = Join-Path ([IO.Path]::GetTempPath()) "kit-admin-$PID"; $kc = New-GitKitCopy $root
Copy-Item (Join-Path $PSScriptRoot 'files/skills/orchestrate/kittool_admin.py') (Join-Path $kc 'skills/orchestrate')
'/skills/orchestrate/kittool_admin.py' | Add-Content (Join-Path $kc '.gitignore'); git -C $kc commit -qam 'chore: ignore the plugin'; git -C $kc push -q origin main 2>&1 | Out-Null; git -C $kc fetch -q origin
$KT = Join-Path $kc 'skills/orchestrate/kittool.py'
# recover --fix never removes a detached worktree holding commits not on origin/main
$wt = Join-Path $root 'wt-detached'; git -C $kc worktree add -q --detach $wt 2>&1 | Out-Null
'work' | Set-Content (Join-Path $wt 'unmerged.txt'); git -C $wt add unmerged.txt; git -C $wt commit -q -m 'feat: unmerged work'
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
$capTo = { param($v) (Get-Content $bj -Raw) -replace '("totalTokens":\s*)\d+', "`${1}$v" | Set-Content $bj -NoNewline; git -C $kc commit -qam cap }
& $capTo 518000; $b1 = & $bt; $c1 = $LASTEXITCODE   # a cap step above the kit: refused
('x' * 1000000) | Set-Content (Join-Path $kc 'pad.dat'); git -C $kc add pad.dat   # not a text file: lint does not scan it
& $capTo 200000
$b2 = & $bt; $c2 = (Get-Content $bj -Raw) -match '"totalTokens": 220000'
Expect 'kit-admin: budget raise refused under the cap, x1.1 over it' ($c1 -eq 1 -and $b1 -match 'fits the cap' -and $b2 -match '200000 -> 220000' -and $c2)
# kit-admin.md: every [CODE] it names is a lint code kittool.py emits (no stale rule names)
$doc = Get-Content (Join-Path $PSScriptRoot 'files/skills/orchestrate/kit-admin.md') -Raw
$emitted = [regex]::Matches((Get-Content (Join-Path $src 'skills/orchestrate/kittool.py') -Raw), "(?:bad\('|\('(?=SECTION-))([A-Z-]+)'") | ForEach-Object { $_.Groups[1].Value }
$named = [regex]::Matches($doc, '\[([A-Z][A-Z, *-]+)\]') | ForEach-Object { $_.Groups[1].Value -split ',\s*' } | Where-Object { $_ -notmatch '\*' -and $_ -ne 'CODE' }
$stale = @($named | Where-Object { $_ -notin $emitted })
Expect "kit-admin: kit-admin.md names only lint codes kittool.py emits (stale: $($stale -join ', '))" ($named.Count -gt 5 -and -not $stale.Count)
# learn lesson tools and the audit nudge (adapters/kit_admin.ps1): -Bump miss frees the lock; org terms go local; -Fixed shows in -History
$ad = New-Item -ItemType Directory -Force (Join-Path $kc 'skills/orchestrate/adapters'); Copy-Item (Join-Path $PSScriptRoot 'files/skills/orchestrate/adapters/kit_admin.ps1') $ad
$O = Join-Path $kc 'skills/orchestrate/orch.ps1'; $lo = { pwsh -NoProfile -File $O learn @args 2>&1 | Out-String }
$au = & { . $O; Get-KitHealthLinesAudit }; $st = & { . (Join-Path $kc 'skills/dev-kit/lib.ps1'); Get-KitPath last-kitty-audit -Create }; (Get-Date).ToString('s') | Set-Content $st; $au2 = & { . $O; Get-KitHealthLinesAudit }
Expect 'kit-admin: health nudges a never-run kitty audit, quiet right after one' ("$au" -match 'Kit audit due \(last never, every 7 days\)' -and -not $au2)
'edited' | Add-Content (Join-Path $kc 'README.md'); $ue = & { . $O; Test-UnstagedEdits $kc 'README.md' }; git -C $kc checkout -q -- README.md
$pc = pwsh -NoProfile -File $O precommit 2>&1 | Out-String
Expect 'kit-admin: precommit runs from the adapter and sees unstaged README edits (it never stages them)' ($ue -and $pc -notmatch 'is an extra' -and $pc -match 'pre-commit')
$sx = Join-Path $kc 'skills/sx.ps1'; "<#`nSections: L9 a`n#>`n# ---- a: x`n" | Set-Content $sx -NoNewline; git -C $kc add -- skills/sx.ps1; $null = pwsh -NoProfile -File $O precommit 2>&1
Expect 'kit-admin: precommit rewrites and stages a stale Sections: map' (@(git -C $kc show :skills/sx.ps1) -contains 'Sections: L4 a'); git -C $kc rm -qf -- skills/sx.ps1
$null = & $lo -Skill revy -Bump 'no such lesson words'; $bc = $LASTEXITCODE
Expect 'kit-admin: learn -Bump miss exits 1, LESSONS.md lock released' ($bc -eq 1 -and -not (Test-Path (Join-Path $kc 'LESSONS.md.lock')))
'{ "orgTerms": ["Acmecorp"] }' | Set-Content (Join-Path $kc 'skills/dev-kit/kit.local.json')
$null = & $lo -Skill revy -Lesson '(2×) a generic lesson'; $null = & $lo -Skill revy -Lesson 'an Acmecorp lesson'
$r1 = & $lo -Read -Skill revy
Expect 'kit-admin: learn -Lesson generic -> LESSONS.md, org term -> LESSONS.local.md' ($r1 -match 'a generic lesson' -and $r1 -match '\(local\)' -and (Get-Content (Join-Path $kc 'LESSONS.local.md') -Raw) -match 'Acmecorp' -and (Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -notmatch 'Acmecorp')
$null = & $lo -Skill revy -Fixed 'a generic lesson'; $hi = & $lo -History -Grep 'a generic lesson'; $st = & $lo -Stats
Expect 'kit-admin: learn -Fixed moves the line out, -History lists it, -Stats counts signals' ((Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -notmatch 'a generic lesson' -and $hi -match '\(fixed in kit\) \(2×\) a generic lesson' -and $st -match 'signals since last retro')
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
foreach ($t in Get-ChildItem $PSScriptRoot -Filter 'tests-*.ps1') { & $pwshExe -NoProfile -File $t.FullName -Kit $src }   # the tests of the extras merged into this one
Complete-Tests
