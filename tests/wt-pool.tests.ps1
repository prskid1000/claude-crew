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
$fm = pwsh @np $D wt pool -Migrate 2>&1 | Out-String; $pt = @(Get-ChildItem (Join-Path (TkPath $k wt-slots) 'patches') -Filter 'fx-app-*.patch' -ErrorAction SilentlyContinue)
$null = git -C $vb apply --check $pt[0].FullName 2>&1; $fm += " apply-check:$LASTEXITCODE"
Expect "K38: squash-merged rebased branch goes, dead lane with only test merges goes, with its own commit stays; merged worktree with edited fixtures: patch, then gone ($(@($vr) -join ' ') | $($fm -replace '\s+', ' '))" ((@($vr) -join ' ') -match 'sq=True .*lane/old-a=True .*lane/old-b=False' -and $fm -match 'patched\s+\S*fx-app' -and $fm -match 'apply-check:0' -and -not (Test-Path $fw) -and $pt.Count -eq 1 -and (Get-Content $pt[0].FullName -Raw) -match '\+regen')
# a stray non-lease file in wt-slots (an array, as lanes.json was): supervise, wt release and bossy release skip it (K42)
Set-Content "$kf/stray.json" '[{"lane":"x","parked":true,"parkedAt":"2026-01-01T00:00:00Z","since":"2026-01-01T00:00:00Z","agent":"devZ"},{"lane":"y","parked":true,"parkedAt":"2026-01-02T00:00:00Z","agent":"devZ"}]'
$sg = Invoke-PsTest stray-slot @'
. $args[0]; foreach ($a in @(Get-ChildItem $args[1] -Filter '*.ps1')) { . $a.FullName }; $now = Get-Date; try { $o = @(Get-KitSuperviseGuardResources); "stray:$(-not @($o | Where-Object { "$($_.what)" -match 'devZ|slot \S* parked' }).Count)" } catch { "stray:ERR $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
'@ @((Join-Path $k 'skills/crafty/lib.ps1'), (Join-Path $k 'skills/bossy/adapters'))
$wr = pwsh @np $D wt release -Agent devZ 2>&1 | Out-String
Expect "a stray array file in wt-slots: supervise resources sweep runs, no slot flag from it; wt release ignores it ($(@($sg) -join ' ') | $($wr.Trim()))" ((@($sg) -join ' ') -match 'stray:True' -and $wr -match 'no slot held by devZ' -and (Test-Path "$kf/stray.json"))
# K55: one lane name in shown text (ids kept in paths, logs, branch names and -Json); -Env takes the shown name; ui-check LANE-ID
$lnt = & { . (Join-Path $k 'skills/crafty/lib.ps1'); $__cfg = [pscustomobject]@{ localEnv = [pscustomobject]@{ envs = [pscustomobject]@{ shop = [pscustomobject]@{ lanes = [pscustomobject]@{ max = 3 } } } } }
  @(@('shop2 · api', 'shop · db', 'env shop', '[shop3] up', 'shop2-api.log', 'lane/shop-kestrel', 'workshop2 · x', 'shop2 &#183; web') | ForEach-Object { ConvertTo-KitLaneText $_ }) -join '|'
  "from:$(ConvertFrom-KitLaneLabel 'shop·Kestrel')/$(ConvertFrom-KitLaneLabel 'SHOP-OSPREY')/$(ConvertFrom-KitLaneLabel 'other')"
  "out:$(@('x shop2' | ConvertTo-KitLaneOut $false) + @('x shop2' | ConvertTo-KitLaneOut $true) -join '/')" }
Set-JsonFile (Join-Path $k 'skills/crafty/kit.local.json') @{ localEnv = @{ envs = @{ shop = @{ lanes = @{ max = 2 } } } } }; $lp = Join-Path (Kd) 'lanes.html'
Set-Content $lp "<html><body><p>env shop·Kestrel</p><p>shop2 &#183; api</p><script>var a='shop2'</script></body></html>"
$lhit = python -X utf8 -c "import sys; sys.argv=['kitbag.py']; sys.path.insert(0, r'$k/skills/bossy'); import kitbag; print(len(kitbag.lane_ids_shown(r'$lp', r'$k')))"
Expect "lane names: ids shown as <product>·<Bird> (paths, branches, other words kept), -Env takes the shown name, -Json keeps ids; ui-check counts a bare id outside scripts ($($lnt -join ' | ') | $lhit)" ($lnt[0] -eq 'shop·Kestrel · api|shop·Falcon · db|env shop·Falcon|[shop·Osprey] up|shop2-api.log|lane/shop-kestrel|workshop2 · x|shop·Kestrel &#183; web' -and $lnt[1] -eq 'from:shop2/shop3/other' -and $lnt[2] -eq 'out:x shop·Kestrel/x shop2' -and "$lhit".Trim() -eq '1')
Remove-TestKit $k
Complete-Tests
