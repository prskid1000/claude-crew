#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/runtimes.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/runtimes.tests.ps1: runtimes (fake isUp / up / down lines on a flag file): lease, start, stop, an owner-started runtime stays,
# the guard's auto lease, supervise -AutoFix on a dead holder; dashboard liveness: run state, Runs band hours and chips, disk rows' age,
# a failed page or stats source, Trends split cells; usage numbers (prices, outcomes, one row per run, host MRs). Usage: pwsh -NoProfile -File tests/runtimes.tests.ps1
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/container_tests.ps1', 'skills/crafty/adapters/runtimes.ps1')   # copied into every New-TestKit kit
$k = New-TestKit rt; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $O = Join-Path $k 'skills/bossy/bossy.ps1'
$env:KIT_PARAM_RUNTIMEPROBE_ISUPSEC = '120'   # the fake isUp spawns a pwsh: the guard's 5 s probe timed out under a full parallel run (K76)
$flag = Join-Path (Kd) 'fake.up'; $log = Join-Path (Kd) 'fake.log'
$fake = @{ isUp = "if (Test-Path '$flag') { 'up' }"; up = "New-Item -Force '$flag' | Out-Null; Add-Content '$log' up"
  down = "Remove-Item -Force '$flag'; Add-Content '$log' down"; match = 'fakectl\b|tcx' }   # unanchored: the kit tests it at each command's head
& $J @{ runtimes = @{ fake = $fake } } (Join-Path $k 'skills/crafty/kit.local.json')
function Log { if (Test-Path $log) { @(Get-Content $log) -join ',' } else { '' } }
function Reset { Remove-Item $flag, $log -Force -ErrorAction SilentlyContinue; Remove-Item (TkPath $k runtimes) -Recurse -Force -ErrorAction SilentlyContinue }

$u = pwsh @np $D runtime use -Name fake -Agent a1 2>&1 | Out-String; $s = pwsh @np $D runtime status -Name fake -Json | Out-String | ConvertFrom-Json
Expect "runtimes: use starts a stopped runtime and marks it kit-started ($u)" ((Log) -eq 'up' -and $s[0].startedByKit -and $s[0].running -and $s[0].leases[0].agent -eq 'a1')
$null = pwsh @np $D runtime use -Name fake -Agent a2; $r1 = pwsh @np $D runtime release -Name fake -Agent a1 | Out-String
Expect "runtimes: a release with a lease left keeps it running ($r1)" ((Log) -eq 'up' -and (Test-Path $flag) -and $r1 -match '1 left')
$r2 = pwsh @np $D runtime release -Agent a2 | Out-String
Expect "runtimes: the last release stops what the kit started ($r2)" ((Log) -eq 'up,down' -and -not (Test-Path $flag) -and $r2 -match 'stopped')

Reset; New-Item $flag | Out-Null
$null = pwsh @np $D runtime use -Name fake -Agent a1; $r3 = pwsh @np $D runtime release -Name fake -Agent a1 | Out-String
Expect "runtimes: an owner-started runtime is never started or stopped ($r3)" ((Log) -eq '' -and (Test-Path $flag) -and $r3 -match 'not started by the kit')
$bad = Invoke-TestScript $D runtime use -Name nope
Expect "runtimes: an unknown runtime exits 1 ($($bad.code))" ($bad.code -eq 1 -and $bad.out -match 'no kit.local.json runtimes.nope')

Reset
$g = { param($c) pwsh @np $D guard -Json (@{ tool_name = 'PowerShell'; tool_input = @{ command = $c }; agent_type = 'devy'; agent_id = 'abcdef123456' } | ConvertTo-Json -Compress) | Out-String }
$o1 = & $g "`$env:CLAUDE_AGENT='g1'; fakectl run x"
for ($i = 0; $i -lt 50 -and -not (Test-Path $flag); $i++) { Start-Sleep -Milliseconds 200 }
$st = Get-Content (Join-Path (TkPath $k runtimes) 'fake.json') -Raw | ConvertFrom-Json
Expect "runtimes: the guard leases for an agent that forgot, starts the runtime, tells it to release ($o1)" ($o1 -match '"additionalContext"' -and $o1 -match 'release -Name fake -Agent g1' -and $o1 -notmatch 'permissionDecision' -and $st.leases[0].auto -and $st.startedByKit -and (Test-Path $flag))
$o2 = & $g "`$env:CLAUDE_AGENT='g1'; fakectl ps"; $o3 = (& $g 'git commit -m "fakectl notes"') + (& $g 'cat fakectl/README.md') + (& $g 'grep tcx pom.xml') + (& $g 'pwsh -Command "x.ps1 learn -Text ''fakectl run''"'); $o4 = & $g "crafty.ps1 gate -Dir . -Cmd 'fakectl test'"
Expect "runtimes: no second note for a held lease, none for quoted text (also inside -Command), a path or a word mid-command ($o2|$o3)" (-not $o2.Trim() -and -not $o3.Trim())
Expect "runtimes: a gate -Cmd counts, the hook's agent names the lease ($o4)" ($o4 -match 'Agent devy-abcdef12')

