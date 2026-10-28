<#
video.ps1 (goody media-evidence): the PowerShell side of the video flow: `pokey.ps1 evidence <verb>` passes through to
skills/pokey/video.py (fetch, index, read-chunk, frames, write-vision, status: its header), and the local STT server lease.
  & <kit>/skills/pokey/pokey.ps1 evidence <verb> [args]     -> python video.py <verb> [args] (exit code passed on)
  & <kit>/skills/pokey/pokey.ps1 evidence stt <key> [-WaitMinutes 30] [-Agent a] [-Refresh]   (video.py index calls it) the
      transcribe stage under the `local-stt` lease (one job) and the memory gate (media.stt.ramGB, kind local-ai); JSON
  Use-KitLocalAi -Name local-stt [-Agent] [-Session] [-WaitMinutes 30]   -> $true held · $false timed out (waiting)
  Remove-KitLocalAi -Name <n> · Get-KitLocalAiState -Name <n>   -> { leases, waiting } (dead pids pruned)
Inputs: kit.local.json media.stt (maxConcurrent 1, ramGB, baseUrl). State: <runtime>/cache/media/_leases/<name>.json; a lease
belongs to the job process (pid + start time): a killed job frees it at once. Loaded by lib.ps1 (adapters/*.ps1): bossy.ps1
supervise gets Get-KitSuperviseGuardLocalAi ("waiting for local AI").
Exit codes: 0 ok · 1 problem (video.py's) · 2 usage.
Sections: L16 lease · L66 stt · L84 verb
#>
#Requires -Version 7
# ---- lease: local-stt, one job at a time per server, bound to the job's process
function Get-KitLocalAiFile([string]$Name) {
  $root = try { Get-KitPath media -Create } catch { Join-Path (Get-KitPath cache -Create) 'media' }   # an older core without _paths.media
  $d = Join-Path $root '_leases'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }; Join-Path $d "$Name.json"
}
function Get-KitLocalAiState([string]$Name) {
  $s = try { Get-Content (Get-KitLocalAiFile $Name) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }
  if ($s -isnot [hashtable]) { $s = @{} }
  $script:KitAiDropped = @($s.leases | Where-Object { $_ -and -not (Test-KitPid $_.pid $_.pidStart) })   # Update-KitLocalAi logs them
  $s.leases = @($s.leases | Where-Object { $_ -and (Test-KitPid $_.pid $_.pidStart) })
  $s.waiting = @($s.waiting | Where-Object { $_ -and (Test-KitPid $_.pid $_.pidStart) }); $s
}
function Update-KitLocalAi([string]$Name, [scriptblock]$Change) {
  $f = Get-KitLocalAiFile $Name
  $r = Invoke-KitLocked $f { $st = Get-KitLocalAiState $Name; $r = & $Change $st; Write-KitAtomic $f ($st | ConvertTo-Json -Depth 5); $r }
  foreach ($d in @($script:KitAiDropped)) { Write-KitLeaseLog release local-ai $Name $d 'holder process ended' }; $script:KitAiDropped = @(); $r
}
function Use-KitLocalAi([string]$Name, [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }), [string]$Session = '', [double]$WaitMinutes = 30) {
  $max = [math]::Max(1, [int](Get-KitSetting 'media.stt.maxConcurrent' 1))
  $me = @{ agent = $Agent; session = $Session; pid = $PID; pidStart = (Get-KitPidStart $PID); at = (Get-Date).ToString('o') }
  $end = (Get-Date).AddMinutes($WaitMinutes); $said = $false
  while ($true) {
    $got = Update-KitLocalAi $Name { param($st)
      $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $PID })
      if ($st.leases.Count -lt $max) { $st.leases += $me; return $true }
      $st.waiting += $me; $false
    }
    if ($got) { Write-KitLeaseLog acquire local-ai $Name $me; return $true }
    if (-not $said) { $h = (Get-KitLocalAiState $Name).leases | Select-Object -First 1; Write-Host "waiting for local AI: $Name busy ($($h.agent) since $(([datetime]$h.at).ToString('HH:mm')))"; $said = $true }
    if ((Get-Date) -ge $end) { $null = Update-KitLocalAi $Name { param($st) $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $PID }) }; return $false }
    Wait-KitPoll 5
  }
}
function Remove-KitLocalAi([string]$Name) {
  $gone = Update-KitLocalAi $Name { param($st) $g = @($st.leases | Where-Object { $_.pid -eq $PID }); $st.leases = @($st.leases | Where-Object { $_.pid -ne $PID }); $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $PID }); $g }
  foreach ($g in @($gone)) { Write-KitLeaseLog release local-ai $Name $g }
}

# bossy.ps1 supervise: who holds the local STT server, who waits (a wait is fine: the server is busy or RAM is short)
function Get-KitSuperviseGuardLocalAi([switch]$AutoFix) {
  $n = 'local-stt'; $f = Get-KitLocalAiFile $n; if (-not (Test-Path $f)) { return }
  $st = Get-KitLocalAiState $n
  if ($AutoFix -and @($script:KitAiDropped).Count) { $null = Update-KitLocalAi $n { } }   # writes out (and logs) the leases of ended jobs
  if (-not ($st.leases.Count + $st.waiting.Count)) { return }
  $now = Get-Date
  "${n}: $(if ($st.leases.Count) { ($st.leases | ForEach-Object { "$($_.agent) $([int]($now - [datetime]$_.at).TotalMinutes) min" }) -join ', ' } else { 'free' })$(if ($st.waiting.Count) { "; $($st.waiting.Count) waiting for local AI" })"
  $long = @($st.waiting | Where-Object { ($now - [datetime]$_.at).TotalMinutes -ge 30 })
  if ($long.Count) { [pscustomobject]@{ level = 'WATCH'; what = "waiting for local AI: $n ($(@($long.agent) -join ', ') 30+ min)"; action = 'Normal while the server or RAM is busy; the job degrades (index without transcript) at its wait limit.' } }
}

# ---- stt: the transcribe stage under the lease and the memory gate; a wait past the limit degrades (JSON on the last line)
function Invoke-KitVideoStt([string]$Key, [double]$WaitMinutes, [string]$Agent, [switch]$Refresh) {
  $vp = Join-Path $KitConf.Kit 'skills/pokey/video.py'; $ref = @(if ($Refresh) { '--refresh' })
  $ix = try { ("$((Invoke-KitExe (Get-Python) @('-X', 'utf8', $vp, 'paths', $Key) 120).out)".Trim() -split "`n" | Select-Object -Last 1 | ConvertFrom-Json).ixDir } catch { $null }
  if (-not $ix) { return @{ degraded = $true; reason = "FAILED: no index folder for $Key (video.py paths)" } }
  if (-not (Use-KitLocalAi 'local-stt' -Agent $Agent -WaitMinutes $WaitMinutes)) { return @{ degraded = $true; reason = "waiting for local AI: local-stt still busy after $WaitMinutes min" } }
  try {
    $cmd = "`"$((Get-Command (Get-Python)).Source)`" -X utf8 `"$vp`" transcribe $Key $($ref -join ' ')"
    $g = @(& (Get-Process -Id $PID).Path -NoProfile -File $KitCmd.dev gate -Dir (Split-Path (Split-Path $ix)) -Cmd $cmd -NeedGB ([double](Get-KitSetting 'media.stt.ramGB' 2)) -WaitMinutes ([math]::Max(1, [int][math]::Ceiling($WaitMinutes))) 2>&1)
    $code = $LASTEXITCODE
    $g | Where-Object { "$_" -match '^\[gate\] (waiting|could not)' } | Select-Object -Last 1 | ForEach-Object { Write-Host "media transcribe: $_" }
    if ($code -eq 3) { return @{ degraded = $true; reason = "waiting for RAM: the memory gate did not start it within $WaitMinutes min" } }
    $j = try { Get-Content (Join-Path $ix 'transcribe.json') -Raw | ConvertFrom-Json } catch { $null }
    if ($code -or -not $j) { return @{ degraded = $true; reason = "stage failed (exit $code): $(@($g | Where-Object { "$_" -notmatch '^\[gate\]' } | Select-Object -Last 1))" } }
    @{ sec = $j.stageSec; degraded = [bool]$j.degraded; reason = "$($j.reason)" }
  } finally { Remove-KitLocalAi 'local-stt' }
}

# ---- verb: pokey.ps1 evidence (raw arguments: video.py parses them)
function Invoke-Evidence {
  $a = @($args)
  if ("$($a[0])" -eq 'stt') {
    $wait = 30; $agent = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }
    for ($i = 2; $i -lt $a.Count; $i++) { switch -regex ("$($a[$i])") { '^-WaitMinutes$' { $wait = [double]$a[++$i] } '^-Agent$' { $agent = "$($a[++$i])" } } }
    if (-not $a[1]) { [Console]::Error.WriteLine('evidence stt: <key> is required'); exit 2 }
    Invoke-KitVideoStt "$($a[1])" $wait $agent -Refresh:($a -contains '-Refresh') | ConvertTo-Json -Compress; return
  }
  if ("$($a[0])" -eq 'status') { $s = Get-KitLocalAiState 'local-stt'; "local-stt: $(if ($s.leases.Count) { "held by $(@($s.leases.agent) -join ', ')" } else { 'free' }); $($s.waiting.Count) waiting" }
  $vp = Join-Path $KitConf.Kit 'skills/pokey/video.py'; Add-KitExtraUse $vp
  & (Get-Python) -X utf8 $vp @a
  exit $LASTEXITCODE
}
