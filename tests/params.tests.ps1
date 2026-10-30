#Requires -Version 7
<#
params.tests.ps1: lib.ps1 params (registry, load tags, sketches, trigger queue, show, params-changes), the supervise sweep (learned
section cost, starved first, background calls), net hang retry budget + back-off, the transcript walk cache, log trim, kitbag params lint.
Usage: pwsh -NoProfile -File <kit>/tests/params.tests.ps1 (or tests/kit-tests.ps1 -Area params).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit params; $O = Join-Path $k 'skills/bossy/bossy.ps1'
& $J @{ logs = @{ keepDays = 30 } } "$k/skills/crafty/kit.local.json"
$pr = Invoke-PsTest params @'
. $args[0]
# owner decision 3: old lines roll into logs-summary.jsonl (one line per stream and month), retired lessons stay, a look back is an observation
$sg = Get-KitPath signals -Create; $n0 = [datetime]'2026-10-30T10:00'
@(@{ at = '2026-03-10T10:00'; skill = 'kitty'; kind = 'friction'; text = 'old a' }, @{ at = '2026-03-11T10:00'; skill = 'kitty'; kind = 'friction'; text = 'old a' },
  @{ at = '2026-04-01T10:00'; skill = 'bossy'; kind = 'retired'; text = 'kept' }, @{ at = '2026-10-28T10:00'; skill = 'kitty'; kind = 'idea'; text = 'new' }) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $sg
