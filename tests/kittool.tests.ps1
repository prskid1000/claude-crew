#Requires -Version 7
<#
kittool.tests.ps1: kittool.py prose, lint, port, new / rename / remove, budget, flow; kit-wide script checks.
Usage: pwsh -NoProfile -File <kit>/tests/kittool.tests.ps1 (or tests/kit-tests.ps1 -Area kittool).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit kittool
$kw = foreach ($ps in @(git -C $src ls-files '*.ps1')) { $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $src $ps), [ref]$null, [ref]$null)
  $ast.FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -in 'if', 'foreach', 'switch', 'while', 'for', 'do', 'try' }, $true) | ForEach-Object { "${ps}:$($_.Extent.StartLineNumber)" } }
Expect "no keyword used as a command, e.g. (if ...) without `$ ($($kw -join ', '))" (-not $kw)
$hx = foreach ($sc in 'skills/dev-kit/dev.ps1', 'skills/qa-kit/qa.ps1', 'skills/android-swarm/swarm.ps1') { $null = Px (Join-Path $src $sc) --help 2>&1; "$LASTEXITCODE" }
Expect "dev.ps1 / qa.ps1 / swarm.ps1 --help exit 0 ($($hx -join ','))" (($hx -join ',') -eq '0,0,0')
$out = "Merge branch 'feature/long-branch-name-for-testing' into deploy/staging-longer-name" | python -X utf8 (Join-Path $src 'skills/orchestrate/kittool.py') prose --kind merge-commit - | Out-String
Expect 'prose: merge-commit kind (no conv, no 72-char subject)' ($LASTEXITCODE -eq 0)
$KT = Join-Path $src 'skills/orchestrate/kittool.py'; $pf = Join-Path $k 'mr.md'
"## Summary`nhttps://t.example.com/T-1 — keep the offset`n## Changes`n- ISO dates`n## How tested`n- tests ``ExportTest```n## Risks`n- none`n## Links`n- doc" | Set-Content $pf
$null = python -X utf8 $KT prose --kind mr-body $pf; Expect 'prose: a template-shaped MR body passes' ($LASTEXITCODE -eq 0)
"Hi, I hope this is basically fine`n## Changes`n- a`n- b`n- c`n- d" | Set-Content $pf
$out = python -X utf8 $KT prose --kind mr-body $pf | Out-String
Expect 'prose: filler, missing sections, a 4th bullet are findings' ($LASTEXITCODE -eq 1 -and $out -match 'filler: "basically"' -and $out -match 'missing sections' -and $out -match '4 bullets')
$out = 'updated stuff' | python -X utf8 $KT prose --kind commit - | Out-String
Expect 'prose: a non-conventional commit subject is a finding' ($LASTEXITCODE -eq 1 -and $out -match 'conv')
$wc = python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kittool as k; k.load_json = lambda p: ({'commitStyle': 'free'}, 0); print(k.words('日本 wörd ok'), k.commit_rx())"
Expect 'prose: CJK per char, any script''s words; commitStyle free' ("$wc" -eq '4 \S')
$yq = python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kittool as k; print(len(k.yaml_problems('steps:\n  - name: Lint: x\n')) > 0, k.yaml_problems('steps:\n  - name: \'Lint: x\'\n  - run: |\n      a: b\n'), k.old_name_rx('qa-kit').search('see skills/qa-kit/qa.ps1') is not None)"
Expect 'lint YAML: an unquoted ": " in a workflow fails, quoted / block scalars pass; old names after a /' ("$yq" -eq 'True [] True')
$rj = Join-Path $k 'results.json'; '{"checks":[{"id":"T1","note":"ok"},{"id":"T2","note":"' + ('word ' * 45) + '"}]}' | Set-Content $rj
$out = python -X utf8 $KT prose --kind result-note $rj | Out-String
Expect 'prose: a results.json note over 40 words is a finding' ($LASTEXITCODE -eq 1 -and $out -match '45 words')
Push-Location $k; $null = python -X utf8 $KT lint --help; $h = $LASTEXITCODE; $null = python -X utf8 $KT flow --bogus 2>&1; $u = $LASTEXITCODE
$null = python -X utf8 $KT lint (Join-Path $k 'skills') 2>&1; $nk = $LASTEXITCODE; Pop-Location
Expect 'kittool: --help 0, writes nothing; bad flag / non-kit dir 2' ($h -eq 0 -and $u -eq 2 -and $nk -eq 2 -and -not (Test-Path (Join-Path $k '--help')))
$eol = git -C $src check-attr eol -- .codex/config.toml .agents/hooks.json .codex/agents/x.toml .agents/workflows/x.md GEMINI.md
Expect 'port: generated ports are eol=lf (an autocrlf clone shows no line-ending-only diffs)' (@($eol | Where-Object { $_ -match ': eol: lf$' }).Count -eq 5)
# kittool internals (python)
$ktt = @'
import importlib.util, json, os, sys, tempfile, tomllib
from pathlib import Path
spec = importlib.util.spec_from_file_location('kittool', sys.argv[1]); kt = importlib.util.module_from_spec(spec); spec.loader.exec_module(kt)
tmp = Path(tempfile.mkdtemp())
# TOML / YAML: a quote and a backslash in a description stay valid
kt.CODEX_AGENTS = tmp / 'c'; kt.GRAVITY_AGENTS = tmp / 'g'; kt.CODEX_AGENTS.mkdir(); kt.GRAVITY_AGENTS.mkdir()
d = 'say "hi" C:\\x'
kt.write_codex('a', {'description': d}, 'body'); kt.write_gravity('a', {'description': d}, 'body')
ok_toml = tomllib.loads((tmp / 'c' / 'a.toml').read_text(encoding='utf-8'))['description'] == d
ok_lf = b'\r\n' not in (tmp / 'c' / 'a.toml').read_bytes()
# port_deploy keeps user files, removes only stale generated ports
kit = tmp / 'ws' / '.claude'
for p in ('.codex/agents/a.toml', '.agents/agents/a.md', 'AGENTS.md', 'GEMINI.md'):
    (kit / p).parent.mkdir(parents=True, exist_ok=True); (kit / p).write_text('x', encoding='utf-8')
