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
  $o.fallbackLine = $mem.T1.description -match '\*\*Tags:\*\* bug, catalogue, shop(\r?\n|$)' -and ((Get-KitTaskTags T1) -join ',') -eq 'bug,catalogue,shop'
  $null = Set-KitTaskTags T1 @('env=needs-deploy'); $null = Set-KitTaskTags T1 @('env=-'); $o.exclusive = ((Get-KitTaskTags T1) -join ',') -eq 'bug,catalogue,shop'
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
  $rtD -match '\| LOCAL-91 \| SHOP-CAT-002 \[Bug\] Catalogue: crash on save \| SHOP-CAT-002 \| SHOP-CAT-002 Crash on save \| no kind tag, no area tag, no product tag \| bug, catalogue, shop \|' -and $rtD -match 'DRY RUN: 2 keyed' -and $rt0 -like '*`[Feature`]*' -and
  $rtA -match 'RETAGGED LOCAL-91' -and $rv.name -eq 'SHOP-CAT-001 Price grid' -and $rv2.name -eq $rv.name -and ([regex]::Matches("$($rv2.description)", 'Old title').Count) -eq 1 -and "$($rv.description)".Contains('**Old title:** SHOP-CAT-001 [Feature] Catalogue: price grid') -and ($rv.tags -join ',') -eq 'feature,catalogue,shop' -and $rp -eq 'bug,catalogue,shop,needs-deploy' -and $rc -eq 'bug,catalogue,shop')

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
  $o.keychain = if ($KitIsWindows) { try { $null = Set-KitSecret $kn $kv; (Get-KitSecret $kn) -eq $kv -and $kn -in @(Get-KitSecretNames 'kit-test-keychain-') } finally { Remove-KitSecret $kn } } else { $true }
  # keychain list (parity): macOS dump-keychain attributes and libsecret search (fixtures: no Mac or Linux keyring here), kit items only
  $o.keychainList = & { $KitIsWindows = $false; function security { }
    function Invoke-KitNetExe { param($Exe, $A) [pscustomobject]@{ code = 0; err = ''; out = "keychain: `"/k.db`"`nversion: 512`nclass: `"genp`"`nattributes:`n    `"acct`"<blob>=`"kit`"`n    `"svce`"<blob>=`"targets/t/u/password`"`nclass: `"genp`"`nattributes:`n    `"acct`"<blob>=`"me`"`n    `"svce`"<blob>=`"other`"`nclass: `"genp`"`nattributes:`n    `"acct`"<blob>=`"kit`"`n    `"svce`"<blob>=`"targets/t/u/login`"" } }
    $mac = @(Get-KitSecretNames) -join ','; Remove-Item Function:security   # no security binary off macOS: libsecret
    function Invoke-KitNetExe { param($Exe, $A) $script:kcl = "$Exe $($A -join ' ')"; [pscustomobject]@{ code = 0; err = ''; out = "[/1]`nlabel = a`nsecret = s3cret`nattribute.service = targets/t/u/login`nattribute.account = kit" } }
    $lnx = @(Get-KitSecretNames) -join ','; $mac -eq 'targets/t/u/password,targets/t/u/login' -and $lnx -eq 'targets/t/u/login' -and $script:kcl -eq 'secret-tool search --all account kit' }
  $o.keychain = $o.keychain -and -not $(if ($KitIsWindows) { & (Join-Path $KitLibDir 'flagged.ps1') credread -Text $kn })
  $o.keychainMac = & { $KitIsWindows = $false; function security { }; function Invoke-KitExe { param($Exe, $A, $TimeoutSec, $Raw, $Cwd, $In) $global:kcx = "$Exe|$($A -join ' ')|$In"; [pscustomobject]@{ code = 0; out = ''; err = '' } }
    $nl = try { $null = Set-KitSecret $kn "a`nb"; 'stored' } catch { "$_" }; $null = Set-KitSecret $kn 'v"1'; $nl -match 'line break is refused' -and $global:kcx -eq "security|-i|add-generic-password -U -a kit -s `"$kn`" -w `"v\`"1`"`n" }
  Remove-Item Env:KIT_SECRET_TARGETS_TQ_QA2_PASSWORD
  $o.GetEnumerator() | ForEach-Object { "$($_.Key):$([bool]$_.Value)" } }
Expect-Each $secR 'secret store: #' @('set', 'get', 'shape', 'names', 'guardFile', 'env', 'envRO', 'missing', 'fake', 'guardStore', 'command', 'keychain', 'keychainList', 'keychainMac') -Show 15

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
  function Get-DbEngineName { $script:dsEng }
  function Invoke-RestMethod { param($Uri, $Method, $ContentType, $Body, $TimeoutSec)
    if ($Method -eq 'Post') { $script:dsSql += @("$Uri $Body"); if ($Body -match '"cursor":"c1"') { return '{"rows":[["d",4]]}' | ConvertFrom-Json }
      return '{"columns":[{"name":"org"}],"rows":[["a",1],["b",2]],"cursor":"c1","schema":[{"name":"org"}],"datarows":[["c",3]]}' | ConvertFrom-Json }
    @([pscustomobject]@{ index = 'orders'; 'docs.count' = '12'; 'store.size' = '3' }, [pscustomobject]@{ index = '.kibana'; 'docs.count' = '1'; 'store.size' = '1' }) }
  $script:dsEng = 'redis'; $rd = @(& $KitAdapters['db-engine'].redis.sizes @{ e = 'x' }) -join '|'
  $script:dsEng = 'opensearch'; $os = @(& $KitAdapters['db-engine'].opensearch.sizes @{ e = 'x' }) -join '|'
  "redis:$($rd -eq "db0`t30`t15|db1`t10`t5" -and $script:dsEnv -eq 'x')"; "search:$($os -eq "orders`t12`t3")"
  # SQL over REST (parity): elasticsearch _sql rows, opensearch SQL plugin datarows; redis has none
  $script:dsSql = @(); $script:dsEng = 'elasticsearch'; $esq = @(& $KitAdapters['db-engine'].elasticsearch.sql @{ e = 'x'; sql = 'SELECT org FROM orders;' } | ForEach-Object { $_ -join ':' }) -join ','
  $script:dsEng = 'opensearch'; $osq = @(& $KitAdapters['db-engine'].opensearch.sql @{ e = 'x'; sql = 'SELECT org FROM orders' } | ForEach-Object { $_ -join ':' }) -join ','
  "searchSql:$($esq -eq 'a:1,b:2,d:4' -and $osq -eq 'c:3' -and $script:dsSql[0] -like 'http://h:1/_sql?format=json *"query":"SELECT org FROM orders"*' -and $script:dsSql[1] -eq 'http://h:1/_sql?format=json {"cursor":"c1"}' -and $script:dsSql[2] -like 'http://h:1/_plugins/_sql *' -and -not $KitAdapters['db-engine'].redis.sql)"
  "nocaps:$(-not $KitAdapters['db-engine'].redis.supportsMarks -and -not $KitAdapters['db-engine'].elasticsearch.supportsTemp)" }
Expect-Each $dsR 'data store: #' @('redis', 'search', 'searchSql', 'nocaps') -Show 5

# transcripts: every read goes through the transcript adapter (workflow dirs, own-transcript search, agent meta); Codex / Antigravity
# say UNSUPPORTED for Claude-only verbs; no kit file outside the adapter names a CLI's transcript folder
$txR = & { $tdir = Join-Path $k 'tx'; New-Item -ItemType Directory -Force (Join-Path $tdir 's1/subagents/workflows/wf1') | Out-Null
  '{"description":"x1 build"}' | Set-Content (Join-Path $tdir 's1/subagents/workflows/wf1/agent-a1b2c3d4e5f6a.meta.json'); 'marker-tx-77' | Set-Content (Join-Path $tdir 's1/subagents/workflows/wf1/agent-a1.jsonl')
  $env:KIT_TRANSCRIPTS = $tdir; . (Join-Path $k 'skills/crafty/lib.ps1')
  "wfdirs:$(@(Get-KitWorkflowDirs | ForEach-Object Name) -contains 'wf1')"; "find:$((Find-KitTranscript 'marker-tx-77' 'agent-*.jsonl') -like '*agent-a1.jsonl')"
  "meta:$((Invoke-KitAdapter transcript claude agent-meta @{ id = 'a1b2c3d4e5f6a' }).Name -eq 'agent-a1b2c3d4e5f6a.meta.json')"
  # parity agentMeta: a Codex subagent rollout (session_meta with a parent thread; a root session is no agent), an Antigravity subagent state file
  $env:KIT_TRANSCRIPTS_CODEX = Join-Path $k 'txc'; $env:KIT_TRANSCRIPTS_ANTIGRAVITY = Join-Path $k 'txa'
  New-Item -ItemType Directory -Force (Join-Path $k 'txc/2026/01/02'), (Join-Path $k 'txa/c1/.system_generated/subagents') | Out-Null
  '{"type":"session_meta","payload":{"id":"th-sub1","parent_thread_id":"th-root","agent_role":"revy"}}' | Set-Content (Join-Path $k 'txc/2026/01/02/rollout-2026-01-02T10-00-00-th-sub1.jsonl')
  '{"type":"session_meta","payload":{"id":"th-root"}}' | Set-Content (Join-Path $k 'txc/2026/01/02/rollout-2026-01-02T09-00-00-th-root.jsonl')
  '{"subagentDescriptor":{"typeName":"checky","role":"Kit File Checker"},"state":"SUBAGENT_STATE_ALIVE"}' | Set-Content (Join-Path $k 'txa/c1/.system_generated/subagents/ag-1.json')
  "meta-ports:$((Invoke-KitAdapter transcript codex agent-meta @{ id = 'th-sub1' }).Name -like '*th-sub1.jsonl' -and -not (Invoke-KitAdapter transcript codex agent-meta @{ id = 'th-root' }) -and (Invoke-KitAdapter transcript antigravity agent-meta @{ id = 'ag-1' }).Name -eq 'ag-1.json' -and -not (Invoke-KitAdapter transcript antigravity agent-meta @{ id = 'nope' }))"
  Remove-Item Env:KIT_TRANSCRIPTS_CODEX, Env:KIT_TRANSCRIPTS_ANTIGRAVITY
  "unsupported:$(@(foreach ($txKind in @('none')) { try { Invoke-KitAdapter transcript $txKind agent-meta @{ id = 'a1' }; $txKind } catch { if ("$_" -notmatch "^UNSUPPORTED transcript/$txKind/agent-meta") { $txKind } } }).Count -eq 0)"
  $env:KIT_TRANSCRIPTS = $null
  $by = @(Get-ChildItem -Recurse -File (Join-Path $src 'skills'), (Join-Path $src 'workflows') -Include *.ps1, *.py, *.js, *.mjs | Where-Object { $_.FullName -notmatch 'node_modules' } |
    Select-String -Pattern 'ClaudeProjectDir|\.claude[/\\]projects|\.codex[/\\]sessions|antigravity-cli[/\\]brain' | Where-Object { -not ($_.Path -like '*crafty?lib.ps1' -and ($_.Line -match "^\s*(ClaudeProjectDir =|'root' =|'agent-meta' =)")) })
  "bypass:$(-not $by.Count)"; if ($by.Count) { $by | Select-Object -First 3 | ForEach-Object { "  $($_.Path):$($_.LineNumber)" } } }
Expect-Each $txR 'transcript adapter: #' @('wfdirs', 'find', 'meta', 'meta-ports', 'unsupported', 'bypass') -Show 9
# device registry (parity.json device): android every ui action, ios all but photo / mic through idb (a fixture: no Mac here; the
# refusal names the registry's), none none
$dvS = Join-Path $k 'dv.ps1'; $dvA = Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/adapters'
$dvBody = @'
. '{K}/skills/crafty/lib.ps1'; . '{A}/ui-android.ps1'; . '{A}/ui-ios.ps1'; function Get-KitSetting { 'ios' }; function Get-AndroidSdk { '.' }
$global:idbCalls = @(); function idb { $global:idbCalls += ($args -join ' '); $global:LASTEXITCODE = 0; if ($args[1] -eq 'describe-all') { '[{"AXLabel":"Save","AXUniqueId":"save-btn","type":"Button","frame":{"x":10,"y":20,"width":100,"height":40}},{"AXLabel":null,"AXValue":"","AXUniqueId":"name","type":"TextField","frame":{"x":0,"y":100,"width":200,"height":30}}]' } }
"$($KitAdapters.device.android.Count)|$($KitAdapters.device.ios.Count)|$($KitAdapters.device.none.Count)"
Invoke-UiIos dump; Invoke-UiIos tap Save; Invoke-UiIos tapid name; Invoke-UiIos key KEYCODE_ENTER; Invoke-UiIos clear 2; Invoke-UiIos swipe 1 2 3 4
"calls=$($global:idbCalls -join ';')"
Invoke-UiIos photo
'@
Set-Content $dvS $dvBody.Replace('{K}', $k).Replace('{A}', $dvA)
$dvO = (pwsh -NoProfile -File $dvS 2>&1 | Out-String); $dvC = $LASTEXITCODE
Expect "device registry: android 15, ios 13, none 0; ios dump / tap / tapid / key / clear / swipe through idb; photo refused naming the rest (exit $dvC)" ($dvO -match '^15\|13\|0' -and $dvO -match 'Save @\(60,40\) #save-btn' -and $dvO -match '@\(100,115\) \[edit\] #name' -and
  $dvO -match "tapped 'Save' at 60,40" -and $dvO -match 'tapped #name at 100,115' -and $dvO -match 'calls=ui describe-all --json;ui describe-all --json;ui tap 60 40;ui describe-all --json;ui tap 100 115;ui key 40;ui key-sequence 42 42;ui swipe 1 2 3 4 --duration 0\.4' -and
  $dvO -match 'ios: no ui photo \(a Simulator has no camera and no audio injection\): use clear \| dump \| key \| log \| openurl' -and $dvC -eq 2)
# browser engines (parity.json browser-engine): chrome reuses its CDP session; the Playwright engines a browser server per login,
# started once, each call connects (a fake Playwright module: none installed here)
$egU = [Uri]::new((Join-Path $dvA 'engine-playwright.mjs')).AbsoluteUri
$egR = "$(node -e "import('$egU').then((m) => { const e = m.ADAPTERS['browser-engine']; console.log(Object.keys(e).map((k) => k + ':' + (e[k].reuse === true ? 'cdp' : typeof e[k].reuse)).join(' ')) })" 2>&1)"
$pwD = New-Item -ItemType Directory -Force (Join-Path $k 'pwfake'); $env:FAKE_PW_DIR = "$pwD"; $env:KIT_PLAYWRIGHT = Join-Path $pwD 'fake-pw.mjs'
Set-Content $env:KIT_PLAYWRIGHT @'
import { appendFileSync, existsSync, readFileSync } from 'node:fs'
const dir = process.env.FAKE_PW_DIR, noop = async () => {}
const page = () => ({ goto: noop, waitForNavigation: noop, waitForLoadState: noop })
export const firefox = {
  launchServer: async ({ port, wsPath }) => { appendFileSync(`${dir}/served.txt`, `${port}${wsPath} ${process.pid}\n`); setInterval(() => {}, 60000); return { close: noop } },
  connect: async (ws) => { const f = `${dir}/served.txt`; if (!existsSync(f) || !readFileSync(f, 'utf8').includes(ws.split(':')[2])) throw new Error('refused'); appendFileSync(`${dir}/connects.txt`, ws + '\n'); return { newContext: async () => ({ newPage: async () => page(), cookies: async () => [], addCookies: noop }), close: noop } },
  launch: async () => { throw new Error('launch: not in this test') } }
'@
$pwRun = Join-Path $pwD 'run.mjs'; $pwL0 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $pwL0.Start(); $pwPort = $pwL0.LocalEndpoint.Port; $pwL0.Stop()
Set-Content $pwRun "const m = await import('$egU'); for (let i = 0; i < 2; i++) await m.pwServed('firefox', {}, { width: 9, height: 9 }, [], $pwPort, process.env.FAKE_PW_DIR); console.log('two sessions'); process.exit(0)"
$env:KIT_PW_IDLE_MS = '3000'   # the server's idle exit, short here
$pwO = "$(node $pwRun 2>&1)"; $pwSv = @(Get-Content (Join-Path $pwD 'served.txt') -ErrorAction SilentlyContinue); $pwCn = @(Get-Content (Join-Path $pwD 'connects.txt') -ErrorAction SilentlyContinue)
$pwTk = "$(Get-Content (Join-Path $pwD "pw-$pwPort.token") -Raw -ErrorAction SilentlyContinue)".Trim(); $pwPid = [int](@($pwSv)[0] -split ' ')[1]
Expect "browser engines: chrome reuses CDP, chromium / firefox / webkit a served browser; two firefox sessions = one server, two connects on its random token path, never /kit ($egR | $pwO | $($pwSv.Count) served, $($pwCn.Count) connects)" ($egR -eq 'chrome:cdp chromium:function firefox:function webkit:function' -and $pwO -eq 'two sessions' -and $pwSv.Count -eq 1 -and $pwTk -match '^[0-9a-f]{48}$' -and $pwSv[0] -like "$pwPort/$pwTk *" -and $pwCn.Count -eq 2 -and @($pwCn | Where-Object { $_ -ne "ws://127.0.0.1:$pwPort/$pwTk" }).Count -eq 0 -and (Test-Path (Join-Path $pwD "pw-$pwPort.used")))
# idle exit: no client touches <used> for KIT_PW_IDLE_MS -> the server closes and removes its token file
for ($pwI = 0; $pwI -lt 40 -and (Get-Process -Id $pwPid -ErrorAction SilentlyContinue); $pwI++) { Start-Sleep -Milliseconds 500 }
$pwIdleGone = -not (Get-Process -Id $pwPid -ErrorAction SilentlyContinue); Stop-Process -Id $pwPid -Force -ErrorAction SilentlyContinue
Expect "served browser: idle past KIT_PW_IDLE_MS -> the server exits and its token file goes" ($pwIdleGone -and -not (Test-Path (Join-Path $pwD "pw-$pwPort.token")))
# killSession: browser.mjs removes <used> -> the server exits within 5 s though its idle time is far off
if (Use-BrowserKit) {
  $env:KIT_PW_IDLE_MS = '600000'; Remove-Item (Join-Path $pwD 'served.txt') -ErrorAction SilentlyContinue
  $bmU = [Uri]::new((Join-Path $k 'skills/pokey/browser.mjs')).AbsoluteUri; $pwKs = Join-Path $pwD 'kill.mjs'
  Set-Content $pwKs "const b = await import('$bmU'), m = await import('$egU'); const d = b.kitPath('sessions', { create: true }); await m.pwServed('firefox', {}, { width: 9, height: 9 }, [], $pwPort, d); console.log(d); process.exit(0)"
  $pwSd = "$(node $pwKs 2>&1)".Trim(); $pwPid = [int](@(Get-Content (Join-Path $pwD 'served.txt') -ErrorAction SilentlyContinue)[0] -split ' ')[1]
  $pwKo = "$(node -e "import('$bmU').then(async (b) => { await b.killSession($pwPort); console.log('killed') })" 2>&1)"
  for ($pwI = 0; $pwI -lt 30 -and $pwPid -and (Get-Process -Id $pwPid -ErrorAction SilentlyContinue); $pwI++) { Start-Sleep -Milliseconds 500 }
  $pwKillGone = $pwPid -and -not (Get-Process -Id $pwPid -ErrorAction SilentlyContinue); if ($pwPid) { Stop-Process -Id $pwPid -Force -ErrorAction SilentlyContinue }
  Expect "served browser: killSession removes <used> -> the server exits within 15 s (idle 10 min) and its token goes ($pwKo | $pwSd)" ($pwKo -eq 'killed' -and $pwKillGone -and -not (Test-Path (Join-Path $pwSd "pw-$pwPort.used")) -and -not (Test-Path (Join-Path $pwSd "pw-$pwPort.token")))
}
Remove-Item Env:FAKE_PW_DIR, Env:KIT_PLAYWRIGHT, Env:KIT_PW_IDLE_MS
# login surfaces (parity.json login): api and app share Get-KitLoginPair: a secret:<name> ref resolved, a profile's login + store secret + tenant
$lgR = & { . (Join-Path $k 'skills/crafty/lib.ps1')
  $fa = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot) 'skills/pokey/pokey.ps1'), [ref]$null, [ref]$null).FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-KitLoginPair' }, $true)[0]; . ([scriptblock]::Create($fa.Extent.Text))
  $__cfg = '{"secrets":{"store":"env"}}' | ConvertFrom-Json; $env:KIT_SECRET_TARGETS_T_QA_PASSWORD = 'S-1'
  $tg = @{ users = @{ qa = @('qa', 'secret:targets/t/qa/password') }; profiles = @{ admin = @{ login = 'root'; secret = 'targets/t/qa/password'; fields = @{ tenant = 'acme' } } } }
  $la = Get-KitLoginPair $tg 'qa'; $lb = Get-KitLoginPair $tg 'admin'; Remove-Item Env:KIT_SECRET_TARGETS_T_QA_PASSWORD; "$($la.u -join ',')|$($lb.u -join ',')|$($lb.pf.fields.tenant)" }