# supervise -AutoFix: a lease whose holder died 1 h ago is released and the kit-started runtime stopped
Reset; New-Item $flag | Out-Null
$old = (Get-Date).AddHours(-1).ToString('o')
& $J @{ name = 'fake'; startedByKit = $true; leases = @(@{ agent = 'ghost'; session = ''; at = $old; holderPid = 999999; holderStart = $old; seen = $old }) } (Join-Path (TkPath $k runtimes -Create) 'fake.json')
$sv = pwsh @np $O supervise 2>&1 | Out-String
Expect "runtimes: supervise flags a dead lease without -AutoFix" ($sv -match 'lease of ghost has no live holder' -and (Test-Path $flag))
$sv = pwsh @np $O supervise -AutoFix 2>&1 | Out-String
Expect "runtimes: supervise -AutoFix releases a dead lease and stops the kit-started runtime" ($sv -match 'released the lease of ghost' -and $sv -match 'stopped' -and -not (Test-Path $flag) -and (Log) -eq 'down')
# the sweep probes isUp only when a stop may follow (kit-started, no live lease): 1-4 s a sweep under load
$pr = Invoke-PsTest rt-probe @'
. $args[0]; $global:probes = 0; function Test-KitRuntimeUp { $global:probes++; $true }; function Test-KitRuntimeLease($l) { $l.agent -eq 'alive' }
$f = Get-KitRuntimeFile fake; $now = (Get-Date).ToString('o')
@{ name = 'fake'; startedByKit = $true; leases = @(@{ agent = 'alive'; at = $now }) } | ConvertTo-Json -Depth 4 | Set-Content $f
$l1 = @(Get-KitSuperviseGuardRuntimes -AutoFix) -join '|'; $p1 = $global:probes
@{ name = 'fake'; startedByKit = $true; leases = @(@{ agent = 'gone'; at = $now; seen = $now }) } | ConvertTo-Json -Depth 4 | Set-Content $f
$l2 = @(Get-KitSuperviseGuardRuntimes -AutoFix) -join '|'
"probe:$($p1 -eq 0 -and $l1 -match 'runtime fake: not probed \(kit-started\), 1 lease' -and $global:probes -eq 1 -and $l2 -match 'runtime fake: running')"
'@ @((Join-Path $k 'skills/crafty/lib.ps1'))
Expect-Each $pr 'runtimes: sweep #' 'probe'

# retro 2205: a verb crash names its innermost frame (16 finalize crashes named only the caller's line)
$vst = pwsh -NoProfile -Command ". '$(Lib)'; function Get-TInner { `$null.X() }; function Invoke-T { Get-TInner }; Invoke-KitVerb Invoke-T @()" 2>&1 | Out-String
Expect "Invoke-KitVerb: a crash names the innermost frame ($(($vst -replace '\s+', ' ').Trim()))" ($vst -match 'FAILED: .*\(at Get-TInner')
# run state (owner 2026-11-21: 17 old runs "running" at 60 min an hour): live = own writes within stuckMinutes, a live holder is not enough
$rsd = Join-Path (Kd) 'wf-state'; $rsOut = Invoke-PsTest run-state @'
$null = . $args[0] 6>$null; $n = Get-Date; $root = $args[1]; $me = [pscustomobject]@{ runId = 'x'; holderPid = $PID; holderStart = (Get-KitPidStart $PID) }
$st = { param([int]$ago, [string[]]$ev, $rec = $me, [string]$fn = 'Get-KitRunState') $d = New-Item -ItemType Directory -Force (Join-Path $root "w$ago-$($ev.Count)-$([guid]::NewGuid().ToString('n').Substring(0, 6))")
  $j = Join-Path $d 'journal.jsonl'; Set-Content $j $ev; (Get-Item $j).LastWriteTime = $n.AddMinutes(-$ago); & $fn $d @($rec) @($ev | ForEach-Object { $_ | ConvertFrom-Json }) $n }
