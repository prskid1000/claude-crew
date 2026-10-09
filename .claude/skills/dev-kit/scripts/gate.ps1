#Requires -Version 7   # ConvertFrom-Json -AsHashtable; under Windows PowerShell 5.1 every load is null and actions run on empty ids
<#
Machine-wide memory gate for heavy builds and tests, so parallel agents (plus other Claude sessions, IDEs,
emulators and browsers) never run the machine out of RAM. Stack-agnostic: Maven, Gradle/Android, .NET,
Angular/Node/React Native, Python, Go, Rust, CMake.

  & <workspace>/.claude/skills/dev-kit/scripts/gate.ps1 -Dir <dir> -Cmd "<command>"

Usually you call check.ps1, which detects the command and runs it through this gate for you.

There is no fixed limit on parallel builds. A build starts only when
    available RAM - (memory still promised to running builds) - (this build's estimate)  >=  KeepFreeGB
- available RAM = free + reclaimable cache (Windows "Available" as Task Manager shows it, Linux MemAvailable, macOS free +
  inactive pages), read through sysinfo.ps1 so the gate runs on Windows, Linux and macOS;
- KeepFreeGB default = 15% of total RAM (min 6 GB); override with -KeepFreeGB or $env:CLAUDE_GATE_KEEP_FREE_GB;
- the estimate is LEARNED per PROJECT: each build's peak working set is recorded per command kind + repo (history.json) and the next
  estimate is the recent peak + 15%; until there are 2 samples, a built-in default per kind is used;
- "promised" = for each gated build still running, max(0, its estimate - what its process tree uses now);
- running builds are listed in a shared ledger in <OS temp folder>/claude-build-gate; dead entries are dropped;
- starts are decided one at a time, under a named mutex, from a FAIR QUEUE: the owner (agent / worktree) with the fewest
  builds started in the last 30 min goes first, then the longest-waiting; a smaller build may backfill only while the head of
  the queue doesn't fit and has waited < 20 min. Owner = $env:CLAUDE_AGENT, else the worktree prefix (x1-backend -> x1).
- heap caps follow load INTELLIGENTLY: ceiling = start value or learned peak x 1.25; floor = what this project's build really
  uses (learned peak x 1.1, min 4 GB). With N builds queued each gets an equal share of the free memory, clamped between floor
  and ceiling: plenty of room -> full headroom and builds run side by side; crowded -> heaps shrink toward real usage (never below
  it, so nothing thrashes in GC), and whatever still doesn't fit waits its fair turn.
- while waiting it prints its queue position and, now and then, the biggest memory users.
Exit code = the command's exit code, or 3 if it could not start within -WaitMinutes.
A build killed by someone else is not a code failure: just run it again.
#>
param(
  [Parameter(Mandatory)][string]$Cmd,
  [string]$Dir = (Get-Location).Path,
  [int]$WaitMinutes = 90,
  [double]$KeepFreeGB = $(if ($env:CLAUDE_GATE_KEEP_FREE_GB) { [double]$env:CLAUDE_GATE_KEEP_FREE_GB } else { -1 }),   # -1 = 15% of total RAM, min 6 GB
  [double]$NeedGB = 0,         # 0 = learned / default estimate for this kind of command
  [int]$MaxParallel = 0        # 0 = no fixed cap (memory decides)
)
# Heap caps for JVM (Maven) and Node builds are DYNAMIC and always override inherited flags (a user-level
# MAVEN_OPTS=-Xmx16g once made one gated `mvn test` take 6 GB):
#   new project (no history for this kind + repo): start Gradle 12 GB, Maven 8 GB, Node 4 GB;
#   after 2 recorded runs: learned peak x 1.25, never above the start value, never below 4 GB;
#   at start time, if memory is tight the heap is REDUCED toward 4 GB instead of waiting longer.
$HeapMinGB = 4
. (Join-Path $PSScriptRoot 'sysinfo.ps1')
if ($KeepFreeGB -lt 0) { $KeepFreeGB = [math]::Max(6, [math]::Round((Get-SysMem).TotalGB * 0.15)) }
$StartGB = @{ gradle = 12; maven = 8; node = 4 }
$mavenKeep = ([string]$env:MAVEN_OPTS -replace '-Xm[xs]\S+|-XX:\+Use\w+GC|-XX:MaxMetaspaceSize=\S+', '' -replace '\s+', ' ').Trim()
$nodeKeep = ([string]$env:NODE_OPTIONS -replace '--max-old-space-size=\d+', '' -replace '\s+', ' ').Trim()
if (-not $env:GRADLE_OPTS) { $env:GRADLE_OPTS = '-Dorg.gradle.workers.max=4' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

# kind of command -> default GB (used until the gate has learned real peaks for that kind)
$Kinds = [ordered]@{
  'emulator'      = @('^exit 0 #emulator', 4.5)
  'android-build' = @('gradlew.*\b(assemble|bundle)', 7)
  'android-test'  = @('gradlew.*\btest|connectedAndroidTest|lintDebug', 6)
  'gradle'        = @('gradle(w|w\.bat)?\b', 3.5)
  'rn-bundle'     = @('export:embed|react-native bundle|expo export', 3)
  'e2e'           = @('cypress|playwright', 3.5)
  'ng-test'       = @('ng test|karma', 3)
  'web-build'     = @('ng build|next build|vite build|webpack|npm run build', 4)
  'maven-test'    = @('\b(mvn|mvnd|mvnw(\.cmd)?)\b.*\b(test|verify|package|install)\b', 3)
  'maven'         = @('\b(mvn|mvnd|mvnw(\.cmd)?)\b', 2.5)
  'dotnet'        = @('msbuild|dotnet (build|test|publish)', 3)
  'rust'          = @('cargo (build|test|clippy|check)', 4)
  'native'        = @('cmake --build|\bmake\b', 3)
  'js-test'       = @('jest|vitest', 2)
  'tsc-lint'      = @('\btsc\b|eslint', 2)
  'python'        = @('pytest|mypy|ruff|compileall', 1.5)
  'go'            = @('go (build|test|vet)', 2)
}
function Get-Kind([string]$c) { foreach ($k in $Kinds.Keys) { if ($c -match $Kinds[$k][0]) { return $k } }; 'other' }

# Repo-local wrappers must be called as .\gradlew.bat / .\mvnw.cmd: Claude Code sets NoDefaultCurrentDirectoryInExePath=1,
# so cmd.exe no longer finds programs in the current directory by bare name (sh never does: ./gradlew there).
$Cmd = [regex]::Replace($Cmd, '(^|&&\s*|&\s*|\|\|\s*)(?<!\.[\\/])(gradlew(\.bat)?|mvnw(\.cmd)?)(?=\s|$)', $(if ($KitIsWindows) { '$1.\$2' } else { '$1./$2' }))
# Test runners fork one worker per core by default; cap them.
if ($Cmd -match '\bjest\b' -and $Cmd -notmatch 'maxWorkers|runInBand|\s-i(\s|$)') { $Cmd = "$Cmd --maxWorkers=2" }
if ($Cmd -match '\bvitest\b' -and $Cmd -notmatch 'maxWorkers|maxThreads') { $Cmd = "$Cmd --maxWorkers=2" }
if ($Cmd -match '\bpytest\b' -and $Cmd -match '\s-n\s+auto') { $Cmd = $Cmd -replace '\s-n\s+auto', ' -n 2' }

$ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
New-Item -ItemType Directory -Force $ledger | Out-Null
$histFile = Join-Path $ledger 'history.json'
function Read-History { try { Get-Content $histFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { @{} } }

$kind = Get-Kind $Cmd
$default = if ($Kinds.Contains($kind)) { $Kinds[$kind][1] } else { 2 }
# Project = main repo name + the subproject folder inside it (repos can hold several modules, e.g. backend/services/api).
# Worktrees resolve to their main checkout (first entry of `git worktree list`), so x1-backend learns into backend.
$project = Split-Path ([IO.Path]::GetFullPath($Dir)) -Leaf
$top = (git -C $Dir rev-parse --show-toplevel 2>$null)
if ($top) {
  $main = ((git -C $Dir worktree list --porcelain 2>$null | Select-Object -First 1) -replace '^worktree\s+', '')
  $repoName = if ($main) { Split-Path $main -Leaf } else { Split-Path $top -Leaf }
  $rel = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($top), [IO.Path]::GetFullPath($Dir)).Replace([char]92, [char]47)
  $project = if ($rel -eq '.') { $repoName } else { "$repoName/$rel" }
}

$histKey = "$kind|$project"
$hist = Read-History
$samples = @($hist[$histKey] | Where-Object { $_ })        # [{gb, sec, ok}, ...] newest last
$peaks = @($samples | ForEach-Object { [double]$_.gb })
$secs = @($samples | ForEach-Object { [double]$_.sec } | Sort-Object)
$need = if ($NeedGB -gt 0) { $NeedGB }
        elseif ($peaks.Count -ge 2) { [math]::Round([math]::Min($default * 1.5, [math]::Max(0.75, (($peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum) * 1.15)), 1) }
        else { $default }

# Dynamic heap for JVM / Node build kinds (see top of file)
$jvmKind = $kind -like 'maven*'
$nodeKind = $kind -in @('ng-test', 'web-build', 'js-test', 'tsc-lint', 'rn-bundle', 'e2e')
$gradleKind = $kind -in @('android-build', 'android-test', 'gradle')
$heap = 0
if ($jvmKind -or $nodeKind -or $gradleKind) {
  # Gradle (Android: Gradle + Kotlin + Hermes) starts high and learns down; Maven/Node start at the floor.
  # JVMs run G1 with tight free-ratios + periodic GC, so the heap tracks LIVE data and the recorded peak can fall
  # (without that a JVM fills whatever -Xmx it gets and the learned estimate never drops).
  $startGB = if ($gradleKind) { $StartGB.gradle } elseif ($jvmKind) { $StartGB.maven } else { $StartGB.node }
  $maxGB = [math]::Max($startGB, 8)
  $heap = if ($peaks.Count -ge 2) { [int][math]::Ceiling((($peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum) * 1.25) } else { $startGB }
  $heap = [math]::Min($maxGB, [math]::Max($HeapMinGB, $heap))
  if ($NeedGB -le 0 -and $peaks.Count -lt 2) { $need = [math]::Max($need, $heap + 0.5) }   # no history yet: assume the heap can fill up
}
function Set-HeapEnv([int]$gb) {
  if ($jvmKind) { $env:MAVEN_OPTS = "$mavenKeep -Xmx${gb}g -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000".Trim() }   # G1 returns unused heap to the OS
  if ($nodeKind) { $env:NODE_OPTIONS = "$nodeKeep --max-old-space-size=$($gb * 1024)".Trim() }
  if ($gradleKind -and $script:Cmd -notmatch 'org\.gradle\.jvmargs') {
    # Gradle daemon heap comes from org.gradle.jvmargs (gradle.properties); a -D on the command line overrides it
    $script:Cmd = ([regex]'(gradlew(\.bat)?|\bgradle)(?=\s|$)').Replace($script:Cmd, "`$1 `"-Dorg.gradle.jvmargs=-Xmx${gb}g -XX:MaxMetaspaceSize=1g -XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000 -Dfile.encoding=UTF-8`"", 1)
  }
}

# Owner for fair turns: explicit agent id, else the worktree/folder prefix (x1-backend -> x1)
$ownerRoot = if ($top) { Split-Path $top -Leaf } else { Split-Path ([IO.Path]::GetFullPath($Dir)) -Leaf }
$owner = if ($env:CLAUDE_AGENT) { $env:CLAUDE_AGENT } else { ($ownerRoot -split '-')[0] }
$heapBase = $heap
# never shrink below what this project's build has really used (a smaller heap only makes it thrash in GC)
$heapFloor = if ($heap -gt 0 -and $peaks.Count -ge 2) { [math]::Min($heapBase, [math]::Max($HeapMinGB, [int][math]::Ceiling((($peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum) * 1.1))) } else { $HeapMinGB }
$queueDir = Join-Path $ledger 'queue'; New-Item -ItemType Directory -Force $queueDir | Out-Null
$startsFile = Join-Path $ledger 'starts.jsonl'
$myTicket = Join-Path $queueDir "$PID.json"
$since = (Get-Date).ToString('o')
function Write-Ticket { @{ pid = $PID; owner = $owner; kind = $kind; need = $need; since = $since; dir = $Dir } | ConvertTo-Json -Compress | Set-Content $myTicket }
function Get-Queue {
  $q = foreach ($f in Get-ChildItem $queueDir -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { $t = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not (Get-Process -Id $t.pid -ErrorAction SilentlyContinue)) { Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue }
    $t
  }
  $cut = (Get-Date).AddMinutes(-30); $recent = @{}
  foreach ($l in Get-Content $startsFile -Tail 300 -ErrorAction SilentlyContinue) { try { $x = $l | ConvertFrom-Json; if ([datetime]$x.at -gt $cut) { $recent[$x.owner] = 1 + [int]$recent[$x.owner] } } catch {} }
  @($q | Sort-Object @{ e = { [int]$recent[$_.owner] } }, @{ e = { [datetime]$_.since } })
}

function Get-Procs {
  $procs = @{}; $kids = @{}; $names = @{}
  foreach ($p in Get-SysProcs -NoCommandLine) {
    $procs[$p.Id] = $p.WorkingSet; $names[$p.Id] = $p.Name
    $pp = $p.ParentId
    if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
    [void]$kids[$pp].Add($p.Id)
  }
  @{ procs = $procs; kids = $kids; names = $names }
}
function Get-TreeGB([int]$rootPid, $Snap) {
  $sum = 0; $stack = New-Object System.Collections.Stack; $stack.Push($rootPid)
  while ($stack.Count) {
    $node = $stack.Pop()
    if ($Snap.procs.ContainsKey($node)) { $sum += $Snap.procs[$node] }
    if ($Snap.kids.ContainsKey($node)) { foreach ($k in $Snap.kids[$node]) { $stack.Push($k) } }
  }
  return $sum / 1GB
}
function Get-AvailGB { (Get-SysMem).AvailGB }
function Get-State {
  $Snap = Get-Procs
  $promised = 0; $running = 0
  foreach ($f in Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json') {
    try { $e = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not $Snap.procs.ContainsKey([int]$e.pid)) { Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue }
    $running++
    $promised += [math]::Max(0, [double]$e.need - (Get-TreeGB ([int]$e.pid) $Snap))
  }
  [pscustomobject]@{ Avail = (Get-AvailGB); Promised = [math]::Round($promised, 1); Running = $running; Snap = $Snap }
}
function Top-Users($Snap) {
  ($Snap.names.GetEnumerator() | Group-Object Value | ForEach-Object { [pscustomobject]@{ n = $_.Name; gb = (($_.Group | ForEach-Object { $Snap.procs[$_.Key] }) | Measure-Object -Sum).Sum / 1GB } } |
    Sort-Object gb -Descending | Select-Object -First 5 | ForEach-Object { '{0} {1:N1} GB' -f $_.n, $_.gb }) -join ', '
}

$gate = New-Object System.Threading.Mutex($false, 'Global\claude-build-gate')
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$learned = if ($NeedGB -le 0 -and $peaks.Count -ge 2) { " (learned from $($peaks.Count) runs)" } else { '' }
$usual = if ($secs.Count -ge 2) { " usually ~$([math]::Ceiling($secs[[int][math]::Floor($secs.Count / 2)] / 60)) min," } else { '' }
Write-Host "[gate] $kind needs ~$need GB$learned,$usual keep $KeepFreeGB GB free: $Cmd"
$proc = $null; $entry = $null; $waits = 0
Write-Ticket
try {
while ((Get-Date) -lt $deadline) {
  $got = $false
  try { $got = $gate.WaitOne([TimeSpan]::FromSeconds(60)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { continue }
  try {
    $s = Get-State
    $queue = Get-Queue
    # Load-aware heap: equal share of free memory per queued build, clamped to [real-usage floor, headroom ceiling]
    if ($heapBase -gt 0 -and $NeedGB -le 0 -and $queue.Count -ge 2) {
      $share = [math]::Floor(($s.Avail - $s.Promised - $KeepFreeGB) / $queue.Count - 0.5)
      $h2 = [math]::Min($heapBase, [math]::Max($heapFloor, $share))
      if ($h2 -ne $heap) {
        Write-Host "[gate] $($queue.Count) builds queued, ~$share GB each: heap $heap GB -> $h2 GB (floor $heapFloor = real usage, ceiling $heapBase)"
        if ($peaks.Count -lt 2) { $need = $h2 + 0.5 }; $heap = $h2; Write-Ticket
      }
    }
    $left = $s.Avail - $s.Promised - $need
    # Fair turns: only the head of the queue may start; others may backfill only while the head doesn't fit (and isn't starving)
    $pos = [array]::IndexOf(@($queue | ForEach-Object { [int]$_.pid }), [int]$PID)
    $head = if ($queue.Count) { $queue[0] } else { $null }
    $myTurn = ($pos -le 0)
    if (-not $myTurn -and $head) {
      $room = $s.Avail - $s.Promised - $KeepFreeGB
      $headWaited = ((Get-Date) - [datetime]$head.since).TotalMinutes
      if ([double]$head.need -gt $room -and $need -le $room -and $headWaited -lt 20) { $myTurn = $true; Write-Host "[gate] backfilling ahead of $($head.owner) (its $($head.need) GB doesn't fit yet)" }
    }
    if (-not $myTurn) {
      $waits++
      if ($waits % 3 -eq 1) { Write-Host "[gate] queued #$($pos + 1) of $($queue.Count) (owner $owner); next: $($head.owner) $($head.kind)" }
    }
    else {
    # Tight memory: shrink the heap toward the real-usage floor instead of waiting (never below it)
    if ($heap -gt 0 -and $left -lt $KeepFreeGB -and $NeedGB -le 0) {
      $room = [math]::Floor($s.Avail - $s.Promised - $KeepFreeGB - 0.5)
      if ($room -ge $heapFloor -and $room -lt $heap) {
        Write-Host "[gate] memory tight: heap $heap GB -> $room GB"
        $need = [math]::Max($heapFloor + 0.5, [math]::Min($need, $room + 0.5)); $heap = $room
        $left = $s.Avail - $s.Promised - $need
      }
    }
    if ($left -ge $KeepFreeGB -and (($MaxParallel -le 0) -or ($s.Running -lt $MaxParallel))) {
      if ($heap -gt 0) { Set-HeapEnv $heap }
      Write-Host "[gate] starting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> ~$([math]::Round($left,1)) GB left$(if ($heap -gt 0) { "; heap cap $heap GB" })"
      if ($KitIsWindows) { $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $Cmd -WorkingDirectory $Dir -NoNewWindow -PassThru }
      else {
        $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($Cmd)
        $psi.WorkingDirectory = $Dir; $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi)
      }
      Remove-Item $myTicket -ErrorAction SilentlyContinue
      @{ owner = $owner; kind = $kind; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Add-Content $startsFile
      $entry = Join-Path $ledger "$($proc.Id).json"
      @{ pid = $proc.Id; need = $need; kind = $kind; cmd = $Cmd; dir = $Dir; started = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $entry
      break
    }
    $waits++
    $msg = "[gate] waiting: $($s.Avail) GB available, $($s.Promised) GB promised to $($s.Running) running -> would leave $([math]::Round($left,1)) GB (< $KeepFreeGB)"
    if ($waits % 15 -eq 1) { $msg += ". Biggest users: $(Top-Users $s.Snap)" }
    Write-Host $msg
    }
  } finally { $gate.ReleaseMutex() }
  Start-Sleep -Seconds 20
}
} finally { Remove-Item $myTicket -ErrorAction SilentlyContinue }
if (-not $proc) { Write-Host "[gate] could not start within $WaitMinutes min"; exit 3 }
# Wait, sampling the process tree's peak memory so the next estimate for this kind is realistic.
$sw = [Diagnostics.Stopwatch]::StartNew(); $peak = 0.0   # double: [math]::Max(int, double) would pick the int overload and truncate
try {
  $null = $proc.Handle   # keep a handle so ExitCode is available after exit
  while (-not $proc.HasExited) { $peak = [math]::Max($peak, (Get-TreeGB $proc.Id (Get-Procs))); Start-Sleep -Seconds 5 }
  $proc.WaitForExit(); $code = $proc.ExitCode
} finally { Remove-Item $entry -ErrorAction SilentlyContinue }
if ($peak -gt 0.2 -and $kind -ne 'emulator') {
  try {
    $h = Read-History
    $h[$histKey] = @(@($h[$histKey] | Where-Object { $_ }) + @{ gb = [math]::Round($peak, 2); sec = [int]$sw.Elapsed.TotalSeconds; ok = ($code -eq 0) } | Select-Object -Last 10)
    $h | ConvertTo-Json -Depth 3 | Set-Content $histFile
  } catch {}
}
exit $code