Expect "login surfaces: api and app resolve a secret:<name> ref and a profile (login, store secret, tenant) alike ($lgR)" ($lgR -eq 'qa,S-1|root,S-1|acme')
# web login (parity): a secret:<name> ref through the kit's secret-store in a child pwsh (env store here), a profile's store
# secret, login and tenant; the form fills them
$wlA = New-Item -ItemType Directory -Force (Join-Path $k 'skills/pokey/adapters'); Copy-Item (Join-Path $dvA 'web-login.mjs') $wlA -Force
$wlU = [Uri]::new((Join-Path $wlA 'web-login.mjs')).AbsoluteUri; $wlRun = Join-Path $k 'wl.mjs'; $wlCfg = Join-Path $k 'skills/crafty/kit.local.json'
& $J @{ secrets = @{ store = 'env' } } $wlCfg
Set-Content $wlRun @"
const m = await import('$wlU'), filled = []
const h = { nav: async () => {}, onLogin: () => true, fill: (s, u, p, tn) => String(s).replace('{user}', u).replace('{pass}', p).replace('{tenant}', tn), step: async (pg, s, f) => { for (const v of Object.values(s.fill || {})) filled.push(f(v)) } }
const t = { web: 'http://x', webLogin: { fields: { '#u': '{user}', '#p': '{pass}@{tenant}' }, submit: '#go' }, users: { qa: ['qa', 'secret:targets/t/qa/password'] }, profiles: { admin: { login: 'root', secret: 'targets/t/qa/password', fields: { tenant: 'acme' } } } }
const tq = await m.login({ page: {}, t, tenant: '', as: 'qa' }, h), ta = await m.login({ page: {}, t, tenant: '', as: 'admin' }, h)
console.log([filled.join(','), tq, ta, m.resolveSecret('plain'), typeof m.ADAPTERS.login.web.secretRefs].join('|'))
"@
$env:KIT_SECRET_TARGETS_T_QA_PASSWORD = 'W-1'; $wlO = "$(node $wlRun 2>&1)"
Remove-Item Env:KIT_SECRET_TARGETS_T_QA_PASSWORD; Remove-Item $wlCfg
Expect "web login: secret:<name> ref and a profile's store secret resolved by the kit's store, profile login + tenant ($wlO)" ($wlO -eq 'qa,W-1@,root,W-1@acme||acme|plain|function')

# local-env caps off (no localEnv, no devices, no tenants): supervise and health print no WATCH / ACT for lanes, marks, partitions, phones
$k9 = New-TestKit adapters-lec; $env:KIT_TRACKER_TYPE = 'none'
$lecJ = pwsh @np (Join-Path $k9 'skills/bossy/bossy.ps1') supervise -Json 2>$null | Out-String | ConvertFrom-Json
$lecF = @($lecJ.flags | Where-Object { $_.level -in 'WATCH', 'ACT' } | ForEach-Object { "$($_.level) $($_.kind) $($_.what)" })
$lecH = @(pwsh @np (Join-Path $k9 'skills/bossy/bossy.ps1') health 2>&1 | Where-Object { "$_" -match '\b(WATCH|ACT)\b' -and "$_" -match '(?i)lane|mark|tenant|partition|phone|device|local env|envy' })
Expect "local-env caps off: no WATCH / ACT about lanes, marks, partitions, phones ($(@($lecF + $lecH) -join ' | '))" ($null -ne $lecJ.flags -and -not @($lecF | Where-Object { $_ -match '(?i)lane|mark|tenant|partition|phone|device|local env|envy' }).Count -and -not $lecH.Count)

Complete-Tests