$open = '{"type":"started","agentId":"a1","label":"build:A"}'; $done = '{"type":"result","agentId":"a1","result":{"ok":true}}'
@((& $st 1 @($open)), (& $st 30 @($open)), (& $st 90 @($open)), (& $st 30 @($open, $done)), (& $st 1 @($open, '{"type":"finished"}')), (& $st 1 @($open) ([pscustomobject]@{ runId = 'x'; paused = 'now' })), (& $st 1 @($open, $done, '{"type":"started","agentId":"a2","label":"learn","phase":"Learn"}', '{"type":"result","agentId":"a2","result":{}}'))) -join ' '
$dead = [pscustomobject]@{ runId = 'x'; holderPid = 999999; holderStart = '2020-01-01T00:00:00Z' }; $cl = 'Test-KitRunCloseable'
"close: $((& $st 30 @($open, $done) $me $cl), (& $st 30 @($open, $done) $dead $cl), (& $st 130 @($open, $done) $me $cl), (& $st 90 @($open) $dead $cl) -join ' ')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $rsd) | Out-String
Expect "run state: running (fresh write) · stuck (open step, quiet < 3x) · stale (open step quiet 3x, or no open step quiet) · ended (an end event, or Learn done with nothing open: v1-retest stayed Running) · paused, whatever the holder; AutoFix closes a stale run only with no open step after 6x quiet (a dead session: stopped, resumed, never closed) ($($rsOut.Trim()))" ($rsOut.Trim() -eq "running stuck stale stale ended paused ended`r`nclose: False False True False" -or $rsOut.Trim() -eq "running stuck stale stale ended paused ended`nclose: False False True False")
# Runs band: hours = the steps' activity, never start-to-now; a stale run chipped; a board-only run newer than the usage pass: counting
$rbd = & { . $O; $n = [datetime]'2026-01-02T15:00:00'; $sx = [pscustomobject]@{ label = 'build:A'; role = 'devy'; at = $n.AddHours(-5).ToString('o'); min = 30; result = 'stopped'; tok = 5 }
  $run = [pscustomobject]@{ run = 'r9'; id = 'wf_9'; label = 'r9'; kind = 'build'; started = $n.AddHours(-6).ToString('o'); status = 'ended'; state = 'stale'; lastAt = $sx.at; at = $sx.at; tok = 5; steps = @($sx); wall = 60 }
  $ag = @([pscustomobject]@{ name = 'k1 (kitty)'; run = 'kit-x'; state = 'ACTIVE'; since = $n.AddMinutes(-9).ToString('o'); last = $n.ToString('o') })
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = $ag; stats = [pscustomobject]@{ usage = [pscustomobject]@{ at = $n.AddMinutes(-30).ToString('o'); runs = @($run) } } })
  $r9 = [regex]::Match($h, "(?s)data-g='rr-wf_9'.*?</div><div class='gk ag").Value
  "$($r9 -match 'Stale &#183; no end record|Stale · no end record') $(([regex]::Matches($r9, ' [1-9]\d* min active')).Count) $($h -match '>Counting… \(usage as of 14:30\)<')" }
$rov = & { . $O; $n = [datetime]'2026-01-02T15:00:00'; $sx = [pscustomobject]@{ label = 'build:A'; role = 'devy'; at = $n.AddHours(-3).ToString('o'); min = 9; result = 'running'; tok = 5 }
  $run = [pscustomobject]@{ run = 'r8'; id = 'wf_8'; label = 'r8'; kind = 'build'; started = $n.AddHours(-4).ToString('o'); status = 'running'; at = $sx.at; tok = 5; steps = @($sx); wall = 60 }
  $ag = @([pscustomobject]@{ name = 'r8 (workflow)'; run = 'r8'; state = 'FINISHED'; since = $n.AddHours(-3).ToString('o'); last = $n.AddHours(-3).ToString('o') })
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = $ag; stats = [pscustomobject]@{ usage = [pscustomobject]@{ at = $n.AddHours(-3).ToString('o'); runs = @($run) } } })
  "$([regex]::Match($h, "(?s)data-g='rr-wf_8'.{0,600}").Value -notmatch 's-act''>running') $($h -match 'usage as of 01-02 12:00')" }
Expect "runs band: this sweep's ended workflow row beats an older usage pass's running; the band says how old usage is ($rov)" ($rov -eq 'True True')
Expect "runs band: a stale run is chipped, its hours only where its steps ran (1 hour), a board-only run newer than usage says counting ($rbd)" ($rbd -eq 'True 1 True')
# board -> run by proof only (owner 2026-11-21): a reviewer whose transcript is in workflows/wf_7 counts in that run; a standalone revy
# overlapping the wave in time (same name) keeps its own row in the agents kind; a run's title = run name + task codes, mandate in the tooltip
$rsa = & { . $O; $n = [datetime]'2026-01-02T15:00:00'; $sx = [pscustomobject]@{ label = 'review:A1'; role = 'revy'; at = $n.AddHours(-2).ToString('o'); min = 20; result = 'pass'; tok = 5 }
  $a7 = [pscustomobject]@{ brief = 'C:/b/wave-brief.md'; agents = @([pscustomobject]@{ items = 'T-17' }); mandate = @('Owner: fix these long words') }
  $run = [pscustomobject]@{ run = 'bugfix-r7'; id = 'wf_7'; label = (Get-KitRunLabel $a7 'bugfix-r7'); mandate = (Get-KitRunMandate $a7); kind = 'build'; started = $n.AddHours(-3).ToString('o'); status = 'ended'; at = $sx.at; tok = 5; steps = @($sx); wall = 60 }
  $ag = @(foreach ($tx0 in 'C:/p/s1/subagents/workflows/wf_7/agent-r1.jsonl', '') { [pscustomobject]@{ name = 'review-A1 (revy)'; run = ''; state = 'FINISHED'; started = $n.AddMinutes(-135).ToString('o'); ended = $n.AddMinutes(-121).ToString('o'); last = $n.AddMinutes(-121).ToString('o'); tx = $tx0 } })
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = $ag; stats = [pscustomobject]@{ usage = [pscustomobject]@{ at = $n.ToString('o'); runs = @($run) } } })
  "$(([regex]::Matches($h, "data-g='rr-board-solo-review-A1-")).Count) $($h -match "(?s)data-g='rk-agents-[\d-]+'.{0,2500}?rtg aria-expanded=false>revy (·|&#183;) review-A1<") $($run.label) $($h -match "(?s)data-g='rr-wf_7'.{0,200}title='[^']*Owner: fix these long words'")" }
