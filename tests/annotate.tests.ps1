#Requires -Version 7
# Usage: pwsh -NoProfile -File tests/annotate.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
# tests/annotate.tests.ps1: annotate: a labelled box is drawn into a copy. Usage: pwsh -NoProfile -File tests/annotate.tests.ps1
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/crafty/adapters/android_sdk.ps1', 'skills/phoney/SKILL.md', 'skills/phoney/adapters/app_kinds.ps1', 'skills/phoney/adapters/arrange.ps1', 'skills/phoney/phoney.ps1', 'skills/pokey/adapters/annotate.ps1', 'skills/pokey/adapters/ui_android.ps1')   # copied into every New-TestKit kit
$k = New-TestKit annotate; $Q = Join-Path $k 'skills/pokey/pokey.ps1'
if ($IsWindows) {
  Add-Type -AssemblyName System.Drawing; $png = Join-Path (Kd) 'shot.png'; $b = [Drawing.Bitmap]::new(200, 100); $b.Save($png, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
  $out = Px $Q annotate -In $png -Rect '10,40,50,30,Save button' -Copy 2>&1 | Out-String
  $m = [Drawing.Bitmap]::new((Join-Path (Kd) 'shot-marked.png')); $px = $m.GetPixel(10, 50); $m.Dispose()
  Expect "annotate: -Copy writes <name>-marked.png with a red box ($out)" ($out -match 'annotated .*shot-marked\.png \(1 rect\)' -and $px.R -gt 150 -and $px.G -lt 100)
} else { 'SKIP annotate (Windows only)' }
Remove-TestKit $k
Complete-Tests
