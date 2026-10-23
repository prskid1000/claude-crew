#Requires -Version 7
# annotate (extra): qa.ps1 annotate -In <image> -Rect 'x,y,w,h[,label]' [-Out <file> | -Copy]: red boxes on a PNG / JPEG
# (Windows, System.Drawing); image px (web: CSS px x DPR). Dot-sourced by qa.ps1 from adapters/.
function Invoke-Annotate {
param([Parameter(Mandatory)][string]$In, [string]$Out, [string[]]$Rect = @(), [switch]$Copy)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'annotate needs Windows (System.Drawing): elsewhere mark() before shot(), or name the element in the check note' }
$Rect = @(Split-KitList $Rect ';')   # one box each, its commas stay
Add-Type -AssemblyName System.Drawing
$src = (Resolve-Path $In).Path
if (-not $Out -and $Copy) { $Out = Join-Path (Split-Path $src) ("{0}-marked{1}" -f [IO.Path]::GetFileNameWithoutExtension($src), [IO.Path]::GetExtension($src)) }
if (-not $Out) { $Out = $src }
$ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($src))   # read fully: the file may be overwritten
$img0 = [Drawing.Image]::FromStream($ms)
$bmp = New-Object Drawing.Bitmap $img0.Width, $img0.Height
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
$g.DrawImage($img0, 0, 0, $img0.Width, $img0.Height)
$k = [math]::Max(1, $img0.Width / 1300)   # sizes grow with the image
$red = [Drawing.Color]::FromArgb(230, 220, 38, 38)
$pen = New-Object Drawing.Pen $red, (4 * $k)
$font = New-Object Drawing.Font ([Drawing.FontFamily]::GenericSansSerif), ([float](15 * $k)), ([Drawing.FontStyle]::Bold)
foreach ($r in $Rect) {
  $p = $r -split ',', 5; $x = [float]$p[0]; $y = [float]$p[1]; $w = [float]$p[2]; $h = [float]$p[3]
  $g.DrawRectangle($pen, $x, $y, $w, $h)
  if ($p.Count -ge 5 -and $p[4]) {   # label above the box, else below; kept inside the image
    $sz = $g.MeasureString($p[4], $font)
    $lx = [math]::Max(0, [math]::Min($x, $bmp.Width - $sz.Width - 2)); $ly = if ($y - 30 * $k -ge 0) { $y - 30 * $k } else { [math]::Min($y + $h + 4 * $k, $bmp.Height - $sz.Height - 2) }
    $g.FillRectangle((New-Object Drawing.SolidBrush $red), $lx, $ly, $sz.Width + 8 * $k, $sz.Height + 2 * $k)
    $g.DrawString($p[4], $font, [Drawing.Brushes]::White, $lx + 4 * $k, $ly + $k)
  }
}
$g.Dispose(); $img0.Dispose(); $ms.Dispose()
$bmp.Save($Out, $(if ($Out -match '\.jpe?g$') { [Drawing.Imaging.ImageFormat]::Jpeg } else { [Drawing.Imaging.ImageFormat]::Png })); $bmp.Dispose()
"annotated $Out ($(@($Rect).Count) rect)"
}
