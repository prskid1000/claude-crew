<#
local-model.ps1: Claude Code, Claude Desktop or VS Code on a local model server (models.local), one seat per client.
  & <kit>/skills/crafty/crafty.ps1 local <claude|desktop|code> [-Model <id>] [-Print] [-Json] [-Unsafe] [-WaitMinutes <m>] [-- <client args>]
      claude runs in this terminal, desktop / code start detached (close an open instance first: it keeps its env).
      From pwsh quote the separator ('--'): a bare -- ends PowerShell's own parameters and never arrives.
      -Print: the command, env names and values (tokens redacted); starts nothing. -Unsafe: adds the client's permission-skip
      flag (flagged.ps1 unsafeflag) for a person's own interactive session only (refused from an agent shell, piped input or
      -PromptFile: agents never skip permissions).
  & <kit>/skills/crafty/crafty.ps1 local claude -PromptFile <f> [-SchemaFile <f>] [-AgentType <crew>] [-Agent <id>]
      headless, the prompt on stdin: claude -p --output-format json [--json-schema] [--agent]
  & <kit>/skills/crafty/crafty.ps1 local status [-Json]   mode, runOn counts + fallbacks in 24 h, server models, seats, RAM, token set or not
  & <kit>/skills/crafty/crafty.ps1 local resolve -Unit <unit> [-Json]   cloud | local for one run unit (models.mode wins over
      models.runOn) + how a local one starts; the coordinator asks it before each spawn, launch -Self puts the local units in CONFIG
  & <kit>/skills/crafty/crafty.ps1 local run -JobFile <f> [-Fnv <hash>] [-DeadlineSec 540]   one workflow step locally: the job { unit, agentType,
      schema, prompt } through local claude (every check below); prints the step's JSON on one line, or exits 3 with
      "FALLBACK cloud[ (started)]: <why>" (not local, refused, no seat; started: client error, deadline, no JSON), logged
  & <kit>/skills/crafty/crafty.ps1 local bench build|run|score|report|diff|coverage|runon [-Model <id>] [-Json] [-Set <s>] [-Roles a,b] [-Ids x,y] [-Against <id>] [-Add] [-Degrade <set>] [-Judge <model>] [-Write <f>] [-WriteRunonEvidence] ...
      recorded real steps replayed on the local model, scored per role; run units and their bench coverage (localbench.py header)
