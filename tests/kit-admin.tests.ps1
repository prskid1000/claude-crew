#Requires -Version 7
<#
kit-admin.tests.ps1: recover --fix keeps unmerged worktrees; release tags SemVer; budget raise steps x1.1 only over the
cap; cost lists every crew agent; learn lesson tools (-Lesson, -Bump, -Fixed, -History, -Stats; core tests the line without it).
Usage: pwsh -NoProfile -File <kit>/tests/kit-admin.tests.ps1 (or tests/kit-tests.ps1 -Area kit-admin).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/kit_admin.ps1', 'skills/bossy/kit-admin.md', 'skills/bossy/kitbag_admin.py', 'skills/bossy/kitbag_scaffold.py')   # copied into every New-TestKit kit
$root = Join-Path ([IO.Path]::GetTempPath()) "kit-admin-$PID"; $kc = New-GitKitCopy $root -Push
$KT = Join-Path $kc 'skills/bossy/kitbag.py'
# recover --fix never removes a detached worktree holding commits not on origin/main
$wt = Join-Path $root 'wt-detached'; git -C $kc worktree add -q --detach $wt 2>&1 | Out-Null
'work' | Set-Content (Join-Path $wt 'unmerged.txt'); git -C $wt add unmerged.txt; git -C $wt commit -q -m 'feat: unmerged work'
Get-ChildItem $wt -Force | ForEach-Object { $_.LastWriteTime = (Get-Date).AddHours(-5) }   # idle, like a forgotten worktree
'# resume' | Set-Content (Join-Path (TkPath $kc launches -Create) 'wf-x.resume.md'); '{}' | Set-Content (Join-Path (TkPath $kc launches) 'args-buildy-x.json')
$out = & $py -X utf8 $KT audit recover --fix --kit $kc 2>&1 | Out-String
Expect 'kit-admin: recover --fix keeps a detached worktree with unmerged commits (listed as RECOVER-HALF); a resume brief or workflow args file is no launch record' ((Test-Path (Join-Path $wt 'unmerged.txt')) -and $out -match 'RECOVER-HALF' -and $out -notmatch 'wf-x\.resume\.md|args-buildy-x')
git -C $kc worktree remove --force $wt 2>&1 | Out-Null
# config: a vendor adapter's tracker name counts (adapter:tracker/<name>), a local file with no example (swarm.config.json) is no CONFIG-FILE; scan: sub-keys named plainly in a README row are documented
$cad = Join-Path $kc 'skills/crafty/adapters'; New-Item -ItemType Directory -Force $cad, (Join-Path $kc 'skills/phoney') | Out-Null; '# adapter:tracker/zzt' | Set-Content (Join-Path $cad 'tracker_zzt.ps1')
Set-JsonFile (Join-Path $kc 'skills/crafty/kit.local.json') @{ tracker = @{ type = 'zzt' } }; '{"lanes": []}' | Set-Content (Join-Path $kc 'skills/phoney/swarm.config.json')
$cfo = & $py -X utf8 $KT audit config --kit $kc 2>&1 | Out-String; $sco = & $py -X utf8 $KT audit scan --kit $kc 2>&1 | Out-String
Expect "kit-admin: config knows vendor tracker names and example-less local files; scan reads plain sub-keys ($(($cfo + $sco) -split "`n" -match 'CONFIG-(VALUE|FILE|UNDOC)' -join ' '))" ($cfo -notmatch 'CONFIG-VALUE.+tracker\.type|CONFIG-FILE.+swarm' -and $sco -notmatch 'CONFIG-UNDOC kit\.example\.json supervise\.heartbeatMinutes')
Remove-Item (Join-Path $cad 'tracker_zzt.ps1'), (Join-Path $kc 'skills/crafty/kit.local.json'), (Join-Path $kc 'skills/phoney/swarm.config.json') -ErrorAction SilentlyContinue
# prepush: a pushed git-ignored file = LOCAL FILE; a file an old `# kitbag <kind> <name>` exclude block lists (now tracked) is not
$ad = Join-Path $kc 'skills/bossy/adapters'; New-Item -ItemType Directory -Force $ad, (Join-Path $kc 'notes') | Out-Null
Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/adapters/kit_admin.ps1') $ad
$xf = git -C $kc rev-parse --path-format=absolute --git-path info/exclude
Add-Content $xf "`n`n/notes/l.txt`n`n# kitbag part old-x`n/notes/g.txt`n# kitbag part end"
$base = git -C $kc rev-parse HEAD; 'l' | Set-Content (Join-Path $kc 'notes/l.txt'); 'g' | Set-Content (Join-Path $kc 'notes/g.txt'); git -C $kc add -f notes/l.txt notes/g.txt; git -C $kc commit -qm 'feat: notes'
$pp = "refs/heads/main $(git -C $kc rev-parse HEAD) refs/heads/main $base" | pwsh -NoProfile -File (Join-Path $kc 'skills/bossy/bossy.ps1') prepush 2>&1 | Out-String
Expect "kit-admin: prepush flags a git-ignored file, not one an old kitbag exclude block lists ($(($pp -split "`n" | Where-Object { $_ -match 'LOCAL FILE' }) -join ' '))" ($pp -match 'LOCAL FILE\s+notes/l\.txt' -and $pp -notmatch 'notes/g\.txt')
Add-Content $xf '/notes/none.txt'; $asu = & $py -X utf8 $KT audit setup --kit $kc 2>&1 | Out-String
Expect "kit-admin: audit setup names an exclude line hiding a tracked file (fix: bossy.ps1 setup) and one not in localOnly" ($asu -match 'SETUP-INSTALL.+line /notes/l\.txt hides tracked file\(s\) notes/l\.txt.+bossy\.ps1 setup' -and $asu -match 'SETUP-EXCLUDE.+line /notes/none\.txt is not in kit\.local\.json localOnly')
git -C $kc reset -q --hard $base
# prepush to main: the full kit run on the pushed clean tree (a fake runner), a stamped tree skipped, a dirty checkout refused, no run off main
$env:FAKE_RAN = Join-Path $root 'ran.txt'; Set-Content (Join-Path $kc 'tests/kit-tests.ps1') @'
"$args" | Add-Content $env:FAKE_RAN; if ($env:FAKE_FLAKY -and $args -contains '-Area') { '0 failure(s) in 1 area(s), 1 s'; exit 0 }
'Failed checks:'; '  [x] y'; '1 failure(s) in 1 area(s), 1 s'; exit 1
'@
git -C $kc commit -qam 'test: fake runner'; $hd = git -C $kc rev-parse HEAD; $snap = $env:KIT_TESTS_SNAPSHOT; Remove-Item Env:KIT_TESTS_SNAPSHOT
$prePush = { param($ref) Remove-Item $env:FAKE_RAN -ErrorAction SilentlyContinue; $ppOut = "$ref $hd $ref $base" | pwsh @np (Join-Path $kc 'skills/bossy/bossy.ps1') prepush 2>&1 | Out-String; [pscustomobject]@{ out = $ppOut; code = $LASTEXITCODE; ran = "$(Get-Content $env:FAKE_RAN -ErrorAction SilentlyContinue)" } }
$pr = & $prePush refs/heads/main; $po = & $prePush refs/heads/f/x; $env:FAKE_FLAKY = '1'; $pf = & $prePush refs/heads/main; Remove-Item Env:FAKE_FLAKY
$gf = Join-Path (TkPath $kc cache -Create) 'kit-tests-green.txt'; git -C $kc rev-parse 'HEAD^{tree}' | Set-Content $gf; $pg = & $prePush refs/heads/main; Remove-Item $gf
'x' | Add-Content (Join-Path $kc 'README.md'); $pd = & $prePush refs/heads/main; git -C $kc checkout -q -- README.md
Expect "kit-admin: prepush to main runs kit-tests -Full (a FAIL blocks; one that passes alone warns), skips a green-stamped tree, refuses a dirty checkout; no run off main ($($pr.code) $($pf.code) $($pg.code) $($pd.code))" (
  $pr.code -eq 1 -and $pr.ran -eq '-Full -Area x' -and $pf.code -eq 0 -and $pf.out -match 'x failed in the full run and passed alone' -and $pr.out -match 'TESTS\s+the full kit run failed' -and $pr.out -match '  \[x\] y' -and -not $po.ran -and $po.out -notmatch 'TESTS' -and
  $pg.code -eq 0 -and -not $pg.ran -and $pg.out -match 'already green' -and $pd.code -eq 1 -and -not $pd.ran -and $pd.out -match 'TESTS\s+the pushed commit is not this clean checkout')
# nightly: idle + none in 20 h -> one detached full run; its total read once, not restarted; busy -> none started
$nf = Join-Path $root 'nightly.ps1'; Set-Content $nf @'
. $args[0]; . $args[1]; $sf = Join-Path (Get-KitPath cache -Create) 'kit-tests-nightly.json'
$o1 = @(Invoke-KitNightlyTests $false); $s0 = Test-Path $sf; $null = Invoke-KitNightlyTests $true; $st = Get-Content $sf -Raw | ConvertFrom-Json
$null = Wait-Process -Id $st.pid -Timeout 60 -ErrorAction SilentlyContinue; $o2 = @(Invoke-KitNightlyTests $true); $o3 = @(Invoke-KitNightlyTests $true)
"busy:$(-not $o1.Count -and -not $s0 -and $st.pid)"
"read:$($o2.Count -eq 1 -and $o2[0] -match '^kit tests nightly: 1 failure\(s\) in 1 area\(s\), 1 s, 1 failed check' -and -not $o3.Count -and (Get-Content $sf -Raw | ConvertFrom-Json).pid -eq $st.pid -and (Get-Content $env:FAKE_RAN) -eq '-Full')"
# no total: started before the last boot = cut by a machine restart (no ACT, due again); started after it = a crash (ACT)
$lfn = Join-Path (Get-KitPath logs -Create) 'kit-tests-nightly.txt'; $cutAt = { param($t) @{ at = $t.ToString('o'); start = $t.ToString('o'); pid = $st.pid; read = $false } | ConvertTo-Json -Compress | Set-Content $sf; '  x done (1 s)' | Set-Content $lfn }
& $cutAt (Get-KitBootTime).AddMinutes(-5); $o4 = @(Invoke-KitNightlyTests $false); $s4 = Get-Content $sf -Raw | ConvertFrom-Json
& $cutAt (Get-Date).AddMinutes(-5); $o5 = @(Invoke-KitNightlyTests $false)
"cut:$(-not $o4.Count -and $s4.read -and $s4.cut -eq 'machine restart' -and ((Get-Date) - [datetime]$s4.at).TotalHours -ge 20 -and $o5.Count -eq 1 -and $o5[0] -match 'no total \(crashed\)')"; "cut detail: $($o4 -join ' ') | $($o5 -join ' ')"
'@; $ng = @(pwsh @np $nf (Join-Path $kc 'skills/crafty/lib.ps1') (Join-Path $kc 'skills/bossy/adapters/kit_admin.ps1') 2>&1)
Expect-Each $ng 'kit-admin: nightly kit tests: #' 'busy', 'read', 'cut' -Show 6
$env:KIT_TESTS_SNAPSHOT = $snap; git -C $kc reset -q --hard $base
# release: the next SemVer from Conventional Commits
$rel = & $py -X utf8 $KT release 2>&1 | Out-String
Expect 'kit-admin: release prints the next SemVer and its notes' ($rel -match '^# v\d+\.\d+\.\d+')
# cost: one start row per crew agent
$cost = & $py -X utf8 $KT cost --json 2>$null | Out-String | ConvertFrom-Json
Expect 'kit-admin: cost has a start row per crew agent' (@($cost | Where-Object { $_.agent -match '\(start\)$' }).Count -ge 1 -and @($cost | Where-Object { $_.total -le 0 }).Count -eq 0)
$cst = & $py -X utf8 $KT cost --steps 2>$null | Out-String
Expect 'kit-admin: cost --steps measures the tidy judge prompt (the prep mock returns its JSON)' ($cst -match '(?m)^tidy\s+apply\s')
# cost and lint START-BUDGET read one measure (start_rows)
$cstJ = & $py -X utf8 $KT cost --json 2>$null | ConvertFrom-Json; $bud = & $py -X utf8 $KT budget 2>&1 | Out-String
$cd = @($cstJ | Where-Object agent -eq 'devy (start)')[0]
Expect "kit-admin: cost start rows equal kitbag.py budget ($($cd.total))" ($cd -and $bud -match "(?m)^devy\s+start\s+$($cd.total) of 12000")
# kit-admin.md: every [CODE] it names is a lint code kitbag.py emits (no stale rule names)
$doc = Get-Content (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/kit-admin.md') -Raw
$emitted = [regex]::Matches((Get-Content (Join-Path $src 'skills/bossy/kitbag.py') -Raw), "(?:bad\('|\('(?=SECTION-))([A-Z-]+)'") | ForEach-Object { $_.Groups[1].Value }
$named = [regex]::Matches($doc, '\[([A-Z][A-Z, *-]+)\]') | ForEach-Object { $_.Groups[1].Value -split ',\s*' } | Where-Object { $_ -notmatch '\*' -and $_ -ne 'CODE' }
$stale = @($named | Where-Object { $_ -notin $emitted })
Expect "kit-admin: kit-admin.md names only lint codes kitbag.py emits (stale: $($stale -join ', '))" ($named.Count -gt 5 -and -not $stale.Count)
# learn lesson tools and the audit nudge (adapters/kit_admin.ps1): -Bump miss frees the lock; org terms go local; -Fixed shows in -History
$ad = New-Item -ItemType Directory -Force (Join-Path $kc 'skills/bossy/adapters'); Copy-Item (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/adapters/kit_admin.ps1') $ad
$O = Join-Path $kc 'skills/bossy/bossy.ps1'; $lo = { pwsh -NoProfile -File $O learn @args 2>&1 | Out-String }
$au = & { . $O; Get-KitHealthLinesAudit }; $st = & { . (Join-Path $kc 'skills/crafty/lib.ps1'); Get-KitPath last-kitty-audit -Create }; (Get-Date).ToString('s') | Set-Content $st; $au2 = & { . $O; Get-KitHealthLinesAudit }
Expect 'kit-admin: health nudges a never-run kitty audit, quiet right after one' ("$au" -match 'Kit audit due \(last never, every 7 days\)' -and -not $au2)
'edited' | Add-Content (Join-Path $kc 'README.md'); $ue = & { . $O; Test-UnstagedEdits $kc 'README.md' }; git -C $kc checkout -q -- README.md
$pc = pwsh -NoProfile -File $O precommit 2>&1 | Out-String; $pcc = $LASTEXITCODE   # a clean copy: nothing to say, exit 0
Expect "kit-admin: precommit runs from the adapter and sees unstaged README edits (it never stages them) ($pcc $($pc.Trim()))" ($ue -and $pcc -eq 0 -and $pc -notmatch 'not recognized|Exception')
$sx = Join-Path $kc 'skills/sx.ps1'; "<#`nSections: L9 a`n#>`n# ---- a: x`n" | Set-Content $sx -NoNewline; git -C $kc add -- skills/sx.ps1; $null = pwsh -NoProfile -File $O precommit 2>&1
Expect 'kit-admin: precommit rewrites and stages a stale Sections: map' (@(git -C $kc show :skills/sx.ps1) -contains 'Sections: L4 a'); git -C $kc rm -qf -- skills/sx.ps1
$null = & $lo -Skill revy -Bump 'no such lesson words'; $bc = $LASTEXITCODE
Expect 'kit-admin: learn -Bump miss exits 1, LESSONS.md lock released' ($bc -eq 1 -and -not (Test-FileLockHeld (Join-Path $kc 'LESSONS.md')))
'{ "orgTerms": ["Acmecorp"] }' | Set-Content (Join-Path $kc 'skills/crafty/kit.local.json')
$null = & $lo -Skill revy -When 'a generic case' -Do 'a generic lesson' -Why 'test'; $null = & $lo -Skill revy -When 'an Acmecorp case' -Do 'an Acmecorp lesson' -Why 'org'
$null = & $lo -Skill revy -Lesson 'free text, no shape'; $freeCode = $LASTEXITCODE
$r1 = & $lo -Read -Skill revy
Expect 'kit-admin: learn -When -Do -Why renders ''- <when> -> <do> (<why>)'': generic -> LESSONS.md, org term -> LESSONS.local.md; a free -Lesson refused (2)' ($freeCode -eq 2 -and $r1 -notmatch 'free text' -and $r1 -match '- a generic case -> a generic lesson \(test\)' -and $r1 -match '\(local\)' -and (Get-Content (Join-Path $kc 'LESSONS.local.md') -Raw) -match 'Acmecorp' -and (Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -notmatch 'Acmecorp')
$null = & $lo -Skill revy -Lesson 'an ascii case -> an ascii counted lesson (why) (1x)'; $null = & $lo -Skill revy -Bump 'ascii counted'
Expect 'kit-admin: learn -Bump counts an ASCII (1x) up to (2×)' ((Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -match 'an ascii counted lesson \(why\) \(2×\)')
$null = & $lo -Skill revy -Lesson "an overlong case $('padword ' * 50)-> refuse it (why)" 3>$null; $longCode = $LASTEXITCODE
Expect "kit-admin: learn refuses a lesson over the templates.md lesson word cap (2), nothing written ($longCode)" ($longCode -eq 2 -and (Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -notmatch 'an overlong case')
$kbPy = Join-Path $kc 'skills/bossy/kitbag.py'; Move-Item $kbPy "$kbPy.off"
$nocap = & $lo -Skill revy -Lesson 'an unchecked case -> written with a warning (no kitbag)'; Move-Item "$kbPy.off" $kbPy
Expect "kit-admin: learn warns when kitbag.py cannot check the lesson word cap, the lesson still written ($($nocap.Trim()))" ($nocap -match '\[prose\] lesson: not checked: kitbag\.py not found' -and (Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -match 'an unchecked case')
$null = & $lo -Skill revy -Fixed 'a generic lesson'; $hi = & $lo -History -Grep 'a generic lesson'; $st = & $lo -Stats
Expect 'kit-admin: learn -Fixed moves the line out, -History lists it, -Stats counts signals' ((Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -notmatch 'a generic lesson' -and $hi -match '\(fixed in kit\) a generic case -> a generic lesson \(test\)' -and $st -match 'signals since last retro')
$splitOne = @("a`nb" -split "`n", -1).Count; $kaText = (Get-Content (Join-Path $src 'skills/bossy/kit-admin.md') -Raw) -replace '\s+', ' '
Expect "kit-admin.md Script pitfalls: -split with limit -1 returns one element ($splitOne): no limit" ($splitOne -eq 1 -and $kaText -match '`-split` limit -1 = one element: no limit')
# audit config: CFG / $cfg bound to one section -> its reads are that section's sub-keys (media.vidy, tests.e2e.specs), not top-level keys
$ck = Join-Path $root 'cfgkeys'; New-Item -ItemType Directory -Force $ck | Out-Null
"CFG = merge(D, load().get('media') or {})`nx = CFG['vidy']`ny = CFG.get('stt')" | Set-Content (Join-Path $ck 'a.py'); "`$cfg = Get-KitSetting 'tests.e2e' `$null`n`$s = `$cfg.specs`n`$p = Join-Path k 'kit.local.json'" | Set-Content (Join-Path $ck 'b.ps1')
$ckPy = Join-Path $root 'cfgkeys.py'; @('import importlib.util, sys', "sys.path.insert(0, r'$(Split-Path $KT)')", 'import kitbag', "spec = importlib.util.spec_from_file_location('ka', r'$(Join-Path (Split-Path $KT) 'kitbag_admin.py')')",
  'ka = importlib.util.module_from_spec(spec); ka.__dict__.update({n: v for n, v in vars(kitbag).items() if not n.startswith("__")}); spec.loader.exec_module(ka)', "print(','.join(sorted(ka.script_config_keys(r'$ck', ['a.py', 'b.ps1']))))") | Set-Content $ckPy
$ckOut = & $py -X utf8 $ckPy 2>&1 | Select-Object -Last 1
Expect "audit config: section-bound CFG / `$cfg reads are sub-keys ($ckOut)" ("$ckOut".Trim() -eq 'media.stt,media.vidy,tests.e2e,tests.e2e.specs')
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Complete-Tests
