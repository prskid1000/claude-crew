#Requires -Version 7
<#
guard.tests.ps1: crafty.ps1 guard (PreToolUse hook), MR links, temp-root writes; supervise report; track add / show; tracker bug.
Usage: pwsh -NoProfile -File <kit>/tests/guard.tests.ps1 (or tests/kit-tests.ps1 -Area guard). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit guard; $D = Join-Path $k 'skills/crafty/crafty.ps1'
$gi = -not (Test-Path "$k/.git"); if ($gi) { git init -q $k }; '.runtime/' | Set-Content "$k/.gitignore"   # {KIT} cases; a plain clone ignores .runtime (strict allow cases, K63s)
$kl = "$k/skills/crafty/kit.local.json";'{"guard":{"layout":"block"}}' | Set-Content $kl
# the guard table (was crafty.ps1 guard -SelfTest): tool, command, deny ($true / $false / 'rw' = runs rewritten), the text its answer holds
$out = Invoke-PsTest guard-table @'
$D = $args[0]; $cDir = Split-Path $D; . (Join-Path $cDir 'lib.ps1'); $gbn = 'KIT_GUARD_BY' + 'PASS'
$wtrT = ([IO.Path]::GetFullPath(@($KitConf.WorktreeRoots)[0])).Replace('\', '/'); $null = New-Item -ItemType Directory -Force "$wtrT/wt-ok"; if (-not (Test-Path "$wtrT/wt-ok/.git")) { 'gitdir: x' | Set-Content "$wtrT/wt-ok/.git" }   # a worktree's .git file
$da = 'default desktop app'; $mg = 'the memory gate';$sx = 'through its interpreter'; $wb = "open the owner's browser"; $rp = 'holds runs in progress'; $hk = 'Hooks must run'; $pb = 'a protected kit branch'; $lk = 'the live kit runs'; $gb = 'Git Bash path'; $rt = 'use the Read tool'; $dr = 'searches a whole drive'
$cases = @(
@('P', 'git stash', $true),
@('P', '& "C:\Program Files\Git\bin\git.exe" stash list', $false),
@('P', 'git stash push -m x', $true),
@('P', '$s = $(git stash list); $s', $false),
@('P', 'pwsh -NoProfile -Command "git stash"', $true),
@('B', 'cd repo && git -C x stash pop', $true),
@('B', 'FOO=1 git --no-pager stash show', $false),
@('B', 'git -C x stash push -m x', $true),
@('B', "bash -c 'git stash'", $true),
@('P', 'git commit -m "fix: never git stash here"', $false),
@('P', "`$m = @'`nnever run git stash`n'@`ngit commit -m `$m", $false),
@('B', "git commit -m `"`$(cat <<'EOF'`nfix: never git stash in worktrees`nEOF`n)`"", $false),
@('B', 'git checkout fix/stash-list', $false),
@('B', 'echo done # not git stash', $false),
@('B', 'aws elasticbeanstalk update-environment --environment-name e1 --option-settings Namespace=aws:elasticbeanstalk:application:environment,OptionName=A,Value=true', $true, 'changes a deployed env'),
@('B', 'aws --region eu-west-1 elasticbeanstalk restart-app-server --environment-name e1', $true, 'changes a deployed env'),
@('P', 'aws ecs update-service --cluster c --service s --force-new-deployment', $true, 'changes a deployed env'),
@('B', 'cd x && kubectl -n qa rollout restart deploy/api', $true, 'changes a deployed env'),
@('B', 'KIT_DECISION=d-none aws lambda update-function-configuration --function-name f', $true, 'changes a deployed env'),
@('B', 'aws elasticbeanstalk describe-configuration-settings --environment-name e1', $false),
@('B', 'git commit -m "test: never aws elasticbeanstalk update-environment"', $false),
@('B', 'kubectl get pods -n qa | grep edit', $false),
@('B', 'kubectl get deploy && npm run scale', $false),
@('B', "git commit -m `"x`naws ecs update-service --cluster c`"", $false),
@('B', 'echo "after web restart"', $false),
@('P', '& "C:\Program Files\Amazon\AWSCLIV2\aws.exe" elasticbeanstalk restart-app-server --environment-name e1', $true, 'changes a deployed env'),
@('B', 'sudo aws ecs update-service --cluster c --service s', $true, 'changes a deployed env'),
@('B', 'bash -c "aws elasticbeanstalk update-environment --environment-name e1"', $true, 'changes a deployed env'),
@('P', 'pwsh -Command "aws ssm put-parameter --name x --value y"', $true, 'changes a deployed env'),
@('P', '& D:\kit\skills\crafty\LESSONS.md', $true, $da),
@('P', 'Invoke-Item .\report.html', $true, $da),
@('P', 'Start-Process https://example.com', $true, $da),
@('B', 'xdg-open out/report.html', $true, $da),
@('B', 'cmd /c start "" report.pdf', $true, $da),
@('P', 'Start-Process pwsh -ArgumentList x.ps1 -WindowStyle Hidden', $false, ''),
@('P', 'Start-Process pwsh -ArgumentList x.ps1 -PassThru -RedirectStandardOutput o.txt', $false, $da),
@('P', 'Start-Process -FilePath .\r.html', $true, $da),
@('P', 'Start-Process -Wait .\r.html', $true, $da),
@('P', 'cd x; ii "out.pdf"', $true, $da),
@('P', '& D:/kit/learn.ps1 -Skill crafty -Text "resumed agent; . templates.md "Resume brief" was read (see notes.md); & LESSONS.md"', $false, $da),
@('P', '& .\tracker.ps1 comment 42 "see guide.md and & x.txt"', $false, $da),
@('P', '. .\kitpaths.ps1; Get-Content LESSONS.md', $false, $da),
@('P', '& D:/kit/learn.ps1 -Skill crafty -Text "agent said \"done\"; . notes.md was read" -Source workflow', $false, $da),
@('P', "& D:/kit/learn.ps1 -Skill crafty -Kind win -Text `"ok`" -Ref B-1`n& D:/kit/skills/crafty/LESSONS.md | Out-Null", $true, $da),
@('P', '& D:\kit\skills\crafty\devtools.py merge 12', 'rw', 'python -X utf8 D:\kit\skills\crafty\devtools.py merge 12'),
@('P', "& 'D:\kit\skills\crafty\devtools.py' merge", 'rw', "python -X utf8 'D:\kit\skills\crafty\devtools.py' merge"),
@('P', '& "$k/skills/pokey/browser.mjs" shot', 'rw', 'node "$k/skills/pokey/browser.mjs" shot'),
@('P', '.\x.py --flag', 'rw', 'python -X utf8 .\x.py --flag'),
@('P', 'tool.ts run', $true, $sx),
@('P', 'Start-Process x.py', $true, $sx),
@('P', 'cmd /c x.js', $true, $sx),
@('B', './skills/crafty/devtools.py merge 12', 'rw', 'python -X utf8 ./skills/crafty/devtools.py merge 12'),
@('B', 'cd x && FOO=1 tool.mjs a', 'rw', 'cd x && FOO=1 node tool.mjs a'),
@('B', 'start x.py', $true, $sx),
@('P', 'python -X utf8 skills/crafty/devtools.py merge 12', $false, ''),
@('P', 'node skills/pokey/browser.mjs shot; npx tsx a.ts', $false, ''),
@('P', 'pwsh -File x.ps1; & D:/kit/x.ps1 -A b.py', $false, ''),
@('P', 'Get-Content x.json; Select-String foo x.md', $false, ''),
@('B', 'python -X utf8 skills/crafty/devtools.py merge 12; node a.mjs', $false, ''),
@('B', 'cat devtools.py; grep -n foo x.md; ls *.json > out.txt', $false, ''),
@('B', 'cd ../MR3/scripts; E=../evidence; ls ../ev/MR3-T2A_0*; cp ../ev/MR3-T2A_02_vin-photo.jpg $E/MR3-T2_00_vin-input.jpg; for i in 1 2 3; do node t2a/run-app-vin.cjs $E/MR3-T2_00_vin-input.jpg $E/MR3-T2_0${i}_run$i.json 1; done', $false, $da),
@('B', 'E=../evidence; cat ../ev/MR3-T2A_02_vin-photo.jpg > $E/MR3-T2_00_vin-input.jpg; for i in 1 2 3; do node t2a/run-app-vin.cjs $E/in.jpg $E/MR3-T2_0${i}_run$i.json 1; done', $false, $da),
@('B', 'LN=D:/x/{RT}/work/lead-notes.md; for i in $(seq 1 30); do m=$(curl -s https://x/ | grep -o ''"mode":"[a-z]*"''); a=$(grep -E "^- .*MR4:" $LN | grep -v "REQUEST"); echo "$m ${a:0:200}"; done', $false, $da),
@('B', 'E=D:/x/{RT}/work/MR4/evidence; F=$E/MR4-T2_retry_03_history.log; { echo "== NRQL"; echo x; } > $F', $false, $da),
@('P', '$x = ''notes.md''; Get-Content $x', $false, $da),
@('B', 'x=$(cat a.md); a=(x.md y.md)', $false, $da),
@('B', 'x.md', $true, $da),
@('B', 'cd x; for f in a; do r.pdf; done', $true, $da),
@('B', 'X=1 r.html', $true, $da),
@('B', 'start x.html', $true, $da),
@('P', 'ii x.pdf', $true, $da),
@('P', '& x.py', 'rw', 'python -X utf8 x.py'),
@('P', '& .\notes.md', $true, $da),
@('P', 'ii .', $true, $da),
@('P', 'explorer.exe D:\x', $true, $da),
@('P', 'code skills/crafty/devtools.py', $true, $da),
@('P', 'notepad a.txt', $true, $da),
@('P', 'mmc; control', $true, $da),
@('P', 'rundll32 url.dll,FileProtocolHandler https://x', $true, $da),
@('P', 'Start-Process report.docx', $true, $da),
@('P', 'cmd /c start https://x', $true, $da),
@('B', 'start https://example.com', $true, $da),
@('B', 'explorer .', $true, $da),
@('B', 'cmd //c start "" a.xlsx', $true, $da),
@('B', 'code .', $true, $da),
@('P', 'Start-Process pwsh -ArgumentList x.ps1 -WindowStyle Hidden; Start-Process -FilePath node.exe -WindowStyle Hidden', $false, ''),
@('B', 'cd D:/x/src/code-review; echo code', $false, ''),
@('P', 'glab mr view 12 --web', $true, $wb),
@('B', 'gh pr view 3 -w', $true, $wb),
@('B', 'gh browse', $true, $wb),
@('P', 'glab mr view 12 -R g/web; gh pr view 3 --json title', $false, ''),
@('B', 'gh run list -w ci.yml; gh workflow run -w x; gh browse -n 12', $false, ''),
@('P', 'code --version; code --list-extensions', $false, ''),
@('B', 'code --version', $false, ''),
@('P', 'Start-Process -FilePath notepad.exe -WindowStyle Hidden', $false, ''),
@('P', 'powershell -c "ii ."', $true, $da),
@('B', 'pwsh -c ". a.py"', $true, $sx),
@('P', 'cmd.exe /k a.js', $true, $sx),
@('B', 'mshta x.hta', $true, $da),
@('B', "cd {KRT} && mkdir -p work/agents/g5 && glab mr view 12 -R group/repo 2>&1 | tail -n +2 > work/agents/g5/body.md; cat >> work/agents/g5/body.md <<'EOF'`n## Review follow-up`n- Plain check: the del flag and rd step are prose here`nEOF`nglab mr update 12 --description `"`$(cat work/agents/g5/body.md)`"", $false, $rp),
@('P', '& D:/kit/learn.ps1 -Skill crafty -Text "never rm the {RT}/work folder" -Source workflow', $false, $rp),
@('B', 'rm -rf {KRTB}/work', $true, $rp),
@('P', 'Remove-Item -Recurse -Force "{KRT}\work"', $true, $rp),
@('B', "python -c `"import shutil; shutil.rmtree('{KRT}/work')`"", $true, $rp),
@('B', 'cd {KRTB} && rm -rf work', $true, $rp), @('B', 'cd {KIT}; rm -rf {RT}/work', $true, $rp), @('B', 'rm -rf $K/{RT}/work', $true, $rp),
@('B', 'rm -rf /d/x/{RT}/work', $false, $rp), @('P', 'Remove-Item -Recurse "D:\x\{RT}\work"', $false, $rp), @('B', 'cd /d/x/{RT} && rm -rf work', $false, $rp),
@('B', 'cd {WS}; rmdir {RT}/work/agents/a {RT}/work {RT}', $false, $rp), @('B', 'cd {WS}; mkdir -p {RT}/work/agents/a', $true, 'outside the kit'),
@('E', '{WS}/{RT}/work/a.md', $true, 'outside the kit'), @('B', 'mkdir -p {KRT}/work/agents/a; echo x > {KRTB}/../x/y/{RT}/a.txt', $false, 'outside the kit'),
@('B', 'rm -rf {KRTU}/work', $true, $rp), @('B', 'cd {WS}; mkdir -p {RTU}/w', $true, 'outside the kit'), @('B', 'mv {WS}/{RT}/work/x {KRT}/work/agents/x; cat {WS}/{RT}/a.md > {KRT}/work/agents/x/b.md', $false, 'outside the kit'),
@('B', 'cd {WS}; echo "{RT}/" >> .gitignore; ls {RT} 2>&1', $false, 'outside the kit'), @('B', 'cd {WS}; mkdir -p a/b/c/{RT}', $false, 'outside the kit'),
@('P', 'Remove-Item D:\x\.claude\tracking.local.json', $true, 'durable local kit state'),
@('P', 'Remove-Item -Force "{KRT}\work\a.json"', $false, $rp), @('B', 'rm -r {KRTB}/work/a.d', $true, $rp),
@('B', "cd repo; python3 - <<'E'`np='a.ts'`ns=open(p).read()  # never git stash here`nE`nnode x.mjs", $false),
@('B', "cd repo; python3 - <<'E'`np='a.ts'`nE`ngit stash list >/dev/null; cp a.ts /tmp/a.bak", $false),
@('B', 'glab mr update 5 --description "$(cat /tmp/mr-body.md)"', $true, 'shared temp root'),
@('P', 'Set-Content $env:TEMP\desc-8543.md $d', $true, 'shared temp root'),
@('B', 'cp body.md /tmp/w1-run/body.md; cat /tmp/out.log', $false, 'shared temp root'),
@('B', 'git push origin +HEAD:main', $true, 'force-push'),
@('P', 'git -C x push origin +f/CU-1-x', $true, 'force-push'),
@('B', 'git push origin HEAD:main', $true, 'push refused: a protected branch'),
@('B', 'git push -u origin HEAD; git push origin HEAD:f/CU-1-x --force-with-lease', $false, 'force-push'),
@('B', 'git push -fu origin main', $true, 'force-push'),
@('P', 'git -C "{KIT}" push origin ":main"', $true, $pb),
@('B', 'cd "{KIT}" && git push origin --delete "main"', $true, $pb),
@('P', 'Set-Location -Path "{KIT}"; git push -d origin main', $true, $pb),
@('P', 'Push-Location "{KIT}"; git push --mirror origin', $true, $pb),
@('B', 'git -C "{KIT}" branch -D main', $true, $pb),
@('B', 'git -C "{KIT}" branch -f main HEAD~1', $true, $pb),
@('P', 'git -C "{KIT}" branch -dr origin/main', $true, $pb),
@('P', 'git -C "{KIT}" update-ref -d refs/remotes/origin/main', $true, $pb),
@('B', 'git -C "{KIT}" push -u origin HEAD:main; git -C "{KIT}" branch --show-current', $false, $pb),
# review f11ca9f1: a rewrite builds on an earlier one; every bad segment gets MSYS_NO_PATHCONV=1; quoted text is data; a path in a message: deny
@('B', 'node a.mjs /d/x/o.png; ./skills/crafty/devtools.py m', 'rw', 'node a.mjs D:/x/o.png; python -X utf8 ./skills/crafty/devtools.py m'),
@('B', 'node a.mjs /api/x; node b.mjs /api/y', 'rw', 'MSYS_NO_PATHCONV=1 node a.mjs /api/x; MSYS_NO_PATHCONV=1 node b.mjs /api/y'),
@('B', 'echo "node a.mjs /api/x"; node a.mjs /api/x', 'rw', 'echo "node a.mjs /api/x"; MSYS_NO_PATHCONV=1 node a.mjs /api/x'),
@('B', './skills/crafty/devtools.py a; git commit -m "fix: call (b.py) here"', 'rw', 'python -X utf8 ./skills/crafty/devtools.py a; git commit -m "fix: call (b.py) here"'),
@('B', 'git commit -m "note: was /d/x/a.png"; node a.mjs /d/x/a.png', $true, 'Git Bash path'),
# only worktrees live in a worktree root (2026-11-27): a loose file or a folder that is no worktree is denied; a worktree's own file passes
@('E', '{WTR}/kitty-x-dbg1.ps1', $true, 'only worktrees live there'), @('B', 'echo x > {WTR}/stray-rt/cache/a.txt', $true, 'that is no worktree'), @('E', '{WTR}/wt-ok/notes.md', $false, 'worktree root'),
@('B', 'cd {KITB} && git push origin HEAD:main', $false, 'push refused'), @('B', 'cd {KITB} && git push --force origin HEAD:main', $true, $pb),   # Git Bash /d/... cd: the kit, not a product repo (audit pick 7)
@('B', 'git -C "{KIT}" push origin --delete kit/build-x; git -C "{KIT}" branch -D kit/main-x', $false, $pb),
@('B', 'git -C /nowhere/repo push origin --delete f/x; git -C /nowhere/repo branch -D develop', $false, $pb),
@('B', 'git -C /nowhere/repo push origin --delete main; git push origin main --tags', $true, 'push refused: a protected branch'),
@('B', 'git push --all origin', $true, 'push refused: a protected branch'),
@('B', 'git -C /nowhere/repo push origin --force-with-lease HEAD:release', $false, $pb),
@('P', 'git commit -m "never git push origin --delete main"', $false, $pb),
@('B', 'git commit -n -m "x"', $true, $hk),
@('B', 'git -c core.hooksPath=/dev/null commit -m x', $true, $hk),
@('B', 'git commit --no-edit --amend', $false, $hk),
@('P', 'git commit -m "use -n for a dry run"', $false, $hk),
@('B', 'git log -n 3; git commit -m x', $false, $hk),
@('E', '{LIVE}/skills/crafty/crafty.ps1', $true, $lk),
@('E', '{LIVE}/{RT}/work/agents/x/x.md', $false, $lk),
@('E', '{LIVE}/.git/info/exclude', $false, $lk),
@('E', '{LIVE}/../wt/skills/crafty/crafty.ps1', $false, $lk),
@('P', 'Set-Content {LIVE}/AGENTS.md x', $true, $lk),
@('B', 'sed -i s/a/b/ {LIVE}/README.md', $true, $lk),
@('B', 'git -C "{LIVE}" commit -m x', $true, $lk),
@('P', 'cd {LIVE}; git pull; git log -1; Get-Content AGENTS.md > {RT}/work/agents/x/a.txt; cp AGENTS.md ../a.md', $false, $lk),
@('B', 'cd {LIVE}; grep -c ">" README.md; git clean -n', $false, $lk),
@('B', 'KIT_LIVE_EDIT=1 git -C "{LIVE}" commit -m x', $false, $lk),
@('B', 'node shot.mjs --out /d/x/{RT}/work/evidence/t1/a.png', 'rw', 'node shot.mjs --out D:/x/{RT}/work/evidence/t1/a.png'),
@('B', "python -c `"open('/d/x/a.txt', 'w')`"", 'rw', "open('D:/x/a.txt', 'w')"),
@('B', "cd /d/x; python3 - <<'E'`nopen('/c/Users/x/a.json')`nE", 'rw', "open('C:/Users/x/a.json')"),
@('B', 'OUT=/d/x/a.png node shot.mjs', 'rw', 'OUT=D:/x/a.png node shot.mjs'),
@('B', 'cd /d/x && node shot.mjs ''{"out":"/d/x/a.png"}''', 'rw', 'cd /d/x && node shot.mjs ''{"out":"D:/x/a.png"}'''),
@('B', 'bash -c "java -jar a.jar /d/x/in.txt"', 'rw', 'java -jar a.jar D:/x/in.txt'),
@('B', 'curl -s -o /d/x/a.json https://h.io/api; x=$(npx tsx a.ts --dir=/e/y)', 'rw', 'curl -s -o D:/x/a.json https://h.io/api; x=$(npx tsx a.ts --dir=E:/y)'),
@('P', 'node shot.mjs /d/x/a.png; adb.exe pull /sdcard/a.png /d/x/', 'rw', 'node shot.mjs D:/x/a.png; adb.exe pull /sdcard/a.png D:/x/'),
@('B', 'command node a.mjs /d/x; { sudo python a.py /d/y; }', 'rw', 'command node a.mjs D:/x; { sudo python a.py D:/y; }'),
@('B', 'curl -sSo /d/x/a.json https://h.io/api', 'rw', 'curl -sSo D:/x/a.json https://h.io/api'),
@('B', 'curl -d @/d/x/body.json https://h.io/api', 'rw', 'curl -d @D:/x/body.json https://h.io/api'),
@('B', 'curl --output=/d/x/a.zip https://h.io/a; curl -T /d/x/a.zip https://h.io/u', 'rw', 'curl --output=D:/x/a.zip https://h.io/a; curl -T D:/x/a.zip https://h.io/u'),
@('B', 'curl -K /d/x/c.txt; curl -F file=@/d/x/a.png https://h.io', 'rw', 'curl -K D:/x/c.txt; curl -F file=@D:/x/a.png https://h.io'),
@('B', 'curl -s -d ''{"route":"/c/orders"}'' https://h.io/api; curl --json ''{"p":"/d/x"}'' "https://h.io/api?path=/d/x"', $false, $gb),
@('B', 'curl --data-raw /c/orders -H "X-Path: /v/1" https://h.io; curl -X POST --data /d/x https://h.io', $false, $gb),
@('B', 'node a.mjs D:/x > {KRTB}/work/agents/a/out.log 2>{KRTB}/work/agents/a/err.log; python a.py < /d/x/in.txt', $false, $gb),
@('B', 'curl -s https://h.io/d/files/a.json -o D:/x/a.json; node a.mjs abc/c/def x/d/y ${R}/c/z', $false, $gb),
@('B', "python a.py D:/x # was /d/x`n# node b.mjs /d/y", $false, $gb),
@('B', 'python a.py x#y /d/z', 'rw', 'python a.py x#y D:/z'),
@('B', 'ls /d/x; cat /d/x/a.md; grep -rn foo /d/x; git -C /d/x status; cd /d/x && node shot.mjs D:/x/a.png', $false, $gb),
@('B', "git commit -m `"fix: node got /d/x paths`"; cat <<'EOF' > /d/x/a.md`npython /d/x/a.py`nEOF", $false, $gb),
@('P', 'python -X utf8 D:\x\a.py --out D:/x/a.png; adb shell ls /sdcard/DCIM', $false, $gb),
@('B', 'cd web && npx cypress run', $true, 'e2e runs go through'), @('P', 'yarn e2e:ci; npx playwright test x.spec.ts', $true, 'e2e runs go through'),
@('P', '& D:/k/skills/crafty/crafty.ps1 check -Dir web -Step e2e', $false, 'e2e runs go through'), @('B', 'crafty.ps1 check -Dir w -Step test; npx cypress run', $true, 'e2e runs go through'),
@('B', 'cat cypress/tsconfig.json; git log --grep "cypress run"; yarn playwright install; npm run cypress:open', $false, 'e2e runs go through'),
# a file path as the command
@('B', '"{KIT}/skills/bossy/SKILL.md"', $true, $rt), @('B', '{CR}/NOTICE', $true, $rt), @('B', 'cd "{CR}" && ./NOTICE', $true, $rt),
@('B', 'start {CR}/NOTICE', $true, $rt), @('B', '& "{CR}\NOTICE"', $true, $rt), @('B', 'cd x; "./tool.ps1" -A', 'rw', 'cd x; pwsh -NoProfile -File "./tool.ps1" -A'),
@('B', 'cd "{CR}" && ./run; bash .githooks/pre-push; cat "{KIT}/README.md"; echo "a; ./x.md"; ls {KIT}', $false, $rt),
@('B', 'f=$(ls -d */wf_1)/journal.jsonl; grep -c x $f', $false, $rt), @('B', '(ls){ ./NOTICE.md; }', $true, $rt),
@('P', '& "{CR}/NOTICE"', $true, $rt), @('P', '& "{KIT}"', $true, $rt), @('P', 'Set-Location "{CR}"; .\NOTICE', $true, $rt),
@('P', '$g = Join-Path "{KIT}" ''skills/bossy/SKILL.md''; & $g', $true, $rt), @('P', '$f = "{KIT}/README.md"; Start-Process -FilePath $f', $true, $rt),
@('P', 'Start-Process "{CR}/NOTICE"', $true, $rt), @('P', 'Start-Process (Join-Path "{KIT}" ''README.md'')', $true, $rt),
@('B', "git log \`n  -- docs/readme.md; git diff \`n  skills/crafty/crafty.ps1", $false, $rt),
@('P', '$py = ''C:/x/python.exe''; & $py a.py; Get-Content "{CR}/NOTICE"; "{KIT}/README.md" | Out-Null; cd "{KIT}"; .\.githooks\pre-commit.ps1', $false, $rt),
# pytest / docker runs go through the gate
@('B', 'cd api && pytest tests/test_a.py -q', $true, $mg), @('P', '& "C:\v\python.exe" -X utf8 -m pytest t', $true, $mg), @('B', 'uv run pytest', $true, $mg),
@('B', 'docker compose -f a.yml -f b.yml up -d --wait', $true, $mg), @('P', 'docker build -t x .', $true, $mg), @('B', 'docker-compose up', $true, $mg),
@('P', '& "C:\Program Files\Py\python.exe" -m pytest t', $true, $mg), @('B', 'FOO=1 timeout 300 pytest -x', $true, $mg), @('B', 'nohup pytest &', $true, $mg),
@('B', 'sudo docker run x', $true, $mg), @('B', 'docker --context ci image build .', $true, $mg), @('B', 'docker container run x', $true, $mg),
@('B', 'grep -rn pytest requirements.txt; pytest --version; pytest -h; docker ps; docker compose logs api', $false, $mg),
@('B', 'rg "foo|pytest" src; grep -E "(pytest|docker run)" a; git commit -m "fix; pytest runs"; echo x | grep -n "; docker build" f', $false, $mg),
@('P', '& {KIT}/skills/crafty/crafty.ps1 gate -Dir x -Cmd ''docker compose up -d''', $false, $mg),
@('B', 'pwsh -File {KIT}/skills/crafty/crafty.ps1 gate -Dir x -Cmd ".\mvnw.cmd -o -q test -pl a -am" 2>&1 | tail -25', $true, 'needs -Log'),
@('P', '& {KIT}/skills/crafty/crafty.ps1 gate -Dir x -Cmd ''yarn test'' -Log {KRTB}/work/agents/a/b.log', $false, 'needs -Log'), @('P', '& {KIT}/skills/crafty/crafty.ps1 gate -Dir D:/x/mvn-app -Cmd ''git status''', $false, 'needs -Log'),
# whole-drive searches denied; scoped paths pass
@('B', 'find / -ipath "*backend-test-reconciler*" 2>/dev/null', $true, $dr), @('B', 'find /c -name SKILL.md', $true, $dr), @('B', 'sudo find -L /d/ -type f | head', $true, $dr),
@('B', 'find C:\ -name x', $true, $dr), @('B', 'grep -rn reconciler /', $true, $dr), @('B', 'rg -l -g "*.md" reconciler C:/', $true, $dr), @('B', 'ls -R /c | grep x', $true, $dr),
@('B', 'bash -c "find / -name x"', $true, $dr), @('P', 'cmd /c dir /s C:\*.md', $true, $dr), @('P', 'Get-ChildItem -Recurse C:\ -Filter SKILL.md', $true, $dr),
@('P', 'gci D:\ -r -Include *.md', $true, $dr), @('P', 'where.exe /r C:\ claude.exe', $true, $dr), @('P', 'rg --files D:\', $true, $dr), @('B', 'find //c/.. -name x', $true, $dr), @('B', 'rg --max-columns 5 x / src', $true, $dr), @('B', 'rg --max-columns 5 / src', $false, $dr),
@('B', 'find . -name x; find ~/.claude/skills -name SKILL.md; find /d/work/repos -maxdepth 2 -name pom.xml; ls /; ls -la /c', $false, $dr),
@('B', "grep -rn / src; rg -n `"/`" skills; grep -e x /etc/hosts; git commit -m `"never find / -name x`"; cat > n.md <<'EOF'`nfind / -name x`nEOF", $false, $dr),
@('P', 'Get-ChildItem -Recurse D:\work\.claude\skills -Filter SKILL.md; Get-ChildItem C:\; where.exe git; rg -l x C:\Users\x\.claude', $false, $dr),
@('B', 'cd / && find . -name x', $true, $dr), @('B', 'cd /c; grep -rn x', $true, $dr), @('P', 'Set-Location C:\; gci -Recurse -Filter x', $true, $dr), @('B', 'find . -name "*.md" -exec grep -rl x / \;', $true, $dr),
@('B', 'cd / && ls; cd ~/src && find . -name x; find . -exec grep -l x {} +; cd /d/repo && rg x', $false, $dr), @('P', 'Set-Location C:\; where.exe git; Get-ChildItem', $false, $dr)
)
$gh = 'browser on Windows'   # Git for Windows help is HTML; elsewhere a man page
if ($IsWindows) { $cases += @(@('B', 'git cherry-pick --help', $true, $gh), @('P', 'git -C x help rebase', $true, $gh), @('B', 'git cherry-pick -h; git help -a; git commit -m "see --help"', $false, $gh)) }
$cr = Join-Path (Get-KitPath agents -Create) 'guard-selftest/crlf'; New-Item -ItemType Directory -Force "$cr/skills/crafty" | Out-Null; git init -q $cr   # tracked CRLF, tracked LF, untracked CRLF
foreach ($cf in 'skills/crafty/crafty.ps1', 'n.ps1') { [IO.File]::WriteAllText("$cr/$cf", "a`r`n") }; [IO.File]::WriteAllText("$cr/lf.md", "a`n"); git -C $cr -c core.autocrlf=false add skills lf.md
[IO.File]::WriteAllText("$cr/NOTICE", "text`n"); [IO.File]::WriteAllText("$cr/run", "#!/bin/sh`necho ok`n")   # an extensionless file a desktop app would open; a #! script
$cases += @(@('B', 'git fetch -q origin merge-requests/12/head:mr12', $true, 'local branch from an MR'), @('P', 'gh pr checkout 7', $true, 'local branch from an MR'),
  @('B', 'git fetch origin merge-requests/12/head && git diff origin/main...FETCH_HEAD; git fetch origin pull/3/head:refs/remotes/origin/pr3', $false, 'local branch from an MR'),
  @('B', 'git -C x worktree remove --force y', $true, 'wt remove -Dir'), @('B', 'git worktree list; git worktree prune', $false, 'wt remove -Dir'))
if ($mc = @(@(Get-KitValue 'repos' @()) | ForEach-Object { "$($_.checkout)" } | Where-Object { $_ -and (Test-Path -LiteralPath $_) })[0]) {   # a configured main checkout
  $ef = @(Get-ChildItem -LiteralPath $mc -File | Select-Object -First 1).Name
  $cases += @(@('B', "echo x > $mc/kit-scratch-$PID.txt", $true, 'shared main checkout'), @('B', "cd $mc && git status > kit-scratch-$PID.txt", $true, 'shared main checkout'), @('E', "$mc/kit-scratch-$PID.md", $true, 'shared main checkout'),
    @('B', "git -C $mc status > $cr/s.txt; echo x >> $mc/$ef; echo x > $mc/sub/new.txt", $false, 'shared main checkout')) }
$cases += @(@('B', "sed -Ei.b s/a/b/ $cr/skills/crafty/crafty.ps1", $true, 'use the Edit tool'), @('B', "sed -i s/a/b/ $cr/lf.md $cr/n.ps1; sed -n 1p $cr/skills/crafty/crafty.ps1; sed 's/ -i / /' $cr/skills/crafty/crafty.ps1", $false, 'use the Edit tool'))
$bp = 'owner only'
$cases += @(@('B', "setx $gbn 1", $true, $bp), @('B', "echo '{""env"":{""$gbn"":""1""}}' > $cr/settings.local.json", $true, $bp), @('B', "$gbn=1 node x.mjs; grep $gbn $cr/settings.json; git commit -m 'setx $gbn > settings.json'", $false, $bp), @('P', "Set-ItemProperty -Path x -Name $gbn -Value 1", $true, $bp), @('B', "grep x y; pwsh -c ""setx $gbn 1""", $true, $bp), @('B', "sed -i 's/}/,""$gbn"":1}/;s/a/b/' settings.json", $true, $bp), @('B', "git commit -m ""`$(setx $gbn 1)""", $true, $bp))
$nr = Join-Path (Get-KitPath agents) 'guard-selftest/neutral'; if (-not (Test-Path "$nr/.git")) { git init -q -b selftest $nr }   # cwd: a repo of its own on an unprotected branch, never the kit (K63s)
$env:KIT_GUARD_SELFTEST_ACTIVE = '1'; $env:KIT_LIVE_EDIT = $null
$live = Split-Path (git -C $cDir rev-parse --path-format=absolute --git-common-dir)
$krt = [IO.Path]::GetFullPath((Get-KitRuntime)).Replace('\', '/'); $fail = 0
foreach ($c in $cases) {
  $tool = @{ P = 'PowerShell'; B = 'Bash'; E = 'Edit' }[$c[0]]
  $v = $c[1].Replace('{KRTU}', ($krt -replace '[^/]+$', { $_.Value.ToUpper() })).Replace('{RTU}', '.RUNTIME').Replace('{KRTB}', ($krt -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() })).Replace('{KRT}', $krt).Replace('{WS}', (Split-Path $live)).Replace('{RT}', '.runtime').Replace('{WTR}', $wtrT).Replace('{KITB}', ((Split-Path (Split-Path $cDir)).Replace('\', '/') -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() })).Replace('{KIT}', (Split-Path (Split-Path $cDir))).Replace('{LIVE}', $live).Replace('{CR}', $cr)
  # cwd-independent results
  $hookIn = @{ tool_name = $tool; cwd = $nr; tool_input = $(if ($tool -eq 'Edit') { @{ file_path = $v } } else { @{ command = $v } }) }
  $json = $hookIn | ConvertTo-Json -Compress -Depth 4
  $out = (& $D guard -Json $json) -join ''
  $denied = $out -match '"permissionDecision":"deny"' -and $out -match $(if ($c.Count -gt 3) { [regex]::Escape($c[3]) } else { 'git stash is shared' })
  $rwTo = if ($out -match '"updatedInput"') { "$(($out | ConvertFrom-Json).hookSpecificOutput.updatedInput.command)" }
  # 'rw': the command runs rewritten, containing $c[3]; a rewrite is no deny for an allow case
  $ok = if ("$($c[2])" -eq 'rw') { $rwTo -and $rwTo.Contains($c[3].Replace('{CR}', $cr).Replace('{RT}', '.runtime').Replace('{KIT}', (Split-Path (Split-Path $cDir)))) } elseif ($c[2]) { $denied } else { $out -notmatch '"permissionDecision":"deny"' }   # strict allow (K63s): a deny for any reason fails it
  if (-not $ok) { $fail++ }
  '{0} {1,-10} {2,-6} {3}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $tool, $(if ("$($c[2])" -eq 'rw') { 'rewrite' } elseif ($c[2]) { 'deny' } else { 'allow' }), (($c[1] -replace "`n", ' \n ') + $(if (-not $ok -and $out -match '(?:Reason|reason)":"([^"]{1,160})') { " <- $($Matches[1])" }))
}
"$($cases.Count - $fail)/$($cases.Count) passed"
'@ @($D) | Out-String; Remove-Item $kl
Expect 'guard table (guard.layout block; strict: an allow case fails on any deny): every case, at least one' ($out -match '([1-9]\d*)/\1 passed')
'/nested/' | Set-Content "$k/.gitignore"; git init -q "$k/nested/wt"; New-Item -ItemType Directory -Force "$k/nested/plain" | Out-Null
$gn = Invoke-PsTest 'guard-nested' @'
$d, $kd = $args; foreach ($x in "$kd/nested/wt", "$kd/skills", "$kd/nested/plain") { $j = @{ tool_name = 'Bash'; cwd = $x; tool_input = @{ command = 'git commit -m x' } } | ConvertTo-Json -Compress; "$((& $d guard -Json $j) -join '' -match 'the live kit runs')" }
'@ @($D, $k)
Remove-Item "$k/.gitignore", "$k/nested" -Recurse -Force
Expect "guard: git commit in a nested worktree passes; a tracked folder, an ignored non-repo denied ($($gn -join ' '))" (($gn -join ' ') -eq 'False True True'); if ($gi) { Remove-Item -Recurse -Force "$k/.git" }
$shop = Join-Path (Kd) 'shop'; git init -q -b f/TT-42-x $shop; git -C $shop commit -q --allow-empty -m init; git -C $shop remote add origin 'https://h.example/g/shop.git'
$plain = Join-Path (Kd) 'plain'; git init -q -b fix/plain $plain; git -C $plain commit -q --allow-empty -m init; git -C $plain remote add origin 'https://h.example/g/shop.git'
$hf = Join-Path (Kd) 'mrget.ps1'; Set-Content $hf '@{ source_branch = $(if ($args[0] -eq 77) { ''deploy/s'' } else { ''f'' }) } | ConvertTo-Json'
& $J @{ tracker = @{ type = 'command'; branchTag = 'TT-' }; gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.get' = "pwsh -NoProfile -File `"$hf`" {n}" } } } $kl
$mg = Invoke-PsTest 'guard-mr' @'
$d, $kd, $shop, $plain = $args; . "$kd/skills/crafty/lib.ps1"
Update-KitTracking { param($t) $t.tasks['T1'] = @{ task = 'T1'; mrs = @('shop!12') } }
$cases = @(
  @('c-plain', $plain, 'glab mr create --title "fix: x" --fill --yes', 'names no tracker task'),
  @('c-branch', $shop, 'glab mr create --title "fix: x" --fill', ''),
  @('c-title', $plain, 'glab mr create -t "fix: x (TT-42)" -s fix/plain', ''),
  @('c-head', $plain, 'gh pr create -H f/TT-9-y -t x', ''),
  @('c-deploy', $plain, 'glab mr create -t x -s deploy/s -b main', ''), @('m-deploy', $shop, 'glab mr merge 77', ''),
  @('m-tracked', $shop, 'glab mr merge 12 --auto-merge --yes', ''),
  @('m-url', $plain, 'gh pr merge https://h.example/g/shop/-/merge_requests/12 --squash', ''),
  @('m-untracked', $shop, 'glab mr merge 13 -s', "track add -Task <id> -Mrs 'shop!13'"),
  @('m-other-repo', $shop, 'glab mr merge 12 -R g/other', "other!12"),
  @('m-no-number', $shop, 'glab mr merge --auto-merge', 'needs the MR number'),
  @('m-cd', $kd, "cd $shop && glab mr merge 13", "shop!13"),
  @('escape', $shop, 'KIT_NO_TASK="hotfix, no task" glab mr merge 13', ''),
  @('quoted', $shop, 'git commit -m "glab mr merge 13; gh pr create"', ''),
  @('heredoc', $shop, "glab mr merge 12 --yes; cat > n.md <<'EOF'`nglab mr merge 99`nEOF", ''),
  @('in-quotes', $shop, "glab mr merge 12; echo 'x`nglab mr merge 99`ny'", ''),
  @('continued', $plain, "glab mr create --fill \`n  --title `"fix (TT-5)`"", ''))
foreach ($c in $cases) {
  $j = @{ tool_name = 'Bash'; cwd = $c[1]; tool_input = @{ command = $c[2] } } | ConvertTo-Json -Compress
  $o = (& $d guard -Json $j) -join ''; $deny = $o -match '"permissionDecision":"deny"'
  "$($c[0]):$(if ($c[3]) { $deny -and $o.Contains($c[3]) } else { -not $deny })"
}
$env:KIT_TRACKER_TYPE = 'none'; $j = @{ tool_name = 'Bash'; cwd = $shop; tool_input = @{ command = 'glab mr merge 13' } } | ConvertTo-Json -Compress
"no-tracker:$(-not ((& $d guard -Json $j) -join '' -match 'deny'))"; $env:KIT_TRACKER_TYPE = $null
"logged:$(@(Read-KitLog guard (Get-Date).AddMinutes(-5) | Where-Object { $_.event -eq 'no-task' -and $_.reason -eq 'hotfix, no task' }).Count -eq 1)"
'@ @($D, $k, $shop, $plain)
& $J @{ tracker = @{ type = 'jira' } } $kl   # no branchTag: the vendor idPattern (the guard was silently off for jira / linear / azure / youtrack)
$gj = Invoke-PsTest 'guard-mr-jira' @'
$d, $plain = $args
foreach ($c in @(@('j-none', 'glab mr create --title "fix: x" --fill'), @('j-title', 'glab mr create -t "fix: x (SHOP-42)" -s fix/plain'), @('j-head', 'gh pr create -H feature/SHOP-7-cart -t x'))) {
  $j = @{ tool_name = 'Bash'; cwd = $plain; tool_input = @{ command = $c[1] } } | ConvertTo-Json -Compress; "$($c[0]):$((& $d guard -Json $j) -join '' -match '"permissionDecision":"deny"')" }
'@ @($D, $plain)
Remove-Item $kl
Expect "guard MR task link, tracker jira: no id denied, SHOP-42 in the title or branch passes ($($gj -join ' '))" (($gj -join ' ') -eq 'j-none:True j-title:False j-head:False')
Expect-Each $mg 'guard MR task link: # (c-*: create needs TT-<id> in branch or title; m-*: merge needs the MR tracked; escape: KIT_NO_TASK)' @('c-plain', 'c-branch', 'c-title', 'c-head', 'm-tracked', 'm-url', 'm-untracked', 'm-other-repo', 'm-no-number', 'm-cd', 'escape', 'quoted', 'heredoc', 'in-quotes', 'continued', 'no-tracker', 'logged', 'c-deploy', 'm-deploy') 19
# agents' background shells: owner from its transcript (Agent-tool meta, workflow journal, main session = coordinator); -AutoFix kills
$sh = Invoke-PsTest 'shells' @'
. $args[0]; $tr = Join-Path $args[1] 'tx-sh'; $env:KIT_TRANSCRIPTS = $tr; $env:KIT_PARAM_SUPERVISE_SHELLSTUCKMINUTES = '0'; $env:KIT_PARAM_SUPERVISE_HEARTBEATMINUTES = '1'; $t0 = Get-Date
$gone = (Join-Path $args[1] 'gone-wt') -replace '\\', '/'; $c1 = "cd $gone; until crafty.ps1 pipes -Dir $gone; do sleep 30; done"; $c2 = "cat > /dev/null; python - <<'EOF' 2>&1 || true`nEOF"
$tu = { param($f, $c, $at) New-Item -ItemType Directory -Force (Split-Path $f) | Out-Null; Add-Content $f (@{ type = 'assistant'; timestamp = ([datetime]$at).ToUniversalTime().ToString('o'); message = @{ content = @(@{ type = 'tool_use'; name = 'Bash'; input = @{ command = $c; run_in_background = $true } }) } } | ConvertTo-Json -Compress -Depth 6) }
$p1, $p2, $p3, $p4, $p5 = 1..5 | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -NoNewWindow }
& $tu "$tr/s9/subagents/agent-k1.jsonl" $c1 $p1.StartTime; '{"agentType":"devy","finished":true}' | Set-Content "$tr/s9/subagents/agent-k1.meta.json"
& $tu "$tr/s9/subagents/workflows/wf_1/agent-w2.jsonl" $c2 $p2.StartTime; '{"type":"started","agentId":"w2","label":"build:H2"}', '{"type":"result","agentId":"w2","result":{}}' | Set-Content "$tr/s9/subagents/workflows/wf_1/journal.jsonl"
# opsy lost its shell waiting on pipelines
$c3 = 'until [ $(glab api projects/1/pipelines/3035902453 | jq -r .status) = success ]; do sleep 60; done'; $c4 = 'cat n.md; python tidy.py --report x'
& $tu "$tr/s9/subagents/agent-k3.jsonl" $c3 $p3.StartTime; '{"agentType":"opsy","finished":true}' | Set-Content "$tr/s9/subagents/agent-k3.meta.json"; & $tu "$tr/s9/subagents/agent-k4.jsonl" $c4 $p4.StartTime
$bd = Get-KitPath board -Create; $hs = (Get-Process -Id $PID).StartTime.ToString('o')
@{ agent = 'opsy-1'; status = 'working'; joined = $t0.ToString('o'); beat = $t0.AddMinutes(-40).ToString('o'); transcript = "$tr/s9/subagents/agent-k3.jsonl"; holderPid = $PID; holderStart = $hs } | ConvertTo-Json | Set-Content "$bd/opsy-1.json"
@{ agent = 'leaver'; status = 'left'; joined = $t0.ToString('o'); beat = $t0.AddMinutes(25).ToString('o'); transcript = "$tr/s9/subagents/agent-k4.jsonl" } | ConvertTo-Json | Set-Content "$bd/leaver.json"
$c5 = 'cat n2.md; python tidy2.py'; & $tu "$tr/s9/subagents/agent-k5.jsonl" $c5 $p5.StartTime; '{"agentType":"revy","finished":true}' | Set-Content "$tr/s9/subagents/agent-k5.meta.json"
Get-ChildItem "$tr/s9" -Recurse -Filter 'agent-*.jsonl' | ForEach-Object { $_.LastWriteTime = $t0.AddMinutes($(if ($_.Name -eq 'agent-k5.jsonl') { 12 } else { 0 })) }
& $tu "$tr/s9.jsonl" 'sleep 900; echo coordinator' $t0.AddMinutes(-60)
$cl = { param($c) "`"C:\Git\bin\bash.exe`" -c `"source s && eval '$($c -replace "'", "'\''" -replace '"', '\"')' < /dev/null && pwd -P >| /tmp/c`"" }
$sp = { param($id, $par, $c, $at) [pscustomobject]@{ Id = $id; ParentId = $par; Name = 'bash.exe'; CommandLine = (& $cl $c); Created = $at; Cpu = 1 } }
$procs = @([pscustomobject]@{ Id = 50; ParentId = 1; Name = 'claude.exe'; CommandLine = 'claude'; Cpu = 9 }, (& $sp $p1.Id 50 $c1 $p1.StartTime), (& $sp $p2.Id 50 $c2 $p2.StartTime), (& $sp $p3.Id 50 $c3 $p3.StartTime), (& $sp $p4.Id 50 $c4 $p4.StartTime), (& $sp $p5.Id 50 $c5 $p5.StartTime),
  (& $sp 999999 50 'sleep 900; echo coordinator' $t0.AddMinutes(-60)), (& $sp 999998 50 'npm run lint' $t0.AddMinutes(28)), (& $sp 999997 7 'sleep 900; echo coordinator' $t0.AddMinutes(-60)))
$st = @{}; $rs = foreach ($i in 0, 1, 1.2, 2) { $w = Get-KitShellSweep $st $t0.AddMinutes(30 + $i) -AutoFix -Procs $procs -Sampler { } -GapSeconds 0; Start-Sleep -Milliseconds 300; $w }   # transcripts 30 min idle
"cmd:$((Get-KitShellCommand (& $cl $c2)) -eq $c2)"; "dir:$((Get-KitShellDir 'cd /tmp/x && npm run dev') -eq '')"; "k1:$($p1.HasExited)"; "k2:$($p2.HasExited)"; "k34:$(-not $p3.HasExited -and -not $p4.HasExited -and $p5.HasExited)"; $p3, $p4 | Stop-Process -Force
foreach ($i in 0..3) { "s${i}:$(@($rs[$i].rows | ForEach-Object { "$($_.owner)=$($_.state)" }) -join ',')|$(@($rs[$i].flags | ForEach-Object what) -join '|')" }
"log:$(@(Read-KitLog calls $t0.AddMinutes(-1) | Where-Object event -eq 'shell-kill').Count)"; Format-KitShellTable $rs[1].rows
# finished-looking owners kept: R2 fresh on the board by name (no transcript there); checky's tree runs a busy child (e2e suite)
$p6, $p7 = 1..2 | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -PassThru -NoNewWindow }
& $tu "$tr/s9/subagents/workflows/wf_2/agent-w6.jsonl" 'cat r6.md; python t6.py' $p6.StartTime; '{"type":"started","agentId":"w6","label":"test:R2"}', '{"type":"result","agentId":"w6","result":{}}' | Set-Content "$tr/s9/subagents/workflows/wf_2/journal.jsonl"
& $tu "$tr/s9/subagents/agent-k7.jsonl" 'cat r7.md; npx cypress run' $p7.StartTime; '{"agentType":"checky","finished":true}' | Set-Content "$tr/s9/subagents/agent-k7.meta.json"
@{ agent = 'R2'; status = 'working'; joined = $t0.ToString('o'); beat = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content "$bd/R2.json"
Get-ChildItem "$tr/s9/subagents" -Recurse -Filter 'agent-[kw][67].jsonl' | ForEach-Object { $_.LastWriteTime = $t0 }
$kid = [pscustomobject]@{ Id = 999990; ParentId = $p7.Id; Name = 'node.exe'; CommandLine = 'cypress'; Created = $t0; Cpu = 5 }; $st2 = @{}; $script:KitLiveCache = @{}
$bz = foreach ($i in 0, 1) { $kid.Cpu += 30; $w = Get-KitShellSweep $st2 $t0.AddMinutes(30 + $i) -AutoFix -Sampler { } -GapSeconds 0 -Procs @($procs[0], (& $sp $p6.Id 50 'cat r6.md; python t6.py' $p6.StartTime), (& $sp $p7.Id 50 'cat r7.md; npx cypress run' $p7.StartTime), $kid)
  "$(@($w.rows | ForEach-Object { "$($_.owner)=$($_.state)" }) -join ',')|$(@($w.flags | ForEach-Object { "$($_.what) -> $($_.action)" }) -join '|')" }
"busy:$($bz -join '#')|$(-not $p6.HasExited -and -not $p7.HasExited)"; $p6, $p7 | Stop-Process -Force; Remove-Item "$bd/R2.json"
$hd = "cd /d/x && export A=1; python - <<'`"'`"'EOF'`"'`"'`nimport a`nb`nEOF"; "short:$(Get-KitShellShort $hd)|$((Get-KitShellShort ('npm run x ' * 9)).Length)"
$dd = @{ at = $t0; rows = @(); flags = @(); mem = @{ TotalGB = 8; AvailGB = 4 }; keepFree = 1; resources = @(@{ name = 'r'; gb = 1 }); shells = $rs[1].rows }
$rp = (Format-KitReport $dd) -join "`n"; Write-KitSuperviseReport $dd @($rp) @() n; $f = Get-Content (Get-KitPath supervise-report) -Raw
"order:$($rp.IndexOf('| Resource |') -lt $rp.IndexOf('| Shell |') -and $f.IndexOf('## Resources') -lt $f.IndexOf('## Shells'))"
$dd.flags = @([pscustomobject]@{ level = 'WATCH'; what = 'w1'; action = 'a1' }, [pscustomobject]@{ level = 'ACT'; what = 'DECISION <b>x</b>'; who = 'devy'; action = 'answer it' }, [pscustomobject]@{ level = 'INFO'; what = 'auto-fixed: killed shell 7' }, [pscustomobject]@{ level = 'INFO'; what = 'plain info' })
'{"at":"2026-01-02T10:00:00","since":"2026-01-01","runs":[],"days":[]}' | Set-Content ((Get-KitPath usage-cache -Create) -replace '\.json$', '.result.json')   # the json must not copy it
$pg = foreach ($i in 1, 2) { Write-KitSuperviseHtml $dd @('sweep line') 'NEXT 5 min (x)' }; $hx = Get-Content $pg[1] -Raw; $hj = Get-Content ([IO.Path]::ChangeExtension($pg[1], '.json')) -Raw | ConvertFrom-Json
"svgfill:$($hx -match "<tr class='f fr ACT'>" -and $hx -match "id=sec-flagmap open><summary><h4>Flags &#183; 24 h</h4><span class=cnt>\(3 flags\)</span>" -and $hx -match "hasAttribute\('data-end'\)&&!tp\[n-1\]\?n-1:" -and $hx -notmatch 'class=fl data-row' -and $hx -match 'data-tg=fx-rows aria-expanded=false>1 auto-fixed this sweep &#183; 1 note' -and $hx -match 'colspan=5>plain info<' -and -not @([regex]::Matches($hx, '<(path|polyline|polygon)\b[^>]*>') | Where-Object { $_.Value -notmatch '\sfill(-opacity)?=' }).Count -and $hx -match '(^|\})svg \.ln\{fill:none')"   # an SVG line without fill draws black (dark theme)
$sx2 = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); agents = @([pscustomobject]@{ name = 's (devy)'; run = 'solo'; state = 'ACTIVE' }); shells = @([pscustomobject]@{ pid = 1; cmd = "a`nb`nc" }, [pscustomobject]@{ pid = 2; age = 19; dir = "$script:KitRoot/"; cmd = 'x' * 200 }, [pscustomobject]@{ pid = 3; cmd = 'ls'; next = ' ' }) })
"fold3:$($sx2 -match '(?s)rtg aria-expanded=false>Other<.{0,3000}?>devy-s<' -and $sx2 -match "class=cmd><summary title='a b c'>a b c</summary><div class=cmdf>a`nb`nc<" -and $sx2 -match "'>x{119}…</sum" -and $sx2 -match '<colgroup>(<col [^>]+>){5}</colgroup>' -and $sx2 -notmatch '<th>(Dir|Next)</th>' -and $sx2 -match "'Age'><span class=ago [^>]+>19 min<")"
$o1 = @(Format-KitSuperviseOut $dd $dd $pg[1]);$o0 = @(Format-KitSuperviseOut $dd $dd '') -join "`n"
# T8: 2 ACT + 30 WATCH of one kind + 3 auto-fixes
$fB = @(1..2 | ForEach-Object { [pscustomobject]@{ level = 'ACT'; what = "BUILD-FAIL: a$_ broke"; action = 'fix' } }) + @(1..30 | ForEach-Object { [pscustomobject]@{ level = 'WATCH'; what = "STALE: w$_ quiet"; who = "w$_"; action = 'ping' } }) + @(1..3 | ForEach-Object { [pscustomobject]@{ level = 'INFO'; what = "auto-fixed: f$_" } })
$oB = @(Format-KitSuperviseOut ([pscustomobject]@{ at = Get-Date; rows = @(); flags = $fB }) $null $pg[1])
$rxB = '^WATCH · STALE .*\(\+29 more: w2, '; "brief25:$($oB.Count -le 25 -and @($oB -match '^ACT').Count -eq 2 -and @($oB -match $rxB).Count -eq 1 -and @($oB -match '^FIXED · f1 · f2 · f3$').Count -eq 1) $($oB.Count): $($oB -join ' | ')"
"page:$($hx.Contains('&lt;b&gt;x&lt;/b&gt;') -and $hx -match '(?s)Kit internals</h2>.*Tuning</h3><span class=cnt>.*class=tgs data-mk=params-now>' -and $hx -match "data-tsv='key&#9;|data-tsv='key\t" -and $hx -notmatch 'as table \(copy\)' -and $hx -notmatch '<h3>(Parameters|Recent changes)</h3>' -and $hx -notmatch '<b>x' -and $hx.IndexOf('fr ACT') -lt $hx.IndexOf('fr WATCH') -and @($hj.history).Count -eq 2 -and @($hj.history[0].flags).Count -eq 2 -and $hj.history[0].fixed -eq 1 -and @($hj.stats.days).Count -eq 7 -and @($hj.stats.live).Count -eq 1 -and -not $hj.sweep -and $hj.stats.usageFile -like '*usage.result.json' -and -not ($hj.stats.PSObject.Properties.Name -contains 'usage') -and @(Get-Content ([IO.Path]::ChangeExtension($pg[1], '.json'))).Count -eq 1)"
$sj = '{"at":"2026-01-02T10:00:00","next":"NEXT 5 min","flags":[{"level":"WATCH","what":"<img src=x onerror=f()>","action":"a&b"}],"agents":[{"name":"<s>n</s> (workflow)","run":"r''1","state":"ACTIVE","task":"t · steps 1/4 · 2k tokens of 10k","since":"2026-01-02T09:00:00"}],"mem":{"TotalGB":8,"AvailGB":2},"history":[],"shells":[{"dir":"D:/w"}],"stats":{"days":[{"day":"2026-01-02","runs":3,"lessons":null}]}}'
$sx = Format-KitSuperviseHtml ($sj | ConvertFrom-Json); "render:$($sx.Contains('&lt;img src=x onerror=f()&gt;') -and $sx -notmatch '<img|<s>' -and $sx.Contains('a&amp;b') -and $sx.Contains('r&#39;1') -and $sx -notmatch '2k tokens of 10k' -and $sx -notmatch 'class=k>Runs</div>' -and $sx -notmatch 'Lessons recorded|Decisions (asked|answered)|Avg agent duration|Deploys recorded' -and $sx -match "agents failed</span><span [^>]*>(<i[^>]*></i>){7}</span><span class='gc z'>—</span>" -and $sx.Length -lt 300kb -and $sx -match "<td data-k='Dir'>D:/<wbr>w</td>" -and ($sx -replace '(\.tl span|\.tgn|\.tkt td|\.hrs\.dy \.kh \.kq,\.kh \.kq\.kt)\{[^}]*\}') -notmatch 'text-overflow|nowrap;overflow:hidden' -and $sx -match '\.cg\{[^}]*align-items:flex-start' -and $sx -match 'scrollbar-width:none.*intersect.*30dvh.*\.fx table\{table-l' -and $sx -match "tail=''>next 10:05<.*ago data-t='2026-01-02T09" -and ($sx -replace 'xmlns=\S+') -notmatch '=.?https?:|@import|url.h')"
$dz = $t0.Date.AddDays(-3).AddHours(9); $cf = Join-Path (Get-KitPath audit -Create) "$($dz.ToString('yyyy-MM-dd'))/calls.jsonl"; New-Item -ItemType Directory -Force (Split-Path $cf) | Out-Null
@(@(0, 'join', 'start', 1, '-Agent A -Run r1'), @(1, 'join', 'end', 1, 'exit'), @(2, 'join', 'start', 2, '-Agent B'), @(3, 'join', 'end', 2, 0), @(30, 'leave', 'start', 3, '-Agent A -Status done'), @(31, 'leave', 'end', 3, 'exit'), @(40, 'leave', 'start', 4, '-Agent B -Status paused'), @(41, 'leave', 'end', 4, 0), @(50, 'leave', 'start', 5, '-Agent C -Status blocked'), @(51, 'leave', 'end', 5, 0)) | ForEach-Object { $q = $_; $o = [ordered]@{ at = $dz.AddMinutes($q[0]).ToString('s'); verb = "board $($q[1])"; event = $q[2]; pid = $q[3] }; if ($q[2] -eq 'start') { $o.args = $q[4] } else { $o.rc = $q[4] }; $o | ConvertTo-Json -Compress } | Set-Content $cf
$dy = @(Get-KitSuperviseDays $null $dz 1)[0]; "days:$($dy.failed)/$(@($dy.PSObject.Properties.Name) -join ',')"
$pf = Join-Path $args[1] 'published.txt'; if (-not $__cfg) { $__cfg = [pscustomobject]@{} }; $__cfg | Add-Member -Force NoteProperty supervise ([pscustomobject]@{ publish = 'Set-Content -LiteralPath "' + $pf + '" -Value ($env:KIT_SUPERVISE_HTML + "  x")' })
'not json{' | Set-Content ([IO.Path]::ChangeExtension($pg[1], '.json'))   # corrupt .json: history restarts, page built
$pp = Write-KitSuperviseHtml $dd @() 'NEXT 5 min'; for ($w = 0; $w -lt 100 -and -not (Test-Path $pf); $w++) { Start-Sleep -Milliseconds 100 }; Start-Sleep -Milliseconds 300
"pub:$((Get-Content $pf -ErrorAction SilentlyContinue) -eq "$pp  x" -and $pp -and -not $env:KIT_SUPERVISE_HTML -and @((Get-Content ([IO.Path]::ChangeExtension($pp, '.json')) -Raw | ConvertFrom-Json).history).Count -eq 1 -and (Get-Content $pp -Raw) -match "\nsupervise\.publish\t\t\(set\)\t")"
"out:$($o1.Count -eq 5 -and $o1[1] -eq 'ACT · DECISION · devy · <b>x</b> -> answer it' -and $o1[2] -eq 'WATCH · w1 -> a1' -and $o1[3] -eq 'FIXED · killed shell 7' -and $o1[4] -eq '0 agent(s) active · 1 ACT · 1 WATCH' -and $o0 -match '\| Level \| Flag')"
(Format-KitSuperviseHtml ([pscustomobject]@{ at = $t0.ToString('o'); stats = @{ params = @(@{ key = 'a.x'; source = 'live' }, @{ key = 'b.y' }) } })) -replace '<head>', "<head><script>sessionStorage.setItem('kc-q','a.x')</script>" | Set-Content "$($args[1])/tg.html"   # a filter restored on load
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), (Kd))
Expect "supervise page: escaped, ACT first, 2 sweeps, no scrollbar, live ages, no URL, every SVG line / area with an explicit fill, standalone agents, long commands folded; -Brief html: link, flags, counts; no page = tables; publish masked ($($sh -match '^(page|out|pub|svgfill|fold3|render|days):'))" ($sh -contains 'page:True' -and $sh -contains 'svgfill:True' -and $sh -contains 'fold3:True' -and $sh -contains 'out:True' -and $sh -contains 'pub:True' -and $sh -contains 'render:True' -and $sh -contains 'days:1/day,final,failed,left')
Expect "supervise -Brief: <= 25 lines, all ACT, 1 WATCH line a kind, 1 FIXED ($($sh -match '^brief25:'))" (@($sh -match '^brief25:True ').Count -eq 1)
# own profile + a 90 s bound: on the default profile a running Chrome held it and the dump hung ~25 min (full run 2026-11-24)
if (Use-BrowserKit) { $tg = "$(NodeT tg "console.log(String((await import('node:child_process')).execFileSync(m.CHROME, ['--headless', ...m.QUIET_ARGS, '--disk-cache-size=1', '--user-data-dir=' + process.argv[3], '--dump-dom', process.argv[2]], { timeout: 90000, killSignal: 'SIGKILL' })))" ([Uri]::new("$(Kd)/tg.html").AbsoluteUri) "$(Kd)/tg-profile")"
  Expect "supervise page: a filter opens Tuning, Settings, the matching group's keys; hides the other$(if ($tg -match 'ETIMEDOUT|Error') { ' (Chrome dump failed or hit its 90 s bound)' })" ($tg -match 'id="sec-tuning" open="" data-fo="1"' -and $tg -match 'id="sec-settings" open="" data-fo="1"' -and $tg -match 'id="tp-b"[^>]* hidden=""' -and $tg -match '<html[^>]*flq') }
Expect "shells: cell unquoted, heredoc collapsed, preambles skipped, 60 chars; after RAM in -Brief and report ($($sh -match '^(short|order):'))" ($sh -contains 'short:python - <<EOF (heredoc, 2 lines)|60' -and $sh -contains 'order:True')
$s0, $s1, $s9, $s2 = @($sh -match '^s\d:')
Expect "shells: gone owner (finished, off board, idle): killed in sweep 1, poll loop or < 20 min idle in sweep 2; live board / fresh beat / coordinator kept ($s0 $s1)" (
  $sh -contains 'cmd:True' -and $sh -contains 'dir:True' -and $s9 -notmatch 'killed' -and $s2 -notmatch 'killed' -and $sh -contains 'k1:True' -and $sh -contains 'k2:True' -and $sh -contains 'k34:True' -and $sh -contains 'log:3' -and
  $s0 -match '^s0:devy=ORPHAN,opsy-1=running,leaver=running,revy=ORPHAN,coordinator=running\|SHELL ORPHAN pid \d+ of devy .+\|auto-fixed: killed shell \d+ of H2 \(owner H2 finished, idle 30 min\): cat > /dev/null' -and $s0 -notmatch 'killed shell \d+ of (devy|opsy|leaver|revy)' -and
  $s1 -match '^s1:opsy-1=STALLED,leaver=STALLED,coordinator=STALLED\|auto-fixed: killed shell \d+ of devy \(owner devy finished, idle 31 min; dir gone: .+gone-wt; no CPU, IO or output for \d+ min.*\): until crafty.*\|SHELL STALLED pid 999999 of coordinator' -and $s1 -match 'killed shell \d+ of revy \(owner revy finished, idle 19 min' -and
  $s2 -match '^s3:opsy-1=STALLED,leaver=STALLED,coordinator=STALLED\|' -and ($sh -join "`n") -match '\| Shell \| Owner \| Age \| State \| Next \|(.|\n)+\| coordinator \| 91 min \| STALLED \| yours: stop it')
$bz = "$($sh -match '^busy:')"
Expect "shells: an owner live on the board by name or a busy child tree is never ORPHAN or killed; a live owner of a STALLED shell gets a board msg, no taskkill ($bz)" ($bz -match '^busy:R2=running,checky=running\|#R2=STALLED,checky=running\|SHELL STALLED pid \d+ of R2 .+ -> board msg R2 to end it \(live agent or busy tree: no taskkill\)\|True$' -and $bz -notmatch 'killed|ORPHAN')
$O = Join-Path $k 'skills/bossy/bossy.ps1'   # supervise -Brief report
$rd = @{ rows = @(@{ name = 'W1'; task = 'T1'; state = 'ACTIVE'; since = '2026-01-02T10:00'; last = '2026-01-02T10:05'; doing = 'StructuredOutput' }, @{ name = 'J1'; task = '2026-10-29-ab-staging-2xyz wf_e8c577f7-894'; state = 'WAITING'; wait = 'cd deploy 0abbaa36, train d09409 waits for leases (switch-over)'; since = '2026-01-02T10:00'; next = 'envy.ps1 wait -Id 0abbaa36' })
  mem = @{ TotalGB = 64; AvailGB = 16 }; keepFree = 8; info = @('ready'); resources = @(@{ name = 'ab · api'; by = 'W1'; gb = 3 }) + @(1..6 | ForEach-Object { @{ name = "browser a-b·c·d$_"; by = 'devy-3dy3'; gb = 1 } }) }
$ef = { param($a, $q) @{ level = 'ACT'; kind = 'ENV-FIX'; who = "$a (wave-brief-a8da)"; age = '34 min'; what = $a; problem = $q; action = "& D:\Kit\.claude\skills\bossy\bossy.ps1 decide answer -Id e-20261029090127-$a-e69a" } }
$rd.flags = @(@{ level = 'WATCH'; what = 'RESTART LOOP: cd search 3x'; action = 'logs' }, (& $ef W 'devy-3dy3-put'), ((& $ef J ('p ' * 60)) + @{ next = 'nx' }), (& $ef J1 'C:\d\|x'))
$r1 = (& { . $O; Format-KitReport $rd }) -join "`n"; $rd.mem.AvailGB = 6; $rd.rows = @(); $r2 = (& { . $O; Format-KitReport $rd }) -join "`n"
$want1 = @('| Agent | Task / run | State | Since | Last progress | Next |', '|---|---|---|---|---|---|', '| J1 | ab-staging- 2xyz e8c577f7 | WAITING: cd deploy 0abbaa36, train d09409 waits for leases (switch- over) | 10:00 | — | envy.ps1 wait -Id 0abbaa36 |', '| W1 | T1 | ACTIVE | 10:00 | 10:05 Structured Output | — |', '', '| Level | Flag | Who / item | Age | Problem | Next step |') -join "`n"
$fr = @($r1 -split "`n" | Where-Object { $_ -match '^\| (ACT|WATCH|INFO) \|' }); $fw = @($r1 -split "`n`n" | Where-Object { $_.StartsWith('|') } | ForEach-Object { $tl = $_ -split "`n"; $nc = ($tl[0] -split '\|').Count - 2
  (1..$nc | ForEach-Object { $ci = $_; @($tl | ForEach-Object { ($_ -split '(?<!\\)\|')[$ci] -split ' ' | ForEach-Object Length }) | Measure-Object -Maximum } | Measure-Object Maximum -Sum).Sum + 3 * $nc + 1 })
$rt = foreach ($n in 2, 3, 7) { $rd.resources = @(1..$n | ForEach-Object { @{ name = "r$_"; gb = $_ } }); $fo = & { . $O; Format-KitReport $rd }; "$(@($fo -match '^\| Resource \|').Count)$(@($fo -match '^\| r\d').Count)$(@($fo -match '^\| r\d.*—').Count)$(@($fo -match '^\| r\d' | Where-Object { ($_ -split '\|').Count -ne (@($fo -match '^\| Resource')[0] -split '\|').Count }).Count)$(@(($fo -join "`n") -split "`n`n" | Where-Object { $_.Trim() -and -not $_.StartsWith('|') -and $_ -notmatch '^\*\*RAM\*\* [^\n]+$' }).Count)" }
Expect "report: tables only (no titles but RAM's, no loose lines), widths ($fw) <= 95, cells <= 80 whole words; RAM groups by rows, no filler ($rt)" ($r1.StartsWith($want1) -and "$rt" -eq '12000 13000 14000' -and $r1.EndsWith("`n") -and -not @($fw | Where-Object { $_ -gt 95 }).Count -and -not ($fr -split '\|' -match '.{83}') -and $r1 -cnotmatch 'full: report|\*\*Flags|\*\*Shells|NEXT|transcripts' -and $fr[1] -match ' p …? \| nx \|$' -and $fr[3] -match 'WATCH \| RESTART LOOP \| coordinator \| — \| cd' -and ($r1 -replace ' ').Contains('J1(wave-brief-a8da)|34min|C:\d\\\|x|bossy.ps1decideanswer-Ide-20261029090127-J1-e69a|') -and $r2 -match 'below the floor 8 GB' -and $r2 -match 'nothing running')
$bnv = (pwsh @np $D wt 2>&1 | ForEach-Object { "$_" }) -join ' '; $bnc = $LASTEXITCODE; $bdv = pwsh @np $O board 2>&1 | Out-String   # the raw line, not the wrapped error view
Expect "a missing verb: exit 2 with the verb list ($bnc); board without one: show" ($bnc -eq 2 -and $bnv -match 'missing -Action\. Verbs: new, sync' -and $bdv -match '^board: ')
$mm = @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $at = @{ '7' = '2026-01-02T10:00Z'; '12' = '2026-01-02T11:00Z' }
function Invoke-HostVerb($Verb, $A) { if ($Verb -eq 'mr.url') { "https://h/$($A.repo)/-/merge_requests/$($A.n)" } else { @{ state = ('opened', 'merged')[[bool]$at[$A.n]]; merged_at = $at[$A.n]; title = "T$($A.n) $(if ($A.n -ne '21') { "(CU-$(('m1', 'b9')[$A.n -eq '13']))" }) ($(($A.repo -split '/')[-1]))" } } }
function Invoke-HostApi { @{ state = 'opened'; title = 'CU-m1 x' } }
function Start-Process { }
'@
$mc = Invoke-PsTest mrs-comment ($mm + @'
$null = Add-TrackerComment m1 'a person''s note'; $KitConf.TrackerTag = 'CU-'
1..2 | ForEach-Object { $null = Invoke-Track add -Task m1 -Mrs 'g/web!9' }; $null = Invoke-Track add -Task m1 -Mrs 'g/web!30'
$c = @(Get-TrackerComments m1)
"mrs:$($c.Count -eq 1 -and $c[0].text -eq 'a person''s note')"
$tb = Invoke-Track add -Task b1 -Mrs 'g/web!12'
"tb:$($tb -match 'names m1; registering under -Task b1' -and (Invoke-Track show -Task b1) -match '^b1 : g/web!12 \| done$')"
"ref:$((& $args[1] tracker comment m1 "MRs (merge order)`n- x !1") -match 'refused: no MRs comment' -and $LASTEXITCODE -eq 1)"
$tg = Invoke-Track add -Mrs 'g/web!9,g/web!13' -HoldPromotion 'x' | Out-String
"tg:$($tg -match 'tracking m1 : g/web!9, g/web!30 [^\n]*HELD: x' -and $tg -match 'tracking b9 : g/web!13 [^\n]*HELD: x' -and "$(Invoke-Track add -Mrs 'g/web!9,g/web!13,g/web!21')" -match 'NOTE: g/web!21 name\(s\) no task')"
'@) @($O, $D)
Expect "track add: no MRs comment written (MR links live in the Items checklist), a person's comment kept ($mc)" ("$mc" -match 'mrs:True')
Expect "track add -Task b1 with an MR titled for m1: keyed by -Task; track show -Task; a tracker comment of an MRs comment refused; no -Task, MRs titled for 2 tasks: one add per task (buildy track step) ($mc)" ("$mc" -match 'tb:True.*ref:True.*tg:True')
git -C $shop worktree add -q -b gone "$(Kd)/gone" 2>$null; Remove-Item -Recurse -Force "$(Kd)/gone"; $wg = "$(pwsh @np $D wt remove -Dir "$(Kd)/gone" -Repo $shop 2>&1) rc=$LASTEXITCODE"
$wt = "$(pwsh @np $D wt remove -Dir "$(Kd)/typo" -Repo $shop 2>&1) rc=$LASTEXITCODE"
Expect "wt remove, folder gone: said, exit 0, record pruned; a path git never listed: error ($wg | $wt)" ($wg -match 'already gone.*rc=0$' -and "$(git -C $shop worktree list)" -notmatch 'gone' -and $wt -match 'no such folder.*rc=1$')
$env:KIT_TRACKER_TYPE = 'none'; $ni =pwsh @np $D tracker comment '' x -Kind comment-status -ProseOk t 2>&1 | Out-String; $env:KIT_TRACKER_TYPE = $null
Expect "tracker comment without a task id: refused, never a branch guess" ($ni -match 'no task id')
$bf = & { . $O; function Test-KitLive($l) { $l.agent -ne 'gone' }; $n = Get-Date; $f = { param($h, $ok) @{ ok = $ok; at = $n.AddMinutes(-$h).ToString('o') } }; $x = { param($h) (& $f ($h + 2) $false), (& $f ($h + 1) $false), (& $f $h $false) }
  $e = { param($p, $o, $c, $h) @{ event = 'end'; kind = 'm'; project = $p; owner = $o; code = $c; at = $n.AddMinutes(-$h).ToString('o') } }
  @(Get-KitBuildFailures @{ 'm|old' = & $x 70; 'm|new' = & $x 5; 'm|gone' = & $x 5; 'm|fixed' = & $x 5; 'm|mix' = @((& $f 3 $false), (& $f 2 $true), (& $f 1 $false)) } $n @((& $e new w 1 5), (& $e gone gone 1 5), (& $e fixed w2 1 5), (& $e fixed/sub w2 0 2)) | ForEach-Object { "$($_.key)@$($_.who)" }) -join ',' }
Expect "build failures: 3 in a row flag only < 60 min old, while their agent lives and has no green build of that dir since ($bf)" ($bf -eq 'm|new@w')
# pokey.ps1 api: auth kinds, -Save, -ContentType, paths
$Q = Join-Path $k 'skills/pokey/pokey.ps1'
$api = Start-TestApi; $apiPort = $api.port
$T = { param($a, $sub) @{ api = "http://127.0.0.1:$apiPort$sub"; auth = $a; users = @{ admin = 'u', 'K9' }; defaultTenant = 'acme' } }; $L = @{ path = '/login'; body = @{}; tokenField = 'access_token' }
& $J @{ targets = @{ tl = & $T ($L + @{ type = 'login' }); tc = & $T ($L + @{ type = 'cookie'; csrfCookie = 'XSRF-TOKEN' }); tt = & $T @{ type = 'none' } '/t/{tenant}' } } (Join-Path $k 'skills/pokey/targets.local.json') 6
$ok = foreach ($x in 'tl/l', 'tt/x') { $n, $ep = $x -split '/'; if ((Px $Q api -Target $n -Path "/$ep" -Save "A1-C1_01_$n" -OutDir (Kd) 2>&1) -match 'HTTP 200') { $n } }
Expect "api auth login + none ($ok)" (@($ok).Count -eq 2 -and (Get-Content "$(Kd)/A1-C1_01_tl.json" -Raw) -match '"authorization": "\[redacted\]"')
foreach ($e in 'pdf', 'txt', 'empty') { $null = Px $Q api -Target tt -Path "/$e" -Save "S-$e" -OutDir (Kd) 2>&1 }; $bo = @(Get-ChildItem (Kd) -Filter 'S-*.body*').Name -join ' '
Expect "api -Save: octet-stream sniffed, empty body: no file ($bo)" ($bo -ceq 'S-pdf.body.pdf S-txt.body.txt')
Expect 'api -ContentType is sent' ((Px $Q api -Target tt -Method POST -Path '/ct' -Body 'hi' -ContentType text/plain 2>&1) -match 'HTTP 200')
$pp = Px $Q api /x -Target tt 2>&1 | Out-String; $pg = Px $Q api -Target tt -Path 'C:/Program Files/Git/x' 2>&1 | Out-String
Expect 'api: a Git Bash path (C:/Program Files/Git/x) is sent as /x' ($pg -match 'HTTP 200'); $pu = Px $Q api -Target tt 2>&1 | ForEach-Object { "$_" } | Out-String; $puc = $LASTEXITCODE
Expect 'api: the first bare arg is -Path; none -> exit 2 with the usage line' ($pp -match 'HTTP 200' -and $puc -eq 2 -and $pu -match 'Usage: api -Target')$api.proc.Kill()
$ke = try { & { $k = $null; Kd } } catch { "$_" }; $re = try { & { . (Lib); $script:KitRoot = '/'; Get-KitRuntime } } catch { "$_" }
Expect "path guards ($ke|$re)" ($ke -match 'Kd:' -and $re -match 'bad runtime')
# cell cuts (back from workflows.tests for its cap)
$ec = & { . (Lib); "$((Limit-KitCell ('x' * 75 + '😀' * 9)) -match '[\uD800-\uDBFF](?!\p{Cs})')$((Format-KitCell ('a' * 11 + '😀')) -eq "$('a' * 11) 😀")$((Format-KitCell "add -HoldPromotion ''" -Exact) -eq "add -HoldPromotion ''")" }
Expect 'cut: emojis, -Parameters whole' ($ec -eq 'FalseTrueTrue')
# guard.envChangeCommands: an org's env-change command joins vocab.json's list in the guard (lib.ps1) and the testing-doc check (kitbag.py)
$ecq = { $gpy = Join-Path $k 'skills/bossy'; "$(& { . (Lib); 'mytool flip-env x' -match (Get-KitEnvChangeRx) })$(python -X utf8 -c "import sys; sys.path.insert(0, r'$gpy'); import kitbag; print(bool(kitbag.env_change_rx().search('Run mytool flip-env now')))")" }
$ecg0 = & $ecq; Set-JsonFile $kl @{ guard = @{ envChangeCommands = @('mytool\s+flip-env') } }; $ecg1 = & $ecq
Expect "guard.envChangeCommands: an org command joins the guard and testing-doc lists ($ecg0 -> $ecg1)" ($ecg0 -eq 'FalseFalse' -and $ecg1 -eq 'TrueTrue')
# deployed-env: KIT_DECISION takes every id decide mints (dec-<words>, old d-<stamp>-<suffix>); a word for another env still refused
$dwAt = (Get-Date).ToString('o'); & { . (Lib); foreach ($dw in @(@('dec-own-domain-3', 'e1'), @('d-20261127080000-coordinator-ab12', 'e2'), @('dec-set-website-3', 'e9'), @('dec-12', 'e3'), @('dec-0012', 'e4'), @('dec', 'e5'))) { Write-KitState (Join-Path (Get-KitPath decisions -Create) "$($dw[0]).json") @{ id = $dw[0]; gate = 'deploy'; status = 'answered'; item = $dw[1]; mrs = @(); by = 'owner'; source = 'chat'; question = 'change it?'; answer = 'yes'; answeredAt = $dwAt } } }
$dwOut = foreach ($dw in @(@('dec-own-domain-3', 'e1'), @('d-20261127080000-coordinator-ab12', 'e2'), @('dec-set-website-3', 'e1'), @('dec-12', 'e3'), @('dec-0012', 'e4'), @('dec', 'e5'))) { $dwJ = @{ tool_name = 'Bash'; cwd = $k; tool_input = @{ command = "KIT_DECISION=$($dw[0]) aws elasticbeanstalk update-environment --environment-name $($dw[1]) --option-settings Namespace=n,OptionName=A,Value=true" } } | ConvertTo-Json -Compress; "$((pwsh @np $D guard -Json $dwJ 2>&1) -join '' -match 'changes a deployed env')" }
Expect "guard deployed-env: dec-<words>, dec-<n>, dec-<nnnn>, bare dec and d-<stamp> owner words pass, a word for another env is refused ($($dwOut -join ' '))" (($dwOut -join ' ') -eq 'False False True False False False')
Remove-TestKit $k
Complete-Tests
