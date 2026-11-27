#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/local-model.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/local-model.tests.ps1: crafty.ps1 local (adapters/local-model.ps1): config resolution, token redaction, no unsafe flag by
# default, -Unsafe refused from an agent shell, forbidden model and RAM refusals, server down / model not served (a fake
# /v1/models), seats full (OVERFLOW in mixed mode, QUEUED else), a resident model skips the RAM need, a schema run keeps StructuredOutput in the
# crew agent's tools, a fake client gets the env and its exit code, supervise line.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/local-model.ps1', 'skills/crafty/adapters/video.ps1', 'agents/steppy.md')
$k = New-TestKit lm; $D = Join-Path $k 'skills/crafty/crafty.ps1'; $cfgFile = Join-Path $k 'skills/crafty/kit.local.json'
$env:LM_TEST_TOKEN = 'tok-' + [guid]::NewGuid().ToString('N')   # a value the output must never show
$lmCfg = @{ baseUrl = 'http://127.0.0.1:9/'; token = 'env:LM_TEST_TOKEN'; defaultModel = 'small-a'; forbiddenModels = @('big-*-mtp'); env = @{ BASH_MAX_TIMEOUT_MS = $null; EXTRA_FLAG = '1' } }
& $J @{ models = @{ local = $lmCfg } } $cfgFile

