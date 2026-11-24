#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/adapters.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/adapters.tests.ps1: adapter contracts (README "Adapters"): capabilities (Test-KitCap, UNSUPPORTED, fallbacks), the
# secret store, evidence store, partition models, data-store caps, deploy strategies, login profiles. Next to <kit>/tests/harness.ps1.
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/tracker-clickup.ps1', 'skills/crafty/adapters/tracker-jira.ps1', 'skills/crafty/adapters/tracker-azure.ps1', 'skills/crafty/adapters/tracker-linear.ps1',
  'skills/crafty/adapters/tracker-youtrack.ps1', 'skills/crafty/adapters/github.ps1', 'skills/crafty/adapters/gitlab.ps1', 'skills/crafty/adapters/gitea.ps1', 'skills/crafty/adapters/bitbucket.ps1',
  'skills/crafty/adapters/azure-devops.ps1', 'skills/bossy/kitbag_naming.py','skills/bossy/adapters/deploy-merge.ps1', 'skills/bossy/adapters/deploys.ps1', 'skills/bossy/deploys.md', 'skills/pokey/adapters/deployed-checks.ps1')
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

# tags parity (owner 2026-11-24): every tracker has verb labels (add + remove) or the description fallback, every git host mr.labels or
# the body line; the fallback writes / reads a Tags line; status promoted -> needs-deploy, closed clears it; tracker retag dry run + apply
Set-JsonFile (Join-Path $k 'skills/crafty/kit.local.json') @{ naming = @{ products = @{ SHOP = 'Shop' }; areas = @{ CAT = 'Catalogue' } } }
$tagR = & { . (Join-Path $k 'skills/crafty/lib.ps1')
  foreach ($af in 'tracker-clickup', 'tracker-jira', 'tracker-azure', 'tracker-linear', 'tracker-youtrack', 'github', 'gitlab', 'gitea', 'bitbucket', 'azure-devops') { . (Join-Path $k "skills/crafty/adapters/$af.ps1") }
  $o = [ordered]@{}; $natT = 'azure clickup github gitlab jira jira-server linear none youtrack'; $natH = 'azure gitea github gitlab'   # README "Adapters": native; the rest fall back
  $tn = @($KitAdapters.tracker.Keys | Where-Object { $_ -ne 'fk' } | Sort-Object); $o.trackers = $tn.Count -ge 10
  $o.trackerNative = (@($tn | Where-Object { Test-KitCap tracker $_ labels }) -join ' ') -eq $natT
  $o.trackerRemove = -not @($natT -split ' ' | Where-Object { $_ -ne 'jira-server' -and "$($KitAdapters.tracker[$_].labels)" -notmatch 'remove' }).Count
  $o.trackerFallback = -not @($tn | Where-Object { -not (Test-KitCap tracker $_ labels) -and -not $KitAdapters.tracker[$_].Contains('describe') -and -not $KitAdapters.tracker[$_].Contains('*') }).Count
  $o.hostNative = (@($KitAdapters['git-host'].Keys | Where-Object { $KitAdapters['git-host'][$_].Contains('mr.labels') } | Sort-Object) -join ' ') -eq $natH
  $mem = @{ T1 = [pscustomobject]@{ id = 'T1'; name = 'SHOP-CAT-004 grid'; status = 'open'; description = "Problem: x" } }
  Register-KitAdapter 'tracker' 'fkt' @{ caps = @{ labels = $false }; view = { param($a) $mem[$a.id] }; describe = { param($a) $mem[$a.id].description = $a.text; 'ok' }; url = { param($a) $a.id } }
  $__trType = 'fkt'; $null = Set-KitTaskTags T1 @('key=SHOP-CAT-004', 'kind=Bug', 'wave=3')
  $o.fallbackLine = $mem.T1.description -match '\*\*Tags:\*\* bug, shop, catalogue, wave-3' -and ((Get-KitTaskTags T1) -join ',') -eq 'bug,shop,catalogue,wave-3'
  $null = Set-KitTaskTags T1 @('env=needs-deploy'); $null = Set-KitTaskTags T1 @('env=-'); $o.exclusive = ((Get-KitTaskTags T1) -join ',') -eq 'bug,shop,catalogue,wave-3'
  $o.bugByTag = (Test-KitBugTask $mem.T1) -and -not (Test-KitBugName $mem.T1.name)
  $o.bugGaps = -not @(Get-KitTaskTextGaps $mem.T1.name 'free text' -Subtask -Bug:(Test-KitBugTask $mem.T1)).Count   # a keyed bug: no template gaps
  $null = Format-KitKeyedName '[ui] fix button' 'SHOP-CAT-004'; $o.oddKind = ($script:KitNameTags -join ',') -eq 'key=SHOP-CAT-004,kind=Feature'
  $lab = [Collections.Generic.List[string]]::new(); Register-KitAdapter 'tracker' 'fkl' @{ labels = { param($x) $lab.AddRange([string[]]@($x.add)) }; view = { param($x) $mem[$x.id] }; describe = { 'ok' }; url = { param($x) $x.id } }
  $__trType = 'fkl'; function Test-KitNamingOn { $false }; $null = Set-KitTaskOrder T1 @() 'v2 wave 2'; $o.namingOffWave = ($lab -join ',') -eq 'Wave: v2 wave 2'; $__trType = 'fkt'
  $o.names = -not @((Get-KitTaskTags T1) | Where-Object { $null = & (Get-Python) -X utf8 $KitCmd.kitbag naming check tag $_ 2>&1; $LASTEXITCODE }).Count
  $o.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
Expect-Each $tagR 'tags parity: #' @('trackers', 'trackerNative', 'trackerRemove', 'trackerFallback', 'hostNative', 'fallbackLine', 'exclusive', 'bugByTag', 'bugGaps', 'oddKind', 'namingOffWave', 'names') -Show 12
$env:KIT_TRACKER_TYPE = 'none'; $Dc = Join-Path $k 'skills/crafty/crafty.ps1'; $tnd = TkPath $k tracker-none -Create
Set-JsonFile (Join-Path $tnd 'LOCAL-90.json') @{ id = 'LOCAL-90'; name = 'SHOP-CAT-001 [Feature] Catalogue: price grid'; status = 'open'; parent = $null; list = 'L'; assignees = @(); description = 'd'; comments = @(); tags = @('wave: shop v2 wave 2') }
Set-JsonFile (Join-Path $tnd 'LOCAL-91.json') @{ id = 'LOCAL-91'; name = 'SHOP-CAT-002 [Bug] Catalogue: crash on save'; status = 'open'; parent = 'LOCAL-90'; list = 'L'; assignees = @(); description = 'd'; comments = @() }
$rtD = pwsh -NoProfile -File $Dc tracker retag LOCAL-90 -DryRun 2>&1 | Out-String; $rt0 = (Get-Content (Join-Path $tnd 'LOCAL-90.json') -Raw | ConvertFrom-Json).name
$rtA = pwsh -NoProfile -File $Dc tracker retag LOCAL-90 2>&1 | Out-String; $rv = pwsh -NoProfile -File $Dc tracker view LOCAL-90 2>$null | ConvertFrom-Json
$null = pwsh -NoProfile -File $Dc tracker retag LOCAL-90 2>&1; $rv2 = pwsh -NoProfile -File $Dc tracker view LOCAL-90 2>$null | ConvertFrom-Json   # a re-run plans from the old title, writes it once
$rpo = pwsh -NoProfile -File $Dc tracker status LOCAL-91 promoted 2>&1 | Out-String; $rp = (pwsh -NoProfile -File $Dc tracker view LOCAL-91 2>$null | ConvertFrom-Json).tags -join ','
$null = pwsh -NoProfile -File $Dc tracker status LOCAL-91 closed 2>&1; $rc = (pwsh -NoProfile -File $Dc tracker view LOCAL-91 2>$null | ConvertFrom-Json).tags -join ','; Remove-Item Env:KIT_TRACKER_TYPE
Expect "tracker retag: dry run = table only; apply = <KEY> <outcome> + tags, the old wave label gone; promoted -> needs-deploy, closed clears ($($rv.name) | $($rv.tags -join ',') | $rp | $rc | $rpo)" (
  $rtD -match '\| LOCAL-91 \| SHOP-CAT-002 \[Bug\] Catalogue: crash on save \| SHOP-CAT-002 \| SHOP-CAT-002 Crash on save \| bug, shop, catalogue \|' -and $rtD -match 'DRY RUN: 2 keyed' -and $rt0 -like '*`[Feature`]*' -and
  $rtA -match 'RETAGGED LOCAL-91' -and $rv.name -eq 'SHOP-CAT-001 Price grid' -and $rv2.name -eq $rv.name -and ([regex]::Matches("$($rv2.description)", 'Old title').Count) -eq 1 -and "$($rv.description)".Contains('**Old title:** SHOP-CAT-001 [Feature] Catalogue: price grid') -and ($rv.tags -join ',') -eq 'feature,shop,catalogue,wave-2' -and $rp -eq 'bug,shop,catalogue,needs-deploy' -and $rc -eq 'bug,shop,catalogue')

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
  # keychain writes (parity): Windows Credential Manager round trip on a test name (deleted after); macOS security -i gets the value on stdin
  $__cfg = '{"secrets":{"store":"keychain"}}' | ConvertFrom-Json; $kn = "kit-test-keychain-$PID"; $kv = 'K "3\'
  $o.keychain = if ($KitIsWindows) { try { $null = Set-KitSecret $kn $kv; (Get-KitSecret $kn) -eq $kv } finally { Remove-KitSecret $kn } } else { $true }
  $o.keychain = $o.keychain -and -not $(if ($KitIsWindows) { & (Join-Path $KitLibDir 'flagged.ps1') credread -Text $kn })
  $o.keychainMac = & { $KitIsWindows = $false; function security { }; function Invoke-KitExe { param($Exe, $A, $TimeoutSec, $Raw, $Cwd, $In) $global:kcx = "$Exe|$($A -join ' ')|$In"; [pscustomobject]@{ code = 0; out = ''; err = '' } }
    $nl = try { $null = Set-KitSecret $kn "a`nb"; 'stored' } catch { "$_" }; $null = Set-KitSecret $kn 'v"1'; $nl -match 'line break is refused' -and $global:kcx -eq "security|-i|add-generic-password -U -a kit -s `"$kn`" -w `"v\`"1`"`n" }
  Remove-Item Env:KIT_SECRET_TARGETS_TQ_QA2_PASSWORD
  $o.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
Expect-Each $secR 'secret store: #' @('set', 'get', 'shape', 'names', 'guardFile', 'env', 'envRO', 'missing', 'fake', 'guardStore', 'command', 'keychain', 'keychainMac') -Show 14

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
# device registry (parity.json device): android every ui action, ios shot / openurl / log (the iOS refusal names the registry's), none none
$dvS = Join-Path $k 'dv.ps1'; $dvA = Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/adapters'
Set-Content $dvS ". '$k/skills/crafty/lib.ps1'; . '$dvA/ui-android.ps1'; . '$dvA/ui-ios.ps1'; function Get-KitSetting { 'ios' }; function Get-AndroidSdk { '.' }`n`"`$(`$KitAdapters.device.android.Count)|`$(`$KitAdapters.device.none.Count)`"; Invoke-UiIos tap Save"
$dvO = (pwsh -NoProfile -File $dvS 2>&1 | Out-String); $dvC = $LASTEXITCODE
Expect "device registry: android 15 actions, none 0; ios refuses tap naming log | openurl | shot (exit $dvC)" ($dvO -match '^15\|0' -and $dvO -match 'ios: no ui tap \(simctl has no UI driver\): use log \| openurl \| shot' -and $dvC -eq 2)
# browser engines (parity.json browser-engine): chrome reuses its CDP session; the Playwright engines open one per process
$egU = [Uri]::new((Join-Path $dvA 'engine-playwright.mjs')).AbsoluteUri
$egR = "$(node -e "import('$egU').then((m) => { const e = m.ADAPTERS['browser-engine']; console.log(Object.keys(e).map((k) => k + ':' + (e[k].reuse ? 'reuse' : typeof e[k].session)).join(' ')) })" 2>&1)"
Expect "browser engines: chrome reuse, chromium / firefox / webkit a session per process ($egR)" ($egR -eq 'chrome:reuse chromium:function firefox:function webkit:function')
# login surfaces (parity.json login): api and app share Get-KitLoginPair: a secret:<name> ref resolved, a profile's login + store secret + tenant
$lgR = & { . (Join-Path $k 'skills/crafty/lib.ps1')
  $fa = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/pokey.ps1'), [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-KitLoginPair' }, $true)[0]; . ([scriptblock]::Create($fa.Extent.Text))
  $__cfg = '{"secrets":{"store":"env"}}' | ConvertFrom-Json; $env:KIT_SECRET_TARGETS_T_QA_PASSWORD = 'S-1'
  $tg = @{ users = @{ qa = @('qa', 'secret:targets/t/qa/password') }; profiles = @{ admin = @{ login = 'root'; secret = 'targets/t/qa/password'; fields = @{ tenant = 'acme' } } } }
  $la = Get-KitLoginPair $tg 'qa'; $lb = Get-KitLoginPair $tg 'admin'; Remove-Item Env:KIT_SECRET_TARGETS_T_QA_PASSWORD; "$($la.u -join ',')|$($lb.u -join ',')|$($lb.pf.fields.tenant)" }
Expect "login surfaces: api and app resolve a secret:<name> ref and a profile (login, store secret, tenant) alike ($lgR)" ($lgR -eq 'qa,S-1|root,S-1|acme')

# local-env caps off (no localEnv, no devices, no tenants): supervise and health print no WATCH / ACT for lanes, marks, partitions, phones
$k9 = New-TestKit adapters-lec; $env:KIT_TRACKER_TYPE = 'none'
$lecJ = pwsh @np (Join-Path $k9 'skills/bossy/bossy.ps1') supervise -Json 2>$null | Out-String | ConvertFrom-Json
$lecF = @($lecJ.flags | Where-Object { $_.level -in 'WATCH', 'ACT' } | ForEach-Object { "$($_.level) $($_.kind) $($_.what)" })
$lecH = @(pwsh @np (Join-Path $k9 'skills/bossy/bossy.ps1') health 2>&1 | Where-Object { "$_" -match '\b(WATCH|ACT)\b' -and "$_" -match '(?i)lane|mark|tenant|partition|phone|device|local env|envy' })
Expect "local-env caps off: no WATCH / ACT about lanes, marks, partitions, phones ($(@($lecF + $lecH) -join ' | '))" ($null -ne $lecJ.flags -and -not @($lecF | Where-Object { $_ -match '(?i)lane|mark|tenant|partition|phone|device|local env|envy' }).Count -and -not $lecH.Count)

Complete-Tests
