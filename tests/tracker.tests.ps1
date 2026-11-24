#Requires -Version 7
<#
tracker.tests.ps1: task texts rendered from a spec (crafty.ps1 "task spec": description, Items / Decisions checklists, the
parent's subtask items), the prose check of tracker kinds (no local paths); (cap moves) supervise page long flag text, build gate heatmap, unknown workflow args, tracker comment -Spec, board msg, board check claims, the online check, the heartbeat cron line and the OS timer's place in supervise (adapters/os_timer.ps1), the area scope (globs, wt commit, buildy prompts, the OUT-OF-AREA watch).
Usage: pwsh -NoProfile -File <kit>/tests/tracker.tests.ps1 (or tests/kit-tests.ps1 -Area tracker).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit tracker; $KT = Join-Path $k 'skills/bossy/kitbag.py'; $O = Join-Path $k 'skills/bossy/bossy.ps1'
function KtPy($code) { python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kitbag as k; $code" }
$lp = KtPy "s = {'limits': '', 'format': '', 'required': []}; print([len(k.prose_check(kd, t, s, [])) for kd, t in (('comment-status', 'see ~/notes/a.md'), ('task-description', 'D:\\x\\y.md'), ('decisions', 'https://h/a/b.md ``common/agent-core``'), ('mr-body', '~/x.md'), ('task-description', 'GET /users/5 and /home/dashboard'))])"
Expect "prose: a local path in a tracker text (task-*, comment-*, decisions) is a finding; a URL, repo path or route is not, other kinds unchecked ($lp)" ("$lp".Trim() -eq '[1, 1, 0, 0, 0]')
# (cap move) board messages: { kind, to, text, ref }, checked by board msg
$bm1 = pwsh -NoProfile -File $O board msg -Agent m1 -To m2 -Kind dispute -Ref 'web!5' -Text 'own, not new' 2>&1 | Out-String
$null = pwsh -NoProfile -File $O board msg -Agent m1 -To m2 -Kind gossip -Text x 2>&1; $bmKindCode = $LASTEXITCODE
$null = pwsh -NoProfile -File $O board msg -Agent m1 -To m2 -Text ('y' * 2001) 2>&1; $bmLongCode = $LASTEXITCODE
$bmRow = Get-Content -Raw (Join-Path (TkPath $k board) 'inbox/m2.jsonl') | ConvertFrom-Json
$bmIn = pwsh -NoProfile -File $O board inbox -Agent m2 2>&1 | Out-String
Expect "board msg: the row is { at, from, to, kind, text, ref, read }; an unknown kind and a text over 2000 chars refused (2); inbox shows kind and ref ($($bmIn.Trim()))" ($bm1 -match 'sent to m2' -and (@($bmRow.PSObject.Properties.Name) -join ',') -eq 'at,from,to,kind,text,ref,read' -and $bmKindCode -eq 2 -and $bmLongCode -eq 2 -and $bmIn -match 'from m1 \[dispute\]: own, not new \(ref web!5\)')
# (cap move) board check claims the worktree on the caller's row (cleanup's sweep keeps live claims); twice = one claim; another agent: OTHER WRITER
$cwt = Join-Path (Kd) 'cwt'; $jw = pwsh -NoProfile -File $O board join -Agent CW -Run cw | Out-String; $sw1 = if ($jw -match 'SESSION (\S+)') { $Matches[1] }
foreach ($n in 1, 2) { $null = pwsh -NoProfile -File $O board check -Worktree $cwt -Session $sw1 }
$jw2 = pwsh -NoProfile -File $O board join -Agent CW2 -Run cw | Out-String; $cwo = pwsh -NoProfile -File $O board check -Worktree $cwt -Session $(if ($jw2 -match 'SESSION (\S+)') { $Matches[1] }) | Out-String; $cwc = $LASTEXITCODE
Expect "board check: claims the worktree once on the caller's row; a second agent gets OTHER WRITER ($cwo)" ("$((Get-Content (Join-Path (TkPath $k board) "$sw1.json") -Raw | ConvertFrom-Json).worktrees)" -eq $cwt -and $cwc -eq 1 -and $cwo -match 'OTHER WRITER: CW ')
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
$bad2 = try { $null = Publish-KitTaskSpec @{ title = 'x'; problem = 'p'; links = @('https://t/2'); goal = 'g'; acceptance = @('a'); items = @(@{ code = 'A'; desc = 'see `D:/work/x.md`' }) } -DryRun; 'passed' } catch { "$_" }
$itemsCap = try { $null = Publish-KitTaskSpec @{ title = 'x'; problem = 'p.'; goal = 'g.'; acceptance = @('a'); links = @('https://t/2'); items = @(1..40 | ForEach-Object { @{ code = "I$_"; desc = 'one two three four five six' } }) } -DryRun; 'passed' } catch { "$_" }
$probCap = try { $null = Publish-KitTaskSpec @{ title = 'x'; problem = ('word ' * 230); goal = 'g.'; acceptance = @('a'); links = @('https://t/2'); items = @(@{ code = 'A'; desc = 'a' }) } -DryRun; 'passed' } catch { "$_" }
$null = Set-TrackerDescription $f.id ("**Testing doc (human):** [open](https://h)`n`n" + $fd.Replace('**Problem:**', "<!-- kit:delivery -->`nD`n<!-- /kit:delivery -->`n`n<!-- kit:triage -->`nT`n<!-- /kit:triage -->`n`n**Problem:**"))
$u = Publish-KitTaskSpec @{ items = @(@{ code = 'C01'; desc = 'Chat, renamed'; done = $true }, @{ code = 'W01'; desc = 'Web tab' }) } -Task $f.id; $ud = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
$sub = Publish-KitTaskSpec @{ kind = 'Feature'; title = 'Sub one'; code = 'SUB1'; parent = $f.id; newTask = 'x'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'Z1'; desc = 'z' }); acceptance = @('a'); links = @('https://t/3') }
$pl = (__TrA 'create' @{ name = '[Bug] Plain one'; parent = $f.id }).id; $null = Publish-KitTaskSpec @{ subtasks = @(@{ id = $pl; code = 'PL1'; desc = 'Plain one' }) } -Task $f.id
$pd = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
[pscustomobject]@{ gold = ($r.description -eq $gold); name = $r.name; items = (@($got) -join "`n"); fb = ($fb -join "`n"); bad = $bad; bad2 = $bad2; itemsCap = $itemsCap; probCap = $probCap; ud = $ud; pd = $pd; sub = $sub.parent } | ConvertTo-Json -Compress
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'), (Join-Path $src 'skills/crafty/templates.md'))
$ts = ("$($ts | Select-Object -Last 1)" | ConvertFrom-Json)
Expect "task spec: the description renders to the golden text (no testing-doc lines before the docs exist), [Kind] name" ($ts.gold -and $ts.name -eq '[Feature] HM — Agents P1')
Expect "task spec: a checklist adapter and the description fallback get the same Items and Decisions ($($ts.items) || $($ts.fb))" ($ts.items -and $ts.items -eq $ts.fb -and $ts.items -match '(?m)^Items\| \|S01 · Agent tables agent \(ports X-01\) · https://git/r/-/merge_requests/5$' -and $ts.items -match '(?m)^Decisions\|x\|ab12 · Caps\? → 40 turns · owner 11-13$')
Expect "task spec: a local path (links or any text) is refused, a link must be a full URL ($($ts.bad) | $($ts.bad2))" ($ts.bad -match "full URL instead of '\.\./brief" -and $ts.bad2 -match 'local path')
Expect "task spec: the generated Items list never counts toward the 200-word cap (40 items pass); a 230-word problem is refused ($($ts.itemsCap) | $($ts.probCap))" ($ts.itemsCap -eq 'passed' -and $ts.probCap -match '1 prose finding.*\(all\): 2\d\d words')
Expect 'task spec update: merged by item code (renamed in place, ticked, added), testing-doc links and kit sections kept' ($ts.ud -match '(?s)^\*\*Testing doc \(human\):\*\* \[open\]\(https://h\)\n\n.*<!-- kit:delivery -->\nD\n<!-- /kit:delivery -->\n\n<!-- kit:triage -->\nT\n<!-- /kit:triage -->.*- S01 ·[^\n]+\n- C01 · Chat, renamed\n- W01 · Web tab\n' -and $ts.ud -match '- \[x\] C01 · Chat, renamed' -and $ts.ud -match '- \[ \] W01 · Web tab')
Expect "task spec: a subtask goes on its parent's Items checklist '<code> · <name> · <URL>' ($($ts.sub))" ($ts.pd -match '- \[ \] SUB1 · Sub one · \S+' -and $ts.pd -match '- \[ \] PL1 · Plain one · \S+' -and $ts.pd -match '(?m)^- PL1 · Plain one$' -and $ts.pd -match '- \[ \] S01 · ' -and $ts.sub -match '1/4 done')
# tracker vocabulary from config: kindPrefixes, nameFormat, taskTemplate labels, process.docs labels; a subtask's required sections follow the template
Set-JsonFile "$k/skills/crafty/kit.local.json" @{ tracker = @{ kindPrefixes = @{ feature = 'FEAT:'; bug = 'DEFECT:' }; nameFormat = '{prefix} {title} ({code})'
    taskTemplate = @(@{ key = 'problem'; label = 'Context'; required = $true }, @{ key = 'goal'; label = 'Outcome'; required = $true }, @{ key = 'items'; label = 'Work'; required = 'subtask' }, @{ key = 'acceptance'; label = 'Done when'; required = $true }, @{ key = 'links'; label = 'Refs'; required = $false }) }
  process = @{ docs = @(@{ key = 'testing-doc'; label = 'QA plan' }) } }
