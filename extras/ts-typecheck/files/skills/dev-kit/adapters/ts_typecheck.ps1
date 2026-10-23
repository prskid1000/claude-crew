#Requires -Version 7
# ts-typecheck (extra): dev.ps1 check -Step typecheck for tsc. TS5103 (a TypeScript too new for the tsconfig) -> one retry with a
# temp tsconfig (ignoreDeprecations); errors count only in changed files (+ config errors); > 200 baseline errors = UNRUN (exit 5).
# Dot-sourced from skills/dev-kit/adapters/; runs inside Invoke-Check and uses its $st, $log, Hash12, Get-ChangedFiles, Get-WtTarget.
# TS5103: one retry with a temp tsconfig; fail only on changed files + config errors
function Invoke-Typecheck([string]$TcCmd) {
  $top = git -C $st.dir rev-parse --show-toplevel 2>$null
  $top = if ($top) { [IO.Path]::GetFullPath("$top".Trim()) } else { $null }
  $Repo = Split-Path $(if ($top) { $top } else { $st.dir }) -Leaf
  $log = Join-Path (Get-KitPath logs -Create) "typecheck-$Repo-$(Get-Date -Format yyyyMMdd-HHmmss).log"
  $proj = if ($TcCmd -match '\s-p\s+"?([^"\s]+)"?') { $Matches[1] } else { 'tsconfig.json' }
  $base = [IO.Path]::GetFullPath((Join-Path $st.dir $proj))
  $bin = $null; $d = $st.dir
  while ($d) {
    $p = Join-Path $d "node_modules/.bin/$(if ($KitIsWindows) { 'tsc.cmd' } else { 'tsc' })"
    if (Test-Path -LiteralPath $p) { $bin = $p; break }
    if (-not $top -or $d -eq $top) { break }
    $parent = Split-Path $d; if (-not $parent -or $parent -eq $d) { break }; $d = $parent
  }
  $ver = '5.0'; $tsVer = ''
  if ($bin) { try { $tsVer = [string](Get-Content -LiteralPath (Join-Path (Split-Path (Split-Path $bin)) 'typescript/package.json') -Raw | ConvertFrom-Json).version; if ([int](($tsVer -split '\.')[0]) -ge 6) { $ver = '6.0' } } catch {} }
  $raw = try { Get-Content -LiteralPath $base -Raw } catch { '' }
  # the marker skips a doomed first run (~1 GB)
  $igd = if ($raw -match '"ignoreDeprecations"\s*:\s*"([^"]*)"') { $Matches[1] } else { '' }
  $flag = Join-Path (Get-KitPath tsbuild -Create) "ts5103.$(Hash12 "$($base.ToLower())|$igd|$tsVer").flag"
  if (Test-Path -LiteralPath $flag) {
    $out = @()
    Write-Host "[check] TS5103 known (marker $(Split-Path $flag -Leaf)): skipping the first tsc run"
  } else {
    & $KitCmd.dev gate -Dir $st.dir -Cmd "$TcCmd > `"$log`" 2>&1"
    $rc = $LASTEXITCODE
    $out = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log })
    $nErr = @($out -match '^(.+?\(\d+,\d+\): )?error TS\d+').Count
    if (-not @($out -match 'error TS5103').Count) {
      if ($rc -and $nErr -gt $script:TypecheckUnrunAbove) { return (Split-TypecheckErrors $out $rc $null $null) }
      $out | ForEach-Object { Write-Host $_ }
      if ($rc -and $out.Count) { Write-Host "[check] typecheck log: $log" }
      return $rc
    }
    Set-Content -LiteralPath $flag -Value "$base | ignoreDeprecations '$igd' | typescript $tsVer"
  }
  $tsCfg = [ordered]@{ extends = $base.Replace('\', '/'); compilerOptions = @{ ignoreDeprecations = $ver } }
  # else tsc includes the temp config's folder
  if ($raw -notmatch '"(files|include)"\s*:') {
    $pd = (Split-Path $base).Replace('\', '/')
    $ex = @('node_modules', 'bower_components', 'jspm_packages')
    try { $j = $raw | ConvertFrom-Json; if ($j.exclude) { $ex = @($j.exclude) } } catch {}
    $tsCfg.include = @("$pd/**/*")
    $tsCfg.exclude = @($ex | ForEach-Object { if ([IO.Path]::IsPathRooted($_)) { $_ } else { "$pd/$_" } })
  }
  $hash = Hash12 $st.dir.ToLower()
  $tmp = Join-Path (Get-KitPath cache -Create) "tsconfig.ts5103.$hash.$PID.json"
  $tsb = Join-Path (Get-KitPath tsbuild -Create) "$hash.ts5103.tsbuildinfo"
  $tsc = if ($bin) { "`"$bin`"" } else { 'npx tsc' }
  Write-Host "[check] typecheck TS5103 fallback: temp tsconfig (ignoreDeprecations $ver), $(if ($bin) { $bin } else { 'npx tsc' })"
  $fbCmd = "$tsc -p `"$tmp`" --noEmit --pretty false --incremental --tsBuildInfoFile `"$tsb`" >> `"$log`" 2>&1"
  $fbStart = [DateTimeOffset]::Now
  try {
    $tsCfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    & $KitCmd.dev gate -Dir $st.dir -Cmd $fbCmd
    $rc = $LASTEXITCODE
  } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  $out2 = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | Select-Object -Skip $out.Count })
  if ($rc -eq 3 -and -not $out2.Count) { return 3 }
  if (@($out2 -match 'error TS5103').Count) { Remove-Item -LiteralPath $flag -ErrorAction SilentlyContinue }   # no cure: next run starts over
  return (Split-TypecheckErrors $out2 $rc $fbCmd $fbStart)
}

