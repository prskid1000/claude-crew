<#
Safety net for test-and-close.js: watches the workflow's journal and publishes a package ONLY when the workflow's
own close step finished without publishing (ok=false, e.g. a small close agent refused). Never double-publishes.

  Windows:      Start-Process pwsh -WindowStyle Hidden -ArgumentList '-File','<workspace>/.claude/skills/qa-kit/scripts/autoclose.ps1','-Journal','<workflow transcript dir>','-RunDir','<run dir>'
  Linux/macOS:  nohup pwsh -File <workspace>/.claude/skills/qa-kit/scripts/autoclose.ps1 -Journal <workflow transcript dir> -RunDir <run dir> >/dev/null 2>&1 &

Merges verify verdicts into the checks, writes <run>/<code>/results.json, runs finalize.ps1 once per code.
Skips packages with > 50% NOT_TESTED. Logs to <run>/autoclose.log; remembers handled codes in <run>/autoclose_done.txt
(a code whose finalize.ps1 fails twice, counted in <run>/autoclose_failed.txt, is given up and logged).
#>
param([Parameter(Mandatory)][string]$Journal, [Parameter(Mandatory)][string]$RunDir, [int]$EveryMinutes = 4, [int]$MaxHours = 12)
$S = Split-Path $MyInvocation.MyCommand.Path
$done = "$RunDir\autoclose_done.txt"; if (-not (Test-Path $done)) { New-Item -ItemType File $done | Out-Null }
$failed = "$RunDir\autoclose_failed.txt"; if (-not (Test-Path $failed)) { New-Item -ItemType File $failed | Out-Null }
$log = "$RunDir\autoclose.log"
function Log($m) { "$(Get-Date -Format 'HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }
$run = Get-Content "$RunDir\run.json" -Raw | ConvertFrom-Json
$end = (Get-Date).AddHours($MaxHours)
while ((Get-Date) -lt $end) {
  try {
    $j = Get-Content "$Journal\journal.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }
    $started = @($j | Where-Object type -eq 'started')
    $results = @{}; foreach ($r in ($j | Where-Object type -eq 'result')) { $results[$r.agentId] = $r.result }
    $byLabel = @{}; foreach ($a in $started) { if ($results.ContainsKey($a.agentId)) { $byLabel[($a.label -replace '@.*$', '')] = $results[$a.agentId] } }
    $latest = @{}; foreach ($a in $started) { $latest[($a.label -replace '@.*$', '')] = $a }   # only the latest attempt per label counts
    $running = @($latest.GetEnumerator() | Where-Object { -not $results.ContainsKey($_.Value.agentId) } | ForEach-Object Key)
    $codes = $started | Where-Object { $_.label -match '^(re)?test:' } | ForEach-Object { ($_.label -replace '^(re)?test:', '') -replace '@.*$', '' } | Sort-Object -Unique
    $doneList = @(Get-Content $done)
    foreach ($code in $codes) {
      if ($doneList -contains $code) { continue }
      if (@("test:$code", "retest:$code", "audit:$code", "verify:$code", "close:$code") | Where-Object { $running -contains $_ }) { continue }
      $close = $byLabel["close:$code"]
      if (-not $close) { continue }
      if ($close.ok -eq $true) { Log "$code published by the workflow"; Add-Content $done $code; continue }
      $cands = @($byLabel["test:$code"], $byLabel["retest:$code"]) | Where-Object { $_ -and @($_.checks).Count }
      if (-not $cands.Count) { continue }
      $nt = { param($r) @($r.checks | Where-Object result -eq 'NOT_TESTED').Count / [math]::Max(1, @($r.checks).Count) }
      $res = $cands | Sort-Object { & $nt $_ } | Select-Object -First 1
      if ((& $nt $res) -gt 0.5) { Log "$code skipped: $([math]::Round((& $nt $res)*100))% NOT_TESTED - needs a manual look"; Add-Content $done $code; continue }
      $v = $byLabel["verify:$code"]
      $res | Add-Member -Force NoteProperty code $code
      # as test-and-close.js runItem(): unique check ids (repeats get b, c, ...), then the note audit (reclassified notes ->
      # FAIL; new defects numbered after the highest X id already used), so verify verdicts match their checks one to one
      $seen = @{}
      foreach ($c in $res.checks) { $id = [string]$c.id; $k = 1; while ($seen.ContainsKey($id)) { $id = "$($c.id)$([char](97 + $k++))" }; $c | Add-Member -Force NoteProperty id $id; $seen[$id] = 1 }
      $au = $byLabel["audit:$code"]
      if ($au) {
        foreach ($d in @($au.reclassify)) { $c = @($res.checks) | Where-Object { $_.id -eq $d.id } | Select-Object -First 1
          if ($c -and $d.defect -and $c.result -eq 'PASS_WITH_NOTE') { $c.result = 'FAIL'; $c.observed = "$($c.observed) | Note audit: a defect, not a note: $($d.reason)" } }
        $n = [int](@($res.checks | ForEach-Object { if ([string]$_.id -match '^X(\d+)$') { [int]$Matches[1] } else { 0 } }) + 0 | Measure-Object -Maximum).Maximum
        $sub = [string](@((@($run.items) | Where-Object code -eq $code | Select-Object -First 1).subtasks) | Select-Object -First 1).id
        foreach ($d in @($au.newDefects | Where-Object { $_ })) { $n++
          $res.checks = @($res.checks) + [pscustomobject]@{ id = "X$n"; subtask_id = $sub; screen = $d.screen; result = 'FAIL'; what_was_done = $d.what_was_done; observed = "$($d.observed) (raised by the note audit)"; evidence = @($d.evidence | Where-Object { $_ }) } }
      }
      foreach ($c in $res.checks) {
        if ($c.result -ne 'FAIL') { continue }
        $x = if ($v) { $v.verdicts | Where-Object id -eq $c.id | Select-Object -First 1 } else { $null }
        if (-not $x) { $c | Add-Member -Force NoteProperty verify 'not re-tested'; continue }
        $c | Add-Member -Force NoteProperty verify ($(if ($x.confirmed) { 'confirmed' } else { 'not reproduced' }))
        $c.evidence = @($c.evidence) + @($x.evidence)
        if ($x.confirmed) { $c.observed = "$($c.observed) | Independent re-test confirmed: $($x.observed)" }
        else { $c.result = 'PASS_WITH_NOTE'; $c.observed = "First run reported a failure; an independent re-test did not reproduce it. Re-test: $($x.observed). First run: $($c.observed)" }
      }
      $itm = @($run.items) | Where-Object code -eq $code | Select-Object -First 1
      if ($itm -and $itm.dups) {   # duplicate subtasks get the same checks as their primary
        foreach ($p in $itm.dups.PSObject.Properties) {
          $res.checks = @($res.checks) + @($res.checks | Where-Object subtask_id -eq $p.Value | ForEach-Object { $cc = $_ | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $cc.subtask_id = $p.Name; $cc })
        }
      }
      New-Item -ItemType Directory -Force "$RunDir\$code" | Out-Null
      $res | ConvertTo-Json -Depth 8 | Out-File "$RunDir\$code\results.json" -Encoding utf8
      Log "$code finalizing: $((($res.checks | Group-Object result | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '))"
      try { & (Join-Path $S 'finalize.ps1') -RunDir $RunDir -Code $code 2>&1 | ForEach-Object { Log "  $_" }; Add-Content $done $code }
      catch {
        # one line per failed attempt: give up after 2 so a broken package is not re-uploaded every loop
        Add-Content $failed $code; $n = @(Get-Content $failed | Where-Object { $_ -eq $code }).Count
        if ($n -ge 2) { Log "$code finalize failed $n times, giving up - needs a manual look: $_"; Add-Content $done $code }
        else { Log "$code finalize failed (attempt $n, retried next loop): $_" }
      }
    }
    if (-not $running.Count -and $started.Count -and ($j | Where-Object type -in 'finished', 'completed', 'done')) { Log 'workflow finished'; break }
  } catch { Log "error: $_" }
  Start-Sleep -Seconds ($EveryMinutes * 60)
}