$tv = Invoke-PsTest taskvocab @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $ErrorActionPreference = 'Stop'
$sp = @{ kind = 'feature'; title = 'Cart'; code = 'C1'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'A'; desc = 'a' }); acceptance = @('x'); links = @('https://t/1'); docs = @{ 'testing-doc' = 'https://d/q' } }
$r = ConvertTo-KitTaskRender $sp ''
"name:$($r.name)"; "desc:$($r.description -replace "`n", '\n')"
"gaps:$((Get-KitTaskTextGaps 'x' "Context: a`nOutcome: b`nDone when: c" -Subtask) -join ',')|$((Get-KitTaskTextGaps 'DEFECT: y' 'z' -Subtask).Count)|$(Test-KitKindName 'FEAT: z')|$(Test-KitKindName '[Feature] z')"
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'))
Remove-Item "$k/skills/crafty/kit.local.json"
$tvd = "$($tv -match '^desc:')"
Expect "tracker vocabulary: kindPrefixes + nameFormat name, taskTemplate labels, process.docs labels in the description; template gaps (subtask Work, Refs optional), a bug prefix skips them ($($tv -join ' | '))" ($tv -contains 'name:FEAT: Cart (C1)' -and $tvd.StartsWith('desc:**QA plan:** [open](https://d/q)\n\n**Context:** p.\n\n**Outcome:** g.\n\n**Work:**\n- A · a\n\n**Done when:**\n- x\n\n**Refs:** https://t/1') -and $tv -contains 'gaps:Work|0|True|False')
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
# supervise page: a flag over 25 words keeps every word (summary + full text); every flag row has a kind, who and age (owner
# 2026-11-19): ATTENTION <task>: its task is the who, no kind: the first word, no who: coordinator, age since first seen (flagSeen)
$lfOut = Invoke-PsTest longflag @'
$null = . $args[0] 6>$null
$dd = @{ flags = @([pscustomobject]@{ level = 'WATCH'; what = 'w1'; action = 'a1' }, [pscustomobject]@{ level = 'ACT'; what = 'DECISION <b>x</b>'; who = 'devy'; action = 'answer it' }) }
$longWhat = 'state file D:\x\qa-runs\r1\run.json: drift: key(s) notes not in the schema (qa-runs:run: dir=*/run.json v0: title runDir items kitDir tracker target mandate left lanes tester envLines localEnv envFixCycles): add them to STATE.md or fix the writer'
$lfFlags = @($dd.flags[0], $dd.flags[1], [pscustomobject]@{ level = 'WATCH'; what = $longWhat; action = ('step ' * 30).Trim() }, [pscustomobject]@{ level = 'ACT'; what = 'ATTENTION t584a: CI task not closed: job failed'; action = 'fix CI' }, [pscustomobject]@{ level = 'WATCH'; what = 'guard blocked 6 commands in the last hour'; action = 'x'; kind = 'GUARD'; who = (Get-KitDenyWho ([pscustomobject]@{ session = '5bdd82c4-35e0' }) @([pscustomobject]@{ name = 'A3 (checky)'; tx = 'C:/p/5bdd82c4-35e0.jsonl' })) })
$now = Get-Date; $st = @{ flagSeen = @{ (Get-KitFlagKey 'w1') = @{ first = $now.AddMinutes(-30).ToString('o'); last = $now.AddMinutes(-15).ToString('o') }; gone = @{ first = $now.AddHours(-5).ToString('o'); last = $now.AddHours(-3).ToString('o') } } }
Set-KitFlagAge $lfFlags $st $now
$hl = Format-KitSuperviseHtml ([pscustomobject]@{ at = $now.ToString('o'); flags = $lfFlags })
$rows = @([regex]::Matches($hl, "(?s)<tr class='f fr [A-Z]+'>.*?</tr>").Value)
"longflag:$(-not @($lfFlags | Where-Object { $fc = Get-KitFlagCells $_; $fw = [Net.WebUtility]::HtmlEncode($fc.problem); $fa = [Net.WebUtility]::HtmlEncode($fc.action); -not @($rows | Where-Object { $_.Contains($fw) -and $_.Contains($fa) }).Count }).Count -and $rows.Count -eq 5 -and $hl -match "<details class=lx><summary>state file run\.json: drift: key\(s\) notes not in the schema \(…\): add them" -and $hl -match 'class=lf>step step' -and $hl -match 'function ms\(\)\{')"
"blank:$(@($rows | Where-Object { $_ -match '<td><span class=m>—</span></td>' }).Count) w1:$(@($rows -match '>W1<.*>coordinator<.*30 min').Count) att:$(@($rows -match '>ATTENTION<.*>t584a<.*>CI task not closed: job failed<').Count) guard:$(@($rows -match '>GUARD<.*>A3<').Count) seen:$(@($st.flagSeen.Keys) -join ',' -match 'gone') disk:$((Get-KitFlagCells ([pscustomobject]@{ level = 'WATCH'; what = 'DISK C: 5 GB free' })).who)."
'@ @($O)
Expect "supervise page: every flag's problem and Next verbatim in its row, a long one as summary + full text; no row has an empty kind, who or age ($lfOut)" ("$lfOut" -match 'longflag:True' -and "$lfOut" -match 'blank:0 w1:1 att:1 guard:1 seen:False disk:\.')
# build gate from its history: a build that started and ended between two sweeps counts; one row per kind (a local env's build = env deploy)
$gtOut = Invoke-PsTest 'gatestats' @'
$null = . $args[0] 6>$null; $t = (Get-Date).Date.AddHours(1); $b = { param($ev, $m, $o, $k, $x) Write-KitLog builds $ev ([ordered]@{ at = $t.AddMinutes($m).ToString('o'); owner = $o; kind = $k; project = 'api' } + $x) }
& $b start 0 a maven-test @{ needGB = 3 }; & $b end 2 a maven-test @{ sec = 120; waitSec = 60 }; & $b end 5 localenv-x maven @{ sec = 30; waitSec = 0 }; & $b end 50 b docker @{ sec = 3600; waitSec = 0 }   # 00:50-01:50: 10 + 50 min over two hours
$g = Get-KitGateStats $t.AddHours(1) @([pscustomobject]@{ name = 'browser rm·web'; gb = 1.25 }, [pscustomobject]@{ name = 'browser hm'; gb = 0.5 }, [pscustomobject]@{ name = 'phone p1'; gb = 2 }); $m = @($g.rows | Where-Object name -eq 'maven test')[0]
$h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $t.AddHours(1).ToString('o'); mem = @{ AvailGB = 20 }; stats = [pscustomobject]@{ keepFree = 10; gate = $g; now = @{ seats = 1; seatsMax = 4 } } })
"$($g.running) $(@($g.rows.name -match '^(env deploy|maven)' | Sort-Object) -join ',') $($m.done)/$($m.waitMax)/$($m.peakGB)/$([array]::IndexOf(@($m.hours | ForEach-Object { $_[1] -gt 0 }), $true))/$(@(@($g.rows | Where-Object name -eq 'docker')[0].hours[21..22] | ForEach-Object { $_[1] }) -join ',') $($h -match "<b>$($g.today)</b><span>builds today</span>" -and $h -match "<div class='gk mb'><span class=gn[^>]*>maven test(?:<span class=och>(?:<span class=chip>[^<]*</span>)+</span>)?</span><span data-mv=b class='gs hm'[^>]*>(<i[^>]*>[^<]*</i>){24}</span>(<span class='gc[^']*' data-mv=b>[^<]*</span>){5}</div>" -and $h -match "title='01:00 &#183; maven test &#183; 1 builds &#183; 2 build-min &#183; max wait 1 min'" -and $h -match "<i class=nw style='--a:0%' title='02:00 \(now\)") $($h -match '<b>2</b><span>test browsers &#183; 1.8 GB</span>')"
'@ @($O)   # other areas' gated checks of this test kit add rows of their own
Expect "gate card: history counts a build between sweeps, a row per kind, its busy minutes in the hours it spans; browsers in the lease row ($gtOut)" ("$gtOut" -eq '0 env deploy,maven test 1/1/3/22/10,50 True True')
# crafty.ps1 tracker bug (lib.ps1 Add-KitAskBug)
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $env:KIT_TRACKER_TYPE = 'none'; $bk = Kd
$ak = (pwsh @np $D tracker create -Key qa-fx-tracker-110 -List L1 -Name 'Ask help routing' -Description 'a' -NewTask fixture | ConvertFrom-Json).id
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
# only the keyed defect path takes free text (owner, 2026-11-15: a free-text [Bug] for merged MRs); describe never drops a section
$fbFree = pwsh @np $D tracker create -List L1 -Name '[Bug] merged MRs untracked' -NewTask x -Description 'free text' 2>&1 | Out-String; $fbFreec = $LASTEXITCODE
'{"kind":"Bug","title":"merged MRs untracked","list":"L1","newTask":"x","problem":"two merged MRs had no task","links":["https://git.example/r/-/merge_requests/5"]}' | Set-Content "$bk/fb.json"; $fbSp = (pwsh @np $D tracker create -Spec "$bk/fb.json" | ConvertFrom-Json).id
$fbDs = pwsh @np $D tracker describe $fbSp 'free text' 2>&1 | Out-String; $fbDsc = $LASTEXITCODE; $fbSec = "**Problem:** p`n**Goal:** g`n**Acceptance:** a`n**Links:** https://x.example/2"
$fbOwn = (pwsh @np $D tracker create -List L1 -Key qa-fb-own -Name 'Owner shaped' -NewTask x -Description $fbSec | ConvertFrom-Json).id
$fbDo = pwsh @np $D tracker describe $fbOwn 'just text' 2>&1 | Out-String; $fbDoc = $LASTEXITCODE; $null = pwsh @np $D tracker describe $fbOwn "**Testing doc (human):** [open](https://x.example/h)`n`n$fbSec"; $fbKeep = $LASTEXITCODE
$fbF = Join-Path (Kd) 'fb-desc.md'; [IO.File]::WriteAllText($fbF, "**Testing doc (AI):** [open](https://x.example/a)`n`n$fbSec"); $null = pwsh @np $D tracker describe $fbOwn $fbF; $fbKeep += $LASTEXITCODE   # devtools.py finish: the text as a file path
$fbE = (pwsh @np $D tracker create -List L1 -Key qa-fb-empty -Name 'Owner empty' -NewTask x -Description ' ' | ConvertFrom-Json).id; $null = pwsh @np $D tracker describe $fbE '**Testing doc (human):** [open](https://x.example/h)'; $fbKeep += $LASTEXITCODE
Expect "tracker create: free text without -Key ([Bug] too) refused, pointing at -Spec; a [Bug] spec and tracker bug -Key pass; describe: refused on a spec task or when it drops a section, links on top pass ($fbFreec $fbDsc $fbDoc $fbKeep)" ($fbFreec -eq 1 -and $fbFree -match 'rendered from a spec: tracker create -Spec <json>' -and $fbSp -and $b1.id -and $fbDsc -eq 1 -and $fbDs -match 'tracker update' -and $fbDoc -eq 1 -and $fbDo -match 'lacks Problem.*tracker update' -and $fbKeep -eq 0)
$kyMade = pwsh @np $D tracker create -List L1 -Key made-up-1 -Name 'Made up' -NewTask x -Description 'free text' 2>&1 | Out-String; $kyMadec = $LASTEXITCODE
$kyBug = pwsh @np $D tracker bug -Parent $ak -Key run-9 -Name '[Bug] x' -File "$bk/w3.md" -List L1 2>&1 | Out-String; $kyBugc = $LASTEXITCODE
$kyWatch = (pwsh @np $D tracker create -List L1 -Key watch-stg-sig9 -Name '[Bug] stg — sig9' -NewTask x -Description 'free text' | ConvertFrom-Json).id
Expect "tracker create / bug: free text only under a qa- / watch- key; a made-up key refused naming -Spec ($kyMadec $kyBugc)" ($kyMadec -eq 1 -and $kyMade -match "'made-up-1' is neither.*" -and $kyMade -match 'tracker create -Spec' -and $kyBugc -eq 1 -and $kyBug -match 'tracker create -Spec' -and $kyWatch -and $fbOwn)
$kyDocs = @(Select-String -Path @(git -C $src ls-files -- 'skills/*.md' 'agents/*.md' 'workflows/*.js' | ForEach-Object { Join-Path $src $_ }) -Pattern 'tracker (create|bug)\b[^`]*?-Key (\S+)' -AllMatches | ForEach-Object { $_.Matches } | Where-Object { $_.Groups[2].Value -notmatch '^(qa|watch)-' } | ForEach-Object { $_.Value })
Expect "kit docs: every tracker create / bug -Key they teach starts qa- or watch- ($($kyDocs -join ' ; '))" (-not $kyDocs.Count)
# (cap move) tracker comment -Spec: a file or inline JSON, rendered; no text never reaches a CLI (it opened an editor)
'{"status":"closed","why":"W0 done: lanes use staging sql_mode.","link":"https://github.com/o/r/commit/fd14532"}' | Set-Content "$bk/cs.json"
$sf = pwsh @np $D tracker comment $ak -Kind comment-status -Spec "$bk/cs.json" 2>&1 | Out-String; $sfc = $LASTEXITCODE
$si = pwsh @np $D tracker comment $ak -Kind comment-status -Spec '{"status":"in test","why":"deployed.","link":"https://h/x/-/merge_requests/3"}' 2>&1 | Out-String; $sic = $LASTEXITCODE
$sm = pwsh @np $D tracker comment $ak -Kind comment-status -Spec "$bk/none.json" 2>&1 | Out-String; $smc = $LASTEXITCODE
$se = pwsh @np $D tracker comment $ak -Kind comment-status 2>&1 | Out-String; $sec = $LASTEXITCODE; $st = @((pwsh @np $D tracker comments $ak | ConvertFrom-Json).text)
Expect "tracker comment -Spec (file, inline JSON) renders '<status> — <why> · <link>'; a missing file names inline JSON; no text refused ($sfc $sic $smc $sec $sf)" ($sfc -eq 0 -and $sic -eq 0 -and @($st -match '^closed — W0 done.* · https://github\.com/o/r/commit/fd14532').Count -eq 1 -and @($st -match '^in test — deployed\. · https://h/').Count -eq 1 -and $smc -eq 2 -and $sm -match 'file path or inline JSON' -and $sec -eq 2 -and $se -match 'no text')
Remove-Item Env:KIT_TRACKER_TYPE
# (cap move) an unknown workflow arg is refused, never dropped (a coordinator's notes reached no tester)
$ua = foreach ($w in @(@('buildy', "{ brief: 'b', agents: [{ id: 'X1', items: 'A1' }], notes: 'n' }"), @('testy', "{ runDir: 'r', notes: 'n' }"), @('testy', "{ skipClose: 1, driveParent: 'd' }"), @('tidy', "{ notes: 'n' }"))) { Invoke-Js "ua-$($w[0])" "run($($w[1]), _n, _n, _n).catch(_err)" (Join-Path $src "workflows/$($w[0]).js") }
Expect "workflows refuse unknown args ($ua)" ("$ua" -match 'buildy\.js args refused: unknown notes;' -and "$ua" -match 'testy\.js args refused: unknown notes; free text for testers goes in args\.context' -and "$ua" -match 'tidy\.js args refused: unknown notes' -and "$ua" -notmatch 'unknown (skipClose|driveParent)')
# (cap move) online check: every resolved address at once (localhost = ::1 + 127.0.0.1, only IPv4 listens); a closed port is offline
$onl = & { . $O; Remove-Item Env:KIT_OFFLINE -ErrorAction SilentlyContinue; $ls = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $ls.Start(); $lp = $ls.LocalEndpoint.Port
  try { "$(Test-KitOnline localhost 3000 $lp)|$(Test-KitOnline 127.0.0.1 3000 $lp)|$($env:KIT_PARAM_NET_PROBEPORT = $lp; Test-KitOnline 127.0.0.1 3000)" } finally { $ls.Stop(); Remove-Item Env:KIT_PARAM_NET_PROBEPORT }; "$(Test-KitOnline 127.0.0.1 1000 $lp)" }