Checks before a start, in order: forbidden model ids (models.local.forbiddenModels, wildcards: -Model, ANTHROPIC_*MODEL,
--model / -m in the client args), free RAM (Get-GateAvailGB - models.local.needGB >= Get-KitKeepFreeGB; skipped while the requested model is resident: GET /v1/models/active), the server
(GET <baseUrl>/v1/models within models.local.probeSec lists the model), a seat (lease local-model, models.local.maxConcurrent;
full: a mixed-mode headless run with models.local.overflow cloud exits 3 OVERFLOW at once, else waits up to -WaitMinutes /
models.local.queueMinutes, then exits 3 QUEUED).
Inputs: kit.local.json models.mode (cloud | local: every unit; mixed: models.runOn; env KIT_MODEL_MODE wins: every client started
here gets local), models.runOn { <unit>: cloud | local | { on, evidence } } (units: local bench runon), models.local { baseUrl,
token (env:<VAR> | secret:<name>; never printed), defaultModel, forbiddenModels, commands, env (name: value, null drops a
default), overflow, maxConcurrent, needGB, probeSec, queueMinutes }
(README "Configuration"). Lease state: video.ps1 Get-KitLocalAiState local-model. Outputs: text, JSON with -Json.
Exit codes: 0 ok · 1 refused (forbidden model, RAM, server down, model not served, client missing) · 2 usage · 3 no seat, run: fall back to the cloud · 4 run: MISMATCH (job file differs from -Fnv) · else the client's (its 1-3 as 11-13).
Sections: L33 config · L145 checks · L175 verb
#>
#Requires -Version 7
# ---- config: models.mode, models.local, the token, each client's env and arguments
function Get-KitModelMode { $mm = "$(if ($env:KIT_MODEL_MODE) { $env:KIT_MODEL_MODE } else { Get-KitSetting 'models.mode' 'cloud' })".ToLower(); if ($mm -in 'cloud', 'local', 'mixed') { $mm } else { 'cloud' } }
# models.runOn per run unit (<agent>, <agent>@<kind>, <agentType>:<step label>): local | cloud (anything else, unset: cloud)
function Get-KitRunOnMap {
  $ro = [ordered]@{}
  foreach ($rp in @(Get-KitProps (Get-KitSetting 'models.runOn' $null))) { if ($rp.Name -like '_*') { continue }
    $rv = if ($rp.Value -is [string]) { $rp.Value } else { Get-KitMember $rp.Value 'on' }; $ro[$rp.Name] = $(if ("$rv".ToLower() -eq 'local') { 'local' } else { 'cloud' }) }
  $ro
}
# one unit: models.mode cloud | local forces it, mixed follows models.runOn; an unknown unit runs on the cloud
function Resolve-KitRunOn([string]$Unit) {
  $mo = Get-KitModelMode; $map = Get-KitRunOnMap
  $on, $why = if ($mo -ne 'mixed') { $mo, "models.mode $mo" } elseif ($map.Contains($Unit)) { $map[$Unit], 'models.runOn' } else { 'cloud', 'not in models.runOn (local bench runon lists the units)' }
  [pscustomobject]@{ unit = $Unit; on = $on; why = $why; mode = $mo }
}
# CONFIG runOn for the workflows (usage.ps1 Get-KitWorkflowConfig): $null when every unit is cloud (the workflows run unchanged)
function Get-KitRunOnConfig {
  $mo = Get-KitModelMode; $map = Get-KitRunOnMap
  $units = if ($mo -eq 'local') { @('*') } elseif ($mo -eq 'mixed') { @($map.Keys | Where-Object { $map[$_] -eq 'local' }) } else { @() }
  if (-not $units.Count) { return $null }
  $dir = "$((Get-KitPath 'agents' -Create) -replace '\\', '/')/local-runs"   # agent scratch: the STEP's Write tool makes the folder
  [ordered]@{ units = $units; step = "STEP: run one workflow step on the local model, nothing else:`n1. Write the line between the markers to $dir/{name}.json with the Write tool, byte for byte (one line of JSON; no markers, nothing added):`n<<<JOB`n{job}`nJOB>>>`n2. Run in PowerShell (pwsh 7; tool timeout 600000): & $($KitLibDir -replace '\\', '/')/crafty.ps1 local run -JobFile '$dir/{name}.json' -Fnv {fnv}`nReturn ok=true when it exits 0 (else ok=false); output = its last output line, verbatim (MISMATCH: write the file again once, re-run)."; redo = 'A local run of this step stopped part way: first find what is done (wt status, git log, the board, MR and tracker state), never apply a change twice; then finish it.' }
}
function Add-KitRunOnFallback([string]$Unit, [string]$Why) {
  $lf = Get-KitPath 'local-fallbacks' -Create; $ln = [ordered]@{ at = (Get-Date).ToString('s'); unit = $Unit; why = "$Why".Trim() -replace '\s+', ' ' } | ConvertTo-Json -Compress
  Add-Content -LiteralPath $lf -Value $ln -Encoding utf8
  if ((Get-Item -LiteralPath $lf).Length -gt 1MB) { $keep = @(Get-Content -LiteralPath $lf -Tail 2000); Set-Content -LiteralPath $lf -Value $keep -Encoding utf8 }   # last 2000 lines
}
function Get-KitRunOnFallbacks([double]$Hours = 24) {
  $lf = Get-KitPath 'local-fallbacks'; if (-not (Test-Path -LiteralPath $lf)) { return @() }
  $since = (Get-Date).AddHours(-$Hours)
  @(Get-Content -LiteralPath $lf -Tail 2000 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and [datetime]$_.at -ge $since })
}
# status and the dashboard Machine row: $null without models.runOn
function Get-KitRunOnCounts {
  $map = Get-KitRunOnMap; $mo = Get-KitModelMode; if (-not $map.Count -and $mo -ne 'local') { return $null }
  if (-not $map.Count) { return [pscustomobject]@{ mode = $mo; local = 'all'; cloud = 0; fallbacks = @(Get-KitRunOnFallbacks).Count; last = '' } }
  $nl = if ($mo -eq 'local') { $map.Count } elseif ($mo -eq 'cloud') { 0 } else { @($map.Values | Where-Object { $_ -eq 'local' }).Count }
  $fb = @(Get-KitRunOnFallbacks)
  [pscustomobject]@{ mode = $mo; local = $nl; cloud = $map.Count - $nl; fallbacks = $fb.Count; last = $(if ($fb.Count) { "$($fb[-1].unit): $($fb[-1].why)" }) }
}
function Get-KitLocalModelConfig {
  $lc = Get-KitSetting 'models.local' $null
  $cmds = @{ claude = @('claude'); code = @('code', 'code-insiders'); desktop = @() }
  foreach ($cp in @(Get-KitProps (Get-KitMember $lc 'commands'))) { $cmds[$cp.Name] = @($cp.Value | Where-Object { $_ }) }
  [pscustomobject]@{
    baseUrl = "$(Get-KitSetting 'models.local.baseUrl' 'http://localhost:8080')".TrimEnd('/')
    token = "$(Get-KitSetting 'models.local.token' 'env:LOCAL_MODEL_TOKEN')"; defaultModel = "$(Get-KitSetting 'models.local.defaultModel' '')"
    forbidden = @(Get-KitSetting 'models.local.forbiddenModels' @() | Where-Object { $_ })
    commands = $cmds; env = (Get-KitMember $lc 'env'); retiredUse = @(Get-KitSetting 'models.local.use' @() | Where-Object { $_ })
    overflow = "$(Get-KitSetting 'models.local.overflow' 'cloud')".ToLower(); maxConcurrent = [math]::Max(1, [int](Get-KitParam 'models.local.maxConcurrent'))
    needGB = [double](Get-KitParam 'models.local.needGB')
  }
}
# the token's value, never printed: env:<VAR> (this process, then the user's saved variables) | secret:<name> (secrets.store)
function Get-KitLocalModelToken([string]$Ref) {
  if ($Ref -match '^env:(?<v>\w+)$') { $tv = [Environment]::GetEnvironmentVariable($Matches.v); if (-not $tv -and $KitIsWindows) { $tv = [Environment]::GetEnvironmentVariable($Matches.v, 'User') }; return "$tv" }
  if ($Ref -match '^secret:.') { return "$(try { Resolve-KitSecretRef $Ref } catch { '' })" }
  if ($Ref) { Write-Warning 'models.local.token takes env:<VAR> or secret:<name> (a token value never sits in a kit file): ignored' }; ''
}
function Test-KitLocalSecretName([string]$Name) { $Name -match '(^|_)(AUTH_TOKEN|API_KEY|TOKEN|KEY|SECRET|PASSWORD)$' }
function Get-KitLocalModelEnv([string]$Client, $Cfg, [string]$Token, [string]$Model) {
  $ev = [ordered]@{ KIT_TOOL = 'local'; KIT_MODEL_MODE = 'local' }   # kit budgets (usage.ps1 Get-KitTool) and mode see the session as local
  $tk = if ($Token) { $Token } else { 'local' }   # the client needs a non-empty key; a server without auth ignores it
  $ev.ANTHROPIC_BASE_URL = $Cfg.baseUrl; $ev.ANTHROPIC_AUTH_TOKEN = $tk
  # a local server: no prompt-cache markers, telemetry, betas, 1M window or tool search; slow tokens: long shell timeouts
  foreach ($dv in @('DISABLE_PROMPT_CACHING=1', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1', 'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1', 'CLAUDE_CODE_ATTRIBUTION_HEADER=0',
      'CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384', 'ENABLE_TOOL_SEARCH=false', 'CLAUDE_CODE_DISABLE_1M_CONTEXT=1', 'BASH_DEFAULT_TIMEOUT_MS=1800000', 'BASH_MAX_TIMEOUT_MS=3600000')) { $dp = $dv -split '=', 2; $ev[$dp[0]] = $dp[1] }
  if ($KitIsWindows) { $ev.CLAUDE_CODE_USE_POWERSHELL_TOOL = '1' }   # the kit runs python and node from the PowerShell tool
  if ($Model) { $ev.ANTHROPIC_MODEL = $Model }
  foreach ($op in @(Get-KitProps $Cfg.env)) { if ($null -eq $op.Value -or "$($op.Value)" -eq '') { $ev.Remove($op.Name) } else { $ev[$op.Name] = "$($op.Value)" } }
  $ev
}
# every model id a start would use: -Model, ANTHROPIC_*MODEL / CLAUDE_CODE_SUBAGENT_MODEL (the map, else inherited), --model,
# -m, --fallback-model (=<id> too)
function Get-KitLocalModelIds($EnvMap, [string[]]$Rest, [string]$Model) {
  $mids = [Collections.Generic.List[string]]::new(); if ($Model) { $mids.Add($Model) }
  foreach ($ek in @(@($EnvMap.Keys) + @(Get-ChildItem env: | ForEach-Object Name) | Select-Object -Unique)) {
    if ($ek -match '^(ANTHROPIC_(\w+_)?MODEL|CLAUDE_CODE_SUBAGENT_MODEL)$') { $mv = if ($EnvMap.Contains($ek)) { $EnvMap[$ek] } else { [Environment]::GetEnvironmentVariable($ek) }; if ($mv) { $mids.Add("$mv") } } }
  for ($ri = 0; $ri -lt $Rest.Count; $ri++) { $ra = "$($Rest[$ri])"; $nx = if ($ri + 1 -lt $Rest.Count) { "$($Rest[$ri + 1])" }
    if ($ra -in '--model', '-m', '--fallback-model' -and $nx) { $mids.Add($nx) } elseif ($ra -match '^--(fallback-)?model=(.+)$') { $mids.Add($Matches[2]) } }
  @($mids | Select-Object -Unique)
}
# the token's config reference for output: a value put there by mistake is never shown
function Format-KitLocalTokenRef([string]$Ref) { if ($Ref -match '^(env|secret):\w') { $Ref } elseif ($Ref) { '<a value, ignored: use env:<VAR> | secret:<name>>' } else { '' } }
# --agent applies the crew file's tools allowlist (drops StructuredOutput: --json-schema then returns prose) and its model alias (not the one the checks saw): hand the agent over inline
function Get-KitLocalModelAgentJson([string]$Type) {
  $af = Join-Path $KitRoot "agents/$Type.md"; if (-not (Test-Path -LiteralPath $af -PathType Leaf)) { return $null }
  $mt = [regex]::Match(((Get-Content -LiteralPath $af -Raw) -replace "`r`n", "`n"), '(?s)\A---\n(.*?)\n---\n(.*)\z'); if (-not $mt.Success) { return $null }
  $fm = @{}; foreach ($fl in $mt.Groups[1].Value -split "`n") { if ($fl -match '^(\w+):\s*(.*)$') { $fm[$Matches[1]] = ($Matches[2].Trim() -replace '^(["''])(.*)\1$', '$2') -replace '\\"', '"' } }
  $tl = @(("$($fm.tools)" -replace '^\[|\]$', '') -split ',\s*' | Where-Object { $_ }); if (-not $tl.Count) { return $null }   # no allowlist: nothing is dropped
  $ad = [ordered]@{ description = "$($fm.description)"; prompt = $mt.Groups[2].Value.Trim(); tools = @($tl + 'StructuredOutput' | Select-Object -Unique) }; $ad.model = 'inherit'   # the run uses ANTHROPIC_MODEL: the model the RAM and forbidden checks saw, never the crew file's alias
  @{ $Type = $ad } | ConvertTo-Json -Depth 5 -Compress
}
function Get-KitLocalModelArgs([string]$Client, $Cfg, [string]$Model, [bool]$Unsafe, [string]$PromptFile, [string]$SchemaFile, [string]$AgentType, [string[]]$Rest) {
  $av = [Collections.Generic.List[string]]::new(); $skip = if ($Unsafe) { "$(& (Join-Path $KitLibDir 'flagged.ps1') unsafeflag -Text $Client)" }   # its name makes pwsh log a script
  if ($Client -eq 'claude') {
    if ($Unsafe) { $av.Add($skip) }
    if ($PromptFile) { $av.AddRange([string[]]@('-p', '--output-format', 'json')); if ($SchemaFile) { $av.AddRange([string[]]@('--json-schema', (Get-Content -LiteralPath $SchemaFile -Raw).Trim())) }; if ($AgentType) { $aj = Get-KitLocalModelAgentJson $AgentType; if (-not $aj -and (Test-Path -LiteralPath (Join-Path $KitRoot "agents/$AgentType.md"))) { Write-Warning "agent ${AgentType}: no tools list parsed, StructuredOutput may be dropped" }; if ($aj) { $av.AddRange([string[]]@('--agents', $aj)) }; $av.AddRange([string[]]@('--agent', $AgentType)) } }
  }
  foreach ($ra in $Rest) { $av.Add("$ra") }
  $av.ToArray()
}
# the client's program: commands.<client> (first one found); desktop: the Claude Desktop app install
function Resolve-KitLocalModelExe([string]$Client, $Cfg) {
  foreach ($cn in @($Cfg.commands[$Client])) { $gc = Get-Command $cn -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($gc) { return $gc.Source }; if (Test-Path -LiteralPath $cn -PathType Leaf) { return $cn } }
  if ($Client -ne 'desktop') { return $null }
  if ($KitIsWindows) { $al = try { (Get-AppxPackage -Name 'Claude' -ErrorAction Stop | Select-Object -First 1).InstallLocation } catch { '' }; if ($al -and (Test-Path -LiteralPath (Join-Path $al 'app/claude.exe'))) { return (Join-Path $al 'app/claude.exe') } }
  elseif ($KitIsMac -and (Test-Path -LiteralPath '/Applications/Claude.app/Contents/MacOS/Claude')) { return '/Applications/Claude.app/Contents/MacOS/Claude' }
  $null
}

