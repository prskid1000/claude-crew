<#
Cross-platform system helpers (Windows, Linux, macOS) for the kit scripts. Dot-source it:

  . (Join-Path <path to skills/dev-kit/scripts> 'sysinfo.ps1')

  $KitIsWindows                 # $true on Windows (also under Windows PowerShell 5.1, where $IsWindows does not exist)
  Get-KitTemp                   # the OS temp folder ($env:TEMP on Windows, $TMPDIR or /tmp elsewhere)
  Get-SysMem                    # { TotalGB; AvailGB (free + reclaimable cache, what Task Manager calls Available); FreeGB }
  Get-FreeGB                    # free RAM for seat/phone decisions (Windows FreeGB; Linux/macOS AvailGB, their cache keeps "free" ~0)
  Get-SysProcs [-Name <regex>] [-NoCommandLine]  # [{ Id; ParentId; Name; CommandLine; WorkingSet (bytes); Created }] for every process
  Stop-SysProcess -Id <pid>     # kill one process (no error when it is already gone)
  New-DirLink -Path <link> -Target <dir>   # junction on Windows (no admin needed), symbolic link elsewhere
  Remove-DirLink -Path <link>   # removes only the link, never the folder it points to
  Get-DirLinks -Dir <d> [-Depth 4]         # directory links (junctions / symlinks) below <d>, without following them
  Resolve-Tool <name>...        # first command that exists (e.g. Resolve-Tool python3 python), as a full path, or $null
  Get-Python                    # 'python' on Windows, else python3 (or python when that is the only one)
  Start-Detached -FilePath <exe> -ArgumentList <args> [-WorkingDirectory <d>] [-Log <file>]   # outlives the shell (hidden window on Windows)
  Get-PortPids <port> / Test-PortListening <port>   # who listens on a local TCP port / is anything listening
  Get-AndroidSdk                # ANDROID_HOME / ANDROID_SDK_ROOT, else the OS default SDK folder
  Get-ExeName <name>            # <name>.exe on Windows, <name> elsewhere

On Linux memory comes from /proc/meminfo and processes from `ps`; on macOS from `sysctl hw.memsize` + `vm_stat` and `ps`.
Process names are the executable name; on Windows they keep the .exe suffix (match with '^chrome(\.exe)?$').
#>
$KitIsWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$KitIsMac = (-not $KitIsWindows) -and ($PSVersionTable.OS -match 'Darwin' -or ((Test-Path variable:IsMacOS) -and $IsMacOS))