$tr = @(Invoke-KitLogTrim -Now $n0); $left = @(Get-Content $sg | ConvertFrom-Json); $sm = @(Get-Content (Get-KitPath logs-summary) | ConvertFrom-Json)
"trim:$($tr[0].rolled):$($left.text -join ','):$($sm[0].stream):$($sm[0].period):$($sm[0].n):$($sm[0].by.'kitty/friction'):$($sm[0].facts[0]):$($tr[0].days)"
$null = Read-KitLog signals (Get-Date).AddDays(-40); "look:$(@(Read-KitLog params (Get-Date).AddHours(-1) | Where-Object { $_.key -eq 'logs.keepDays' -and $_.ctx -eq 'signals' -and $_.v -gt 39 }).Count)"
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
'@ @((Lib))
Expect "params: owner decision 3: old lines roll into logs-summary (month, counts, facts), retired stay, raw for logs.keepDays ($(@($pr -match '^trim:') -join ' '))" ($pr -contains 'trim:2:kept,new:signals:2026-03:2:2:2x old a:30')
Expect 'params: a look back into a trimmed log is a logs.keepDays observation; a reboot is one trigger' ($pr -contains 'look:1' -and $pr -contains 'wake:|reboot|1')
Expect 'params: the registry gives config defaults; kit.local.json pins; an unknown key is null' ($pr -contains 'reg:20:30:0:config')
Expect "params: an observation carries load (busy at cpu 91), host and minutes since a wake ($(@($pr -match '^tags:') -join ' '))" ($pr -contains 'tags:busy:91:5:True')
Expect "params: raw 14 d, hourly sketches within 2%, past 90 d gone ($(@($pr -match '^win:') -join ' '))" ($pr -contains 'win:1:2:2:True:2')
Expect "params: a deploy trigger is queued until the cadence minimum passed, then evaluated; p90 per load bucket ($(@($pr -match '^queue:') -join ' '))" ($pr -contains 'queue:deploy:False:True:6')
Expect "params: show has cadence, due, trigger, state and the What-learns-when table ($(@($pr -match '^show:') -join ' '))" ($pr -contains 'show:True:True:1')
Expect "params: a pin is a params-changes line; Settings since a time ($(@($pr -match '^changes:') -join ' '))" (@($pr -match '^changes:SETTINGS: idle\.graceMinutes \[_\] default -> 9 \(pin by').Count -eq 1)
# supervise sweep: costs (EWMA) and starved sections; a slow -Background verb runs detached, its last result next sweep
$bs = Join-Path (Kd) 'bg.ps1'; "'bg-out'; Start-Sleep -Milliseconds 300" | Set-Content $bs
$sr = Invoke-PsTest sweep @'
. $args[0]; $st = @{ sweep = @{ cost = @{ a = 10; b = 1; c = 5 }; starved = @('c') } }; $n0 = Get-Date
$sw = New-KitSweep $n0.AddSeconds(12) $st
"sweep:$(Test-KitSweep $sw a $n0)$(Test-KitSweep $sw b $n0)$(Test-KitSweep $sw c $n0.AddSeconds(2))$(Test-KitSweep $sw d $n0.AddSeconds(13))"
Complete-KitSweep $sw $st $n0.AddSeconds(14); "sweep2:$($st.sweep.starved -join ','):$($st.sweep.cost.b):$($st.sweep.cost.c)"
$sw = New-KitSweep (Get-Date).AddSeconds(30) @{ sweep = @{ cost = @{ bgx = 50 } } }
$i1 = @(Invoke-KitSweepCall $sw quick $args[1] @() -Background); $b1 = @(Invoke-KitSweepCall $sw bgx $args[1] @() -Background)
$wait = { $r = Get-Content (Join-Path (Get-KitPath background) 'bgx.json') -Raw | ConvertFrom-Json; for ($i = 0; $i -lt 150 -and (Test-KitPid $r.pid $r.start); $i++) { Start-Sleep -Milliseconds 100 } }
& $wait; $b2 = @(Invoke-KitSweepCall $sw bgx $args[1] @() -Background); & $wait
"bg:$($i1 -join ','):$($sw.cost.quick -gt 0):$($b1.Count):$($b2 -join ','):$($sw.cost.bgx -lt 50)"
'@ @((Lib), $bs)
Expect "sweep: a section runs when its cost fits the time left after starved ones; starved first; costs EWMA; skipped = next starved ($(@($sr -match '^sweep') -join ' '))" ($sr -contains 'sweep:FalseTrueTrueFalse' -and $sr -contains 'sweep2:a,d:1.3:6.8')
Expect "sweep: a verb runs inline (cost learned); over half the time left with -Background: the last result, a fresh detached run ($(@($sr -match '^bg:') -join ' '))" ($sr -contains 'bg:bg-out:True:0:bg-out:True')
# net: after a timeout the next call waits x1.5 (that call only); hang retries within 10% of calls (>= 1 a minute)
$nr = Invoke-PsTest net @'
. $args[0]; $script:seen = @(); $script:ok = $false; $env:KIT_NET_TIMEOUT_SEC = 40
function Invoke-KitExe($Exe, $A, $T) { $script:seen += $T; [pscustomobject]@{ code = $(if ($script:ok) { 0 } else { -1 }); out = ''; err = ''; timedOut = -not $script:ok } }
$null = Invoke-KitNetExe gh @('x'); $null = Invoke-KitNetExe gh @('x'); $script:ok = $true; $null = Invoke-KitNetExe gh @('x'); $null = Invoke-KitNetExe gh @('x'); "backoff:$($seen -join ',')"
Remove-Item (Get-KitPath net-budget) -ErrorAction SilentlyContinue; 1..24 | ForEach-Object { $null = Add-KitNetCount }
"budget:$(@(1..4 | ForEach-Object { Add-KitNetCount -Retry -Check }) -join ',')"
$script:ok = $false; $r = Invoke-KitRetry { Invoke-KitNetExe gh @('x') } 3; "spent:$($r.err -match 'hang retry budget spent')"
$root = Join-Path (Get-KitPath cache -Create) 'tx'; New-Item -ItemType Directory -Force "$root/s1/subagents", "$root/s2" | Out-Null; 'x' | Set-Content "$root/s1/subagents/a.jsonl"
function Invoke-KitAdapter { [pscustomobject]@{ dir = $root; filter = '*.jsonl' } }
$n1 = @(Get-KitLiveTranscripts (Get-Date) 10).Count; New-Item -ItemType Directory -Force "$root/s2/subagents" | Out-Null; 'x' | Set-Content "$root/s2/subagents/b.jsonl"; $n2 = @(Get-KitLiveTranscripts (Get-Date) 10).Count
$cf = Get-KitPath transcript-dirs; $c = Get-Content $cf -Raw | ConvertFrom-Json -AsHashtable; $c[$root].at = (Get-Date).AddMinutes(-2).ToString('o'); $c | ConvertTo-Json -Depth 4 | Set-Content $cf
"tx:$n1$n2$(@(Get-KitLiveTranscripts (Get-Date) 10).Count)"
'@ @((Lib))
Expect "net: after a timeout the next call waits x1.5, then back ($(@($nr -match '^backoff:') -join ' '))" ($nr -contains 'backoff:40,60,60,40')
Expect "net: hang retries within 10% of the calls of 10 min (>= 1 a minute); spent: the call returns at once ($(@($nr -match '^(budget|spent):') -join ' '))" ($nr -contains 'budget:True,True,True,False' -and $nr -contains 'spent:True')
Expect "transcripts: the session folder walk is cached 60 s ($(@($nr -match '^tx:') -join ' '))" ($nr -contains 'tx:112')
# cleanup: tracking.json.migrated goes (owner decision 3)
'{}' | Set-Content "$(TkPath $k tracking -Create).migrated"
$cd = pwsh @np $O cleanup -DryRun -WorktreeRoot (Join-Path (Kd) 'no-wt') 2>&1 | Out-String
Expect 'cleanup: tracking.json.migrated goes' ($cd -match 'tracking\.json\.migrated')
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
'@
$plf = Join-Path (Kd) 'pl.py'; Set-Content $plf $pl; $lr = @(& $py -X utf8 $plf $k 2>&1 | ForEach-Object { "$_" })
Expect "lint: an unregistered key, a literal other than the registry default ($(@($lr -match '^lint:') -join ' '))" ($lr -contains 'lint:PARAM-DEFAULT a.ps1:1|PARAM-UNREG a.ps1:1')
Expect "lint: tunable literals WARN over the baseline; --ratchet records them; a new one warns again ($(@($lr -match '^(warn|ratchet|again):') -join ' '))" ($lr -contains 'warn:a.ps1 1 tunable literal(s)|b.py 2 tunable literal(s)|c.mjs 1 tunable literal(s)' -and $lr -contains 'ratchet:0' -and $lr -contains 'again:b.py')
Remove-TestKit $k
Complete-Tests
