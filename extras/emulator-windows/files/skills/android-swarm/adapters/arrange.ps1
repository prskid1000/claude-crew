#Requires -Version 7
# emulator-windows (extra): swarm.ps1 arrange + up places visible emulator windows in a row on the main monitor (Windows,
# lanes with headless: false or up -ShowAll). Dot-sourced by swarm.ps1 from adapters/.
# ---- arrange: place emulator windows (Windows; run by up)
function Invoke-Arrange {
param([int]$Gap = 16, [double]$HeightShare = 0.78)   # share of the monitor's height
# lane-order row of equal windows centred on the main monitor (physical px); Windows only
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { 'window arranging is Windows-only (Win32 APIs): skipped - place emulator windows by hand or use swarm.ps1 up -Headless'; return }
Add-Type @'
using System; using System.Runtime.InteropServices;
public class SwarmWin {
  public struct RECT { public int L, T, R, B; }
  public struct MONITORINFO { public int cb; public RECT rc; public RECT work; public uint flags; }
  const string U = "user32.dll";
  [DllImport(U)] public static extern bool SetProcessDPIAware();
  [DllImport(U)] public static extern IntPtr MonitorFromPoint(long pt, uint flags);
  [DllImport(U)] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
  [DllImport(U)] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport(U)] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport(U)] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@ -ErrorAction SilentlyContinue
[SwarmWin]::SetProcessDPIAware() | Out-Null
$mi = New-Object SwarmWin+MONITORINFO; $mi.cb = [Runtime.InteropServices.Marshal]::SizeOf($mi)
[SwarmWin]::GetMonitorInfo([SwarmWin]::MonitorFromPoint(0, 1), [ref]$mi) | Out-Null   # point 0,0; 1 = primary
$work = $mi.work; $mw = $work.R - $work.L; $mh = $work.B - $work.T
$order = @((Get-SwarmConfig).lanes.name)
$wins = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -match 'Android Emulator - (\w+):' } |
  ForEach-Object { $null = $_.MainWindowTitle -match 'Android Emulator - (\w+):'; [pscustomobject]@{ Lane = $Matches[1]; H = $_.MainWindowHandle } } | Sort-Object { [array]::IndexOf($order, $_.Lane) })
if (-not $wins) { 'no emulator windows found'; return }
foreach ($w in $wins) { [SwarmWin]::ShowWindow($w.H, 9) | Out-Null }
# size from the first phone's aspect
$r = New-Object SwarmWin+RECT; [SwarmWin]::GetWindowRect($wins[0].H, [ref]$r) | Out-Null
$h = [int]($mh * $HeightShare); $w = [int](($r.R - $r.L) * $h / ($r.B - $r.T)); $total = $wins.Count * ($w + $Gap) - $Gap
$x = $work.L + [math]::Max(0, [int](($mw - $total) / 2)); $y = $work.T + [math]::Max(0, [int](($mh - $h) / 2))
$placed = foreach ($v in $wins) { [SwarmWin]::SetWindowPos($v.H, [IntPtr]::Zero, $x, $y, $w, $h, 0x0004) | Out-Null; "$($v.Lane) at x=$x"; $x += $w + $Gap }   # NOZORDER
if ($total -gt $mw) { Write-Warning 'windows are wider than the main monitor - they overlap' }
"main monitor ${mw}x${mh}: $($placed -join ', ') (y=$y)"
}
