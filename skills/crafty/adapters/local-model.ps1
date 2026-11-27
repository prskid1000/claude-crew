<#
local-model.ps1: Claude Code, Claude Desktop, VS Code or Codex on a local model server (models.local), one seat per client.
  & <kit>/skills/crafty/crafty.ps1 local <claude|desktop|code|codex> [-Model <id>] [-Print] [-Json] [-Unsafe] [-WaitMinutes <m>] [-- <client args>]
      claude / codex run in this terminal, desktop / code start detached (close an open instance first: it keeps its env).
      From pwsh quote the separator ('--'): a bare -- ends PowerShell's own parameters and never arrives.
      -Print: the command, env names and values (tokens redacted); starts nothing. -Unsafe: adds the client's permission-skip
      flag (flagged.ps1 unsafeflag) for a person's own interactive session only (refused from an agent shell, piped input or
      -PromptFile: agents never skip permissions).
  & <kit>/skills/crafty/crafty.ps1 local <claude|codex> -PromptFile <f> [-SchemaFile <f>] [-AgentType <crew>] [-Agent <id>]
      headless, the prompt on stdin: claude -p --output-format json [--json-schema] [--agent] · codex exec [--output-schema] -
  & <kit>/skills/crafty/crafty.ps1 local status [-Json]   mode, mixed-mode use list, server models, seats, RAM, token set or not
