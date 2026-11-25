#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (crafty.ps1 check exits).
# Sections: L4 check builds · L13 check stamps · L52 ci runs · L60 run digest
# ---- check builds: a clean tree's build, keyed by its tree: envy deploys of the same code stage its artifact (envy Find-CheckBuild)
function Save-CheckBuild([string]$Dir, [string]$Cmd, [datetime]$Start) {
  $top = "$(git -C $Dir rev-parse --show-toplevel 2>$null)".Trim(); if (-not $top -or @(git -C $top status --porcelain 2>$null).Count) { return }
  $tree = "$(git -C $top rev-parse 'HEAD^{tree}' 2>$null)".Trim(); if (-not $tree) { return }
  Write-KitAtomic (Join-Path (Get-KitPath check-builds -Create) "$tree.json") ([ordered]@{ tree = $tree; dir = $Dir; rel = [IO.Path]::GetRelativePath($top, $Dir).Replace('\', '/'); cmd = $Cmd; start = (Get-KitStamp stored $Start); at = (Get-KitStamp) } | ConvertTo-Json)
}
# a step's log: per dir, step and run (parallel checks of one dir); cleanup drops it after keep.check-logs hours
function Get-CheckLog([string]$Dir, [string]$Step) { Join-Path (Get-KitPath check-logs -Create) "$((Get-KitHash $Dir.ToLower() MD5).Substring(0, 12))-$Step-$PID.log" }

# ---- check stamps: per module dir, step + command -> the source key of its last run; Invoke-Check skips an unchanged rerun
# (2026-11-18: 51 of 211 checks re-ran the previous command of their dir; a doc-only edit rebuilt the module)
# the repo's sources as one key: index blobs + the content of every changed or untracked file; ignored files and docs
# (.md .adoc .rst outside src / resources / assets / test folders) aside; a dirty submodule or a failed git call: no key (runs)
function Get-CheckSourceKey([string]$Dir) {
  $top = "$(git -C $Dir rev-parse --show-toplevel 2>$null)".Trim(); if (-not $top) { return $null }
  $doc = '^(?!(.*/)?(src|resources|assets|tests?|fixtures)/).*\.(md|adoc|rst)$'
  $idx = @(git -C $top ls-files -s 2>$null | Where-Object { ($_ -split "`t", 2)[1] -notmatch $doc }); if ($LASTEXITCODE) { return $null }
  $chg = @(git -C $top -c core.quotePath=false status --porcelain --untracked-files=all 2>$null | ForEach-Object { $_.Substring(3) -replace '^.* -> ', '' -replace '^"|"$', '' -replace '\\(["\\])', '$1' } | Where-Object { $_ -notmatch $doc } | Sort-Object -Unique)
  if ($LASTEXITCODE -or @($chg | Where-Object { Test-Path -LiteralPath (Join-Path $top $_) -PathType Container }).Count) { return $null }
  $files = @($chg | Where-Object { Test-Path -LiteralPath (Join-Path $top $_) -PathType Leaf })
  $blobs = if ($files.Count) { @($files | git -C $top hash-object --stdin-paths 2>$null) } else { @() }   # stdin: no command-line limit
  if ($LASTEXITCODE -or $blobs.Count -ne $files.Count) { return $null }
  (Get-KitHash ((@($idx) + '--' + @($chg) + '--' + @($blobs)) -join "`n") SHA1).ToLower()
}
function Get-CheckStampFile([string]$Dir) { Join-Path (Get-KitPath check-stamps -Create) "$((Get-KitHash ([IO.Path]::GetFullPath($Dir).TrimEnd('\', '/').ToLower()) MD5).Substring(0, 16)).json" }
function Read-CheckStamps([string]$Dir) { $h = try { Read-KitText (Get-CheckStampFile $Dir) | ConvertFrom-Json -AsHashtable } catch { $null }; if ($h -is [hashtable]) { $h } else { @{} } }
# the sources' key once per check run, before it runs ($script:CheckSrcKey, reset by Invoke-Check); its last run of $Slot on that key:
# -1 none (run it) · 0 passed (say so, skip) · rc it failed with: refused, its failures reprinted (2026-11-25: 217 of 841 gated builds
# failed, agents reran unchanged trees to grep the output again); -Force reruns either
function Test-CheckStamp([string]$Dir, [string]$Slot, [switch]$Force) {
  if ($null -eq $script:CheckSrcKey) { $script:CheckSrcKey = "$(Get-CheckSourceKey $Dir)" }
  $was = if ($script:CheckSrcKey -and -not $Force) { (Read-CheckStamps $Dir)[$Slot] }
  if (-not $was -or "$($was.key)" -ne $script:CheckSrcKey) { return -1 }
  $s = ($Slot -split '\|')[0]; $hm = ([datetime]$was.at).ToString('HH:mm')
  if (-not [int]$was.rc) { Write-Host "[check] $s ok: passed on these sources at $hm, not rerun (-Force reruns)"; return 0 }
  foreach ($l in @($was.sum)) { Write-Host $l }
  Write-Host "[check] $s FAILED on these unchanged sources at $hm (exit $($was.rc)): not rerun; full log $($was.log). Change the code, or -Force after an env fix (a jar, a service, a flaky test)"
  [int]$was.rc
}
function Save-CheckStamp([string]$Dir, [string]$Slot, [int]$Rc = 0, [string]$Log = '', [string[]]$Sum = @()) {   # the newest 30 slots per dir
  if ($null -eq $script:CheckSrcKey) { $script:CheckSrcKey = "$(Get-CheckSourceKey $Dir)" }
  if (-not $script:CheckSrcKey) { return }
  # an edit during the run: the result belongs to neither tree (agents edited while their build ran)
  if ("$(Get-CheckSourceKey $Dir)" -ne $script:CheckSrcKey) { Write-Host "[check] sources changed during the run: result not kept; rerun when your edits are done"; return }
  $h = Read-CheckStamps $Dir; $h[$Slot] = if ($Rc) { @{ key = $script:CheckSrcKey; at = (Get-KitStamp); rc = $Rc; log = $Log; sum = @($Sum) } } else { @{ key = $script:CheckSrcKey; at = (Get-KitStamp) } }
  $keep = [ordered]@{}; foreach ($kv in @($h.GetEnumerator() | Sort-Object { "$($_.Value.at)" } -Descending | Select-Object -First 30)) { $keep[$kv.Key] = $kv.Value }
  Write-KitAtomic (Get-CheckStampFile $Dir) ($keep | ConvertTo-Json -Depth 4)
}
# ---- ci runs: tests.ciRuns = "<repo>/<module>" globs whose MR pipeline runs the full build + suite (check skips them locally)
function Exit-KitCiRuns {   # in crafty.ps1 check: its $Step, $Tests, $AllTests, $Force, $Show, $st, Get-CheckRepo, ConvertTo-GlobRx
  if ($Force -or $Show -or -not ($Step -eq 'build' -or ($Step -eq 'test' -and $AllTests -and -not $Tests -and -not $Touched))) { return }
  $Repo = Get-CheckRepo; if (-not $Repo.top) { return }
  $key = "$(if ($Repo.conf.name) { $Repo.conf.name } else { Split-Path "$($Repo.top)" -Leaf })/$([IO.Path]::GetRelativePath("$($Repo.top)", $st.dir).Replace('\', '/'))".TrimEnd('/', '.')
  foreach ($g in @(Get-KitSetting 'tests.ciRuns' @()) | Where-Object { $_ }) { if ($key -match (ConvertTo-GlobRx $g)) { Write-Host "[check] $Step left to CI: $key matches tests.ciRuns '$g'; before a push: check + -Step test -Tests <names> -Touched; -Force runs it here"; exit 0 } }
}

# ---- run digest: what a gated run prints (crafty.ps1 gate -Log, check)
# a gated run's log -> what an agent reads (owner 2026-11-22: 60 agents pasted whole build / test logs): a short log whole; else the
# failure lines (+ the next 2 lines each) up to check.printLines, the last 10 lines (the summary), the log path
function Write-KitRunDigest([string]$Path, [int]$Code) {
  $ls = @(try { Get-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop } catch { })
  $cap = [int](Get-KitParam 'check.printLines')
  if ($ls.Count -le $cap) { foreach ($l in $ls) { Write-Host $l }; if ($Code) { foreach ($l in @(Get-KitRunFailures $ls)) { Write-Host $l } }; return }
  $tail = 10; $keep = [Collections.Generic.SortedSet[int]]::new()
  if ($Code) {
    $rx = '(?i)\b(error|errors|fail(ed|ure|ures|ing)?|exception|assert\w*|traceback|panic|fatal|expected|not ok)\b|^\s*[✗×✖]|(?-i:^E\s)'
    for ($i = 0; $i -lt $ls.Count - $tail -and $keep.Count -lt $cap - $tail; $i++) { if ($ls[$i] -match $rx -and $ls[$i] -notmatch $script:KitDigestNoise) { for ($j = $i; $j -le [math]::Min($i + 2, $ls.Count - $tail - 1); $j++) { $null = $keep.Add($j) } } }
  }
  $prev = -1; foreach ($i in $keep) { if ($prev -ge 0 -and $i -gt $prev + 1) { Write-Host '  ...' }; Write-Host $ls[$i]; $prev = $i }
  if ($keep.Count) { Write-Host '  ...' }
  foreach ($l in @($ls | Select-Object -Last $tail)) { Write-Host $l }
  Write-Host "[gate] $($ls.Count) lines, $(if ($Code) { "$($keep.Count) failure line(s) and " })the last $tail shown; the full log: $Path (read a range: never the whole file)"
  if ($Code) { foreach ($l in @(Get-KitRunFailures $ls)) { Write-Host $l } }   # last: an agent's | tail -N still sees them
}
# no failure signal: zero counts ("Failures: 0, Errors: 0") and build-tool warnings filled the digest's 60 lines
$script:KitDigestNoise = '(?i)\b(Failures|failed): 0\b.*\bErrors?: 0\b|^\s*\[WARN(ING)?\]'
# a failed run's first causes, compile errors before test failures, each cut to 200 chars: "[gate] first failures:" + up to 8 lines
function Get-KitRunFailures([string[]]$Lines) {
  $cmp = '(?i)(\.(java|kt|scala|cs|ts|tsx|py|go|rs)[:(\[]\s*\d+.*\b(error|cannot find symbol|does not exist|incompatible)\b|\berror (TS|CS)\d+\b|COMPILATION ERROR|\bSyntaxError\b|\bcannot find symbol\b)'
  $tst = '(?i)(Tests run:.*(Failures: [1-9]|Errors: [1-9])|<<< (FAIL|ERROR)|^\s*(FAIL|FAILED|not ok)\b|^\s*●|AssertionError|\bexpected\b.*\b(but|to (be|equal))\b|(?-i:^E\s))'
  $got = @(@($Lines | Where-Object { $_ -match $cmp }) + @($Lines | Where-Object { $_ -match $tst -and $_ -notmatch $cmp -and $_ -notmatch $script:KitDigestNoise }) | ForEach-Object { $t = "$_".Trim(); if ($t.Length -gt 200) { $t.Substring(0, 200) + ' …' } else { $t } } | Select-Object -Unique -First 8)
  if ($got.Count) { @('[gate] first failures:') + @($got | ForEach-Object { "  $_" }) }
}
