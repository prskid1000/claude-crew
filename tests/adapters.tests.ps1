#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/adapters.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/adapters.tests.ps1: adapter contracts (README "Adapters"): capabilities (Test-KitCap, UNSUPPORTED, fallbacks), the
# secret store, evidence store, partition models, data-store caps, deploy strategies, login profiles. Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/tracker-clickup.ps1', 'skills/bossy/adapters/deploy-merge.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/deploys.md', 'skills/pokey/adapters/deployed-checks.ps1')
$k = New-TestKit adapters

# caps: declared entry wins, config <kind>.caps.<cap> false switches it off, else the verb; a declared adapter throws UNSUPPORTED
$capR = & { . (Join-Path $k 'skills/crafty/lib.ps1')
  Register-KitAdapter 'tracker' 'fk' @{ caps = @{ checklist = $false; attach = $false }; checklist = { 'x' }; comment = { param($a) $global:fkC = $a.text; "ok" }; 'comment-edit' = { 'e' } }
  $o = [ordered]@{ declOff = -not (Test-KitCap tracker fk checklist); verb = (Test-KitCap tracker fk commentEdit); noVerb = -not (Test-KitCap tracker fk move) }
  $o.unsupported = try { Invoke-KitAdapter tracker fk move @{}; $false } catch { "$_" -match '^UNSUPPORTED tracker/fk/move' }
  $__cfg = '{"tracker":{"caps":{"commentEdit":false}}}' | ConvertFrom-Json
  $o.cfgOff = -not (Test-KitCap tracker fk commentEdit)
  $__cfg = '{"tracker":{"commands":{"statuses":"t s","move":"t m"}}}' | ConvertFrom-Json
  $o.cmd = (Test-KitCap tracker command statuses) -and (Test-KitCap tracker command move) -and -not (Test-KitCap tracker command checklist)
  $__trType = 'fk'; $f = Join-Path $k 'ev.png'; 'x' | Set-Content $f
  $atR = try { Add-TrackerAttachment 'T1' $f 'shot' 2>&1 } catch { "ERR $_" }
  $o.attachFallback = "$global:fkC" -match 'shot.*ev\.png kept with the run'; if (-not $o.attachFallback) { "attach: $atR" }
  $o.clickup = & { . (Join-Path $k 'skills/crafty/adapters/tracker-clickup.ps1'); @('checklist', 'commentEdit', 'commentDelete', 'statuses', 'move', 'attach' | Where-Object { -not (Test-KitCap tracker clickup $_) }).Count -eq 0 }
  $o.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
Expect-Each $capR 'caps: #' @('declOff', 'verb', 'noVerb', 'unsupported', 'cfgOff', 'cmd', 'attachFallback', 'clickup') -Show 9

# secret store: file round trip (targets.local.json shape kept), names only, env read-only, secret:<name> refs, a fake store,
# the guard denies the configured store's backing file and keeps the file store's default
$secR = & { . (Join-Path $k 'skills/crafty/lib.ps1')
  $o = [ordered]@{}; $nm = 'targets/tq/qa1/password'
  $o.set = (Set-KitSecret $nm 'Pw-9x') -notmatch 'Pw-9x'
  $o.get = (Get-KitSecret $nm) -eq 'Pw-9x' -and (Get-KitSecret 'targets/tq/qa1/login') -eq 'qa1'
  $o.shape = @((Get-Content (Join-Path $k 'skills/pokey/targets.local.json') -Raw | ConvertFrom-Json).targets.tq.users.qa1)[1] -eq 'Pw-9x'
  $o.names = (@(Get-KitSecretNames 'targets/tq/') -join ',') -eq 'targets/tq/qa1/login,targets/tq/qa1/password'
  $o.guardFile = "$(Invoke-KitAdapter guard secrets check @{ raw = 'cat skills/pokey/targets.local.json' })" -match 'never read'
  $__cfg = '{"secrets":{"store":"env"}}' | ConvertFrom-Json; $env:KIT_SECRET_TARGETS_TQ_QA2_PASSWORD = 'E-1'
  $o.env = (Resolve-KitSecretRef 'secret:targets/tq/qa2/password') -eq 'E-1' -and (Resolve-KitSecretRef 'plain') -eq 'plain'
  $o.envRO = try { Set-KitSecret 'targets/tq/qa2/password' 'x'; $false } catch { "$_" -match '^UNSUPPORTED secret-store/env/set' }
  $o.missing = try { $null = Get-KitSecret 'targets/tq/nobody/password'; $false } catch { "$_" -notmatch 'E-1' }
  $mem = @{}; Register-KitAdapter 'secret-store' 'fake' @{ caps = @{ write = $true; list = $true }; get = { param($a) $mem[$a.name] }; set = { param($a) $mem[$a.name] = $a.value }; list = { param($a) @($mem.Keys) } }
  $__cfg = '{"secrets":{"store":"fake","fake":{"paths":["vault.local.txt"]}}}' | ConvertFrom-Json
  $null = Set-KitSecret 'targets/x/u/password' 'F-2'; $o.fake = (Get-KitSecret 'targets/x/u/password') -eq 'F-2' -and @(Get-KitSecretNames).Count -eq 1
  $o.guardStore = "$(Invoke-KitAdapter guard secrets check @{ raw = 'type C:\v\vault.local.txt' })" -match 'vault\.local\.txt holds test logins and secrets' -and "$(Invoke-KitAdapter guard secrets check @{ raw = 'cat skills/pokey/targets.local.json' })" -match 'never read'
  # command store: set gets the value through env KIT_SECRET_VALUE (not argv), get prints it raw (JSON-looking text stays text)
  $cs = (Join-Path $k 'cs.txt').Replace('\', '/'); $pw = 'pwsh -NoProfile -Command'
  $__cfg = ([ordered]@{ secrets = @{ store = 'command'; command = @{ set = "$pw Set-Content -Path '$cs' -Value `$env:KIT_SECRET_VALUE -NoNewline"; get = "$pw Get-Content -Raw '$cs'" } } } | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
  $null = Set-KitSecret 'targets/x/u/password' '{"p":1}'; $o.command = (Get-KitSecret 'targets/x/u/password') -eq '{"p":1}' -and -not (Test-KitCap 'secret-store' 'command' 'list')
  Remove-Item Env:KIT_SECRET_TARGETS_TQ_QA2_PASSWORD
  $o.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
Expect-Each $secR 'secret store: #' @('set', 'get', 'shape', 'names', 'guardFile', 'env', 'envRO', 'missing', 'fake', 'guardStore', 'command') -Show 12

# deploy run: each deploys[] row of the target through its kind's deploy verb; command runs without a git host, manual
# prints the steps, ssh without deployCmd and a kind with no deploy verb (probe) say a person deploys
$kl = Join-Path $k 'skills/crafty/kit.local.json'
& $J @{ repos = @(@{ name = 'svc'; deploys = @(@{ target = 't1'; command = @{ deploy = 'pwsh -NoProfile -Command Write-Output shipped-{repo}-{mr}' } }, @{ target = 't2'; manual = 'open the console, press Deploy' }, @{ target = 't2'; kind = 'probe'; probe = 'echo x' }, @{ target = 't3'; ssh = @{ host = 'h.invalid' } }) }) } $kl
$B = Join-Path $k 'skills/bossy/bossy.ps1'
$drW = { param($e) if ((Px $B decide record -Gate deploy -Item $e -Question "deploy $e?" -Answer "yes, deploy $e" -Source chat 2>&1 | Out-String) -match 'RECORDED (\S+)') { $Matches[1] } }
$dr0 = Px $B deploy run -To t1 2>&1 | Out-String; $dr0c = $LASTEXITCODE
$dr1 = Px $B deploy run -To t1 -Mrs 'svc!4' -Decision (& $drW t1) 2>&1 | Out-String
$dr2 = Px $B deploy run -To t2 -Decision (& $drW t2) 2>&1 | Out-String
$dr3 = Px $B deploy run -To t3 -Decision (& $drW t3) 2>&1 | Out-String
$dr4 = Px (Join-Path $k 'skills/bossy/bossy.ps1') deploy run -To nowhere 2>&1 | Out-String; $dr4c = $LASTEXITCODE
Expect "deploy run: no person's word = REFUSED, nothing runs; with one the command kind deploys ($($dr1.Trim()))" ($dr0c -eq 1 -and $dr0 -match '^REFUSED deploy run -To t1' -and $dr0 -notmatch 'shipped' -and $dr1 -match 'DEPLOY svc -> t1 \(command\): shipped-svc-svc!4')
Expect "deploy run: manual waits for a person, probe is UNSUPPORTED ($(($dr2 -split "`n" | Where-Object { $_ }) -join ' | '))" ($dr2 -match 'DEPLOY svc -> t2 \(manual\): manual · waiting for a person: open the console' -and $dr2 -match 'UNSUPPORTED deploy-kind/probe/deploy svc -> t2')
Expect "deploy run: ssh without deployCmd fails naming it; no row = exit 2 ($($dr3.Trim()))" ($dr3 -match 'FAILED svc -> t3 \(ssh\) · no deploys\[\]\.ssh\.deployCmd' -and $dr4c -eq 2)
Remove-Item $kl

# data stores: redis and search engines answer schemaSizes rows from their own APIs (no SQL); no marks / temp caps
$dsR = & { . (Join-Path $k 'skills/crafty/lib.ps1'); . (Join-Path $src 'skills/envy/adapters/db-engines.ps1')
  function Get-EnvCfg { @{ db = @{ host = 'h'; port = 1 } } }; function EnvVars { @{ REDISCLI_AUTH = 'x' } }; function With-Env($v, $b) { $script:dsEnv = $v.REDISCLI_AUTH; & $b }; function Get-DbEngine { $KitAdapters['db-engine'][$script:dsEng] }
  function Invoke-KitExe { [pscustomobject]@{ code = 0; out = "used_memory:20971520`ndb0:keys=30,expires=0`ndb1:keys=10,expires=0"; err = '' } }
  function Invoke-RestMethod { @([pscustomobject]@{ index = 'orders'; 'docs.count' = '12'; 'store.size' = '3' }, [pscustomobject]@{ index = '.kibana'; 'docs.count' = '1'; 'store.size' = '1' }) }
  $script:dsEng = 'redis'; $rd = @(& $KitAdapters['db-engine'].redis.sizes @{ e = 'x' }) -join '|'
  $script:dsEng = 'opensearch'; $os = @(& $KitAdapters['db-engine'].opensearch.sizes @{ e = 'x' }) -join '|'
  "redis:$($rd -eq "db0`t30`t15|db1`t10`t5" -and $script:dsEnv -eq 'x')"; "search:$($os -eq "orders`t12`t3")"
  "nocaps:$(-not $KitAdapters['db-engine'].redis.supportsMarks -and -not $KitAdapters['db-engine'].elasticsearch.supportsTemp)" }
Expect-Each $dsR 'data store: #' @('redis', 'search', 'nocaps') -Show 4

# transcripts: every read goes through the transcript adapter (workflow dirs, own-transcript search, agent meta); Codex / Antigravity
# say UNSUPPORTED for Claude-only verbs; no kit file outside the adapter names a CLI's transcript folder
$txR = & { $tdir = Join-Path $k 'tx'; New-Item -ItemType Directory -Force (Join-Path $tdir 's1/subagents/workflows/wf1') | Out-Null
  '{"description":"x1 build"}' | Set-Content (Join-Path $tdir 's1/subagents/workflows/wf1/agent-a1b2c3d4e5f6a.meta.json'); 'marker-tx-77' | Set-Content (Join-Path $tdir 's1/subagents/workflows/wf1/agent-a1.jsonl')
  $env:KIT_TRANSCRIPTS = $tdir; . (Join-Path $k 'skills/crafty/lib.ps1')
  "wfdirs:$(@(Get-KitWorkflowDirs | ForEach-Object Name) -contains 'wf1')"; "find:$((Find-KitTranscript 'marker-tx-77' 'agent-*.jsonl') -like '*agent-a1.jsonl')"
  "meta:$((Invoke-KitAdapter transcript claude agent-meta @{ id = 'a1b2c3d4e5f6a' }).Name -eq 'agent-a1b2c3d4e5f6a.meta.json')"
  "unsupported:$(@(foreach ($txKind in 'codex', 'antigravity', 'none') { try { Invoke-KitAdapter transcript $txKind agent-meta @{ id = 'a1' }; $txKind } catch { if ("$_" -notmatch "^UNSUPPORTED transcript/$txKind/agent-meta") { $txKind } } }).Count -eq 0)"
  $env:KIT_TRANSCRIPTS = $null
  $by = @(Get-ChildItem -Recurse -File (Join-Path $src 'skills'), (Join-Path $src 'workflows') -Include *.ps1, *.py, *.js, *.mjs | Where-Object { $_.FullName -notmatch 'node_modules' } |
    Select-String -Pattern 'ClaudeProjectDir|\.claude[/\\]projects|\.codex[/\\]sessions|antigravity-cli[/\\]brain' | Where-Object { -not ($_.Path -like '*crafty?lib.ps1' -and ($_.Line -match "^\s*(ClaudeProjectDir =|'root' =|'agent-meta' =)")) })
  "bypass:$(-not $by.Count)"; if ($by.Count) { $by | Select-Object -First 3 | ForEach-Object { "  $($_.Path):$($_.LineNumber)" } } }
Expect-Each $txR 'transcript adapter: #' @('wfdirs', 'find', 'meta', 'unsupported', 'bypass') -Show 9

# local-env caps off (no localEnv, no devices, no tenants): supervise and health print no WATCH / ACT for lanes, marks, partitions, phones
$k9 = New-TestKit adapters-lec; $env:KIT_TRACKER_TYPE = 'none'
$lecJ = pwsh @np (Join-Path $k9 'skills/bossy/bossy.ps1') supervise -Json 2>$null | Out-String | ConvertFrom-Json
$lecF = @($lecJ.flags | Where-Object { $_.level -in 'WATCH', 'ACT' } | ForEach-Object { "$($_.level) $($_.kind) $($_.what)" })
$lecH = @(pwsh @np (Join-Path $k9 'skills/bossy/bossy.ps1') health 2>&1 | Where-Object { "$_" -match '\b(WATCH|ACT)\b' -and "$_" -match '(?i)lane|mark|tenant|partition|phone|device|local env|envy' })
Expect "local-env caps off: no WATCH / ACT about lanes, marks, partitions, phones ($(@($lecF + $lecH) -join ' | '))" ($null -ne $lecJ.flags -and -not @($lecF | Where-Object { $_ -match '(?i)lane|mark|tenant|partition|phone|device|local env|envy' }).Count -and -not $lecH.Count)

Complete-Tests
