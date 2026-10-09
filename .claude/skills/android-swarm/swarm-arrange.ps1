param([int]$Gap = 16, [double]$HeightShare = 0.78)   # every window gets the same size: this share of the monitor's height
# Places the running swarm emulator windows side by side in the CENTRE of the MAIN monitor,
# in lane order (swarm.config.json lanes). Works in physical pixels, so display scaling is handled.
# Run any time the windows get lost or overlap. Other monitors are ignored.
# Windows only (Win32 window APIs): on Linux/macOS it does nothing - place the windows by hand or boot with -Headless.
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { 'window arranging is Windows-only (Win32 APIs): skipped - place emulator windows by hand or use swarm-up.ps1 -Headless'; return }
Add-Type @'
using System; using System.Runtime.InteropServices;
public class SwarmWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cb; public RECT rc; public RECT work; public uint flags; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@ -ErrorAction SilentlyContinue
[SwarmWin]::SetProcessDPIAware() | Out-Null
$mi = New-Object SwarmWin+MONITORINFO; $mi.cb = [Runtime.InteropServices.Marshal]::SizeOf($mi)
[SwarmWin]::GetMonitorInfo([SwarmWin]::MonitorFromPoint((New-Object SwarmWin+POINT), 1), [ref]$mi) | Out-Null   # 1 = primary
$work = $mi.work

$order = @((& (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '_config.ps1')).lanes.name)
$wins = Get-Process | Where-Object { $_.MainWindowTitle -match 'Android Emulator - (\w+):' -and $_.MainWindowHandle -ne 0 } |
  ForEach-Object { $null = $_.MainWindowTitle -match 'Android Emulator - (\w+):'; [pscustomobject]@{ Lane = $Matches[1]; H = $_.MainWindowHandle } } |
  Sort-Object { [array]::IndexOf($order, $_.Lane) }
if (-not $wins) { 'no emulator windows found'; return }

# centre the row on the main monitor, both horizontally and vertically
$sizes = foreach ($w in $wins) { [SwarmWin]::ShowWindow($w.H, 9) | Out-Null; $r = New-Object SwarmWin+RECT; [SwarmWin]::GetWindowRect($w.H, [ref]$r) | Out-Null; [pscustomobject]@{ W = $w; Width = $r.R - $r.L; Height = $r.B - $r.T } }
# same size for every window: height = HeightShare of the monitor, width from the phone's aspect (first window)
$ref = $sizes[0]; $h = [int]((($work.B - $work.T) * $HeightShare)); $w = [int]($ref.Width * $h / $ref.Height)
foreach ($s in $sizes) { $s.Width = $w; $s.Height = $h }
$total = ($sizes | Measure-Object Width -Sum).Sum + $Gap * ($sizes.Count - 1)
$tallest = ($sizes | Measure-Object Height -Maximum).Maximum
$x = $work.L + [math]::Max(0, [int](($work.R - $work.L - $total) / 2))
$y = $work.T + [math]::Max(0, [int](($work.B - $work.T - $tallest) / 2))
$placed = @()
foreach ($s in $sizes) {
  [SwarmWin]::SetWindowPos($s.W.H, [IntPtr]::Zero, $x, $y, $s.Width, $s.Height, 0x0004) | Out-Null   # NOZORDER, explicit equal size
  $placed += "$($s.W.Lane) at x=$x"
  $x += $s.Width + $Gap
}
if ($total -gt ($work.R - $work.L)) { Write-Warning 'windows are wider than the main monitor - they overlap' }
"main monitor $($work.R - $work.L)x$($work.B - $work.T): " + ($placed -join ', ') + " (y=$y)"
