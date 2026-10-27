<#
evidence.ps1 (goody media-evidence): `pokey.ps1 evidence` - tester evidence links -> a time-indexed text index, frames on demand.
  & <kit>/skills/pokey/pokey.ps1 evidence fetch <link> [-Refresh]
  & <kit>/skills/pokey/pokey.ps1 evidence index <link> [-Refresh] [-WaitMinutes 30] [-LockMinutes 90] [-NoTranscript] [-NoVision]
  & <kit>/skills/pokey/pokey.ps1 evidence read-chunk <key> [<start> <end>] [-At <m:ss> -Window <s>] [-AroundError] [-Frames 3]
      [-Size 1280] [-Item <task>]   (frames as JPEGs for the Read tool: crafty.ps1 dir -Kind evidence -Item <task>, else the cache)
  & <kit>/skills/pokey/pokey.ps1 evidence status [<key or link>]
Inputs: kit.local.json `media` (GOODY.md), media_evidence.py (stages), adapters/local_ai.ps1 (leases). Outputs: text; files in
<runtime>/cache/media/<key>/. One lock per video key: a second agent on the same video waits, then reads the same cache.
STT / vision stages: lease `local-stt` / `local-vision` (one job each), then the memory gate reserves media.<stt|vision>.ramGB.
Exit codes: 0 ok · 1 problem (unreadable link: ask the tester for the file; no index) · 2 usage.
Sections: L15 helpers · L51 verb
#>
#Requires -Version 7
# ---- helpers: the python stages, the per-video lock, AI stages under lease + gate
function Invoke-KitMediaPy([string[]]$A, [int]$TimeoutSec = 3600) {
  Invoke-KitExe (Get-Python) (@('-X', 'utf8', (Join-Path $KitConf.Kit 'skills/pokey/media_evidence.py')) + $A) $TimeoutSec
}
function ConvertFrom-KitMediaJson($r) { try { "$($r.out)".Trim() -split "`n" | Select-Object -Last 1 | ConvertFrom-Json } catch { $null } }
# a FileShare.None handle on <key>.lock: the OS frees it when its holder dies; another agent waits for it (one processing per video)
function Lock-KitMediaKey([string]$KeyDir, [double]$WaitMinutes) {
  $lock = "$KeyDir.lock"; New-Item -ItemType Directory -Force (Split-Path $lock) | Out-Null
  $end = (Get-Date).AddMinutes($WaitMinutes); $said = $false
  while ($true) {
    try { return [IO.File]::Open($lock, 'OpenOrCreate', 'ReadWrite', 'None') } catch {}
    if (-not $said) { Write-Host "media: another agent is processing this video ($(Split-Path $KeyDir -Leaf)); waiting, then reusing its index"; $said = $true }
    if ((Get-Date) -ge $end) { return $null }
    Wait-KitPoll 3
  }
}
# a stage that calls a local AI server: lease (one job per server) -> memory gate (its RAM) -> the stage; a wait past the limit degrades
function Invoke-KitMediaAiStage([string]$Key, [string]$Stage, [string]$IxDir, [double]$WaitMinutes, [string]$Agent, [string[]]$Ref = @()) {
  $need = ConvertFrom-KitMediaJson (Invoke-KitMediaPy (@('needs', $Key, $Stage) + $Ref) 300)
  if (-not $need) { return [pscustomobject]@{ stage = $Stage; degraded = $true; reason = 'FAILED: the needs check crashed (media_evidence.py needs)' } }   # never a stage without its lease
  if (-not $need.need) { return ConvertFrom-KitMediaJson (Invoke-KitMediaPy (@($Stage, $Key) + $Ref)) }
  $lease = if ($Stage -eq 'transcribe') { 'local-stt' } else { 'local-vision' }
  if (-not (Use-KitLocalAi $lease -Agent $Agent -WaitMinutes $WaitMinutes)) { return [pscustomobject]@{ stage = $Stage; degraded = $true; reason = "waiting for local AI: $lease still busy after $WaitMinutes min" } }
  try {
    $ram = [double](Get-KitSetting "media.$(if ($Stage -eq 'transcribe') { 'stt' } else { 'vision' }).ramGB" 2)
    $cmd = "`"$((Get-Command (Get-Python)).Source)`" -X utf8 `"$(Join-Path $KitConf.Kit 'skills/pokey/media_evidence.py')`" $Stage $Key $($Ref -join ' ')"
    $g = @(& (Get-Process -Id $PID).Path -NoProfile -File $KitCmd.dev gate -Dir (Split-Path (Split-Path $IxDir)) -Cmd $cmd -NeedGB $ram -WaitMinutes ([int][math]::Ceiling($WaitMinutes)) 2>&1)
    $code = $LASTEXITCODE
    $g | Where-Object { "$_" -match '^\[gate\] (waiting|could not)' } | Select-Object -Last 1 | ForEach-Object { Write-Host "media $Stage`: $_" }
    if ($code -eq 3) { return [pscustomobject]@{ stage = $Stage; degraded = $true; reason = "waiting for RAM: the memory gate did not start it within $WaitMinutes min" } }
    $j = try { Get-Content (Join-Path $IxDir "$Stage.json") -Raw | ConvertFrom-Json } catch { $null }
    if ($code -or -not $j) { return [pscustomobject]@{ stage = $Stage; degraded = $true; reason = "stage failed (exit $code): $(@($g | Where-Object { "$_" -notmatch '^\[gate\]' } | Select-Object -Last 1))" } }
    [pscustomobject]@{ stage = $Stage; sec = $j.stageSec; degraded = [bool]$j.degraded; reason = "$($j.reason)" }
  } finally { Remove-KitLocalAi $lease }
}