Expect "runs band: board -> run by proof only (transcript in workflows/wf_7: in the run; a same-name standalone revy overlapping it: its own row under agents); run title = run name + codes, mandate in the tooltip ($rsa)" ($rsa -eq '1 True bugfix-r7 · T-17 True')
# kind groups (owner 2026-11-21): a day's ended runs by kind, each a fold with its count, the newest open; today on the running block's axis
$kgo = & { . $O; $n = [datetime]'2026-01-02T15:00:00'; $mk = { param($id, $kind, $h) [pscustomobject]@{ run = $id; id = $id; label = $id; kind = $kind; started = $n.AddHours(-$h - 1).ToString('o'); status = $(if ($h) { 'ended' } else { 'running' }); at = $n.AddHours(-$h).ToString('o'); tok = 5; steps = @(); wall = 60 } }
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); stats = [pscustomobject]@{ usage = [pscustomobject]@{ at = $n.ToString('o'); runs = @((& $mk wf_l build 0), (& $mk wf_b build 3), (& $mk wf_c build 3), (& $mk wf_k kit 1), (& $mk wf_t test 2), (& $mk wf_y test 20)) } } })
  $kg = @([regex]::Matches($h, "<div class='rgg rkg( cl)?' data-g='rk-([a-z]+)-[\d-]+'") | ForEach-Object { "$($_.Groups[2].Value)$($_.Groups[1].Value)" }); $ax = @([regex]::Matches([regex]::Match($h, "(?s)id=sec-runs(?: open)?>.*?(?=<details class='sec top'|<footer)").Value, "<span class='gs0 hrs' aria-hidden=true>(.*?)</span>") | ForEach-Object { $_.Groups[1].Value })
  "$($kg -join ',') $($h -match "(?s)data-g='rk-kit-2026-01-02'.{0,1500}?<small>1 ended</small>.*?data-g='rr-wf_k'") $($ax.Count -eq 3 -and $ax[0] -eq $ax[1] -and $ax[2] -notmatch 'class=nw') $($h -match "build (·|&#183;) 120 min active") $(($lb = Get-KitRunLabel ([pscustomobject]@{ agents = @([pscustomobject]@{ items = 'T-17,T-18,T-19' }) }) 'bugfix-dashboard-labels-wave-twelve-and-more') -match ' · 3 items$' -and $lb.Length -le 48)" }
Expect "runs band: ended runs folded by kind per day (build, test, kit order; newest open; minutes added up), title codes never cut, today on the running block's axis ($kgo)" ($kgo -eq 'build cl,test cl,kit,test True True True True')
# a short agent that left before any status scan: one scan after it left finds its transcript (its tokens on the Runs band)
$env:KIT_TRANSCRIPTS = Join-Path (Kd) 'tx-left'; $lvd = New-Item -ItemType Directory -Force (Join-Path $env:KIT_TRANSCRIPTS 's1/subagents')
$lvj = pwsh @np $O board join -Type revy -Agent LV1 | Out-String; $lvs = if ($lvj -match 'SESSION (\S+)') { $Matches[1] }
@("{""type"":""user"",""text"":""SESSION $lvs   (pass -Session $lvs to beat / check / leave)""}") | Set-Content (Join-Path $lvd 'agent-lv1.jsonl')
@("{""type"":""user"",""text"":""grep: SESSION $lvs""}") | Set-Content (Join-Path $lvd 'agent-aa-other.jsonl'); $null = Px $O board leave -Session $lvs   # another agent that only greps the id: never its transcript
$lvt = & { . $O; @(Get-KitStatusRows | Where-Object { $_.name -like 'LV1 *' } | ForEach-Object { [IO.Path]::GetFileName("$($_.tx)") }) -join ',' }; Remove-Item Env:KIT_TRANSCRIPTS
Expect "status: an agent that left before any scan: one transcript scan after it left, by its own join line (a transcript that only greps the id never matches) ($lvt)" ($lvt -eq 'agent-lv1.jsonl')
$qaq = & { . $O; $n = Get-Date; $rd = New-Item -ItemType Directory -Force (Join-Path (Get-KitPath qa-runs -Create) 'qq-run'); $hm = { param($m) $n.AddMinutes(-$m).ToString('HH:mm') }
  Set-Content (Join-Path $rd 'lead-notes.md') @('# Lead notes', '## Answers (newest last)', "- $(& $hm 30) T1: which tenant for step 3?", "- $(& $hm 25) T2: is the flag on?", "- $(& $hm 20) T2: yes, on", "- $(& $hm 3) T3: a fresh one?", "- $(& $hm 40) T4: done, PASS") -Encoding utf8
  $f = @(Get-KitQaQuestionFlags $n); "$($f.Count) $(@($f.what) -join '|') $($f[0].action -match 'lead-notes add -RunDir .*qq-run -Code T1')" }
Expect "QA QUESTION: an unanswered tester question older than 10 min is a WATCH with the answer command; answered, fresh or no-question lines are not ($qaq)" ($qaq -eq '1 QA QUESTION · qq-run T1: which tenant for step 3? True')
$dsk = & { . $O; $pv0 = [pscustomobject]@{ disks = @(@{ drive = 'C'; at = (Get-Date).AddHours(-3).ToString('o'); free = 1 }, @{ drive = 'D'; at = (Get-Date).AddMinutes(-5).ToString('o'); free = 2 }, @{ drive = 'E'; free = 3 }) }
  @((Get-KitSuperviseSeries @() $pv0).disks | ForEach-Object { $_.drive }) -join ',' }
Expect "disks: no disk line this sweep keeps only rows under 2 heartbeats old, never an old copy as today's ($dsk)" ($dsk -eq 'D')
$epg = & { . $O; function Format-KitSuperviseHtml { throw 'boom-x' }; $hp = [IO.Path]::ChangeExtension((Get-KitPath supervise-report -Create), '.html'); [IO.File]::WriteAllText($hp, 'old page')
  $null = Write-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date); flags = @(); rows = @() }) @() ''; $t = [IO.File]::ReadAllText($hp); "$($t -match 'Supervisor page failed') $($t -match 'boom-x') $($t -notmatch 'old page')" }
