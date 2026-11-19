#Requires -Version 7
<#
kit-admin.tests.ps1: recover --fix keeps unmerged worktrees; release tags SemVer; budget raise steps x1.1 only over the
cap; cost lists every crew agent; learn lesson tools (-Lesson, -Bump, -Fixed, -History, -Stats; core tests the line without it); setup -BrowserPolicy (HKCU policies, model folders).
Usage: pwsh -NoProfile -File <kit>/tests/kit-admin.tests.ps1 (or tests/kit-tests.ps1 -Area kit-admin).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/kit_admin.ps1', 'skills/bossy/kit-admin.md', 'skills/bossy/kitbag_admin.py', 'skills/bossy/kitbag_scaffold.py', 'skills/bossy/kitbag_forget.py')   # copied into every New-TestKit kit
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
# prepush (owner 2026-11-19: tests are the agent's, before it commits and pushes): a push to main never runs the kit tests
$env:FAKE_RAN = Join-Path $root 'ran.txt'; Set-Content (Join-Path $kc 'tests/kit-tests.ps1') @'
"$args" | Add-Content $env:FAKE_RAN; if ($env:FAKE_HANG) { '  a done (1 s)'; Start-Sleep 60 }
'Failed checks:'; '  [x] y'; '1 failure(s) in 1 area(s), 1 s'; exit 1
'@
git -C $kc commit -qam 'test: fake runner'; $hd = git -C $kc rev-parse HEAD; $snap = $env:KIT_TESTS_SNAPSHOT; Remove-Item Env:KIT_TESTS_SNAPSHOT
$pr = "refs/heads/main $hd refs/heads/main $base" | pwsh @np (Join-Path $kc 'skills/bossy/bossy.ps1') prepush 2>&1 | Out-String; $prc = $LASTEXITCODE
Expect "kit-admin: prepush to main runs no kit tests, passes a clean push ($prc)" ($prc -eq 0 -and -not (Test-Path $env:FAKE_RAN) -and $pr -notmatch 'TESTS')
# weekly (kitTests.fullEveryDays): idle + no green full run within the days -> one detached full run; read once; one try a day;
# a green run within the week -> none; a week old -> due again (catch-up), unless the tree is green-stamped (unchanged kit); health names the last green and the last run
$nf = Join-Path $root 'weekly.ps1'; Set-Content $nf @'
. $args[0]; . $args[1]; $sf = (Get-KitFullTestsState).file
$o1 = @(Invoke-KitWeeklyTests $false); $s0 = Test-Path $sf; $null = Invoke-KitWeeklyTests $true; $st = Get-Content $sf -Raw | ConvertFrom-Json
$null = Wait-Process -Id $st.pid -Timeout 60 -ErrorAction SilentlyContinue; $o2 = @(Invoke-KitWeeklyTests $true); $o3 = @(Invoke-KitWeeklyTests $true)
"busy:$(-not $o1.Count -and -not $s0 -and $st.pid)"
"read:$($o2.Count -eq 1 -and $o2[0] -match '^kit tests \(full\): 1 failure\(s\) in 1 area\(s\), 1 s, 1 failed check' -and -not $o3.Count -and (Get-Content $sf -Raw | ConvertFrom-Json).pid -eq $st.pid -and (Get-Content $env:FAKE_RAN) -eq '-Full -Detached')"
$wk = { param($green, $at) @{ at = $at.ToString('o'); start = $at.ToString('o'); greenAt = $green.ToString('o'); pid = 999999; read = $true } | ConvertTo-Json -Compress | Set-Content $sf; Remove-Item $env:FAKE_RAN -ErrorAction SilentlyContinue }
$began = { (Get-Content $sf -Raw | ConvertFrom-Json).pid -ne 999999 }   # a started run stamps its pid (the detached runner writes FAKE_RAN later)
& $wk (Get-Date).AddDays(-2) (Get-Date).AddDays(-2); $null = Invoke-KitWeeklyTests $true; $w1 = & $began
& $wk (Get-Date).AddDays(-8) (Get-Date).AddDays(-8); $null = Invoke-KitWeeklyTests $true; $w2 = & $began; $hl = Get-KitHealthLinesFullTests
git -C $KitConf.Kit rev-parse 'HEAD^{tree}' | Set-Content (Join-Path (Get-KitPath cache -Create) 'kit-tests-green.txt'); & $wk (Get-Date).AddDays(-8) (Get-Date).AddDays(-8); $null = Invoke-KitWeeklyTests $true; $w3 = & $began
"week:$(-not $w1 -and $w2 -and -not $w3 -and $hl -match '^Kit tests \(full, every 7 days while idle\): last green \d{4}-\d\d-\d\d, last run \d{4}-\d\d-\d\d')"; "week detail: $w1 $w2 $hl"
# no total: started before the last boot = cut by a machine restart (no ACT, due again); started after it = a crash (ACT)
$lfn = (Get-KitFullTestsState).log; $cutAt = { param($t) @{ at = $t.ToString('o'); start = $t.ToString('o'); pid = 999999; read = $false } | ConvertTo-Json -Compress | Set-Content $sf; '  x done (1 s)' | Set-Content $lfn }
& $cutAt (Get-KitBootTime).AddMinutes(-5); $o4 = @(Invoke-KitWeeklyTests $false); $s4 = Get-Content $sf -Raw | ConvertFrom-Json
& $cutAt (Get-Date).AddMinutes(-5); $o5 = @(Invoke-KitWeeklyTests $false)
"cut:$(-not $o4.Count -and $s4.read -and $s4.cut -eq 'machine restart' -and ((Get-Date) - [datetime]$s4.at).TotalHours -ge 24 -and $o5.Count -eq 1 -and $o5[0] -match 'no total \(crashed\)')"; "cut detail: $($o4 -join ' ') | $($o5 -join ' ')"
'@; $ng = @(pwsh @np $nf (Join-Path $kc 'skills/crafty/lib.ps1') (Join-Path $kc 'skills/bossy/adapters/kit_admin.ps1') 2>&1)
Expect-Each $ng 'kit-admin: weekly full kit tests: #' 'busy', 'read', 'week', 'cut' -Show 6
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
$au = & { . $O; Get-KitHealthLinesAudit }; $null = pwsh -NoProfile -File $O board join -Type kitty -Run kit-fix-0303; $auK = & { . $O; Get-KitHealthLinesAudit }; $null = pwsh -NoProfile -File $O board leave -Agent kitty-kit-fix-0303; $st =& { . (Join-Path $kc 'skills/crafty/lib.ps1'); Get-KitPath last-kitty-audit -Create }; (Get-Date).ToString('s') | Set-Content $st; $au2 = & { . $O; Get-KitHealthLinesAudit }
Expect 'kit-admin: health nudges a never-run kitty audit, quiet while a kitty-<run> works and right after one' ("$au" -match 'Kit audit due \(last never, every 7 days\)' -and -not $auK -and -not $au2)
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
# forget on cap (kitbag_forget.py): scoring, archive / restore, retention, purge, the feature gate, the cap hooks
$fgD = Join-Path $kc 'fg'; $null = New-Item -ItemType Directory -Force $fgD; $fgRun = { & $py -X utf8 $KT forget @args 2>&1 | Out-String }
$fgL = Join-Path $fgD 'LESSONS-fg.md'
[IO.File]::WriteAllText($fgL, "## alpha`n- a hot case -> keep it (seen) (3×)`n- a cold case -> drop it (once)`n- (fixed in kit) an old case -> gone (fixed)`n- an owner case -> keep (owner, 2026-01-01)`n## Decisions`n- an ADR line`n")
$fo = & $fgRun --target $fgL --section alpha --to 2 --apply; $fgT = [IO.File]::ReadAllText($fgL)
Expect "forget: lessons over cap lose the fixed-in-kit line, then the lowest hits; owner lines and Decisions stay ($($fo.Trim()))" ($fgT -notmatch 'an old case|a cold case' -and $fgT -match 'a hot case' -and $fgT -match 'an owner case' -and $fgT -match 'an ADR line' -and $fo -match 'FORGOT .*2 item')
$fgId = [regex]::Match($fo, 'lessons-\d{8}-[0-9a-f]{6}').Value; $ro = & $fgRun --restore $fgId
$fgRet = Get-Content (Join-Path (TkPath $kc forgotten) 'retention.json') -Raw | ConvertFrom-Json
Expect "forget --restore puts the line back after its anchor and doubles the kind's retention 7 -> 14 d ($($ro.Trim()))" ($ro -match "restored $fgId" -and [IO.File]::ReadAllText($fgL) -match '(cold|old) case' -and $fgRet.kinds.lessons.days -eq 14)
[IO.File]::WriteAllText((Join-Path $fgD 'doc.md'), "# Doc`n## Used part`nkept: named elsewhere`n## Old notes`nnobody names this`n## Hard rules`nnever cut`n")
[IO.File]::WriteAllText((Join-Path $fgD 'ref.md'), "see doc.md `"Used part`"`n")
$fgDn = 'zq' + '_unused_fn'   # built: the literal name in this file would count as a call site
[IO.File]::WriteAllText((Join-Path $fgD 'tool.py'), "def used_fn():`n    return 1`n`ndef $($fgDn)():`n    return 2`n`nprint(used_fn())`n")
git -C $kc add fg 2>&1 | Out-Null; git -C $kc commit -q -m 'test: forget fixtures' 2>&1 | Out-Null
$fo = & $fgRun --target (Join-Path $fgD 'doc.md') --to 5 --apply --unused-days 0; $fgT = [IO.File]::ReadAllText((Join-Path $fgD 'doc.md'))
Expect "forget: an unreferenced section goes; a referenced one and a protected heading stay ($($fo.Trim()))" ($fgT -notmatch 'Old notes' -and $fgT -match 'Used part' -and $fgT -match 'Hard rules')
$fo = & $fgRun --target (Join-Path $fgD 'tool.py') --to 1 --apply; $fgB = [regex]::Match($fo, 'BATCH (fb-\S+):').Groups[1].Value
$co = & $fgRun --confirm $fgB --decision d-fg-1; $coRc = $LASTEXITCODE
Expect "forget: a feature (0 call sites) is never cut by --apply: one BATCH + decide ask; --confirm without an answer refuses (1) ($($co.Trim()))" ($fo -match "CONFIRM .*$fgDn" -and $fo -match 'decide ask' -and $fgB -and $coRc -eq 1 -and [IO.File]::ReadAllText((Join-Path $fgD 'tool.py')) -match $fgDn)
$fgDl = TkPath $kc decisions-log -Create
'{"at":"2026-01-01T00:00:00+00:00","event":"answered","id":"d-fg-0","item":"deploy-x","answer":"yes","by":"owner"}', ('{"at":"2026-01-01T00:00:00+00:00","event":"answered","id":"d-fg-2","item":"forget-' + $fgB + '","answer":"yet to decide","by":"owner"}') | Add-Content $fgDl
$c0 = & $fgRun --confirm $fgB --decision d-fg-0; $c2 = & $fgRun --confirm $fgB --decision d-fg-2
Expect "forget --confirm refuses a yes to another ask and a 'yet ...' answer ($($c0.Trim()) | $($c2.Trim()))" ($c0 -match 'not the owner' -and $c2 -match 'kept' -and [IO.File]::ReadAllText((Join-Path $fgD 'tool.py')) -match $fgDn)
Push-Location $kc; $fo = & $fgRun --target fg/tool.py --to 1 --apply; Pop-Location; $fgB = [regex]::Match($fo, 'BATCH (fb-\S+):').Groups[1].Value
('{"at":"2026-01-01T00:00:00+00:00","event":"answered","id":"d-fg-1","item":"forget-' + $fgDn + '","answer":"yes","by":"owner"}') | Add-Content $fgDl   # item may name the feature instead of the batch
$co = & $fgRun --confirm $fgB --decision d-fg-1
Expect "forget --confirm after the owner's yes removes the feature, archived, used_fn stays ($($co.Trim()))" ($co -match 'forgot 1 feature' -and [IO.File]::ReadAllText((Join-Path $fgD 'tool.py')) -notmatch $fgDn -and [IO.File]::ReadAllText((Join-Path $fgD 'tool.py')) -match 'used_fn')
$fgK = 'zq' + 'key'; $fgJ = Join-Path $fgD 'c.json'; [IO.File]::WriteAllText($fgJ, "{`n  `"_meta`": {`n    `"$fgK`": 1,`n    `"z`": 2`n  },`n  `"$fgK`": {`n    `"a`": 1`n  },`n  `"last`": 1`n}`n")
$jo = & $fgRun --target $fgJ --to 1
Expect "forget: a config key is the top-level one, never a nested key of the same name ($($jo.Trim()))" ($jo -match "CONFIRM fg/c\.json:6 `"$fgK`"" -and $jo -notmatch 'c\.json:3 ')
$fgQ = '```'; $fgM = Join-Path $fgD 'fence.md'; [IO.File]::WriteAllText($fgM, "# F`n## A`n$fgQ`n## never cut: not a heading`n$fgQ`n`n## Zq bee`nb text`n`n## Zq sea`nc text`n")
$fo = & $fgRun --target $fgM --to 1 --apply --unused-days 0; $fgC = [regex]::Matches($fo, 'doc-\d{8}-[0-9a-f]{6}') | ForEach-Object Value
$null = & $fgRun --restore $fgC[0]; $fgT = [IO.File]::ReadAllText($fgM) -split "`n"
Expect "forget --restore with a repeated anchor line (a code fence) lands after the nearest one, never inside the block ($($fgT -join '|'))" ($fgT[4] -eq '```' -and ($fgT[5..7] -join '|') -match '## Zq (bee|sea)')
$fgA = Join-Path (TkPath $kc forgotten) 'doc'; $null = New-Item -ItemType Directory -Force $fgA; 'x' | Set-Content (Join-Path $fgA '2026-01-01.md')
@{ kinds = @{ doc = @{ days = 28; restores = 1; since = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z').ToUnixTimeSeconds() } } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path (TkPath $kc forgotten) 'retention.json')
$p1 = & $fgRun --purge --now 2026-01-20T00:00:00+00:00; $kept = Test-Path (Join-Path $fgA '2026-01-01.md')
$p2 = & $fgRun --purge --now 2026-02-15T00:00:00+00:00; $fgRet = Get-Content (Join-Path (TkPath $kc forgotten) 'retention.json') -Raw | ConvertFrom-Json
Expect "forget --purge keeps an archive inside its kind's days (28), deletes it after, and halves days after a window with no restore ($($p2.Trim()))" ($kept -and $p2 -match 'deleted doc/2026-01-01.md' -and -not (Test-Path (Join-Path $fgA '2026-01-01.md')) -and $fgRet.kinds.doc.days -eq 14)
$fgP = Join-Path $fgD 'status.md'; [IO.File]::WriteAllText($fgP, "Deployed the fix to the test env today for the team.`nDeployed the fix to the test env today for the team.`nGenerated with a tool, nothing to read here at all.`nNever close the task before the retest has passed fully.`n")
$po = & $py -X utf8 $KT prose --kind comment-status $fgP 2>&1 | Out-String
Expect "prose over its word cap prints forget proposals: the duplicate first, a never-line protected ($($po.Trim()))" ($po -match 'FORGET PROPOSE .*status\.md:2 .*duplicate' -and $po -notmatch 'FORGET .*Never close')
[IO.File]::WriteAllText((Join-Path $fgD 'hook.md'), ("# Hook`n## Spare bit`nunused`n## Filler`n" + ('word ' * 2200))); $hk = Join-Path $root 'fg-hook.py'
Set-Content $hk @"
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location('kitbag', r'$KT'); kb = importlib.util.module_from_spec(spec); spec.loader.exec_module(kb); kb.load_plugins()
probs = [('BUDGET', 'fg/hook.md', '9 tokens (cap 1)')]
for h in kb.LINT_HOOKS:
    h(types.SimpleNamespace(dir=r'$kc'), probs, {'--warn': True, '--no-flow': True})
print(probs[0][2])
"@
$ho = & $py -X utf8 $hk 2>&1 | Select-Object -Last 1
Expect "lint BUDGET over cap names the forget candidates ($ho)" ("$ho" -match 'forget first: ## Spare bit' -and "$ho" -match 'kitbag.py forget --target fg/hook.md')
$null = & $lo -Skill zeta -When 'a first case' -Do 'act one' -Why 'why one'; $null = & $lo -Skill zeta -When 'a second case' -Do 'act two' -Why 'why two'; $null = & $lo -Skill zeta -Bump 'a first case'
$tr = & $lo -Skill zeta -Trim -Max 1; $ls = [IO.File]::ReadAllText((Join-Path $kc 'LESSONS.md'))
Expect "learn -Trim forgets by score (the bumped lesson stays), archives it, -History lists it ($($tr.Trim()))" ($ls -match 'a first case' -and $ls -notmatch 'a second case' -and $tr -match 'retired 1' -and (& $lo -History) -match 'a second case')
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
# setup -BrowserPolicy: browsers.chromePolicies -> HKCU policy values (idempotent, undo leaves no key); model folders in kit and Cypress profiles reported, -Clean deletes them
if ($IsWindows) {
  $k = New-TestKit kitadminbp; $O = Join-Path $k 'skills/bossy/bossy.ps1'
  $bpKey = "KitTest$PID"
  & $J @{ browsers = @{ chromePolicies = @{ "$bpKey/Chrome" = [ordered]@{ GenAILocalFoundationalModelSettings = 1; ComponentUpdatesEnabled = 0; Note = 'x' } } } } (Join-Path $k 'skills/crafty/kit.local.json')
  $bp = Invoke-PsTest browserpolicy @'
$env:APPDATA = Join-Path $args[1] 'appdata'; $null = . $args[0] 6>$null; $rt = "HKCU:\Software\$($args[2])"; $key = "$rt\$($args[2])\Chrome"
$elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
$dRx = '^browser policies: not written \(.*\): run once elevated \(one UAC prompt, same user\): .* -Verb RunAs -WindowStyle Hidden .*bossy\.ps1" setup -BrowserPolicy''$'
"denied:$($elev -or ((Set-KitBrowserPolicy) -match $dRx -and -not (Test-Path -LiteralPath "HKCU:\Software\Policies\$($args[2])")))"
New-Item -Path $rt -Force | Out-Null
$r1 = Set-KitBrowserPolicy -Root $rt; $p = Get-ItemProperty -LiteralPath $key
"set:$($r1 -match "$($args[2])/Chrome: GenAILocalFoundationalModelSettings=1, ComponentUpdatesEnabled=0, Note=x" -and $p.GenAILocalFoundationalModelSettings -eq 1 -and $p.ComponentUpdatesEnabled -eq 0 -and (Get-Item -LiteralPath $key).GetValueKind('Note') -eq 'String')"
"same:$(-not (Set-KitBrowserPolicy -Root $rt))"
Set-ItemProperty -LiteralPath $key -Name Note -Value 'admin'
$r2 = Set-KitBrowserPolicy -Undo -Root $rt; "undokeeps:$($r2 -match 'Chrome: GenAILocalFoundationalModelSettings, ComponentUpdatesEnabled$' -and (Get-ItemProperty -LiteralPath $key).Note -eq 'admin')"
Remove-ItemProperty -LiteralPath $key -Name Note; $null = Set-KitBrowserPolicy -Root $rt
$r3 = Set-KitBrowserPolicy -Undo -Root $rt; "undo:$($r3 -match '^browser policies removed: ' -and -not (Test-Path -LiteralPath "$rt\$($args[2])") -and (Test-Path -LiteralPath $rt))"
"undoagain:$(-not (Set-KitBrowserPolicy -Undo -Root $rt))"
$KitIsWindows = $false; "otheros:$((Set-KitBrowserPolicy -Root $rt) -match 'Windows' -and -not (Test-Path -LiteralPath $key))"; $KitIsWindows = $true
"nomodels:$(-not (Get-KitBrowserModelLine))"
foreach ($d in (Join-Path (Get-KitPath chrome-profiles -Create) 'stg__a/optimization_guide_model_store/13'), (Join-Path $env:APPDATA 'Cypress/cy/production/browsers/chrome-stable/run-1/OptGuideOnDeviceModel'), (Join-Path (Get-KitPath chrome-profiles) 'stg__a/Default/keep')) { New-Item -ItemType Directory -Force $d | Out-Null; [IO.File]::WriteAllBytes((Join-Path $d 'model.tflite'), [byte[]]::new(1MB)) }
"report:$((Get-KitBrowserModelLine) -match '^browser models: 2 folder\(s\), 2 MB left in test profiles; delete: bossy.ps1 setup -BrowserPolicy -Clean')"
$hk = @(Invoke-KitHooks Get-KitSetupLines); $null = Set-KitBrowserPolicy -Undo; "hook:$($hk.Count -eq 2 -and $hk[0] -match '^browser policies(?: set|: not written)' -and $hk[1] -match '^browser models: 2')"
"clean:$((Get-KitBrowserModelLine -Clean) -match '^browser models: deleted 2 folder' -and -not (Get-KitBrowserModelDirs) -and (Test-Path -LiteralPath (Join-Path (Get-KitPath chrome-profiles) 'stg__a/Default/keep/model.tflite')))"
'@ @($O, $k, $bpKey)
  Expect-Each $bp 'setup -BrowserPolicy: #' 'denied', 'set', 'same', 'undokeeps', 'undo', 'undoagain', 'otheros', 'nomodels', 'report', 'hook', 'clean' -Show 6
  foreach ($bk in "HKCU:\Software\$bpKey", "HKCU:\Software\Policies\$bpKey") { if (Test-Path -LiteralPath $bk) { Remove-Item -LiteralPath $bk -Recurse } }
} else { 'SKIP setup -BrowserPolicy (HKCU: Windows only)' }
Complete-Tests
