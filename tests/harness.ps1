#Requires -Version 7
<#
harness.ps1: the shared helpers every tests/<area>.tests.ps1 dot-sources (not run on its own).
Usage: . (Join-Path $PSScriptRoot 'harness.ps1') at the top of an area file; Complete-Tests at its end.
Exit codes: none here; Complete-Tests ends the area file with 0 pass · 1 a check failed.
#>
$ErrorActionPreference = 'Stop'   # the area files inherit it (dot-sourced), as the single file did
$src = Split-Path $PSScriptRoot   # the kit
$script:fails = 0
Remove-Item Env:CLAUDE_RUNTIME -ErrorAction SilentlyContinue   # own runtime + state per test kit
foreach ($v in 'AUTHOR', 'COMMITTER') { Set-Item "env:GIT_${v}_NAME" 't'; Set-Item "env:GIT_${v}_EMAIL" 't@t' }   # test repos commit without a git config
$np = '-NoProfile', '-File'   # pwsh @np <script>
$py = if (Get-Command python -ErrorAction SilentlyContinue) { 'python' } else { 'python3' }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $env:PYTHONIOENCODING = 'utf-8'   # child output (· …) read as UTF-8 under any console code page
$env:KIT_POLL_MS = '200'; $env:CLAUDE_GATE_KEEP_FREE_GB = '0'; $env:KIT_STORAGE_SCAN = '0'; $env:KIT_KEEP_DAEMONS = '1'   # Wait-KitPoll fake clock; test builds are tiny: never queue for RAM; no drive scans; no daemon kills
$env:TEMP = $env:TMP = Join-Path ([IO.Path]::GetTempPath()) "kit-tests-$PID"; New-Item -ItemType Directory -Force $env:TEMP | Out-Null   # own temp: never the machine's build-gate queue
# `pwsh -NoProfile -File <kit script>` runs in this process (0.07 s, not 0.7 s), seen as a child sees it (streams, exit code, cwd,
# env, globals); stdin readers, gate / check / guard and KIT_TESTS_SPAWN=1: real processes
$pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
function pwsh {
  $a = @($args); $in = @($input)
  if ($env:KIT_TESTS_SPAWN -or $in.Count -or $a.Count -lt 3 -or $a[0] -ne '-NoProfile' -or $a[1] -ne '-File' -or "$($a[2])" -notmatch '\.ps1$' -or "$($a[3])" -in 'gate', 'check', 'guard' -or
    "$((Get-PSCallStack)[1].ScriptName)" -notlike "$PSScriptRoot*") { $in | & $pwshExe @a; return }
  $ErrorActionPreference = 'Continue'; $here = Get-Location; $envs = [Environment]::GetEnvironmentVariables(); $g0 = @((Get-Variable -Scope Global).Name)
  $ew = [IO.StringWriter]::new(); $e0 = [Console]::Error; [Console]::SetError($ew); $i0 = [Console]::In; [Console]::SetIn([IO.StringReader]::new('')); $global:LASTEXITCODE = 0
  $rest = @($a | Select-Object -Skip 3)
  try { & $a[2] @rest *>&1 | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { Write-Error -ErrorRecord $_ } else { "$_" } } }
  catch { Write-Error -ErrorRecord $_; $global:LASTEXITCODE = 1 }
  finally {
    $code = $global:LASTEXITCODE; [Console]::SetError($e0); [Console]::SetIn($i0); Set-Location $here
    Get-Variable -Scope Global | Where-Object Name -NotIn $g0 | Remove-Variable -Scope Global -Force -ErrorAction SilentlyContinue   # memos ($KitTrackerMemo, ...) die with a process
    $now = [Environment]::GetEnvironmentVariables(); foreach ($n in $now.Keys) { if (-not $envs.Contains($n)) { [Environment]::SetEnvironmentVariable($n, $null) } }
    foreach ($n in $envs.Keys) { if ($now[$n] -ne $envs[$n]) { [Environment]::SetEnvironmentVariable($n, $envs[$n]) } }
    if ("$ew") { Write-Error "$ew".TrimEnd() }
    $global:LASTEXITCODE = $code
  }
}

