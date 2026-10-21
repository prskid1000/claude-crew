# posix (extra): lib.ps1's OS helpers on Linux and macOS (memory, processes, directory links, python, detached starts);
# dot-sourced from skills/dev-kit/adapters/ after the Windows versions, which these replace when the OS is not Windows.
if ($KitIsWindows) { return }
function Get-SysMem {
  $kv = { param($lines, $re) $h = @{}; foreach ($l in $lines) { if ($l -match $re) { $h[$Matches[1]] = [double]$Matches[2] } }; $h }
  if ($KitIsWindows) {
    $total = (Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1GB
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -Property AvailableMBytes, CacheBytes
    $cache = $pm.CacheBytes / 1GB   # system file cache: resident, trimmed only under pressure
    $avail = $pm.AvailableMBytes / 1KB   # Available = free + standby (the cache is not "used")
    $free = (Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory / 1MB
  }
  elseif ($KitIsMac) {
    $total = [double](sysctl -n hw.memsize) / 1GB
    $vm = vm_stat
    $page = if (($vm | Select-Object -First 1) -match 'page size of (\d+)') { [double]$Matches[1] } else { 4096 }
    $n = & $kv $vm '^(Pages [^:]+):\s+(\d+)'
    $free = ($n['Pages free'] + $n['Pages speculative']) * $page / 1GB
    $avail = $free + ($n['Pages inactive'] + $n['Pages purgeable']) * $page / 1GB
  }
  else {
    $m = & $kv (Get-Content /proc/meminfo) '^(\w+):\s+(\d+)'
    $total = $m['MemTotal'] / 1MB
    $free = $m['MemFree'] / 1MB
    $avail = $(if ($m.ContainsKey('MemAvailable')) { $m['MemAvailable'] } else { $m['MemFree'] + $m['Cached'] + $m['Buffers'] }) / 1MB
  }
  [pscustomobject]@{ TotalGB = [math]::Round($total, 1); AvailGB = [math]::Round($avail, 1); FreeGB = [math]::Round($free, 1); CacheGB = [math]::Round([double]$cache, 1) }
}
function Get-FreeGB { $m = Get-SysMem; if ($KitIsWindows) { $m.FreeGB } else { $m.AvailGB } }
function ConvertFrom-PsElapsed([string]$e) {
  if ($e -notmatch '^(\d+-)?(\d+:){1,2}\d+$') { return $null }
  $d = 0; if ($e -match '^(\d+)-(.*)$') { $d = [int]$Matches[1]; $e = $Matches[2] }
  $s = 0; foreach ($x in $e -split ':') { $s = $s * 60 + [int]$x }
  (Get-Date).AddSeconds(-($s + 86400 * $d))
}
function Get-SysProcs([string]$Name, [switch]$NoCommandLine) {   # -NoCommandLine: faster on Windows, no CommandLine/Created
  $all = if ($KitIsWindows) {
    $props = if ($NoCommandLine) { 'ProcessId', 'ParentProcessId', 'Name', 'WorkingSetSize' } else { 'ProcessId', 'ParentProcessId', 'Name', 'CommandLine', 'ExecutablePath', 'WorkingSetSize', 'CreationDate', 'PrivatePageCount', 'KernelModeTime', 'UserModeTime' }
    foreach ($p in Get-CimInstance Win32_Process -Property $props -ErrorAction SilentlyContinue) {   # Private: bytes; Cpu: seconds used
      [pscustomobject]@{ Id = [int]$p.ProcessId; ParentId = [int]$p.ParentProcessId; Name = $p.Name; CommandLine = $p.CommandLine; Path = $p.ExecutablePath; WorkingSet = [double]$p.WorkingSetSize; Created = $p.CreationDate; Private = [double]$p.PrivatePageCount; Cpu = ([double]$p.KernelModeTime + [double]$p.UserModeTime) / 1e7 }
    }
  }
  else {
    $names = @{}
    foreach ($l in (ps -A -o pid= -o comm= 2>$null)) { if ($l -match '^\s*(\d+)\s+(.*)$') { $names[[int]$Matches[1]] = Split-Path $Matches[2].Trim() -Leaf } }
    foreach ($l in (ps -A -o pid= -o ppid= -o rss= -o etime= -o args= 2>$null)) {
      if ($l -notmatch '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s?(.*)$') { continue }
      $id = [int]$Matches[1]; $cl = $Matches[5]; $n = [string]$names[$id]
      $exe = Split-Path (($cl -split '\s+')[0]) -Leaf
      if ($n.Length -ge 15 -and $exe.StartsWith($n)) { $n = $exe }
      [pscustomobject]@{ Id = $id; ParentId = [int]$Matches[2]; Name = $n; CommandLine = $cl; Path = ($cl -split '\s+')[0]; WorkingSet = [double]$Matches[3] * 1KB; Created = (ConvertFrom-PsElapsed $Matches[4]); Private = [double]$Matches[3] * 1KB; Cpu = $null }
    }
  }
  if ($Name) { @($all | Where-Object { $_.Name -match $Name }) } else { @($all) }
}
function New-DirLink([string]$Path, [string]$Target) {
  if ($KitIsWindows) { cmd /c mklink /J "$Path" "$Target" | Out-Null; if ($LASTEXITCODE) { throw "New-DirLink: mklink /J $Path -> $Target failed ($LASTEXITCODE)" } }
  else { New-Item -ItemType SymbolicLink -Path $Path -Value $Target | Out-Null }
}
function Remove-DirLink([string]$Path) {
  if ($KitIsWindows) { cmd /c rmdir "$Path" | Out-Null }
  else { & /bin/rm -f -- "$($Path.TrimEnd('/'))" }
}
function Get-DirLinks([string]$Dir, [int]$Depth = 4) {
  if ($KitIsWindows) { Get-ChildItem $Dir -Recurse -Depth $Depth -Directory -Attributes ReparsePoint -ErrorAction SilentlyContinue }
  else { Get-ChildItem $Dir -Recurse -Depth $Depth -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -eq 'SymbolicLink' -and (Test-Path -PathType Container $_.FullName) } }
}
function Get-Python { if ($KitIsWindows) { 'python' } else { $p = Resolve-Tool python3 python; if ($p) { $p } else { 'python3' } } }
function Start-Detached([string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory = (Get-Location).Path, [string]$Log) {
  if ($KitIsWindows) { $null = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden; return }
  if (-not $Log) { $Log = Join-Path (Get-KitTemp) "kit-bg-$([IO.Path]::GetFileNameWithoutExtension($FilePath))-$PID.log" }
  $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.UseShellExecute = $false
  $script = 'cd "$1" || exit 1; log=$2; shift 2; s=; command -v setsid >/dev/null 2>&1 && s=setsid; $s nohup "$@" >"$log" 2>&1 </dev/null &'
  foreach ($a in @('-c', $script, 'sh', $WorkingDirectory, $Log, $FilePath) + @($ArgumentList)) { $psi.ArgumentList.Add([string]$a) }
  ([Diagnostics.Process]::Start($psi)).WaitForExit()
}
