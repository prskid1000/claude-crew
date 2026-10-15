# wt.ps1 commit guard + deploy-merge.ps1 hooks, on throw-away local git repos (no remote host, no kit state).
#   pwsh -NoProfile -File <kit>/skills/dev-kit/tests/test-wt.ps1      exit 0 = all pass
$S = Join-Path (Split-Path $PSScriptRoot) 'scripts'
$r = Join-Path ([IO.Path]::GetTempPath()) "kit-test-wt-$PID"; New-Item -ItemType Directory -Force "$r/outer/inner" | Out-Null
$env:CLAUDE_WT_ROOT = "$r/wt"; foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }
$fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
try {
  # 1. commit refuses a folder that is not the top of a worktree (git -C would fall through to the enclosing repo)
  git -C "$r/outer" init -q; git -C "$r/outer" commit -q --allow-empty -m init
  'x' | Set-Content "$r/outer/stray.txt"; 'y' | Set-Content "$r/outer/inner/a.txt"
  $o = pwsh -NoProfile -File "$S/wt.ps1" commit -Dir "$r/outer/inner" -Message m 2>&1 | Out-String
  Expect 'commit refuses a plain subfolder' ($LASTEXITCODE -ne 0 -and $o -match 'not the top of a git worktree' -and -not (git -C "$r/outer" diff --cached --name-only))
  # 2. -Dir defaults to the current folder; -MessageFile
  'feat: from file' | Set-Content "$r/msg.txt"
  Push-Location "$r/outer"; $null = pwsh -NoProfile -File "$S/wt.ps1" commit -MessageFile "$r/msg.txt" 2>&1; $code = $LASTEXITCODE; Pop-Location
  Expect 'commit from the current folder with -MessageFile' ($code -eq 0 -and (git -C "$r/outer" log -1 --format=%s) -eq 'feat: from file')
  # 3. deploy-merge commits the merge through wt.ps1 commit, so pre-commit hooks run
  git init -q --bare "$r/origin.git"; git clone -q "$r/origin.git" "$r/repo" 2>$null
  'a' | Set-Content "$r/repo/a.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m init; git -C "$r/repo" branch -M main
  git -C "$r/repo" push -q origin main 2>$null; git -C "$r/repo" push -q origin main:staging 2>$null
  New-Item -ItemType Directory -Force "$r/repo/.githooks" | Out-Null
  [IO.File]::WriteAllText("$r/repo/.githooks/pre-commit", "#!/bin/sh`necho hooked > `"`$(git rev-parse --git-dir)/hook-ran`"`n")
  git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m hooks; git -C "$r/repo" config core.hooksPath .githooks
  'b' | Set-Content "$r/repo/b.txt"; git -C "$r/repo" add -A; git -C "$r/repo" commit -q -m 'feat: b'; git -C "$r/repo" push -q origin main 2>$null
  $o = pwsh -NoProfile -File "$S/deploy-merge.ps1" -Repo "$r/repo" -To staging -From main 2>&1 | Out-String
  $wt = if ($o -match 'worktree: (.+)') { $Matches[1].Trim() }
  $gd = if ($wt) { (git -C $wt rev-parse --absolute-git-dir).Trim() }
  Expect 'deploy merge is a merge commit' ($wt -and @((git -C $wt log -1 --format=%p) -split ' ').Count -eq 2)
  Expect 'deploy merge ran the pre-commit hook' ($gd -and (Test-Path (Join-Path $gd 'hook-ran')))
} finally { Remove-Item $r -Recurse -Force -ErrorAction SilentlyContinue }
"$fails failure(s)"; exit [int]($fails -gt 0)
