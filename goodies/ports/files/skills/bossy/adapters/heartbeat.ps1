<#
heartbeat.ps1 (goody ports): the bossy E1 timer for Codex, which has no timer tool; dot-sourced by bossy.ps1 (skills/bossy/adapters/).
  bossy.ps1 heartbeat -Thread <Codex session id> [-Minutes <n>]   one detached pwsh waits n min (default: the learned
    heartbeat), then `codex queue` puts the E1 prompt into that session; arming again replaces the armed one
  bossy.ps1 heartbeat -Stop   nothing runs any more: the armed timer goes
Inputs: $env:CODEX_SESSION_ID (default thread), codex on PATH. Outputs: one line; <runtime>/cache/heartbeat.json (pid, thread, due).
Exit codes: 0 ok · 1 codex not found · 2 usage.
Sections: L11 heartbeat
#>
#Requires -Version 7
# ---- heartbeat: one armed timer at a time
function Invoke-Heartbeat {
param([string]$Thread = "$env:CODEX_SESSION_ID", [double]$Minutes = 0, [switch]$Stop)
$f = Join-Path (Get-KitPath cache -Create) 'heartbeat.json'
$old = try { Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
if ($old.pid -and (Test-KitPid $old.pid $old.start)) { Stop-SysProcess $old.pid }
Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
if ($Stop) { 'heartbeat: stopped'; return }
if (-not $Thread) { 'usage: heartbeat -Thread <Codex session id> [-Minutes <n>] | -Stop'; exit 2 }
if (-not $Minutes) { $Minutes = Get-KitBeatMinutes }
$codex = (Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $codex) { 'heartbeat: UNKNOWN: codex is not on PATH, nothing armed'; exit 1 }
$msg = "Run & '$($KitCmd.orch -replace '\\', '/')' supervise -AutoFix -Brief, paste its output verbatim, one own line only when an ACT needs action, then re-arm: bossy.ps1 heartbeat -Thread $Thread -Minutes <its stderr NEXT=n> (bossy E1)"
$cmd = "Start-Sleep -Seconds $([int]($Minutes * 60)); & '$codex' queue --thread '$Thread' --message '$($msg -replace "'", "''")'"
$a = @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))   # no quoting through Start-Process
$p = if ($KitIsWindows) { Start-Process pwsh -ArgumentList $a -WindowStyle Hidden -PassThru } else { Start-Process pwsh -ArgumentList $a -PassThru }
Write-KitAtomic $f (@{ pid = $p.Id; start = (Get-KitPidStart $p.Id); thread = $Thread; due = (Get-Date).AddMinutes($Minutes).ToString('o') } | ConvertTo-Json)
"heartbeat: armed, $Minutes min, Codex session $Thread (pid $($p.Id))"
}
