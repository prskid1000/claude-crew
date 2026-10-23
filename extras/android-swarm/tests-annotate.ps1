#Requires -Version 7
# Tests of the extra annotate: a labelled box is drawn into a copy. Run: kittool.py extra test annotate
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit annotate; $Q = Join-Path $k 'skills/qa-kit/qa.ps1'
if ($IsWindows) {
  Add-Type -AssemblyName System.Drawing; $png = Join-Path (Kd) 'shot.png'; $b = [Drawing.Bitmap]::new(200, 100); $b.Save($png, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
  $out = Px $Q annotate -In $png -Rect '10,40,50,30,Save button' -Copy 2>&1 | Out-String
  $m = [Drawing.Bitmap]::new((Join-Path (Kd) 'shot-marked.png')); $px = $m.GetPixel(10, 50); $m.Dispose()
  Expect "annotate: -Copy writes <name>-marked.png with a red box ($out)" ($out -match 'annotated .*shot-marked\.png \(1 rect\)' -and $px.R -gt 150 -and $px.G -lt 100)
} else { 'SKIP annotate (Windows only)' }
Remove-TestKit $k
Complete-Tests