$sfl = & { . $O; function Get-KitGateStats { throw 'boom-g' }; $dd = [pscustomobject]@{ at = (Get-Date); flags = @(); rows = @() }; $hp = Write-KitSuperviseHtml $dd @() ''; "$([IO.File]::ReadAllText($hp) -match 'dashboard data not updated this sweep: gate: boom-g') $(@($dd.flags | Where-Object what -match 'boom-g').Count)" }
Expect "a stats source that fails raises a WATCH flag on the page, never a silent stale section, and in the sweep's own flags ($sfl)" ($sfl -eq 'True 1')
Expect "page build failed: a minimal page says so (never the last good page passing as this sweep's) ($epg)" ($epg -eq 'True True True')
# Trends tokens / est. cost (owner 2026-11-21: three sub-cells that did not add up): a day = one total = the sum of its 4 parts over a bar
$sbt = & { . $O; $e = { param($s) [Net.WebUtility]::HtmlEncode("$s") }; $d1 = [pscustomobject]@{ tok = 100; in = 10; out = 20; cr = 60; cw = 10 }; $d2 = [pscustomobject]@{ tok = 50; in = 5; out = 5; cr = 30; cw = 10 }
  $h = Format-KitDayHeat @(@{ n = 'tokens'; v = @(100, 50); sk = 'tokens'; so = @($d1, $d2); t = '150' }) @('2026-01-01', '2026-01-02') 'x'
  $c = @([regex]::Matches($h, "<i class='sdc[^']*' style='--a:\d+%;--sb:linear-gradient\(90deg,(var\(--[\w]+\) [\d.]+% [\d.]+%,?){4}\)' title='[^']*'>(\d+)</i>") | ForEach-Object { $_.Groups[2].Value }); "$($c -join ',') $($h -match '>150</span></div>')" }
