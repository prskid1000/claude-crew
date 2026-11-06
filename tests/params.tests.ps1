#Requires -Version 7
<#
params.tests.ps1: lib.ps1 params (registry, load tags, sketches, trigger queue, show, params-changes), the supervise sweep (learned
section cost, cadence, starved first, background calls), net hang retry budget + back-off, the transcript walk cache, log trim, kitbag params
lint, the tidy digest's QA gaps, track status lag; (cap moves) program state, browser.mjs exit release / kitParam / ports, pipes default.
Usage: pwsh -NoProfile -File <kit>/tests/params.tests.ps1 (or tests/kit-tests.ps1 -Area params).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit params; $O = Join-Path $k 'skills/bossy/bossy.ps1'
& $J @{ logs = @{ keepDays = 30 } } "$k/skills/crafty/kit.local.json"
# program state (moved from bossy.tests for its cap), before the param tests change the kit
$null = Px $O program set -Program 'Big Plan' -Key phases -Value '{"p1":"wf_1"}'; $pg = Px $O program get -Program 'Big Plan' -Key phases | Out-String; $pm = Invoke-TestScript $O program get -Program 'Big Plan' -Key nope
Expect 'program state in .state: set, get, a missing key exit 1' ($pg -match 'wf_1' -and $pm.code -eq 1)
$pr = Invoke-PsTest params @'
. $args[0]
# owner decision 3: old lines roll into logs-summary.jsonl (one line per stream and month), retired lessons stay, a look back is an observation
$sg = Get-KitPath signals -Create; $n0 = [datetime]'2026-10-30T10:00'
@(@{ at = '2026-03-10T10:00'; skill = 'kitty'; kind = 'friction'; text = 'old a' }, @{ at = '2026-03-11T10:00'; skill = 'kitty'; kind = 'friction'; text = 'old a' },
  @{ at = '2026-04-01T10:00'; skill = 'bossy'; kind = 'retired'; text = 'kept' }, @{ at = '2026-10-28T10:00'; skill = 'kitty'; kind = 'idea'; text = 'new' }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $sg
$n0.AddDays(-50).ToString('o') | Set-Content (Get-KitPath last-retro -Create); $hw = [IO.FileStream]::new($sg, 'Append', 'Write', 'ReadWrite, Delete')   # an appender holds it (Write-KitLog's share)
try { $tr = @(Invoke-KitLogTrim -Now $n0); $lb = [Text.Encoding]::UTF8.GetBytes('{"at":"2026-10-30T09:00","skill":"x","kind":"idea","text":"late"}' + "`n"); $hw.Write($lb, 0, $lb.Length) } finally { $hw.Dispose() }
$null = Invoke-KitLogTrim -Now $n0; $left = @(Get-Content $sg | ConvertFrom-Json); $sm = @(Get-Content (Get-KitPath logs-summary) | ConvertFrom-Json)
"trim:$($tr[0].rolled):$($left.text -join ','):$($sm.Count):$($sm[0].stream):$($sm[0].period):$($sm[0].n):$($sm[0].by.'kitty/friction'):$($sm[0].facts[0]):$($tr[0].days):$(([datetime]$sm[0].from).Day -eq 10)"
"look:$(@(Read-KitLog params (Get-Date).AddHours(-1) | Where-Object { $_.key -eq 'logs.keepDays' -and $_.ctx -eq 'signals' -and [math]::Round($_.v) -eq 50 }).Count)"
# a reboot since the last look: one trigger line
$w1 = Test-KitWake; $s = Read-KitParams; $s.boot = (Get-Date).AddDays(-3).ToString('o'); $s | ConvertTo-Json -Depth 8 | Set-Content (Get-KitPath param-state); $w3 = Test-KitWake
"wake:$w1|$w3|$(@(Read-KitLog params (Get-Date).AddHours(-1) | Where-Object { $_.event -eq 'trig' -and $_.why -eq 'reboot' }).Count)"
# registry: a config key's default, a kit.local.json pin, an unknown key
"reg:$(Get-KitParam 'supervise.stuckMinutes'):$(Get-KitParam 'logs.keepDays' $null signals):$([int](Get-KitParam 'no.such.key')):$((Get-KitParamSpec 'idle.beatMinutes').how)"
# load tags and wake on an observation
$t = [datetime]'2026-03-01T08:00'; $env:KIT_NOW = $t.ToString('o')
@{ load = @{ at = (Get-Date).ToString('o'); availGB = 9.5; cpu = 91; agents = 2 } } | ConvertTo-Json | Set-Content (Get-KitPath supervise-state -Create)
$s = Read-KitParams; $s.wakeAt = $t.AddMinutes(-5).ToString('o'); $s | ConvertTo-Json -Depth 8 | Set-Content (Get-KitPath param-state); $script:KitParamMemo.Clear()
Add-KitParamObs idle.graceMinutes 12 '' ok 10; $o = @(Read-KitLog params $t.AddDays(-1) | Where-Object event -eq obs)[-1]
"tags:$($o.lb):$($o.load.cpu):$($o.wake):$([bool]$o.host)"; Remove-Item (Get-KitPath audit), (Get-KitPath param-state) -Recurse -Force   # the learner below starts clean (no real-clock lines)
# raw observations 14 d, older ones in hourly sketches (2%), those past 90 d go
$e = @{ obs = @() }; foreach ($d in 100, 50, 20, 3) { Update-KitParamWindow $e $t @($t.AddDays(-$d).ToString('o'), 10.0, 'ok', 2.0, 'calm') }
$h = @(Get-KitParamHistory $e); "win:$(@($e.obs).Count):$($e.hr.Count):$($h.Count):$([math]::Abs($h[0][1] - 10) -lt 0.2):$($h[0][3])"
# trigger queue: a deploy trigger waits for the key's cadence minimum since its last evaluation, then one pass takes it
function F($v, $n, $h) { for ($i = 0; $i -lt $n; $i++) { $env:KIT_NOW = $t.AddHours($h + $i).ToString('o'); Add-KitParamObs gate.waitMinutes $v w ok 90 } }
function Ln($m) { $env:KIT_NOW = $t.AddMinutes($m).ToString('o'); $script:KitParamMemo.Clear(); $null = Invoke-ParamLearn }
F 30 6 1; Ln 420; $env:KIT_NOW = $t.AddMinutes(425).ToString('o'); Add-KitParamTrigger deploy; Ln 430; $q1 = @((Read-KitParams).queue['gate.waitMinutes|w'].why) -join ','
Ln 440; $p = Read-KitParams; "queue:${q1}:$([bool]$p.queue['gate.waitMinutes|w']):$($p.byKey['gate.waitMinutes']['w'].cad.lastTrig -match '^deploy '):$($p.byKey['gate.waitMinutes']['w'].byLoad.busy.n)"
$sh = (Invoke-KitParamVerb show gate.waitMinutes) -join ' '; $all = @(Invoke-KitParamVerb show)
"show:$($sh -match 'cadence 15 min, due \d\d-\d\d \d\d:\d\d, trigger deploy; p90 by load: busy 30'):$($all -contains '| Trigger | Effect |'):$(@($all -match '^supervise\.stuckMinutes: 20 \(default; config\)').Count)"
$null = Invoke-KitParamVerb pin idle.graceMinutes 9; "changes:$((Get-KitParamChanges $t) -join '|')"
# a stable key (cadence 1 d) with a fail trigger: evaluated after 15 min, not a day; a frozen key's trigger drains
$s = Read-KitParams; $e = $s.byKey['gate.waitMinutes']['w']; $e.cad = @{ min = 1440; stable = 0; due = $t.AddDays(3).ToString('o') }; $e.evalAt = $t.AddMinutes(440).ToString('o')
$s.byKey['gate.waitMinutes']['z'] = @{ d = 90; obs = @(); since = $t.ToString('o'); frozen = $t.AddYears(1).ToString('o') }; $s | ConvertTo-Json -Depth 8 -Compress | Set-Content (Get-KitPath param-state)
$env:KIT_NOW = $t.AddMinutes(470).ToString('o'); Add-KitParamObs gate.waitMinutes 400 w short 90; Add-KitParamTrigger wake gate.waitMinutes z; Ln 480; $p = Read-KitParams
"urgent:$($p.byKey['gate.waitMinutes']['w'].evalAt -eq $t.AddMinutes(480).ToString('o')):$($p.byKey['gate.waitMinutes']['w'].cad.min):$($p.queue.Count)"
'@ @((Lib))
Expect "params: owner decision 3: old lines roll into logs-summary once (month, counts, facts, span), retired stay, raw for logs.keepDays; an appender's handle neither blocks nor loses a line ($(@($pr -match '^trim:') -join ' '))" ($pr -contains 'trim:2:kept,new,late:1:signals:2026-03:2:2:2x old a:30:True')
Expect 'params: the gap since the last retro is a logs.keepDays observation (each trim); a reboot is one trigger' ($pr -contains 'look:2' -and $pr -contains 'wake:|reboot|1')
Expect 'params: the registry gives config defaults; kit.local.json pins; an unknown key is null' ($pr -contains 'reg:20:30:0:config')
Expect "params: an observation carries load (busy at cpu 91), host and minutes since a wake ($(@($pr -match '^tags:') -join ' '))" ($pr -contains 'tags:busy:91:5:True')
Expect "params: raw 14 d, hourly sketches within 2%, past 90 d gone ($(@($pr -match '^win:') -join ' '))" ($pr -contains 'win:1:2:2:True:2')
Expect "params: a deploy trigger is queued until the cadence minimum passed, then evaluated; p90 per load bucket ($(@($pr -match '^queue:') -join ' '))" ($pr -contains 'queue:deploy:False:True:6')
Expect "params: show has cadence, due, trigger, state and the What-learns-when table ($(@($pr -match '^show:') -join ' '))" ($pr -contains 'show:True:True:1')
Expect "params: an urgent trigger on a key with a 1 d cadence is evaluated within 15 min; a frozen key's trigger drains ($(@($pr -match '^urgent:') -join ' '))" ($pr -contains 'urgent:True:15:0')
Expect "params: a pin is a params-changes line; Settings since a time ($(@($pr -match '^changes:') -join ' '))" (@($pr -match '^changes:SETTINGS: idle\.graceMinutes \[_\] default -> 9 \(pin by').Count -eq 1)
# supervise sweep: costs (EWMA) and starved sections; a slow -Background verb runs detached, its last result next sweep
$bs = Join-Path (Kd) 'bg.ps1'; '"bg-out$($args -join '' '' -replace ''[^ -~]'', ''?'')"; Start-Sleep -Milliseconds 300' | Set-Content $bs
$sr = Invoke-PsTest sweep @'
. $args[0]; $st = @{ sweep = @{ v = 2; cost = @{ a = 10; b = 1; c = 5 }; starved = @('c') } }; $n0 = Get-Date
$sw = New-KitSweep $n0.AddSeconds(12) $st
"sweep:$(Test-KitSweep $sw a $n0)$(Test-KitSweep $sw b $n0)$(Test-KitSweep $sw c $n0.AddSeconds(2))$(Test-KitSweep $sw d $n0.AddSeconds(13))"
Complete-KitSweep $sw $st $n0.AddSeconds(14); "sweep2:$($st.sweep.starved -join ','):$($st.sweep.cost.b):$($st.sweep.cost.c)"
$sw = New-KitSweep (Get-Date).AddSeconds(30) @{ sweep = @{ v = 2; cost = @{ bgx = 50 } } }
$i1 = @(Invoke-KitSweepCall $sw quick $args[1] @() -Background); $b1 = @(Invoke-KitSweepCall $sw bgx $args[1] @('-X', "a'$([char]0x2019)b") -Background)
$wait = { param($wn = 'bgx') $r = Get-Content (Join-Path (Get-KitPath background) "$wn.json") -Raw | ConvertFrom-Json; for ($i = 0; $i -lt 150 -and (Test-KitPid $r.pid $r.start); $i++) { Start-Sleep -Milliseconds 100 } }
& $wait; $b2 = @(Invoke-KitSweepCall $sw bgx $args[1] @('-X', "a'$([char]0x2019)b") -Background); & $wait
$dq = foreach ($r in 1, 2) { @(Invoke-KitSweepCall $sw dq $args[1] @() -Detached).Count; & $wait dq }
"bg:$($dq -join '')$($sw.cost.dq -gt 0)$($i1 -join ','):$($sw.cost.quick -gt 0):$($b1.Count):$($b2 -join ','):$($sw.cost.bgx -lt 50)"
$s2 = New-KitSweep $n0.AddSeconds(-6) @{ sweep = @{ v = 2; cost = @{ s = 10; q = 0.5 }; starved = @('s', 'q') } }; "starved:$(Test-KitSweep $s2 s $n0)$(Test-KitSweep $s2 q $n0)"
$s3 = New-KitSweep $n0.AddSeconds(60) @{}; $null = Test-KitSweep $s3 a $n0; Start-KitSweepPhase $s3 hook $n0.AddSeconds(2); $null = Test-KitSweep $s3 b $n0.AddSeconds(7); $st3 = @{}
$s4 = New-KitSweep $n0.AddSeconds(20) @{ sweep = @{ v = 2; cost = @{ big = 30; x = 4 }; starved = @('big') } }; "hold:$(Test-KitSweep $s4 x $n0):$((New-KitSweep $n0 @{ sweep = @{ cost = @{ old = 99 } } }).cost.Count)"
$s5 = New-KitSweep $n0.AddSeconds(20) @{ sweep = @{ v = 2; cost = @{}; last = @{ 'deploy checks' = "$($n0.AddMinutes(-5))"; cleanup = "$($n0.AddMinutes(-40))" } } }; $st5 = @{}
"due:$(Test-KitSweep $s5 'deploy checks' $n0)$(Test-KitSweep $s5 cleanup $n0)$(Test-KitSweep $s5 cleanup $n0):$($s5.skipped.Count):$($null = Complete-KitSweep $s5 $st5 $n0.AddSeconds(1); [datetime]$st5.sweep.last.cleanup -gt $n0)"
$top = Complete-KitSweep $s3 $st3 $n0.AddSeconds(8); "phase:$($st3.sweep.cost.a):$($st3.sweep.cost.b):$($st3.sweep.cost.ContainsKey('~hook')):$top"
$hp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden; $hb = Join-Path (Get-KitPath background) 'hung.json'
@{ pid = $hp.Id; start = (Get-KitPidStart $hp.Id); at = (Get-Date).AddHours(-2).ToString('o') } | ConvertTo-Json | Set-Content $hb
$hu = @(Invoke-KitBackground hung $args[1] @() $null 5); $null = $hp.WaitForExit(5000)
$ce = Join-Path (Split-Path $args[1]) 'ce.ps1'; '[Console]::Error.WriteLine("boom: no tracker"); exit 1' | Set-Content $ce; $null = Invoke-KitBackground crash $ce @(); & $wait crash
$cr = @(Invoke-KitBackground crash $ce @()); "hung:$($hu[0] -match '^WATCH background hung hung 120 min: stopped')$($hp.HasExited):$($cr[0] -eq 'WATCH background crash failed: boom: no tracker')"
& $wait; & $wait crash; Start-Sleep -Seconds 2
'@ @((Lib), $bs)
Expect "sweep: a section runs when its cost fits the time left after starved ones; starved first; costs EWMA; skipped = next starved ($(@($sr -match '^sweep') -join ' '))" ($sr -contains 'sweep:FalseTrueTrueFalse' -and $sr -contains 'sweep2:a,d:1.3:6.8')
Expect "sweep: a verb runs inline (cost learned); over half the time left with -Background, or cheap with -Detached: the last result, a fresh detached run, args intact, smart quotes too ($(@($sr -match '^bg:') -join ' '))" ($sr -contains "bg:01Truebg-out:True:0:bg-out-X a'?b:True")
Expect "sweep: a starved section runs up to 10 s past the deadline if min(cost, 5) s fit; a hung background run is stopped; a crashed one (console stderr) is a WATCH line ($(@($sr -match '^(starved|hung):') -join ' '))" ($sr -contains 'starved:FalseTrue' -and $sr -contains 'hung:TrueTrue:True')
Expect "sweep: an ungated phase is no section's cost, named in slowest; starved hold at most half; pre-v2 costs relearn ($(@($sr -match '^(phase|hold):') -join ' '))" ($sr -contains 'phase:2:1:False:slowest: ~hook 5.0 s, a 2.0 s, b 1.0 s' -and $sr -contains 'hold:True:0')
Expect "sweep: inside its sectionMinutes not due (no skip); due: runs (twice in a round too), stamped ($(@($sr -match '^due:') -join ' '))" ($sr -contains 'due:FalseTrueTrue:0:True')
# net: after a timeout the next call waits x1.5 (that call only); hang retries within 10% of calls (>= 1 a minute)
$nr = Invoke-PsTest net @'
. $args[0]; $script:seen = @(); $script:ok = $false; $env:KIT_NET_TIMEOUT_SEC = 40
function Invoke-KitExe($Exe, $A, $T) { $script:seen += $T; [pscustomobject]@{ code = $(if ($script:ok) { 0 } else { -1 }); out = ''; err = ''; timedOut = -not $script:ok } }
$null = Invoke-KitNetExe gh @('x'); $null = Invoke-KitNetExe gh @('x'); $script:ok = $true; $null = Invoke-KitNetExe gh @('x'); $null = Invoke-KitNetExe gh @('x'); "backoff:$($seen -join ',')"
Remove-Item (Get-KitPath net-budget) -ErrorAction SilentlyContinue; '999999' | Set-Content "$(Get-KitPath net-budget).lock"; 1..24 | ForEach-Object { $null = Add-KitNetCount }
"budget:$(@(1..4 | ForEach-Object { Add-KitNetCount -Retry -Check }) -join ','):$(Test-Path "$(Get-KitPath net-budget).lock")"
$script:ok = $false; $r = Invoke-KitRetry { Invoke-KitNetExe gh @('x') } 3; "spent:$($r.err -match 'hang retry budget spent')"
$env:KIT_NET_TIMEOUT_SEC = ''; $env:KIT_PARAM_NET_TIMEOUTSEC = 30; $null = Invoke-KitNetExe gh @('x'); $null = Invoke-KitNetExe gh @('x')
"tobs:$(@(Read-KitLog params (Get-Date).AddHours(-1) | Where-Object { $_.key -eq 'net.timeoutSec' -and $_.r -eq 'timeout' } | ForEach-Object v) -join ',')|$($seen[-2..-1] -join ',')"
$root = Join-Path (Get-KitPath cache -Create) 'tx'; New-Item -ItemType Directory -Force "$root/s1/subagents", "$root/s2" | Out-Null; 'x' | Set-Content "$root/s1/subagents/a.jsonl"
function Invoke-KitAdapter { [pscustomobject]@{ dir = $root; filter = '*.jsonl' } }
$n1 = @(Get-KitLiveTranscripts (Get-Date) 10).Count; New-Item -ItemType Directory -Force "$root/s2/subagents" | Out-Null; 'x' | Set-Content "$root/s2/subagents/b.jsonl"; $n2 = @(Get-KitLiveTranscripts (Get-Date) 10).Count
$cf = Get-KitPath transcript-dirs; $c = Get-Content $cf -Raw | ConvertFrom-Json -AsHashtable; $c[$root].at = (Get-Date).AddMinutes(-2).ToString('o'); $c | ConvertTo-Json -Depth 4 | Set-Content $cf
"tx:$n1$n2$(@(Get-KitLiveTranscripts (Get-Date) 10).Count)"; '{"payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":75}}}}' | Set-Content "$root/c.jsonl"; "spend:$((Get-KitSpend "$root/c.jsonl").spend)"
Set-Content "$root/d.jsonl" (@('{"message":{"model":"m1","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}') + @(1..700 | ForEach-Object { '{"x":"' + ('y' * 1000) + '"}' })); "spend2:$((Get-KitSpend "$root/d.jsonl").spend)"; "ss:$(Format-KitSessionStart 'hi' @{ conversationId = 'c' })|$(Format-KitSessionStart '' @{ conversationId = 'c' })|$(ConvertTo-KitAskPayload @() | ConvertTo-Json -Compress)"
'@ @((Lib))
Expect "net: after a timeout the next call waits x1.5, then back ($(@($nr -match '^backoff:') -join ' '))" ($nr -contains 'backoff:40,60,60,40')
Expect "net: a timeout is observed at the learned value, not the x1.5 back-off ($(@($nr -match '^tobs:') -join ' '))" ($nr -contains 'tobs:30,30|45,45')
Expect "net: hang retries within 10% of the calls of 10 min (>= 1 a minute); a dead writer's count lock is cleared; spent: the call returns at once ($(@($nr -match '^(budget|spent):') -join ' '))" ($nr -contains 'budget:True,True,True,False:False' -and $nr -contains 'spent:True')
Expect "transcripts: the session folder walk is cached 60 s ($(@($nr -match '^tx:') -join ' ')); Codex spend = last token_count" ($nr -contains 'tx:112' -and $nr -contains 'spend:75' -and $nr -contains 'spend2:10')
Expect 'Antigravity SessionStart: injectSteps (empty: []); no blocking decision: ids []' ($nr -contains 'ss:{"injectSteps":[{"systemMessage":{"systemMessage":"hi"}}]}|{"injectSteps":[]}|{"ids":[],"questions":[]}')
# health: the python checks (lint, port --check, goody check) run in the background; the next session shows their lines
$hcw = { $r = Read-Json (Join-Path (TkPath $k background) 'health-checks.json'); for ($i = 0; $i -lt 300 -and (& { . (Lib); Test-KitPid $r.pid $r.start }); $i++) { Start-Sleep -Milliseconds 100 } }
'# a' | Set-Content "$k/AGENTS.md"; $hh = Px $O health | Out-String; & $hcw   # a kit folder: lint has lines
$hc = (Get-Content (Join-Path (TkPath $k background) 'health-checks.out') -Raw) -replace '\s+', ' '; $hh2 = Px $O health | Out-String; & $hcw; Remove-Item "$k/AGENTS.md"
Expect "health: the python checks run in the background; the next session shows their lines ($hc)" ($hh -notmatch 'kitbag lint' -and "$hc" -match 'kitbag lint' -and $hh2 -match 'kitbag lint')
# cleanup: tracking.json.migrated goes (owner decision 3)
'{}' | Set-Content "$(TkPath $k tracking -Create).migrated"
$cd = pwsh @np $O cleanup -DryRun -WorktreeRoot (Join-Path (Kd) 'no-wt') 2>&1 | Out-String
Expect 'cleanup: tracking.json.migrated goes' ($cd -match 'tracking\.json\.migrated')
# heartbeat SETTINGS: shown until a heartbeat (-AutoFix) saw them; a manual run does not consume them
$null = pwsh @np $O param pin idle.graceMinutes 8; $sv = foreach ($af in $false, $true, $true) { pwsh @np $O supervise -Json -AutoFix:$af 2>$null | Out-String }
Expect 'supervise: SETTINGS lines until a heartbeat saw them; a manual run leaves them' ($sv[0] -match 'SETTINGS: idle\.graceMinutes' -and $sv[1] -match 'SETTINGS: idle\.graceMinutes' -and $sv[2] -notmatch 'SETTINGS: idle\.graceMinutes')
# the sweep-budget WATCH exists before the acks: in lastFlags (what -Ack matches), hidden once acked
& $J @{ logs = @{ keepDays = 30 }; supervise = @{ briefSeconds = 0 } } "$k/skills/crafty/kit.local.json"; $null = pwsh @np $O supervise -Brief 2>$null
$sbl = @((Read-Json (TkPath $k supervise-state)).lastFlags.what -match '^sweep hit its 0 s budget').Count; $null = pwsh @np $O supervise -Ack 'sweep hit its 0 s budget' -Reason 'test'
$sbh = Invoke-PsTest sbh ". `$args[0]; `$a = (Get-Content (Get-KitPath supervise-state) -Raw | ConvertFrom-Json -AsHashtable).acks; (Select-KitFlags @([pscustomobject]@{ level = 'WATCH'; what = 'sweep hit its 0 s budget: skipped storage' }) `$a (Get-Date)).what" @($O)
& $J @{ logs = @{ keepDays = 30 } } "$k/skills/crafty/kit.local.json"
Expect "supervise: the sweep-budget WATCH is in lastFlags and -Ack hides it ($sbl; $sbh)" ($sbl -eq 1 -and "$sbh" -match '^1 acknowledged flag')
# supervise collision words; -Ack from -Brief cells (wrap spaces, \|, one cell); refs (UNTRACKED MR) kept, a new MR flags
$ac = Invoke-PsTest ack @'
. $args[0]; "cx:$(Test-KitCollision 'H6a overwrote MR !8543 description with another agent''s body file from /tmp; halted the push')$(Test-KitCollision 'Halted: another agent is editing the same worktree')"
$n = Get-Date; $a = @{}; foreach ($t in 'mvn- test\|j- c/ api failed 4 times', 'datay-R1 (datay) (R1)') { $a[(Get-KitFlagKey $t)] = @{ at = "$n" } }
$fl = @{ level = 'W'; what = "builds 'mvn-test|j-c/api' failed 3 times"; kind = 'B'; problem = 'mvn-test|j-c/api failed 3 times' }, @{ level = 'A'; what = 'STUCK datay-R1 (datay) (R1): no progress' }, @{ level = 'W'; what = 'STUCK revy-7 (revy) (): no progress' }
"cells:$(@(Select-KitFlags @($fl | ForEach-Object { [pscustomobject]$_ }) $a $n).what -join '|')"
$f = Get-KitPath supervise-state -Create; @{ lastFlags = @(@{ what = 'x'; kind = 'UNTRACKED MR'; who = 'someone1'; refs = 'web!1', 'web!2' }) } | ConvertTo-Json -Depth 5 | Set-Content $f
$o = "$(Invoke-Supervise -Ack 'UNTRACKED MR | someone1')"; $s = Get-Content $f -Raw | ConvertFrom-Json -AsHashtable
$s.untrackedMrs = @{ at = "$n"; user = 'u'; mrs = @(1..3 | ForEach-Object { @{ repo = 'web'; iid = "$_"; author = 'u'; merged_at = $n.ToUniversalTime().ToString('o') } }) }
"refs:$(@($s.known.Keys | Sort-Object) -join ',')|$($s.acks.Count)|$($o -match 'known from now on' -and $o -match 'hides 1')|$((Get-KitUntrackedMrFlag $s $n).problem)"
'@ @($O)
Expect "supervise: a fix report naming another agent: no collision; -Ack: a cell matches, UNTRACKED MR keeps its MRs ($($ac -join ' // '))" ($ac -contains 'cx:FalseTrue' -and $ac -contains 'cells:STUCK revy-7 (revy) (): no progress|2 acknowledged flag(s) hidden (supervise -Ack, 24 h)' -and $ac -contains 'refs:web!1,web!2|0|True|web!3 merged, no task')
# supervise failedTesting: 3 tracker views a round, unseen first, then a 2-beat cache
$qd = TkPath $k qa-runs -Create; $null = New-Item -ItemType Directory -Force "$qd/q1/A1"; & $J @{ subtasks = @(1..4 | ForEach-Object { @{ id = "ft$_"; failedTesting = $true } }) } "$qd/q1/A1/finalize.json"
$tn = TkPath $k tracker-none -Create; $ts = { param($i, $s) & $J @{ id = "ft$i"; name = 'n'; status = $s } "$tn/ft$i.json" }; 1..4 | ForEach-Object { & $ts $_ 'failed testing' }
$ftn = { "$(@((pwsh @np $O supervise -Json 2>$null | Out-String | ConvertFrom-Json).flags.what) -match 'failed testing, back' -replace ' .*')" }
$f1 = & $ftn; $f2 = & $ftn; & $ts 4 'in progress'; $f3 = & $ftn
Expect "supervise failedTesting: 3 views a round, unseen first, then cached ($f1 $f2 $f3)" ("$f1$f2$f3" -eq '344')
# kitbag lint: PARAM-UNREG, PARAM-DEFAULT; tunable literals over the _literals baseline WARN; --ratchet records, then only lowers
'$x = Get-KitParam ''supervise.stuckMinutes'' 25; $y = Get-KitParam ''no.key''; Start-Sleep 5' | Set-Content "$k/a.ps1"
$pl = @'
import sys; sys.path.insert(0, sys.argv[1] + '/skills/bossy'); import kitbag as kb
class K: pass
k = K(); k.dir = sys.argv[1]; k.files = ['a.ps1', 'b.py', 'c.mjs']
k.texts = {'a.ps1': open(k.dir + '/a.ps1').read(), 'b.py': 'import time\ntime.sleep(30)\nrun(x, timeout=90)\n', 'c.mjs': 'const waitMs = 5000\n'}
out = []; kb.params_lint(k, lambda c, w, m: out.append(c + ' ' + w)); print('lint:' + '|'.join(sorted(out)))
print('warn:' + '|'.join(f'{w} {m.split(",")[0]}' for c, w, m in kb.literal_warns(k)))
print('ratchet:' + str(len(kb.literal_warns(k, True))))
k.texts['b.py'] += 'time.sleep(9)\n'; print('again:' + '|'.join(w for c, w, m in kb.literal_warns(k)))
import json; p = k.dir + '/' + kb.PARAMS_JSON; r = json.load(open(p, encoding='utf-8')); r['_literals'] = {}; json.dump(r, open(p, 'w', encoding='utf-8'))
print('zero:' + str(len(kb.literal_warns(k, True))))
'@
$rj = "$k/skills/bossy/params.registry.json"; $rg = Get-Content $rj -Raw | ConvertFrom-Json -AsHashtable; $rg.Remove('_literals'); $rg | ConvertTo-Json -Depth 5 | Set-Content $rj   # no baseline yet
$plf = Join-Path (Kd) 'pl.py'; Set-Content $plf $pl; $lr = @(& $py -X utf8 $plf $k 2>&1 | ForEach-Object { "$_" })
Expect "lint: an unregistered key, a literal other than the registry default ($(@($lr -match '^lint:') -join ' '))" ($lr -contains 'lint:PARAM-DEFAULT a.ps1:1|PARAM-UNREG a.ps1:1')
Expect "lint: tunable literals WARN over the baseline; --ratchet records them; a new one warns again ($(@($lr -match '^(warn|ratchet|again):') -join ' '))" ($lr -contains 'warn:a.ps1 1 tunable literal(s)|b.py 2 tunable literal(s)|c.mjs 1 tunable literal(s)' -and $lr -contains 'ratchet:0' -and $lr -contains 'again:b.py' -and $lr -contains 'zero:3')
$qr = Join-Path (Kd) 'qg'; foreach ($x in 'A1', 'B1') { $null = New-Item -ItemType Directory -Force "$qr/r1/$x", "$qr/r0"; '{}' | Set-Content "$qr/r1/$x/results.json" }; 'r' | Set-Content "$qr/r1/A1/report.md"
$qg = pwsh -NoProfile -Command ". '$O'; Get-KitQaRunGap '$qr/r1'; Get-KitQaRunGap '$qr/r0'"
Expect "tidy digest: QA reports are per item; the items without one named, an empty run said ($qg)" ("$qg" -eq ', no report: B1 , no item tested')
# track lag: t2 held (its HOLD, INFO), t4 held with an older cached LAG, t3 not held = LAG (supervise ACT)
$lg = Invoke-PsTest 'track-lag' @'
. $args[0]; $KitConf.GitlabGroup = 'g'; $global:st = @{ t1 = 'Open'; t2 = 'for review'; t3 = 'for review'; t4 = 'for review' }
Register-KitAdapter 'tracker' 'fake' @{ view = { param($a) [pscustomobject]@{ id = $a.id; name = 'n'; status = $global:st[$a.id] } }; status = { param($a) $global:st[$a.id] = $a.status; 'ok' } }; Initialize-KitTracker -Type fake
function Invoke-HostApi($p) { @{ state = $(if ($p -match '/1$') { 'opened' } else { 'merged' }) } }
$ago = (Get-Date).AddHours(-2).ToString('s'); Update-KitTracking { param($all) $all.tasks.t1 = @{ task = 't1'; mrs = @('web!1') }; foreach ($i in 2..4) { $all.tasks["t$i"] = @{ task = "t$i"; mrs = @("web!$i"); mergedSeenAt = $ago } }
  $all.tasks.t2.holdPromotion = $all.tasks.t4.holdPromotion = 'agent stopped'; $all.tasks.t4.lagLine = 'LAG t4: cached'; $all.tasks.t4.lagAt = (Get-Date).ToString('s') }
Invoke-Track run -Detail; "t1:$($global:st.t1)"
'@ @($O) | Out-String
Expect 'track: an open MR moves an Open task to review; merged 60+ min = LAG, held = HOLD only' ($lg -match "DONE t1: status 'Open' -> review" -and $lg -match 't1:for review' -and $lg -match "LAG t3: all MRs merged at \d\d:\d\d, status still 'for review'" -and $lg -notmatch 'LAG t[24]' -and $lg -match 'HOLD t2' -and $lg -match 'HOLD t4')
# ---- moved here for the per-file test caps: browser.mjs exit release, kitParam, ports (pokey), pipes default (crafty)
if (Use-BrowserKit) {
  $relf = Join-Path (Kd) 'released.txt'
  $res = NodeT exitrel ("const fs = await import('node:fs'), f = process.argv[2]; m.releaseOnExit(async () => fs.appendFileSync(f, 'a')); const off = m.releaseOnExit(async () => fs.appendFileSync(f, 'b')); off()`n" +
    "setTimeout(() => { throw new Error('boom') }, 10)") $relf; $relc = $LASTEXITCODE
  Expect "browser.mjs: an uncaught error runs each open session's done() (not a finished one's), then exits 1 ($relc)" ($relc -eq 1 -and "$res" -match 'boom' -and (Get-Content $relf -Raw) -eq 'a')
  & $J @{ pins = @{ 'net.timeoutSec|gh' = @{ value = 33 } }; byKey = @{ 'idle.graceMinutes' = @{ _ = @{ value = 4.6 } } } } (TkPath $k param-state -Create)
  $ps = pwsh -NoProfile -Command ". '$(Lib)'; Get-KitParam idle.graceMinutes 10; Get-KitParam net.timeoutSec 60 gh; Get-KitParam gate.waitMinutes 90"
  $res = NodeT param "console.log([m.kitParam('idle.graceMinutes', 10), m.kitParam('net.timeoutSec', 60, 'gh'), m.kitParam('gate.waitMinutes', 90)].join(' '))"
  Expect 'browser.mjs kitParam = Get-KitParam' ("$res" -eq ($ps -join ' ') -and "$res" -eq '4.6 33 90')
  $res = NodeT ports @'
import { rmSync, existsSync } from 'node:fs'
const P = m.sessionPort, a = await P('s', 't', 'a'), seen = [], job = (n) => m.withLock('l', async () => { seen.push(n); await new Promise((r) => setTimeout(r, 150)); seen.push(n) })
await Promise.all([job(1), job(2)]); const uniq = new Set([a, await P('s', 't', 'v'), await P('p', 't', 'a')]).size === 3
rmSync(m.kitPath('browser-ports')); console.log(a === await P('s', 't', 'a') && uniq, /^(\d),\1,/.test(seen.join(',')), existsSync(m.kitPath('browser-ports')))
'@
  Expect 'browser.mjs: stable port per user key, locked logins' ("$res" -eq 'true true true')
}
$D = Join-Path $k 'skills/crafty/crafty.ps1'; $lf = Join-Path (Kd) 'mrs.ps1'; Set-Content $lf "'[]'"
& $J @{ gitHost = 'git.example'; gitHostType = 'command'; gitHostApi = @{ commands = @{ 'mr.list' = "pwsh -NoProfile -File `"$lf`"" } } } "$k/skills/crafty/kit.local.json"
$pipeRepo = Join-Path (Kd) 'pp'; $pipeWt = Join-Path (Kd) 'pp-wt'; git init -q -b main $pipeRepo; git -C $pipeRepo commit -q --allow-empty -m i; git -C $pipeRepo remote add origin 'https://git.example/g/pp.git'; git -C $pipeRepo worktree add -q -b TK-11-x $pipeWt
Set-Content (Join-Path "$(git -C $pipeWt rev-parse --absolute-git-dir)" 'claude-target') 'main'; Push-Location $pipeWt; $pipeNone = pwsh @np $D pipes -MaxMinutes 0 2>&1 | Out-String; $pipeNoneCode = $LASTEXITCODE
Set-Content $lf "'[{""iid"":6,""state"":""opened"",""source_branch"":""TK-11-x"",""target_branch"":""main"",""web_url"":""https://git.example/g/pp/-/merge_requests/6""}]'"; $pipeOut = pwsh @np $D pipes -MaxMinutes 0 2>&1 | Out-String; Pop-Location; Set-Content $lf "'[]'"
Expect "pipes without -Mrs in a wt worktree: its branch's open MRs; none = exit 2 naming the branch ($pipeNoneCode)" ($pipeNoneCode -eq 2 -and $pipeNone -match 'no open MR for TK-11-x -> main' -and $pipeOut -match 'pipes: -Mrs https://git\.example/g/pp/-/merge_requests/6 \(open MRs of TK-11-x\)')
# supervise NO MRS (bossy.ps1) and prior overrides (adapters/supervise_resources.ps1): a stale flag source each
$nm = & { . $O; $s = @(@{ agentId = 'b1'; label = 'build:W2' }, @{ agentId = 'b2'; label = 'local:W2' }); $r1 = @{ mrs = @(); worktrees = @('C:\wt\w2-web'); deferred = @(@{ id = 'T9' }) }
  $rs = @(@{ agentId = 'b1'; result = $r1 }, @{ agentId = 'b2'; result = @{ mrs = @(@{ url = 'u' }) } }); $tk = @{ tasks = @{ T9 = @{ mrs = @('api!4') } } }
  "$(Test-KitNoMrs $s $rs build:W2 $r1 'not done' $tk)|$(Test-KitNoMrs $s @($rs[0]) build:W2 $r1 'not done' $tk)|$(Test-KitNoMrs $s @($rs[0]) build:W2 $r1 'not done' @{ tasks = @{ T9 = @{ mrs = @('web!5') } } })|$(Test-KitNoMrs $s @($rs[0]) build:W2 $r1 'shipped' $tk)|$(Test-KitNoMrs $s @($rs[0]) build:W2 $r1 'not done' @{ tasks = @{ T9 = @{ done = $true; mrs = @('web!5') } } })" }
Expect "NO MRS: only when no later step of its item nor the open task's tracked MR in its repo has MRs ($nm)" ($nm -eq 'False|True|False|False|True')
$wbf = Join-Path (Kd) 'wave7.md'; Set-Content $wbf 'items: P7, P13'; & $J @{ run = 'w7'; args = @{ brief = $wbf } } (Join-Path (TkPath $k launches -Create) 'self-buildy-w7.json')
$pov = pwsh -NoProfile -Command ". '$O'; Update-KitTaskIndex P7 { param(`$x) `$x.prior = [ordered]@{ at = (Get-Date).ToString('o'); validUntil = (Get-Date).AddHours(1).ToString('o'); found = @(@{ kind = 'branch'; ref = 'P7-a'; tagged = `$true }, @{ kind = 'task'; ref = 'P12' }) } }
  Assert-KitPrior P7 '' 'wt x' 'own'; & '$py' -X utf8 '$k/skills/crafty/devtools.py' finish P7 a b --override pyown 2>&1 | Out-Null
  Write-KitLog calls prior-override @{ task = 'P7'; what = 'mr w'; reason = 'r'; matched = @(@{ kind = 'task'; ref = 'P13' }, @{ kind = 'task'; ref = 'P1' }) }; Write-KitLog calls prior-override @{ task = 'P7'; what = 'mr'; reason = 'r' }
  @(Read-KitLog calls (Get-Date).AddMinutes(-9) | Where-Object event -eq 'prior-override' | ForEach-Object { @(`$_.matched | Where-Object { `$_ }).Count }) -join ','; '|'; @(Get-KitSuperviseFlagsPrior | ForEach-Object what) -join ';'"
Expect "prior override: the gate's hits are logged; WATCH only for another task's work or no hits known ($pov)" ("$pov" -match '^2,2,2,0 \|' -and "$pov" -match 'wt x P7 \(own\): matches task P12' -and "$pov" -match 'finish P7 P7 \(pyown\): matches task P12' -and "$pov" -match 'mr w P7 \(r\): matches task P1;' -and "$pov" -match 'override: mr P7 \(r\)$' -and "$pov" -notmatch 'P13|P7-a')
Remove-TestKit $k
Complete-Tests
