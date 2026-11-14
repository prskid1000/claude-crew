#Requires -Version 7
<#
kitbag.tests.ps1: kitbag.py prose, lint, budget; kit-wide script checks (port, cost, release: ports / kit-admin tests).
Usage: pwsh -NoProfile -File <kit>/tests/kitbag.tests.ps1 (or tests/kit-tests.ps1 -Area kitbag).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit kitbag
# sweeps over every kit .ps1: a keyword / unknown Verb-Noun run as a command ((if ...) without $); a helper nested in one
# function, called outside it (Update-BoardEntry in Invoke-Board; adapters' hooks and envy.ps1's top-level helpers use their verb's helpers)
$FD = [Management.Automation.Language.FunctionDefinitionAst]; $Up = { param($n) $p = $n.Parent; while ($p -and $p -isnot $FD) { $p = $p.Parent }; $p }
$asts = @(git -C $src ls-files '*.ps1' ':!tests' | ForEach-Object { , @($_, [Management.Automation.Language.Parser]::ParseFile((Join-Path $src $_), [ref]$null, [ref]$null)) })
$defs = @{}; foreach ($x in $asts) { foreach ($d in $x[1].FindAll({ $args[0] -is $FD }, $true)) { if (-not $defs.ContainsKey($d.Name)) { $defs[$d.Name] = [Collections.ArrayList]::new() }; $pa = & $Up $d; $null = $defs[$d.Name].Add($(if ($pa) { $pa } else { 'top' })) } }
$bad = foreach ($x in $asts) { foreach ($c in $x[1].FindAll({ $args[0] -is [Management.Automation.Language.CommandAst] }, $true)) { $n = $c.GetCommandName(); if (-not $n) { continue }
  if ($n -in 'if', 'foreach', 'switch', 'while', 'for', 'do', 'try' -or ($n -match '^[A-Z][a-z]+-[A-Z]\w+$' -and -not $defs[$n] -and -not (Get-Command $n -CommandType Cmdlet, Function, Alias -ErrorAction SilentlyContinue))) { "$($x[0]):$($c.Extent.StartLineNumber) $n" }
  elseif ($defs[$n] -and 'top' -notin $defs[$n] -and $x[0] -notmatch '/adapters/|/envy/envy\.ps1') { $p = $c; $ok = $false; while ($p = & $Up $p) { if ($defs[$n] -contains $p) { $ok = $true; break } }; if (-not $ok) { "$($x[0]):$($c.Extent.StartLineNumber) $n outside its function" } } } }