Expect "Trends tokens row: a day cell = the sum of its 4 parts (one number, a stacked bar), the 7-day total = the days' sum ($sbt)" ($sbt -eq '100,50 True')
# (moved from layout.tests.ps1: its cap)
$ld = TkPath $k launches -Create
# usage numbers: 5.5 prices (alias, dated and [1m] ids, 1-hour writes), unknown model listed; ok=false / failed event = fail, empty = no field but ok,
# stopped its own rate; one calendar window (a 9-day-old message drops); runs a day by workflow id; coordinator sessions; host-merged MRs
$uy = Join-Path (Kd) 'uy'; $y1 = New-Item -ItemType Directory -Force "$uy/s1/subagents/workflows/wf_y1"; $y2 = New-Item -ItemType Directory -Force "$uy/s1/subagents/workflows/wf_y2"
$ym = { param($id, [string]$model, [int[]]$v, [int]$h1, [datetime]$at) "{`"type`":`"assistant`",`"timestamp`":`"$($at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))`",`"message`":{`"model`":`"$model`",`"id`":`"$id`",`"usage`":{`"input_tokens`":$($v[0]),`"cache_creation_input_tokens`":$($v[3]),`"cache_read_input_tokens`":$($v[2]),`"output_tokens`":$($v[1]),`"cache_creation`":{`"ephemeral_1h_input_tokens`":$h1,`"ephemeral_5m_input_tokens`":$($v[3] - $h1)}}}}" }
$yt = (Get-Date).Date.AddHours(1)
[IO.File]::WriteAllText("$y1/agent-b1.jsonl", ((& $ym 'msg_o' 'claude-sonnet-5-5[1m]' 5000, 0, 0, 0 0 $yt.AddDays(-9)), (& $ym 'msg_n' 'claude-sonnet-5-5[1m]' 100, 10, 1000, 200 0 $yt) -join "`n") + "`n")
[IO.File]::WriteAllText("$y1/agent-b2.jsonl", (& $ym 'msg_a' 'sonnet' 10, 0, 0, 0 0 $yt) + "`n"); [IO.File]::WriteAllText("$y1/agent-b3.jsonl", (& $ym 'msg_b' 'claude-haiku-5-5-20261101' 1000, 100, 0, 0 0 $yt) + "`n")
[IO.File]::WriteAllText("$y1/agent-b4.jsonl", (& $ym 'msg_c' 'gpt-x' 7, 0, 0, 0 0 $yt) + "`n"); [IO.File]::WriteAllText("$y2/agent-c1.jsonl", (& $ym 'msg_d' 'sonnet' 1, 0, 0, 0 0 $yt) + "`n")
[IO.File]::WriteAllText("$uy/main-1.jsonl", ((& $ym 'msg_m' 'claude-opus-5-5' 100, 10, 0, 1000 1000 $yt), (& $ym 'msg_s' 'claude-sonnet-5-5' 0, 0, 0, 0 0 $yt) -join "`n") + "`n")   # a /model switch: parts per model
(@{ type = 'started'; agentId = 'b1'; label = 'build:A' }, @{ type = 'result'; agentId = 'b1'; result = @{ ok = $false; summary = 'red' } }, @{ type = 'started'; agentId = 'b2'; label = 'review:A' }, @{ type = 'result'; agentId = 'b2'; result = @{ ok = $true; summary = '' } },
  @{ type = 'started'; agentId = 'b3'; label = 'check:A' }, @{ type = 'result'; agentId = 'b3'; result = @{ ok = $true; findings = @('f1') } }, @{ type = 'started'; agentId = 'b4'; label = 'fix:A' }, @{ type = 'failed'; agentId = 'b4' }, @{ type = 'finished' } | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) | Set-Content "$y1/journal.jsonl"
(@{ type = 'started'; agentId = 'c1'; label = 'track:A' }, @{ type = 'finished' } | ForEach-Object { $_ | ConvertTo-Json -Compress }) | Set-Content "$y2/journal.jsonl"
foreach ($wy in 'wf_y1', 'wf_y2') { @{ runId = $wy; run = 'same-run'; script = 'buildy.js'; at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $ld "$wy.json") }
$yo = Invoke-PsTest usage2 @'
$null = . $args[0] 6>$null; $env:KIT_TRANSCRIPTS = $args[1]; $KitConf.TrackerRepos = @('r1')
function Get-KitHostUser { 'me' }; function Get-HostProject { param($n, [switch]$Raw) $n }
function Invoke-HostVerb { param($v, $a) $mr = { param($i, $d, $who, $src) [pscustomobject]@{ iid = $i; merged_at = (Get-Date).AddDays($d).ToString('o'); author = @{ username = $who }; source_branch = $src; target_branch = 'main' } }
  & $mr 1 0 'me' 'f/x'; & $mr 2 -10 'me' 'f/y'; & $mr 3 0 'other' 'f/z'; & $mr 4 0 'me' 'main' }   # in window, too old, not mine, a deploy MR
