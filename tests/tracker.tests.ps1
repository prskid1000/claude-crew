#Requires -Version 7
<#
tracker.tests.ps1: task texts rendered from a spec (crafty.ps1 "task spec": description, Items / Decisions checklists, the
parent's subtask items), the prose check of tracker kinds (no local paths); (cap moves) supervise page long flag text, build gate heatmap, unknown workflow args.
Usage: pwsh -NoProfile -File <kit>/tests/tracker.tests.ps1 (or tests/kit-tests.ps1 -Area tracker).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit tracker; $KT = Join-Path $k 'skills/bossy/kitbag.py'; $O = Join-Path $k 'skills/bossy/bossy.ps1'
function KtPy($code) { python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kitbag as k; $code" }
$lp = KtPy "s = {'limits': '', 'format': '', 'required': []}; print([len(k.prose_check(kd, t, s, [])) for kd, t in (('comment-status', 'see ~/notes/a.md'), ('task-description', 'D:\\x\\y.md'), ('decisions', 'https://h/a/b.md ``common/agent-core``'), ('mr-body', '~/x.md'), ('task-description', 'GET /users/5 and /home/dashboard'))])"
Expect "prose: a local path in a tracker text (task-*, comment-*, decisions) is a finding; a URL, repo path or route is not, other kinds unchecked ($lp)" ("$lp".Trim() -eq '[1, 1, 0, 0, 0]')
# task spec (crafty.ps1 "task spec"): one renderer; a checklist adapter and the description fallback get the same items
$ts = Invoke-PsTest taskspec @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $ErrorActionPreference = 'Stop'; Copy-Item $args[1] (Join-Path $script:KitRoot 'skills/crafty')   # templates.md: the prose check
$sp = @{ kind = 'Feature'; title = 'HM — Agents P1'; list = 'L1'; code = 'P1'; problem = 'HM has no agents.'; goal = 'Editors build agents.'; acceptance = @('flag off by default')
  items = @(@{ code = 'S01'; desc = 'Agent tables `agent` (ports X-01)'; mrs = @('https://git/r/-/merge_requests/5') }, @{ code = 'C01'; desc = 'Chat with an agent' })
  links = @(@{ text = 'parent'; url = 'https://t/1' }); decisions = @(@{ id = 'd-20261113-x-ab12'; question = 'Caps?'; answer = '40 turns'; by = 'owner'; at = '2026-11-13T10:00:00Z' }) }
$gold = "**Problem:** HM has no agents.`n`n**Goal:** Editors build agents.`n`n**Items:**`n- S01 · Agent tables agent (ports X-01)`n- C01 · Chat with an agent`n`n**Acceptance:**`n- flag off by default`n`n**Links:** [parent](https://t/1)"
$r = Publish-KitTaskSpec $sp -DryRun
$got = [Collections.Generic.List[string]]::new(); $KitAdapters['tracker']['none']['checklist'] = { param($a) foreach ($i in $a.items) { $got.Add("$($a.name)|$(if ($i.done) { 'x' } else { ' ' })|$($i.text)") } }
$c = Publish-KitTaskSpec $sp; $KitAdapters['tracker']['none'].Remove('checklist')
$sp.title = 'HM — Agents P1 copy'; $sp.newTask = 'fixture'; $f = Publish-KitTaskSpec $sp; $fd = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
$fb = @(foreach ($sn in 'Items', 'Decisions') { if ($fd -match "(?s)<!-- kit:$($sn.ToLower()) -->(.*?)<!-- /kit:") { [regex]::Matches($Matches[1], '(?m)^- \[(.)\] (.+)$') | ForEach-Object { "$sn|$($_.Groups[1].Value)|$($_.Groups[2].Value)" } } })
$bad = try { $sb = $sp.Clone(); $sb.links = @('../brief/x.md'); $null = Publish-KitTaskSpec $sb -DryRun; 'passed' } catch { "$_" }
$bad2 = try { $null = Publish-KitTaskSpec @{ title = 'x'; problem = 'p'; links = @('https://t/2'); goal = 'g'; acceptance = @('a'); items = @(@{ code = 'A'; desc = 'see `D:/Codebase/x.md`' }) } -DryRun; 'passed' } catch { "$_" }
$null = Set-TrackerDescription $f.id ("**Testing doc (human):** [open](https://h)`n`n" + $fd.Replace('**Problem:**', "<!-- kit:delivery -->`nD`n<!-- /kit:delivery -->`n`n<!-- kit:triage -->`nT`n<!-- /kit:triage -->`n`n**Problem:**"))
$u = Publish-KitTaskSpec @{ items = @(@{ code = 'C01'; desc = 'Chat, renamed'; done = $true }, @{ code = 'W01'; desc = 'Web tab' }) } -Task $f.id; $ud = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
$sub = Publish-KitTaskSpec @{ kind = 'Feature'; title = 'Sub one'; code = 'SUB1'; parent = $f.id; newTask = 'x'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'Z1'; desc = 'z' }); acceptance = @('a'); links = @('https://t/3') }
$pl = (__TrA 'create' @{ name = '[Bug] Plain one'; parent = $f.id }).id; $null = Publish-KitTaskSpec @{ subtasks = @(@{ id = $pl; code = 'PL1'; desc = 'Plain one' }) } -Task $f.id
$pd = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
[pscustomobject]@{ gold = ($r.description -eq $gold); name = $r.name; items = (@($got) -join "`n"); fb = ($fb -join "`n"); bad = $bad; bad2 = $bad2; ud = $ud; pd = $pd; sub = $sub.parent } | ConvertTo-Json -Compress
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'), (Join-Path $src 'skills/crafty/templates.md'))
$ts = ("$($ts | Select-Object -Last 1)" | ConvertFrom-Json)
Expect "task spec: the description renders to the golden text (no testing-doc lines before the docs exist), [Kind] name" ($ts.gold -and $ts.name -eq '[Feature] HM — Agents P1')
Expect "task spec: a checklist adapter and the description fallback get the same Items and Decisions ($($ts.items) || $($ts.fb))" ($ts.items -and $ts.items -eq $ts.fb -and $ts.items -match '(?m)^Items\| \|S01 · Agent tables agent \(ports X-01\) · https://git/r/-/merge_requests/5$' -and $ts.items -match '(?m)^Decisions\|x\|ab12 · Caps\? → 40 turns · owner 11-13$')
Expect "task spec: a local path (links or any text) is refused, a link must be a full URL ($($ts.bad) | $($ts.bad2))" ($ts.bad -match "full URL instead of '\.\./brief" -and $ts.bad2 -match 'local path')
Expect 'task spec update: merged by item code (renamed in place, ticked, added), testing-doc links and kit sections kept' ($ts.ud -match '(?s)^\*\*Testing doc \(human\):\*\* \[open\]\(https://h\)\n\n.*<!-- kit:delivery -->\nD\n<!-- /kit:delivery -->\n\n<!-- kit:triage -->\nT\n<!-- /kit:triage -->.*- S01 ·[^\n]+\n- C01 · Chat, renamed\n- W01 · Web tab\n' -and $ts.ud -match '- \[x\] C01 · Chat, renamed' -and $ts.ud -match '- \[ \] W01 · Web tab')
Expect "task spec: a subtask goes on its parent's Items checklist '<code> · <name> · <URL>' ($($ts.sub))" ($ts.pd -match '- \[ \] SUB1 · Sub one · \S+' -and $ts.pd -match '- \[ \] PL1 · Plain one · \S+' -and $ts.pd -match '(?m)^- PL1 · Plain one$' -and $ts.pd -match '- \[ \] S01 · ' -and $ts.sub -match '1/4 done')
# non-ASCII end to end, long text never cut: a command-adapter tracker, crafty.ps1 run with no console (stdout in the OEM code page before the fix)
$fakeTr = Join-Path (Kd) 'fake-tracker.ps1'; Set-Content $fakeTr -Encoding utf8 @'
param($Verb, $Id, $Text)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $db = Join-Path $PSScriptRoot 'fake-tracker.json'
$st = if (Test-Path $db) { Get-Content $db -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { @{} }
switch ($Verb) { 'create' { $st['F-1'] = @{ id = 'F-1'; name = $Id; description = $Text }; '{"id":"F-1"}' } 'view' { $st[$Id] | ConvertTo-Json -Compress } 'describe' { $st[$Id].description = $Text; 'ok' } }
[IO.File]::WriteAllText($db, ($st | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
'@
$fakeCmd = "pwsh -NoProfile -File `"$fakeTr`""
Set-JsonFile "$k/skills/crafty/kit.local.json" @{ tracker = @{ type = 'command'; commands = @{ create = "$fakeCmd create {name} {description}"; view = "$fakeCmd view {id}"; describe = "$fakeCmd describe {id} {text}" } } }
$longDesc = 'Add sample-setup → plan gate for £5 café orders with a step-wording rule (set up sample data, then confirm each step in order, never skip one)'
Set-JsonFile "$(Kd)/u8spec.json" @{ kind = 'Feature'; title = 'Café · £ → é'; newTask = 'fixture'; problem = 'Prices show £ wrong → café.'; goal = 'Fix é · £.'; acceptance = @('£ → ok'); links = @('https://t/9'); items = @(@{ code = 'SG-1'; desc = $longDesc })
  decisions = @(@{ id = 'd-20261113-x-cd34'; question = 'Does the £5 café plan gate also hold for bulk orders that skip the sample-setup step entirely?'; answer = 'yes'; by = 'owner'; at = '2026-11-13T10:00:00Z' }) }
function Invoke-NoConsole([string[]]$Argv) { $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path); foreach ($x in $Argv) { $psi.ArgumentList.Add($x) }
  $psi.RedirectStandardOutput = $psi.RedirectStandardError = $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false; $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $pr = [Diagnostics.Process]::Start($psi); $so = $pr.StandardOutput.ReadToEndAsync(); $null = $pr.StandardError.ReadToEnd(); $pr.WaitForExit(); $so.Result }
$u8c = Invoke-NoConsole @('-NoProfile', '-File', "$k/skills/crafty/crafty.ps1", 'tracker', 'create', '-Spec', "$(Kd)/u8spec.json")
$u8v = Invoke-NoConsole @('-NoProfile', '-File', "$k/skills/crafty/crafty.ps1", 'tracker', 'view', 'F-1')
$u8db = (Get-Content -Raw -Encoding utf8 "$(Kd)/fake-tracker.json" | ConvertFrom-Json).'F-1'
Expect "task spec, non-ASCII: the adapter gets · → £ é intact, the long item uncut in Items and its checklist; kit stdout is UTF-8 with no console ($($u8c.Trim() -replace '\s+', ' '))" (
  $u8db.name -eq '[Feature] Café · £ → é' -and $u8db.description.Contains("- SG-1 · $longDesc") -and $u8db.description.Contains("- [ ] SG-1 · $longDesc") -and $u8db.description.Contains('bulk orders that skip the sample-setup step entirely? → yes') -and $u8db.description -notmatch '…|�' -and
  $u8c -match '"name": "\[Feature\] Café · £ → é"' -and $u8v.Contains("SG-1 · $longDesc"))
# supervise page: a flag over 25 words keeps every word (summary + full text); the flag grid packs as masonry
$lfOut = Invoke-PsTest longflag @'
$null = . $args[0] 6>$null
$dd = @{ flags = @([pscustomobject]@{ level = 'WATCH'; what = 'w1'; action = 'a1' }, [pscustomobject]@{ level = 'ACT'; what = 'DECISION <b>x</b>'; who = 'devy'; action = 'answer it' }) }
$longWhat = 'state file D:\x\qa-runs\r1\run.json: drift: key(s) notes not in the schema (qa-runs:run: dir=*/run.json v0: title runDir items kitDir tracker target mandate left lanes tester envLines localEnv envFixCycles): add them to STATE.md or fix the writer'
$lfFlags = @($dd.flags[0], $dd.flags[1], [pscustomobject]@{ level = 'WATCH'; what = $longWhat; action = ('step ' * 30).Trim() })
$hl = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); flags = $lfFlags })
$cards = @([regex]::Matches($hl, '(?s)<article class=.flag .*?</article>').Value)
"longflag:$(-not @($lfFlags | Where-Object { $fc = Get-KitFlagCells $_; $fw = [Net.WebUtility]::HtmlEncode($fc.problem); $fa = [Net.WebUtility]::HtmlEncode($fc.action); -not @($cards | Where-Object { $_.Contains($fw) -and $_.Contains($fa) }).Count }).Count -and $cards.Count -eq 3 -and $hl -match "<details class=lx><summary>state file run\.json: drift: key\(s\) notes not in the schema \(…\): add them" -and $hl -match 'class=lf>step step' -and $hl -match "fmas style='--cmin:300px' data-mas>" -and $hl -match 'function ms\(\)\{' -and $hl -match 'px below free space in another column')"
'@ @($O)
Expect "supervise page: every flag's problem and Next verbatim on its card, a long one as summary + full text ($lfOut)" ("$lfOut" -match 'longflag:True')
# build gate from its history: a build that started and ended between two sweeps counts; one row per kind (a local env's build = env deploy)
$gtOut = Invoke-PsTest 'gatestats' @'
$null = . $args[0] 6>$null; $t = (Get-Date).Date.AddHours(1); $b = { param($ev, $m, $o, $k, $x) Write-KitLog builds $ev ([ordered]@{ at = $t.AddMinutes($m).ToString('o'); owner = $o; kind = $k; project = 'api' } + $x) }
& $b start 0 a maven-test @{ needGB = 3 }; & $b end 2 a maven-test @{ sec = 120; waitSec = 60 }; & $b end 5 localenv-x maven @{ sec = 30; waitSec = 0 }; & $b end 50 b docker @{ sec = 3600; waitSec = 0 }   # 00:50-01:50: 10 + 50 min over two hours
$g = Get-KitGateStats $t.AddHours(1) @([pscustomobject]@{ name = 'browser rm·web'; gb = 1.25 }, [pscustomobject]@{ name = 'browser hm'; gb = 0.5 }, [pscustomobject]@{ name = 'phone p1'; gb = 2 }); $m = @($g.rows | Where-Object name -eq 'maven test')[0]
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); mem = @{ AvailGB = 20 }; stats = [pscustomobject]@{ keepFree = 10; gate = $g; now = @{ seats = 1; seatsMax = 4 } } })
"$($g.running) $(@($g.rows.name -match '^(env deploy|maven)' | Sort-Object) -join ',') $($m.done)/$($m.waitMax)/$($m.peakGB)/$([array]::IndexOf(@($m.hours | ForEach-Object { $_[1] -gt 0 }), $true))/$(@(@($g.rows | Where-Object name -eq 'docker')[0].hours[21..22] | ForEach-Object { $_[1] }) -join ',') $($h -match "<span class=gn[^>]*>maven test</span>" -and $h -match "builds today</title>.*?</svg>$($g.today)</span>" -and $h -match "<div class='gk gh'><span class=gn>kind · hour</span><span class='gs0 hrs' aria-hidden=true>.*?<b class=nw style='grid-column:23/span 2'>now</b>" -and $h -match "class='gc z' title='maven test: 0 running builds'><svg class='ic i-run hit'.*?</svg>0<" -and $h -match "<div class=gk><span class=gn[^>]*>maven test</span><span class='gs hm'[^>]*>(<i[^>]*></i>){24}</span>(<span class='gc[^']*'[^>]*>.*?</span>){6}</div>" -and $h -match "title='01:00 &#183; maven test &#183; 1 builds &#183; 2 build-min &#183; max wait 1 min'" -and $h -match "<i class=nw style='--a:0%' title='02:00 \(now\)") $($h -match 'test browsers 2 \(1\.8 GB, leased\)')"
'@ @($O)   # other areas' gated checks of this test kit add rows of their own
Expect "gate card: history counts a build between sweeps, a row per kind, its busy minutes in the hours it spans; browsers in the lease row ($gtOut)" ("$gtOut" -eq '0 env deploy,maven test 1/1/3/22/10,50 True True')
# crafty.ps1 tracker bug (lib.ps1 Add-KitAskBug)
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $env:KIT_TRACKER_TYPE = 'none'; $bk = Kd
$ak = (pwsh @np $D tracker create -List L1 -Name 'Ask help routing' -Description 'a' -NewTask fixture | ConvertFrom-Json).id
'help answers link other product pages (vector.py:120)' | Set-Content "$bk/w1.md"; 'second defect' | Set-Content "$bk/w2.md"; 'same root cause' | Set-Content "$bk/w3.md"
$tbg = { param($key, $name, $file, $sig) pwsh @np $D tracker bug -Parent $ak -Key $key -Name $name -File "$bk/$file" -Signature $sig -List L1 | ConvertFrom-Json }
$b1 = & $tbg watch-stg-a '[Bug] Ask help — new defects (1)' w1.md 'vector.py:120'; $b2 = & $tbg qa-run1 '[Bug] staging run — new defects' w2.md 'other.py:9'
$b3 = & $tbg qa-run2 '[Bug] another run' w3.md 'VECTOR.py:120|x.js:1'; 'second defect v2' | Set-Content "$bk/w2.md"; $b4 = & $tbg qa-run1 '[Bug] staging run — new defects' w2.md 'other.py:9'
$bdx = (pwsh @np $D tracker view $b1.id | ConvertFrom-Json).description; $null = pwsh @np $D tracker status $b1.id closed; $b5 = & $tbg qa-run3 '[Bug] Ask help — later' w2.md 'none.py:0'
Expect "tracker bug: one open [Bug] per ask, titles; re-run replaces its section; known signature = duplicate line; closed -> new one ($($b1.action) $($b2.action) $($b3.action) $($b4.action) $($b5.action))" ($b1.action -eq 'created' -and $b2.id -eq $b1.id -and $b2.action -eq 'appended' -and $b3.id -eq $b1.id -and @($b3.duplicates).Count -eq 1 -and $bdx -notmatch 'same root cause' -and $bdx -match 'Duplicates.*qa-run2 \(`VECTOR\.py:120`\)' -and $bdx -match 'second defect v2' -and $bdx -notmatch 'second defect\r?\n' -and ([regex]::Matches($bdx, '\[kit:bug:qa-run1\]')).Count -eq 1 -and $b5.action -eq 'created' -and $b5.id -ne $b1.id)
$sg = & { . (Lib); $h = ConvertTo-KitBugNorm 'see src/my\_mod.py:12 and vector.py:1205, GET https://h.x/api/orders/5/lines'
  "$(Test-KitBugSig $h 'my_mod.py:12')$(Test-KitBugSig $h 'mod.py:12')$(Test-KitBugSig $h 'vector.py:120')$(Test-KitBugSig $h 'https://h.x/api/orders')$(Test-KitBugSig $h 'https://h.x/api/orders/9/lines')"
  (Get-KitDefectSigs ([pscustomobject]@{ observed = 'connect api.example.com:443 refused; https://app.example/#/orders/7?x=1 and https://app.example/#top'; cause = '' })) -join ' ' }
$kb = pwsh @np $D tracker bug -Parent $ak -Key 'watch-stg-err [x]' -Name '[Bug] k' -File "$bk/w3.md" -Signature 'zz.py:1' -List L1 | ConvertFrom-Json; $kc = pwsh @np $D tracker bug -Parent $ak -Key 'watch-stg-err [x]' -Name '[Bug] k' -File "$bk/w3.md" -Signature 'zz.py:1' -List L1 | ConvertFrom-Json
Expect "bug signatures: whole matches, escaped read-back, no host:port, hash routes kept; a key with ] stays one section ($($sg -join ' | '))" ($sg[0] -eq 'TrueFalseFalseFalseTrue' -and $sg[1] -eq 'https://app.example/#/orders/7' -and ([regex]::Matches((pwsh @np $D tracker view $kc.id | ConvertFrom-Json).description, 'kit:bug:watch-stg-err_x')).Count -eq 1 -and $kb.id -eq $kc.id)
Remove-Item Env:KIT_TRACKER_TYPE
# (cap move) an unknown workflow arg is refused, never dropped (a coordinator's notes reached no tester)
$ua = foreach ($w in @(@('buildy', "{ brief: 'b', agents: [{ id: 'X1', items: 'A1' }], notes: 'n' }"), @('testy', "{ runDir: 'r', notes: 'n' }"), @('testy', "{ skipClose: 1, driveParent: 'd' }"), @('tidy', "{ notes: 'n' }"))) { Invoke-Js "ua-$($w[0])" "run($($w[1]), _n, _n, _n).catch(_err)" (Join-Path $src "workflows/$($w[0]).js") }
Expect "workflows refuse unknown args ($ua)" ("$ua" -match 'buildy\.js args refused: unknown notes;' -and "$ua" -match 'testy\.js args refused: unknown notes; free text for testers goes in args\.context' -and "$ua" -match 'tidy\.js args refused: unknown notes' -and "$ua" -notmatch 'unknown (skipClose|driveParent)')
Remove-TestKit $k
Complete-Tests