Expect "static: no keyword / unknown command, no nested helper called outside its function ($($bad -join ', '))" (-not $bad)
$hx = foreach ($sc in 'skills/crafty/crafty.ps1', 'skills/pokey/pokey.ps1') { $null = Px (Join-Path $src $sc) --help 2>&1; "$LASTEXITCODE" }
Expect "crafty.ps1 / pokey.ps1 --help exit 0 ($($hx -join ','))" (($hx -join ',') -eq '0,0')
$out = "Merge branch 'feature/long-branch-name-for-testing' into deploy/staging-longer-name" | python -X utf8 (Join-Path $src 'skills/bossy/kitbag.py') prose --kind merge-commit - | Out-String
Expect 'prose: merge-commit kind (no conv, no 72-char subject)' ($LASTEXITCODE -eq 0)
$KT = Join-Path $src 'skills/bossy/kitbag.py'; $pf = Join-Path $k 'mr.md'
function KtPy($code) { python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kitbag as k; $code" }   # kitbag internals
"## Summary`nhttps://t.example.com/T-1 — keep the offset`n## Changes`n- ISO dates`n## How tested`n- tests ``ExportTest```n## Risks`n- none`n## Links`n- doc" | Set-Content $pf
$null = python -X utf8 $KT prose --kind mr-body $pf; Expect 'prose: a template-shaped MR body passes' ($LASTEXITCODE -eq 0)
"# Lead notes: r1`n**Result:** 2 in, 1 left out · target ``local```n`n## Prerequisites`n`n| Item | Flags / accounts / data ids | State |`n|---|---|---|`n| P1 | flag ``x`` ON | ready |" | Set-Content $pf
$tj = Get-Content (Join-Path $src 'workflows/tidy.js') -Raw
Expect 'retro + lead notes: tidy renders the retro (devtools.py render retro), checky names the lead-notes headings; a lead-notes sample passes' ($tj -match 'devtools\.py render retro' -and
  (Get-Content (Join-Path $src 'agents/checky.md') -Raw) -match '(?s)# Lead notes: .*## Prerequisites' -and (Test-Prose kit-report $pf))
"Hi, I hope this is basically fine, merged successfully`n## Changes`n- a`n- b`n- c`n- d" | Set-Content $pf
$out = python -X utf8 $KT prose --kind mr-body $pf | Out-String
Expect 'prose: filler (the whole banned list), missing sections, a 4th bullet are findings' ($LASTEXITCODE -eq 1 -and $out -match 'filler: "basically"' -and $out -match '"I hope"' -and $out -match '"successfully"' -and $out -match 'missing sections' -and $out -match '4 bullets')
$rd = Get-Content (Join-Path $src 'README.md') -Raw; $sec = { param($h) ($rd -split '(?m)^## ' | Where-Object { $_.StartsWith($h) }) -join '' }
Expect 'README keeps what other files cite it for: Install (not ported, Org router rows), Using it (supervise.output)' ((& $sec 'Install') -match 'Not ported' -and (& $sec 'Install') -match 'Org router rows' -and (& $sec 'Using it') -match 'supervise\.output')
$out = KtPy "sys.exit(k.audited('x.py', ['v'], lambda: int('zz')))" 2>&1 | Out-String
Expect "audited: an uncaught error prints one line (script verb: type: why (at file:line)), exit 1 ($LASTEXITCODE)" ($LASTEXITCODE -eq 1 -and $out -match 'x\.py v: ValueError: .*zz.*\(at <string>:1\)' -and $out -notmatch 'Traceback')
$out = KtPy "g = []; k.kitlog = lambda *a: g.append(a[2]); k.audited('x', ['v'], lambda: (print('usage: x\nx: error: no verb', file=sys.stderr), sys.exit(2))); print(g[-1])" 2>&1 | Out-String
Expect 'audited: a usage exit 2 keeps its stderr why in the call line' ($out -match "'error': 'x: error: no verb'")
$out = 'updated stuff' | python -X utf8 $KT prose --kind commit - | Out-String
Expect 'prose: a non-conventional commit subject is a finding' ($LASTEXITCODE -eq 1 -and $out -match 'conv')
$wc = KtPy "k.load_json = lambda p: ({'commitStyle': 'free'}, 0); print(k.words('日本 wörd ok'), k.commit_rx())"
Expect 'prose: CJK per char, any script''s words; commitStyle free' ("$wc" -eq '4 \S')
$um = Join-Path (Split-Path $k) 'unmerged'; $null = git init -q -b main $um; $gu = @('-C', $um, '-c', 'user.name=t', '-c', 'user.email=t@t')
'a' | Set-Content "$um/c.md"; $null = git @gu add -A; $null = git @gu commit -qm a; $null = git @gu checkout -qb side; 'b' | Set-Content "$um/c.md"; $null = git @gu commit -qam b
$null = git @gu checkout -q main; 'c' | Set-Content "$um/c.md"; $null = git @gu commit -qam c; $null = git @gu merge side 2>&1
$tu = KtPy "print(k.tracked(r'$um'), len(k.counted_files(r'$um')))"
Expect "lint file lists: an unmerged file (3 index stages) counts once ($tu)" ("$tu" -eq "['c.md'] 1" -and @(git -C $um ls-files).Count -eq 3)
$kpv = KtPy "import os; a = k.kit_param('uiCheck.timeoutSec'); os.environ['KIT_PARAM_UICHECK_TIMEOUTSEC'] = '5'; print(a, k.kit_param('uiCheck.timeoutSec'))"
Expect "kit_param: the registry default, KIT_PARAM_<KEY> wins ($kpv)" ("$kpv" -eq '600.0 5.0')
$yq = KtPy "print(len(k.yaml_problems('steps:\n  - name: Lint: x\n')) > 0, k.yaml_problems('steps:\n  - name: \'Lint: x\'\n  - run: |\n      a: b\n'), k.old_name_rx('pokey').search('see skills/pokey/pokey.ps1') is not None)"
Expect 'lint YAML: an unquoted ": " in a workflow fails, quoted / block scalars pass; old names after a /' ("$yq" -eq 'True [] True')
$pc = KtPy "print(k.ps_case('function A {\n  `$s = \'{\'\n  `$o = 1\n}\nfunction B {\n  `$O = 2\n}\n'), k.ps_case('function A {\n  `$o = 1\n  if (`$x) { `$O = 2 }\n}\n'))"
Expect "PS-CASE: per function, a brace in a string ignored ($pc)" ("$pc" -eq "[] [(3, 'O', 'o', 2)]")
$mp = Join-Path $k 'mermaid.py'; @'
import sys, re; sys.path.insert(0, sys.argv[1]); import kitbag as t
k = t.load(sys.argv[2]); k.index['crafty'] = [(1, 'step 0 (bossy.ps1 learn -Read -Skill crafty)', ['LESSONS.md']), (2, 'say "q" a|b <x> #1; ' + 'word ' * 20, ['LESSONS.md'])]
sec = t.readme_sections(k, t.graph(k)); q = r'"[^"]*"'
node = re.compile(r'\w+(?:\[' + q + r'\]|\(' + q + r'\)|\(\[' + q + r'\]\)|\[/' + q + r'/\]|\{' + q + r'\})?$')
bad = [l for n, ls in sec.items() if not n.startswith('table-') for l in ls[1:] if not all(node.match(x.strip()) for x in re.split(r'-->(?:\|' + q + r'\|)?', l))]
print(len(bad), *sec['skill-crafty'][2:4], sep='\n')
'@ | Set-Content $mp -Encoding utf8
$mo = @(python -X utf8 $mp (Split-Path $KT) $src)   # GitHub: an unquoted ( ) ; in |label| = "Parse error ... got 'PS'"
Expect "README graphs: every Mermaid label and node text quoted + escaped, cut at a word ($($mo -join ' / '))" ($mo[0] -eq '0' -and $mo[1] -like '*-->|"step 0 (bossy.ps1 learn -Read -Skill crafty)"| LESSONS_md*' -and $mo[2] -like '*-->|"say #quot;q#quot; a#124;b #lt;x#gt; #35;1; word word word*…"|*')
$rj = Join-Path $k 'results.json'; '{"checks":[{"id":"T1","note":"ok"},{"id":"T2","note":"' + ('word ' * 45) + '"}]}' | Set-Content $rj
$out = python -X utf8 $KT prose --kind result-note $rj | Out-String
Expect 'prose: a results.json note over 40 words is a finding' ($LASTEXITCODE -eq 1 -and $out -match '45 words')
Push-Location $k; $null = python -X utf8 $KT lint --help; $h = $LASTEXITCODE; $null = python -X utf8 $KT flow --bogus 2>&1; $u = $LASTEXITCODE
$null = python -X utf8 $KT lint (Join-Path $k 'skills') 2>&1; $nk = $LASTEXITCODE; Pop-Location
Expect 'kitbag: --help 0, writes nothing; bad flag / non-kit dir 2' ($h -eq 0 -and $u -eq 2 -and $nk -eq 2 -and -not (Test-Path (Join-Path $k '--help')))
$eol = git -C $src check-attr eol -- .codex/config.toml .agents/hooks.json .codex/agents/x.toml .agents/workflows/x.md GEMINI.md
Expect 'port: generated ports are eol=lf (an autocrlf clone shows no line-ending-only diffs)' (@($eol | Where-Object { $_ -match ': eol: lf$' }).Count -eq 5)
# kitbag internals (python)
$ktt = @'
import importlib.util, json, os, sys, tempfile, tomllib
from pathlib import Path
spec = importlib.util.spec_from_file_location('kitbag', sys.argv[1]); kt = importlib.util.module_from_spec(spec); spec.loader.exec_module(kt)
tmp = Path(tempfile.mkdtemp())
# a linked worktree reads localOnly from the main clone; a non-repo folder is its own main clone
ok_main = kt.main_clone(str(tmp)) == str(tmp)
# lint measures PROSE against the linted kit's templates.md (k.dir), not the script's kit
src = open(sys.argv[1], encoding='utf-8').read()
ok_prose = 'writing_standards(k.dir)' in src and 'writing_standards(KIT)' not in src
print(f'kitbag-misc:{ok_main and ok_prose}')
'@
$kf = Join-Path ([IO.Path]::GetTempPath()) "kt-test-$PID.py"; Set-Content $kf $ktt -Encoding utf8
$res = @(& $py -X utf8 $kf (Join-Path $src 'skills/bossy/kitbag.py') 2>&1); Remove-Item $kf -Force
Expect-Each $res 'kitbag: #' 'kitbag-misc'
# a throw-away git copy of the kit: lint codes, budget
$kc = New-GitKitCopy (Join-Path ([IO.Path]::GetTempPath()) "kit-reg-$PID"); $KT2 = Join-Path $kc 'skills/bossy/kitbag.py'
# lint codes on the copy
$oldWf = 'dev' + '-wave'; $oldSk = 'tech' + '-audit'   # built: no old name in the kit (lint OLD-NAME)
Add-Content (Join-Path $kc 'workflows/tidy.js') "`nawait agent('x', { label: 'gp' })`nappendFileSync('a.jsonl', x)`nconst f = rp('agents')" -Encoding utf8; Add-Content (Join-Path $kc 'README.md') "`nsee $oldWf" -Encoding utf8
Add-Content (Join-Path $kc 'skills/crafty/templates.md') "`nsee last-${oldSk}s" -Encoding utf8
Add-Content (Join-Path $kc 'README.md') '', 'run `skills/gone/y.ps1`' -Encoding utf8
$ngw = 'Go' + 'odies'   # built: the retired word never sits in a kit file
Set-Content (Join-Path $kc '.githooks/ng') "$ngw here`nthe $ngw line kept (one-time migration 2026-11-14)" -Encoding utf8; git -C $kc add -f .githooks/ng
$qa2 = Join-Path $kc 'skills/pokey/pokey.ps1'; @(Get-Content $qa2) | Where-Object { $_ -notmatch '^#Requires' } | Set-Content $qa2 -Encoding utf8; Add-Content $qa2 "Start-Process $('pw' + 'sh') -ArgumentList x"   # PS-VERSION, HIDDEN-WINDOW
$rv = "$kc/agents/revy.md"; (Get-Content $rv -Raw) -replace 'Show me', 'X' | Set-Content $rv -NoNewline
$l2 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
Expect 'kitbag lint: MANIFEST (Character), AGENT-TYPE, LOG-DIRECT, PS-VERSION, HIDDEN-WINDOW, OLD-NAME (also last-<old>s), REF-DANGLING, RUNTIME-MAP rp() name missing from KP' ($l2 -match "RUNTIME-MAP\s+workflows/tidy\.js: rp\('agents'\) is not in const KP" -and $l2 -match 'HIDDEN-WINDOW\s+skills/pokey/pokey\.ps1:\d+' -and $l2 -match 'AGENT-TYPE\s+workflows/tidy\.js' -and $l2 -match 'LOG-DIRECT\s+workflows/tidy\.js:\d+' -and $l2 -match "OLD-NAME\s+README\.md.*$oldWf" -and $l2 -match "OLD-NAME\s+skills/crafty/templates\.md.*$oldSk" -and
  $l2 -match 'MANIFEST\s+agents/revy\.md: the Character block differs' -and $l2 -match 'REF-DANGLING\s+README\.md: skills/gone/y\.ps1' -and $l2 -match 'PS-VERSION\s+skills/pokey/pokey\.ps1')
Expect 'kitbag lint: RETIRED-WORD flags the retired word in any tracked file (case-insensitive, .githooks too); the one-time migration line is exempt' ($l2 -match 'RETIRED-WORD\s+\.githooks/ng:1' -and $l2 -notmatch 'RETIRED-WORD\s+\.githooks/ng:2')
# budget: start tokens per role vs 12000 (lint START-BUDGET); repo and tests totals are INFO; a doc no skill leads to = ORPHAN-DOC
$b2 = & $py -X utf8 $KT2 budget 2>&1 | Out-String
Add-Content (Join-Path $kc 'agents/rechy.md') ('#' * 40000), 'First read `skills/crafty/lib.ps1` end to end.'; Set-Content (Join-Path $kc 'zz-orphan.md') '# Orphan'
Set-Content (Join-Path $kc 'tests/zz.tests.ps1') ('#' * 140000) -NoNewline; git -C $kc add tests/zz.tests.ps1 zz-orphan.md
$l4 = & $py -X utf8 $KT2 lint --no-flow 2>&1 | Out-String
Expect "budget: a start line per role + INFO totals; START-BUDGET over 12000; a test file over 9000 = BUDGET, no total cap; ORPHAN-DOC ($($b2.Trim()))" ($b2 -match '(?m)^rechy\s+start\s+\d+ of 12000' -and
  $b2 -match 'INFO repo total \d+ tokens . tests \d+' -and $l4 -match 'START-BUDGET\s+agents/rechy\.md: rechy loads \d+ tokens at start' -and $l4 -match 'zz\.tests\.ps1: 35000 tokens \(cap 9000\)' -and
  $l4 -notmatch 'BUDGET-TESTS|BUDGET-CAP|kit total' -and $l4 -match 'ORPHAN-DOC\s+zz-orphan\.md' -and $l4 -match 'SCRIPT-READ\s+agents/rechy\.md:\d+')
# migrate: the retired install blocks leave .git/info/exclude; a listed file git no longer tracks goes, tracked and localOnly ones
# stay; the use stamps and the config key named after the marker go; a second run prints nothing (words built: no retired word here)
$mgw = 'go' + 'ody'; $mgKey = 'go' + 'odies'; $mgx = git -C $kc rev-parse --path-format=absolute --git-path info/exclude
Add-Content $mgx "# kitbag $mgw duel", '/skills/old/x.ps1', '/README.md', '/notes/mine.txt', "# kitbag $mgw end", '/keep-me.txt'
New-Item -ItemType Directory -Force "$kc/skills/old", "$kc/notes", "$kc/.state/extras-used" | Out-Null; 'x' | Set-Content "$kc/skills/old/x.ps1"; 'm' | Set-Content "$kc/notes/mine.txt"
& $J @{ localOnly = @('notes'); $mgKey = @('duel') } (Join-Path $kc 'skills/crafty/kit.local.json')
$mg1 = & $py -X utf8 $KT2 migrate 2>&1 | Out-String; $mg2 = & $py -X utf8 $KT2 migrate 2>&1 | Out-String
$mgEx = Get-Content $mgx -Raw; $mgCfg = Get-Content (Join-Path $kc 'skills/crafty/kit.local.json') -Raw | ConvertFrom-Json
Expect "kitbag migrate: install blocks out, other exclude lines kept, an untracked listed file removed, tracked + localOnly kept, stamps + config key gone, then silent ($($mg1.Trim() -replace '\s+', ' '))" ($mgEx -notmatch "kitbag $mgw" -and
  $mgEx -match '(?m)^/keep-me\.txt' -and -not (Test-Path "$kc/skills/old") -and (Test-Path "$kc/README.md") -and (Test-Path "$kc/notes/mine.txt") -and -not (Test-Path "$kc/.state/extras-used") -and
  -not $mgCfg.PSObject.Properties[$mgKey] -and @($mgCfg.localOnly).Count -eq 1 -and -not $mg2.Trim())
Add-Content $mgx "# kitbag $mgw duel", '/notes/mine.txt', "# kitbag $mgw end"; '{ broken' | Set-Content (Join-Path $kc 'skills/crafty/kit.local.json')
$mg3 = & $py -X utf8 $KT2 migrate 2>&1 | Out-String; $mg3c = $LASTEXITCODE
Expect "kitbag migrate: an unreadable kit.local.json changes nothing, exit 1 ($($mg3.Trim()))" ($mg3c -eq 1 -and (Test-Path "$kc/notes/mine.txt") -and (Get-Content $mgx -Raw) -match "kitbag $mgw duel")
Remove-Item (Split-Path $kc) -Recurse -Force -ErrorAction SilentlyContinue
# section maps: lint SECTION-MAP / SECTION-UNMAPPED, audit SECTION-BIG, sections --fix
$sp = Join-Path $k 'sec.py'; @'
import sys; sys.path.insert(0, sys.argv[1]); import kitbag as t
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
foreach ($a in 'bossy', 'crafty') { "$(if ($a -eq 'bossy') { 'Start-Sleep 2; ' })'PASS same  Case'; 'PASS own $a'; 'FAIL x'; ""py `$((Get-Command python).Source -notmatch '\.(bat|cmd)`$')""; '1 failure(s)'" | Set-Content "$td/$a.tests.ps1" }   # bossy ends last
$tdr = Invoke-TestScript "$td/kit-tests.ps1" -Area bossy,crafty
Expect 'kit-tests: a case in two areas = TEST-DUP (area order, exit 1); real python, no shim; FAILs recapped by area' ($tdr.code -eq 1 -and $tdr.out -match 'Failed checks:\s+\[bossy\] x\s+\[crafty\] x' -and $tdr.out -match 'TEST-DUP same case: bossy, crafty' -and $tdr.out -notmatch 'TEST-DUP own' -and $tdr.out -match 'py True' -and $tdr.out -notmatch 'py False')
$null = & $py -X utf8 (Join-Path $src 'skills/bossy/kitbag.py') lint --org-terms (Join-Path (Kd) 'no-such.json') 2>&1
Expect 'lint --org-terms: a missing .json is a usage error (2), never a term' ($LASTEXITCODE -eq 2)
# lib.ps1 Add-KitAskBug (here for the guard area's cap): only a QA collector [Bug] takes sections
$env:KIT_TRACKER_TYPE = 'none'; $cbD = Join-Path $k 'skills/crafty/crafty.ps1'; $cbDir = Kd; 'defect one' | Set-Content "$cbDir/c1.md"; 'defect two' | Set-Content "$cbDir/c2.md"
$cbAsk = (pwsh @np $cbD tracker create -List L1 -Name 'Ask panel' -Description 'a' -NewTask fixture | ConvertFrom-Json).id
$cbHand = (pwsh @np $cbD tracker create -List L1 -Parent $cbAsk -Name '[Bug] Ask help icon does nothing' -Description 'hand scope' -NewTask fixture | ConvertFrom-Json).id
$cbFirst = pwsh @np $cbD tracker bug -Parent $cbAsk -Key qa-r1 -Name '[Bug] Ask help icon — new defects (1)' -File "$cbDir/c1.md" -List L1 | ConvertFrom-Json; $cbSecond = pwsh @np $cbD tracker bug -Parent $cbAsk -Key qa-r2 -Name '[Bug] Ask x' -File "$cbDir/c2.md" -List L1 | ConvertFrom-Json
$cbUnit = & { . (Lib); "$(Test-KitBugCollector ([pscustomobject]@{ name = '[Bug] a'; description = "hand`n`nSource: k [kit:bug:k]" }))$(Test-KitBugCollector ([pscustomobject]@{ name = '[Bug] a - new defects (2): x'; description = '' }))$(Test-KitBugCollector ([pscustomobject]@{ name = '[Bug] a'; description = "Source: a \[kit:bug:a\_b\]`r`n`r`nx" }))" }
Expect "tracker bug: a hand-made [Bug] under the ask never takes a section; a new collector does ($($cbFirst.action) $($cbSecond.action) $cbUnit)" ($cbFirst.action -eq 'created' -and $cbFirst.id -ne $cbHand -and $cbSecond.id -eq $cbFirst.id -and $cbSecond.action -eq 'appended' -and (pwsh @np $cbD tracker view $cbHand | ConvertFrom-Json).description -eq 'hand scope' -and $cbUnit -eq 'FalseTrueTrue')
Remove-Item Env:KIT_TRACKER_TYPE
Remove-TestKit $k
$pg = [IO.File]::ReadAllText((Join-Path $src '.github/workflows/pages.yml')); $il = $pg.IndexOf('kitbag.py lint')
Expect 'pages.yml: lint runs the flow checks (no --no-flow), so an issue the page would show fails CI' ($il -ge 0 -and $pg -notmatch '--no-flow')
$cpNoAgent = @(Get-ChildItem "$src/agents/*.md", "$src/skills/*/SKILL.md", "$src/workflows/*.js" | Select-String -Pattern '(crafty\.ps1|\$D) checkpoint (?!-Agent )' | ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
Expect "every documented checkpoint call names -Agent (crafty.ps1 exits 2 without it): $($cpNoAgent -join ', ')" (-not $cpNoAgent.Count)
Complete-Tests