$u = Get-KitUsage -Seconds 30; $s = @($u.runs.steps); $res = ($s | Sort-Object label | ForEach-Object { "$($_.label)=$($_.result)" }) -join ','
$b1 = @($s | Where-Object label -eq 'build:A')[0]; $cst = { param($l) [math]::Round([double](@($s | Where-Object label -eq $l)[0].cost), 6) }
"$res|$($b1.in)|$(& $cst 'build:A')|$(& $cst 'review:A')|$(& $cst 'check:A')|$(@($u.unpriced).model -join ',')|$($u.rates.n) $($u.rates.fail) $($u.rates.empty) $($u.rates.stopped)"
"$(@($u.days)[-1].runs)|$(@($u.runs).Count) $(@($u.runs)[0].resumed)/$(@($u.runs)[0].total)/$(@($u.runs)[0].id)|$($u.coord[0].tok) $([math]::Round((Get-KitUsageCost @(100, 10, 0, 1000, 1000) 'claude-opus-5-5'), 4))|$(@($u.days)[-1].tok)|$($u.merged.source) $($u.merged.n) $(@($u.days)[-1].merged)"
$pgu = @{}; $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ usage = $u } }) $pgu
"$($h -match "<span class=gn title='coordinator[^']*'>coordinator</span>") $($h -match "<span class=gn[^>]*>tokens</span><span class='gs hm dy sbr' style='--n:\d+'" -and $h -match '<b class=nw>today</b>' -and $h -notmatch "class='lch lgw'|class=dch") $(([regex]::Matches($h, "class='st uc dn'|class=gauge|viewBox='0 0 42 42'")).Count) $($h -match 'tokens only \(Codex / Antigravity, no list price kept\): gpt-x' -and $h -notmatch 'not priced: gpt-x') $($h -match '1 MR\(s\) merged on the git host by me') $((@($pgu.Values) -join '') -match ">Time<")"
$pm = @(Get-KitUsageParts (Update-KitUsageFile "$($args[1])/main-1.jsonl" $null ([ref][long]1GB)) @((Get-Date).ToString('yyyy-MM-dd')) | ForEach-Object model | Sort-Object) -join ','
function Invoke-HostVerb { throw 'host down' }; $hp = Get-KitUsageHostMrs (Get-Date).Date (Get-Date) @{ at = '2020-01-01T00:00:00'; since = 'x'; mrs = @(1) }
$cf = Get-KitPath usage-cache; $cj = Get-Content $cf -Raw | ConvertFrom-Json -AsHashtable; foreach ($kv in @($cj.files.GetEnumerator())) { if ($kv.Key -like '*agent-b3*') { $kv.Value.v = 2 } }; $cj | ConvertTo-Json -Depth 7 | Set-Content $cf
"$pm|$(@($hp.mrs).Count)|$(@((Get-KitUsage -Seconds 0).runs.steps | Where-Object label -eq 'check:A').Count)"
function Get-KitStorageSamples { param($Drive, $Tail) foreach ($x in @(0, 100), @(3600, 110), @(7200, 60)) { [pscustomobject]@{ t = $x[0]; free = $x[1] } } }   # a 50 GB drop in the last hour
$sr = Get-KitSuperviseSeries @('disk D: 60 GB free, +25 GB/h (normal 1), full in 2.4 h') $null; $h2 = Format-KitSuperviseHtml ([pscustomobject]@{ at = (Get-Date).ToString('o'); stats = [pscustomobject]@{ disks = $sr.disks } })
"$($sr.disks[0].h1) $($h2.Contains('filling 25 GB/h (11 min) &#183; last hour 50 GB used'))"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $uy) | Out-String
$yv = @($yo.Trim() -split "`r?`n")
Expect "usage numbers: prices, outcomes, runs, host MRs, charts, disk filling ($($yv -join ' // '))" ($yv[-5] -eq 'build:A=fail,check:A=pass,fix:A=fail,review:A=empty,track:A=stopped|100|0.0009|2E-05|0.00015|gpt-x|5 2 1 1' -and $yv[-4] -eq '1|1 1/5/wf_y2|1110 0.0086|3538|host 1 1' -and $yv[-3] -eq 'True True 0 True True True' -and $yv[-2] -eq 'claude-opus-5-5,claude-sonnet-5-5|1|0' -and $yv[-1] -eq '-50 True')
Remove-Item (Join-Path $ld 'wf_y1.json'), (Join-Path $ld 'wf_y2.json') -Force
# (moved from dashboard, supervise, tracker tests: their caps)
# test runs by the result's own at (a copy or touch moves the file time): written now, at 2 days ago -> that day
$qaAt = & { . $O; $r = Get-KitPath qa-runs -Create; $f = Join-Path (New-Item -ItemType Directory -Force (Join-Path $r 'runat/T1')) 'results.json'; @{ at = (Get-Date).AddDays(-2).ToString('o'); checks = @(@{ result = 'PASS' }) } | ConvertTo-Json -Depth 4 | Set-Content $f
  $hit = @((Get-KitQaDays).days | Where-Object { @($_.runs).run -contains 'runat' }); Remove-Item -LiteralPath $f; Remove-Item -LiteralPath (Split-Path $f); Remove-Item -LiteralPath (Join-Path $r 'runat'); "$($hit.Count) $(@($hit.day) -join ',')" }
