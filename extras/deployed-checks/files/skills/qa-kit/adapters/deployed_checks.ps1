# deployed-checks (extra): deploy kinds ssh, awsStack, probe, tag, manual for qa.ps1 deployed (dot-sourced from adapters/).
# Test-DeployedExtra runs inside Invoke-Deployed and uses its $sha, $s8, $mr, $p, $r, $memo, Row, Api, OnRef, LocalAncestor.
function Invoke-Sh([string]$c) { if ($KitIsWindows) { cmd.exe /d /c $c 2>$null } else { /bin/sh -c $c 2>$null } }
# probeField: JSON path in the answer
function Probe($d, $r) {
  if ($d.tag) { git -C $r.checkout fetch -q --tags 2>$null; return @(git -C $r.checkout tag --sort=-creatordate 2>$null | Where-Object { $_ -match $d.tag })[0] }
  $o = if ($d.probe -match '^https?://') { try { (Invoke-WebRequest $d.probe -ConnectionTimeoutSeconds 30).Content } catch { '' } } else { (Invoke-Sh $d.probe) -join "`n" }
  if ($d.probeField) { try { $j = $o | ConvertFrom-Json; foreach ($k in $d.probeField.Split('.')) { $j = $j.$k }; $o = "$j" } catch { $o = '' } }
  if ($d.probeRegex) { $m = [regex]::Match("$o", [string]$d.probeRegex); return $(if ($m.Success) { $m.Groups[1].Value } else { '' }) }
  [regex]::Match("$o", '\b[0-9a-f]{7,40}\b').Value
}
# one memoised ssh call (script as base64); rc 0 match, 1 DIFF, 2 failed
function Sq($v) { "'" + ([string]$v -replace "'", "'\''") + "'" }
function SshState($s, $sha) {
  $sub = ([string]$s.subdir).Trim('/')
  $k = "$($s.host)|$($s.repoDir)|$sub|$($s.appDir)|$sha"
  if ($memo.ContainsKey($k)) { return $memo[$k] }
  $xs = (@($s.exclude | Where-Object { $_ }) | ForEach-Object { Sq $_ }) -join ' '
  $awk = 'NR == FNR { if (length($0) > 66) a[substr($0, 67)] = substr($0, 1, 64); next } length($0) > 66 { p = substr($0, 67); if (!(p in a)) print "not installed: " p; else if (a[p] != substr($0, 1, 64)) print "differs: " p }'
  $sh = @(
    '{'
    "R=$(Sq ([string]$s.repoDir).TrimEnd('/')); SUB=$(Sq $sub); A=$(Sq ([string]$s.appDir).TrimEnd('/')); X=($xs); SU=$(if ($s.sudo -ne $false) { "'sudo -n'" })"
    'H=sha256sum; command -v sha256sum >/dev/null || H="shasum -a 256"'
    'echo "HEAD=$(git -C "$R" rev-parse --short HEAD 2>/dev/null) $(git -C "$R" log -1 --format=%cI HEAD 2>/dev/null)"'
    "if git -C `"`$R`" merge-base --is-ancestor $sha HEAD 2>/dev/null; then echo ANC=yes; else echo ANC=no; fi"
    $(if ($s.service) { "echo `"SVC=`$(systemctl show -p ActiveEnterTimestamp --value $(Sq $s.service) 2>/dev/null)`"" })
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
  $lines = @(ssh -i $key -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $s.host "echo $b64 | base64 -d | bash" 2>$null)
  $r = if (-not ($lines -match '^RC=')) { $null } else {
    @{ head = (($lines -match '^HEAD=') -replace '^HEAD=', '' | Select-Object -First 1).Trim()
      anc = [bool]($lines -match '^ANC=yes'); rc = [int](($lines -match '^RC=') -replace '^RC=', '' | Select-Object -First 1)
      diff = @($lines -match '^DIFF=' -replace '^DIFF=', ''); svc = (($lines -match '^SVC=') -replace '^SVC=', '' | Select-Object -First 1)
      files = [int](($lines -match '^FILES=') -replace '^FILES=', '' | Select-Object -First 1) }
  }
  $memo[$k] = $r; $r
}
function Test-DeployedExtra($d) {
  if ($d.ssh) {   # host HEAD holds the merge AND files match
    $s = $d.ssh; $st = SshState $s $sha
    if (-not $st) { return Row $d 'UNKNOWN' "no answer from $($s.host) over ssh (key $($s.key); the host needs bash, git, base64)" }
    $where = "host HEAD $($st.head)$(if ($st.svc) { ", service up since $($st.svc)" })"
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