# ---- checks: RAM, the server's models, seats (lease local-model)
# a model already in memory needs no new RAM: GET <baseUrl>/v1/models/active (Telecode-style: alive, active_model); a server without it = not resident
function Test-KitLocalModelResident($Cfg, [string]$Token, [string]$Model) {
  $hd = @{}; if ($Token) { $hd.Authorization = "Bearer $Token"; $hd['x-api-key'] = $Token }
  try { $ac = Invoke-RestMethod -Uri "$($Cfg.baseUrl)/v1/models/active" -Headers $hd -TimeoutSec ([int](Get-KitParam 'models.local.probeSec')) -ErrorAction Stop } catch { return $false }
  $am = "$($ac.active_model)"; [bool]($ac.alive -and $am -and -not (Test-KitLocalModelForbidden $Cfg $am) -and (-not $Model -or $am -eq $Model))
}
function Test-KitLocalModelRam($Cfg, [string]$Token = '', [string]$Model = '') {
  $mem = Get-SysMem; $avl = Get-GateAvailGB $mem; $flo = Get-KitKeepFreeGB; $ok = ($avl - $Cfg.needGB -ge $flo); $res = $false
  if (-not $ok) { $res = Test-KitLocalModelResident $Cfg $Token $Model; $ok = $res }
  [pscustomobject]@{ ok = $ok; resident = $res; availGB = $avl; needGB = $Cfg.needGB; keepFreeGB = $flo }
}
function Get-KitLocalModelServed($Cfg, [string]$Token) {
  $hd = @{}; if ($Token) { $hd.Authorization = "Bearer $Token"; $hd['x-api-key'] = $Token }
  try { $rs = Invoke-RestMethod -Uri "$($Cfg.baseUrl)/v1/models" -Headers $hd -TimeoutSec ([int](Get-KitParam 'models.local.probeSec')) -ErrorAction Stop; [pscustomobject]@{ up = $true; ids = @($rs.data | ForEach-Object { "$($_.id)" } | Where-Object { $_ }); error = '' } }
  catch { [pscustomobject]@{ up = $false; ids = @(); error = "$($_.Exception.Message)" -replace '\s+', ' ' } }
}
function Test-KitLocalModelForbidden($Cfg, [string]$Id) { [bool]@($Cfg.forbidden | Where-Object { $Id -like $_ }).Count }
# supervise and the dashboard Machine row: $null while the mode is cloud and nothing holds a seat
function Get-KitLocalModelSeats {
  $mo = Get-KitModelMode; $st = Get-KitLocalAiState 'local-model'
  if ($mo -eq 'cloud' -and -not $st.leases.Count) { return $null }
  $now = Get-Date
  [pscustomobject]@{ mode = $mo; used = $st.leases.Count; max = (Get-KitLocalModelConfig).maxConcurrent; waiting = $st.waiting.Count
    holders = @($st.leases | ForEach-Object { "$($_.agent) $([int]($now - [datetime]$_.at).TotalMinutes) min" }) }
}
function Format-KitLocalEnv($EnvMap, [string]$Token) {
  $shown = [ordered]@{}; foreach ($ek in @($EnvMap.Keys)) { $shown[$ek] = if (-not (Test-KitLocalSecretName $ek)) { $EnvMap[$ek] } elseif ($Token) { '<redacted>' } else { '<placeholder: no token>' } }; $shown
}