Expect "test runs: a result counts on its own at day, not its file time ($qaAt)" ($qaAt -eq "1 $((Get-Date).AddDays(-2).ToString('yyyy-MM-dd'))")
# one run = one row: a resumed run's two folders (same run name) are one workflow row, the newer folder's
$zr = Invoke-PsTest 'resumed' '. $args[0]; $env:KIT_TRANSCRIPTS = $args[1]; $ld = Get-KitPath launches -Create
  foreach ($y in 1, 2) { $wzd = "$($args[1])/s3/subagents/workflows/wf_z$y"; $null = New-Item -ItemType Directory -Force $wzd; Set-Content "$wzd/agent-z$y.jsonl" "{}"
    @{ type = "started"; agentId = "z$y"; label = "build:Z$y" }, @{ type = "result"; agentId = "z$y"; result = @{ summary = "ok" } } | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 } | Set-Content "$wzd/journal.jsonl"
    @{ runId = "wf_z$y"; run = "rz"; script = "buildy.js"; at = (Get-Date).AddMinutes(-30 + $y).ToString("o") } | ConvertTo-Json | Set-Content (Join-Path $ld "wf_z$y.json")
    Get-ChildItem $wzd | ForEach-Object { $_.LastWriteTime = (Get-Date).AddMinutes(-20 + 10 * $y) }; (Get-Item $wzd).LastWriteTime = (Get-Date).AddMinutes(-20 + 10 * $y) }
  @(Get-KitStatusRows | Where-Object name -eq "rz (workflow)" | ForEach-Object { $_.task }) -join "|"; foreach ($y in 1, 2) { Remove-Item (Join-Path $ld "wf_z$y.json") }' @($O, (Join-Path (Kd) 'tx3'))
Expect "status: a resumed run's two folders are one workflow row, the newer folder's ($zr)" ("$zr" -match 'wf_z2' -and "$zr" -notmatch 'wf_z1|\|')
# label pass: a head <b> and a row name capitalised; a value <b>, flag text in <li>, an id row (translate=no) kept
$lcIn = "<b>idle</b><span class='gs0 hrs dy'><b>steps</b></span><li class='f hr'>build gate</li><span class=gn translate=no>api</span><span class=gn>browser x</span>"
$lcOut = & { . $O; ConvertTo-KitLabelCase $lcIn }
Expect "labels: sentence case on heads and row names only ($lcOut)" ($lcOut -ceq "<b>idle</b><span class='gs0 hrs dy'><b>Steps</b></span><li class='f hr'>build gate</li><span class=gn translate=no>api</span><span class=gn>Browser x</span>")
# flag age: a flag back after a gap starts again
$fgOut = & { . $O; $now = Get-Date
  $gst = @{ flagSeen = @{ (Get-KitFlagKey 'back') = @{ first = $now.AddHours(-3).ToString('o'); last = $now.AddMinutes(-90).ToString('o') }; (Get-KitFlagKey 'held') = @{ first = $now.AddMinutes(-50).ToString('o'); last = $now.AddMinutes(-15).ToString('o') } } }
  $gf = @([pscustomobject]@{ level = 'WATCH'; what = 'back' }, [pscustomobject]@{ level = 'WATCH'; what = 'held' }); Set-KitFlagAge $gf $gst $now; "flaggap:$($gf[0].age)/$($gf[1].age)"
}
Expect "flag age: a flag back after more than supervise.flagGapMinutes starts again, one seen 15 min ago keeps its first-seen ($fgOut)" ("$fgOut" -eq 'flaggap:0 min/50 min')
# an id list in another order is the same flag: the ack holds, one key (heartbeat noise 2026-11-22)
$ro = pwsh -NoProfile -Command ". '$O'; `$f = { param(`$w) [pscustomobject]@{ level = 'ACT'; what = `$w } }; `$x = 'FAILED TESTING · t9a, t2b, t5c'; `$y = 'FAILED TESTING · t5c, t9a, t2b'; `$z = 'FAILED TESTING · t5c, t9a, t2d'
  (Get-KitFlagKey `$x) -eq (Get-KitFlagKey `$y); Test-KitAcked (& `$f `$y) @(`$x); Test-KitAcked (& `$f `$z) @(`$x)
  Test-KitAcked (& `$f 'FAILED TESTING · t9a, t2b, t5c, t1d need a fix round') @('FAILED TESTING · t9a, t2b…'); (Get-KitFlagKey 'ids: a1, b1.') -eq (Get-KitFlagKey 'ids: b1, a1.')"
Expect "supervise: an ack and the flag key ignore the order of an id list (a period after it too), a changed id flags again, a cut list still acks ($($ro -join ','))" (($ro -join ',') -eq 'True,True,False,True,True')
Remove-TestKit $k
Complete-Tests