Expect "online check: any address counts, net.probePort sets the default port, a closed port is offline ($onl)" ("$onl" -eq 'True|True|True False')
# (cap move) heartbeat (owner 2026-11-14: the sweep stopped with every session): one durable recurring cron, the OS timer's sweeps never count as the coordinator's
$hb = Invoke-PsTest beat-cron @'
. $args[0]; $al = Get-KitBeatArmLine; "arm:$($al -match "^CronList has no heartbeat -> CronCreate cron '\*/\d+ \* \* \* \*', recurring: true, durable: true, prompt " -and (Get-KitBeatPrompt) -notmatch 're-arm|one-shot')"
function Read-KitJsonFiles { @([pscustomobject]@{ status = 'working'; beat = (Get-Date).ToString('o') }) }; function Get-KitLastActivity { Get-Date }
Write-KitAtomic (Get-KitPath supervise-state -Create) (@{ nextBeat = 5; coordAt = (Get-Date).AddMinutes(-40).ToString('o'); report = @{ at = (Get-Date).ToString('o') } } | ConvertTo-Json)
"coord:$((Get-KitBeatOverdue) -match '^heartbeat OVERDUE 2[45] min: .*CronCreate')"
'@ @($O)
Expect-Each $hb 'heartbeat: # (arm: the CronCreate call, recurring + durable, the prompt has no re-arm; coord: overdue counts the coordinator''s sweeps against heartbeatMinutes, not the OS timer''s)' 'arm', 'coord'
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $sr = Join-Path (Kd) 'scope-repo'; New-Item -ItemType Directory -Force "$sr/src", "$sr/specs" | Out-Null
'a' | Set-Content "$sr/specs/a.cy.js"; Save-GitRepo $sr base; git -C $sr checkout -q -b b1; Set-Content (Join-Path $sr '.git/claude-scope') "specs/**"
'b' | Set-Content "$sr/specs/b.cy.js"; $c1 = pwsh @np $D wt commit -Dir $sr -Message 'test: add the b spec' 2>&1 | Out-String; $e1 = $LASTEXITCODE
'x' | Set-Content "$sr/src/Inv.java"; $c2 = pwsh @np $D wt commit -Dir $sr -Message 'fix: change the service' 2>&1 | Out-String; $e2 = $LASTEXITCODE
$wid = "$(pwsh @np $O decide record -Gate scope -Item b1 -Question 'src in a spec area?' -Answer yes -Source chat 2>&1)" -replace '(?s)^.*RECORDED (\S+).*$', '$1'
$null = pwsh @np $D wt commit -Dir $sr -Message 'fix: change the service' -ScopeOk $wid 2>&1; $e3 = $LASTEXITCODE
$ap = Invoke-Js area-paths @'
const fn = async (p, o) => /^build/.test(o.label) ? _rep({ status: 'PASS', failing: [] }) : /^ship/.test(o.label) ? _rep({ status: 'PASS', failing: [] }, _merged(1)) : undefined
const m = _mock(fn, '[]'); await run({ ..._kl, brief: 'C:/b/w.md', mandate: ['m'], agents: [{ id: 'W2c', items: 'A1', area: 'specs', paths: ['specs/**'] }] }, m.agent, _n, _n, pipeline).catch(_err)
const p = (l) => (m.calls.find((c) => c.label.startsWith(l)) || {}).prompt || ''
console.log([/AREA PATHS: wt lease -Scope 'specs\/\*\*'/.test(p('build')), /wt lease -Repo <its repo> -Branch <its source branch> -Agent \S+ .*merge <wt> <iid> --scope 'specs\/\*\*'; at the end .*wt release -Agent/.test(p('ship'))].join(' '))
'@ (Join-Path $src 'workflows/buildy.js')
Expect "buildy: agents[].paths reach the build (wt lease -Scope) and ship (lease, merge --scope, release) prompts ($ap)" ("$ap".Trim() -eq 'true true')
Expect "wt commit: area files pass; a file outside is refused naming it; the owner's scope word (decide record -Gate scope) lets it through ($e1 $e2 $e3)" ($e1 -eq 0 -and $e2 -eq 1 -and $c2 -match 'commit refused: 1 file\(s\) outside the area \(specs/\*\*\): src/Inv\.java' -and $e3 -eq 0 -and (git -C $sr log -1 --format=%s) -eq 'fix: change the service')
# (cap moves from guard) malformed hook input, a body file in the shared temp root, background loops
$D = Join-Path $k 'skills/crafty/crafty.ps1'
$gl = (@{ tool_name = 'Write'; tool_input = @{ file_path = "$(TkPath $k runtime)/work/x2/a.md" } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
$dd = pwsh @np $D dir -Agent 'B 1' -Item T9 -Name 'Run.LOG' 2>&1 | Out-String
Expect 'guard: a write off the layout gets a note naming crafty.ps1 dir; dir: agents/<id>/<item>/<file>, lowercase-kebab' ($gl -match 'additionalContext.*kit layout: runtime/work/x2/a\.md.*dir -Agent' -and $gl -notmatch 'deny' -and $dd.Trim() -match '[\\/]work[\\/]agents[\\/]b-1[\\/]t9[\\/]run\.log$')
$gbad = '{not json' | Px $D guard | Out-String
$gnone = '' | Px $D guard | Out-String
Expect 'guard: malformed hook input denies, empty input allows' ($gbad -match '"permissionDecision":"deny"' -and -not $gnone.Trim())
$gt = (@{ tool_name = 'Write'; tool_input = @{ file_path = '/tmp/mr-body.md' } } | ConvertTo-Json -Compress) | Px $D guard | Out-String
Expect 'guard: a Write of a body file to the shared temp root is denied, naming crafty.ps1 dir' ($gt -match '"deny"' -and $gt -match 'shared temp root.*dir -Agent')
$bgc = foreach ($c in @('until curl -s x; do sleep 5; done', 1), @("cd x; cat > /dev/null; python - <<'EOF'`nEOF", 1), @('until x; do sleep 5; done', 0), @('timeout 5 curl x; until curl -s x; do sleep 2; done', 1), @('git log | cat', 1), @("python - <<'PY'`nprint(1)`nPY", 1), @('for i in $(seq 1 20); do sleep 5; done', 1), @('timeout 600 bash -c "until x; do sleep 5; done"', 1), @("cat <<'EOF' > n.md`nx`nEOF", 1)) {
  "$(((@{ tool_name = 'Bash'; tool_input = @{ command = $c[0]; run_in_background = [bool]$c[1] } } | ConvertTo-Json -Compress) | Px $D guard | Out-String) -match 'background shell may never end')" }
Expect "guard: a background sleep loop with no bound or a stdin read gets a note; bounded, foreground or a heredoc into a file: none ($bgc)" (($bgc -join ' ') -eq 'True True False True False False False False False')
# (cap move from kitbag) load(): git excludes
$giK = Join-Path (Kd) 'gi-kit'; New-Item -ItemType Directory -Force "$giK/skills/crafty", "$giK/skills/orgskill" | Out-Null; git -C $giK init -q
'x' | Set-Content "$giK/kept.md"; 'x' | Set-Content "$giK/stray.json"; 'x' | Set-Content "$giK/skills/orgskill/SKILL.md"; '{"localOnly":["skills/orgskill"]}' | Set-Content "$giK/skills/crafty/kit.local.json"
"stray.json`nskills/orgskill/" | Add-Content "$giK/.git/info/exclude"
$giF = KtPy "print(','.join(k.load(r'$giK').files))"
Expect 'load: a .git/info/exclude stray is no kit file (org-term scan); a localOnly overlay stays' ($giF -match 'kept\.md' -and $giF -match 'orgskill/SKILL\.md' -and $giF -notmatch 'stray')
$bl = Px $O board list 2>&1 | Out-String; $blc = $LASTEXITCODE; $bsh = Px $O board show 2>&1 | Out-String
Expect "board list = board show (an agent's guess), exit 0 ($blc)" ($blc -eq 0 -and $bl -eq $bsh -and $bl -match 'board \(active agents\)')
# (cap move from workflows) buildy prompts point devy at its own wave commands
Expect 'devy.md "In a /buildy wave": the loop commands, then ship.md the ship ones buildy prompts point to (start load: ship phase only)' ((Get-Content (Join-Path $src 'agents/devy.md') -Raw) -match '(?s)ENV-FIX and decision pauses: crafty D2 / D1.*In a /buildy wave.*LOCAL LOOP until 0 open bugs.*ship\.md` "In a /buildy' -and (Get-Content (Join-Path $src 'skills/crafty/ship.md') -Raw) -match '(?s)## In a /buildy wave.*never an earlier round removed.*FIX round.*SHIP step.*PIPELINE_FAILED' -and (Get-Content (Join-Path $src 'workflows/buildy.js') -Raw) -match 'SW = `\$\{K\}/ship\.md "In a /buildy wave"`')
Remove-TestKit $k
Complete-Tests
