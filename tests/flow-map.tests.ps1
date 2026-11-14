#Requires -Version 7
<#
tests.ps1 (goody flow-map): the flow model's loop checks; the plugin loads from files/ beside this file.
Usage: pwsh -NoProfile -File goodies/flow-map/tests.ps1 -Kit <kit with skills/bossy/kitbag.py>
Exit codes: 0 pass · 1 a check failed.
#>
param([string]$Kit = (Split-Path $PSScriptRoot))
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
M = {'agents/a.md': '---\nname: a\n---\n# a\n1. Spawn the `b` agent for each review.\n','agents/b.md': '---\nname: b\n---\n# b\n1. Report to `a`.\n',
     'workflows/w.js': "export async function run(agent) {\n  await agent({ agentType: 'a', prompt: 'go' })\n  await agent({ agentType: 'b', prompt: 'go' })\n}\n",
     'skills/bossy/SKILL.md': '# bossy\n## Steps\n1. Spawn the `a` agent.\n'}   # the page fixture: agent-agent, workflow-agent and skill-agent links
k = types.SimpleNamespace(files=list(T) + list(M), texts={**T, **M}, dir=sys.argv[2], skills=['bossy'], agents={'a': 'agents/a.md', 'b': 'agents/b.md'}, workflows={'w': 'workflows/w.js'})
d = flow.model(k, [])
flow.write(sys.argv[4], dict(d, home='https://example.org/kit', readme='https://example.org/kit#readme'), {})   # the page, for kitbag.py ui-check and the behaviour check
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
$res = "$(& $py -X utf8 $f (Join-Path $Kit 'skills/bossy') ([IO.Path]::GetTempPath()) (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/kitbag_flow.py') $pgOut 2>&1)"
Remove-Item $f -Force
# the page: no clipped label, no node or label off-screen or overlapping (window.uiBoxes) at 1366 / 900 / 390, light + dark,
# as loaded, with each side tab open (key included) and in the Detail and Everything views
$uiRt = Join-Path ([IO.Path]::GetTempPath()) "kit-flow-ui-rt-$PID"; Set-Item Env:CLAUDE_RUNTIME $uiRt   # own shots and stamp, never the kit's
$uiKit = @($Kit, $env:KIT_TEST_CORE) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'skills/pokey/node_modules/puppeteer-core')) } | Select-Object -First 1   # goody test's kit copy has no node_modules: the core's
$kb = { param($w, $c) @(& $py -X utf8 (Join-Path $uiKit 'skills/bossy/kitbag.py') ui-check $pgOut --widths $w --click $c 2>&1); $LASTEXITCODE }   # desktop clicks; a phone taps (its level buttons sit in the menu)
$ui = @(if ($uiKit) { & $kb '1366,900' '.ri[data-t=key];.ri[data-t=issues];.ri[data-t=loops];.ri[data-t=trace];.ri[data-t=code];#lv .b:nth-child(2);#lv .b:nth-child(3);#ix'; & $kb 390 '#vw;#vw,#mn,#lv .b:nth-child(3);.ri[data-t=key];#lst .li' } else { 'SKIP flow-map page check: no puppeteer-core in the kit' })   # @(): a bare string's [-1] is its last letter
# behaviour on the fixture page: what a person and a screen reader meet first (title, intro, buttons, deep links, keys, phone list, contrast)
$bh = @'
import puppeteer from 'puppeteer-core'
import { pathToFileURL } from 'node:url'
const [bm, file] = process.argv.slice(1), { CHROME } = await import(bm), url = pathToFileURL(file).href, o = {}
const b = await puppeteer.launch({ executablePath: CHROME, headless: true })
const open = async (w, hash = '', theme = 'light', c = null) => { c = c || await b.createBrowserContext(); const p = await c.newPage(); await p.setViewport({ width: w, height: 800 }); await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }]); await p.goto(url + hash); return p }
const ev = (p, f, ...a) => p.evaluate(f, ...a)
try {
  const p = await open(1366), xy = () => KF.N.map((n) => Math.round(n.x) + ',' + Math.round(n.y)).join(' ')
  Object.assign(o, await ev(p, () => ({ title: document.title, meta: (document.querySelector('meta[name=description]') || {}).content || '', noscript: /README/.test(document.querySelector('noscript').textContent),
    buttons: [...document.querySelectorAll('.b,.ri')].every((e) => /^(BUTTON|INPUT)$/.test(e.tagName)) && !!document.querySelector('.ri[aria-pressed]'),
    canvas: document.querySelector('#c').getAttribute('role') === 'img' && document.querySelector('#c').getAttribute('aria-label').length > 20,
    home: KF.sel && KF.sel.id, hash0: location.hash, intro: !document.querySelector('#intro').hidden, deskList: document.querySelector('#lst').classList.contains('sr') })))
  o.seed = (await ev(p, xy)) === (await ev(await open(1366), xy))
  await p.keyboard.press('Escape'); o.ov = await ev(p, () => [KF.drawnEdges(), KF.ovEdges(), KF.allEdges()])
  await ev(p, () => KF.select(KF.N.find((n) => n.id === 'agents/a.md'))); await p.keyboard.press('ArrowRight'); o.live = await ev(p, () => document.querySelector('#live').textContent)
  await p.keyboard.press('Enter'); o.keyPick = await ev(p, () => KF.sel.id)
  const p2 = await open(1366, '#sel=agents%2Fb.md&level=1'); o.deep = await ev(p2, () => KF.sel.id + '@' + KF.lvl); await ev(p2, () => KF.setLevel(2)); o.hash2 = await ev(p2, () => location.hash)
  await p.click('#ix'); await p.reload(); o.introKept = await ev(p, () => document.querySelector('#intro').hidden)
  const p3 = await open(390); o.phone = await ev(p3, () => { const l = document.querySelector('#lst'), r = l.getBoundingClientRect(); return !l.classList.contains('sr') && r.width > 300 && r.left >= 0 && l.querySelectorAll('button.li').length })
  for (const t of ['light', 'dark']) o['aa-' + t] = await ev(await open(1366, '', t), () => {
    const cs = getComputedStyle(document.documentElement), hex = (k) => cs.getPropertyValue(k).trim(), lum = (h) => { const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((x) => x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
    const ratio = (a, z) => { const [x, y] = [lum(hex(a)), lum(hex(z))].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05) }
    return ['--fg', '--mut', '--cm', '--va', '--bad', '--st', '--kw', '--nu', '--lp'].flatMap((k) => ['--bg', '--pn'].map((z) => [k, z, ratio(k, z)])).filter((r) => r[2] < 4.5).map((r) => r.join(' ')).join('; ') || 'ok' })
} finally { await b.close() }
console.log(JSON.stringify(o))
'@
$bo = if ($uiKit) { Push-Location (Join-Path $uiKit 'skills/pokey'); try { $raw = @(& node --input-type=module -e $bh (([uri](Join-Path $uiKit 'skills/pokey/browser.mjs')).AbsoluteUri) $pgOut 2>&1); try { $raw[-1] | ConvertFrom-Json } catch { "$raw" } } finally { Pop-Location } }
Remove-Item Env:CLAUDE_RUNTIME; Remove-Item $pgOut, ($pgOut -replace '\.html$', '-src.js'), $uiRt -Recurse -Force -ErrorAction SilentlyContinue
$pg = Get-Content -Raw (Join-Path (Split-Path $PSScriptRoot) 'skills/bossy/kitbag_flow.py')
$checks = [ordered]@{}
if ($ui[-1] -is [string]) { $ui[-1] } else { $checks["page: no clipped text, every node + label in view, none overlapping (kitbag.py ui-check, 1366 / 900 click 9 states, 390 taps 5, x 2 themes; $(@($ui | Where-Object { "$_" -cmatch 'CLIP|failed' }) -join ' | '))"] = @($ui | Where-Object { $_ -is [int] -and $_ -ne 0 }).Count -eq 0 }
if ($bo -is [string]) { $checks["page behaviour check ran ($bo)"] = $false } elseif ($bo) { $checks += [ordered]@{
  "F1 title, meta description, noscript README link; an intro on the first visit, its dismissal kept ($($bo.title))" = $bo.title -eq 'Claude Crew kit map' -and $bo.meta.Length -gt 40 -and $bo.noscript -and $bo.intro -and $bo.introKept
  "F2 Overview at rest draws only agent-agent / workflow-agent links ($($bo.ov -join ' / ') drawn / ov / all); seeded layout; bossy selected first" = $bo.ov[0] -eq $bo.ov[1] -and $bo.ov[1] -gt 0 -and $bo.ov[2] -gt $bo.ov[1] -and $bo.seed -and $bo.home -eq 'skills/bossy/SKILL.md'
  "F3 controls are buttons, the canvas an img with a label, arrows step neighbours and Enter picks ($($bo.live) -> $($bo.keyPick))" = $bo.buttons -and $bo.canvas -and $bo.live -match ' of \d' -and $bo.keyPick -ne 'agents/a.md'
  "F4 deep links: #sel / level read on load, every change mirrored ($($bo.deep), $($bo.hash0), $($bo.hash2))" = $bo.deep -eq 'agents/b.md@1' -and $bo.hash0 -match 'sel=skills%2Fbossy%2FSKILL\.md' -and $bo.hash2 -match 'level=2'
  "F5 under 640 px the parts list is the default view ($($bo.phone) parts); a desktop keeps it off-screen for keyboards" = $bo.phone -ge 3 -and $bo.deskList
  "F6 text tokens AA (4.5:1) on --bg and --pn, light ($($bo.'aa-light')) and dark ($($bo.'aa-dark'))" = $bo.'aa-light' -eq 'ok' -and $bo.'aa-dark' -eq 'ok' } }
$checks += [ordered]@{
  'F2 / F9 a resting label is one line of 28 chars + ellipsis (whole on hover and in the tooltip); label text never under 11 px' = $pg -match "const oneL = t => \{ t = String\(t\); return t\.length > 28" -and $pg -match 'const full = n === hover' -and $pg -notmatch '(?<![\d.])(10\.5|10|9) \* lw\}px'
  'F7 node glyphs 70% of the node; loop labels and badges on the --lp token, not a literal pink' = $pg -match 'r \* 1\.4, n\.col' -and $pg -notmatch '#db2777'
  'F8 node descriptions ride in the sidecar (KF_DESC), not the page' = $pg -match "window\.KF_DESC=" -and $pg -match "nodes=\[n\[:4\] \+ \[''\] \+ n\[5:\]"
  'F10 kit repo + README links in the code tab and the intro (D.home)' = ([regex]::Matches($pg, 'D\.home')).Count -ge 3 -and $pg -match 'README</a>'
  'legend lists use the kit''s one compact grid (.cg auto-fill via cgrid()), no fixed column counts' = $pg -match '\.cg\{display:grid;[^}]*repeat\(auto-fill,minmax\(min\(100%' -and $pg -notmatch 'repeat\([23],minmax\(0,1fr\)\)' -and ([regex]::Matches($pg, "\+ cgrid\(")).Count -eq 3
  'the fitted layout stays: rebuild never reheats; load, resize (until a pan or zoom) and every view button refit the whole graph' = $pg -notmatch 'heat\(\.15\)' -and $pg -match 'function setLevel\(L\) \{ LVL = L; rebuild\(\); fitView\(\); toHash\(\) \}' -and $pg -match 'if \(auto\) return fitView\(\)'
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