# ---- verb: crafty.ps1 local
function Invoke-Local {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('claude', 'desktop', 'code', 'status', 'bench', 'resolve', 'run')][string]$Client,
  [string]$Unit, [string]$JobFile, [string]$Fnv, [Alias('DeadlineSeconds')][int]$DeadlineSec,   # resolve, run
  [string]$Model, [switch]$Unsafe, [switch]$Print, [switch]$Json, [string]$PromptFile, [string]$SchemaFile, [string]$AgentType,
  [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }), [string]$Session, [double]$WaitMinutes = -1,
  [string]$Set, [string]$Roles, [string]$Ids, [string]$Against, [int]$N, [string]$Since, [string]$Transcripts, [Alias('TimeoutSeconds')][int]$TimeoutSec, [switch]$Force,   # bench
  [switch]$Add, [string]$Degrade, [string]$Judge, [string]$Write, [switch]$WriteRunonEvidence, [int]$Min,   # bench build / runon / report / coverage
  [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$Rest = @($Rest | Where-Object { $null -ne $_ })
if ($Client -eq 'bench') {   # the replay bench: localbench.py (each run step comes back here as local claude)
  $ba = @($Rest) + @('-Agent', $Agent) + @(if ($Json) { '-Json' }) + @(if ($Force) { '-Force' }) + @(if ($Add) { '-Add' }) + @(if ($WriteRunonEvidence) { '-WriteRunonEvidence' }) + @(if ($N) { '-N', $N }) + @(if ($Min) { '-Min', $Min }) + @(if ($TimeoutSec) { '-TimeoutSec', $TimeoutSec })
  foreach ($bp in @(@('-Model', $Model), @('-Set', $Set), @('-Roles', $Roles), @('-Ids', $Ids), @('-Against', $Against), @('-Degrade', $Degrade), @('-Judge', $Judge), @('-Since', $Since), @('-Transcripts', $Transcripts), @('-Write', $Write))) { if ($bp[1]) { $ba += $bp } }
  & (Get-Python) -X utf8 (Join-Path $KitLibDir 'adapters/localbench.py') @ba; $global:LASTEXITCODE = $LASTEXITCODE; if ($LASTEXITCODE) { exit $LASTEXITCODE }; return
}
if ($Client -eq 'resolve') {   # one run unit: cloud | local and how a local one starts (the coordinator, before each spawn)
  if (-not $Unit) { Stop-KitVerb 'local resolve: -Unit <agent | agent@kind | agentType:step label> (local bench runon lists them)' }
  $rs = Resolve-KitRunOn $Unit
  $rs | Add-Member launch $(if ($rs.on -eq 'local') { "& $($KitLibDir -replace '\\', '/')/crafty.ps1 local claude -AgentType $(($Unit -split '[:@]')[0]) -PromptFile <prompt file> [-SchemaFile <schema file>]$(if ($Unit -match '^\w+:') { " (a workflow step: local run -JobFile)" })" } else { '' })
  if ($Json) { return ($rs | ConvertTo-Json -Compress) }
  "$($rs.on)   $Unit ($($rs.why))"; if ($rs.launch) { "launch: $($rs.launch); refused or exit 3: spawn it on the cloud and say so (Add-KitRunOnFallback logs a workflow step's)" }; return
}
if ($Client -eq 'run') {   # one workflow step (a job file a STEP wrote) on the local model; any failure: exit 3, the workflow runs it on the cloud
  $raw = try { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $JobFile).Path).TrimStart([char]0xFEFF).TrimEnd("`r", "`n") } catch { Stop-KitVerb "local run: -JobFile <job json { unit, agentType, schema, prompt }>: $($_.Exception.Message)" }
  if ($Fnv -and (Get-KitFnv $raw) -ne $Fnv.Trim().ToLower()) { Stop-KitVerb "MISMATCH: the job file hashes to $(Get-KitFnv $raw), not ${Fnv}: write it again, byte for byte" 4 }   # a re-typed prompt never runs changed
  $job = try { $raw | ConvertFrom-Json -ErrorAction Stop } catch { Stop-KitVerb "local run: the job file is no JSON: $($_.Exception.Message)" }
  # before the client starts: "FALLBACK cloud:"; after: "FALLBACK cloud (started):" (the cloud step first checks what is done)
  $fall = { param($why, [switch]$Started) Add-KitRunOnFallback "$($job.unit)" "$(if ($Started) { 'started: ' })$why"; Stop-KitVerb "FALLBACK cloud$(if ($Started) { ' (started)' }): $($job.unit) $why" 3 }
  $rs = Resolve-KitRunOn "$($job.unit)"; if ($rs.on -ne 'local') { & $fall "is cloud ($($rs.why))" }
  $stem = $JobFile -replace '\.json$', ''; $pf = "$stem.prompt.md"; Set-Content -LiteralPath $pf -Value "$($job.prompt)" -Encoding utf8 -NoNewline
  $la = @('-NoProfile', '-File', (Join-Path $KitLibDir 'crafty.ps1'), 'local', 'claude', '-PromptFile', $pf, '-AgentType', "$($job.agentType)", '-Agent', $Agent)
  if ($job.schema) { $sf = "$stem.schema.json"; Set-Content -LiteralPath $sf -Value (ConvertTo-Json -InputObject $job.schema -Depth 30 -Compress) -Encoding utf8; $la += '-SchemaFile', $sf }
  $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path); foreach ($lx in $la) { $psi.ArgumentList.Add("$lx") }
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
  $child = [Diagnostics.Process]::Start($psi); $so = $child.StandardOutput.ReadToEndAsync(); $se = $child.StandardError.ReadToEndAsync()
  # the STEP's tool times out at 600 s: past the deadline the client tree is ended, never left running next to the cloud step
  if (-not $child.WaitForExit([int](1000 * $(if ($DeadlineSec -gt 0) { $DeadlineSec } else { 540 })))) { try { $child.Kill($true) } catch { }; & $fall "no answer in $(if ($DeadlineSec -gt 0) { $DeadlineSec } else { 540 }) s (client ended)" -Started }
  $child.WaitForExit(); $rc = $child.ExitCode; $out = @("$($so.Result)$($se.Result)" -split "\r?\n" | Where-Object { $_ })
  if ($rc -in 1, 2, 3) { & $fall "launcher exit ${rc}: $((@($out | Where-Object { $_ -match 'REFUSED|OVERFLOW|QUEUED' })[0], $out[-1] | Where-Object { $_ } | Select-Object -First 1))" }
  if ($rc) { & $fall "client exit ${rc}: $($out[-1])" -Started }
  $res = $null   # claude -p --output-format json: the last JSON line with result / structured_output
  foreach ($ol in [object[]]@($out)[($out.Count - 1)..0]) { $oj = try { $ol | ConvertFrom-Json -ErrorAction Stop } catch { $null }; if ($oj -and @((Get-KitProps $oj).Name | Where-Object { $_ -in 'result', 'structured_output' }).Count) { $res = $oj; break } }
  $val = if ($null -ne $res.structured_output) { $res.structured_output } elseif ($res.result) { try { "$($res.result)".Trim() -replace '^```(json)?\s*|\s*```$', '' | ConvertFrom-Json -NoEnumerate -ErrorAction Stop } catch { $null } }
  if ($null -eq $val -or $val -is [string]) { & $fall "no JSON answer ($("$($res.result)$(if (-not $res) { $out[-1] })".Trim() -replace '\s+', ' ' | ForEach-Object { $_.Substring(0, [math]::Min(160, $_.Length)) }))" -Started }
  return (ConvertTo-Json -InputObject $val -Depth 30 -Compress)
}
$cfg = Get-KitLocalModelConfig; $tok = Get-KitLocalModelToken $cfg.token
if ($Client -eq 'status') {
  $sv = Get-KitLocalModelServed $cfg $tok; $ram = Test-KitLocalModelRam $cfg $tok $cfg.defaultModel; $sts = Get-KitLocalAiState 'local-model'; $mo = Get-KitModelMode
  $roc = Get-KitRunOnCounts
  $so = [ordered]@{ mode = $mo; runOn = $roc; baseUrl = $cfg.baseUrl; up = $sv.up; served = @($sv.ids); forbidden = @($sv.ids | Where-Object { Test-KitLocalModelForbidden $cfg $_ }); error = $sv.error
    seats = $sts.leases.Count; maxConcurrent = $cfg.maxConcurrent; overflow = $cfg.overflow; holders = @($sts.leases | ForEach-Object { "$($_.agent)" }); waiting = $sts.waiting.Count; ram = $ram; token = $(if ($tok) { 'set' } else { 'unset' }) }
  if ($Json) { return ($so | ConvertTo-Json -Depth 5 -Compress) }
  "mode: $mo$(if ($mo -eq 'mixed') { " · overflow $($cfg.overflow)" })"
  "runOn: $(if ($roc) { "$($roc.local) local / $($roc.cloud) cloud · fallbacks to the cloud in 24 h: $($roc.fallbacks)$(if ($roc.last) { " (last $($roc.last))" })" } else { 'not set: every unit cloud (local bench runon -Write <kit.local.json> lists them all)' })"
  if ($cfg.retiredUse.Count) { "WARNING: models.local.use is retired and ignored: local bench runon -Write <kit.local.json> folds it into models.runOn" }
  "server $($cfg.baseUrl): $(if ($sv.up) { "up, serves $(@($sv.ids) -join ', ')$(if ($so.forbidden.Count) { " (forbidden: $($so.forbidden -join ', '))" })" } else { "DOWN ($($sv.error))" })"
  "seats: $($sts.leases.Count)/$($cfg.maxConcurrent)$(if ($sts.leases.Count) { " ($($so.holders -join ', '))" }) · $($sts.waiting.Count) waiting"
  "RAM: $($ram.availGB) GB available, a start needs $($ram.needGB) GB over the $($ram.keepFreeGB) GB floor: $(if ($ram.resident) { 'ok, a model is resident (no new start)' } elseif ($ram.ok) { 'ok' } else { 'SHORT' })"
  "token ($(Format-KitLocalTokenRef $cfg.token)): $($so.token)"; return
}
$headless = [bool]$PromptFile
if ($headless -and $Client -ne 'claude') { Stop-KitVerb "local ${Client}: -PromptFile runs claude only" }
if ($headless -and -not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Stop-KitVerb "local: no prompt file $PromptFile" }
if ($SchemaFile -and -not ($headless -and (Test-Path -LiteralPath $SchemaFile -PathType Leaf))) { Stop-KitVerb "local: -SchemaFile needs -PromptFile and an existing file ($SchemaFile)" }
if ($AgentType -and -not $headless) { Stop-KitVerb 'local: -AgentType runs a crew agent headless: claude -PromptFile only' }
if ($Unsafe -and $Client -in 'desktop', 'code') { Stop-KitVerb "local ${Client}: -Unsafe has no flag there" }
if ($Unsafe -and -not $Print -and ($headless -or $env:CLAUDECODE -or $env:CLAUDE_AGENT -or [Console]::IsInputRedirected)) { Stop-KitVerb "local: -Unsafe is for a person's own interactive session (agents never skip permissions): refused from an agent shell, piped input or -PromptFile" }
$mdl = if ($Model) { $Model } elseif ($headless) { $cfg.defaultModel } else { '' }   # interactive claude: the server's default unless -Model
$envMap = Get-KitLocalModelEnv $Client $cfg $tok $mdl
$bad = @(Get-KitLocalModelIds $envMap $Rest $mdl | Where-Object { Test-KitLocalModelForbidden $cfg $_ })
if ($bad.Count) { Stop-KitVerb "REFUSED: model $($bad -join ', ') is forbidden here (models.local.forbiddenModels)" 1 }
$exe = Resolve-KitLocalModelExe $Client $cfg
if ($AgentType -and $exe -match '\.(cmd|bat)$') { Stop-KitVerb "REFUSED: $exe is a .cmd shim: cmd.exe cuts the inline crew agent (quotes, 8191 chars); use the native claude install (models.local.commands.claude)" 1 }
$argv = @(Get-KitLocalModelArgs $Client $cfg $mdl $Unsafe.IsPresent $PromptFile $SchemaFile $AgentType $Rest)
if ($Print) {
  $po = [ordered]@{ client = $Client; exe = "$exe"; args = $argv; model = $(if ($mdl) { $mdl } else { '(server default)' }); baseUrl = $cfg.baseUrl; mode = (Get-KitModelMode); token = $(if ($tok) { 'set' } else { 'unset' }); env = (Format-KitLocalEnv $envMap $tok) }
  if ($Json) { return ($po | ConvertTo-Json -Depth 5 -Compress) }
  "local ${Client}: $(if ($exe) { $exe } else { "(not found: models.local.commands.$Client)" }) $($argv -join ' ')"
  "server $($cfg.baseUrl) · model $($po.model) · token ($(Format-KitLocalTokenRef $cfg.token)) $($po.token) · nothing started (-Print)"
  foreach ($pe in $po.env.GetEnumerator()) { "  $($pe.Key)=$($pe.Value)" }; return
}
if (-not $exe) { Stop-KitVerb "REFUSED: $Client not found (models.local.commands.${Client}: $(@($cfg.commands[$Client]) -join ', '))" 1 }
$ram = Test-KitLocalModelRam $cfg $tok $mdl
if (-not $ram.ok) { Stop-KitVerb "REFUSED: RAM $($ram.availGB) GB available; a local start needs $($ram.needGB) GB over the $($ram.keepFreeGB) GB floor (models.local.needGB, gate.keepFreeGB)" 1 }
$sv = Get-KitLocalModelServed $cfg $tok
if (-not $sv.up) { Stop-KitVerb "REFUSED: no local model server at $($cfg.baseUrl) ($($sv.error)): start it or set models.local.baseUrl" 1 }
$okIds = @($sv.ids | Where-Object { -not (Test-KitLocalModelForbidden $cfg $_) })
if ($mdl -and $mdl -notin $sv.ids) { Stop-KitVerb "REFUSED: model $mdl is not served at $($cfg.baseUrl) (served: $($okIds -join ', '))" 1 }
if (-not $mdl -and @($sv.ids).Count -ne $okIds.Count) {   # no id named: a one-model server would answer with the forbidden one
  if ($cfg.defaultModel -and $cfg.defaultModel -in $okIds) { $mdl = $cfg.defaultModel; $envMap.ANTHROPIC_MODEL = $mdl }
  else { Stop-KitVerb "REFUSED: $($cfg.baseUrl) serves a forbidden model ($((@($sv.ids) | Where-Object { $_ -notin $okIds }) -join ', ')): pass -Model <an allowed id> or set models.local.defaultModel" 1 } }
