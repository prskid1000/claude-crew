#Requires -Version 7
<#
tests.ps1 (extra deploy-merge): offline, on a throw-away test kit with this extra's files.
Usage: kittool.py extra test deploy-merge (tests/kit-tests.ps1 -Area extras runs every installed extra)
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')   # kittool.py extra test: the kit's harness; New-TestKit adds this extra's files
$k = New-TestKit deploy-merge; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
# deploy merge is a verb of the deploys extra: its adapter from the kit, else nothing to test
$dpa = Join-Path $src 'skills/orchestrate/adapters/deploys.ps1'
if (-not (Test-Path $dpa)) { 'SKIP deploy merge (needs the extra deploys)'; Remove-TestKit $k; Complete-Tests }
Copy-Item $dpa (Join-Path $k 'skills/orchestrate/adapters'); $r = Join-Path (Kd) 'git'
$env:CLAUDE_WT_ROOT = "$r/wt"
git init -q --bare "$r/origin.git"; git clone -q "$r/origin.git" "$r/repo" 2>$null
'a' | Set-Content "$r/repo/a.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m init; git -C "$r/repo" branch -M main
git -C "$r/repo" push -q origin main 2>$null; git -C "$r/repo" push -q origin main:staging 2>$null
New-Item -ItemType Directory -Force "$r/repo/.githooks" | Out-Null
[IO.File]::WriteAllText("$r/repo/.githooks/pre-commit", "#!/bin/sh`necho hooked > `"`$(git rev-parse --git-dir)/hook-ran`"`n")
git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m hooks; git -C "$r/repo" config core.hooksPath .githooks
'b' | Set-Content "$r/repo/b.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: b'; git -C "$r/repo" push -q origin main 2>$null
$out = pwsh @np $O deploy merge -Repo "$r/repo" -To staging -From main 2>&1 | Out-String
$wt = if ($out -match 'worktree: (.+)') { $Matches[1].Trim() }
$gd = if ($wt) { (git -C $wt rev-parse --absolute-git-dir).Trim() }
Expect 'deploy merge is a merge commit' ($wt -and @((git -C $wt log -1 --format=%p) -split ' ').Count -eq 2)
Expect 'deploy merge ran the pre-commit hook' ($gd -and (Test-Path (Join-Path $gd 'hook-ran')))
$kl = "$k/skills/dev-kit/kit.local.json"; @{ repos = @(@{ checkout = "$r/repo"; target = 'main'; deploys = @(@{ target = 'live'; tag = 'rel-{date}' }) }) } | ConvertTo-Json -Depth 5 | Set-Content $kl
$o1 = pwsh @np $O deploy merge -Repo "$r/repo" -To main 2>&1 | Out-String; $o2 = pwsh @np $O deploy merge -Repo "$r/repo" -To live -Push 2>&1 | Out-String
Expect 'deploy merge: trunk = no merge; tag deploy pushes a tag' ($o1 -match 'trunk' -and $o2 -match 'pushed rel-' -and (git -C "$r/origin.git" tag) -match '^rel-')
Remove-Item Env:CLAUDE_WT_ROOT
Remove-TestKit $k
Complete-Tests