ws = kit.parent
for p in ('.codex/config.local.toml', '.codex/agents/old.toml', '.agents/agents/mine.txt'):
    (ws / p).parent.mkdir(parents=True, exist_ok=True); (ws / p).write_text('user', encoding='utf-8')
kt.KIT, kt.WORKSPACE = kit, ws
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    kt.port_deploy()
ok_deploy = (ws / '.codex/config.local.toml').exists() and (ws / '.agents/agents/mine.txt').exists() and not (ws / '.codex/agents/old.toml').exists() \
    and (ws / '.codex/agents/a.toml').read_text(encoding='utf-8') == 'x' and kt.deployed_stale() == []
# a linked worktree reads localOnly from the main clone; a non-repo folder is its own main clone
ok_main = kt.main_clone(str(tmp)) == str(tmp)
# lint measures PROSE against the linted kit's templates.md (k.dir), not the script's kit
src = open(sys.argv[1], encoding='utf-8').read()
ok_prose = 'writing_standards(k.dir)' in src and 'writing_standards(KIT)' not in src \
    and "kit_path('cache', create=True, kit=kit), osp.basename(loc_rel)" in src and "render timed out" in src
print(f'kittool-ports:{ok_toml and ok_lf}')
print(f'kittool-deploy:{ok_deploy}')
print(f'kittool-misc:{ok_main and ok_prose}')
'@
$kf = Join-Path ([IO.Path]::GetTempPath()) "kt-test-$PID.py"; Set-Content $kf $ktt -Encoding utf8
$res = @(& $py -X utf8 $kf (Join-Path $src 'skills/orchestrate/kittool.py') 2>&1); Remove-Item $kf -Force
Expect-Each $res 'kittool: #' 'kittool-ports', 'kittool-deploy', 'kittool-misc'
$oldWf = 'dev' + '-wave'; $oldSk = 'tech' + '-audit'   # built: no old name in the kit (lint OLD-NAME)
$kc = Join-Path ([IO.Path]::GetTempPath()) "kit-reg-$PID\.claude"; New-Item -ItemType Directory -Force $kc | Out-Null
foreach ($f in @(git -C $src ls-files) + @('agents/devy.md', 'agents/revy.md', 'agents/checky.md', 'agents/kitty.md')) { $s1 = Join-Path $src $f; if (Test-Path $s1) { $d = Join-Path $kc (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $s1 $d -Force } }
git -C $kc init -q; git -C $kc add -A; git -C $kc -c user.name=t -c user.email=t@t commit -q -m 'feat: base'
$KT2 = Join-Path $kc 'skills/orchestrate/kittool.py'
$n1 = & $py -X utf8 $KT2 new agent zappy --skill dev-kit 2>&1 | Out-String
$l1 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
$mf = { (Get-Content (Join-Path $kc 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json)._manifest }
$okNew = (Test-Path (Join-Path $kc 'agents/zappy.md')) -and (& $mf).agents.zappy -and (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -match '\| R\d+ \| TODO\(new\).*`zappy` agent' -and $l1 -match 'TODO-STUB'
$tpl = Join-Path $kc 'skills/dev-kit/templates.md'; Add-Content $tpl "`nsee last-zappys and zappy-stamp" -Encoding utf8
$r1 = & $py -X utf8 $KT2 rename agent zappy zippy 2>&1 | Out-String
$okRen = (Test-Path (Join-Path $kc 'agents/zippy.md')) -and -not (Test-Path (Join-Path $kc 'agents/zappy.md')) -and (& $mf).renamed.zappy -eq 'zippy' -and
  (Get-Content $tpl -Raw) -match 'see last-zippys and zippy-stamp' -and
  (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -match '`zippy` agent' -and (Test-Path (Join-Path $kc '.codex/agents/zippy.toml')) -and -not (Test-Path (Join-Path $kc '.codex/agents/zappy.toml'))
$x1 = & $py -X utf8 $KT2 remove agent zippy 2>&1 | Out-String
$okRem = -not (Test-Path (Join-Path $kc 'agents/zippy.md')) -and -not (& $mf).agents.zippy -and (Get-Content (Join-Path $kc 'AGENTS.md') -Raw) -notmatch 'zippy'
$klj = Join-Path $kc 'skills/dev-kit/kit.local.json'; '{ "net": { "timeoutSec": 5 } }' | Set-Content $klj -Encoding utf8
$null = & $py -X utf8 $KT2 rename event E14 E15 2>&1; $rnw = & $py -X utf8 $KT2 rename config-key net.timeoutSec net.waitSec 2>&1 | Out-String
$null = & $py -X utf8 $KT2 new adr Budget per agent 2>&1
$sk = Get-Content (Join-Path $kc 'skills/orchestrate/SKILL.md') -Raw
$okId = $rnw -match 'WARN nested read\? skills/local-env/localenv\.ps1' -and (& $mf).events -contains 'E15' -and -not ((& $mf).events -contains 'E14') -and $sk -match '\|\s*E15\s*\|' -and $sk -notmatch '\bE14\b' -and
  (Get-Content (Join-Path $kc 'skills/dev-kit/kit.example.json') -Raw | ConvertFrom-Json).net.waitSec -eq 60 -and (Get-Content $klj -Raw | ConvertFrom-Json).net.waitSec -eq 5 -and
  -not (git -C $kc grep -l 'net\.timeoutSec' -- . ':!.codex' ':!.agents') -and (Get-Content (Join-Path $kc 'LESSONS.md') -Raw) -match '## Decisions\r?\n(?:.*\r?\n)*- \d{4}-\d\d-\d\d Budget per agent: context TODO\(new\)'
Expect "kittool rename event + config-key, new adr ($okId)" $okId
$wfp = Join-Path $kc 'workflows/tidy.js'; Add-Content $wfp "`nawait agent('x', { label: 'gp' })" -Encoding utf8; Add-Content (Join-Path $kc 'README.md') "`nsee $oldWf" -Encoding utf8; Add-Content (Join-Path $kc 'skills/dev-kit/templates.md') "`nsee last-${oldSk}s" -Encoding utf8
$l2 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
$rel = & $py -X utf8 $KT2 release 2>&1 | Out-String
Expect "kittool new / rename / remove (new $okNew, rename $okRen, remove $okRem)" ($okNew -and $okRen -and $okRem)
Expect 'kittool lint: AGENT-TYPE, OLD-NAME (also last-<old>s); release: SemVer tag' ($l2 -match 'AGENT-TYPE\s+workflows/tidy\.js' -and $l2 -match "OLD-NAME\s+README\.md.*$oldWf" -and $l2 -match "OLD-NAME\s+skills/dev-kit/templates\.md.*$oldSk" -and $rel -match '^# v\d+\.\d+\.\d+')
$bj = Join-Path $kc 'skills/dev-kit/kit.example.json'; $bt = { & $py -X utf8 $KT2 budget raise -Reason x 2>&1 | Out-String }
$capTo = { param($v) foreach ($p in $bj, $KT2) { (Get-Content $p -Raw) -replace '(totalTokens[''"]:\s*)\d+', "`${1}$v" | Set-Content $p -NoNewline }; git -C $kc commit -qam cap }
& $capTo 480000; $b1 = & $bt; $c1 = $LASTEXITCODE   # a cap step above any kit size: refused
& $capTo 360000
$b2 = & $bt; $c2 = (Get-Content $bj -Raw) -match '"totalTokens": 396000'
(Get-Content $bj -Raw) -replace '"totalTokens": \d+', '"totalTokens": 999000' | Set-Content $bj -NoNewline; $l3 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
Expect 'budget raise: refused under the cap, x1.1 over it; a manual cap edit = BUDGET-CAP' ($c1 -eq 1 -and $b1 -match 'fits the cap' -and $b2 -match '360000 -> 396000' -and $c2 -and $l3 -match 'BUDGET-CAP')
Remove-Item (Split-Path $kc) -Recurse -Force -ErrorAction SilentlyContinue
# kit-flow: loop words in strings / comments / one-liners are no loops; unbounded ones are (kittool.py 2b)
$fx = @'
import re, sys, types, collections
sys.path.insert(0, sys.argv[1])
import kittool
T = {'fp.ps1': '''function Active { All | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $staleMin } }
function Hint { "== heartbeat: arm ONE: CronCreate (cron */10 * * * *), prompt: run supervise and retry when stale" }
function Keep($x, $rm) { $x.m = @(@($x.m) | Where-Object { $p = "$_" -split '>', 2; $p[0] -notin $rm }) }
function Label { $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }; $v }
function Bounded { for ($i = 0; $i -lt 3; $i++) { Start-Sleep 1 }; foreach ($x in @(1, 2)) { $x }; while ((Get-Date) -lt $end) { Start-Sleep 5 } }
''', 'fp.py': 'def port():\n    print("kittool port: GEMINI.md stale or missing; retry later")\n',
     'fp.mjs': 'export function login(page, L) {\n  if (!page.url().includes(L.path)) {   // logged in as someone else: clear and retry\n    return 1\n  }\n}\n',
     'real.ps1': 'function Poll($f) {\n  while ($true) { Start-Sleep 5; if (Test-Path $f) { break } }\n}\n',
     'real.mjs': 'export async function waitDone(poll) {\n  let done = false\n  while (!done) { done = await poll() }\n}\n',
     'marked.ps1': 'function Watch($f) {\n  while ($true) { Start-Sleep 5 }   # flow: unbounded on purpose - watch until Ctrl+C\n}\n'}
k = types.SimpleNamespace(files=list(T), texts=T, dir=sys.argv[2], skills=[], agents={}, workflows={})
d = kittool.model(k, [])
c = collections.Counter(m.group(0) for i in d['issues'] for m in [re.search(r'(fp|real|marked)\.\w+', i['text'])] if m)
print(' '.join(f'{f}={c.get(f, 0)}' for f in T), 'deliberate=' + str(sum(1 for i in d['deliberate'] if 'marked.ps1' in i['text'])))
'@
$fxf = Join-Path ([IO.Path]::GetTempPath()) "kit-flow-fixture-$PID.py"; Set-Content $fxf $fx -Encoding utf8
$res = "$(& $py -X utf8 $fxf (Join-Path $src 'skills/orchestrate') ([IO.Path]::GetTempPath()) 2>&1)"
Expect "kit-flow: no false loop issues ($res)" ($res -match 'fp\.ps1=0 fp\.py=0 fp\.mjs=0')
Expect 'kit-flow: real unbounded loops flagged once each' ($res -match 'real\.ps1=1 real\.mjs=1')
Expect 'kit-flow: a loop marked `flow: <reason>` is listed as deliberate, not counted' ($res -match 'marked\.ps1=0' -and $res -match 'deliberate=1')
Remove-TestKit $k
Complete-Tests
