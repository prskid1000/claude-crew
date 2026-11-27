#Requires -Version 7
<#
wt-pool.tests.ps1: crafty.ps1 wt lease / release / pool (fixed worktree slots per repo), end to end: lease -> branch -> commit ->
push (the MR's branch) -> release -> fix round -> host merge -> release -> next task reuses the slot; queue, reaper, parking, migration.
Also (was wt-pool-2.tests.ps1): agents after board leave / handoff: lease waits (Remove-KitPoolWaits,
Test-KitPoolWaiterGone, the wait loop exits), messages to a left id (Resolve-KitMsgTarget) and the inbox on wt / check / checkpoint;
e2e lane portFiles (Use- / Restore-KitLanePortFiles); a slot leased to another agent (Get-KitSlotForeign); kit slots (parallel.kitty).
Usage: pwsh -NoProfile -File <kit>/tests/wt-pool.tests.ps1 (or tests/kit-tests.ps1 -Area wt-pool).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit pool; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $DT = Join-Path $k 'skills/crafty/devtools.py'
$base = Kd; $orig = "$base/origin.git"; $app = "$base/app"; $env:CLAUDE_WT_ROOT = "$base/wt"
git init -q --bare -b main $orig; git init -q -b main $app; 'v1' | Set-Content "$app/a.txt"; 1..30 | ForEach-Object { "f$_" | Set-Content "$app/f$_.txt" }
Save-GitRepo $app base; git -C $app remote add origin $orig; git -C $app push -q origin main 2>$null
& $J @{ repos = @(@{ name = 'app'; checkout = $app; target = 'main'; poolSize = 2 }); tracker = @{ type = 'none' }; pool = @{ wipRestore = @('one.txt') } } "$k/skills/crafty/kit.local.json"
$lease = { param($ag, $br, [int]$wm = 0) (pwsh @np $D wt lease -Repo app -Branch $br -Agent $ag -WaitMinutes $wm 2>&1 | ForEach-Object { "$_" }) -join "`n" }
$slotOf = { param($o) if ($o -match '(?m)^worktree: (.+)$') { $Matches[1].Trim().Replace('\', '/') } }
$falcon = "$base/wt/falcon-app".Replace('\', '/'); $kestrel = "$base/wt/kestrel-app".Replace('\', '/')
$atp = foreach ($atpIn in '', $src, "$base/nogit") { try { $null = if ($atpIn -like '*nogit') { Get-TestGitDir $atpIn } else { Assert-TestPath $atpIn }; 'kept' } catch { 'threw' } }
Expect "harness Assert-TestPath / Get-TestGitDir: an empty dir, one outside the test home, a non-repo throw (no `"/<name>`" write at the drive root) ($($atp -join ','))" (($atp -join ',') -eq 'threw,threw,threw' -and (Assert-TestPath $base) -eq $base)

# task 1: a new slot on a new branch, a commit, the MR's branch pushed
$o1 = & $lease devA feat/one; $s1 = & $slotOf $o1
'one' | Set-Content "$(Assert-TestPath $s1)/one.txt"; $c1 = pwsh @np $D wt commit -Dir $s1 -Message 'feat: one' 2>&1 | Out-String; git -C $s1 push -q -u origin feat/one 2>$null
Expect "lease: the first slot created lazily (app·Falcon), the branch new from origin/main ($($o1 -replace '\s+', ' '))" ($o1 -match 'new slot app·Falcon \(pool 1/2\)' -and $s1 -eq $falcon -and (git -C $s1 branch --show-current) -eq 'feat/one' -and $o1 -match 'new, from origin/main' -and (git -C $s1 log -1 --format=%s) -eq 'feat: one')
$o2 = & $lease devB feat/two; $o3 = & $lease devC feat/three; $o4 = & $lease devB feat/one
Expect "lease: a second slot up to poolSize; all leased -> no slot within -WaitMinutes; a branch another agent holds -> refused" ($o2 -match 'new slot app·Kestrel' -and $o3 -match 'no app slot free within 0 min' -and $o4 -match 'two agents never share a slot')
# retro 2205: -Agent from KIT_AGENT, -Repo / -Branch from the linked worktree at -Dir; outside one, the error names what is missing
$lm = (pwsh @np $D wt lease -Dir (Kd) -WaitMinutes 0 2>&1 | ForEach-Object { "$_" }) -join ' '; $env:KIT_AGENT = 'devA'
$ld = (pwsh @np $D wt lease -Dir $s1 -WaitMinutes 0 2>&1 | ForEach-Object { "$_" }) -join "`n"; $lo = (pwsh @np $D wt lease -Dir $s1 -Repo (Kd) -WaitMinutes 0 2>&1 | ForEach-Object { "$_" }) -join ' '; Remove-Item Env:KIT_AGENT
Expect "lease: defaults from KIT_AGENT + the slot at -Dir (same slot back); another -Repo never takes its branch; none -> names -Agent -Branch -Repo ($lm | $lo | $(& $slotOf $ld))" ($lm -match 'lease needs -Agent -Branch -Repo:' -and $lo -match 'lease needs -Branch:' -and (& $slotOf $ld) -eq $s1)
$lb = (pwsh @np $D wt lease -Repo app -Agent devA -WaitMinutes 0 2>&1 | ForEach-Object { "$_" }) -join "`n"
Expect "lease: no -Branch outside a worktree -> the agent's last leased branch on that repo, same slot ($(& $slotOf $lb))" ($lb -match '(?m)^default:  -Branch feat/one ' -and (& $slotOf $lb) -eq $s1)
$py1 = & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools; print(devtools.target_of(r'$s1'))" 2>&1 | Select-Object -Last 1
Expect "devtools.py mr / merge read the slot's target record ($py1)" ("$py1".Trim() -eq 'main')

# release with uncommitted work: a WIP commit on the branch, the slot detached in place (no file written), branch kept
'wip' | Set-Content "$(Assert-TestPath $s1)/two.txt"; 'rewritten by a test run' | Set-Content "$s1/one.txt"; $null = New-Item -Force "$s1/cypress/reports/r.json" -Value '{}'; $r1 = pwsh @np $D wt release -Agent devA 2>&1 | Out-String
Expect "release: uncommitted work -> WIP commit; detached at the same commit; the unmerged branch kept ($($r1 -replace '\s+', ' '))" ($r1 -match 'WIP commit' -and $r1 -match 'released app·Falcon' -and $r1 -match 'branch feat/one kept' -and -not (git -C $s1 branch --show-current) -and (git -C $app log -1 --format=%s feat/one) -match '^wip: ' -and "$(git -C $s1 status --porcelain)".Trim() -eq '?? cypress/' -and
  "$(git -C $app show --name-only --format= feat/one)".Trim() -eq 'two.txt' -and (Get-Content "$s1/one.txt") -eq 'one')   # pool.wipRestore: one.txt restored, not committed; untracked cypress/reports output left out

# fix round: another agent re-leases by branch: the warm slot that had it
$o5 = & $lease devA2 feat/one
Expect "fix round: re-lease by branch takes the slot that last had it, the local branch as is, the WIP commit there" ((& $slotOf $o5) -eq $falcon -and $o5 -match 'local branch, as is' -and (git -C $falcon log -1 --format=%s) -match '^wip: ')
git -C $falcon push -q origin feat/one 2>$null
$mg = "$base/merger"; git clone -q $orig $mg 2>$null; git -C $mg merge -q --no-ff -m 'merge feat/one' origin/feat/one 2>$null; 'b' | Set-Content "$mg/f1.txt"; 'c' | Set-Content "$mg/f2.txt"; git -C $mg commit -q -am 'feat: main moves'; git -C $mg push -q origin main 2>$null; git -C $app fetch -q origin 2>$null
$r2 = pwsh @np $D wt release -Agent devA2 2>&1 | Out-String
Expect "release after the host merge: slot back, the merged local branch deleted ($($r2 -replace '\s+', ' '))" ($r2 -match 'branch feat/one deleted \(merged' -and -not (git -C $app branch --list feat/one))

# next task reuses the slot: only the diff is written, no new slot, no area record left
'x' | Set-Content "$base/scope.txt"; $o6 = & $lease devD feat/four
$scf = Join-Path "$(git -C $falcon rev-parse --path-format=absolute --git-dir)" 'claude-scope'
Expect "next task reuses the slot clean: no new slot, files changed by the switch < a fresh checkout, no scope record ($(($o6 -split "`n" | Select-String 'files:') -replace '\s+', ' '))" ((& $slotOf $o6) -eq $falcon -and $o6 -notmatch 'new slot' -and $o6 -match 'files:\s+2 changed by the switch, not 3[0-9] written' -and -not (Test-Path $scf) -and @(Get-ChildItem "$base/wt" -Directory).Count -eq 2)

# a slot is never removed; sweep leaves it; pool lists the states (the refusal is an error record: wrapped at the host width)
$rm = pwsh @np $D wt remove -Dir $falcon 2>&1 | Out-String; $sw = pwsh @np $D wt sweep -DryRun -IdleHours 0 2>&1 | Out-String; $pl = pwsh @np $D wt pool 2>&1 | Out-String
Expect "remove refuses a slot, sweep skips slots, pool lists them ($(($pl -split "`n")[0].Trim()))" (($rm -replace '\s*\|\s*|\s+', ' ') -match 'is a pool slot: never deleted' -and $sw -notmatch 'falcon-app|kestrel-app' -and $pl -match 'pool app: 2/2 slots, 0 free' -and $pl -match 'app·Falcon\s+leased\s+feat/four\s+devD')

# reaper: a holder gone past the grace -> another agent's lease reclaims the clean slot
$kf = TkPath $k 'wt-slots'; $kl = Get-Content "$kf/kestrel-app.json" -Raw | ConvertFrom-Json
$kl.agent = 'ghost'; $kl | Add-Member -Force holderPid 999999; $kl | Add-Member -Force seen (Get-Date).AddMinutes(-30).ToString('o'); $kl | Add-Member -Force graceMin 10
$kl | ConvertTo-Json | Set-Content "$kf/kestrel-app.json"; Remove-Item Env:CLAUDE_AGENT -ErrorAction SilentlyContinue
$o7 = & $lease devE feat/five
Expect "reaper: a slot with no live holder past the grace is reclaimed by the next lease" ((& $slotOf $o7) -eq $kestrel -and (Get-Content (TkPath $k leases) -Raw) -match '"reclaim".*app·Kestrel.*ghost|ghost.*reclaim')

# a WIP commit the hooks refuse (no hook skip: guard) -> the work goes to a patch file, the slot frees; the branch's next lease prints it
$hd = "$base/hooks"; New-Item -ItemType Directory -Force $hd | Out-Null; "#!/bin/sh`nexit 1" | Set-Content "$hd/pre-commit" -NoNewline; git -C $app config core.hooksPath $hd; 'u' | Set-Content "$kestrel/u.txt"; 'v2' | Set-Content "$kestrel/a.txt"; 'k' | Set-Content "$kestrel/api-credentials.json"; New-Item -ItemType Directory -Force "$kestrel/cfg" | Out-Null; 'k' | Set-Content "$kestrel/cfg/.env"; 'c' | Set-Content "$kestrel/cfg/c.txt"
$r3 = pwsh @np $D wt release -Agent devE 2>&1 | Out-String; git -C $app config --unset core.hooksPath; $wpr = Get-ChildItem (TkPath $k wip-patches) -Filter '*.patch' | Get-Content -Raw
$sec = $r3 -match 'kept untracked api-credentials.json, cfg/.env \(secret-named, never committed\)' -and (Test-Path "$kestrel/api-credentials.json") -and (Test-Path "$kestrel/cfg/.env") -and $wpr -notmatch 'credentials|\.env' -and $wpr -match 'cfg/c\.txt'
Expect "release: untracked secret-named files (one in a new folder) are never patched or committed, they stay and are named" $sec; Remove-Item "$kestrel/api-credentials.json", "$kestrel/cfg" -Recurse
$o9 = & $lease devG feat/five; $wpf = if ($o9 -match '(?m)^WIP patch of feat/five: git -C \S+ apply --3way (\S+\.patch)') { $Matches[1] }; git -C $kestrel apply --3way $wpf 2>$null
Expect "refused WIP: a patch file, the slot released clean; the same branch's lease prints it, it restores both files ($($r3 -replace '\s+', ' '))" ($r3 -match 'saved to \S+feat_five~\w+\.patch' -and $r3 -notmatch 'PARKED' -and (& $slotOf $o9) -eq $kestrel -and $wpf -and (Get-Content "$kestrel/u.txt") -eq 'u' -and (Get-Content "$kestrel/a.txt") -eq 'v2')
Remove-Item -LiteralPath $wpf

$br = pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') release -Agent devG -Reason 'agent finished' 2>&1 | Out-String
Expect "bossy.ps1 release -Agent: its slot released too (re-applied files -> WIP commit) ($($br.Trim()))" ($br -match 'devG slot: released app·Kestrel' -and (git -C $app log -1 --format=%s feat/five) -match '^wip: ' -and -not (Test-Path "$kf/kestrel-app.json"))
# migration: a merged per-task worktree goes, one with unpushed work is kept and listed
$null = pwsh @np $D wt release -Agent devD 2>&1; git -C $app worktree add -q -b old/merged "$base/wt/old1-app" origin/main 2>$null; git -C $app worktree add -q -b old/wip "$base/wt/old2-app" origin/main 2>$null
'w' | Set-Content "$base/wt/old2-app/w.txt"; git -C "$base/wt/old2-app" add -A; git -C "$base/wt/old2-app" commit -q -m wip
$mi = pwsh @np $D wt pool -Migrate 2>&1 | Out-String
Expect "pool -Migrate: merged per-task worktree removed, unpushed one kept with its reason ($($mi -replace '\s+', ' '))" ($mi -match 'gone\s+\S*old1-app \(old/merged\)' -and -not (Test-Path "$base/wt/old1-app") -and $mi -match 'keep\s+\S*old2-app \(old/wip\): 1 commit' -and (Test-Path "$base/wt/old2-app"))
& $J @{ repos = @(@{ name = 'app'; checkout = $app; target = 'main'; poolSize = 2 }); tracker = @{ type = 'none'; branchRx = '(?<id>T-\d+)' } } "$k/skills/crafty/kit.local.json"
$wn = (pwsh @np $D wt new -Repo app -Branch f/T-1-x -Target main -Name z 2>&1 | Out-String) -replace '\s+(\|\s+)?', ' '   # the error view wraps
Expect "wt new refuses a task branch of a pooled repo (wt lease)" ($wn -match 'has a worktree pool and f/T-1-x is a task branch: .*wt lease -Repo' -and -not (Test-Path "$base/wt/z-app"))
# a parked slot whose resuming lease fails after the switch (a missing dep source): parked again with its files, never orphaned
$o10 = & $lease devH feat/seven; $s10 = & $slotOf $o10; 'p' | Set-Content "$(Assert-TestPath $s10)/p.txt"; git -C $s10 switch -q --detach; $null = pwsh @np $D wt release -Agent devH 2>&1   # detached + dirty: parked
& $J @{ repos = @(@{ name = 'app'; checkout = $app; target = 'main'; poolSize = 2; linkFromByTarget = @{ main = "$base/no-deps" } }); tracker = @{ type = 'none' } } "$k/skills/crafty/kit.local.json"
$o11 = & $lease devI feat/seven; $pf = Get-ChildItem $kf -Filter '*-app.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.branch -eq 'feat/seven' }
Expect "a failed resume of a parked slot parks it again (files kept, parkedAt set), the lease file stays ($($o11 -replace '\s+', ' '))" ($o11 -match 'dep source .* is missing' -and $pf.parked -and $pf.parkedAt -and (Test-Path "$s10/p.txt"))
# repo sync (wt pool): behind -> fast-forwarded (checked out + clean too), diverged listed, gone + merged and a lane branch with no worktree pruned; warm slots made
$so = "$base/sync.git"; $sr = "$base/syn"; $sx = "$base/syn-other"; git init -q --bare -b main $so; git clone -q $so $sr 2>$null; 'a' | Set-Content "$sr/a.txt"; Save-GitRepo $sr s0; git -C $sr push -q origin main 2>$null
foreach ($b in 'beh', 'div', 'gone') { git -C $sr branch -q $b; git -C $sr push -q -u origin $b 2>$null }
git clone -q $so $sx 2>$null; foreach ($b in 'main', 'beh', 'div') { git -C $sx checkout -q $b; "$b+" | Set-Content "$sx/$b.txt"; Save-GitRepo $sx "$b up"; git -C $sx push -q origin $b 2>$null }
git -C $sr checkout -q div; 'local' | Set-Content "$sr/l.txt"; Save-GitRepo $sr 'div local'; git -C $sr checkout -q main; git -C $sr push -q origin --delete gone 2>$null; git -C $sr branch -q lane/syn-falcon
& $J @{ repos = @(@{ name = 'syn'; checkout = $sr; target = 'main'; poolSize = 3; poolWarm = 1 }); tracker = @{ type = 'none' } } "$k/skills/crafty/kit.local.json"
$tip = { param($r) "$(git -C $sr rev-parse $r)".Trim() }; $pv = pwsh @np $D wt pool -Repo syn 2>&1 | Out-String; $behPv = (& $tip beh) -ne (& $tip origin/beh)   # plain pool: a preview, nothing moves
$sp = pwsh @np $D wt pool -Repo syn -Sync 2>&1 | Out-String
$syj = Get-Content (Join-Path (TkPath $k wt-slots) 'sync/syn.json') -Raw | ConvertFrom-Json
Expect "repo sync: main (checked out, clean) and beh fast-forwarded, div diverged kept, gone (merged) + lane/syn-falcon pruned, 1 warm slot ($(($sp -split "`n")[0].Trim()))" ((& $tip main) -eq (& $tip origin/main) -and (& $tip beh) -eq (& $tip origin/beh) -and (& $tip div) -ne (& $tip origin/div) -and -not (git -C $sr branch --list gone lane/syn-falcon) -and @($syj.diverged) -match '^div ' -and $sp -match '1 warm slot' -and $sp -match 'pool syn: 1/3 slots, 1 free' -and $behPv -and $pv -match 'sync syn: 2 fast-forwarded')
# never under a live agent: a leased slot's branch behind upstream is not moved; a free slot with commits on no branch is not detached
$wsl = "$base/wt/falcon-syn"; 'x' | Set-Content "$wsl/strand.txt"; git -C $wsl add -A; git -C $wsl commit -q -m strand; $strand = "$(git -C $wsl rev-parse HEAD)".Trim(); $null = pwsh @np $D wt pool -Repo syn -Sync 2>&1; $stOk = "$(git -C $wsl rev-parse HEAD)".Trim() -eq $strand -and @((Get-Content (Join-Path (TkPath $k wt-slots) 'sync/syn.json') -Raw | ConvertFrom-Json).dirty) -match 'holds commits on no branch'
git -C $sx checkout -q beh; 'more' | Set-Content "$sx/beh2.txt"; Save-GitRepo $sx 'beh more'; git -C $sx push -q origin beh 2>$null
$ls = pwsh @np $D wt lease -Repo syn -Branch beh -Agent devS 2>&1 | Out-String; $lsd = if ($ls -match '(?m)^worktree: (.+)$') { $Matches[1].Trim() }; $b0 = & $tip beh
$sp2 = pwsh @np $D wt pool -Repo syn -Sync 2>&1 | Out-String; $syj2 = Get-Content (Join-Path (TkPath $k wt-slots) 'sync/syn.json') -Raw | ConvertFrom-Json
Expect "repo sync: a leased slot's branch stays (listed), a stranded detached commit is kept ($(@($syj2.dirty) -join ' | '))" ($lsd -and (& $tip beh) -eq $b0 -and @($syj2.dirty) -match 'leased slot' -and $stOk)
# git writes: a preview reuses a fetch under 10 min old; gc only from a sync with no slot leased; kit git (lib.ps1, kitbag.py) never auto-gcs
$fhp = "$sr/.git/FETCH_HEAD"; $fh0 = (Get-Item $fhp).LastWriteTime; $null = pwsh @np $D wt pool -Repo syn 2>&1; $fh1 = (Get-Item $fhp).LastWriteTime
(Get-Item $fhp).LastWriteTime = (Get-Date).AddMinutes(-11); $null = pwsh @np $D wt pool -Repo syn 2>&1; $fh2 = (Get-Item $fhp).LastWriteTime
$gx = @{ GIT_CONFIG_COUNT = $null; GIT_CONFIG_KEY_0 = $null; GIT_CONFIG_VALUE_0 = $null }; $gx0 = @{}; foreach ($n in $gx.Keys) { $gx0[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $gx[$n]) }
$gPs = "$(& $pwshExe -NoProfile -Command ". '$src/skills/crafty/lib.ps1'; . '$src/skills/crafty/lib.ps1'; '{0} {1}' -f `$env:GIT_CONFIG_COUNT, (git config maintenance.auto)")".Trim()
$gPy = "$(& $py -X utf8 -c "import sys, subprocess; sys.path.insert(0, r'$src/skills/bossy'); import kitbag, os; print(os.environ['GIT_CONFIG_COUNT'], subprocess.run(['git', 'config', 'maintenance.auto'], capture_output=True, text=True).stdout.strip())")".Trim()
foreach ($n in $gx.Keys) { [Environment]::SetEnvironmentVariable($n, $gx0[$n]) }
Expect "git writes: preview fetch reused under 10 min, refreshed after; sync gc only unleased ($($syj.maint)/$($syj2.maint)); lib.ps1 '$gPs', kitbag '$gPy' set maintenance.auto=false once" ($fh1 -eq $fh0 -and $fh2 -gt (Get-Date).AddMinutes(-5) -and $syj.maint -eq $true -and $syj2.maint -eq $false -and $gPs -eq '1 false' -and $gPy -eq '1 false')
# K38 verdicts: a squash-merged branch with no upstream (the MR merged a rebased copy) goes; a dead lane goes when only its test merges
# are local, stays with its own commit; a merged worktree whose only leftovers are edited tracked files: patch saved, then removed
$vb = "$base/vb"; git clone -q $orig $vb 2>$null; $mk = { param($b, $msg) git -C $vb checkout -q -b $b origin/main; "$b" | Set-Content "$vb/$($b -replace '/', '_').txt"; Save-GitRepo $vb $msg; "$(git -C $vb rev-parse HEAD)".Trim() }
$null = & $mk 'sq' 'fix: sq'; $rb = & $mk 'sq-rb' 'fix: sq +hook'; $null = & $mk 'lane/old-a' 'localenv layer x (a)'; $null = & $mk 'lane/old-b' 'mine'; git -C $vb checkout -q --detach origin/main
$vr = Invoke-PsTest verdicts @'
. $args[0]; $ast = [Management.Automation.Language.Parser]::ParseFile($args[1], [ref]$null, [ref]$null)
foreach ($fd in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-KitWorktrees' }, $true)) { . ([scriptblock]::Create($fd.Extent.Text)) }
$rb = $args[3]; $vrp = $args[2]; function Get-MergedMrs { param($R, $B) if ($B -eq 'sq') { @([pscustomobject]@{ iid = 7; sha = $rb }) } }
@('sq', 'lane/old-a', 'lane/old-b') | ForEach-Object { $x = Get-KitBranchVerdict $vrp $_ @{} -IdleHours 0; "$_=$($x.delete) ($($x.why))" }
'@ @((Join-Path $k 'skills/crafty/lib.ps1'), (Join-Path $k 'skills/crafty/crafty.ps1'), $vb, $rb)
$fw = "$base/wt/fx-app"; git -C $app worktree add -q -b old/fx $fw origin/main 2>$null; 'regen' | Set-Content "$fw/a.txt"; [IO.File]::WriteAllText("$fw/f1.txt", "crlf`r`nkept`r`n")
$fm = pwsh @np $D wt pool -Migrate 2>&1 | Out-String; $pt = @(Get-ChildItem (Join-Path (TkPath $k wt-slots) 'patches') -Filter 'patch-*.patch' -ErrorAction SilentlyContinue | Where-Object Name -match '^patch-[a-z0-9-]+\.patch$')   # patch-<slot words>, no counter
$null = git -C $vb apply --check $pt[0].FullName 2>&1; $fm += " apply-check:$LASTEXITCODE"
Expect "K38: squash-merged rebased branch goes, dead lane with only test merges goes, with its own commit stays; merged worktree with edited fixtures: patch, then gone ($(@($vr) -join ' ') | $($fm -replace '\s+', ' '))" ((@($vr) -join ' ') -match 'sq=True .*lane/old-a=True .*lane/old-b=False' -and $fm -match 'patched\s+\S*fx-app' -and $fm -match 'apply-check:0' -and -not (Test-Path $fw) -and $pt.Count -eq 1 -and (Get-Content $pt[0].FullName -Raw) -match '\+regen')
# a stray non-lease file in wt-slots (an array, as lanes.json was): supervise, wt release and bossy release skip it (K42)
Set-Content "$kf/stray.json" '[{"lane":"x","parked":true,"parkedAt":"2026-01-01T00:00:00Z","since":"2026-01-01T00:00:00Z","agent":"devZ"},{"lane":"y","parked":true,"parkedAt":"2026-01-02T00:00:00Z","agent":"devZ"}]'
$sg = Invoke-PsTest stray-slot @'
. $args[0]; foreach ($a in @(Get-ChildItem $args[1] -Filter '*.ps1')) { . $a.FullName }; $now = Get-Date; try { $o = @(Get-KitSuperviseGuardResources); "stray:$(-not @($o | Where-Object { "$($_.what)" -match 'devZ|slot \S* parked' }).Count)" } catch { "stray:ERR $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
'@ @((Join-Path $k 'skills/crafty/lib.ps1'), (Join-Path $k 'skills/bossy/adapters'))
$wr = pwsh @np $D wt release -Agent devZ 2>&1 | Out-String
Expect "a stray array file in wt-slots: supervise resources sweep runs, no slot flag from it; wt release ignores it ($(@($sg) -join ' ') | $($wr.Trim()))" ((@($sg) -join ' ') -match 'stray:True' -and $wr -match 'no slot held by devZ' -and (Test-Path "$kf/stray.json"))
# K40: the learned warm count = p90 of 7 days of leased-slot samples + 1; a free slot unused 7+ days goes when 3 days stayed under it, one a day
$pu = & { . (Join-Path $k 'skills/crafty/lib.ps1'); function Get-KitCheckoutName { 'app' }; $now = [datetime]'2026-02-10T12:00:00'; $f = Get-KitPath pool-usage -Create
  $smp = @(0..40 | ForEach-Object { , @($now.AddHours(-4 * $_).ToString('o'), $(if ($_ % 10 -eq 0) { 2 } else { 1 })) })
  Write-KitState $f ([ordered]@{ repos = [ordered]@{ app = [ordered]@{ samples = $smp; used = [ordered]@{ '1' = $now.AddDays(-1).ToString('o'); '2' = $now.AddDays(-2).ToString('o'); '3' = $now.AddDays(-9).ToString('o'); '4' = $now.AddDays(-9).ToString('o') }; shrunk = '' } } })
  $sl = @(1..4 | ForEach-Object { [pscustomobject]@{ n = $_; file = (Join-Path (Kd) "none-$_.json") } })
  $r1 = Update-KitPoolUsage 'x' 10 2 $sl $now; $null = Update-KitPoolUsage 'x' 10 2 @() $now.AddHours(1) -Shrunk; $r2 = Update-KitPoolUsage 'x' 10 2 $sl $now.AddHours(2); $r3 = Update-KitPoolUsage 'x' 2 2 $sl $now.AddDays(2)
  "$($r1.target)|$($r1.drop -join ',')|$($r2.drop -join ',')|$($r3.target)|$(@((Read-KitState $f).repos.app.samples).Count)" }
Expect "pool: learned warm = p90 + 1 (capped by the pool size), idle candidates newest first, none for a day after a removal, samples kept 7 days ($pu)" ($pu -eq '3|4,3||2|33')
# K55: one lane name in shown text (ids kept in paths, logs, branch names and -Json); -Env takes the shown name; ui-check LANE-ID
$lnt = & { . (Join-Path $k 'skills/crafty/lib.ps1'); $__cfg = [pscustomobject]@{ localEnv = [pscustomobject]@{ envs = [pscustomobject]@{ shop = [pscustomobject]@{ lanes = [pscustomobject]@{ max = 3 } } } } }
  @(@('shop2 · api', 'shop · db', 'env shop', '[shop3] up', 'shop2-api.log', 'lane/shop-kestrel', 'workshop2 · x', 'shop2 &#183; web', 'env shop&#183;Falcon J', 'lane shop&middot;Falcon', 'env shop·Falcon', 'env shop&#xB7;Falcon', 'shop &middot; db') | ForEach-Object { ConvertTo-KitLaneText $_ }) -join '|'
  "from:$(ConvertFrom-KitLaneLabel 'shop·Kestrel')/$(ConvertFrom-KitLaneLabel 'SHOP-OSPREY')/$(ConvertFrom-KitLaneLabel 'other')"
  "out:$(@('x shop2' | ConvertTo-KitLaneOut $false) + @('x shop2' | ConvertTo-KitLaneOut $true) -join '/')"
  $spk = [pscustomobject]@{ what = 'ERROR SPIKE: 1 new error line(s) in C:\x\shop2-api.log'; kind = 'ERROR SPIKE'; who = 'shop2 api'; problem = '1 new error line in shop2 api log' }
  "ack:$(Test-KitAcked $spk @('ERROR SPIKE · shop·Kestrel api'))/$(Test-KitAcked $spk @('ERROR SPIKE · shop2 api'))/$(Test-KitAcked $spk @('ERROR SPIKE · shop·Osprey api'))" }
# laneIds bird: records from before the rename (shop · api, shop2, lane shop) show and group under the bird id
$lnb = & { . (Join-Path $k 'skills/crafty/lib.ps1'); $__cfg = [pscustomobject]@{ localEnv = [pscustomobject]@{ laneIds = 'bird'; envs = [pscustomobject]@{ shop = [pscustomobject]@{ lanes = [pscustomobject]@{ max = 2 } } } } }
  "$(@('shop &#183; api', 'shop2 · web', 'env shop', 'shop-falcon · api', 'workshop · x') | ForEach-Object { ConvertTo-KitLaneText $_ })|$(@('shop · api', 'lane shop2', 'shop2', 'shop-kestrel · db', 'other · x') | ForEach-Object { ConvertTo-KitLaneId $_ })" }
Expect "lane ids bird: old ids shown and grouped as the bird id ($lnb)" ($lnb -eq 'shop·Falcon &#183; api shop·Kestrel · web env shop·Falcon shop·Falcon · api workshop · x|shop-falcon · api lane shop-kestrel shop-kestrel shop-kestrel · db other · x')
# N3 laneIds nn: lane-<10 x env index + k>, the bird shown only; old and bird ids alias to it; branch lane/<nn>, worktree lane-<nn>-<repo> (the bird one = -Old);
# a phone's lane-<nn> outside a lane context stays; pool slots slot-<nn>-<repo>, shown <repo>·slot-<nn>
$lnn = & { . (Join-Path $k 'skills/crafty/lib.ps1'); $__cfg = [pscustomobject]@{ localEnv = [pscustomobject]@{ laneIds = 'nn'; envs = [pscustomobject][ordered]@{ shop = [pscustomobject]@{ lanes = [pscustomobject]@{ max = 2 } }; 'shop-kestrel' = [pscustomobject]@{}; desk = [pscustomobject]@{} } } }
  "$((Get-KitLaneNames) -join ',')|$(Get-KitPoolLabel env 'lane-02')|$(Get-KitPoolLabel env 'lane-11')|$(ConvertTo-KitLaneId 'shop2 · api')/$(ConvertTo-KitLaneId 'lane shop-kestrel')/$(ConvertTo-KitLaneId 'desk · web')|$(ConvertFrom-KitLaneLabel 'shop·Kestrel')/$(ConvertFrom-KitLaneLabel 'SHOP-KESTREL')/$(ConvertFrom-KitLaneLabel 'shop2')|$(Get-KitLaneBranch 'lane-02')|$(Split-Path (Get-KitLaneWorktree 'lane-02' 'C:/r/app' -New) -Leaf)/$(Split-Path (Get-KitLaneWorktree 'lane-02' 'C:/r/app' -Old) -Leaf)|$(ConvertTo-KitLaneText 'lane-02 · api')/$(ConvertTo-KitLaneText 'phone lane-02 up')/$(ConvertTo-KitLaneText 'phone lane-02 · 2 GB')|$(Get-KitSlotLeaf 3 'web')/$(Get-KitSlotName 3 'web')" }
Expect "lane ids nn: lane-01,02,11; labels shop·Kestrel / desk·Falcon; aliases; lane/02, lane-02-app (old lane-shop-kestrel-app); text; slot-03-web ($lnn)" ($lnn -eq 'lane-01,lane-02,lane-11|shop·Kestrel|desk·Falcon|lane-02 · api/lane lane-02/lane-11 · web|lane-02/lane-02/lane-02|lane/02|lane-02-app/lane-shop-kestrel-app|shop·Kestrel · api/phone lane-02 up/phone lane-02 · 2 GB|slot-03-web/web·slot-03')
# laneIds "bird" (the default scheme, owner 2026-11-24): a new slot gets a bird (<bird>-<repo>, <repo>·<Bird>), a lane its bird branch and worktree
$lbd = & { . (Join-Path $k 'skills/crafty/lib.ps1'); $__cfg = [pscustomobject]@{ localEnv = [pscustomobject]@{ laneIds = 'bird'; envs = [pscustomobject][ordered]@{ 'shop-falcon' = [pscustomobject]@{}; 'shop-kestrel' = [pscustomobject]@{} } } }
  "$(Get-KitSlotLeaf 3 'web')/$(Get-KitSlotName 3 'web')|$(Get-KitLaneBranch 'shop-kestrel')|$(Split-Path (Get-KitLaneWorktree 'shop-kestrel' 'C:/r/app' -New) -Leaf)" }
Expect "lane ids bird: slot osprey-web / web·Osprey, lane branch lane/shop-kestrel, worktree lane-shop-kestrel-app ($lbd)" ($lbd -eq 'osprey-web/web·Osprey|lane/shop-kestrel|lane-shop-kestrel-app')
Set-JsonFile (Join-Path $k 'skills/crafty/kit.local.json') @{ localEnv = @{ envs = @{ shop = @{ lanes = @{ max = 2 } } } } }; $lp = Join-Path (Kd) 'lanes.html'
Set-Content $lp "<html><body><p>env shop·Kestrel</p><p>shop2 &#183; api</p><script>var a='shop2'</script></body></html>"
$lhit = python -X utf8 -c "import sys; sys.argv=['kitbag.py']; sys.path.insert(0, r'$k/skills/bossy'); import kitbag; print(len(kitbag.lane_ids_shown(r'$lp', r'$k')))"
# K61b: linkFromByTarget.<t> as a list: per package folder the first store that has its node_modules
$mono = "$base/mono"; git init -q -b main $mono; '{}' | Set-Content "$mono/package.json"; New-Item -ItemType Directory -Force "$mono/sub" | Out-Null; '{}' | Set-Content "$mono/sub/package.json"
Save-GitRepo $mono base; $monoO = "$base/mono.git"; git init -q --bare -b main $monoO; git -C $mono remote add origin $monoO; git -C $mono push -q origin main 2>$null
foreach ($dm in "$base/storeA/node_modules/a-mark", "$base/storeB/sub/node_modules/b-mark", "$base/storeB/node_modules/wrong-mark") { New-Item -ItemType Directory -Force $dm | Out-Null }
Set-JsonFile (Join-Path $k 'skills/crafty/kit.local.json') @{ repos = @(@{ name = 'mono'; checkout = $mono; target = 'main'; linkFromByTarget = @{ main = @("$base/storeA", "$base/storeB") } }); tracker = @{ type = 'none' } }
$dl = (pwsh @np $D wt new -Repo mono -Branch feat/deps -Target main -Name dl 2>&1 | Out-String); $dlw = "$base/wt/dl-mono"
Expect "wt new: linkFromByTarget list -> root node_modules from the first store, sub/node_modules from the second (the first lacks it) ($(($dl -split "`n" | Select-String 'linked') -replace '\s+', ' '))" ((Test-Path "$dlw/node_modules/a-mark") -and -not (Test-Path "$dlw/node_modules/wrong-mark") -and (Test-Path "$dlw/sub/node_modules/b-mark") -and $dl -match 'storeA, .*storeB')
# -Target <feature branch> (not in linkFromByTarget): deps from the worktree on that branch, never the main checkout (retro 2026-11-25)
git -C $dlw push -q origin feat/deps 2>$null; $fbOut = (pwsh @np $D wt new -Repo mono -Branch feat/stack -Target feat/deps -Name fb 2>&1 | Out-String); $fbw = "$base/wt/fb-mono"
Expect "wt new -Target <feature branch>: node_modules linked from that branch's worktree ($(($fbOut -split "`n" | Select-String 'link') -replace '\s+', ' '))" ((Test-Path "$fbw/node_modules/a-mark") -and $fbOut -match 'linking dependencies from \S*dl-mono')
Expect "lane names: ids shown as <product>·<Bird> (paths, branches, other words kept), -Env takes the shown name, -Json keeps ids; ui-check counts a bare id outside scripts ($($lnt -join ' | ') | $lhit)" ($lnt[0] -eq 'shop·Kestrel · api|shop·Falcon · db|env shop·Falcon|[shop·Osprey] up|shop2-api.log|lane/shop-kestrel|workshop2 · x|shop·Kestrel &#183; web|env shop&#183;Falcon J|lane shop&middot;Falcon|env shop·Falcon|env shop&#xB7;Falcon|shop·Falcon &middot; db' -and $lnt[1] -eq 'from:shop2/shop3/other' -and $lnt[2] -eq 'out:x shop·Kestrel/x shop2' -and $lnt[3] -eq 'ack:True/True/False' -and "$lhit".Trim() -eq '1')
# a leftover folder (no worktree) whose only files are a test kit's runtime scratch (a *.local.* too) is disposable: wt remove deletes it
$loRt = & { . (Lib); Split-Path (Get-KitRuntime) -Leaf }; $lo = "$base/wt/lo-left"; New-Item -ItemType Directory -Force "$lo/$loRt/t" | Out-Null; 'x' | Set-Content "$lo/$loRt/t/k.local.json"
$loOut = pwsh @np $D wt remove -Dir $lo -Root "$base/wt" 2>&1 | Out-String
Expect "wt remove: a leftover with only runtime scratch (a *.local.* file too) is removed ($($loOut.Trim()))" (-not (Test-Path $lo))
# a kit worktree's leftover (<name>-.claude): its files are in the kit's own history
Save-GitRepo $k kit; $kl = "$base/wt/kt-$(Split-Path $k -Leaf)"; New-Item -ItemType Directory -Force "$kl/skills/crafty" | Out-Null; Copy-Item "$k/skills/crafty/lib.ps1" "$kl/skills/crafty/"
$kl1 = pwsh @np $D wt remove -Dir $kl -Root "$base/wt" 2>&1 | Out-String; $kl0 = Test-Path $kl
Expect "wt remove: a kit worktree leftover whose files are in the kit's history is removed ($($kl1.Trim()))" (-not $kl0)
# gate owner with no CLAUDE_AGENT: a slot's build is its lease holder's, a lane worktree's "lane <env>·<Bird>" ("builds per agent" read falcon, kestrel)
Remove-TestKit $k; $k = New-TestKit owner-name; & $J @{ localEnv = @{ envs = @{ shop = @{ lanes = @{ max = 2 }; services = @() } } } } (Join-Path $k 'skills/crafty/kit.local.json')
$on = Invoke-PsTest owner-name @'
. $args[0]
@{ slot = 'app·Falcon'; agent = 'J1'; path = 'D:/w/falcon-app' } | ConvertTo-Json | Set-Content (Join-Path (Get-KitPath wt-slots -Create) 'falcon-app.json')
"$(Get-KitBuildOwner 'falcon-app' 'app' 'D:\w\falcon-app')|$(Get-KitBuildOwner 'kestrel-app' 'app' 'D:\w\kestrel-app')|$(Get-KitBuildOwner 'lane-shop-kestrel-app' 'app' 'D:\w\lane-shop-kestrel-app')"
'@ @((Join-Path $k 'skills/crafty/lib.ps1'))
Expect "gate owner: a leased slot's build is its agent's, a free slot keeps its name, a lane worktree reads lane shop·Kestrel ($(@($on) -join ' '))" ((@($on) -join ' ') -eq 'J1|kestrel|lane shop·Kestrel')
# ENV-FIX 2026-11-25: a service running from the env worktree held a tracked file open; git reset could not unlink it, every train crashed
Remove-TestKit $k; $k = New-TestKit tree; $ted = New-Item -ItemType Directory -Force (Join-Path $k 'skills/envy/adapters'); Copy-Item (Join-Path $src 'skills/envy/envy.ps1') (Split-Path $ted)
Copy-Item @((Join-Path $src 'skills/envy/adapters/shared-builds.ps1'), (Join-Path $src 'skills/envy/adapters/lane-standard.ps1')) $ted; $TL = Join-Path $k 'skills/envy/envy.ps1'
$tg = Kd; git init -q -b main "$tg/o"; Set-Content "$tg/o/f.txt" v1; git -C "$tg/o" add .; git -C "$tg/o" -c user.name=t -c user.email=t@t commit -qm init; git clone -q "$tg/o" "$tg/c" 2>$null
& $J @{ repos = @(@{ name = 'r'; checkout = "$tg/c"; target = 'main' }); localEnv = @{ envs = @{ t = @{ services = @(@{ name = 'py'; repo = 'r'; start = 'x' }, @{ name = 'jar'; repo = 'r'; start = 'x'; artifact = 'app.jar' }, @{ name = 'idle'; repo = 'r'; start = 'x' }) } } } } (Join-Path $k 'skills/crafty/kit.local.json') 8
$th = & { . $TL; function Sync-DepLinks { }; $script:thStop = @(); $script:thStart = @()
  function Stop-Svc([string]$se, $ss) { $script:thStop += $ss.name; Update-State $se { param($z) $z.services[$ss.name].status = 'down' } }
  function Start-Svc([string]$se, $ss, [int]$rel) { $script:thStart += "$($ss.name)@$rel" }
  Update-State t { param($x) $x.services = @{ py = @{ status = 'up'; release = 4 }; jar = @{ status = 'up'; release = 4 }; idle = @{ status = 'down'; release = 4 } } }
  $rr = [pscustomobject]@{ name = 'r'; wt = "$tg/c"; target = 'main'; cfg = [pscustomobject]@{ checkout = "$tg/c" } }
  $null = Sync-Repo t $rr @() -NoFetch -KeepRunning; $kept = $script:thStop.Count
  $null = Sync-Repo t $rr @() -NoFetch; $held = @($script:TreeStopped) -join ','
  Restart-TreeStopped t -Keep @('r'); $kept += $script:thStart.Count; Restart-TreeStopped t @('r') 5; Restart-TreeStopped t @('r') 5
  "$kept|$($script:thStop -join ',')|$held|$($script:thStart -join ',')|$($script:TreeStopped.Count)" }
Expect "sync: a service running from the env worktree (no artifact) stops before the reset, none with -KeepRunning (lanes -Sync); -Keep leaves it to the switch-over; the train restarts it once on the new release ($th)" ($th -eq '0|py|py|py@5|0')
$tsw = (Get-Content $TL -Raw) -match 'TreeStopped\.Contains\(\$_\.name\) -or \(\$_\.artifact' -and (Get-Content $TL -Raw) -match 'Restart-TreeStopped \$e \$changed \$newN' -and (Get-Content $TL -Raw) -match 'Restart-TreeStopped \$e -Keep' -and [regex]::Matches((Get-Content $TL -Raw), 'kept the running release \(\$err\)"\);[^\n]{0,160}Sync-Repo \$e \S+ @\(\$cur\[\$rn\]\) -NoFetch; continue').Count -eq 2
Expect "train: services the sync stopped join the switch-over; the rest restart before the smoke checks (a failed build puts the tree back first), in Record-Train and after a crash ($tsw)" $tsw
Remove-TestKit $k
# ---- was wt-pool-2.tests.ps1 (its own test kit)
$k = New-TestKit pool2
# coordinator 2026-11-25: a handed-off agent's wt lease kept waiting (an orphan pwsh refreshed wait/<agent>-<repo>.json); its successor queued behind it
$owTest = Invoke-PsTest pool-orphan-wait @"
. '$k/skills/crafty/lib.ps1'; `$wd = Join-Path (Get-KitPath wt-slots -Create) 'wait'; New-Item -ItemType Directory -Force `$wd | Out-Null; `$bd = Get-KitPath board -Create
`$t0 = (Get-Date).AddMinutes(-5).ToString('o'); `$t1 = (Get-Date).ToString('o')
@{ agent = 'devQ'; repo = 'app'; since = `$t0; token = 'x' } | ConvertTo-Json | Set-Content (Join-Path `$wd 'devQ-app.json'); @{ agent = 'devR'; repo = 'app'; since = `$t0 } | ConvertTo-Json | Set-Content (Join-Path `$wd 'devR-app.json')
"removed:`$((Remove-KitPoolWaits devQ) -join ',') kept:`$(Test-Path (Join-Path `$wd 'devR-app.json'))"
"never-joined:`$(Test-KitPoolWaiterGone devZ `$t0)"
@{ agent = 'devQ'; status = 'left'; beat = `$t1 } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devQ-1.json'); "left-after:`$(Test-KitPoolWaiterGone devQ `$t0)"
"left-before:`$(Test-KitPoolWaiterGone devQ (Get-Date).AddMinutes(1).ToString('o'))"
@{ agent = 'devQ'; status = 'active'; beat = `$t1 } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devQ-2.json'); "successor-live:`$(Test-KitPoolWaiterGone devQ `$t0)"
"@
$owOut = $owTest -join ' '
Expect "pool: board leave removes only the leaving agent's queued waits; a waiter stops once its agent left after the wait began, never for one that never joined, left before it, or has a live successor row ($owOut)" ($owOut -match 'removed:devQ-app kept:True' -and $owOut -match 'never-joined:False' -and $owOut -match 'left-after:True' -and $owOut -match 'left-before:False' -and $owOut -match 'successor-live:False')
$lsrc = Get-Content (Join-Path $k 'skills/crafty/adapters/wt-pool.ps1') -Raw; $bsrc = Get-Content (Join-Path $k 'skills/bossy/bossy.ps1') -Raw
Expect "pool: the lease wait loop exits on a removed / replaced wait file or a gone agent, and its finally keeps a newer waiter's file; board leave calls Remove-KitPoolWaits" ($lsrc -match 'if \(-not \(& \$ownWait\)\) \{ throw' -and $lsrc -match 'if \(-not \(& \$ownWait\)\) \{ return \$null \}' -and $lsrc -match 'Test-KitPoolWaiterGone \$Agent \$since' -and $lsrc -match 'finally \{ if \(& \$ownWait\)' -and $bsrc -match 'Remove-KitPoolWaits \$script:leftEntry\.agent')
# coordinator 2026-11-25: 9 TASK CLOCK nudges to a workflow agent's left id never arrived: a msg goes to the live row of the same run,
# area and type; the agent's next wt / check / checkpoint call prints its unread messages (stderr)
$mbTest = Invoke-PsTest board-msg-left @"
. '$k/skills/crafty/lib.ps1'; `$bd = Get-KitPath board -Create; `$now = (Get-Date).ToString('o')
@{ agent = 'devy-old'; type = 'devy'; run = 'r1'; area = 'a1'; status = 'left'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-old-1.json')
@{ agent = 'devy-90'; type = 'devy'; run = 'r1'; area = 'a1'; status = 'step 4'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-90-1.json')
@{ agent = 'devy-lone'; type = 'devy'; run = 'r2'; area = 'a2'; status = 'left'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-lone-1.json')
Send-BoardMsg 'supervise' 'devy-old' 'TASK CLOCK: open the MR'; Send-BoardMsg 'supervise' 'devy-lone' 'kept'
"to:`$script:KitMsgTo new:`$(Test-Path (Get-InboxFile 'devy-90')) lone:`$(Test-Path (Get-InboxFile 'devy-lone'))"
Show-KitVerbInbox @('release', '-Agent', 'devy-90'); `$env:KIT_AGENT = 'coordinator'; Show-KitVerbInbox @('lease', '-Agent', 'devy-90'); Remove-Item Env:KIT_AGENT
Show-KitVerbInbox @('lease', '-Repo', 'x', '-Agent', 'devy-90'); Show-KitVerbInbox @('lease', '-Agent', 'devy-90'); Show-KitVerbInbox @('lease', '-Agent', 'devy-lone')
"@
$mbOut = $mbTest -join ' // '
Expect "board msg: a left id's message goes to the live agent of its run + area (a lone one stays); wt / check / checkpoint print the unread ones once, never a left agent's ($mbOut)" ($mbOut -match 'to:devy-lone new:True lone:True' -and @([regex]::Matches($mbOut, '\[inbox\] MESSAGE for devy-90 \(do what it says\): \d\d:\d\d from supervise: TASK CLOCK: open the MR')).Count -eq 1 -and $mbOut -notmatch 'MESSAGE for devy-lone' -and (Get-Content (Join-Path $k 'skills/crafty/crafty.ps1') -Raw) -match "if \(\`$__verb -in 'wt', 'check', 'checkpoint'\) \{ try \{ Show-KitVerbInbox")
# coordinator 2026-11-26: a successor resumed in its area's slot without leasing it; the old holder's lease ran out and the slot went
# to a third agent while the successor's board row still listed it: a dead holder's slot lease moves to the live row that lists it
$mvTest = Invoke-PsTest pool-slot-claim @"
. '$k/skills/crafty/lib.ps1'; `$bd = Get-KitPath board -Create; `$now = (Get-Date).ToString('o'); `$wtp = Join-Path '$k' 'wt/osprey-app'; `$sf = Get-KitSlotFile 'osprey-app'
`$mk = { @{ slot = 'app·Osprey'; n = 3; path = `$wtp; branch = 'f/x'; agent = 'devy-gone'; holderPid = 999999; holderStart = '2020-01-01T00:00:00Z'; at = `$now; seen = (Get-Date).AddHours(-2).ToString('o') } | ConvertTo-Json | Set-Content `$sf; Read-KitSlotLease `$sf }
@{ agent = 'devy-gone'; status = 'left'; beat = `$now } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-gone-1.json')
@{ agent = 'devy-quit'; session = 'devy-quit-1'; status = 'left'; beat = `$now; pid = `$PID; pidStart = (Get-KitPidStart `$PID); worktrees = @(`$wtp) } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-quit-1.json')
`$l0 = & `$mk; "left-claim:`$(Update-KitLease `$l0)/`$(`$l0.agent)"
@{ agent = 'devy-next'; session = 'devy-next-1'; run = 'r9'; status = 'step 2'; beat = `$now; pid = `$PID; pidStart = (Get-KitPidStart `$PID); worktrees = @('C:/other', `$wtp.Replace('\', '/')) } | ConvertTo-Json | Set-Content (Join-Path `$bd 'devy-next-1.json')
`$script:KitJsonMemo = `$null; `$l1 = & `$mk; `$r1 = Update-KitLease `$l1; `$s1 = Read-KitSlotLease `$sf
"live-claim:`$r1/`$(`$l1.agent)/`$(`$s1.agent)/`$(`$s1.session)/`$(`$s1.run)/`$(`$null -eq `$s1.graceMin)/`$(Update-KitLease `$s1)"
`$lg = @(Get-Content (Get-KitLogFile leases) | ForEach-Object { `$_ | ConvertFrom-Json } | Where-Object name -eq 'app·Osprey' | ForEach-Object { "`$(`$_.event):`$(`$_.agent)" }) -join ','
"log:`$lg"; `$lp = & `$mk; Set-KitProp `$lp parked `$true; "parked:`$(Move-KitSlotLease `$lp)"
`$lgr = & `$mk; Set-KitProp `$lgr seen `$now; "grace:`$(Update-KitLease `$lgr)/`$(`$lgr.agent)"
`$lsm = & `$mk; Set-KitProp `$lsm agent 'devy-next'; Set-KitProp `$lsm session 'devy-next-0'; "same-id:`$(Update-KitLease `$lsm)/`$(`$lsm.session)"
"@
$mvOut = $mvTest -join ' '
Expect "pool: a slot lease with no live holder moves to the live agent whose board row lists the slot (saved, logged reclaim + acquire, live after); a left row's claim, a parked slot or a holder still in its grace: never; a successor with the same id and a new session gets it ($mvOut)" ($mvOut -match 'grace:True/devy-gone' -and $mvOut -match 'same-id:True/devy-next-1' -and $mvOut -match 'left-claim:False/devy-gone' -and $mvOut -match 'live-claim:True/devy-next/devy-next/devy-next-1/r9/True/True' -and $mvOut -match 'log:reclaim:devy-gone,acquire:devy-next' -and $mvOut -match 'parked:False')
# coordinator 2026-11-25: an api suite reads its URLs from cypress/data/config.ts (devys hand-edited it): tests.e2e.run[].portFiles
# get the lane's ports for the run and are put back after; a file with its own edits is refused; a killed run is restored first
$pfRepo = Join-Path (Kd) 'pf-repo'; New-Item -ItemType Directory -Force "$pfRepo/cypress/data" | Out-Null; Set-Content "$pfRepo/cypress/data/config.ts" "serverUrl: 'http://localhost:8443'"; Set-Content "$pfRepo/b.ts" "u: 'http://localhost:8443'"; Save-GitRepo $pfRepo base
$pfTest = Invoke-PsTest port-files @"
. '$k/skills/crafty/lib.ps1'; `$fx = { param([string]`$t) `$t -replace ':8443', ':8543' }; `$cf = '$pfRepo/cypress/data/config.ts'
Use-KitLanePortFiles '$pfRepo' @('cypress/data/config.ts', 'gone.ts') `$fx; "run:`$((Get-Content `$cf -Raw).Trim())|mark:`$(Test-Path (Get-KitPortFilesMark '$pfRepo'))"
Use-KitLanePortFiles '$pfRepo' @('cypress/data/config.ts') `$fx; "again:`$((Get-Content `$cf -Raw).Trim())"
Restore-KitLanePortFiles '$pfRepo'; "after:`$((Get-Content `$cf -Raw).Trim())|mark:`$(Test-Path (Get-KitPortFilesMark '$pfRepo'))|clean:`$(-not (git -C '$pfRepo' status --porcelain))"
Set-Content `$cf "serverUrl: 'http://localhost:8443' // mine"; try { Use-KitLanePortFiles '$pfRepo' @('b.ts', 'cypress/data/config.ts') `$fx; 'own:written' } catch { "own:refused|b:`$((Get-Content '$pfRepo/b.ts' -Raw).Trim())" }
"@
$pfOut = $pfTest -join ' // '
Expect "e2e portFiles: lane ports written for the run (a missing file skipped), a second run restores the first, put back after (clean tree); a file with its own edits refused; crafty runs it in try / finally ($pfOut)" ($pfOut -match "run:serverUrl: 'http://localhost:8543'\|mark:True" -and $pfOut -match "again:serverUrl: 'http://localhost:8543'" -and $pfOut -match "after:serverUrl: 'http://localhost:8443'\|mark:False\|clean:True" -and $pfOut -match "own:refused\|b:u: 'http://localhost:8443'" -and (Get-Content (Join-Path $k 'skills/crafty/crafty.ps1') -Raw) -match 'Invoke-KitE2eRuns \$st\.dir \$runs @\(if \(\$ln\) \{ \$recipe\.portFiles \}\)' -and (Get-Content (Join-Path $k 'skills/crafty/adapters/wt-pool.ps1') -Raw) -match '\} finally \{ Restore-KitLanePortFiles \$Dir \}')
# wt new / lease -Scope and devtools.py --scope: a brace glob keeps its commas (reported twice: 'src/{main' and 'test}/**' as two globs)
$bgS = 'src/{main,test}/java/**, docs/**,web/{a,b}/*.ts'; $bgSep = ',(?![^{}]*\})'
$bgP = & { . (Lib) *>$null; @(Split-KitList $bgS -Sep $bgSep) -join '|' }
$bgSrc = @('skills/crafty/crafty.ps1', 'skills/crafty/adapters/wt-pool.ps1' | Where-Object { -not (Get-Content (Join-Path $src $_) -Raw).Contains("Split-KitList `$Scope -Sep '$bgSep'") })
$bgY = & $py -X utf8 -c "import sys; sys.path.insert(0, sys.argv[1]); import devtools as d; g = d.scope_of('', sys.argv[2]); print('|'.join(g) + ' / ' + '|'.join(d.scope_dropped(sys.argv[2], lambda: g + ['x/**'])))" (Join-Path $src 'skills/crafty') $bgS
Expect "scope globs: a brace glob is one glob in wt new / lease -Scope and devtools.py --scope ($bgP ; $bgY ; $($bgSrc -join ','))" ($bgP -eq 'src/{main,test}/java/**|docs/**|web/{a,b}/*.ts' -and "$bgY" -eq "$bgP / x/**" -and -not $bgSrc.Count)
# coordinator 2026-11-26: a round's successor deployed from its old slot after the pool re-leased it (another agent's branch went live
# as its layer): envy deploy, wt commit and wt sync refuse a slot leased to another agent
$sfRepo = Join-Path (Kd) 'sf-repo'; New-Item -ItemType Directory -Force $sfRepo | Out-Null; Set-Content "$sfRepo/a.txt" 'a'; Save-GitRepo $sfRepo base
$sfSlot = Join-Path (Kd) 'heron-sf'; git -C $sfRepo worktree add -q --detach $sfSlot 2>$null | Out-Null
Set-Content (Join-Path "$(git -C $sfSlot rev-parse --absolute-git-dir)" 'claude-slot') '2'
$sfAssert = Join-Path (Kd) 'sf-assert.ps1'; Set-Content $sfAssert ". '$k/skills/crafty/lib.ps1'; Assert-KitSlotOwn '$sfSlot' 'devy-signup' 'commit'; 'passed'"
$sfTest = Invoke-PsTest slot-foreign @"
. '$k/skills/crafty/lib.ps1'; `$sff = Get-KitSlotFile 'heron-sf'
@{ slot = 'sf-Heron'; n = 2; repo = '$sfRepo'; path = '$sfSlot'; branch = 'f/theirs'; agent = 'devy-kyc'; since = '2026-01-02T03:04:05Z' } | ConvertTo-Json | Set-Content `$sff
"other:`$(Get-KitSlotForeign '$sfSlot' 'devy-signup')"; "holder:[`$(Get-KitSlotForeign '$sfSlot' 'devy-kyc')]"; "noid:[`$(Get-KitSlotForeign '$sfSlot' '')]"; `$env:KIT_AGENT = 'devy-signup'; "envid:`$(Get-KitSlotForeign '$sfSlot' '')"; Remove-Item Env:KIT_AGENT; "repo:[`$(Get-KitSlotForeign '$sfRepo' 'devy-signup')]"
`$sfa = @(pwsh -NoProfile -File '$sfAssert' 2>&1); "assert:`$LASTEXITCODE|`$(`$sfa -join ' ')"
Remove-Item -LiteralPath `$sff; "free:[`$(Get-KitSlotForeign '$sfSlot' 'devy-signup')]"
"@
$sfOut = $sfTest -join ' // '; $sfCrafty = Get-Content (Join-Path $k 'skills/crafty/crafty.ps1') -Raw; $sfEnvy = Get-Content (Join-Path $src 'skills/envy/envy.ps1') -Raw
Expect "pool: a slot leased to another agent is refused with its holder and the wt lease command; the holder, a free slot, a plain repo or no caller id pass; envy deploy, wt commit and wt sync call it ($sfOut)" ($sfOut -match 'other:\S+ is pool slot sf-Heron, leased to devy-kyc \(no live holder yet\) on f/theirs since .+wt lease -Repo sf-repo -Branch <your branch> -Agent devy-signup' -and $sfOut -match 'holder:\[\]' -and $sfOut -match 'noid:\[\]' -and $sfOut -match 'envid:\S+ is pool slot sf-Heron, leased to devy-kyc' -and $sfOut -match 'repo:\[\]' -and $sfOut -match 'free:\[\]' -and $sfOut -match 'assert:1\|commit refused: \S+ is pool slot sf-Heron' -and $sfOut -notmatch 'passed' -and $sfCrafty -match "Assert-KitSlotOwn \`$Dir \`$Agent 'wt sync'" -and $sfCrafty -match "Assert-KitSlotOwn \`$Dir \`$Agent 'commit'" -and $sfEnvy -match 'Assert-KitSlotOwn \$dd \$Agent "envy\.ps1: \[\$e\] deploy"')
# kit slots (owner 2026-11-27: up to 3 kitty at once): parallel.kitty slots of the kit's own clone, wt new refused, a 3rd waits; the sync never moves the live clone
$ksBase = Kd; $ksD = Join-Path $k 'skills/crafty/crafty.ps1'; $env:CLAUDE_WT_ROOT = "$ksBase/wt"; Save-GitRepo $k kit
git init -q --bare -b main "$ksBase/kit.git"; git -C $k branch -M main; git -C $k remote add origin "$ksBase/kit.git"; git -C $k push -q -u origin main 2>$null; git -C $k symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
& $J @{ tracker = @{ type = 'none' }; parallel = @{ kitty = 2 } } "$k/skills/crafty/kit.local.json"
$kLease = { param($ag, $br) (pwsh @np $ksD wt lease -Repo $k -Branch $br -Agent $ag -WaitMinutes 0 2>&1 | ForEach-Object { "$_" }) -join "`n" }
$kn = (pwsh @np $ksD wt new -Repo $k -Branch kit/n -Target main -Name kn 2>&1 | Out-String) -replace '\s*\|\s*|\s+', ' '
$kq1 = & $kLease kitty-1 kit/one; $kq2 = & $kLease kitty-2 kit/two; $kq3 = & $kLease kitty-3 kit/three
Expect "kit slots: wt new refused, 2 slots (parallel.kitty) leased as .claude·Falcon / Kestrel, a 3rd kitty waits ($($kq3 -replace '\s+', ' '))" ($kn -match 'wt new refused: the kit has 2 kit slots' -and $kq1 -match 'new slot \.claude·Falcon \(pool 1/2\)' -and $kq2 -match 'new slot \.claude·Kestrel \(pool 2/2\)' -and $kq3 -match 'no \.claude slot free within 0 min' -and (Test-Path "$ksBase/wt/falcon-.claude"))
$ksClone = "$ksBase/kitc"; git clone -q "$ksBase/kit.git" $ksClone 2>$null; 'n' | Set-Content "$ksClone/new.txt"; Save-GitRepo $ksClone 'feat: ahead'; git -C $ksClone push -q origin main 2>$null
$kh0 = "$(git -C $k rev-parse HEAD)".Trim(); $null = pwsh @np $ksD wt release -Agent kitty-1 2>&1; $ks = pwsh @np $ksD wt pool -Repo $k -Sync 2>&1 | Out-String
$kq4 = & $kLease kitty-3 kit/three; $kf = "$ksBase/wt/falcon-.claude"
Expect "kit slots: the sync leaves the live clone's main behind (named), a released slot goes to the waiter on a fresh origin/main ($(($ks -split "`n" | Select-String 'kept') -join ' '))" ("$(git -C $k rev-parse HEAD)".Trim() -eq $kh0 -and $ks -match 'main behind 1 \(the live kit clone' -and $kq4 -match '\.claude·Falcon' -and (Test-Path "$kf/new.txt") -and (git -C $kf branch --show-current) -eq 'kit/three')
$ksSlotRun = pwsh @np "$kf/skills/crafty/crafty.ps1" wt pool -Repo $k -Sync 2>&1 | Out-String   # review R4: a slot's own crafty.ps1 ($KitConf.Kit = the slot)
Expect "kit slots: a sync run from a kit slot's crafty.ps1 still leaves the live clone alone ($(($ksSlotRun -split "`n" | Select-String 'kept') -join ' '))" ("$(git -C $k rev-parse HEAD)".Trim() -eq $kh0 -and $ksSlotRun -match 'the live kit clone')
Remove-TestKit $k
Complete-Tests
