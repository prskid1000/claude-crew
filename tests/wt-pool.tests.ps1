#Requires -Version 7
<#
wt-pool.tests.ps1: crafty.ps1 wt lease / release / pool (fixed worktree slots per repo), end to end: lease -> branch -> commit ->
push (the MR's branch) -> release -> fix round -> host merge -> release -> next task reuses the slot; queue, reaper, parking, migration.
Usage: pwsh -NoProfile -File <kit>/tests/wt-pool.tests.ps1 (or tests/kit-tests.ps1 -Area wt-pool).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit pool; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $DT = Join-Path $k 'skills/crafty/devtools.py'
$base = Kd; $orig = "$base/origin.git"; $app = "$base/app"; $env:CLAUDE_WT_ROOT = "$base/wt"
git init -q --bare -b main $orig; git init -q -b main $app; 'v1' | Set-Content "$app/a.txt"; 1..30 | ForEach-Object { "f$_" | Set-Content "$app/f$_.txt" }
Save-GitRepo $app base; git -C $app remote add origin $orig; git -C $app push -q origin main 2>$null
& $J @{ repos = @(@{ name = 'app'; checkout = $app; target = 'main'; poolSize = 2 }); tracker = @{ type = 'none' } } "$k/skills/crafty/kit.local.json"
$lease = { param($ag, $br, [int]$wm = 0) (pwsh @np $D wt lease -Repo app -Branch $br -Agent $ag -WaitMinutes $wm 2>&1 | ForEach-Object { "$_" }) -join "`n" }
$slotOf = { param($o) if ($o -match '(?m)^worktree: (.+)$') { $Matches[1].Trim().Replace('\', '/') } }
$falcon = "$base/wt/falcon-app".Replace('\', '/'); $kestrel = "$base/wt/kestrel-app".Replace('\', '/')

# task 1: a new slot on a new branch, a commit, the MR's branch pushed
$o1 = & $lease devA feat/one; $s1 = & $slotOf $o1
'one' | Set-Content "$s1/one.txt"; $c1 = pwsh @np $D wt commit -Dir $s1 -Message 'feat: one' 2>&1 | Out-String; git -C $s1 push -q -u origin feat/one 2>$null
Expect "lease: the first slot created lazily (app·Falcon), the branch new from origin/main ($($o1 -replace '\s+', ' '))" ($o1 -match 'new slot app·Falcon \(pool 1/2\)' -and $s1 -eq $falcon -and (git -C $s1 branch --show-current) -eq 'feat/one' -and $o1 -match 'new, from origin/main' -and (git -C $s1 log -1 --format=%s) -eq 'feat: one')
$o2 = & $lease devB feat/two; $o3 = & $lease devC feat/three; $o4 = & $lease devB feat/one
Expect "lease: a second slot up to poolSize; all leased -> no slot within -WaitMinutes; a branch another agent holds -> refused" ($o2 -match 'new slot app·Kestrel' -and $o3 -match 'no app slot free within 0 min' -and $o4 -match 'two agents never share a slot')
$py1 = & $py -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $DT)'); import devtools; print(devtools.target_of(r'$s1'))" 2>&1 | Select-Object -Last 1
Expect "devtools.py mr / merge read the slot's target record ($py1)" ("$py1".Trim() -eq 'main')

# release with uncommitted work: a WIP commit on the branch, the slot detached in place (no file written), branch kept
'wip' | Set-Content "$s1/two.txt"; $r1 = pwsh @np $D wt release -Agent devA 2>&1 | Out-String
Expect "release: uncommitted work -> WIP commit; detached at the same commit; the unmerged branch kept ($($r1 -replace '\s+', ' '))" ($r1 -match 'WIP commit' -and $r1 -match 'released app·Falcon' -and $r1 -match 'branch feat/one kept' -and -not (git -C $s1 branch --show-current) -and (git -C $app log -1 --format=%s feat/one) -match '^wip: ' -and -not (git -C $s1 status --porcelain))

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

# a slot is never removed; sweep leaves it; pool lists the states
$rm = pwsh @np $D wt remove -Dir $falcon 2>&1 | Out-String; $sw = pwsh @np $D wt sweep -DryRun -IdleHours 0 2>&1 | Out-String; $pl = pwsh @np $D wt pool 2>&1 | Out-String
Expect "remove refuses a slot, sweep skips slots, pool lists them ($(($pl -split "`n")[0].Trim()))" ($rm -match 'is a pool slot: never deleted' -and $sw -notmatch 'falcon-app|kestrel-app' -and $pl -match 'pool app: 2/2 slots, 0 free' -and $pl -match 'app·Falcon\s+leased\s+feat/four\s+devD')

# reaper: a holder gone past the grace -> another agent's lease reclaims the clean slot
$kf = TkPath $k 'wt-slots'; $kl = Get-Content "$kf/kestrel-app.json" -Raw | ConvertFrom-Json
$kl.agent = 'ghost'; $kl | Add-Member -Force holderPid 999999; $kl | Add-Member -Force seen (Get-Date).AddMinutes(-30).ToString('o'); $kl | Add-Member -Force graceMin 10
$kl | ConvertTo-Json | Set-Content "$kf/kestrel-app.json"; Remove-Item Env:CLAUDE_AGENT -ErrorAction SilentlyContinue
$o7 = & $lease devE feat/five
Expect "reaper: a slot with no live holder past the grace is reclaimed by the next lease" ((& $slotOf $o7) -eq $kestrel -and (Get-Content (TkPath $k leases) -Raw) -match '"reclaim".*app·Kestrel.*ghost|ghost.*reclaim')

# parked: a WIP commit the hooks refuse -> the slot keeps the branch and its files, only that branch gets it
$hd = "$base/hooks"; New-Item -ItemType Directory -Force $hd | Out-Null; "#!/bin/sh`nexit 1" | Set-Content "$hd/pre-commit" -NoNewline; git -C $app config core.hooksPath $hd; 'u' | Set-Content "$kestrel/u.txt"
$r3 = pwsh @np $D wt release -Agent devE 2>&1 | Out-String; git -C $app config --unset core.hooksPath
$o8 = & $lease devF feat/six; $o9 = & $lease devG feat/five
Expect "parked: dirty + refused WIP keeps the files; another branch waits, the same branch resumes it ($($r3 -replace '\s+', ' '))" ($r3 -match 'PARKED app·Kestrel' -and (Test-Path "$kestrel/u.txt") -and $o8 -match 'no app slot free' -and (& $slotOf $o9) -eq $kestrel)

$br = pwsh @np (Join-Path $k 'skills/bossy/bossy.ps1') release -Agent devG -Reason 'agent finished' 2>&1 | Out-String
Expect "bossy.ps1 release -Agent: its slot released too (resumed parked files -> WIP commit) ($($br.Trim()))" ($br -match 'devG slot: released app·Kestrel' -and (git -C $app log -1 --format=%s feat/five) -match '^wip: ' -and -not (Test-Path "$kf/kestrel-app.json"))
# migration: a merged per-task worktree goes, one with unpushed work is kept and listed
$null = pwsh @np $D wt release -Agent devD 2>&1; git -C $app worktree add -q -b old/merged "$base/wt/old1-app" origin/main 2>$null; git -C $app worktree add -q -b old/wip "$base/wt/old2-app" origin/main 2>$null
'w' | Set-Content "$base/wt/old2-app/w.txt"; git -C "$base/wt/old2-app" add -A; git -C "$base/wt/old2-app" commit -q -m wip
$mi = pwsh @np $D wt pool -Migrate 2>&1 | Out-String
Expect "pool -Migrate: merged per-task worktree removed, unpushed one kept with its reason ($($mi -replace '\s+', ' '))" ($mi -match 'gone\s+\S*old1-app \(old/merged\)' -and -not (Test-Path "$base/wt/old1-app") -and $mi -match 'keep\s+\S*old2-app \(old/wip\): 1 commit' -and (Test-Path "$base/wt/old2-app"))
& $J @{ repos = @(@{ name = 'app'; checkout = $app; target = 'main'; poolSize = 2 }); tracker = @{ type = 'none'; branchRx = '(?<id>T-\d+)' } } "$k/skills/crafty/kit.local.json"
$wn = (pwsh @np $D wt new -Repo app -Branch f/T-1-x -Target main -Name z 2>&1 | Out-String) -replace '\s+(\|\s+)?', ' '   # the error view wraps
Expect "wt new refuses a task branch of a pooled repo (wt lease)" ($wn -match 'has a worktree pool and f/T-1-x is a task branch: .*wt lease -Repo' -and -not (Test-Path "$base/wt/z-app"))
# a parked slot whose resuming lease fails after the switch (a missing dep source): parked again with its files, never orphaned
$o10 = & $lease devH feat/seven; $s10 = & $slotOf $o10; 'p' | Set-Content "$s10/p.txt"; git -C $app config core.hooksPath $hd; $null = pwsh @np $D wt release -Agent devH 2>&1; git -C $app config --unset core.hooksPath
& $J @{ repos = @(@{ name = 'app'; checkout = $app; target = 'main'; poolSize = 2; linkFromByTarget = @{ main = "$base/no-deps" } }); tracker = @{ type = 'none' } } "$k/skills/crafty/kit.local.json"
$o11 = & $lease devI feat/seven; $pf = Get-ChildItem $kf -Filter '*-app.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.branch -eq 'feat/seven' }
Expect "a failed resume of a parked slot parks it again (files kept, parkedAt set), the lease file stays ($($o11 -replace '\s+', ' '))" ($o11 -match 'dep source .* is missing' -and $pf.parked -and $pf.parkedAt -and (Test-Path "$s10/p.txt"))
Remove-TestKit $k
Complete-Tests