function Get-KitTemp { [IO.Path]::GetTempPath().TrimEnd([char]'\', [char]'/') }

function Get-ExeName([string]$Name) { if ($KitIsWindows) { "$Name.exe" } else { $Name } }

function Get-SysMem {
  if ($KitIsWindows) {
    $total = (Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1GB
    $avail = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -Property AvailableMBytes).AvailableMBytes / 1KB
    $free = (Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory).FreePhysicalMemory / 1MB
  }
  elseif ($KitIsMac) {
    $total = [double](sysctl -n hw.memsize) / 1GB
    $vm = vm_stat
    $page = if (($vm | Select-Object -First 1) -match 'page size of (\d+)') { [double]$Matches[1] } else { 4096 }
    $n = @{}; foreach ($l in $vm) { if ($l -match '^(Pages [^:]+):\s+(\d+)') { $n[$Matches[1]] = [double]$Matches[2] } }
    $free = ($n['Pages free'] + $n['Pages speculative']) * $page / 1GB
    $avail = $free + ($n['Pages inactive'] + $n['Pages purgeable']) * $page / 1GB
  }
  else {
    $m = @{}; foreach ($l in Get-Content /proc/meminfo) { if ($l -match '^(\w+):\s+(\d+)') { $m[$Matches[1]] = [double]$Matches[2] } }
    $total = $m['MemTotal'] / 1MB
    $free = $m['MemFree'] / 1MB
    $avail = $(if ($m.ContainsKey('MemAvailable')) { $m['MemAvailable'] } else { $m['MemFree'] + $m['Cached'] + $m['Buffers'] }) / 1MB
  }
  [pscustomobject]@{ TotalGB = [math]::Round($total, 1); AvailGB = [math]::Round($avail, 1); FreeGB = [math]::Round($free, 1) }
}

# Free RAM for "may I start another phone / browser seat" decisions: Windows free physical memory (as before), and on Linux/macOS
# the available figure (their page cache keeps MemFree near zero on a healthy machine, so "free" alone would block everything)
function Get-FreeGB { $m = Get-SysMem; if ($KitIsWindows) { $m.FreeGB } else { $m.AvailGB } }

# etime from ps: [[dd-]hh:]mm:ss
function ConvertFrom-PsElapsed([string]$e) {
  if ($e -notmatch '^(\d+-)?(\d+:){1,2}\d+$') { return $null }
  $d = 0; if ($e -match '^(\d+)-(.*)$') { $d = [int]$Matches[1]; $e = $Matches[2] }
  $p = @($e -split ':' | ForEach-Object { [int]$_ }); [array]::Reverse($p)
  $sec = $p[0] + 60 * $(if ($p.Count -gt 1) { $p[1] } else { 0 }) + 3600 * $(if ($p.Count -gt 2) { $p[2] } else { 0 }) + 86400 * $d
  (Get-Date).AddSeconds(-$sec)
}

function Get-SysProcs([string]$Name, [switch]$NoCommandLine) {   # -NoCommandLine: faster on Windows (CommandLine/Created left empty)
  $all = if ($KitIsWindows) {
    $props = if ($NoCommandLine) { 'ProcessId', 'ParentProcessId', 'Name', 'WorkingSetSize' } else { 'ProcessId', 'ParentProcessId', 'Name', 'CommandLine', 'WorkingSetSize', 'CreationDate' }
    foreach ($p in Get-CimInstance Win32_Process -Property $props -ErrorAction SilentlyContinue) {
      [pscustomobject]@{ Id = [int]$p.ProcessId; ParentId = [int]$p.ParentProcessId; Name = $p.Name; CommandLine = $p.CommandLine; WorkingSet = [double]$p.WorkingSetSize; Created = $p.CreationDate }
    }
  }
  else {
    # comm is listed separately (last column, may contain spaces on macOS); on Linux it is cut to 15 chars, so prefer the
    # executable from the command line when it starts with comm
    $names = @{}
    foreach ($l in (ps -A -o pid= -o comm= 2>$null)) { if ($l -match '^\s*(\d+)\s+(.*)$') { $names[[int]$Matches[1]] = Split-Path $Matches[2].Trim() -Leaf } }
    foreach ($l in (ps -A -o pid= -o ppid= -o rss= -o etime= -o args= 2>$null)) {
      if ($l -notmatch '^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s?(.*)$') { continue }
      $id = [int]$Matches[1]; $cl = $Matches[5]; $n = [string]$names[$id]
      $exe = Split-Path (($cl -split '\s+')[0]) -Leaf
      if ($n.Length -ge 15 -and $exe.StartsWith($n)) { $n = $exe }
      [pscustomobject]@{ Id = $id; ParentId = [int]$Matches[2]; Name = $n; CommandLine = $cl; WorkingSet = [double]$Matches[3] * 1KB; Created = (ConvertFrom-PsElapsed $Matches[4]) }
    }
  }
  if ($Name) { @($all | Where-Object { $_.Name -match $Name }) } else { @($all) }
}

function Stop-SysProcess([int]$Id) { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }

function New-DirLink([string]$Path, [string]$Target) {
  if ($KitIsWindows) { cmd /c mklink /J "$Path" "$Target" | Out-Null }
  else { New-Item -ItemType SymbolicLink -Path $Path -Target $Target | Out-Null }
}

function Remove-DirLink([string]$Path) {
  if ($KitIsWindows) { cmd /c rmdir "$Path" | Out-Null }   # rmdir on a junction removes only the link
  else { & /bin/rm -f -- "$($Path.TrimEnd('/'))" }             # rm on a symlink (no trailing slash, no -r) removes only the link
}

function Get-DirLinks([string]$Dir, [int]$Depth = 4) {
  if ($KitIsWindows) { Get-ChildItem $Dir -Recurse -Depth $Depth -Directory -Attributes ReparsePoint -ErrorAction SilentlyContinue }
  else { Get-ChildItem $Dir -Recurse -Depth $Depth -Force -ErrorAction SilentlyContinue | Where-Object { $_.LinkType -eq 'SymbolicLink' -and (Test-Path -PathType Container $_.FullName) } }
}

function Resolve-Tool {
  foreach ($n in $args) { $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { return $c.Source } }
  $null
}

# Python 3 launcher: 'python' on Windows (python3 there is often the Store stub), python3 first elsewhere
function Get-Python { if ($KitIsWindows) { 'python' } else { $p = Resolve-Tool python3 python; if ($p) { $p } else { 'python3' } } }

# Starts a program that outlives this shell (and a tool timeout): hidden window on Windows; on Linux/macOS through
# `setsid nohup` (plain nohup where setsid is missing, e.g. macOS) with output to -Log (default: a kit-bg-*.log in the OS temp)
function Start-Detached([string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory = (Get-Location).Path, [string]$Log) {
  if ($KitIsWindows) { $null = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden; return }
  if (-not $Log) { $Log = Join-Path (Get-KitTemp) "kit-bg-$([IO.Path]::GetFileNameWithoutExtension($FilePath))-$PID.log" }
  $psi = [Diagnostics.ProcessStartInfo]::new('/bin/sh'); $psi.UseShellExecute = $false
  $script = 'cd "$1" || exit 1; log=$2; shift 2; if command -v setsid >/dev/null 2>&1; then setsid nohup "$@" >"$log" 2>&1 </dev/null & else nohup "$@" >"$log" 2>&1 </dev/null & fi'
  foreach ($a in @('-c', $script, 'sh', $WorkingDirectory, $Log, $FilePath) + @($ArgumentList)) { $psi.ArgumentList.Add([string]$a) }
  ([Diagnostics.Process]::Start($psi)).WaitForExit()
}

# Process ids listening on a local TCP port (Get-NetTCPConnection on Windows, lsof or fuser elsewhere)
function Get-PortPids([int]$Port) {
  if ($KitIsWindows) { return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique) }
  if (Resolve-Tool lsof) { return @(lsof -t -nP -iTCP:$Port -sTCP:LISTEN 2>$null | ForEach-Object { [int]$_ } | Select-Object -Unique) }
  if (Resolve-Tool fuser) { return @(("$(fuser -n tcp $Port 2>$null)" -split '\s+') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
  @()
}

# $true when something accepts connections on localhost:<Port>
function Test-PortListening([int]$Port) {
  if ($KitIsWindows) { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) }
  $t = [Net.Sockets.TcpClient]::new()
  try { $t.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $t.Connected } catch { $false } finally { $t.Dispose() }
}

function Get-AndroidSdk {
  foreach ($e in $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) { if ($e) { return $e } }
  if ($KitIsWindows) { Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
  elseif ($KitIsMac) { Join-Path $HOME 'Library/Android/sdk' }
  else { Join-Path $HOME 'Android/Sdk' }
}