# a huge baseline (node_modules mismatch) is UNRUN, not a pass
function Split-TypecheckErrors($out2, [int]$rc, [string]$GateCmd, $Since) {
  $changed = @(Get-ChangedFiles | ForEach-Object { $_.ToLower() })
  $mine = [Collections.Generic.List[string]]::new(); $mineN = 0; $baseN = 0; $baseFiles = @{}; $cur = $null; $blocks = 0
  foreach ($l in $out2) {
    if ($l -match '^(?<f>.+?)\(\d+,\d+\): error TS(?<code>\d+)' -or $l -match '^error TS(?<code>\d+)') {
      $blocks++
      $f = $Matches.f; $isCfg = (-not $f) -or $Matches.code -match '^[56]\d{3}$' -or $Matches.code -eq '18003'
      $full = if ($f) { [IO.Path]::GetFullPath((Join-Path $st.dir $f)).ToLower() } else { $null }
      if ($isCfg -or $changed -contains $full) { $cur = 'mine'; $mineN++ } else { $cur = 'base'; $baseN++; $baseFiles[$full] = 1 }
    }
    elseif (-not ($cur -and $l -match '^\s')) { $cur = $null }
    if ($cur -eq 'mine') { $mine.Add($l) }
  }
  $mine | ForEach-Object { Write-Host $_ }
  Write-Host "BASELINE: $baseN errors outside your changes ($($baseFiles.Count) files; not failing; log: $log)"
  if ($mineN) { Write-Host "[check] typecheck: $mineN errors in your changed files (or config)"; return 1 }
  if ($rc -and -not $blocks) { $out2 | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }; return $rc }
  if ($baseN -gt $script:TypecheckUnrunAbove) {
    $tgt = Get-WtTarget; if (-not $tgt) { $tgt = '<target>' }
    Write-Host "[check] typecheck UNRUN: $baseN baseline errors (> $script:TypecheckUnrunAbove): the linked node_modules do not match this branch, real errors hide there. Say 'typecheck unrun' in the MR; the lead sets kit.local.json linkFromByTarget.$tgt to a checkout with matching node_modules."
    return 'unrun'
  }
  if ($rc -and $GateCmd) { Set-GateSampleOk $GateCmd $Since }
  return 0
}
$script:TypecheckUnrunAbove = 200

function Set-GateSampleOk([string]$GateCmd, [DateTimeOffset]$Since) {
  $hf = Join-Path (Join-Path (Get-KitTemp) 'claude-build-gate') 'history.json'
  if (-not (Test-Path -LiteralPath $hf)) { return }
  $pre = if ($GateCmd.Length -gt 60) { $GateCmd.Substring(0, 60) } else { $GateCmd }
  $fromUtc = $Since.UtcDateTime.AddSeconds(-2)
  $mx = New-Object System.Threading.Mutex($false, 'Global\claude-build-gate'); $got = $false
  try {
    $got = Lock-Gate $mx
    if (-not $got) { return }
    $h = Get-Content -LiteralPath $hf -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($h -isnot [hashtable]) { return }
    $best = $null; $bestAt = [datetime]::MinValue
    foreach ($k in @($h.Keys)) { foreach ($s in @($h[$k])) {
      if (-not $s -or $s.ok -or -not $s.at -or -not ([string]$s.cmd).StartsWith($pre)) { continue }
      $at = ([datetime]$s.at).ToUniversalTime()
      if ($at -ge $fromUtc -and $at -gt $bestAt) { $best = $s; $bestAt = $at } } }
    if (-not $best) { return }
    $best.ok = $true; $best.baseline = $true
    $h | ConvertTo-Json -Depth 3 | Set-Content "$hf.tmp" -ErrorAction Stop
    Move-Item "$hf.tmp" $hf -Force -ErrorAction Stop
  } catch {} finally { if ($got) { $mx.ReleaseMutex() }; $mx.Dispose() }
}
