#Requires -Version 7
<#
kittool.tests.ps1: kittool.py prose, lint, extras, budget; kit-wide script checks (port, cost, release: their extras' tests).
Usage: pwsh -NoProfile -File <kit>/tests/kittool.tests.ps1 (or tests/kit-tests.ps1 -Area kittool).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit kittool
# sweeps over every kit .ps1: a keyword / unknown Verb-Noun run as a command ((if ...) without $); a helper nested in one
# function, called outside it (Update-BoardEntry in Invoke-Board)
$FD = [Management.Automation.Language.FunctionDefinitionAst]; $Up = { param($n) $p = $n.Parent; while ($p -and $p -isnot $FD) { $p = $p.Parent }; $p }
$asts = @(git -C $src ls-files '*.ps1' ':!tests' | ForEach-Object { , @($_, [Management.Automation.Language.Parser]::ParseFile((Join-Path $src $_), [ref]$null, [ref]$null)) })
$defs = @{}; foreach ($x in $asts) { foreach ($d in $x[1].FindAll({ $args[0] -is $FD }, $true)) { if (-not $defs.ContainsKey($d.Name)) { $defs[$d.Name] = [Collections.ArrayList]::new() }; $pa = & $Up $d; $null = $defs[$d.Name].Add($(if ($pa) { $pa } else { 'top' })) } }
$bad = foreach ($x in $asts) { foreach ($c in $x[1].FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) { $n = $c.GetCommandName(); if (-not $n) { continue }
  if ($n -in 'if', 'foreach', 'switch', 'while', 'for', 'do', 'try' -or ($n -match '^[A-Z][a-z]+-[A-Z]\w+$' -and -not $defs[$n] -and -not (Get-Command $n -CommandType Cmdlet, Function, Alias -ErrorAction SilentlyContinue))) { "$($x[0]):$($c.Extent.StartLineNumber) $n" }
  elseif ($defs[$n] -and 'top' -notin $defs[$n]) { $p = $c; $ok = $false; while ($p = & $Up $p) { if ($defs[$n] -contains $p) { $ok = $true; break } }; if (-not $ok) { "$($x[0]):$($c.Extent.StartLineNumber) $n outside its function" } } } }
Expect "static: no keyword / unknown command, no nested helper called outside its function ($($bad -join ', '))" (-not $bad)
$hx = foreach ($sc in 'skills/dev-kit/dev.ps1', 'skills/qa-kit/qa.ps1') { $null = Px (Join-Path $src $sc) --help 2>&1; "$LASTEXITCODE" }
Expect "dev.ps1 / qa.ps1 --help exit 0 ($($hx -join ','))" (($hx -join ',') -eq '0,0')
$out = "Merge branch 'feature/long-branch-name-for-testing' into deploy/staging-longer-name" | python -X utf8 (Join-Path $src 'skills/orchestrate/kittool.py') prose --kind merge-commit - | Out-String
Expect 'prose: merge-commit kind (no conv, no 72-char subject)' ($LASTEXITCODE -eq 0)
$KT = Join-Path $src 'skills/orchestrate/kittool.py'; $pf = Join-Path $k 'mr.md'
function KtPy($code) { python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kittool as k; $code" }   # kittool internals
"## Summary`nhttps://t.example.com/T-1 — keep the offset`n## Changes`n- ISO dates`n## How tested`n- tests ``ExportTest```n## Risks`n- none`n## Links`n- doc" | Set-Content $pf
$null = python -X utf8 $KT prose --kind mr-body $pf; Expect 'prose: a template-shaped MR body passes' ($LASTEXITCODE -eq 0)
"Hi, I hope this is basically fine`n## Changes`n- a`n- b`n- c`n- d" | Set-Content $pf
$out = python -X utf8 $KT prose --kind mr-body $pf | Out-String
Expect 'prose: filler, missing sections, a 4th bullet are findings' ($LASTEXITCODE -eq 1 -and $out -match 'filler: "basically"' -and $out -match 'missing sections' -and $out -match '4 bullets')
$out = 'updated stuff' | python -X utf8 $KT prose --kind commit - | Out-String
Expect 'prose: a non-conventional commit subject is a finding' ($LASTEXITCODE -eq 1 -and $out -match 'conv')
$wc = KtPy "k.load_json = lambda p: ({'commitStyle': 'free'}, 0); print(k.words('日本 wörd ok'), k.commit_rx())"
Expect 'prose: CJK per char, any script''s words; commitStyle free' ("$wc" -eq '4 \S')
$yq = KtPy "print(len(k.yaml_problems('steps:\n  - name: Lint: x\n')) > 0, k.yaml_problems('steps:\n  - name: \'Lint: x\'\n  - run: |\n      a: b\n'), k.old_name_rx('qa-kit').search('see skills/qa-kit/qa.ps1') is not None)"
Expect 'lint YAML: an unquoted ": " in a workflow fails, quoted / block scalars pass; old names after a /' ("$yq" -eq 'True [] True')
$pc = KtPy "print(k.ps_case('function A {\n  `$s = \'{\'\n  `$o = 1\n}\nfunction B {\n  `$O = 2\n}\n'), k.ps_case('function A {\n  `$o = 1\n  if (`$x) { `$O = 2 }\n}\n'))"
Expect "PS-CASE: per function, a brace in a string ignored ($pc)" ("$pc" -eq "[] [(3, 'O', 'o', 2)]")
$mp = Join-Path $k 'mermaid.py'; @'
import sys, re; sys.path.insert(0, sys.argv[1]); import kittool as t
k = t.load(sys.argv[2]); k.index['dev-kit'] = [(1, 'step 0 (orch.ps1 learn -Read -Skill dev-kit)', ['LESSONS.md']), (2, 'say "q" a|b <x> #1; ' + 'word ' * 20, ['LESSONS.md'])]
sec = t.readme_sections(k, t.graph(k)); q = r'"[^"]*"'
node = re.compile(r'\w+(?:\[' + q + r'\]|\(' + q + r'\)|\(\[' + q + r'\]\)|\[/' + q + r'/\]|\{' + q + r'\})?$')
bad = [l for n, ls in sec.items() if not n.startswith('table-') for l in ls[1:] if not all(node.match(x.strip()) for x in re.split(r'-->(?:\|' + q + r'\|)?', l))]
print(len(bad), *sec['skill-dev-kit'][2:4], sep='\n')
'@ | Set-Content $mp -Encoding utf8
$mo = @(python -X utf8 $mp (Split-Path $KT) $src)   # GitHub: an unquoted ( ) ; in |label| = "Parse error ... got 'PS'"
Expect "README graphs: every Mermaid label and node text quoted + escaped, cut at a word ($($mo -join ' / '))" ($mo[0] -eq '0' -and $mo[1] -like '*-->|"step 0 (orch.ps1 learn -Read -Skill dev-kit)"| LESSONS_md*' -and $mo[2] -like '*-->|"say #quot;q#quot; a#124;b #lt;x#gt; #35;1; word word word*…"|*')
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
# a linked worktree reads localOnly from the main clone; a non-repo folder is its own main clone
ok_main = kt.main_clone(str(tmp)) == str(tmp)
# lint measures PROSE against the linted kit's templates.md (k.dir), not the script's kit
src = open(sys.argv[1], encoding='utf-8').read()
ok_prose = 'writing_standards(k.dir)' in src and 'writing_standards(KIT)' not in src
print(f'kittool-misc:{ok_main and ok_prose}')
'@
$kf = Join-Path ([IO.Path]::GetTempPath()) "kt-test-$PID.py"; Set-Content $kf $ktt -Encoding utf8
$res = @(& $py -X utf8 $kf (Join-Path $src 'skills/orchestrate/kittool.py') 2>&1); Remove-Item $kf -Force
Expect-Each $res 'kittool: #' 'kittool-misc'
# a throw-away git copy of the kit with a local origin: extras, lint codes, budget
$kc = New-GitKitCopy (Join-Path ([IO.Path]::GetTempPath()) "kit-reg-$PID"); $KT2 = Join-Path $kc 'skills/orchestrate/kittool.py'; $og = Join-Path (Split-Path $kc) 'origin.git'
$xw = Join-Path (Split-Path $kc) 'xw'; git init -q -b extras $xw
$xd = Join-Path $xw 'extras/demo'; New-Item -ItemType Directory -Force "$xd/files/skills/orchestrate" | Out-Null
"# demo`n`nA demo command.`nNeeded when: ``tracker.type`` = ``demo```n" | Set-Content "$xd/EXTRA.md"
"COMMANDS = {'demo': lambda a: print('demo ran') or 0}`nARGS = {'demo': (set(), set(), False)}`n" | Set-Content "$xd/files/skills/orchestrate/kittool_demo.py"
$pushX = { param($m) Save-GitRepo $xw $m; git -C $xw push -q $og extras 2>&1 | Out-Null }   # commit all, push the extras branch
& $pushX 'feat: demo extra'
$ex = { $o = & $py -X utf8 $KT2 @args 2>&1 | Out-String; [pscustomobject]@{ out = $o; code = $LASTEXITCODE } }
'{ "tracker": { "type": "demo" } }' | Set-Content (Join-Path $kc 'skills/dev-kit/kit.local.json')
$demo = Join-Path $kc 'skills/orchestrate/kittool_demo.py'
Expect-Cases @(
  , @('extra: a command of a missing extra = exit 2 + one "extra add" line', { & $ex flow $kc }, { param($r) $r.code -eq 2 -and $r.out.Trim() -eq 'kittool.py flow is an extra: run kittool.py extra add flow-map' })
  , @('extra list: names from origin/extras', { & $ex extra list }, { param($r) $r.code -eq 0 -and $r.out -match '(?m)^  demo\s+A demo command' })
  , @('extra check: config asks for a missing extra', { & $ex extra check }, { param($r) $r.code -eq 1 -and $r.out -match 'tracker\.type "demo" is an extra: run kittool\.py extra add demo' })
  , @('extra add: files written, local-only (git status clean), command loaded', { & $ex extra add demo; & $ex demo },
      { param($r) $r.out.Trim() -eq 'demo ran' -and (Test-Path $demo) -and -not (git -C $kc status --porcelain) })
  , @('extra add: lint skips it, list marks it, check is satisfied', { (& $ex lint --no-flow).out + (& $ex extra list).out + (& $ex extra check).code },
      { param($r) $r -notmatch 'kittool_demo' -and $r -match '(?m)^\* demo' -and $r -match '0$' })
  , @('extra add: never overwrites a file it did not install', { $null = & $ex extra remove demo; '# mine' | Set-Content $demo; & $ex extra add demo },
      { param($r) $r.code -eq 1 -and $r.out -match 'refused' -and (Get-Content $demo -Raw) -match 'mine' })
  , @('extra remove: files and the exclude block go, user lines stay', { Remove-Item $demo; $null = & $ex extra add demo; & $ex extra remove demo },
      { param($r) $exc = Get-Content (git -C $kc rev-parse --path-format=absolute --git-path info/exclude) -Raw
        $r.code -eq 0 -and -not (Test-Path $demo) -and $exc -notmatch 'kittool extra' -and $exc -match '(?m)^# ' })
)
# extra sync: config in kit.local.json or another local file, an existing kit file; a changed branch file updates
foreach ($x in @(@('duo', 'Needed when (targets.local.json, checked by qa.ps1): `targets.*.auth.type` = `basic` | `token`'), @('own', 'Needed when: `.githooks/pre-commit` exists'), @('never', 'Needed when: you want the page (`flow --readme` stays core).'))) {
  New-Item -ItemType Directory -Force "$xw/extras/$($x[0])/files/notes" | Out-Null; "# $($x[0])`n`n$($x[1])" | Set-Content "$xw/extras/$($x[0])/EXTRA.md"; "$($x[0])" | Set-Content "$xw/extras/$($x[0])/files/notes/$($x[0]).txt"
}
New-Item -ItemType Directory -Force "$xw/extras/duo/files/notes/__pycache__" | Out-Null; 'x' | Set-Content "$xw/extras/duo/files/notes/__pycache__/d.pyc"   # a stray build file is never installed or compared
git -C $xw add -A -f; & $pushX 'feat: duo, own, never'
'{ "targets": { "t1": { "auth": { "type": "token" } } } }' | Set-Content (Join-Path $kc 'skills/qa-kit/targets.local.json'); git -C $kc push -q origin main 2>&1 | Out-Null; git -C $kc fetch -q origin
$s1 = & $ex extra sync; $s2 = & $ex extra sync
"x = 1" | Add-Content "$xd/files/skills/orchestrate/kittool_demo.py"; & $pushX 'fix: demo'
$s3 = & $ex extra sync
Expect 'extra sync: installs what config or the kit needs, one line each; then silent; a branch change updates it' ($s1.code -eq 0 -and @($s1.out.Trim() -split "`n").Count -eq 3 -and $s1.out -match 'extra duo: installed' -and $s1.out -match 'extra own: installed' -and -not $s2.out.Trim() -and $s3.out.Trim() -match '^extra demo: updated 1 file' -and (Get-Content $demo -Raw) -match 'x = 1' -and -not (git -C $kc status --porcelain))
# an extra whose old version listed other files (exclude block) updates, not refused; two syncs at once never collide
$xf = git -C $kc rev-parse --path-format=absolute --git-path info/exclude
(Get-Content $xf -Raw) -replace '(?m)^/notes/own\.txt\r?$', "/notes/own.txt`n/notes/own-old.txt" | Set-Content $xf -NoNewline
'own v2' | Set-Content "$xw/extras/own/files/notes/own.txt"; & $pushX 'fix: own'
Remove-Item (Join-Path $kc 'notes/duo.txt')
$jobs = 1..2 | ForEach-Object { Start-Job -ArgumentList $py, $KT2 { param($py, $kt) & $py -X utf8 $kt extra sync 2>&1 | Out-String } }
$both = (Receive-Job $jobs -Wait -AutoRemoveJob) -join "`n"
Expect "extra sync: its own old file list is updated, not refused; two syncs at once never collide ($($both.Trim() -replace '\s+', ' '))" ($both -notmatch 'refused' -and (Get-Content (Join-Path $kc 'notes/own.txt') -Raw) -match 'own v2' -and (Test-Path (Join-Path $kc 'notes/duo.txt')))
$kl = Join-Path $kc 'skills/dev-kit/kit.local.json'; $a1 = & $ex extra add never; $l1 = (Read-Json $kl).extras
Remove-Item (Join-Path $kc 'notes/never.txt'); $s4 = & $ex extra sync; $null = & $ex extra remove never; $l2 = (Read-Json $kl).extras
Expect 'extra add lists it in kit.local.json extras (a fresh clone''s sync reinstalls it), remove unlists it; a prose need never installs' ($a1.code -eq 0 -and 'never' -in $l1 -and $s4.out -match 'extra never: installed' -and 'never' -notin $l2 -and $s1.out -notmatch 'extra never')
# extra sync, a real-like config (tracker clickup, gdocs reports, liquibase db commands, a node web service) -> exactly those
# four (decoys: another tracker and report type, a listed-only extra)
$needs = [ordered]@{ 'tracker-clickup' = 'Needed when: `tracker.type` = `clickup`'; 'tracker-jira' = 'Needed when: `tracker.type` = `jira` | `jira-server`'
  'report-gdocs' = 'Needed when: `reports.type` = `gdocs` (unset with gws on PATH also means gdocs: set reports.type or add the extra)'; 'report-pdf' = 'Needed when: `reports.type` = `pdf`'
  'liquibase' = 'Needed when: `localEnv.envs.*.db.applied` ~ `liquibase`, `localEnv.envs.*.db.rollback` ~ `liquibase`, or listed in kit.local.json `extras`'
  'node-spec' = 'Needed when: `localEnv.envs.*.services.*.start` ~ `ng serve` | `npm` | `yarn` | `pnpm`, or listed in kit.local.json `extras`'
  'module-audit' = 'Needed when: listed in kit.local.json extras (extra add does it)'
  'ts-typecheck' = 'Needed when: `tsconfig.json` in a repo'; 'cargo-x' = 'Needed when: `Cargo.toml` in a repo'
  'os-here' = 'Needed when: `windows` OS, `linux` OS, `macos` OS'; 'os-none' = 'Needed when: `beos` OS' }
$wr = Join-Path (Kd) 'web repo'; New-Item -ItemType Directory -Force "$wr/app" | Out-Null; '{}' | Set-Content "$wr/app/tsconfig.json"; git -C $wr init -q; git -C $wr add -A
foreach ($n in $needs.Keys) { New-Item -ItemType Directory -Force "$xw/extras/$n/files/notes" | Out-Null; "# $n`n`n$($needs[$n])" | Set-Content "$xw/extras/$n/EXTRA.md"; $n | Set-Content "$xw/extras/$n/files/notes/$n.txt" }
& $pushX 'feat: real-like extras'
& $J @{ tracker = @{ type = 'clickup' }; reports = @{ type = 'gdocs' }; localEnv = @{ envs = @{ e1 = @{ db = @{ applied = 'mvn liquibase:status'; rollback = 'mvn liquibase:rollback' }
  services = @(@{ name = 'api'; start = 'java -jar api.jar' }, @{ name = 'web'; start = 'yarn ng serve --port 4200' }) } } }; repos = @(@{ name = 'web'; checkout = $wr }) } $kl
$s5 = & $ex extra sync; $got = @([regex]::Matches($s5.out, '(?m)^extra (\S+): installed') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
Expect "extra sync: a real-like config installs exactly tracker-clickup, report-gdocs, liquibase, node-spec, ts-typecheck (a repo file), os-here (this OS) ($($got -join ','))" ($s5.code -eq 0 -and ($got -join ',') -eq 'liquibase,node-spec,os-here,report-gdocs,tracker-clickup,ts-typecheck')
# lint codes on the copy
$oldWf = 'dev' + '-wave'; $oldSk = 'tech' + '-audit'   # built: no old name in the kit (lint OLD-NAME)
Add-Content (Join-Path $kc 'workflows/tidy.js') "`nawait agent('x', { label: 'gp' })`nappendFileSync('a.jsonl', x)" -Encoding utf8; Add-Content (Join-Path $kc 'README.md') "`nsee $oldWf" -Encoding utf8
Add-Content (Join-Path $kc 'skills/dev-kit/templates.md') "`nsee last-${oldSk}s" -Encoding utf8
Add-Content (Join-Path $kc 'README.md') '', 'run `skills/gone/x.ps1` (extra `demo`)', 'run `skills/gone/y.ps1`', 'see extra `nope`' -Encoding utf8   # a path an extra brings: cited with its extra
$l2 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
Expect 'kittool lint: AGENT-TYPE, LOG-DIRECT, OLD-NAME (also last-<old>s), REF-DANGLING unless the line names a real extra' ($l2 -match 'AGENT-TYPE\s+workflows/tidy\.js' -and $l2 -match 'LOG-DIRECT\s+workflows/tidy\.js:\d+' -and $l2 -match "OLD-NAME\s+README\.md.*$oldWf" -and $l2 -match "OLD-NAME\s+skills/dev-kit/templates\.md.*$oldSk" -and
  $l2 -match 'REF-DANGLING\s+README\.md: skills/gone/y\.ps1' -and $l2 -notmatch 'gone/x\.ps1' -and $l2 -match 'REF-DANGLING\s+README\.md: extra .nope.: no such extra')
# extras' section maps: lint checks installed files; extra test the branch's, with or without a tests.ps1
('# x' + "`n") * 3000 | Add-Content $demo; New-Item -ItemType Directory -Force "$xw/extras/big/files/skills" | Out-Null; '# big' | Set-Content "$xw/extras/big/EXTRA.md"
('# x' + "`n") * 3000 | Set-Content "$xw/extras/big/files/skills/big.ps1"; & $pushX 'feat: big'
$l5 = (& $ex lint --no-flow).out; $null = & $ex extra list; $t5 = & $ex extra test big   # list fetches the branch
Expect 'sections: lint flags an installed extra''s file (fix on the extras branch); extra test flags the branch''s files; an unknown extra = exit 2' ($l5 -match 'SECTION-MAP\s+skills/orchestrate/kittool_demo\.py: no section markers.*\(extra demo: fix it on the extras branch\)' -and $t5.code -eq 1 -and $t5.out -match 'FAIL SECTION-MAP skills/big\.ps1' -and (& $ex extra test nope).code -eq 2)
# budget raise is in kit-admin (its tests); a manual cap edit is lint BUDGET-CAP
$bj = Join-Path $kc 'skills/dev-kit/kit.example.json'; $b1 = & $py -X utf8 $KT2 budget raise -Reason x 2>&1 | Out-String; $c1 = $LASTEXITCODE
(Get-Content $bj -Raw) -replace '"totalTokens": \d+', '"totalTokens": 999000' | Set-Content $bj -NoNewline; $l3 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
Expect 'budget raise without kit-admin: exit 2 + the extra line; a manual cap edit = BUDGET-CAP' ($c1 -eq 2 -and $b1 -match 'extra add kit-admin' -and $l3 -match 'BUDGET-CAP')
# tests/ stay outside the kit total (agents never load them), under their own cap testTokens
$rb = 'kit total (\d+) of cap \d+ \(\d+%\) . tests (\d+) of cap 33000'; $b2 = & $py -X utf8 $KT2 budget 2>&1 | Out-String
Set-Content (Join-Path $kc 'tests/zz.tests.ps1') ('#' * 140000) -NoNewline; git -C $kc add tests/zz.tests.ps1
$b3 = & $py -X utf8 $KT2 budget 2>&1 | Out-String; $l4 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
$m2 = [regex]::Match($b2, $rb); $m3 = [regex]::Match($b3, $rb)
Expect "budget: +35000 test tokens add to tests, not the kit total; over testTokens = BUDGET-TESTS, a file over 8000 = BUDGET ($($b3.Trim()))" ($m2.Success -and $m3.Success -and
  $m2.Groups[1].Value -eq $m3.Groups[1].Value -and [int]$m3.Groups[2].Value - [int]$m2.Groups[2].Value -eq 35000 -and $l4 -match 'BUDGET-TESTS\s+tests: \d+ tokens \(cap 33000\)' -and $l4 -match 'zz\.tests\.ps1: 35000 tokens \(cap 8000\)')
Remove-Item (Split-Path $kc) -Recurse -Force -ErrorAction SilentlyContinue
# section maps: lint SECTION-MAP / SECTION-UNMAPPED, audit SECTION-BIG, sections --fix
$sp = Join-Path $k 'sec.py'; @'
import sys; sys.path.insert(0, sys.argv[1]); import kittool as t
ps = "<#\nSections: L9 old\n#>\n\n# ---- a: one\nfunction A { }\n\n\n# ---- b: two\nswitch ($__verb) {\n  'go' { Invoke-KitVerb A $r }\n  'no' { Write-Host x }\n  'ex' { Assert-KitExtra X }\n}\n"
p, fx = t.sec_check('x.ps1', ps)
lg = '"""\nSections:\n"""\n' + ''.join(f'# ---- section-name-{n}: x\n' for n in range(15))
lf = t.sec_check('y.py', lg)[1]
print(sorted({c for c, _, _ in p}), fx.split('\n')[1], [w for _, w, _ in t.sec_check('x.ps1', fx)[0]], len(lf.split('\n')) - len(lg.split('\n')),
  t.sec_check('y.py', lf)[0], [w for _, w, _ in t.sec_check('z.py', '"""\nSections: L5 a\n"""\ndef f(): pass\n# ---- a: x\n')[0]],
  t.sec_check('w.py', 'x = 1\n' * 2000)[0][0][2][:19], [x[:2] for x in t.sec_sizes('v.py', '# ---- a: x\n' + 'y\n' * 700)],
  [w for _, w, _ in t.sec_check('u.ps1', fx.replace("'no' { Write-Host x }", "'no' { Write-Host x }\r").replace('Assert-KitExtra X', 'Write-Host y') + 'function Late { }\n')[0]],
  t.sec_check('d.ps1', '<#\r\nSections: L5 a\r\n#>\n\r\n# ---- a: x\r\n# ---- a: y\n')[0][0][2][:24])
'@ | Set-Content $sp; $r = (& $py -X utf8 $sp (Split-Path $KT) | Out-String).Trim()
Expect "sections: map from markers (wrapped), function / verb outside a section, no markers, big section, mixed endings, repeated name ($r)" ($r -eq "['SECTION-MAP', 'SECTION-UNMAPPED'] Sections: L5 a · L9 b ['x.ps1:12'] 2 [] ['z.py:4'] no section markers: [(1, 'a')] ['u.ps1:12', 'u.ps1:13'] section name ""a"" repeats")
$sf = Join-Path $k 'sec.ps1'; [IO.File]::WriteAllText($sf, "<#`r`nSections: L4 a`r`n#>`r`n`r`n# ---- a: x`r`n")
$null = & $py -X utf8 $KT sections $sf (Join-Path $k 'none.ps1') 2>$null; $c1 = $LASTEXITCODE; $null = & $py -X utf8 $KT sections --fix $sf
Expect 'sections: a shifted map or a missing file exits 1; --fix rewrites only the map, keeps CRLF' ($c1 -eq 1 -and $LASTEXITCODE -eq 0 -and [IO.File]::ReadAllText($sf) -eq "<#`r`nSections: L5 a`r`n#>`r`n`r`n# ---- a: x`r`n")
$td = Join-Path (Kd) 'dup/tests'; New-Item -ItemType Directory -Force $td | Out-Null; Copy-Item (Join-Path $src 'tests/kit-tests.ps1') $td
foreach ($a in 'orch', 'devkit') { "$(if ($a -eq 'orch') { 'Start-Sleep 2; ' })'PASS same  Case'; 'PASS own $a'; 'FAIL x'; ""py `$((Get-Command python).Source -notmatch '\.(bat|cmd)`$')""; '1 failure(s)'" | Set-Content "$td/$a.tests.ps1" }   # orch ends last
$tdr = Invoke-TestScript "$td/kit-tests.ps1" -Area orch,devkit
Expect 'kit-tests: a case in two areas = TEST-DUP (area order, exit 1); real python, no shim; FAILs recapped by area' ($tdr.code -eq 1 -and $tdr.out -match 'Failed checks:\s+\[orch\] x\s+\[devkit\] x' -and $tdr.out -match 'TEST-DUP same case: orch, devkit' -and $tdr.out -notmatch 'TEST-DUP own' -and $tdr.out -match 'py True' -and $tdr.out -notmatch 'py False')
Remove-TestKit $k
$null = & $py -X utf8 (Join-Path $src 'skills/orchestrate/kittool.py') lint --org-terms (Join-Path (Kd) 'no-such.json') 2>&1
Expect 'lint --org-terms: a missing .json is a usage error (2), never a term' ($LASTEXITCODE -eq 2)
$pg = [IO.File]::ReadAllText((Join-Path $src '.github/workflows/pages.yml')); $ia = $pg.IndexOf('extra add flow-map'); $il = $pg.IndexOf('kittool.py lint')
Expect 'pages.yml: lint runs the flow checks (flow-map added first, no --no-flow), so an issue the page would show fails CI' ($ia -ge 0 -and $il -gt $ia -and $pg -notmatch '--no-flow')
Complete-Tests