function Kd {
  if (-not $k) { throw 'Kd: $k is unset or empty' }
  $p = Split-Path $k
  if (-not $p) { throw "Kd: Split-Path for '$k' returned empty" }
  $p
}
function Lib {
  if (-not $k) { throw 'Lib: $k is unset or empty' }
  Join-Path $k 'skills/crafty/lib.ps1'
}   # the test kit's lib.ps1
function Px { $input | pwsh -NoProfile -File @args }
# KIT_TESTS_TIME=1: Complete-Tests lists the slowest checks (time since the previous check)
$script:clock = [Diagnostics.Stopwatch]::StartNew(); $script:times = [Collections.Generic.List[object]]::new()
function Expect($what, $cond) {
  $script:times.Add([pscustomobject]@{ s = $script:clock.Elapsed.TotalSeconds; what = $what }); $script:clock.Restart()
  if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ }
}
# one Expect per key: a "<key>:true" line in $res ('#' in $label = the key); -Show N: N lines on a miss
function Expect-Each($res, [string]$label, [string[]]$keys, [int]$Show = 0) {
  foreach ($x in $keys) { Expect $label.Replace('#', $x) (@($res | Where-Object { "$_" -eq "${x}:true" }).Count -eq 1) }
  if ($Show -and @($res | Where-Object { "$_" -match ':true$' }).Count -ne $keys.Count) { $res | Select-Object -First $Show }
}
# a script run in its own pwsh: .out = stdout + stderr as one string, .code = its exit code
function Invoke-TestScript {
  $out = $input | pwsh -NoProfile -File @args 2>&1 | Out-String
  [pscustomobject]@{ out = $out; code = $LASTEXITCODE }
}
# table-driven cases: each row = @(name, { run }, { param($r) check $r }); one Expect per row
function Expect-Cases([object[]]$Cases) {
  foreach ($case in $Cases) { $result = & $case[1]; Expect $case[0] (& $case[2] $result) }
}
function Invoke-PsTest([string]$Name, [string]$Script, $ArgsToPass = @()) { $f = Join-Path (Kd) "$Name.ps1"; Set-Content $f $Script -Encoding utf8; @(pwsh @np $f @ArgsToPass 2>&1) }
function Set-JsonFile([string]$Path, $Obj, [int]$Depth = 8) {
  $d = Split-Path $Path; if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  $Obj | ConvertTo-Json -Depth $Depth | Set-Content $Path -Encoding utf8
}
$J = { param($o, $f, [int]$d = 8) Set-JsonFile $f $o $d }
function Test-Prose($Kind, $File) { $null = python -X utf8 (Join-Path $src 'skills/bossy/kitbag.py') prose --kind $Kind $File; $LASTEXITCODE -eq 0 }   # vs the source kit's templates.md
function Read-Json($Path) { Get-Content $Path -Raw | ConvertFrom-Json }
# a scratch mysqld batch as Invoke-MySqlStatement runs it (--unbuffered, the end marker): a lost read is asked again, a lost write throws (a re-run write is no repro)
function Invoke-TestMySql([string]$Sql, [string]$Port) {
  $tmRead = $Sql -match '^\s*(SELECT|SHOW|WITH|CHECKSUM)\b' -and ($Sql -replace '(?i)^\s*SHOW\s+CREATE\s+\w+', 'SHOW') -notmatch '(?i)\b(INSERT|UPDATE|DELETE|REPLACE|DROP|ALTER|CREATE|TRUNCATE|CALL|KILL|SET|INTO|OUTFILE|DUMPFILE|GRANT|RENAME|LOAD|FLUSH|LOCK)\b|;\s*\S'
  foreach ($tmTry in 1..3) { $tmOut = @("$($Sql.TrimEnd().TrimEnd(';'));`nSELECT '__kit_rows_end__';" | mysql -h 127.0.0.1 -P $Port -u root --default-character-set=utf8mb4 -N -B --unbuffered 2>&1); if ($LASTEXITCODE) { throw "$tmOut" }
    if ($tmOut.Count -and $tmOut[-1] -eq '__kit_rows_end__') { return $tmOut | Select-Object -SkipLast 1 }
    if (-not $tmRead) { throw "mysql: exit 0 without the end marker (a write: not re-run, it may have run): $($Sql.Substring(0, [math]::Min(80, $Sql.Length)))" } }
  throw "mysql: a read without the end marker 3 times: $Sql" }