Checks before a start, in order: forbidden model ids (models.local.forbiddenModels, wildcards: -Model, ANTHROPIC_*MODEL,
--model / -m in the client args), free RAM (Get-GateAvailGB - models.local.needGB >= Get-KitKeepFreeGB), the server
(GET <baseUrl>/v1/models within models.local.probeSec lists the model), a seat (lease local-model, models.local.maxConcurrent;
full: a mixed-mode headless run with models.local.overflow cloud exits 3 OVERFLOW at once, else waits up to -WaitMinutes /
models.local.queueMinutes, then exits 3 QUEUED).
Inputs: kit.local.json models.mode (cloud | local | mixed; env KIT_MODEL_MODE wins: every client started here gets local),
models.local { baseUrl, token (env:<VAR> | secret:<name>; never printed), defaultModel, forbiddenModels, wireApi, commands,
env (name: value, null drops a default), use, overflow, maxConcurrent, needGB, probeSec, queueMinutes, streamIdleTimeoutMs }
(README "Configuration"). Lease state: video.ps1 Get-KitLocalAiState local-model. Outputs: text, JSON with -Json.
Exit codes: 0 ok · 1 refused (forbidden model, RAM, server down, model not served, client missing) · 2 usage · 3 no seat · else the client's.
Sections: L25 config · L98 checks · L118 verb
#>
#Requires -Version 7
# ---- config: models.mode, models.local, the token, each client's env and arguments
function Get-KitModelMode { $mm = "$(if ($env:KIT_MODEL_MODE) { $env:KIT_MODEL_MODE } else { Get-KitSetting 'models.mode' 'cloud' })".ToLower(); if ($mm -in 'cloud', 'local', 'mixed') { $mm } else { 'cloud' } }
# mixed mode: crew types or <type>:<label prefix> whose work fits a local model (peak context under 64k, low judgement)
$script:KitLocalUse = @('steppy', 'checky:close', 'checky:audit', 'devy:ship')
function Get-KitLocalModelConfig {
  $lc = Get-KitSetting 'models.local' $null
  $cmds = @{ claude = @('claude'); codex = @('codex'); code = @('code', 'code-insiders'); desktop = @() }
  foreach ($cp in @(Get-KitProps (Get-KitMember $lc 'commands'))) { $cmds[$cp.Name] = @($cp.Value | Where-Object { $_ }) }
  [pscustomobject]@{
    baseUrl = "$(Get-KitSetting 'models.local.baseUrl' 'http://localhost:8080')".TrimEnd('/')
    token = "$(Get-KitSetting 'models.local.token' 'env:LOCAL_MODEL_TOKEN')"; defaultModel = "$(Get-KitSetting 'models.local.defaultModel' '')"
    forbidden = @(Get-KitSetting 'models.local.forbiddenModels' @() | Where-Object { $_ }); wireApi = "$(Get-KitSetting 'models.local.wireApi' 'responses')"
    commands = $cmds; env = (Get-KitMember $lc 'env'); use = @(Get-KitSetting 'models.local.use' $script:KitLocalUse)
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
  $tk = if ($Token) { $Token } else { 'local' }   # both clients need a non-empty key; a server without auth ignores it
  if ($Client -eq 'codex') { $ev.KIT_LOCAL_MODEL_TOKEN = $tk }
  else {
    $ev.ANTHROPIC_BASE_URL = $Cfg.baseUrl; $ev.ANTHROPIC_AUTH_TOKEN = $tk
    # a local server: no prompt-cache markers, telemetry, betas, 1M window or tool search; slow tokens: long shell timeouts
    foreach ($dv in @('DISABLE_PROMPT_CACHING=1', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1', 'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1', 'CLAUDE_CODE_ATTRIBUTION_HEADER=0',
        'CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384', 'ENABLE_TOOL_SEARCH=false', 'CLAUDE_CODE_DISABLE_1M_CONTEXT=1', 'BASH_DEFAULT_TIMEOUT_MS=1800000', 'BASH_MAX_TIMEOUT_MS=3600000')) { $dp = $dv -split '=', 2; $ev[$dp[0]] = $dp[1] }
    if ($KitIsWindows) { $ev.CLAUDE_CODE_USE_POWERSHELL_TOOL = '1' }   # the kit runs python and node from the PowerShell tool
    if ($Model) { $ev.ANTHROPIC_MODEL = $Model }
  }
  foreach ($op in @(Get-KitProps $Cfg.env)) { if ($null -eq $op.Value -or "$($op.Value)" -eq '') { $ev.Remove($op.Name) } else { $ev[$op.Name] = "$($op.Value)" } }
  $ev
}
# every model id a start would use: -Model, the env's ANTHROPIC_*MODEL values, --model / -m / --model=<id> in the client args
function Get-KitLocalModelIds($EnvMap, [string[]]$Rest, [string]$Model) {
  $mids = [Collections.Generic.List[string]]::new(); if ($Model) { $mids.Add($Model) }
  foreach ($ek in @($EnvMap.Keys)) { if ($ek -match '^ANTHROPIC_(\w+_)?MODEL$' -and $EnvMap[$ek]) { $mids.Add("$($EnvMap[$ek])") } }
  for ($ri = 0; $ri -lt $Rest.Count; $ri++) { if ("$($Rest[$ri])" -in '--model', '-m' -and $ri + 1 -lt $Rest.Count) { $mids.Add("$($Rest[$ri + 1])") } elseif ("$($Rest[$ri])" -match '^--model=(.+)$') { $mids.Add($Matches[1]) } }
  @($mids | Select-Object -Unique)
}
function Get-KitLocalModelArgs([string]$Client, $Cfg, [string]$Model, [bool]$Unsafe, [string]$PromptFile, [string]$SchemaFile, [string]$AgentType, [string[]]$Rest) {
  $av = [Collections.Generic.List[string]]::new(); $skip = if ($Unsafe) { "$(& (Join-Path $KitLibDir 'flagged.ps1') unsafeflag -Text $Client)" }   # its name makes pwsh log a script
  if ($Client -eq 'claude') {
    if ($Unsafe) { $av.Add($skip) }
    if ($PromptFile) { $av.AddRange([string[]]@('-p', '--output-format', 'json')); if ($SchemaFile) { $av.AddRange([string[]]@('--json-schema', (Get-Content -LiteralPath $SchemaFile -Raw).Trim())) }; if ($AgentType) { $av.AddRange([string[]]@('--agent', $AgentType)) } }
  }
  elseif ($Client -eq 'codex') {
    if ($PromptFile) { $av.Add('exec') }
    $pv = 'model_providers.local'; $idle = [int64](Get-KitParam 'models.local.streamIdleTimeoutMs')
    foreach ($kv in @("$pv.name=local", "$pv.base_url=$($Cfg.baseUrl)/v1", "$pv.wire_api=$($Cfg.wireApi)", "$pv.env_key=KIT_LOCAL_MODEL_TOKEN", "$pv.stream_idle_timeout_ms=$idle", 'model_provider=local')) { $av.AddRange([string[]]@('-c', $kv)) }
    if ($Model) { $av.AddRange([string[]]@('-m', $Model)) }
    if ($Unsafe) { $av.Add($skip) }
    if ($PromptFile -and $SchemaFile) { $av.AddRange([string[]]@('--output-schema', $SchemaFile)) }
  }
  foreach ($ra in $Rest) { $av.Add("$ra") }
  if ($Client -eq 'codex' -and $PromptFile) { $av.Add('-') }   # exec reads the prompt from stdin
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
function Test-KitLocalModelRam($Cfg) { $mem = Get-SysMem; $avl = Get-GateAvailGB $mem; $flo = Get-KitKeepFreeGB; [pscustomobject]@{ ok = ($avl - $Cfg.needGB -ge $flo); availGB = $avl; needGB = $Cfg.needGB; keepFreeGB = $flo } }
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
  [Parameter(Mandatory, Position = 0)][ValidateSet('claude', 'desktop', 'code', 'codex', 'status')][string]$Client,
  [string]$Model, [switch]$Unsafe, [switch]$Print, [switch]$Json, [string]$PromptFile, [string]$SchemaFile, [string]$AgentType,
  [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }), [string]$Session, [double]$WaitMinutes = -1,
  [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$cfg = Get-KitLocalModelConfig; $Rest = @($Rest | Where-Object { $null -ne $_ }); $tok = Get-KitLocalModelToken $cfg.token
if ($Client -eq 'status') {
  $sv = Get-KitLocalModelServed $cfg $tok; $ram = Test-KitLocalModelRam $cfg; $sts = Get-KitLocalAiState 'local-model'; $mo = Get-KitModelMode
  $so = [ordered]@{ mode = $mo; use = @($cfg.use); baseUrl = $cfg.baseUrl; up = $sv.up; served = @($sv.ids); forbidden = @($sv.ids | Where-Object { Test-KitLocalModelForbidden $cfg $_ }); error = $sv.error
    seats = $sts.leases.Count; maxConcurrent = $cfg.maxConcurrent; overflow = $cfg.overflow; holders = @($sts.leases | ForEach-Object { "$($_.agent)" }); waiting = $sts.waiting.Count; ram = $ram; token = $(if ($tok) { 'set' } else { 'unset' }) }
  if ($Json) { return ($so | ConvertTo-Json -Depth 5 -Compress) }
  "mode: $mo$(if ($mo -eq 'mixed') { " · local use: $($cfg.use -join ', ') · overflow $($cfg.overflow)" })"
  "server $($cfg.baseUrl): $(if ($sv.up) { "up, serves $(@($sv.ids) -join ', ')$(if ($so.forbidden.Count) { " (forbidden: $($so.forbidden -join ', '))" })" } else { "DOWN ($($sv.error))" })"
  "seats: $($sts.leases.Count)/$($cfg.maxConcurrent)$(if ($sts.leases.Count) { " ($($so.holders -join ', '))" }) · $($sts.waiting.Count) waiting"
  "RAM: $($ram.availGB) GB available, a start needs $($ram.needGB) GB over the $($ram.keepFreeGB) GB floor: $(if ($ram.ok) { 'ok' } else { 'SHORT' })"
  "token ($($cfg.token)): $($so.token)"; return
}
$headless = [bool]$PromptFile
if ($headless -and $Client -notin 'claude', 'codex') { Stop-KitVerb "local ${Client}: -PromptFile runs claude or codex only" }
if ($headless -and -not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Stop-KitVerb "local: no prompt file $PromptFile" }
if ($SchemaFile -and -not ($headless -and (Test-Path -LiteralPath $SchemaFile -PathType Leaf))) { Stop-KitVerb "local: -SchemaFile needs -PromptFile and an existing file ($SchemaFile)" }
if ($AgentType -and -not ($headless -and $Client -eq 'claude')) { Stop-KitVerb 'local: -AgentType runs a crew agent headless: claude -PromptFile only (codex has no --agent)' }
if ($Unsafe -and $Client -in 'desktop', 'code') { Stop-KitVerb "local ${Client}: -Unsafe has no flag there" }
if ($Unsafe -and -not $Print -and ($headless -or $env:CLAUDECODE -or $env:CODEX_SANDBOX -or [Console]::IsInputRedirected)) { Stop-KitVerb "local: -Unsafe is for a person's own interactive session (agents never skip permissions): refused from an agent shell, piped input or -PromptFile" }
$mdl = if ($Model) { $Model } elseif ($Client -eq 'codex' -or $headless) { $cfg.defaultModel } else { '' }   # interactive claude: the server's default unless -Model
if ($Client -eq 'codex' -and -not $mdl) { Stop-KitVerb 'local codex: needs -Model or models.local.defaultModel (local status lists the served ids)' }
$envMap = Get-KitLocalModelEnv $Client $cfg $tok $mdl
$bad = @(Get-KitLocalModelIds $envMap $Rest $mdl | Where-Object { Test-KitLocalModelForbidden $cfg $_ })
if ($bad.Count) { Stop-KitVerb "REFUSED: model $($bad -join ', ') is forbidden here (models.local.forbiddenModels)" 1 }
$exe = Resolve-KitLocalModelExe $Client $cfg; $argv = @(Get-KitLocalModelArgs $Client $cfg $mdl $Unsafe.IsPresent $PromptFile $SchemaFile $AgentType $Rest)
if ($Print) {
  $po = [ordered]@{ client = $Client; exe = "$exe"; args = $argv; model = $(if ($mdl) { $mdl } else { '(server default)' }); baseUrl = $cfg.baseUrl; mode = (Get-KitModelMode); token = $(if ($tok) { 'set' } else { 'unset' }); env = (Format-KitLocalEnv $envMap $tok) }
  if ($Json) { return ($po | ConvertTo-Json -Depth 5 -Compress) }
  "local ${Client}: $(if ($exe) { $exe } else { "(not found: models.local.commands.$Client)" }) $($argv -join ' ')"
  "server $($cfg.baseUrl) · model $($po.model) · token ($($cfg.token)) $($po.token) · nothing started (-Print)"
  foreach ($pe in $po.env.GetEnumerator()) { "  $($pe.Key)=$($pe.Value)" }; return
}
if (-not $exe) { Stop-KitVerb "REFUSED: $Client not found (models.local.commands.${Client}: $(@($cfg.commands[$Client]) -join ', '))" 1 }
$ram = Test-KitLocalModelRam $cfg
if (-not $ram.ok) { Stop-KitVerb "REFUSED: RAM $($ram.availGB) GB available; a local start needs $($ram.needGB) GB over the $($ram.keepFreeGB) GB floor (models.local.needGB, gate.keepFreeGB)" 1 }
$sv = Get-KitLocalModelServed $cfg $tok
if (-not $sv.up) { Stop-KitVerb "REFUSED: no local model server at $($cfg.baseUrl) ($($sv.error)): start it or set models.local.baseUrl" 1 }
if ($mdl -and $mdl -notin $sv.ids) { Stop-KitVerb "REFUSED: model $mdl is not served at $($cfg.baseUrl) (served: $(@($sv.ids | Where-Object { -not (Test-KitLocalModelForbidden $cfg $_) }) -join ', '))" 1 }
$over = $headless -and (Get-KitModelMode) -eq 'mixed' -and $cfg.overflow -eq 'cloud'
$wait = if ($WaitMinutes -ge 0) { $WaitMinutes } elseif ($over) { 0 } else { [double](Get-KitParam 'models.local.queueMinutes') }
if (-not (Use-KitLocalAi 'local-model' -Agent $Agent -Session $Session -WaitMinutes $wait -Max $cfg.maxConcurrent)) {
  $full = "local model seats full ($($cfg.maxConcurrent)/$($cfg.maxConcurrent): $(@((Get-KitLocalAiState 'local-model').leases.agent) -join ', '))"
  if ($over) { Stop-KitVerb "OVERFLOW cloud: $full -> run this step on the cloud (models.local.overflow)" 3 }; Stop-KitVerb "QUEUED: $full after $wait min -> rerun" 3
}
if ($Client -in 'desktop', 'code') {
  try {
    $qa = @($argv | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } })   # Start-Process joins arguments with spaces
    $sp = @{ FilePath = $exe; Environment = @{} + $envMap; PassThru = $true }; if ($qa.Count) { $sp.ArgumentList = $qa }; if ($exe -match '\.(cmd|bat)$') { $sp.WindowStyle = 'Hidden' }
    $child = Start-Process @sp
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
$global:LASTEXITCODE = [int]$rc; if ($rc) { exit [int]$rc }
}