$pc = Invoke-TestScript $D local claude -Print -Json
$pj = try { $pc.out | ConvertFrom-Json } catch { $null }
Expect "local: -Print resolves config: base URL trimmed, env overrides (one dropped, one added), no model for interactive claude ($($pc.out.Substring(0, [math]::Min(200, $pc.out.Length))))" ($pc.code -eq 0 -and $pj.env.ANTHROPIC_BASE_URL -eq 'http://127.0.0.1:9' -and $pj.env.EXTRA_FLAG -eq '1' -and -not $pj.env.BASH_MAX_TIMEOUT_MS -and $pj.env.KIT_MODEL_MODE -eq 'local' -and $pj.model -eq '(server default)')
$px = Invoke-TestScript $D local codex -Print
Expect "local: the token never printed, its env names redacted (claude + codex)" ($pc.out -notmatch [regex]::Escape($env:LM_TEST_TOKEN) -and $px.out -notmatch [regex]::Escape($env:LM_TEST_TOKEN) -and $pj.env.ANTHROPIC_AUTH_TOKEN -eq '<redacted>' -and $px.out -match 'KIT_LOCAL_MODEL_TOKEN=<redacted>' -and $pj.token -eq 'set')
Expect "local: codex gets the provider, the default model, the token by env name, never a value ($($px.code))" ($px.code -eq 0 -and $px.out -match 'model_providers\.local\.base_url=http://127\.0\.0\.1:9/v1' -and $px.out -match 'env_key=KIT_LOCAL_MODEL_TOKEN' -and $px.out -match '-m small-a')
Expect "local: no permission-skip flag by default (claude, codex)" ($pc.out -notmatch 'dangerously' -and $px.out -notmatch 'dangerously')
$pu = Invoke-TestScript $D local claude -Print -Unsafe; $pu2 = Invoke-TestScript $D local codex -Print -Unsafe
Expect "local: -Unsafe adds the flag only when asked ($($pu.code))" ($pu.out -match '--dangerously-skip-permissions' -and $pu2.out -match '--dangerously-bypass-approvals-and-sandbox')
$ua = Invoke-TestScript $D local claude -Unsafe
Expect "local: -Unsafe refused from an agent shell, exit 2 ($($ua.code))" ($ua.code -eq 2 -and $ua.out -match 'agents never skip permissions')
$fm = Invoke-TestScript $D local codex -Model big-27b-mtp -Print; $fa = Invoke-TestScript $D local claude -Print '--' --model big-x-mtp   # pwsh drops a bare -- (end of parameters): quoted
Expect "local: a forbidden model refused, from -Model and from the client args, exit 1 ($($fm.code) $($fa.code))" ($fm.code -eq 1 -and $fm.out -match 'REFUSED: model big-27b-mtp is forbidden' -and $fa.code -eq 1 -and $fa.out -match 'big-x-mtp')
$fb = @(@{ a = @('-Model', 'small-a', '--', '--model', 'big-1-mtp') }, @{ a = @('--', '--fallback-model', 'big-2-mtp') }, @{ a = @('--', '-c', 'model=big-3-mtp'); c = 'codex' }, @{ a = @(); e = 'big-4-mtp' }) | ForEach-Object {
  if ($_.e) { $env:ANTHROPIC_DEFAULT_SONNET_MODEL = $_.e }; $fr = Invoke-TestScript $D local $(if ($_.c) { $_.c } else { 'claude' }) -Print @($_.a); Remove-Item Env:ANTHROPIC_DEFAULT_SONNET_MODEL -ErrorAction SilentlyContinue; "$($fr.code):$(@($fr.out -split "`n" | Where-Object { $_ -match 'REFUSED' })[0] -replace '^.*model ([\w-]+).*$', '$1')" }
Expect "local: no way past the forbidden list: -Model before --, --fallback-model, codex -c model=, an inherited ANTHROPIC_*_MODEL ($($fb -join ' '))" (($fb -join ' ') -eq '1:big-1-mtp 1:big-2-mtp 1:big-3-mtp 1:big-4-mtp')
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
Expect "local: a headless run gets the env, -p json, the crew agent, the prompt on stdin; the client's exit 3 comes back as 13 (3 = no seat) ($($run.code): $($run.out.Trim()))" ($run.code -eq 13 -and $run.out -match "BASE=http://127\.0\.0\.1:$port MODEL=small-a ARGS=-p --output-format json --agent steppy IN=hello local")
$rst = pwsh -NoProfile -Command "`$null = & '$D' local claude -PromptFile '$pf' 2>&1; `"rc=`$LASTEXITCODE base=[`$env:ANTHROPIC_BASE_URL] tool=[`$env:KIT_TOOL]`"" 2>&1 | Select-Object -Last 1
Expect "local: run in the caller's own pwsh (& crafty.ps1), the client's env is gone after it ($rst)" ("$rst" -eq 'rc=13 base=[] tool=[]')
# a model already in memory needs no new RAM (GET /v1/models/active); another model, or a server without that route, still does; a schema run keeps StructuredOutput in the crew agent's tools
$tl2 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl2.Start(); $port2 = $tl2.LocalEndpoint.Port; $tl2.Stop()
$srv2 = Start-Job { param($p) $hl = [Net.HttpListener]::new(); $hl.Prefixes.Add("http://127.0.0.1:$p/"); $hl.Start(); $end = (Get-Date).AddMinutes(3)
  while ((Get-Date) -lt $end) { $ct = $hl.GetContextAsync(); while (-not $ct.Wait(500)) { if ((Get-Date) -ge $end) { break } }; if (-not $ct.IsCompleted) { break }
    $js = if ($ct.Result.Request.Url.AbsolutePath -eq '/v1/models/active') { '{"alive":true,"active_model":"small-a","inflight":0}' } else { '{"object":"list","data":[{"id":"small-a"},{"id":"small-b"}]}' }
    $by = [Text.Encoding]::UTF8.GetBytes($js); $rs = $ct.Result.Response; $rs.ContentType = 'application/json'; $rs.OutputStream.Write($by, 0, $by.Length); $rs.Close() } } -ArgumentList $port2
for ($wi = 0; $wi -lt 60; $wi++) { try { $tc = [Net.Sockets.TcpClient]::new('127.0.0.1', $port2); $tc.Dispose(); break } catch { Start-Sleep -Milliseconds 250 } }
$lmCfg.baseUrl = "http://127.0.0.1:$port2"; & $J @{ models = @{ local = $lmCfg } } $cfgFile; $env:CLAUDE_GATE_KEEP_FREE_GB = '99999'
$rr = Invoke-TestScript $D local claude -Model small-a -PromptFile $pf; $ro = Invoke-TestScript $D local claude -Model small-b -PromptFile $pf; $rs2 = Invoke-TestScript $D local status
Remove-Item Env:CLAUDE_GATE_KEEP_FREE_GB; $lmCfg.baseUrl = "http://127.0.0.1:$port"; & $J @{ models = @{ local = $lmCfg } } $cfgFile
Expect "local: RAM short but the requested model is resident: the client starts (exit 13), another model is still refused, status says resident ($($rr.code) $($ro.code))" ($rr.code -eq 13 -and $rr.out -match 'MODEL=small-a' -and $ro.code -eq 1 -and $ro.out -match 'REFUSED: RAM' -and $rs2.out -match 'a model is resident')
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
Stop-Job $srv -ErrorAction SilentlyContinue; Remove-Job $srv -Force -ErrorAction SilentlyContinue
Remove-Item Env:LM_TEST_TOKEN; Remove-TestKit $k
Complete-Tests
