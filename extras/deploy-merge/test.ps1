#Requires -Version 7
# Offline test of the extra: a throw-away copy of the kit's orch.ps1 + lib.ps1 with this extra installed. Exit 0 pass, 1 fail.
param([Parameter(Mandatory)][string]$Kit)
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
$k = Join-Path ([IO.Path]::GetTempPath()) "extra-test-$PID\.claude"
foreach ($f in 'skills/dev-kit/lib.ps1', 'skills/dev-kit/kit.example.json', 'skills/dev-kit/dev.ps1', 'skills/orchestrate/orch.ps1') { New-Item -ItemType Directory -Force (Join-Path $k (Split-Path $f)) | Out-Null; Copy-Item (Join-Path $Kit $f) (Join-Path $k $f) }
Copy-Item -Recurse (Join-Path $PSScriptRoot 'files/*') $k -Force
Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue
$O = Join-Path $k 'skills/orchestrate/orch.ps1'; $np = '-NoProfile', '-File'
try {
  $r = Join-Path (Split-Path $k) 'git'; foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
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
} finally { Remove-Item (Split-Path $k) -Recurse -Force -ErrorAction SilentlyContinue }
exit [int]($script:fails -gt 0)
