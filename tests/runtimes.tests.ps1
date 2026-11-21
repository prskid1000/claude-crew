#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/runtimes.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/runtimes.tests.ps1: runtimes (fake isUp / up / down lines on a flag file): lease, start, stop, an owner-started runtime stays,
# the guard's auto lease, supervise -AutoFix on a dead holder; dashboard liveness: run state, Runs band hours and chips, disk rows' age,
# a failed page or stats source, Trends split cells. Usage: pwsh -NoProfile -File tests/runtimes.tests.ps1
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
@((& $st 1 @($open)), (& $st 30 @($open)), (& $st 90 @($open)), (& $st 30 @($open, $done)), (& $st 1 @($open, '{"type":"finished"}')), (& $st 1 @($open) ([pscustomobject]@{ runId = 'x'; paused = 'now' }))) -join ' '
$dead = [pscustomobject]@{ runId = 'x'; holderPid = 999999; holderStart = '2020-01-01T00:00:00Z' }; $cl = 'Test-KitRunCloseable'
"close: $((& $st 30 @($open, $done) $me $cl), (& $st 30 @($open, $done) $dead $cl), (& $st 130 @($open, $done) $me $cl), (& $st 90 @($open) $dead $cl) -join ' ')"
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'), $rsd) | Out-String
Expect "run state: running (fresh write) · stuck (open step, quiet < 3x) · stale (open step quiet 3x, or no open step quiet) · ended · paused, whatever the holder; AutoFix closes a stale run only with no open step after 6x quiet (a dead session: stopped, resumed, never closed) ($($rsOut.Trim()))" ($rsOut.Trim() -eq "running stuck stale stale ended paused`r`nclose: False False True False" -or $rsOut.Trim() -eq "running stuck stale stale ended paused`nclose: False False True False")
# Runs band: hours = the steps' activity, never start-to-now; a stale run chipped; a board-only run newer than the usage pass: counting
$rbd = & { . $O; $n = [datetime]'2026-01-02T15:00:00'; $sx = [pscustomobject]@{ label = 'build:A'; role = 'devy'; at = $n.AddHours(-5).ToString('o'); min = 30; result = 'stopped'; tok = 5 }
  $run = [pscustomobject]@{ run = 'r9'; id = 'wf_9'; label = 'r9'; kind = 'build'; started = $n.AddHours(-6).ToString('o'); status = 'ended'; state = 'stale'; lastAt = $sx.at; at = $sx.at; tok = 5; steps = @($sx); wall = 60 }
  $ag = @([pscustomobject]@{ name = 'k1 (kitty)'; run = 'kit-x'; state = 'ACTIVE'; since = $n.AddMinutes(-9).ToString('o'); last = $n.ToString('o') })
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = $ag; stats = [pscustomobject]@{ usage = [pscustomobject]@{ at = $n.AddMinutes(-30).ToString('o'); runs = @($run) } } })
  $r9 = [regex]::Match($h, "(?s)data-g='rr-wf_9'.*?</div><div class='gk ag").Value
  "$($r9 -match 'stale &#183; no end record|stale · no end record') $(([regex]::Matches($r9, ' [1-9]\d* min active')).Count) $($h -match '>counting… \(usage as of 14:30\)<')" }
$rov = & { . $O; $n = [datetime]'2026-01-02T15:00:00'; $sx = [pscustomobject]@{ label = 'build:A'; role = 'devy'; at = $n.AddHours(-3).ToString('o'); min = 9; result = 'running'; tok = 5 }
  $run = [pscustomobject]@{ run = 'r8'; id = 'wf_8'; label = 'r8'; kind = 'build'; started = $n.AddHours(-4).ToString('o'); status = 'running'; at = $sx.at; tok = 5; steps = @($sx); wall = 60 }
  $ag = @([pscustomobject]@{ name = 'r8 (workflow)'; run = 'r8'; state = 'FINISHED'; since = $n.AddHours(-3).ToString('o'); last = $n.AddHours(-3).ToString('o') })
  $h = Format-KitSuperviseHtml ([pscustomobject]@{ at = $n.ToString('o'); agents = $ag; stats = [pscustomobject]@{ usage = [pscustomobject]@{ at = $n.AddHours(-3).ToString('o'); runs = @($run) } } })
  "$([regex]::Match($h, "(?s)data-g='rr-wf_8'.{0,600}").Value -notmatch 's-act''>running') $($h -match 'usage as of 01-02 12:00')" }
Expect "runs band: this sweep's ended workflow row beats an older usage pass's running; the band says how old usage is ($rov)" ($rov -eq 'True True')
Expect "runs band: a stale run is chipped, its hours only where its steps ran (1 hour), a board-only run newer than usage says counting ($rbd)" ($rbd -eq 'True 1 True')
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
Remove-TestKit $k
Complete-Tests
