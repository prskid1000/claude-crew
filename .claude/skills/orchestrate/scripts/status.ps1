#Requires -Version 7   # ConvertFrom-Json -AsHashtable; under Windows PowerShell 5.1 every load is null and actions run on empty ids
<#
One-page status of everything the kit is doing: memory + running gated builds, worktrees (branch, dirty, ahead/behind),
QA runs (per package verdicts, published or not), the learning loop (signals, guard blocks, last retro).
Writes <.claude-runtime>\dashboard.html (auto-refreshes every 60 s in the browser).

  & <workspace>\.claude\skills\orchestrate\scripts\status.ps1 [-Open] [-Watch] [-WorktreeRoot <folder with worktrees>]
-Watch regenerates every 60 s until stopped (run it in the background during a wave).
-WorktreeRoot default: kit.local.json "worktreeRoots" (else <reposRoot>-wt, the wt.ps1 default).
#>
param([switch]$Open, [switch]$Watch, [string[]]$WorktreeRoot = @())
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path ($PSCommandPath -replace '[\\/]\.claude[\\/].*$', '') '.claude-runtime' }
. (Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit/scripts/kitconfig.ps1')
. (Join-Path (Split-Path (Split-Path (Split-Path $PSCommandPath))) 'dev-kit/scripts/sysinfo.ps1')
if (-not $WorktreeRoot) { $WorktreeRoot = $KitConf.WorktreeRoots }
$out = Join-Path $rt 'dashboard.html'
function Esc($t) { [System.Net.WebUtility]::HtmlEncode([string]$t) }

function Build {
  $cell = 'border:1px solid #d1d5db;padding:5px 8px;font-size:10pt;vertical-align:top'
  $hd = "border:1px solid #d1d5db;padding:5px 8px;font-size:10pt;background:#1f3a68;color:#fff"
  $h2 = 'font-size:13pt;border-bottom:2px solid #1f3a68;padding-bottom:3px;margin-top:18px'
  $sb = New-Object System.Text.StringBuilder
  function A($s) { [void]$sb.Append($s) }
  function Table($heads, $rows) { $rows = @($rows); if ($rows.Count -and $rows[0] -isnot [array]) { $rows = , $rows }; A "<table style='border-collapse:collapse;width:100%'><tr>$(($heads | ForEach-Object { "<td style='$hd'><b>$_</b></td>" }) -join '')</tr>"; foreach ($r in $rows) { A "<tr>$(($r | ForEach-Object { "<td style='$cell'>$_</td>" }) -join '')</tr>" }; A '</table>' }
  A "<html><head><meta charset='utf-8'><meta http-equiv='refresh' content='60'><title>Kit status</title></head><body style='font-family:Arial,Helvetica,sans-serif;color:#111827;margin:20px;max-width:1200px'>"
  A "<p style='font-size:9pt;color:#6b7280;margin:0'>KIT STATUS · $(Get-Date -Format 'd MMM yyyy HH:mm:ss') · refreshes every 60 s</p><h1 style='font-size:20pt;margin:2px 0 8px 0'>Agents, builds and QA</h1>"

  # Memory + gate
  $mem = Get-SysMem; $tot = $mem.TotalGB
  $avail = $mem.AvailGB; $pct = [int](100 * (1 - $avail / $tot))
  $bar = if ($pct -gt 85) { '#b91c1c' } elseif ($pct -gt 70) { '#b7791f' } else { '#1e7b34' }
  A "<h2 style='$h2'>Memory and builds</h2><p>RAM in use <b>$pct%</b> · $avail GB available of $([math]::Round($tot)) GB</p>"
  A "<div style='background:#e5e7eb;height:10px;width:100%'><div style='background:$bar;height:10px;width:$pct%'></div></div>"
  $ledger = Join-Path (Get-KitTemp) 'claude-build-gate'
  $running = @(Get-ChildItem $ledger -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -ne 'history.json' | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} } | Where-Object { Get-Process -Id $_.pid -ErrorAction SilentlyContinue })
  if ($running.Count) { A '<p><b>Running gated builds</b></p>'; Table @('Kind', 'Est. GB', 'Started', 'Dir', 'Command') ($running | ForEach-Object { , @((Esc $_.kind), $_.need, (Esc $_.started), (Esc $_.dir), (Esc ($_.cmd.Substring(0, [math]::Min(90, $_.cmd.Length))))) }) }
  else { A '<p>No gated builds running.</p>' }
  $hist = try { Get-Content (Join-Path $ledger 'history.json') -Raw | ConvertFrom-Json -AsHashtable } catch { @{} }
  if ($hist.Count) {
    A '<p><b>Learned build profiles</b> (last 10 runs per kind)</p>'
    Table @('Kind', 'Runs', 'Peak GB (max)', 'Median time', 'Failures') ($hist.Keys | Sort-Object | ForEach-Object { $s = @($hist[$_]); $t = @($s | ForEach-Object { [double]$_.sec } | Sort-Object); , @($_, $s.Count, ([math]::Round((($s | ForEach-Object { [double]$_.gb }) | Measure-Object -Maximum).Maximum, 2)), ("{0:N0} s" -f $t[[int][math]::Floor($t.Count / 2)]), @($s | Where-Object { $_.ok -eq $false }).Count) })
  }

  # Worktrees
  $wts = foreach ($root in $WorktreeRoot) { Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName '.git') } }
  if ($wts) {
    A "<h2 style='$h2'>Worktrees ($(@($wts).Count))</h2>"
    $rows = foreach ($w in $wts) {
      $d = $w.FullName
      $br = (git -C $d rev-parse --abbrev-ref HEAD 2>$null)
      $gd = (git -C $d rev-parse --git-dir 2>$null); if ($gd -and -not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $d $gd }
      $tg = if ($gd -and (Test-Path "$gd\claude-target")) { (Get-Content "$gd\claude-target" -Raw).Trim() } else { '' }
      $ab = if ($tg) { (git -C $d rev-list --left-right --count "HEAD...origin/$tg" 2>$null) -replace '\s+', ' / ' } else { '' }
      $dirty = @(git -C $d status --porcelain 2>$null).Count
      $last = "$(git -C $d log -1 --format='%cr · %s' 2>$null)"
      , @((Esc $w.Name), (Esc $br), (Esc $tg), (Esc $ab), $(if ($dirty) { "<span style='color:#b7791f'><b>$dirty</b></span>" } else { '0' }), (Esc ($last.Substring(0, [math]::Min(80, $last.Length)))))
    }
    Table @('Worktree', 'Branch', 'Target', 'Ahead / behind', 'Dirty files', 'Last commit') $rows
  }

  # QA runs
  $runs = Get-ChildItem (Join-Path $rt 'qa-runs') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
  if ($runs) {
    A "<h2 style='$h2'>QA runs (latest 5)</h2>"
    foreach ($r in $runs) {
      $run = try { Get-Content "$($r.FullName)\run.json" -Raw | ConvertFrom-Json } catch { $null }
      A "<p style='margin:10px 0 4px 0'><b>$(Esc $(if ($run.title) { $run.title } else { $r.Name }))</b> <span style='color:#6b7280'>· $(Esc $r.Name)</span></p>"
      $rows = foreach ($it in @($run.items)) {
        $res = try { Get-Content "$($r.FullName)\$($it.code)\results.json" -Raw | ConvertFrom-Json } catch { $null }
        $fin = try { Get-Content "$($r.FullName)\$($it.code)\finalize.json" -Raw | ConvertFrom-Json } catch { $null }
        $c = @($res.checks); $n = { param($k) @($c | Where-Object result -eq $k).Count }
        $state = if ($fin) { "<a href='$($fin.doc)'>published</a>" } elseif ($res) { 'tested, not published' } else { 'pending' }
        , @((Esc $it.code), (Esc $it.lane), (& $n 'PASS') + (& $n 'PASS_WITH_NOTE'), "<span style='color:#991b1b'><b>$(& $n 'FAIL')</b></span>", (& $n 'NOT_TESTED'), $state)
      }
      Table @('Code', 'Lane', 'Pass', 'Fail', 'Not tested', 'State') $rows
    }
  }

  # Learning loop
  $sig = Join-Path $rt 'learning\signals.jsonl'; $mark = Join-Path $rt 'learning\last-retro.txt'; $guard = Join-Path $rt 'guard.log'
  $since = if (Test-Path $mark) { [datetime](Get-Content $mark -Raw).Trim() } else { [datetime]::MinValue }
  $sigs = if (Test-Path $sig) { @(Get-Content $sig | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
  $new = @($sigs | Where-Object { [datetime]$_.at -gt $since })
  $blocks = if (Test-Path $guard) { @(Get-Content $guard) } else { @() }
  A "<h2 style='$h2'>Learning loop</h2><p>$($new.Count) new signal(s) since the last retro ($(if ($since -eq [datetime]::MinValue) { 'never run' } else { $since.ToString('d MMM HH:mm') })) · $($sigs.Count) total · $($blocks.Count) guard block(s)$(if (($new.Count + $blocks.Count) -ge 15) { " · <b style='color:#b91c1c'>run /kit-retro</b>" })</p>"
  if ($new.Count) { Table @('When', 'Skill', 'Kind', 'Signal') ($new | Select-Object -Last 15 | ForEach-Object { , @(([datetime]$_.at).ToString('d MMM HH:mm'), (Esc $_.skill), (Esc $_.kind), (Esc $_.text)) }) }
  if ($blocks.Count) { A '<p><b>Recent guard blocks</b></p>'; Table @('When', 'Reason', 'Command') ($blocks | Select-Object -Last 8 | ForEach-Object { $p = $_ -split "`t"; , @((Esc $p[0]), (Esc $p[2]), (Esc $p[3])) }) }
  $cl = Join-Path $rt 'cleanup.log'; if (Test-Path $cl) { $last = Get-Content $cl | Where-Object { $_ -match '^\d{4}-' } | Select-Object -Last 1; A "<h2 style='$h2'>Cleanup</h2><p>$(Esc $last)</p>" }
  A '</body></html>'
  New-Item -ItemType Directory -Force $rt | Out-Null
  $sb.ToString() | Out-File $out -Encoding utf8
}

Build
"dashboard: $out"; $global:LASTEXITCODE = 0
if ($Open) { Start-Process $out }
while ($Watch) { Start-Sleep 60; Build }
