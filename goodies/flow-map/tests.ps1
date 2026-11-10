#Requires -Version 7
<#
tests.ps1 (goody flow-map): the flow model's loop checks; the plugin loads from files/ beside this file.
Usage: pwsh -NoProfile -File goodies/flow-map/tests.ps1 -Kit <kit with skills/bossy/kitbag.py>
Exit codes: 0 pass · 1 a check failed.
#>
param([Parameter(Mandatory)][string]$Kit)
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
$fx = @'
import importlib.util, re, sys, types, collections
sys.path.insert(0, sys.argv[1])
import kitbag
spec = importlib.util.spec_from_file_location('kitbag_flow', sys.argv[3])
flow = importlib.util.module_from_spec(spec)
flow.__dict__.update({n: v for n, v in vars(kitbag).items() if not n.startswith('__')})
spec.loader.exec_module(flow)
T = {'fp.ps1': '''function Active { All | Where-Object { $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt $staleMin } }
function Hint { "== heartbeat: arm ONE: CronCreate (cron */10 * * * *), prompt: run supervise and retry when stale" }
function Keep($x, $rm) { $x.m = @(@($x.m) | Where-Object { $p = "$_" -split '>', 2; $p[0] -notin $rm }) }
function Label { $v = if ($Matches[1]) { ' (independent re-test)' } else { '' }; $v }
function Bounded { for ($i = 0; $i -lt 3; $i++) { Start-Sleep 1 }; foreach ($x in @(1, 2)) { $x }; while ((Get-Date) -lt $end) { Start-Sleep 5 } }
''', 'fp.py': 'def port():\n    print("kitbag port: GEMINI.md stale or missing; retry later")\n',
     'fp.mjs': 'export function login(page, L) {\n  if (!page.url().includes(L.path)) {   // logged in as someone else: clear and retry\n    return 1\n  }\n}\n',
     'real.ps1': 'function Poll($f) {\n  while ($true) { Start-Sleep 5; if (Test-Path $f) { break } }\n}\n',
     'real.mjs': 'export async function waitDone(poll) {\n  let done = false\n  while (!done) { done = await poll() }\n}\n',
     'marked.ps1': 'function Watch($f) {\n  while ($true) { Start-Sleep 5 }   # flow: unbounded on purpose - watch until Ctrl+C\n}\n'}
k = types.SimpleNamespace(files=list(T), texts=T, dir=sys.argv[2], skills=[], agents={}, workflows={})
d = flow.model(k, [])
flow.write(sys.argv[4], dict(d), dict(d).pop('_texts', {}))   # the page, for kitbag.py ui-check
c = collections.Counter(m.group(0) for i in d['issues'] for m in [re.search(r'(fp|real|marked)\.\w+', i['text'])] if m)
print(' '.join(f'{f}={c.get(f, 0)}' for f in T), 'deliberate=' + str(sum(1 for i in d['deliberate'] if 'marked.ps1' in i['text'])))
V = {'tool.py': "def cmd_lint(a):\n    pass\n\nCOMMANDS = {'lint': cmd_lint, 'audit': cmd_lint}\nFORMATS = {'json': cmd_lint}\nEXTRA_OF = {'flow': 'flow-map',\n  'port': 'ports'}\n",
     'a.ps1': "function Invoke-Board { }\nswitch ($__verb) {\n  'board' {\n    if ($x) { Invoke-KitVerb Invoke-Board $r }\n  }\n"
       "  'two' { switch ($m) { 'x' {1}  default {2} } }\n  'deploy' { $null = Assert-KitExtra Invoke-Deploy 'a.ps1 deploy' 'deploys'; Invoke-KitVerb Invoke-Deploy $r }\n"
       "  { $_ -in 'deployed', 'annotate' } {\n    Invoke-KitVerb $fn $r\n  }\n  default { exit 2 }\n}\n",
     'doc.md': '# d\n- `tool.py lint`, `tool.py audit scan`, `tool.py port`, `a.ps1 board`, `a.ps1 deploy request`, `a.ps1 annotate`, `a.ps1 nope`, `tool.py json`\n'}
k = types.SimpleNamespace(files=list(V), texts=V, dir=sys.argv[2], skills=[], agents={}, workflows={})
print('verbs=' + ','.join(sorted(i['text'].split(':')[0] for i in flow.model(k, [])['issues'] if i['code'] == 'UNRESOLVED')))
tool = "function Invoke-Go { Set-Content run.json '{}' }\nswitch ($__verb) {\n  'go' { Invoke-KitVerb Invoke-Go $r }\n  default { exit 2 }\n}\n"
runread = "& pwsh tool.ps1 go\n$j = Get-Content run.json | ConvertFrom-Json\n"
for name, S in [('tests', {'tool.ps1': tool, 'tests/t.tests.ps1': runread}), ('driver', {'tool.ps1': tool, 'driver.ps1': runread}),
                ('doc', {'tool.ps1': tool, 'doc.md': '# d\n## Steps\n1. Run `tool.ps1 go`, then read run.json.\n'}),
                ('rmw', {'rmw.ps1': "$j = Get-Content run.json\n" + '#' * 100 + "\nSet-Content run.json $j\n"})]:   # a script is a loop; a test, a doc, a read-modify-write never
    k = types.SimpleNamespace(files=list(S), texts=S, dir=sys.argv[2], skills=[], agents={}, workflows={})
    print(f'scc-{name}=' + str(sum(1 for c in flow.model(k, [])['cycles'] if c['kind'] == 'scc')))
