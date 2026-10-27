<#
local_ai.ps1 (goody media-evidence): job leases on the local AI servers (`local-stt`, `local-vision`: README "Leases"), so one
job at a time per server reserves its RAM through the memory gate and never starves builds or local envs.
  Use-KitLocalAi -Name local-stt|local-vision [-Agent] [-Session] [-WaitMinutes 30]   -> $true held · $false timed out (waiting)
  Remove-KitLocalAi -Name <n>                                                        -> drops this process's lease
  Get-KitLocalAiState -Name <n>                                                      -> { leases, waiting } (dead pids pruned)
Inputs: kit.local.json media.stt / media.vision: maxConcurrent (1), ramGB (the gate reservation), baseUrl. State:
<runtime>/cache/media/_leases/<name>.json. A lease belongs to the job process (pid + start time): a killed job frees it at once.
Dot-sourced by lib.ps1 (adapters/*.ps1); bossy.ps1 supervise gets Get-KitSuperviseGuardLocalAi ("waiting for local AI").
Exit codes: none (functions).
#>
#Requires -Version 7
function Get-KitLocalAiConf([string]$Name) { Get-KitSetting "media.$(if ($Name -eq 'local-stt') { 'stt' } else { 'vision' })" $null }
function Get-KitLocalAiFile([string]$Name) {
  $root = try { Get-KitPath media -Create } catch { Join-Path (Get-KitPath cache -Create) 'media' }   # an older core without _paths.media
  $d = Join-Path $root '_leases'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }; Join-Path $d "$Name.json"
}
function Get-KitLocalAiState([string]$Name) {
  $s = try { Get-Content (Get-KitLocalAiFile $Name) -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }
  if ($s -isnot [hashtable]) { $s = @{} }
  $s.leases = @($s.leases | Where-Object { $_ -and (Test-KitPid $_.pid $_.pidStart) })
  $s.waiting = @($s.waiting | Where-Object { $_ -and (Test-KitPid $_.pid $_.pidStart) }); $s
}
function Update-KitLocalAi([string]$Name, [scriptblock]$Change) {
  $f = Get-KitLocalAiFile $Name
  Invoke-KitLocked $f { $st = Get-KitLocalAiState $Name; $r = & $Change $st; Write-KitAtomic $f ($st | ConvertTo-Json -Depth 5); $r }
}
function Use-KitLocalAi([string]$Name, [string]$Agent = $(if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' }), [string]$Session = '', [double]$WaitMinutes = 30) {
  $max = [math]::Max(1, [int](Get-KitSetting "media.$(if ($Name -eq 'local-stt') { 'stt' } else { 'vision' }).maxConcurrent" 1))
  $me = @{ agent = $Agent; session = $Session; pid = $PID; pidStart = (Get-KitPidStart $PID); at = (Get-Date).ToString('o') }
  $end = (Get-Date).AddMinutes($WaitMinutes); $said = $false
  while ($true) {
    $got = Update-KitLocalAi $Name { param($st)
      $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $PID })
      if ($st.leases.Count -lt $max) { $st.leases += $me; return $true }
      $st.waiting += $me; $false
    }
    if ($got) { return $true }
    if (-not $said) { $h = (Get-KitLocalAiState $Name).leases | Select-Object -First 1; Write-Host "waiting for local AI: $Name busy ($($h.agent) since $(([datetime]$h.at).ToString('HH:mm')))"; $said = $true }
    if ((Get-Date) -ge $end) { $null = Update-KitLocalAi $Name { param($st) $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $PID }) }; return $false }
    Wait-KitPoll 5
  }
}
function Remove-KitLocalAi([string]$Name) { $null = Update-KitLocalAi $Name { param($st) $st.leases = @($st.leases | Where-Object { $_.pid -ne $PID }); $st.waiting = @($st.waiting | Where-Object { $_.pid -ne $PID }) } }

# bossy.ps1 supervise: who holds the local AI servers, who waits (a wait is fine: the server is busy or RAM is short)
function Get-KitSuperviseGuardLocalAi([switch]$AutoFix) {
  foreach ($n in 'local-stt', 'local-vision') {
    $f = Get-KitLocalAiFile $n; if (-not (Test-Path $f)) { continue }
    $st = Get-KitLocalAiState $n; if (-not ($st.leases.Count + $st.waiting.Count)) { continue }
    $now = Get-Date
    "${n}: $(if ($st.leases.Count) { ($st.leases | ForEach-Object { "$($_.agent) $([int]($now - [datetime]$_.at).TotalMinutes) min" }) -join ', ' } else { 'free' })$(if ($st.waiting.Count) { "; $($st.waiting.Count) waiting for local AI" })"
    $long = @($st.waiting | Where-Object { ($now - [datetime]$_.at).TotalMinutes -ge 30 })
    if ($long.Count) { [pscustomobject]@{ level = 'WATCH'; what = "waiting for local AI: $n ($(@($long.agent) -join ', ') 30+ min)"; action = 'Normal while the server or RAM is busy; the job degrades (index without transcript / screen text) at its wait limit.' } }
  }
}
