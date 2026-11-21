#Requires -Version 7
# Usage: dot-sourced by pokey.ps1 from adapters/. Exit codes: none here (its verbs exit through pokey.ps1).
# deploys: pokey.ps1 deployed and the deploy-kind registry (ci-job, branch-mr, ssh, awsStack, probe, tag, manual, command, laneApk).
# Test-DeployedExtra runs inside Invoke-Deployed and uses its $sha, $s8, $mr, $p, $r, $memo, Row, Hv, OnRef, LocalAncestor.
# Sections: L6 shell · L15 probe · L78 kinds · L199 deployed
# ---- shell: one shell line per OS
function Invoke-Sh([string]$c) { if ($KitIsWindows) { cmd.exe /d /c $c 2>$null } else { /bin/sh -c $c 2>$null } }
# a deploy's paths (globs): deploys[].paths, else its ssh.subdir (a monorepo host installs only that folder); none = every MR
function Get-DeployPaths($d) { if ($d.paths) { @($d.paths) } elseif ("$($d.ssh.subdir)".Trim('/')) { @("$("$($d.ssh.subdir)".Trim('/'))/**") } else { @() } }
# glob: ** any depth, * and ? within one folder, the rest literal ([id] too); also used by deploy plan / intest (deploys.ps1)
function Test-DeployTouched($d, [string[]]$Files) {
  $rx = @(Get-DeployPaths $d | ForEach-Object { '^' + ([regex]::Escape($_) -replace '\\\*\\\*/', '(.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]') + '$' })
  -not $rx.Count -or @($Files | Where-Object { $f = $_; @($rx | Where-Object { $f -match $_ }).Count }).Count -gt 0
}
# ---- probe: version probe, memoised ssh state
# probeField: JSON path in the answer
function Probe($d, $r) {
  if ($d.tag) { git -C $r.checkout fetch -q --tags 2>$null; return @(git -C $r.checkout tag --sort=-creatordate 2>$null | Where-Object { $_ -match $d.tag })[0] }
  $o = if ($d.probe -match '^https?://') { try { (Invoke-WebRequest $d.probe -ConnectionTimeoutSeconds 30).Content } catch { '' } } else { (Invoke-Sh $d.probe) -join "`n" }
  if ($d.probeField) { try { $j = $o | ConvertFrom-Json; foreach ($k in $d.probeField.Split('.')) { $j = (Get-KitMember $j $k) }; $o = "$j" } catch { $o = '' } }
  if ($d.probeRegex) { $m = [regex]::Match("$o", [string]$d.probeRegex); return $(if ($m.Success) { $m.Groups[1].Value } else { '' }) }
  [regex]::Match("$o", '\b[0-9a-f]{7,40}\b').Value
}
# one memoised ssh call (script as base64); rc 0 match, 1 DIFF, 2 failed
function Sq($v) { "'" + ([string]$v -replace "'", "'\''") + "'" }
# ssh bounded by deploy.sshTimeoutSeconds (a hung host no longer eats the plan's deadline); a stub ssh function (tests) runs as is
function Invoke-BoundedSsh([string[]]$A, [int]$Sec) {
  $c = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c.CommandType -ne 'Application') { return @(ssh @A 2>$null) }
  $si = [Diagnostics.ProcessStartInfo]::new($c.Source); foreach ($x in $A) { $si.ArgumentList.Add($x) }
  $si.RedirectStandardOutput = $si.RedirectStandardError = $si.CreateNoWindow = $true; $si.UseShellExecute = $false
  $pr = [Diagnostics.Process]::Start($si); $so = $pr.StandardOutput.ReadToEndAsync(); $null = $pr.StandardError.ReadToEndAsync()
  if (-not $pr.WaitForExit($Sec * 1000)) { Stop-KitProcessTree $pr; return @() }
  @(if ($so.Wait(2000)) { $so.Result -split "`r?`n" | Where-Object { $_ } })
}
function SshState($s, $sha) {
  $sub = ([string]$s.subdir).Trim('/')
  $hk = "$($s.host)|$($s.repoDir)|$sub|$($s.appDir)|$($s.shaFile)"; $k = "$hk|$sha"
  if ($memo.ContainsKey($k)) { return $memo[$k] }
  $h = $memo[$hk]   # one ssh per host: a later MR's ancestry comes from the local checkout when it has the host HEAD
  if ($memo.ContainsKey($hk) -and -not $h.head) { $memo[$k] = $h; return $h }   # a host that failed once stays UNKNOWN this run
  if ($h.head) { $on = LocalAncestor $r.checkout $sha (($h.head -split ' ')[0]); if ($null -ne $on) { $memo[$k] = $h.Clone(); $memo[$k].anc = $on; return $memo[$k] } }
  $xs = (@(@($s.exclude) + '*.log' + '*.log.*' | Where-Object { $_ }) | ForEach-Object { Sq $_ }) -join ' '   # a tracked rotated log (application.log.1) is runtime, not code
  $awk = 'NR == FNR { if (length($0) > 66) a[substr($0, 67)] = substr($0, 1, 64); next } length($0) > 66 { p = substr($0, 67); if (!(p in a)) print "not installed: " p; else if (a[p] != substr($0, 1, 64)) print "differs: " p }'
  $sh = @(
    '{'
    "R=$(Sq ([string]$s.repoDir).TrimEnd('/')); SUB=$(Sq $sub); A=$(Sq ([string]$s.appDir).TrimEnd('/')); X=($xs); SU=$(if (Test-KitSshSudo $s) { "'sudo -n'" })"   # ssh.sudo (else deploy.ssh.sudo) true: sudo -n (default none)
    'H=sha256sum; command -v sha256sum >/dev/null || H="shasum -a 256"'
    'echo "HEAD=$(git -C "$R" rev-parse --short HEAD 2>/dev/null) $(git -C "$R" log -1 --format=%cI HEAD 2>/dev/null)"'
    $(if ($s.shaFile) { "echo `"DSHA=`$(`$SU cat $(Sq $s.shaFile) 2>/dev/null | head -c 64)`"" })
    "if git -C `"`$R`" merge-base --is-ancestor $sha HEAD 2>/dev/null; then echo ANC=yes; else echo ANC=no; fi"
    $(if ($s.service -and ($sc = Get-KitSshServiceCmd $s 'since' $s.service)) { "echo `"SVC=`$($sc 2>/dev/null)`"" })   # ssh.manager's start time
    'skip() { local c pat cs; IFS=/ read -ra cs <<< "$1"; for c in "${cs[@]}"; do for pat in "${X[@]}"; do [[ $c == $pat ]] && return 0; done; done; return 1; }'
    'cd "$R" 2>/dev/null || { echo RC=2; echo "DIFF=cannot cd to $R"; exit 0; }'
    '$SU test -d "$A" 2>/dev/null || { echo RC=2; echo "DIFF=$SU test -d $A failed (no app dir / passwordless sudo: ssh.sudo false)"; exit 0; }'
    'L=$(mktemp) || { echo RC=2; echo "DIFF=mktemp failed"; exit 0; }; trap ''rm -f "$L"'' EXIT'
    'git ls-files -z -- ${SUB:+"$SUB"} | while IFS= read -r -d "" f; do r="${f#"$SUB"/}"; skip "$r" || printf "%s\0" "$r"; done > "$L"'
    'N=$(tr -cd "\0" < "$L" | wc -c); echo "FILES=$N"'
    '[ "$N" -gt 0 ] || { echo RC=2; echo "DIFF=git ls-files lists no tracked files under ${SUB:-the repo}"; exit 0; }'
    'src=$(cd "$R/$SUB" && xargs -0 $H -- < "$L" 2>/dev/null)'
    'app=$($SU sh -c ''cd "$1" && shift && xargs -0 "$@" -- 2>/dev/null'' _ "$A" $H < "$L")'
    "out=`$(awk $(Sq $awk) <(printf '%s\n' `"`$app`") <(printf '%s\n' `"`$src`"))"
    'if [ -n "$out" ]; then echo RC=1; printf "%s\n" "$out" | sed "s/^/DIFF=/"; else echo RC=0; fi'
    '}'
  ) -join "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
  $key = [string]$s.key -replace '^~', $HOME
  $sec = [int](Get-KitParam 'deploy.sshTimeoutSeconds')
  $lines = Invoke-BoundedSsh @('-i', $key, '-o', 'BatchMode=yes', '-o', "ConnectTimeout=$([math]::Min(15, $sec))", '-o', 'StrictHostKeyChecking=accept-new', $s.host, "echo $b64 | base64 -d | bash") $sec
  $res = if (-not ($lines -match '^RC=')) { $null } else {
    @{ head = (($lines -match '^HEAD=') -replace '^HEAD=', '' | Select-Object -First 1).Trim()
      anc = [bool]($lines -match '^ANC=yes'); rc = [int](($lines -match '^RC=') -replace '^RC=', '' | Select-Object -First 1)
      diff = @($lines -match '^DIFF=' -replace '^DIFF=', ''); svc = (($lines -match '^SVC=') -replace '^SVC=', '' | Select-Object -First 1)
      files = [int](($lines -match '^FILES=') -replace '^FILES=', '' | Select-Object -First 1); dsha = "$(($lines -match '^DSHA=') -replace '^DSHA=', '' | Select-Object -First 1)".Trim() }
  }
  $memo[$k] = $res; if (-not $memo.ContainsKey($hk)) { $memo[$hk] = $res }; $res
}
# ---- kinds: the deploy-kind registry (README "Adapters"): Register-KitAdapter 'deploy-kind' <name> @{ <verb> = { param($a) } }, $a.d = the
# deploys[] row. Verbs: isDeployed (a row; runs inside Invoke-Deployed: its $sha, $s8, $mr, $p, $r, Row, OnRef, LocalAncestor, Hv),
# lastDeploy (@{ at; source } | $null; $a.repo, $a.name), isRunning ($true | $false | $null), restart (deploys.ps1 deploy restart), plan (a hint line).
# A verb a kind lacks = UNKNOWN. deploys[].kind names one; else the row's keys pick it (laneApk, ssh, tag, probe, manual, awsStack, command, branch = ci-job).
function Get-KitDeployKind($d) {
  if ($d.kind) { return "$($d.kind)" }
  foreach ($k in 'laneApk', 'ssh', 'tag', 'probe', 'manual', 'awsStack', 'command') { if ((Get-KitMember $d $k)) { return $k } }
  if ($d.branch) { 'ci-job' } else { '' }
}
# a deploy-kind verb; $null = the kind lacks it (UNKNOWN), never another kind's check
function Invoke-KitDeployKind($d, [string]$Verb, [hashtable]$A = @{}) {
  $k = Get-KitDeployKind $d; $ad = $KitAdapters['deploy-kind'][$k]
  if (-not $ad -or -not $ad.ContainsKey($Verb)) { return $null }
  & $ad[$Verb] (@{ d = $d } + $A) $Verb
}
# ssh.manager: systemd | docker | pm2 | custom (ssh.restartCmd / statusCmd / sinceCmd, {svc} = the service); none = no restart, no status
function Get-KitSshServiceCmd($s, [string]$Verb, [string]$Svc) {
  $m = "$($s.manager)".ToLower(); if (-not $m -and ($s.restartCmd -or $s.statusCmd)) { $m = 'custom' }; if (-not $m) { $m = ([string](Get-KitSetting 'deploy.ssh.manager' '')).ToLower() }
  $t = switch ($m) {
    'systemd' { @{ restart = 'systemctl restart {svc}'; status = 'systemctl is-active {svc}'; since = 'systemctl show -p ActiveEnterTimestamp --value {svc}' }[$Verb] }
    'docker' { @{ restart = 'docker restart {svc}'; status = "docker inspect -f '{{.State.Status}}' {svc}"; since = "docker inspect -f '{{.State.StartedAt}}' {svc}" }[$Verb] }
    'pm2' { @{ restart = 'pm2 restart {svc}'; status = 'pm2 pid {svc}'; since = '' }[$Verb] }
    'custom' { [string](Get-KitMember $s "$($Verb)Cmd") }
    default { '' } }
  if ($t) { $t.Replace('{svc}', (Sq $Svc)) } else { '' }
}
# ssh.sudo, else deploy.ssh.sudo (default false)
function Test-KitSshSudo($s) { if ($null -ne $s.sudo) { $s.sudo -eq $true } else { (Get-KitSetting 'deploy.ssh.sudo' $false) -eq $true } }
# deploys[].command: { isDeployed, lastDeploy, isRunning, restart } command lines ({sha} {target} {branch} {repo} {mr} {service}); isDeployed
# prints DEPLOYED / NOT-DEPLOYED (yes / no) or the live commit; lastDeploy an ISO time; isRunning yes / no
function __DkCmd($d, [string]$Verb, [hashtable]$A) { Invoke-KitCommand 'deploy-kind' $d.command $Verb (@{ target = "$($d.target)"; branch = "$($d.branch)" } + $A) }
# adapter:deploy-kind/command
Register-KitAdapter 'deploy-kind' 'command' @{
  isDeployed = { param($a) $d = $a.d; $o = "$(__DkCmd $d 'isDeployed' @{ sha = $sha; repo = "$($r.name)"; mr = $ref })".Trim()
    if (-not $o) { return Row $d 'UNKNOWN' "command isDeployed gave no answer (deploys[].command.isDeployed)" }
    if ($o -match '^(?i)(DEPLOYED|yes|true)\b') { return Row $d 'DEPLOYED' "command: $o" }
    if ($o -match '^(?i)(NOT-DEPLOYED|no|false)\b') { return Row $d 'NOT-DEPLOYED' "command: $o" }
    $c = [regex]::Match($o, '\b[0-9a-f]{7,40}\b').Value; if (-not $c) { return Row $d 'UNKNOWN' "command isDeployed: $o" }
    $on = LocalAncestor $r.checkout $sha $c; if ($null -eq $on) { $on = OnRef $p $mr $sha $c }
    Row $d $(if ($on) { 'DEPLOYED' } else { 'NOT-DEPLOYED' }) "live commit $c $(if ($on) { 'holds' } else { 'lacks' }) $s8" }
  lastDeploy = { param($a) $o = "$(__DkCmd $a.d 'lastDeploy' @{})".Trim(); $at = try { [datetime]$o } catch { $null }; if ($at) { @{ at = $at; source = "command $($a.d.target)" } } }
  isRunning = { param($a) $o = "$(__DkCmd $a.d 'isRunning' @{})".Trim(); if ($o -match '^(?i)(yes|true|running)\b') { $true } elseif ($o) { $false } else { $null } }
  restart = { param($a) __DkCmd $a.d 'restart' @{ service = "$($a.service)" } }
}
# CI deploy job on deploys[].branch (deploys[].job, a -like pattern): the MR on the branch and a green job run that holds it
# adapter:deploy-kind/ci-job
Register-KitAdapter 'deploy-kind' 'ci-job' @{
  isDeployed = { param($a) $d = $a.d
    if (-not (OnRef $p $mr $sha $d.branch)) { return NotLiveRow $p $ref $d "not on $($d.branch) yet" }
    $hit = $null
    # a run older than the merge cannot hold it
    foreach ($pl in @(Hv 'ci.runs' @{ ref = $d.branch; per_page = 10 }) | Where-Object { $_ -and (-not $mr.merged_at -or [datetimeoffset]$_.created_at -ge [datetimeoffset]$mr.merged_at) }) {
      if ($pl.sha -ne $sha -and -not (OnRef $p $mr $sha $pl.sha $d.branch)) { continue }   # the checkout answers first; jobs only for a run that holds it
      $job = @(Hv 'ci.jobs' @{ id = $pl.id }) | Where-Object { $_.name -like $d.job } | Select-Object -First 1   # matrix names
      if ((ConvertTo-KitCiState "$($job.status)") -eq 'success') { $hit = $job; break }
    }
    if ($hit) { Row $d 'DEPLOYED' "$($d.job) finished $($hit.finished_at)" } else { NotLiveRow $p $ref $d "on $($d.branch), but no successful $($d.job) includes it yet" } }
  # newest first: the first green run = the last deploy; a running / pending one before it = a deploy in flight (manual / scheduled are not)
  lastDeploy = { param($a) foreach ($pl in @(Invoke-HostVerb 'ci.runs' @{ repo = $a.repo; ref = $a.d.branch; per_page = 5 })) { if ((ConvertTo-KitCiState "$($pl.status)") -eq 'success') { return @{ at = ([datetime]$(if ($pl.updated_at) { $pl.updated_at } else { $pl.created_at })).ToLocalTime(); source = "CI $($a.name) $($a.d.branch)" } } } }
  isRunning = { param($a) foreach ($pl in @(Invoke-HostVerb 'ci.runs' @{ repo = $a.repo; ref = $a.d.branch; per_page = 5 })) { $w = __CiWord "$($pl.status)"; if ($w -eq 'success') { return $false }; if ($w -in 'running', 'pending') { return $true } }; $false }
  plan = { param($a) "merge into $($a.d.branch); CI job $($a.d.job) deploys (bossy.ps1 deploy merge -To $($a.d.target) -Mr)" }
}
# deploys[].branch reached through a deploy MR (bossy.ps1 deploy merge -Mr); live = on that branch (no job to wait for)
# adapter:deploy-kind/branch-mr
Register-KitAdapter 'deploy-kind' 'branch-mr' @{
  isDeployed = { param($a) $d = $a.d; if (OnRef $p $mr $sha $d.branch) { Row $d 'DEPLOYED' "on $($d.branch)" } else { NotLiveRow $p $ref $d "not on $($d.branch) yet" } }
  plan = { param($a) "deploy MR into $($a.d.branch) (bossy.ps1 deploy merge -To $($a.d.target) -Mr)" }
}
# adapter:deploy-kind/ssh
Register-KitAdapter 'deploy-kind' 'ssh' @{ isDeployed = { param($a) Test-DeployedExtra $a.d }; restart = { param($a) Invoke-DeployRestartSsh $a.d.target $a.d $a.service } }
# adapter:deploy-kind/tag
Register-KitAdapter 'deploy-kind' 'tag' @{ isDeployed = { param($a) Test-DeployedExtra $a.d }; plan = { param($a) "tag $($a.d.tag) (bossy.ps1 deploy merge -To $($a.d.target) -Push)" } }
# adapter:deploy-kind/probe
Register-KitAdapter 'deploy-kind' 'probe' @{ isDeployed = { param($a) Test-DeployedExtra $a.d } }
# adapter:deploy-kind/manual
Register-KitAdapter 'deploy-kind' 'manual' @{ isDeployed = { param($a) Test-DeployedExtra $a.d } }
# adapter:deploy-kind/awsStack
Register-KitAdapter 'deploy-kind' 'awsStack' @{ isDeployed = { param($a) Test-DeployedExtra $a.d } }
# adapter:deploy-kind/laneApk
Register-KitAdapter 'deploy-kind' 'laneApk' @{ isDeployed = { param($a) Test-LaneApkDeployed $a.d } }
# adapter-end:deploy-kind
# isDeployed of ssh, awsStack, probe, tag, manual
function Test-DeployedExtra($d) {
  if ($d.ssh) {   # host HEAD holds the merge AND files match
    $s = $d.ssh; $st = SshState $s $sha
    if (-not $st) { return Row $d 'UNKNOWN' "no answer from $($s.host) over ssh within $(Get-KitParam 'deploy.sshTimeoutSeconds') s (key $($s.key); the host needs bash, git, base64)" }
    $where = "host HEAD $($st.head)$(if ($st.svc) { ", service up since $($st.svc)" })"
    if ($s.shaFile) {   # a CI deploy writes the commit it installed: live = the merge is its ancestor; the deploy branch head should equal it
      $ds = "$(("$($st.dsha)".Trim() -split '\s+')[0])".ToLower(); if ($ds -notmatch '^[0-9a-f]{7,40}$') { return Row $d 'UNKNOWN' "no commit in $($s.shaFile) on $($s.host) ($where)" }
      $d8 = $ds.Substring(0, [math]::Min(8, $ds.Length)); $bh = if ($d.branch) { "$(RefSha $p $d.branch)" }
      $lag = if (-not $d.branch) { '' } elseif (-not $bh) { "; $($d.branch) head unknown (git host)" } elseif (-not $bh.StartsWith($ds, 'OrdinalIgnoreCase')) { "; $($d.branch) is at $($bh.Substring(0, [math]::Min(8, $bh.Length))): a deploy pending or failed" }
      $on = if ($sha -eq $ds) { $true } else { LocalAncestor $r.checkout $sha $ds }
      if ($null -eq $on) { $mb = (Hv 'repo.base' @{ a = $sha; b = $ds }).id; if (-not $mb) { return Row $d 'UNKNOWN' "git host did not answer whether $d8 ($($s.shaFile)) holds $s8" }; $on = $mb -eq $sha }   # a failed call is not 'not deployed'
      return Row $d $(if ($on) { 'DEPLOYED' } else { 'NOT-DEPLOYED' }) "deployed commit $d8 ($($s.shaFile)) $(if ($on) { 'holds' } else { 'lacks' }) $s8$lag"
    }
    if ($st.rc -gt 1 -and -not $st.head) { return Row $d 'UNKNOWN' "host checkout unreadable: $(($st.diff | Select-Object -First 2) -join '; ')" }   # a wrong repoDir is not 'not deployed'
    if (-not $st.anc) { return Row $d 'NOT-DEPLOYED' "$s8 is not in the host checkout ($where)" }
    if ($st.rc -gt 1) { return Row $d 'UNKNOWN' "in the host checkout, but the compare failed: $(($st.diff | Select-Object -First 2) -join '; ')" }
    if ($st.diff.Count) { return Row $d 'NOT-DEPLOYED' "in the host checkout ($where), but $($st.diff.Count) of $($st.files) tracked file(s) differ from the installed app: $(($st.diff | Select-Object -First 3) -join '; ')" }
    return Row $d 'DEPLOYED' "in the host checkout and installed ($($st.files) tracked files match, $where)"
  }
  if ($d.probe -or $d.tag) {   # live commit: probe (URL / command) or newest matching tag
    $c = Probe $d $r; $w = if ($d.tag) { "tag $c" } else { "probe commit $c" }
    if (-not $c) { return Row $d 'UNKNOWN' "no commit from $(if ($d.tag) { "tags matching $($d.tag)" } else { "probe $($d.probe)" })" }
    $on = LocalAncestor $r.checkout $sha $c; if ($null -eq $on) { $on = OnRef $p $mr $sha $c }
    return Row $d $(if ($on) { 'DEPLOYED' } else { 'NOT-DEPLOYED' }) "$w $(if ($on) { 'holds' } else { 'lacks' }) $s8"
  }
  if ($d.manual) { return Row $d 'MANUAL' 'deployed by hand: confirm with the owner or an ssh check' }
  if ($d.awsStack) {   # no CI job: stack updated after the merge
    $ra = if ($d.region) { @('--region', $d.region) } else { @() }   # else AWS CLI default region
    $upd = aws cloudformation describe-stacks @ra --stack-name $d.awsStack --query 'Stacks[0].[LastUpdatedTime,StackStatus,CreationTime]' --output text 2>$null
    if (-not $upd) { return Row $d 'UNKNOWN' "cannot read stack $($d.awsStack) (aws sts get-caller-identity?)" }
    $at, $st, $created = "$upd" -split '\s+'
    if ($at -eq 'None') { $at = $created }   # a stack never updated since creation
    try {
      if ([datetimeoffset]$at -gt [datetimeoffset]$mr.merged_at -and $st -match 'COMPLETE$' -and $st -notmatch 'ROLLBACK') { Row $d 'DEPLOYED' "stack $($d.awsStack) updated $at after the merge (by hand: confirm the build was from the merged branch)" }
      else { Row $d 'NOT-DEPLOYED' "stack $($d.awsStack) last updated $at ($st), merged $($mr.merged_at)" }
    } catch { Row $d 'UNKNOWN' "stack $($d.awsStack): cannot read its update time ($upd)" }
  }
}

# ---- deployed: pokey.ps1 deployed, an MR live per test env
# pokey.ps1 deployed: is a merged MR live on a test env (CI deploy job, squash-merged deploy MR, same content; laneApk:
# ui_android.ps1; the kinds ssh, awsStack, probe, tag, manual: Test-DeployedExtra below)
# K93: a supervise beat's parallel probes (up to 16 processes) share their branch-level answers: each asked the same ci.runs / ci.jobs (96 calls a beat);
# the first asker holds the key's lock while it calls, the rest read its answer; bossy.ps1 supervise sets KIT_API_BEAT and drops the folder after the beat
function Get-BeatShared([string]$Key, [scriptblock]$Call) {
  $bd = Join-Path (Get-KitPath cache -Create) "api-memo/$env:KIT_API_BEAT"; $null = New-Item -ItemType Directory -Force $bd
  # file name: a readable prefix + two FNV-1a hashes of the whole key (feat/a vs feat_a, Main vs main, a cut long key: one file each)
  $h1 = [long]2166136261; $h2 = [long]2166136261; foreach ($ch in $Key.ToCharArray()) { $h1 = (($h1 -bxor [long][int]$ch) * 16777619) -band 4294967295L }; foreach ($ch in [char[]]($Key.ToCharArray() | Sort-Object -Descending)) { $h2 = (($h2 -bxor [long][int]$ch) * 16777619) -band 4294967295L }
  $bk = $Key -replace '[^\w.=-]+', '_'; $bf = Join-Path $bd "$($bk.Substring(0, [math]::Min(60, $bk.Length)))-$($h1.ToString('x8'))$($h2.ToString('x8')).json"; $script:beatAnswer = $null
  # an empty or failed answer is shared too ('null'): else every probe queued on the lock and asked again (16 x 40 s with the host down)
  Invoke-KitLocked $bf { if (Test-Path -LiteralPath $bf) { $script:beatAnswer = Get-Content -LiteralPath $bf -Raw | ConvertFrom-Json -Depth 40 } else { $script:beatAnswer = & $Call; Write-KitAtomic $bf $(if ($null -eq $script:beatAnswer) { 'null' } else { ConvertTo-Json -InputObject $script:beatAnswer -Depth 40 -Compress }) } }
  $script:beatAnswer
}
function Invoke-Deployed {
param([Parameter(Mandatory)][string[]]$Mrs, [string]$Target, [switch]$Json, [switch]$Detail, [string]$Exclude, [switch]$Lines, [int]$TimeoutSec = (Get-KitParam 'deploy.deployedTimeoutSec'))   # -Exclude <regex>: skip those targets; -Lines: one JSON row per line as each is known (deploy plan keeps them on a timeout); -TimeoutSec: past it the MRs left are UNKNOWN (the first is always checked)
$ErrorActionPreference = 'SilentlyContinue'

$repos = @(Get-KitValue 'repos' @())
function Row($d, $s, $x) { [pscustomobject]@{ mr = $ref; target = $d.target; state = $s; detail = $x; branch = "$($mr.target_branch)"; mrState = "$($mr.state)"; mergedAt = $(if ($mr.merged_at -is [datetime]) { ([datetimeoffset]$mr.merged_at).ToString('yyyy-MM-ddTHH:mm:sszzz') } else { "$($mr.merged_at)" }); source = "$($mr.source_branch)" } }   # branch: deploy plan's feeds check needs no host call; mrState / mergedAt: mr.get's, shown as is
function Repo($name) { $repos | Where-Object { $_.name -eq $name -or @($_.aliases) -contains $name } | Select-Object -First 1 }
# memoised: supervise asks per round
$memo = @{}
# one host verb on this MR's repo ($p = its host path), memoised by verb + args
function Hv([string]$Verb, [hashtable]$A = @{}) { $A = @{ repo = $p } + $A; $k = "$Verb|$(($A.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&')"; if (-not $memo.ContainsKey($k)) { $memo[$k] = if ($env:KIT_API_BEAT -and $Verb -in 'ci.runs', 'ci.jobs', 'repo.commit', 'repo.compare', 'repo.base', 'mr.list') { Get-BeatShared $k { Invoke-HostVerb $Verb $A } } else { Invoke-HostVerb $Verb $A } }; $memo[$k] }
# a ref -> its commit sha (one memoised host call per branch); a full sha as is
function RefSha($p, $ref) { if ($ref -match '^[0-9a-f]{40}$') { $ref } else { (Hv 'repo.commit' @{ ref = $ref }).id } }
# the local checkout answers when it holds both commits (ms, not a host call each); else the host
function IsAncestor($p, $sha, $ref) {
  if ($sha -eq $ref) { return $true }
  if (($at = RefSha $p $ref) -and $null -ne ($on = LocalAncestor $r.checkout $sha $at)) { return $on }
  (Hv 'repo.base' @{ a = $sha; b = $ref }).id -eq $sha
}
# squash / cherry-pick: live if no file differs from $ref
function ContentOn($p, $mr, $sha, $ref) {
  # cheap guard: a ref older than the merge (a pipeline sha: its date from the checkout when it has it)
  $cd = if ($ref -match '^[0-9a-f]{40}$' -and $r.checkout -and (Test-Path $r.checkout)) { "$(git -C $r.checkout show -s --format=%cI "$ref^{commit}" 2>$null)".Trim() }
  $head = if ($cd) { @{ id = $ref; committed_date = $cd } } else { Hv 'repo.commit' @{ ref = $ref } }
  if (-not $head -or ($mr.merged_at -and [datetimeoffset]$head.committed_date -lt [datetimeoffset]$mr.merged_at)) { return $false }
  if (-not (IsAncestor $p $sha $mr.target_branch)) { return $false }
  $files = @((MrChanges $mr.iid).changes | ForEach-Object { $_.new_path; $_.old_path } | Sort-Object -Unique)
  if (-not $files.Count) { return $false }
  $tip = RefSha $p $mr.target_branch
  if ($head.id -and $tip -and $null -ne ($same = LocalSame $r.checkout $head.id $tip $files)) { return $same }
  $cmp = Hv 'repo.compare' @{ from = $ref; to = $mr.target_branch; straight = 'true' }
  if (-not $cmp -or $cmp.compare_timeout -or $cmp.overflow) { return $false }   # a capped diff list (3000 of 6552 files) proves nothing
  -not @($cmp.diffs | Where-Object { $files -contains $_.new_path -or $files -contains $_.old_path }).Count
}
# squash-merged deploy MR: live if one merged into $branch after a source head held the commit
function ViaDeployMr($p, $mr, $sha, $ref, $branch) {
  if (-not $branch -or -not $mr.merged_at) { return $false }
  $after = ([datetimeoffset]$mr.merged_at).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
  foreach ($dm in @(Hv 'mr.list' @{ state = 'merged'; target_branch = $branch; updated_after = $after; per_page = 50 }) | Where-Object { $_ -and $_.iid -ne $mr.iid }) {
    $land = @($dm.merge_commit_sha, $dm.squash_commit_sha) | Where-Object { $_ } | Select-Object -First 1
    if ($land -and $dm.sha -and (IsAncestor $p $sha $dm.sha) -and (IsAncestor $p $land $ref)) { return $true }
  }
  $false
}
# NOT-DEPLOYED only if the host answers, else UNKNOWN
function NotLiveRow($p, $ref, $d, [string]$detail) { if ($null -eq (Hv 'repo.commit' @{ ref = $d.branch })) { Row $d 'UNKNOWN' "the git host did not answer for $($d.branch): try again" } else { Row $d 'NOT-DEPLOYED' $detail } }
# a yes is kept across beats per (merge sha, commit of $ref): ancestry never changes; a no may be a failed host call
function OnRef($p, $mr, $sha, $ref, $branch = $ref) {
  $at = if ($env:KIT_API_BEAT -and $null -ne $rcache) { RefSha $p $ref }; $ok = if ($at) { "on|$sha|$at" }
  if ($ok -and $rcache[$ok]) { return $true }
  $on = (IsAncestor $p $sha $ref) -or (ViaDeployMr $p $mr $sha $ref $branch) -or (ContentOn $p $mr $sha $ref)
  if ($on -and $ok) { $rcache[$ok] = @{ at = (Get-Date).ToString('o') }; $rdirty.on = $true }
  $on
}
# a merged MR's changed files (never change): kept across beats
function MrChanges($iid) {
  # keyed by repo + iid, never $ref: ContentOn's parameter of that name (a branch) shadows it
  $k = "chg|$($r.name)!$iid"; if ($null -ne $rcache -and $rcache[$k]) { return [pscustomobject]@{ changes = @($rcache[$k].files | ForEach-Object { [pscustomobject]@{ new_path = $_; old_path = $_ } }); overflow = [bool]$rcache[$k].overflow } }
  $ch = Hv 'mr.changes' @{ n = $iid }
  if ($env:KIT_API_BEAT -and $null -ne $rcache -and $ch -and $mr.state -eq 'merged') { $rcache[$k] = @{ at = (Get-Date).ToString('o'); overflow = [bool]$ch.overflow -or @($ch.changes).Count -ge 100; files = @(@($ch.changes) | ForEach-Object { $_.new_path; $_.old_path } | Where-Object { $_ } | Select-Object -Unique) }; $rdirty.on = $true }
  $ch
}
# $null if the checkout or either commit is missing
function LocalAncestor($dir, $sha, $commit) {
  if (-not $dir -or -not (Test-Path $dir)) { return $null }
  foreach ($c in $commit, $sha) { git -C $dir cat-file -e "$c^{commit}" 2>$null; if ($LASTEXITCODE) { return $null } }
  git -C $dir merge-base --is-ancestor $sha $commit 2>$null
  $LASTEXITCODE -eq 0
}
# $files equal in commits $a and $b; $null if the checkout or either commit is missing
function LocalSame($dir, $a, $b, $files) {
  if (-not $dir -or -not (Test-Path $dir)) { return $null }
  foreach ($c in $a, $b) { git -C $dir cat-file -e "$c^{commit}" 2>$null; if ($LASTEXITCODE) { return $null } }
  $global:LASTEXITCODE = $null   # git not started must not read as "same"
  $changed = @(git -C $dir -c core.quotePath=off diff --no-renames --name-only $a $b 2>$null)   # no pathspecs: no command-line limit on a large MR
  if ($LASTEXITCODE -ne 0) { return $null }
  -not @($changed | Where-Object { $files -contains $_ }).Count
}
# supervise beats only (KIT_API_BEAT): answers kept across beats, merged MRs and settled rows (D13: 238 host verbs a beat)
$keepH = [double](Get-KitParam 'deploy.deployedKeepHours'); $rcf = Join-Path (Get-KitPath cache -Create) 'deployed-rows.json'; $rdirty = @{ on = $false }
$rcache = if ($env:KIT_API_BEAT) { try { Read-KitText $rcf | ConvertFrom-Json -AsHashtable } catch { $null } }; if ($rcache -isnot [hashtable]) { $rcache = @{} }# pwsh -File keeps the quotes: strip, split
$out = [Collections.Generic.List[object]]::new(); $until = (Get-Date).AddSeconds($TimeoutSec); $nth = 0
& { foreach ($m in @(Split-KitList $Mrs)) {
  if ($nth++ -and (Get-Date) -gt $until) { [pscustomobject]@{ mr = $m; target = "$Target"; state = 'UNKNOWN'; detail = "not checked: -TimeoutSec $TimeoutSec reached (check it again)" }; continue }
  $m = if ($u = ConvertFrom-MrUrl $m) { "$(($u.repo -split '/')[-1])!$($u.n)" } else { "$m".Trim() -replace '^[\w./-]+/(?=[\w.-]+!\d+$)' }   # an MR URL or <group>/<repo>!<iid> -> <repo>!<iid> (as bossy.ps1 ConvertTo-MrRef; pokey does not load bossy)
  if ($m -notmatch '^(?<repo>[\w.-]+)!(?<iid>\d+)$') { [pscustomobject]@{ mr = $m; target = ''; state = 'BAD-REF'; detail = 'expected <repo>!<iid>, <group>/<repo>!<iid> or an MR URL' }; continue }
  $r = Repo $Matches.repo; $iid = $Matches.iid
  # K106: a repo nothing deploys (docs) is n/a, never BAD-REF (it left a task out of a testy run)
  if (-not $r) { [pscustomobject]@{ mr = $m; target = "$Target"; state = 'N/A'; detail = 'n/a: repo not in kit.local.json repos (no deploy config)' }; continue }
  if (-not @($r.deploys | Where-Object { $_ }).Count) { [pscustomobject]@{ mr = "$($r.name)!$iid"; target = "$Target"; state = 'N/A'; detail = 'n/a: no deploys configured for this repo' }; continue }
  $p = Get-HostProject $r.name -Raw; $ref = "$($r.name)!$iid"   # gitHostGroup/<repo>
  $mr = if ($rcache["mr|$ref"]) { $rcache["mr|$ref"].mr } else { Hv 'mr.get' @{ n = $iid } }
  if ($mr.state -eq 'merged' -and -not $rcache["mr|$ref"]) { $rcache["mr|$ref"] = @{ at = (Get-Date).ToString('o'); mr = $mr | Select-Object iid, state, merged_at, target_branch, source_branch, squash_commit_sha, merge_commit_sha, sha }; $rdirty.on = $true }   # a merged MR never changes
  if (-not $mr -or -not $mr.iid) { [pscustomobject]@{ mr = $ref; target = ''; state = 'UNKNOWN'; detail = 'git host did not answer (glab/gh auth status?)' }; continue }   # a failed call is not 'not merged'
  if ($mr.state -ne 'merged') { [pscustomobject]@{ mr = $ref; target = ''; state = 'NOT-MERGED'; detail = "$($mr.state)" }; continue }
  # fast-forward: the MR head sha landed
  $sha = @($mr.squash_commit_sha, $mr.merge_commit_sha, $mr.sha) | Where-Object { $_ } | Select-Object -First 1
  if (-not $sha) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'UNKNOWN'; detail = 'merged MR has no commit sha (glab auth status?)' }; continue }
  $s8 = $sha.Substring(0, [math]::Min(8, $sha.Length))
  # deploys[].serves: the app envs a service host backs (a backend service of the app env checked on its own hosts)
  $deps = @($r.deploys | Where-Object { (-not $Target -or $_.target -in @(Split-KitList $Target) -or @(@($_.serves) | Where-Object { $_ -in @(Split-KitList $Target) }).Count) -and (-not $Exclude -or $_.target -notmatch $Exclude) })
  if (-not $deps.Count) { [pscustomobject]@{ mr = $ref; target = "$Target"; state = 'NO-TARGET'; detail = $(if ($Target) { "no deploys[] entry of $($r.name) has target or serves $Target (map an app env to this repo's hosts: deploys[].serves)" } else { "every deploys[] entry of $($r.name) matches -Exclude $Exclude" }) }; continue }
  foreach ($d in $deps) {
    if ($d.from -and $mr.target_branch -and $mr.target_branch -notin @($d.from) -and $mr.target_branch -ne $d.branch) { Row $d 'N/A' "n/a for $($d.target): merged into $($mr.target_branch), not $(@($d.from) -join ' / ')"; continue }   # before any probe (ssh, pipelines)
    if (@(Get-DeployPaths $d).Count) {   # an MR outside the target's paths is n/a there: no ssh, no NOT-DEPLOYED
      $ch = MrChanges $iid; $files = @(@($ch.changes) | ForEach-Object { $_.new_path; $_.old_path } | Where-Object { $_ } | Select-Object -Unique)
      if ($files.Count -and -not $ch.overflow -and @($ch.changes).Count -lt 100 -and -not (Test-DeployTouched $d $files)) { Row $d 'N/A' "n/a for $($d.target): changes nothing under $((Get-DeployPaths $d) -join ', ')"; continue }   # a partial list proves nothing
    }
    # incremental: DEPLOYED holds deploy.deployedKeepHours; NOT-DEPLOYED while the deploy branch head is unchanged (one shared call a branch)
    $ck = "row|$ref|$($d.target)"; $c = $rcache[$ck]; $fresh = $c -and ((Get-Date) - [datetime]$c.at).TotalHours -lt $keepH
    if ($fresh -and $c.row.state -eq 'DEPLOYED') { [pscustomobject]$c.row; continue }
    $hd = if ($d.branch) { RefSha $p $d.branch }; if ($fresh -and $hd -and $c.head -eq $hd -and "$($c.row.detail)" -like 'not on * yet') { [pscustomobject]$c.row; continue }
    # the row's deploy kind answers (registry above); a kind without isDeployed, or none, = UNKNOWN
    $kd = Get-KitDeployKind $d
    $kRow = try { Invoke-KitDeployKind $d 'isDeployed' } catch { Row $d 'UNKNOWN' "deploy kind ${kd}: $($_.Exception.Message)" }
    if (-not $kRow) { $kRow = Row $d 'UNKNOWN' $(if ($kd) { "deploy kind $kd has no isDeployed check (README ""Adapters"" deploy-kind)" } else { 'no deploy kind: set deploys[].kind or branch + job, ssh, probe, tag, awsStack, manual, command' }) }
    # NOT-DEPLOYED only while the merge is not on the branch: on it, a deploy job or host install finishes with the head unchanged
    if (@($kRow).Count -eq 1 -and ($kRow.state -eq 'DEPLOYED' -or ($kRow.state -eq 'NOT-DEPLOYED' -and "$($kRow.detail)" -like 'not on * yet'))) { $rcache[$ck] = @{ at = (Get-Date).ToString('o'); head = $hd; row = $kRow }; $rdirty.on = $true }
    $kRow
  }
} } | ForEach-Object { $out.Add($_); if ($Lines) { $_ | ConvertTo-Json -Depth 3 -Compress } }
if ($env:KIT_API_BEAT -and $rdirty.on) {   # parallel probes: merged under the lock; rows past their hours and month-old MRs dropped
  Invoke-KitLocked $rcf { $all = try { Read-KitText $rcf | ConvertFrom-Json -AsHashtable } catch { $null }; if ($all -isnot [hashtable]) { $all = @{} }
    foreach ($k in $rcache.Keys) { $all[$k] = $rcache[$k] }
    foreach ($k in @($all.Keys)) { if ($k -like 'row|*' -and ((Get-Date) - [datetime]$all[$k].at).TotalHours -ge $keepH) { $all.Remove($k) } elseif ($k -match '^(mr|chg|on)\|' -and ((Get-Date) - [datetime]$all[$k].at).TotalDays -gt 30) { $all.Remove($k) } }
    Write-KitAtomic $rcf ($all | ConvertTo-Json -Depth 12 -Compress) }
}
$miss = @($out | Where-Object { $_.state -notin 'DEPLOYED', 'N/A' })   # N/A: the MR has nothing for that target
if ($Lines) { exit $(if ($miss.Count) { 1 } else { 0 }) }
$row = { "{0,-13} {1,-18} {2,-12} {3}" -f $_.state, $_.mr, $_.target, $_.detail }
if ($Json) { return ($out | ConvertTo-Json -Depth 3) }   # returns, never exits: pokey.ps1 prepare calls it in-process (an exit ended prepare silently)
elseif ($Detail) { $out | ForEach-Object $row }
else {
  $live = @($out | Where-Object state -eq 'DEPLOYED')
  "deployed: $($live.Count)/$($live.Count + $miss.Count) MR x target$(if ($live.Count) { ' (' + (($live | ForEach-Object { "$($_.mr)@$($_.target)" }) -join ', ') + ')' })"
  $out | Where-Object state -ne 'DEPLOYED' | ForEach-Object $row
}
exit $(if ($miss.Count) { 1 } else { 0 })
}
