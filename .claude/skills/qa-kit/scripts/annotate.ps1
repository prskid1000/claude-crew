<#
Marks up a screenshot in one call: rectangles, arrows and text labels, so a reviewer sees at once what the evidence is about.
Works on PNG/JPEG from any source (web, Android, desktop). Pure PowerShell + System.Drawing, no installs.
Windows only: .NET supports System.Drawing only there. On Linux/macOS mark the element before the shot instead
(browser.mjs mark() before shot(); Android shots stay unmarked - name the element in the check note).

  $A = '<workspace>\.claude\skills\qa-kit\scripts\annotate.ps1'
  & $A -In shots\GT4-X1_02_manifest.png -Rect '55,780,543,40,cut off here' -Arrow '400,600,540,790,last word missing' -Text '40,40,Expected: wraps inside A4'
  -Rect 'x,y,w,h[,label]'      -Arrow 'x1,y1,x2,y2[,label]' (tip at x2,y2)      -Text 'x,y,text'      (each repeatable / comma lists)
  -Out <file>  default: overwrites -In (keep the evidence name); -Color red|orange|green|blue (default red); -Scale for very large shots.
Coordinates are image pixels (Android: uiautomator bounds are already pixels; web: CSS px x devicePixelRatio).
#>
param(
  [Parameter(Mandatory)][string]$In, [string]$Out,
  [string[]]$Rect = @(), [string[]]$Arrow = @(), [string[]]$Text = @(),
  [ValidateSet('red', 'orange', 'green', 'blue')][string]$Color = 'red', [double]$Scale = 0
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'annotate.ps1 needs Windows (System.Drawing). On Linux/macOS use browser.mjs mark() before shot(); for Android name the element in the check note.' }
Add-Type -AssemblyName System.Drawing
$src = (Resolve-Path $In).Path
if (-not $Out) { $Out = $src }
$bytes = [IO.File]::ReadAllBytes($src)                     # read fully so we can overwrite the same file
$ms = New-Object IO.MemoryStream(, $bytes)
$img0 = [Drawing.Image]::FromStream($ms)
$bmp = New-Object Drawing.Bitmap $img0.Width, $img0.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
$g.DrawImage($img0, 0, 0, $img0.Width, $img0.Height)
$k = if ($Scale) { $Scale } else { [math]::Max(1, $img0.Width / 1300) }  # line/font size grows with the image
$col = @{ red = [Drawing.Color]::FromArgb(230, 220, 38, 38); orange = [Drawing.Color]::FromArgb(230, 245, 140, 0); green = [Drawing.Color]::FromArgb(230, 22, 163, 74); blue = [Drawing.Color]::FromArgb(230, 37, 99, 235) }[$Color]
$pen = New-Object Drawing.Pen $col, (4 * $k)
$font = New-Object Drawing.Font 'Segoe UI', ([float](15 * $k)), ([Drawing.FontStyle]::Bold)
$bg = New-Object Drawing.SolidBrush $col
$fg = [Drawing.Brushes]::White
function Label([string]$t, [float]$x, [float]$y) {
  if (-not $t) { return }
  $sz = $g.MeasureString($t, $font)
  $x = [math]::Max(0, [math]::Min($x, $bmp.Width - $sz.Width - 2)); $y = [math]::Max(0, [math]::Min($y, $bmp.Height - $sz.Height - 2))
  $g.FillRectangle($bg, $x, $y, $sz.Width + 8 * $k, $sz.Height + 2 * $k)
  $g.DrawString($t, $font, $fg, $x + 4 * $k, $y + $k)
}
function Parts($s) { $p = $s -split ',', 5; $p }
foreach ($r in ($Rect | ForEach-Object { $_ -split ';' } | Where-Object { $_ })) {
  $p = $r -split ',', 5; $x = [float]$p[0]; $y = [float]$p[1]; $w = [float]$p[2]; $h = [float]$p[3]
  $g.DrawRectangle($pen, $x, $y, $w, $h)
  if ($p.Count -ge 5) { $ly = if ($y - 30 * $k -ge 0) { $y - 30 * $k } else { $y + $h + 4 * $k }; Label $p[4] $x $ly }
}
foreach ($a in ($Arrow | ForEach-Object { $_ -split ';' } | Where-Object { $_ })) {
  $p = $a -split ',', 5; $x1 = [float]$p[0]; $y1 = [float]$p[1]; $x2 = [float]$p[2]; $y2 = [float]$p[3]
  $ap = New-Object Drawing.Pen $col, (4 * $k)
  $ap.CustomEndCap = New-Object Drawing.Drawing2D.AdjustableArrowCap 4, 4, $true
  $g.DrawLine($ap, $x1, $y1, $x2, $y2)
  if ($p.Count -ge 5) { Label $p[4] ($x1 - 10 * $k) ($y1 - 30 * $k) }
}
foreach ($t in ($Text | Where-Object { $_ })) { $p = $t -split ',', 3; Label $p[2] ([float]$p[0]) ([float]$p[1]) }
$g.Dispose(); $img0.Dispose(); $ms.Dispose()
$fmt = if ($Out -match '\.jpe?g$') { [Drawing.Imaging.ImageFormat]::Jpeg } else { [Drawing.Imaging.ImageFormat]::Png }
$bmp.Save($Out, $fmt); $bmp.Dispose()
"annotated $Out ($(@($Rect).Count) rect, $(@($Arrow).Count) arrow, $(@($Text).Count) text)"
