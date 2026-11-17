<#
guard_server.ps1: the warm PreToolUse guard (K48): one long-lived pwsh holds crafty.ps1 loaded in a runspace and answers
guard_client.mjs over a named pipe, so a tool call costs no pwsh start + kit load (~1 s). The client starts it when absent and
falls back to crafty.ps1 guard for that call; any kit file change, 30 idle minutes or a failed request ends it (the next call
restarts it).
  pwsh -NoProfile -File <kit>/skills/crafty/guard_server.ps1 [-Pipe <name>]   (the client starts it: never by hand)
Request (one line): {"env":{...},"input":"<hook stdin>"} -> reply (one line): {"code":0,"out":"..."} | {"reload":true}; {"stop":true}: ends
Exit codes: 0 ended (idle, kit changed, failed request) · 1 the pipe is taken (another server runs) or crafty.ps1 did not load.
#>
#Requires -Version 7
param([string]$Pipe)
$kit = Split-Path (Split-Path $PSScriptRoot)
if (-not $Pipe) { 'usage: guard_server.ps1 -Pipe <name> (guard_client.mjs names it)'; exit 1 }
# the files the guard's answer depends on: a change ends the server (no stale code)
$stamp = { @(Get-ChildItem -LiteralPath (Join-Path $kit 'skills/crafty') -Recurse -File -Include '*.ps1', '*.json' -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';' }
$s0 = & $stamp
# a runspace keeps the guard's script state; its exit ends one call, never the runspace
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs; $null = $ps.AddScript("`$ErrorActionPreference = 'SilentlyContinue'; . '$((Join-Path $kit 'skills/crafty/crafty.ps1').Replace("'", "''"))'; `$script:KitScript = 'crafty.ps1'; `$script:KitVerb = 'guard'").Invoke(); $ps.Dispose()
$ps = [powershell]::Create(); $ps.Runspace = $rs; $loaded = @($ps.AddScript('[bool](Get-Command Invoke-Guard -ErrorAction SilentlyContinue)').Invoke())[0]; $ps.Dispose()
$mk = try { $pm = (Get-Content (Join-Path $PSScriptRoot 'kit.example.json') -Raw | ConvertFrom-Json)._paths; Join-Path $kit "$($pm.runtimeDir)/$($pm.runtime.cache)$Pipe.noload" } catch { $null }
if (-not $loaded) {   # a half-loaded crafty.ps1 would answer every call with an empty allow: the client's plain path decides
  # the marker (crafty.ps1 + lib.ps1 mtimes) stops the client starting a server per call until either changes (K67r)
  try { $null = New-Item -ItemType Directory -Force (Split-Path $mk); Set-Content -LiteralPath $mk -NoNewline (@('crafty.ps1', 'lib.ps1' | ForEach-Object { [DateTimeOffset]::new((Get-Item (Join-Path $PSScriptRoot $_)).LastWriteTimeUtc).ToUnixTimeMilliseconds() }) -join ',') } catch { }
  exit 1
}
if ($mk) { Remove-Item -LiteralPath $mk -ErrorAction SilentlyContinue }   # loaded: an old mark goes
$env0 = @{}; foreach ($v in Get-ChildItem env:) { $env0[$v.Name] = $v.Value }
if ($IsWindows -and [IO.File]::Exists("\\.\pipe\$Pipe")) { exit 1 }   # two cold calls started two: the later one goes
while ($true) {
  $srv = try { [IO.Pipes.NamedPipeServerStream]::new($Pipe, 'InOut', 1, 'Byte', 'Asynchronous') } catch { exit 1 }
  try {
    if (-not $srv.WaitForConnectionAsync().Wait([TimeSpan]::FromMinutes(30))) { exit 0 }
    $rd = [IO.StreamReader]::new($srv, [Text.UTF8Encoding]::new($false)); $wr = [IO.StreamWriter]::new($srv, [Text.UTF8Encoding]::new($false)); $wr.AutoFlush = $true
    $line = $rd.ReadLine(); $stale = (& $stamp) -ne $s0 -or $line -eq '{"stop":true}'   # stop: tests, kitty
    if ($stale -or -not $line) { $wr.WriteLine('{"reload":true}'); if ($stale) { exit 0 }; continue }
    $req = $line | ConvertFrom-Json -AsHashtable; $vars = @($req.env.Keys)
    # the caller's environment for this call only (agent id, session, KIT_* switches): set, run, put back (one process env)
    $drop = @($env0.Keys | Where-Object { $_ -match '^(CLAUDE|KIT)_' -and $_ -notin $vars }); foreach ($n in $drop) { Remove-Item "env:$n" -ErrorAction SilentlyContinue }; foreach ($n in $vars) { Set-Item "env:$n" $req.env[$n] }
    $code = 0; $ps = [powershell]::Create(); $ps.Runspace = $rs; $rs.SessionStateProxy.SetVariable('LASTEXITCODE', 0)
    $cwd = try { "$(($req.input | ConvertFrom-Json).cwd)" } catch { '' }; if ($cwd -and (Test-Path -LiteralPath $cwd -PathType Container)) { [Environment]::CurrentDirectory = $cwd } else { $cwd = '' }   # the hook's cwd: child git calls and relative paths as in the plain path
    $out = try { (@($ps.AddScript('param($j, $d) if ($d) { Set-Location -LiteralPath $d }; $ErrorActionPreference = ''Stop''; Invoke-Guard -Json $j').AddArgument([string]$req.input).AddArgument($cwd).Invoke()) | ForEach-Object { "$_" }) -join "`n"; $code = [int]$rs.SessionStateProxy.GetVariable('LASTEXITCODE') } catch { $code = -1; '' } finally { $ps.Dispose() }
    foreach ($n in @($vars) + $drop) { if ($env0.ContainsKey($n)) { Set-Item "env:$n" $env0[$n] } else { Remove-Item "env:$n" -ErrorAction SilentlyContinue } }
    $wr.WriteLine($(if ($code -lt 0) { '{"reload":true}' } else { @{ code = $code; out = $out } | ConvertTo-Json -Compress }))
    if ($code -lt 0) { exit 0 }
  } catch { exit 0 } finally { $srv.Dispose() }
}