$over = $headless -and (Get-KitModelMode) -eq 'mixed' -and $cfg.overflow -eq 'cloud'
$wait = if ($WaitMinutes -ge 0) { $WaitMinutes } elseif ($over) { 0 } else { [double](Get-KitParam 'models.local.queueMinutes') }
if (-not (Use-KitLocalAi 'local-model' -Agent $Agent -Session $Session -WaitMinutes $wait -Max $cfg.maxConcurrent)) {
  $full = "local model seats full ($($cfg.maxConcurrent)/$($cfg.maxConcurrent): $(@((Get-KitLocalAiState 'local-model').leases.agent) -join ', '))"
  if ($over) { Stop-KitVerb "OVERFLOW cloud: $full -> run this step on the cloud (models.local.overflow)" 3 }; Stop-KitVerb "QUEUED: $full after $wait min -> rerun" 3
}
if ($Client -in 'desktop', 'code') {
  try {
    # a <app>/bin/<x>.cmd shim (VS Code) starts the app and exits: start the app's exe so the seat follows the window
    if ($exe -match '\.(cmd|bat)$' -and (Split-Path (Split-Path $exe) -Leaf) -eq 'bin') { $ax = @(Get-ChildItem -LiteralPath (Split-Path (Split-Path $exe)) -Filter '*.exe' -File -ErrorAction SilentlyContinue | Where-Object Name -notmatch '^unins')[0]; if ($ax) { $exe = $ax.FullName } }
    $qa = @($argv | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } })   # Start-Process joins arguments with spaces
    $sp = @{ FilePath = $exe; Environment = @{} + $envMap; PassThru = $true }; if ($qa.Count) { $sp.ArgumentList = $qa }; if ($exe -match '\.(cmd|bat)$') { $sp.WindowStyle = 'Hidden' }
    $child = Start-Process @sp
    if ($child.WaitForExit(5000)) { Remove-KitLocalAi 'local-model'; Stop-KitVerb "REFUSED: $Client exited at once (code $($child.ExitCode)): an open instance took the call without this env (close it first), or set models.local.commands.$Client to the app's exe" 1 }
    $null = Update-KitLocalAi 'local-model' { param($st) foreach ($ls in @($st.leases)) { if ($ls.pid -eq $PID) { $ls.pid = $child.Id; $ls.pidStart = Get-KitPidStart $child.Id } } }   # the seat lives as long as the app
  } catch { Remove-KitLocalAi 'local-model'; throw }
  return "started $Client (pid $($child.Id)) on $($cfg.baseUrl); its seat frees when that process ends"
}
$saved = @{}; foreach ($ek in @($envMap.Keys)) { $saved[$ek] = [Environment]::GetEnvironmentVariable($ek) }
try {
  foreach ($ek in @($envMap.Keys)) { [Environment]::SetEnvironmentVariable($ek, $envMap[$ek]) }
  if ($headless) { Get-Content -LiteralPath $PromptFile -Raw | & $exe @argv } else { & $exe @argv }
  $rc = $LASTEXITCODE
} finally { foreach ($ek in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($ek, $saved[$ek]) }; Remove-KitLocalAi 'local-model' }   # a dot-sourced caller keeps its own env
$global:LASTEXITCODE = [int]$rc; if ($rc) { exit $(if ($rc -in 1, 2, 3) { 10 + $rc } else { [int]$rc }) }   # 1-3 are the verb's own codes
}