'@
$f = Join-Path ([IO.Path]::GetTempPath()) "kit-flow-fixture-$PID.py"; Set-Content $f $fx -Encoding utf8
$pgOut = Join-Path ([IO.Path]::GetTempPath()) "kit-flow-ui-$PID.html"
$res = "$(& $py -X utf8 $f (Join-Path $Kit 'skills/bossy') ([IO.Path]::GetTempPath()) (Join-Path $PSScriptRoot 'files/skills/bossy/kitbag_flow.py') $pgOut 2>&1)"
Remove-Item $f -Force
# the page: no clipped label, no node or label off-screen or overlapping (window.uiBoxes) at 1366 / 900 / 390, light + dark,
# as loaded, with each side tab open (key included) and in the Detail and Everything views
$uiRt = Join-Path ([IO.Path]::GetTempPath()) "kit-flow-ui-rt-$PID"; $env:CLAUDE_RUNTIME = $uiRt   # own shots and stamp, never the kit's
$ui = if (Test-Path (Join-Path $Kit 'skills/pokey/node_modules/puppeteer-core')) { @(& $py -X utf8 (Join-Path $Kit 'skills/bossy/kitbag.py') ui-check $pgOut --click '.ri[data-t=key];.ri[data-t=issues];.ri[data-t=loops];.ri[data-t=trace];.ri[data-t=code];#lv .b:nth-child(2);#lv .b:nth-child(3)' 2>&1); $LASTEXITCODE } else { 'SKIP flow-map page check: no puppeteer-core in the kit' }
Remove-Item Env:CLAUDE_RUNTIME; Remove-Item $pgOut, ($pgOut -replace '\.html$', '-src.js'), $uiRt -Recurse -Force -ErrorAction SilentlyContinue
$pg = Get-Content -Raw (Join-Path $PSScriptRoot 'files/skills/bossy/kitbag_flow.py')
$checks = [ordered]@{}
if ($ui[-1] -is [string]) { $ui[-1] } else { $checks["page: no clipped text, every node + label in view, none overlapping (kitbag.py ui-check, 3 widths x 2 themes x 8 states; $(@($ui | Where-Object { "$_" -cmatch 'CLIP|failed' }) -join ' | '))"] = $ui[-1] -eq 0 }
$checks += [ordered]@{
  'canvas labels wrap, never cut (no label .slice)' = $pg -notmatch '\.l\.slice\(0|t\.slice\(0, 64\)|`\.slice\(0, [68]0\)'
  'legend lists use the kit''s one compact grid (.cg auto-fill via cgrid()), no fixed column counts' = $pg -match '\.cg\{display:grid;[^}]*repeat\(auto-fill,minmax\(min\(100%' -and $pg -notmatch 'repeat\([23],minmax\(0,1fr\)\)' -and ([regex]::Matches($pg, "\+ cgrid\(")).Count -eq 3
  'the fitted layout stays: rebuild never reheats; load, resize (until a pan or zoom) and every view button refit the whole graph' = $pg -notmatch 'heat\(\.15\)' -and $pg -match 'function setLevel\(L\) \{ LVL = L; rebuild\(\); fitView\(\) \}' -and $pg -match 'if \(auto\) return fitView\(\)'
  'the key docks as a side tab (a bottom sheet on phones), never a panel over the graph' = $pg -match "key: \['key', 'Key'\]" -and $pg -notmatch 'id="leg"'
  "no false loop issues ($res)" = $res -match 'fp\.ps1=0 fp\.py=0 fp\.mjs=0'
  'real unbounded loops flagged once each' = $res -match 'real\.ps1=1 real\.mjs=1'
  'a loop marked `flow: <reason>` is deliberate, not counted' = $res -match 'marked\.ps1=0' -and $res -match 'deliberate=1'
  'run-then-read is a loop from a script, never from a test file, a doc step or one read-modify-write' = $res -match 'scc-tests=0 scc-driver=1 scc-doc=0 scc-rmw=0'
  'verbs from COMMANDS / EXTRA_OF tables and multi-line switch ($__verb) cases resolve (a nested default does not end the scan); an unknown verb or a non-verb table does not' = $res -match 'verbs=a\.ps1 nope,tool\.py json(\s|$)'
}
$fails = 0
foreach ($c in $checks.GetEnumerator()) { if ($c.Value) { "PASS flow-map: $($c.Key)" } else { "FAIL flow-map: $($c.Key)"; $fails++ } }
exit [int]($fails -gt 0)