# ---- verb: pokey.ps1 evidence
function Invoke-Evidence {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('fetch', 'index', 'read-chunk', 'status')][string]$Action,
  [Parameter(Position = 1)][string]$Link, [Parameter(Position = 2)][string]$Start, [Parameter(Position = 3)][string]$End,
  [string]$At, [double]$Window = 20, [switch]$AroundError, [int]$Frames = 3, [int]$Size = 1280, [string]$Item, [string]$Agent,
  [double]$WaitMinutes = 30, [double]$LockMinutes = 90, [switch]$Refresh, [switch]$NoTranscript, [switch]$NoVision, [switch]$Json
)
$ErrorActionPreference = 'Stop'
if (-not $Agent) { $Agent = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { 'main' } }
Add-KitExtraUse (Join-Path $KitConf.Kit 'skills/pokey/media_evidence.py')
$ref = @(if ($Refresh) { '--refresh' })
switch ($Action) {
  'fetch' {
    if (-not $Link) { [Console]::Error.WriteLine('evidence fetch: <link> is required'); exit 2 }
    $sel = ConvertFrom-KitMediaJson (Invoke-KitMediaPy @('select', $Link) 60)
    $fs = if ($sel) { Lock-KitMediaKey (ConvertFrom-KitMediaJson (Invoke-KitMediaPy @('paths', $sel.key) 60)).keyDir $LockMinutes }   # never refetch under a running index
    if (-not $fs) { [Console]::Error.WriteLine("evidence fetch: $($sel.key) is being processed by another agent (or select failed); run it again later"); exit 1 }
    try { $r = Invoke-KitMediaPy (@('fetch', $Link) + $ref); $f = ConvertFrom-KitMediaJson $r } finally { $fs.Dispose() }
    if (-not $f) { [Console]::Error.WriteLine("evidence fetch: failed: $($r.err)"); exit 1 }
    if ($f.kind -eq 'unreadable') { "unreadable: $($f.reason)$(if ($f.reason -notmatch 'ask the tester') { ', ask the tester for the file' })"; exit 1 }
    if ($Json) { $f | ConvertTo-Json -Depth 5; return }
    "fetched $($f.key) via $($f.fetcher): $($f.kind) $([math]::Round($f.bytes / 1MB, 1)) MB$(if ($f.cached) { ' (cached)' } else { " in $($f.fetchSec) s" })$(if (@($f.sidecars.PSObject.Properties).Count) { "; sidecars: $(@($f.sidecars.PSObject.Properties.Name) -join ', ')" })"
  }
  'index' {
    if (-not $Link) { [Console]::Error.WriteLine('evidence index: <link> is required'); exit 2 }
    $sel = ConvertFrom-KitMediaJson (Invoke-KitMediaPy @('select', $Link) 60)
    if (-not $sel) { [Console]::Error.WriteLine('evidence index: media_evidence.py select failed'); exit 1 }
    $kd = (ConvertFrom-KitMediaJson (Invoke-KitMediaPy @('paths', $sel.key) 60)).keyDir
    $fs = Lock-KitMediaKey $kd $LockMinutes
    if (-not $fs) { [Console]::Error.WriteLine("evidence index: $($sel.key) is still being processed by another agent; run it again later"); exit 1 }
    try {
      $t0 = Get-Date; $r = Invoke-KitMediaPy (@('fetch', $Link) + $ref); $f = ConvertFrom-KitMediaJson $r
      if (-not $f) { [Console]::Error.WriteLine("evidence index: fetch failed: $($r.err)"); exit 1 }
      if ($f.kind -eq 'unreadable') { "unreadable: $($f.reason)$(if ($f.reason -notmatch 'ask the tester') { ', ask the tester for the file' })"; exit 1 }
      $times = [ordered]@{ fetch = $(if ($f.cached) { 'cached' } else { "$($f.fetchSec) s" }) }; $notes = @()
      foreach ($st in 'detect', 'transcribe', 'vision') {
        if (($st -eq 'transcribe' -and $NoTranscript) -or ($st -eq 'vision' -and $NoVision)) { $times[$st] = 'skipped'; continue }
        $s0 = Get-Date
        $res = if ($st -eq 'detect') { ConvertFrom-KitMediaJson (Invoke-KitMediaPy (@($st, $f.key) + $ref)) } else { Invoke-KitMediaAiStage $f.key $st $f.ixDir $WaitMinutes $Agent $ref }
        if (-not $res) { $notes += "FAILED $st`: the stage crashed (run media_evidence.py $st $($f.key)): its part of the index is missing, not empty"; $times[$st] = 'failed'; continue }
        $times[$st] = "$([math]::Round(((Get-Date) - $s0).TotalSeconds, 1)) s$(if ($res.cached) { ' (cached)' })"
        if ($res.reason) { $notes += "$(if ($res.degraded) { 'degraded' } else { 'note' }) $st`: $($res.reason)" }
      }
      $b = ConvertFrom-KitMediaJson (Invoke-KitMediaPy @('build', $f.key) 300)
      if (-not $b) { [Console]::Error.WriteLine('evidence index: build failed'); exit 1 }
      Write-KitLog calls media-index @{ key = $f.key; fetcher = $f.fetcher; tokens = $b.tokens; sec = [int]((Get-Date) - $t0).TotalSeconds }
      if ($Json) { [pscustomobject]@{ key = $f.key; fetcher = $f.fetcher; index = $b.index; tokens = $b.tokens; chunks = $b.chunks; times = $times; notes = $notes } | ConvertTo-Json -Depth 4; return }
      "index $($f.key) ($($f.fetcher)): $($b.chunks) chunks, ~$($b.tokens) tokens, $($b.index) · $(($times.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ')"
      $notes
      ''
      Get-Content $b.index -Raw
    } finally { $fs.Dispose() }
  }
  'read-chunk' {
    if (-not $Link) { [Console]::Error.WriteLine('evidence read-chunk: <key> is required (index prints it)'); exit 2 }
    $key = if ($Link -match '^[0-9a-f]{16}$') { $Link } else { (ConvertFrom-KitMediaJson (Invoke-KitMediaPy @('select', $Link) 60)).key }
    $out = if ($Item) { "$(& $KitCmd.dev dir -Kind evidence -Item $Item -Agent $Agent)".Trim() } else { '' }
    $a = @('read', $key) + @(if ($Start) { $Start }) + @(if ($End) { $End }) + @('--window', "$Window", '--frames', "$Frames", '--size', "$Size") +
      @(if ($At) { '--at', $At }) + @(if ($AroundError) { '--around-error' }) + @(if ($out) { '--out', $out })
    $r = Invoke-KitMediaPy $a 600
    if ($r.code) { [Console]::Error.WriteLine("evidence read-chunk: $("$($r.err)".Trim())"); exit 1 }
    $r.out
  }
  'status' {
    foreach ($n in 'local-stt', 'local-vision') { $s = Get-KitLocalAiState $n; "${n}: $(if ($s.leases.Count) { "held by $(@($s.leases.agent) -join ', ')" } else { 'free' }); $($s.waiting.Count) waiting" }
    if ($Link) { (Invoke-KitMediaPy @('paths', $Link) 60).out }
  }
}
}
