#Requires -Version 7
<#
tests.ps1 (extra kit-admin): audit recover --fix never removes a worktree holding commits not on origin/main.
Usage: pwsh -NoProfile -File extras/kit-admin/tests.ps1 -Kit <kit>   (the plugin comes from files/ beside this file)
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
$ErrorActionPreference = 'Stop'
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$root = Join-Path ([IO.Path]::GetTempPath()) "kit-admin-$PID"; $kc = Join-Path $root '.claude'; New-Item -ItemType Directory -Force $kc | Out-Null
foreach ($f in @(git -C $Kit ls-files)) { $s1 = Join-Path $Kit $f; if (Test-Path $s1) { $d = Join-Path $kc (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $s1 $d -Force } }
Copy-Item (Join-Path $PSScriptRoot 'files/skills/orchestrate/kittool_admin.py') (Join-Path $kc 'skills/orchestrate')
'/skills/orchestrate/kittool_admin.py' | Add-Content (Join-Path $kc '.gitignore')
$gt = { git -C $args[0] -c user.name=t -c user.email=t@t @($args | Select-Object -Skip 1) }
git -C $kc init -q -b main; git -C $kc add -A; & $gt $kc commit -q -m 'feat: base'
$og = Join-Path $root 'origin.git'; git init -q --bare $og; git -C $kc remote add origin $og; git -C $kc push -q origin main 2>&1 | Out-Null; git -C $kc fetch -q origin
$wt = Join-Path $root 'wt-detached'; git -C $kc worktree add -q --detach $wt 2>&1 | Out-Null
'work' | Set-Content (Join-Path $wt 'unmerged.txt'); git -C $wt add unmerged.txt; & $gt $wt commit -q -m 'feat: unmerged work'
Get-ChildItem $wt -Force | ForEach-Object { $_.LastWriteTime = (Get-Date).AddHours(-5) }   # idle, like a forgotten worktree
$out = & $py -X utf8 (Join-Path $kc 'skills/orchestrate/kittool.py') audit recover --fix --kit $kc 2>&1 | Out-String
$ok = (Test-Path (Join-Path $wt 'unmerged.txt')) -and $out -match 'RECOVER-HALF'
git -C $kc worktree remove --force $wt 2>&1 | Out-Null
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($ok) { 'PASS kit-admin: recover --fix keeps a detached worktree with unmerged commits (listed as RECOVER-HALF)'; exit 0 }
"FAIL kit-admin: recover --fix keeps a detached worktree with unmerged commits`n$out"; exit 1
