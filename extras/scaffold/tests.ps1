#Requires -Version 7
<#
tests.ps1 (extra scaffold): new / rename / remove / new adr / rename event + config-key on a throw-away git copy of the kit.
Usage: pwsh -NoProfile -File extras/scaffold/tests.ps1 -Kit <kit>   (the plugin comes from files/ beside this file)
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
$ErrorActionPreference = 'Stop'
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$kc = Join-Path ([IO.Path]::GetTempPath()) "kit-scaffold-$PID\.claude"; New-Item -ItemType Directory -Force $kc | Out-Null
foreach ($f in @(git -C $Kit ls-files)) { $s1 = Join-Path $Kit $f; if (Test-Path $s1) { $d = Join-Path $kc (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $s1 $d -Force } }
Copy-Item (Join-Path $PSScriptRoot 'files/skills/orchestrate/kittool_scaffold.py') (Join-Path $kc 'skills/orchestrate')
'/skills/orchestrate/kittool_scaffold.py' | Add-Content (Join-Path $kc '.gitignore')
git -C $kc init -q; git -C $kc add -A; git -C $kc -c user.name=t -c user.email=t@t commit -q -m 'feat: base'
$KT = Join-Path $kc 'skills/orchestrate/kittool.py'
$mf = { (Get-Content (Join-Path $kc 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._manifest }
$null = & $py -X utf8 $KT new agent zappy --skill dev-kit 2>&1
$l1 = & $py -X utf8 $KT lint --no-flow 2>&1 | Out-String
$okNew = (Test-Path (Join-Path $kc 'agents/zappy.md')) -and (& $mf).agents.zappy -and (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -match '\| R\d+ \| TODO\(new\).*`zappy` agent' -and $l1 -match 'TODO-STUB'
$tpl = Join-Path $kc 'skills/dev-kit/templates.md'; Add-Content $tpl "`nsee last-zappys and zappy-stamp" -Encoding utf8
$null = & $py -X utf8 $KT rename agent zappy zippy 2>&1
$okRen = (Test-Path (Join-Path $kc 'agents/zippy.md')) -and -not (Test-Path (Join-Path $kc 'agents/zappy.md')) -and (& $mf).renamed.zappy -eq 'zippy' -and
  (Get-Content $tpl -Raw) -match 'see last-zippys and zippy-stamp' -and (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -match '`zippy` agent' -and
  (Test-Path (Join-Path $kc '.codex/agents/zippy.toml')) -and -not (Test-Path (Join-Path $kc '.codex/agents/zappy.toml'))
$null = & $py -X utf8 $KT remove agent zippy 2>&1
$okRem = -not (Test-Path (Join-Path $kc 'agents/zippy.md')) -and -not (& $mf).agents.zippy -and (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -notmatch 'zippy'
$ev = @((& $mf).events); $e1, $e2 = $ev[-1], "E$([int]$ev[-1].Substring(1) + 1)"
$null = & $py -X utf8 $KT rename event $e1 $e2 2>&1
$null = & $py -X utf8 $KT new adr Budget per agent 2>&1
$sk = Get-Content (Join-Path $kc 'skills/orchestrate/SKILL.md') -Raw
$okId = (& $mf).events -contains $e2 -and -not ((& $mf).events -contains $e1) -and $sk -match "\|\s*$e2\s*\|" -and
  (Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -match '## Decisions\r?\n(?:.*\r?\n)*- \d{4}-\d\d-\d\d Budget per agent: context TODO\(new\)'
$nskill = @(Get-ChildItem (Join-Path $kc 'skills') -Recurse -File).Count
$null = & $py -X utf8 $KT remove skill '' 2>&1; $rc = $LASTEXITCODE
$okEmpty = $rc -ne 0 -and @(Get-ChildItem (Join-Path $kc 'skills') -Recurse -File).Count -eq $nskill
Remove-Item (Split-Path $kc) -Recurse -Force -ErrorAction SilentlyContinue
$fails = 0
foreach ($c in @(@('new agent: file, manifest, Router stub, TODO-STUB lint', $okNew), @('rename agent: file, references, manifest renamed, ports', $okRen),
    @('remove agent: file, manifest, Router row', $okRem), @('rename event + new adr', $okId), @('remove skill "": refused, no skill touched', $okEmpty))) {
  if ($c[1]) { "PASS scaffold: $($c[0])" } else { "FAIL scaffold: $($c[0])"; $fails++ }
}
exit [int]($fails -gt 0)