# a scratch mysqld for one area file: data dir in the kit's runtime (work/tests, never %TEMP%), an OS-picked port, cheap writes (8 MB
# redo, no doublewrite, lazy log flush: ~1 GB a suite before); -Binlog: ROW / FULL binlogs. Stop-TestMySql in a finally; a hard
# kill leaves it to bossy.ps1 cleanup / supervise (no live launcher)
function Start-TestMySql([switch]$Binlog) {
  $tmExe = (Get-Command mysqld -ErrorAction Stop).Source
  $tmRoot = & { . (Join-Path $src 'skills/crafty/lib.ps1'); Join-Path (Get-KitPath work) 'tests' }   # the source kit's runtime
  $tmData = Join-Path $tmRoot "mysqld-$PID"; Remove-Item $tmData -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $tmRoot | Out-Null
  $tmCheap = '--innodb-redo-log-capacity=8M --innodb-doublewrite=OFF --innodb-flush-log-at-trx-commit=2'
  & $tmExe --no-defaults --initialize-insecure "--datadir=$tmData" --skip-log-bin @($tmCheap -split ' ') 2>&1 | Out-Null
  $fp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $fp.Start(); $tmPort = $fp.LocalEndpoint.Port; $fp.Stop()   # an OS-picked free port: 3390+ raced parallel runs
  $tmLog = if ($Binlog) { '--log-bin=binlog --server-id=1 --binlog-row-metadata=FULL --sync-binlog=0' } else { '--skip-log-bin' }
  $tmProc = Start-Process $tmExe -ArgumentList "--no-defaults `"--datadir=$tmData`" --port=$tmPort --bind-address=127.0.0.1 --mysqlx=OFF $tmCheap $tmLog" -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 60 -and -not (Test-NetConnection 127.0.0.1 -Port $tmPort -InformationLevel Quiet -WarningAction SilentlyContinue); $i++) { Start-Sleep 1 }
  $tmSrv = [pscustomobject]@{ proc = $tmProc; port = $tmPort; data = $tmData }
  if ($i -ge 60) { Stop-TestMySql $tmSrv; throw "Start-TestMySql: mysqld not listening on $tmPort after 60 s" }
  $tmSrv
}
# a clean shutdown, else the whole tree (Windows: the started mysqld is a monitor, its worker a child: killing the monitor alone orphans it)
function Stop-TestMySql($Server) {
  if (-not $Server) { return }
  if (-not $Server.proc.HasExited) { & mysqladmin -h 127.0.0.1 -P $Server.port -u root shutdown 2>&1 | Out-Null; $null = $Server.proc.WaitForExit(30000) }
  try { $Server.proc.Kill($true) } catch {}; $null = $Server.proc.WaitForExit(10000)
  for ($tmTry = 0; $tmTry -lt 10 -and (Test-Path $Server.data); $tmTry++) { Remove-Item $Server.data -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $Server.data) { Start-Sleep -Milliseconds 500 } }   # a killed worker frees its files a moment later
}
# commit everything in $Dir (a git repo first if it is none)
function Save-GitRepo($Dir, $Message) { if (-not (Test-Path "$Dir/.git")) { git -C $Dir init -q }; git -C $Dir add -A; git -C $Dir commit -q -m $Message }
# a throw-away kit copy (the scripts the tests run) in %TEMP%; one per area file
function New-TestKit([string]$name) {
  $k = Join-Path ([IO.Path]::GetTempPath()) "kit-test-$name-$PID\.claude"
  foreach ($f in @('skills/crafty/lib.ps1', 'skills/crafty/flagged.ps1', 'skills/crafty/kit.example.json', 'skills/crafty/crafty.ps1', 'skills/crafty/devtools.py', 'skills/pokey/pokey.ps1',
      'skills/bossy/bossy.ps1', 'skills/bossy/adapters/supervise_resources.ps1', 'skills/bossy/adapters/supervise_stats.ps1', 'skills/bossy/adapters/usage.ps1', 'skills/bossy/adapters/storage.ps1', 'skills/bossy/kitbag.py', 'skills/bossy/params.registry.json', 'LESSONS.md', 'skills/crafty/vocab.json', 'skills/crafty/adapters/process_gates.ps1', 'skills/crafty/adapters/task_items.ps1', 'skills/crafty/adapters/supervise_report.ps1') + @($TestKitFiles | Where-Object { $_ })) {   # $TestKitFiles: the area's own scripts
    $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path $src $f) $d
  }
  $k
}
function TkPath($tkDir, $tkName, [switch]$Create) {
  if (-not $tkDir) { throw 'TkPath: $tkDir is unset or empty' }
  & { . (Join-Path $tkDir 'skills/crafty/lib.ps1'); Get-KitPath $tkName -Create:$Create }
}
function Remove-TestKit($k) {
  $nm = Get-Item "$k/skills/pokey/node_modules" -ErrorAction SilentlyContinue; if ($nm.LinkType) { [IO.Directory]::Delete($nm.FullName) }   # the link only, never the kit's packages
  Remove-Item (Kd) -Recurse -Force -ErrorAction SilentlyContinue
}
# every tracked kit file copied to $To (no git)
function Copy-KitTree([string]$To) {
  foreach ($f in @(git -C $src ls-files)) { $s1 = Join-Path $src $f; if (Test-Path $s1) { $d = Join-Path $To (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $s1 $d -Force } }
}
# Copy-KitTree into <Dir>/.claude as a git repo (one commit on main) with the bare <Dir>/origin.git; -Push: main pushed + fetched
function New-GitKitCopy([string]$Dir, [switch]$Push) {
  $kc = Join-Path $Dir '.claude'; Copy-KitTree $kc
  git -C $kc init -q -b main; git -C $kc add -A; git -C $kc commit -q -m 'feat: base'
  git init -q --bare "$Dir/origin.git"; git -C $kc remote add origin "$Dir/origin.git"
  if ($Push) { git -C $kc push -q origin main 2>&1 | Out-Null; git -C $kc fetch -q origin }
  $kc
}
# git repo <Kd>/<Name>: lib.ps1, kit.example.json, $Files; kit.local.json = $Local (uncommitted); returns its worktree '<Name> wt'
function New-LinkedKit([string]$Name, [hashtable]$Local, [string[]]$Files = @()) {
  $mk = Join-Path (Kd) $Name
  foreach ($f in @('skills/crafty/lib.ps1', 'skills/crafty/kit.example.json') + $Files) { $d = New-Item -ItemType Directory -Force (Join-Path $mk (Split-Path $f)); Copy-Item (Join-Path $k $f) $d }
  Save-GitRepo $mk init
  & $J $Local "$mk/skills/crafty/kit.local.json"
  git -C $mk worktree add -q --detach "$mk wt" 2>$null; "$mk wt"
}
# a local JSON API for pokey.ps1 api: /login gives tokens + cookies; each other path answers 200 only with its auth; /v returns $Sha
function Start-TestApi([string]$Sha = '') {
  $sv = Join-Path (Kd) 's.cjs'; $port = 18000 + $PID % 1000
  Set-Content $sv @'
require('http').createServer((q, s) => { let b = ''; q.on('data', (d) => b += d); q.on('end', () => {
  const u = q.url, h = q.headers, j = (o, st = 200, hd = {}) => { s.writeHead(st, { 'content-type': 'application/json', ...hd }); s.end(JSON.stringify(o)) }
  if (u === '/login') return /R1/.test(b) ? j({ access_token: 'A2' }) : j({ access_token: 'A1', refresh_token: 'R1' }, 200, { 'set-cookie': ['sid=1', 'XSRF-TOKEN=x1'] })
  const ok = { '/l': h.authorization === 'Bearer A1', '/c': h.cookie && h['x-xsrf-token'] === 'x1', '/b': h.authorization === 'Bearer A2', '/q?api_key=K9': 1, '/t/acme/x': 1, '/t/acme/ct': h['content-type'] === 'text/plain', '/h': h['x-sig'] === 's1' }[u]
  if (/^\/t\/acme\/(pdf|txt|empty)$/.test(u)) { s.writeHead(200, { 'content-type': 'application/octet-stream' }); return s.end({ pdf: '%PDF-1 x', txt: 'a,b' }[u.slice(8)] || '') }
  u === '/v' ? j({ v: { sha: process.argv[3] } }) : j({}, ok ? 200 : 401) }) }).listen(+process.argv[2], '127.0.0.1')
'@
  [pscustomobject]@{ port = $port; proc = (Start-Process node -ArgumentList $sv, $port, $Sha -PassThru -NoNewWindow) }; Start-Sleep 1
}
# browser.mjs + the kit's puppeteer-core linked ($false: none); NodeT <name> <js> [args]: $js after m = await import(BM)
function Use-BrowserKit {
  $nm = "$src/skills/pokey/node_modules"; if (-not (Test-Path "$nm/puppeteer-core")) { return $false }
  Copy-Item "$src/skills/pokey/browser.mjs" "$k/skills/pokey"; New-Item -ItemType Junction -Path "$k/skills/pokey/node_modules" -Value (Resolve-Path $nm).Path | Out-Null; $true
}
# NodeT head: login app at `web` (/login form; /sso-app -> /idp on localhost; a 6-digit c logs in; posts counted; gen++ logs out)
$LoginApp = @'
import http from 'node:http'
import { writeFileSync } from 'node:fs'
let posts = 0, gen = 1
const form = (to) => `<html><form method="post" action="${to}"><input id="u" name="u"><input id="c" name="c"><button>Go</button>`
const app = http.createServer((q, s) => {
  const go = (l, c) => { s.writeHead(302, { location: l, ...(c && { 'set-cookie': `sid=${gen}; HttpOnly` }) }); s.end() }
  if (q.method === 'POST') { posts++; let d = ''; q.on('data', (x) => (d += x)); return q.on('end', () => (/u=qa&c=\d{6}/.test(d) ? go(web + '/', 1) : go(q.url))) }
  if (/^\/(login|idp)$/.test(q.url)) return s.end(form(q.url === '/idp' ? web + '/sso' : '/login'))
  if (q.headers.cookie === `sid=${gen}`) return s.end('<html>home')
  go(q.url === '/sso-app' ? web.replace('127.0.0.1', 'localhost') + '/idp' : '/login')
})
await new Promise((r) => app.listen(0, r))
const web = `http://127.0.0.1:${app.address().port}`, U = { admin: ['qa', '', 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'] }
const login = async () => { const b = await import(BM + '?a'); return { b, home: async (s) => (await b.text(s.page)).includes('home'), out: async (k, f) => console.log(k + ':' + await f().catch((e) => e.message)) } }
'@ + "`n"
function NodeT($n, $js) { $f = Join-Path (Kd) "$n.mjs"; [IO.File]::WriteAllText($f, "const BM = '$([Uri]::new("$k/skills/pokey/browser.mjs").AbsoluteUri)', m = await import(BM)`n$js"); @(node $f @args 2>&1) }
# workflow sims: Invoke-Js <name> <js> <workflow>: $jsLib + $js in node, run() = the workflow body (agents mocked)
$jsLib = @'
const _ck = (id, result, extra = {}) => ({ id, subtask_id: 'T1', screen: 's', result, what_was_done: 'w', observed: `o ${id}`, evidence: [], attempts: 1, ...extra })
const _res = (code, checks) => ({ code, checks, findings: [], setup_changes: [], data_created: [] })
const _rep = (localTest, more = {}) => ({ mrs: [{ url: 'https://h/g/api/-/merge_requests/1', repo: 'api', merged: false }], worktrees: ['C:/wt/x1'], done: ['A1'], deferred: [], needsDecision: [], needsEnvFix: [], localTest, needsLiveCheck: [], seed: [], foreignHooks: [], summary: 's', testerGuide: 'https://doc', ...more })
const _merged = (n) => ({ mrs: [{ url: `https://h/g/api/-/merge_requests/${n}`, repo: 'api', merged: true, mergeState: 'MERGED' }] })
const _CFG = 'CONFIG {"roles":{"api":"producer","app":"consumer"},"qaLanes":{"web":{"kind":"web","parallel":5,"followUp":"app"},"api":{"kind":"api","parallel":5,"followUp":"app"},"app":{"kind":"app","devices":"android"}}}'   // the legacy lanes + roles
const _rec = () => ({ ok: true, output: 'RECORDED\n' + _CFG })
const _ok = (output) => ({ ok: true, output, signals: 0, lessonsChanged: [] })
// a recording agent: calls = { label, model, prompt }; record-args RECORDED, ci green, else fn's answer or _ok(dflt)
const _mock = (fn, dflt = '') => { const calls = []; return { calls, agent: async (prompt, o) => { calls.push({ label: o.label, model: o.model, prompt })
  if (/^record-args/.test(o.label)) return _rec()
  if (/^ci:/.test(o.label)) return { done: true, mrs: [{ mr: '1', status: 'success' }] }
  return (await fn(prompt, o)) ?? _ok(dflt) } } }
// every step passes: build and ship return a merged MR
const _pass = async (p, o) => /^record-args/.test(o.label) ? _rec() : /^(build|ship):/.test(o.label) ? _rep({ status: 'PASS', failing: [] }, _merged(1)) : _ok('[]')
const _err = (e) => console.log('error:' + e)
const _n = () => {}
// every sim's args share these; a testy item on lane `lane`, subtask T1
const _kl = { kitDir: 'C:/kit', learn: false }
const _item = (code, lane = 'api', x = {}) => ({ code, title: code, guideFile: 'g.md', lane, subtasks: [{ id: 'T1' }], ...x })
const run = async (args, agent, log, phase, pipeline, parallel) => { __BODY__ }
const pipeline = async (items, ...stages) => Promise.all(items.map(async (a) => { let x = await stages[0](a); for (const s of stages.slice(1)) x = await s(x, a); return x }))
'@
function Invoke-Js($name, $js, $wf) { $f = Join-Path (Kd) "$name.mjs"; [IO.File]::WriteAllText($f, ($jsLib + "`n" + $js).Replace('__BODY__', ([IO.File]::ReadAllText($wf) -replace '(?m)^export const meta', 'const meta'))); @(node $f 2>&1) }
function Complete-Tests {
  if ($env:KIT_TESTS_TIME) { $script:times | Sort-Object s -Descending | Select-Object -First 8 | ForEach-Object { 'TIME {0,5:N1} s  {1}' -f $_.s, $_.what } }
  "$script:fails failure(s)"; exit [int]($script:fails -gt 0)
}
