#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/local-model.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/local-model.tests.ps1: crafty.ps1 local (adapters/local-model.ps1): config resolution, token redaction, no unsafe flag by
# default, -Unsafe refused from an agent shell, forbidden model and RAM refusals, server down / model not served (a fake
# /v1/models), seats full (OVERFLOW in mixed mode, QUEUED else), a resident model skips the RAM need, a schema run keeps StructuredOutput in the
# crew agent's tools, a fake client gets the env and its exit code, supervise line.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/local-model.ps1', 'skills/crafty/adapters/video.ps1', 'agents/steppy.md', 'skills/crafty/adapters/localbench.py')
$k = New-TestKit lm; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $cfgFile = Join-Path $k 'skills/crafty/kit.local.json'
$env:LM_TEST_TOKEN = 'tok-' + [guid]::NewGuid().ToString('N')   # a value the output must never show
$lmCfg = @{ baseUrl = 'http://127.0.0.1:9/'; token = 'env:LM_TEST_TOKEN'; defaultModel = 'small-a'; forbiddenModels = @('big-*-mtp'); env = @{ BASH_MAX_TIMEOUT_MS = $null; EXTRA_FLAG = '1' } }
& $J @{ models = @{ local = $lmCfg } } $cfgFile

$pc = Invoke-TestScript $D local claude -Print -Json
$pj = try { $pc.out | ConvertFrom-Json } catch { $null }
Expect "local: -Print resolves config: base URL trimmed, env overrides (one dropped, one added), no model for interactive claude ($($pc.out.Substring(0, [math]::Min(200, $pc.out.Length))))" ($pc.code -eq 0 -and $pj.env.ANTHROPIC_BASE_URL -eq 'http://127.0.0.1:9' -and $pj.env.EXTRA_FLAG -eq '1' -and -not $pj.env.BASH_MAX_TIMEOUT_MS -and $pj.env.KIT_MODEL_MODE -eq 'local' -and $pj.model -eq '(server default)')
Expect "local: the token never printed, its env name redacted" ($pc.out -notmatch [regex]::Escape($env:LM_TEST_TOKEN) -and $pj.env.ANTHROPIC_AUTH_TOKEN -eq '<redacted>' -and $pj.token -eq 'set')
Expect "local: no permission-skip flag by default" ($pc.out -notmatch 'dangerously')
$pu = Invoke-TestScript $D local claude -Print -Unsafe
Expect "local: -Unsafe adds the flag only when asked ($($pu.code))" ($pu.out -match '--dangerously-skip-permissions')
$ua = Invoke-TestScript $D local claude -Unsafe
Expect "local: -Unsafe refused from an agent shell, exit 2 ($($ua.code))" ($ua.code -eq 2 -and $ua.out -match 'agents never skip permissions')
$fm = Invoke-TestScript $D local claude -Model big-27b-mtp -Print; $fa = Invoke-TestScript $D local claude -Print '--' --model big-x-mtp   # pwsh drops a bare -- (end of parameters): quoted
Expect "local: a forbidden model refused, from -Model and from the client args, exit 1 ($($fm.code) $($fa.code))" ($fm.code -eq 1 -and $fm.out -match 'REFUSED: model big-27b-mtp is forbidden' -and $fa.code -eq 1 -and $fa.out -match 'big-x-mtp')
$fb = @(@{ a = @('-Model', 'small-a', '--', '--model', 'big-1-mtp') }, @{ a = @('--', '--fallback-model', 'big-2-mtp') }, @{ a = @(); e = 'big-4-mtp' }) | ForEach-Object {
  if ($_.e) { $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $_.e }; $fr = Invoke-TestScript $D local $(if ($_.c) { $_.c } else { 'claude' }) -Print @($_.a); Remove-Item Env:ANTHROPIC_DEFAULT_SONNET_MODEL -ErrorAction SilentlyContinue; "$($fr.code):$(@($fr.out -split "`n" | Where-Object { $_ -match 'REFUSED' })[0] -replace '^.*model ([\w-]+).*$', '$1')" }
Expect "local: no way past the forbidden list: -Model before --, --fallback-model, an inherited ANTHROPIC_*_MODEL ($($fb -join ' '))" (($fb -join ' ') -eq '1:big-1-mtp 1:big-2-mtp 1:big-4-mtp')
$litCfg = $lmCfg.Clone(); $litCfg.token = 'literal-' + $env:LM_TEST_TOKEN; & $J @{ models = @{ local = $litCfg } } $cfgFile; $lt = Invoke-TestScript $D local status; $lp = Invoke-TestScript $D local claude -Print; & $J @{ models = @{ local = $lmCfg } } $cfgFile
Expect "local: a token value put in models.local.token is never printed (status, -Print)" ($lt.out -notmatch [regex]::Escape($env:LM_TEST_TOKEN) -and $lp.out -notmatch [regex]::Escape($env:LM_TEST_TOKEN) -and $lt.out -match 'a value, ignored')
$env:CLAUDE_GATE_KEEP_FREE_GB = '99999'; $rm = Invoke-TestScript $D local claude; Remove-Item Env:CLAUDE_GATE_KEEP_FREE_GB
Expect "local: RAM short of need + floor refused before any start, exit 1 ($($rm.code))" ($rm.code -eq 1 -and $rm.out -match 'REFUSED: RAM .* 99999 GB floor')
$dn = Invoke-TestScript $D local claude
Expect "local: no server at the base URL refused, exit 1 ($($dn.code))" ($dn.code -eq 1 -and $dn.out -match 'REFUSED: no local model server at http://127\.0\.0\.1:9')

# a fake server: GET /v1/models lists small-a and a forbidden id; a fake client prints its env and exits 3 (the verb: 13)
$tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl.Start(); $port = $tl.LocalEndpoint.Port; $tl.Stop()
$srv = Start-Job { param($p) $hl = [Net.HttpListener]::new(); $hl.Prefixes.Add("http://127.0.0.1:$p/"); $hl.Start(); $end = (Get-Date).AddMinutes(3)
  while ((Get-Date) -lt $end) { $ct = $hl.GetContextAsync(); while (-not $ct.Wait(500)) { if ((Get-Date) -ge $end) { break } }; if (-not $ct.IsCompleted) { break }
    $by = [Text.Encoding]::UTF8.GetBytes('{"object":"list","data":[{"id":"small-a"},{"id":"big-27b-mtp"}]}'); $rs = $ct.Result.Response; $rs.ContentType = 'application/json'; $rs.OutputStream.Write($by, 0, $by.Length); $rs.Close() } } -ArgumentList $port
$fake = Join-Path (Kd) 'fakeclaude.ps1'; Set-Content $fake "`"BASE=`$env:ANTHROPIC_BASE_URL MODEL=`$env:ANTHROPIC_MODEL ARGS=`$(`$args -join ' ') IN=`$(@(`$input) -join '')`"; exit 3" -Encoding utf8
$lmCfg.baseUrl = "http://127.0.0.1:$port"; $lmCfg.commands = @{ claude = @($fake) }; & $J @{ models = @{ local = $lmCfg } } $cfgFile
for ($wi = 0; $wi -lt 60; $wi++) { try { $tc = [Net.Sockets.TcpClient]::new('127.0.0.1', $port); $tc.Dispose(); break } catch { Start-Sleep -Milliseconds 250 } }   # the job's listener is up
$st = Invoke-TestScript $D local status
Expect "local: status names the served and the forbidden ids ($($st.out.Trim() -replace '\s+', ' '))" ($st.code -eq 0 -and $st.out -match 'up, serves small-a, big-27b-mtp \(forbidden: big-27b-mtp\)' -and $st.out -match 'seats: 0/2' -and $st.out -notmatch [regex]::Escape($env:LM_TEST_TOKEN))
$ns = Invoke-TestScript $D local claude -Model other-1
Expect "local: a model the server does not serve refused, the forbidden one not offered ($($ns.code))" ($ns.code -eq 1 -and $ns.out -match 'not served .*\(served: small-a\)')
$ic = Invoke-TestScript $D local claude; $noDef = $lmCfg.Clone(); $noDef.Remove('defaultModel'); & $J @{ models = @{ local = $noDef } } $cfgFile; $ir = Invoke-TestScript $D local claude; & $J @{ models = @{ local = $lmCfg } } $cfgFile
Expect "local: no -Model while the server also serves a forbidden id: the default model is pinned, none -> refused ($($ic.code) $($ir.code))" ($ic.code -eq 13 -and $ic.out -match 'MODEL=small-a' -and $ir.code -eq 1 -and $ir.out -match 'serves a forbidden model \(big-27b-mtp\)')
$pw = (Get-Process -Id $PID).Path; $dkCfg = $lmCfg.Clone(); $dkCfg.commands = @{ claude = @($fake); desktop = @($pw) }; & $J @{ models = @{ local = $dkCfg } } $cfgFile
$dq = Invoke-TestScript $D local desktop '--' -NoProfile -Command exit; $dqs = Invoke-TestScript $D local status; & $J @{ models = @{ local = $lmCfg } } $cfgFile
Expect "local: a detached client that exits at once (an open instance took the call) is refused, its seat freed ($($dq.code))" ($dq.code -eq 1 -and $dq.out -match 'exited at once' -and $dqs.out -match 'seats: 0/2')
$pf = Join-Path (Kd) 'prompt.txt'; Set-Content $pf 'hello local' -Encoding utf8
$run = Invoke-TestScript $D local claude -PromptFile $pf -AgentType steppy
Expect "local: a headless run gets the env, -p json, the crew agent, the prompt on stdin; the client's exit 3 comes back as 13 (3 = no seat) ($($run.code): $($run.out.Trim()))" ($run.code -eq 13 -and $run.out -match "BASE=http://127\.0\.0\.1:$port MODEL=small-a ARGS=-p --output-format json --agents \{`"steppy`":.*`"model`":`"inherit`"\}\} --agent steppy IN=hello local")
$rst = pwsh -NoProfile -Command "`$null = & '$D' local claude -PromptFile '$pf' 2>&1; `"rc=`$LASTEXITCODE base=[`$env:ANTHROPIC_BASE_URL] tool=[`$env:KIT_TOOL]`"" 2>&1 | Select-Object -Last 1
Expect "local: run in the caller's own pwsh (& crafty.ps1), the client's env is gone after it ($rst)" ("$rst" -eq 'rc=13 base=[] tool=[]')
# a model already in memory needs no new RAM (GET /v1/models/active); another model, or a server without that route, still does; a schema run keeps StructuredOutput in the crew agent's tools
$tl2 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl2.Start(); $port2 = $tl2.LocalEndpoint.Port; $tl2.Stop()
$actF = Join-Path (Kd) 'active.json'; $srv2 = Start-Job { param($p, $af) $hl = [Net.HttpListener]::new(); $hl.Prefixes.Add("http://127.0.0.1:$p/"); $hl.Start(); $end = (Get-Date).AddMinutes(3)
  while ((Get-Date) -lt $end) { $ct = $hl.GetContextAsync(); while (-not $ct.Wait(500)) { if ((Get-Date) -ge $end) { break } }; if (-not $ct.IsCompleted) { break }
    $js = if ($ct.Result.Request.Url.AbsolutePath -eq '/v1/models/active') { if (Test-Path $af) { Get-Content $af -Raw } else { '' } } else { '{"object":"list","data":[{"id":"small-a"},{"id":"small-b"}]}' }
    $rs = $ct.Result.Response; if (-not $js) { $rs.StatusCode = 404; $js = '{}' }; $by = [Text.Encoding]::UTF8.GetBytes($js); $rs.ContentType = 'application/json'; $rs.OutputStream.Write($by, 0, $by.Length); $rs.Close() } } -ArgumentList $port2, $actF
for ($wi = 0; $wi -lt 60; $wi++) { try { $tc = [Net.Sockets.TcpClient]::new('127.0.0.1', $port2); $tc.Dispose(); break } catch { Start-Sleep -Milliseconds 250 } }
$lmCfg.baseUrl = "http://127.0.0.1:$port2"; & $J @{ models = @{ local = $lmCfg } } $cfgFile; $env:CLAUDE_GATE_KEEP_FREE_GB = '99999'
Set-Content $actF '{"alive":true,"active_model":"small-a"}'; $rr = Invoke-TestScript $D local claude -Model small-a -PromptFile $pf; $ro = Invoke-TestScript $D local claude -Model small-b -PromptFile $pf; $rs2 = Invoke-TestScript $D local status
Set-Content $actF '{"alive":true,"active_model":"big-x-mtp"}'; $rf = Invoke-TestScript $D local claude; Set-Content $actF '{"alive":false,"active_model":"small-a"}'; $rl = Invoke-TestScript $D local claude -PromptFile $pf; Remove-Item $actF; $r4 = Invoke-TestScript $D local claude -PromptFile $pf
Remove-Item Env:CLAUDE_GATE_KEEP_FREE_GB; $lmCfg.baseUrl = "http://127.0.0.1:$port"; & $J @{ models = @{ local = $lmCfg } } $cfgFile
Expect "local: RAM short but the requested model is resident: the client starts (exit 13), another model is still refused, status says resident ($($rr.code) $($ro.code))" ($rr.code -eq 13 -and $rr.out -match 'MODEL=small-a' -and $ro.code -eq 1 -and $ro.out -match 'REFUSED: RAM' -and $rs2.out -match 'a model is resident')
Expect "local: a forbidden resident model, a model not alive and a server without the route do not skip the RAM need ($($rf.code) $($rl.code) $($r4.code))" (@($rf, $rl, $r4 | Where-Object { $_.code -eq 1 -and $_.out -match 'REFUSED: RAM' }).Count -eq 3)
$scf = Join-Path (Kd) 'schema.json'; Set-Content $scf '{"type":"object"}' -Encoding utf8; $ra = Invoke-TestScript $D local claude -PromptFile $pf -SchemaFile $scf -AgentType steppy
Expect "local: -SchemaFile with -AgentType hands the agent over inline with StructuredOutput added to its tools ($($ra.out.Trim().Substring(0, [math]::Min(160, $ra.out.Trim().Length))))" ($ra.out -match '--agents \{"steppy":\{"description":"[^\n]*"tools":\["Read","Write","Bash","PowerShell","ToolSearch","StructuredOutput"\]' -and $ra.out -match '--agent steppy IN=hello local')
Stop-Job $srv2 -ErrorAction SilentlyContinue; Remove-Job $srv2 -Force -ErrorAction SilentlyContinue
$sf = Join-Path (Kd) 'seat.ps1'; Set-Content $sf ". '$(Lib)'; `$me = @{ agent = 'busy'; pid = $PID; pidStart = (Get-KitPidStart $PID); at = (Get-KitStamp) }; `$null = Update-KitLocalAi 'local-model' { param(`$st) `$st.leases += `$me }" -Encoding utf8
$lmCfg.maxConcurrent = 1; & $J @{ models = @{ mode = 'mixed'; local = $lmCfg } } $cfgFile; $null = pwsh @np $sf
$ov = Invoke-TestScript $D local claude -PromptFile $pf; $qd = Invoke-TestScript $D local claude -WaitMinutes 0
Expect "local: seats full: a mixed-mode headless run overflows to the cloud at once, an interactive one queues, exit 3 ($($ov.code) $($qd.code))" ($ov.code -eq 3 -and $ov.out -match 'OVERFLOW cloud: local model seats full \(1/1: busy\)' -and $qd.code -eq 3 -and $qd.out -match 'QUEUED')
$sv = pwsh -NoProfile -Command ". '$(Lib)'; Get-KitSuperviseGuardLocalAi" 2>&1 | Out-String
Expect "local: supervise shows the mode and the held seats ($($sv.Trim()))" ($sv -match 'local-model \(mode mixed, 1/1 seats\): busy \d+ min')
$pg = (Invoke-PsTest lmpage @'
. $args[0]
Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00'; history = @(); stats = [pscustomobject]@{ now = (Get-KitSuperviseNow @('memory: 61% used, 24.7 GB available') 20); live = @() } })
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join "`n"
Expect "local: the dashboard Machine row has a local model seats tile with the mode, amber when full" ($pg -match "<div class='tl watch' title='local model seats: [^']*: busy \d+ min'><b>1 / 1</b><span>local model seats (&#183;|·) mixed</span>")

# models.runOn (owner 2026-11-27): one setting per run unit, models.mode wins, a refused local run falls back to the cloud (logged)
$roRes = { param($roMode, $roMap, [string[]]$roUnits) & $J @{ models = @{ mode = $roMode; runOn = $roMap; local = $lmCfg } } $cfgFile; @($roUnits | ForEach-Object { $roR = Invoke-TestScript $D local resolve -Unit $_ -Json; "$(($roR.out | ConvertFrom-Json).on)" }) -join ',' }
$roMap = @{ 'devy@fix' = 'local'; 'checky:close' = @{ on = 'local'; evidence = @{ pilot = @{ accepted = 12; n = 13 } } }; 'revy@mr' = 'cloud' }
$roU = @('devy@fix', 'checky:close', 'revy@mr', 'devy:nope')
$roC = & $roRes 'cloud' $roMap $roU; $roL = & $roRes 'local' $roMap $roU; $roX = & $roRes 'mixed' $roMap $roU
Expect "runOn resolve: mode cloud = all cloud, local = all local, mixed follows runOn (string or { on, evidence }), an unknown unit cloud ($roC | $roL | $roX)" ($roC -eq 'cloud,cloud,cloud,cloud' -and $roL -eq 'local,local,local,local' -and $roX -eq 'local,local,cloud,cloud')
$roT = Invoke-TestScript $D local resolve -Unit 'devy@fix'
Expect "runOn resolve: a local unit prints its launch line ($($roT.out.Trim() -replace '\s+', ' '))" ($roT.code -eq 0 -and $roT.out -match '^local\s+devy@fix \(models\.runOn\)' -and $roT.out -match 'local claude -AgentType devy -PromptFile')
$roWc = { param($roMode) & $J @{ models = @{ mode = $roMode; runOn = $roMap; local = $lmCfg } } $cfgFile; @(Invoke-PsTest rowc "`$null = . `$args[0] 6>`$null`nGet-KitWorkflowConfig | ConvertTo-Json -Depth 8 -Compress" @((Join-Path $k 'skills/bossy/bossy.ps1')))[-1] }
$roW0 = & $roWc 'cloud'; $roW1 = & $roWc 'mixed'; $roW1j = $roW1 | ConvertFrom-Json
Expect "runOn CONFIG: all cloud = no runOn key and no runOn map (the workflows run unchanged); mixed = the local units + the STEP text ($($roW1.Substring(0, [math]::Min(160, $roW1.Length))))" ($roW0 -notmatch 'runOn' -and (@($roW1j.runOn.units | Sort-Object) -join ',') -eq 'checky:close,devy@fix' -and $roW1j.runOn.step -match '\{name\}\.json' -and $roW1j.runOn.step -match 'local run -JobFile' -and "$($roW1j.models)" -notmatch 'runOn')
$roJob = Join-Path (Kd) 'job-close.json'; @{ unit = 'checky:close'; agentType = 'steppy'; schema = @{ type = 'object'; properties = @{ ok = @{ type = 'boolean' } }; required = @('ok') }; prompt = 'close T1' } | ConvertTo-Json -Depth 8 | Set-Content $roJob -Encoding utf8
$roFb = TkPath $k 'local-fallbacks'; Remove-Item $roFb -ErrorAction SilentlyContinue
& $J @{ models = @{ mode = 'cloud'; runOn = $roMap; local = $lmCfg } } $cfgFile; $roR1 = Invoke-TestScript $D local run -JobFile $roJob
$roDown = $lmCfg.Clone(); $roDown.baseUrl = 'http://127.0.0.1:9'; & $J @{ models = @{ mode = 'mixed'; runOn = $roMap; local = $roDown } } $cfgFile; $roR2 = Invoke-TestScript $D local run -JobFile $roJob
$roOk = Join-Path (Kd) 'fakeok.ps1'; Set-Content $roOk "`$null = @(`$input); '{`"type`":`"result`",`"result`":`"`",`"structured_output`":{`"ok`":true,`"output`":`"closed T1`"}}'; exit 0" -Encoding utf8
$roUp = $lmCfg.Clone(); $roUp.commands = @{ claude = @($roOk) }; $roUp.maxConcurrent = 4; & $J @{ models = @{ mode = 'mixed'; runOn = $roMap; local = $roUp } } $cfgFile; $roH = (pwsh -NoProfile -Command ". '$(Lib)'; Get-KitFnv ([IO.File]::ReadAllText('$roJob').TrimStart([char]0xFEFF).TrimEnd(""`r"", ""`n""))" | Select-Object -Last 1); $roR3 = Invoke-TestScript $D local run -JobFile $roJob -Fnv $roH
$roLog = @(Get-Content $roFb -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
Expect "runOn run: a cloud unit and a server down exit 3 FALLBACK cloud, each logged with its reason ($($roR1.code) $($roR2.code): $($roR2.out.Trim() -replace '\s+', ' '))" ($roR1.code -eq 3 -and $roR1.out -match 'FALLBACK cloud: checky:close is cloud \(models\.mode cloud\)' -and $roR2.code -eq 3 -and $roR2.out -match 'REFUSED: no local model server' -and $roLog.Count -eq 2 -and $roLog[1].unit -eq 'checky:close')
Expect "runOn run: a local unit runs through the launcher and prints the step's JSON on one line ($($roR3.code): $($roR3.out.Trim()))" ($roR3.code -eq 0 -and ($roR3.out.Trim() -split "`n")[-1] -eq '{"ok":true,"output":"closed T1"}')
$roS = Invoke-TestScript $D local status -Json; $roSj = $roS.out | ConvertFrom-Json; $roSt = Invoke-TestScript $D local status
Expect "runOn status: N local / M cloud and the fallbacks in 24 h ($($roSt.out -split "`n" | Where-Object { $_ -match '^runOn' }))" ($roSj.runOn.local -eq 2 -and $roSj.runOn.cloud -eq 1 -and $roSj.runOn.fallbacks -eq 2 -and $roSt.out -match 'runOn: 2 local / 1 cloud · fallbacks to the cloud in 24 h: 2')
$roPg = (Invoke-PsTest ropage @'
. $args[0]
Format-KitSuperviseHtml ([pscustomobject]@{ at = '2026-01-02T10:00:00'; history = @(); stats = [pscustomobject]@{ now = (Get-KitSuperviseNow @('memory: 61% used, 24.7 GB available') 20); live = @() } })
'@ @((Join-Path $k 'skills/bossy/bossy.ps1'))) -join "`n"
Expect "runOn dashboard: the Machine row shows local / cloud units and the fallbacks, amber with fallbacks" ($roPg -match "<div class='tl watch' title='models\.runOn units[^']*'><b>2 / 1</b><span>runOn local / cloud (&#183;|·) 2 fallbacks 24 h</span>")
# after the client starts (no JSON, deadline) the fallback says (started): the cloud step first checks what is done; a changed job never runs
$roMm = Invoke-TestScript $D local run -JobFile $roJob -Fnv 0badf00d
$roNj = Join-Path (Kd) 'fakenojson.ps1'; Set-Content $roNj "`$null = @(`$input); 'thinking out loud'; exit 0" -Encoding utf8
$roSl = Join-Path (Kd) 'fakeslow.ps1'; Set-Content $roSl "`$null = @(`$input); Start-Sleep 60; exit 0" -Encoding utf8
$roUp.commands = @{ claude = @($roNj) }; & $J @{ models = @{ mode = 'mixed'; runOn = $roMap; local = $roUp } } $cfgFile; $roR4 = Invoke-TestScript $D local run -JobFile $roJob
$roUp.commands = @{ claude = @($roSl) }; & $J @{ models = @{ mode = 'mixed'; runOn = $roMap; local = $roUp } } $cfgFile; $roT0 = Get-Date; $roR5 = Invoke-TestScript $D local run -JobFile $roJob -DeadlineSec 4; $roSec = ((Get-Date) - $roT0).TotalSeconds
$roLog2 = @(Get-Content $roFb | ForEach-Object { $_ | ConvertFrom-Json })
Expect "runOn run: a job that differs from -Fnv never runs (exit 4 MISMATCH, nothing logged); no JSON and a deadline exit 3 (started), logged ($($roMm.code) $($roR4.code) $($roR5.code) in $([int]$roSec) s)" ($roMm.code -eq 4 -and $roMm.out -match 'MISMATCH' -and $roR4.code -eq 3 -and $roR4.out -match 'FALLBACK cloud \(started\): checky:close no JSON answer' -and $roR5.code -eq 3 -and $roR5.out -match 'FALLBACK cloud \(started\): checky:close no answer in 4 s' -and $roSec -lt 40 -and $roLog2.Count -eq 4 -and $roLog2[-1].why -match '^started: ')
# runon -Write keeps a CRLF + BOM file's line ends and BOM
$roCr = Join-Path (Kd) 'crlf.json'; [IO.File]::WriteAllText($roCr, "{`r`n `"models`": { `"mode`": `"cloud`" },`r`n `"x`": 1`r`n}`r`n", [Text.UTF8Encoding]::new($true))
$null = Invoke-TestScript $D local bench runon -Write $roCr; $roCb = [IO.File]::ReadAllBytes($roCr); $roCt = [IO.File]::ReadAllText($roCr)
Expect "runon -Write: a CRLF file with a BOM keeps both and stays JSON" ($roCb[0] -eq 0xEF -and $roCb[1] -eq 0xBB -and ($roCt -replace "`r`n", '') -notmatch "`n" -and ($roCt | ConvertFrom-Json).models.runOn.'devy@fix' -eq 'cloud' -and ($roCt | ConvertFrom-Json).x -eq 1)
# runon -Write folds the retired models.local.use list in (its units local), drops it, keeps an unknown unit and names it
$roUse = $lmCfg.Clone(); $roUse.use = @('steppy', 'checky:close'); & $J @{ models = @{ mode = 'mixed'; runOn = @{ 'devy@nope' = 'local' }; local = $roUse } } $cfgFile
$roWr = Invoke-TestScript $D local bench runon -Write $cfgFile; $roCf = Get-Content $cfgFile -Raw | ConvertFrom-Json -AsHashtable
$roVals = $roCf.models.runOn
Expect "runon -Write: every unit listed, use folded in (steppy steps + checky:close local, a step before CONFIG stays cloud), use dropped, unknown kept and named, exit 1 ($($roWr.code))" ($roWr.code -eq 1 -and $roVals['steppy:budget'] -eq 'local' -and $roVals['checky:close'] -eq 'local' -and $roVals['steppy:record-args'] -eq 'cloud' -and $roVals['devy@feature'] -eq 'cloud' -and -not $roCf.models.local.ContainsKey('use') -and $roVals['devy@nope'] -eq 'local' -and $roWr.out -match 'UNKNOWN devy@nope' -and $roVals.Count -ge 100)
# the workflows: no runOn in CONFIG (all cloud) = the same steps as an empty list; a local unit runs as one steppy STEP; refused -> the cloud step, logged
$roJs = @'
const mk = (ro, ans) => { const calls = [], logs = []; return { calls, logs, agent: async (p, o) => { calls.push(`${o.label}|${o.agentType}|${o.model}|${p.length}`)
  if (/^record-args/.test(o.label)) return _ok(`RECORDED\nCONFIG ${JSON.stringify({ roles: {}, ...(ro ? { runOn: { units: ro, step: 'STEP: job {name} {fnv}: {job}', redo: 'REDO-CHECK' } } : {}) })}`)
  if (/@local$/.test(o.label)) { calls.push(`PROMPT ${p}`); return ans } if (/^build:X1$/.test(o.label)) calls.push(`CLOUD ${p.slice(0, 40)}`); return _pass(p, o) } } }
const base = { brief: 'C:/b/w.md', mandate: ['m'], ..._kl, agents: [{ id: 'X1', items: 'A1' }] }
const go = async (ro, ans) => { const m = mk(ro, ans); await run(base, m.agent, (l) => m.logs.push(l), _n, pipeline); return m }
const a = await go(null), b = await go([]), c = await go(['devy:build'], _ok(JSON.stringify(_rep({ status: 'PASS', failing: [] }, _merged(1))))), d = await go(['devy:build'], { ok: false, output: 'FALLBACK cloud: devy:build launcher exit 1: REFUSED: RAM' }), e = await go(['devy:build'], { ok: false, output: 'FALLBACK cloud (started): devy:build no JSON answer' }), f = await go(['devy:build'], null)
console.log(`noop:${a.calls.join() === b.calls.join() && !a.calls.some((x) => /@local\|/.test(x))}`)
console.log(`local:${c.calls.some((x) => /^build:X1@local\|steppy\|/.test(x)) && c.calls.some((x) => /^PROMPT STEP: job buildy-w-build_X1 [0-9a-f]{8}: \{"unit":"devy:build","agentType":"devy","schema":\{/.test(x)) && !c.calls.some((x) => /^build:X1\|/.test(x))}`)
console.log(`started:${e.calls.some((x) => /^CLOUD REDO-CHECK\n/.test(x)) && f.calls.some((x) => /^CLOUD REDO-CHECK\n/.test(x)) && !d.calls.some((x) => /^CLOUD REDO/.test(x))}`)
console.log(`fallback:${d.calls.some((x) => /^build:X1\|devy\|/.test(x)) && d.logs.some((l) => /^build:X1: devy:build on the cloud \(local: FALLBACK cloud: devy:build launcher exit 1/.test(l))}`)
'@
Expect-Each (Invoke-Js ro-buildy $roJs (Join-Path $src 'workflows/buildy.js')) 'runOn buildy.js: # (started: the cloud step first checks what is done)' 'noop', 'local', 'started', 'fallback' -Show 4
# testy close and tidy apply run locally the same way (their own STEP, no cloud step after a JSON answer)
$roTy = Invoke-Js ro-testy 'const cf = `RECORDED\nCONFIG ${JSON.stringify({ roles: {}, qaLanes: null, runOn: { units: ["checky:close"], step: "S {name} {fnv} {job}", redo: "R" } })}`, m = _mock((p, o) => /^test:/.test(o.label) ? _res("W1", [_ck("C1", "PASS")]) : /@local$/.test(o.label) ? _ok(JSON.stringify({ ok: true, output: "closed" })) : undefined)
await run({ runDir: "C:/runs/G", ..._kl, items: [_item("W1", "")] }, async (p, o) => /^record-args/.test(o.label) ? _ok(cf) : m.agent(p, o), _n, _n, null); const L = m.calls.map((c) => c.label)
console.log(`testy-local:${L.includes("close:W1@local") && !L.includes("close:W1")}`)' (Join-Path $src 'workflows/testy.js')
$roTd = Invoke-Js ro-tidy 'const m = _mock((p, o) => o.label === "prep" ? { ok: true, record: `RECORDED\nCONFIG ${JSON.stringify({ runOn: { units: ["kitty:apply"], step: "S {name} {fnv} {job}", redo: "R" } })}`, prep: JSON.stringify({ work: 1, steps: [], digest: "d.md" }), run: "tidy" } : /@local$/.test(o.label) ? _ok(JSON.stringify({ applied: ["a"], proposedForApproval: [], rejected: [], report: "r" })) : { applied: [], proposedForApproval: [], rejected: [], report: "cloud" })
const res = await run({ kitDir: "C:/k" }, m.agent, _n, _n, null); const L = m.calls.map((c) => c.label)
console.log(`tidy-local:${L.includes("apply@local") && !L.includes("apply") && res.report === "r"}`)' (Join-Path $src 'workflows/tidy.js')
Expect-Each (@($roTy) + @($roTd)) 'runOn #: a local unit runs as its own STEP, the cloud step skipped' 'testy-local', 'tidy-local' -Show 4
# every step the sims run maps to a run unit the generator lists (buildy, testy, tidy)
$roOut = Join-Path (Kd) 'units.tsv'; $env:KIT_UNITS_OUT = $roOut
$null = Invoke-Js ro-b2 'await run({ brief: "C:/b/w.md", mandate: ["m"], ..._kl, agents: [{ id: "X1", items: "A1", migrations: true }] }, _mock(_pass).agent, _n, _n, pipeline)' (Join-Path $src 'workflows/buildy.js')
$null = Invoke-Js ro-t2 'await run({ runDir: "C:/runs/G", ..._kl, items: [_item("W1", "")] }, _mock((p, o) => /^test:/.test(o.label) ? _res("W1", [_ck("C1", "PASS")]) : undefined).agent, _n, _n, null)' (Join-Path $src 'workflows/testy.js')
$null = Invoke-Js ro-d2 'await run({ kitDir: "C:/k" }, _mock((p, o) => o.label === "prep" ? { ok: true, record: "RECORDED", prep: JSON.stringify({ work: 1, steps: [] }), run: "tidy" } : { applied: [], proposedForApproval: [], rejected: [], report: "r" }).agent, _n, _n, null)' (Join-Path $src 'workflows/tidy.js')
Remove-Item Env:KIT_UNITS_OUT
$roAll = @((Invoke-TestScript $D local bench runon -Json).out | ConvertFrom-Json | ForEach-Object { $_.units.unit })
$roSeen = @(Get-Content $roOut | ForEach-Object { $roP = $_ -split "`t"; "$($roP[0]):$((($roP[1] -split '[:@~]')[0]) -replace '-retry$', '')" } | Sort-Object -Unique)
$roMiss = @($roSeen | Where-Object { $_ -notin $roAll })
Expect "runOn generator: every step the buildy / testy / tidy sims ran is a listed unit ($($roSeen.Count) seen, $($roAll.Count) units; missing: $($roMiss -join ', '))" ($roSeen.Count -ge 12 -and -not $roMiss.Count -and $roAll.Count -ge 100)
# lint RUNON: kit.example.json names every unit once (an unknown or a missing one fails), a workflow step label maps to a declared unit
$roPy = Join-Path (Kd) 'rolint.py'; Set-Content $roPy @'
import json, sys, types
sys.path.insert(0, sys.argv[1] + '/skills/bossy'); import kitbag
src = open(sys.argv[1] + '/' + kitbag.PATHS_JSON, encoding='utf-8').read(); d = json.loads(src); ro = d['models']['runOn']
ro.pop('devy@fix'); ro['devy@typo'] = 'cloud'; ro['revy@mr'] = 'maybe'
k = types.SimpleNamespace(dir=sys.argv[1], texts={kitbag.PATHS_JSON: json.dumps(d), 'workflows/x.js': "await agent(p, { label: `zzz:${a}`, agentType: 'devy' })"}, workflows={'buildy': 'workflows/x.js'})
out = []; kitbag.runon_lint(k, kitbag.manifest(sys.argv[1]), lambda c, w, m: out.append(f'{c} {w} {m}')); print('\n'.join(out))
'@ -Encoding utf8
$roLn = @(python -X utf8 $roPy $src 2>&1) -join "`n"
Expect "lint RUNON: an unknown unit, a missing one, a bad value, a step label no unit declares ($($roLn -replace '\s+', ' '))" ($roLn -match 'RUNON .*"devy@typo" is no run unit' -and $roLn -match 'misses unit "devy@fix"' -and $roLn -match '"revy@mr" = "maybe"' -and $roLn -match 'workflows/x\.js:1.*step unit devy:zzz')
Stop-Job $srv -ErrorAction SilentlyContinue; Remove-Job $srv -Force -ErrorAction SilentlyContinue
Remove-Item Env:LM_TEST_TOKEN; Remove-TestKit $k
Complete-Tests
