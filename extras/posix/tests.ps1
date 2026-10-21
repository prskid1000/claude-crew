#Requires -Version 7
# Tests of the extra posix: memory, processes and directory links answer on Linux / macOS. Run: kittool.py extra test posix
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit posix
if ($IsWindows) { 'SKIP posix (Linux / macOS only)' } else {
  $r = pwsh -NoProfile -Command ". '$k/skills/dev-kit/lib.ps1'; `$m = Get-SysMem; `$p = @(Get-SysProcs | Where-Object Id -eq `$PID); `$d = Join-Path '$(Kd)' 'l'; New-DirLink `$d '$(Kd)'; ""`$(`$m.TotalGB -gt 0 -and `$m.AvailGB -gt 0)|`$(`$p.Count)|`$(@(Get-DirLinks '$(Kd)' 1).Count)""" 2>&1 | Out-String
  Expect "posix: memory, own process, a directory link ($($r.Trim()))" ($r.Trim() -match '^True\|1\|1$')
}
Remove-TestKit $k
Complete-Tests
