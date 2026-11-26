#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (crafty.ps1 check exits).
# Sections: L4 check builds · L14 check stamps · L55 main skip · L96 ci runs · L104 run digest
# ---- check builds: a clean tree's build, keyed by its tree: envy deploys of the same code stage its artifact (envy Find-CheckBuild)
function Save-CheckBuild([string]$Dir, [string]$Cmd, [datetime]$Start) {
  Save-KitMainKey
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
function Get-CheckSourceKey([string]$Dir, [string]$Skip = '') {   # -Skip <regex>: those paths aside too (Get-KitMainSkip: test sources)
  $top = "$(git -C $Dir rev-parse --show-toplevel 2>$null)".Trim(); if (-not $top) { return $null }
  $doc = '^(?!(.*/)?(src|resources|assets|tests?|fixtures)/).*\.(md|adoc|rst)$'; if ($Skip) { $doc = "$doc|$Skip" }
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
  $Slot = Get-KitMainSlot $Slot
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
  $Slot = Get-KitMainSlot $Slot; Save-KitMainKey $Rc $Log
  if ($null -eq $script:CheckSrcKey) { $script:CheckSrcKey = "$(Get-CheckSourceKey $Dir)" }
  if (-not $script:CheckSrcKey) { return }
  # an edit during the run: the result belongs to neither tree (agents edited while their build ran)
  if ("$(Get-CheckSourceKey $Dir)" -ne $script:CheckSrcKey) { Write-Host "[check] sources changed during the run: result not kept; rerun when your edits are done"; return }
  $h = Read-CheckStamps $Dir; $h[$Slot] = if ($Rc) { @{ key = $script:CheckSrcKey; at = (Get-KitStamp); rc = $Rc; log = $Log; sum = @($Sum) } } else { @{ key = $script:CheckSrcKey; at = (Get-KitStamp) } }
  $keep = [ordered]@{}; foreach ($kv in @($h.GetEnumerator() | Sort-Object { "$($_.Value.at)" } -Descending | Select-Object -First 30)) { $keep[$kv.Key] = $kv.Value }
  Write-KitAtomic (Get-CheckStampFile $Dir) ($keep | ConvertTo-Json -Depth 4)
}
# ---- main skip: a Maven step whose non-test inputs are the ones its target/classes were compiled from gets -Dmaven.main.skip=true
# (2026-11-26: a no-change `mvn compile` rewrote 8940 classes + 4289 generated files in 111 s, a generator plugin re-stamps its
# sources each run; 245 test steps a day, ~2 MB of NTFS metadata per MB written to target/). <module>/target/kit-main.key (a clean
# drops it) holds 2 lines: the key (every tracked, changed and untracked file of the repo outside test folders + the command's
# profiles / compiler flags + JAVA_HOME) and the compile mark (the compiler plugin's own lists: any compile, here or by hand,
# rewrites them). Both must match; a run that will compile drops the file first, so only a finished compile records it again.
# Never: -Force, an own -pl / -f / clean, a command with no compiling phase. A dependency jar replaced under an unchanged repo: -Force.
$script:KitMainTestRx = '(^|/)src/(test|it|integration-test)/|^(?!(.*/)?src/main/)(.*/)?(cypress|e2e)/'
function Get-KitMainMark([string]$Dir) {
  $d = Join-Path $Dir 'target/maven-status/maven-compiler-plugin/compile/default-compile'
  @('inputFiles.lst', 'createdFiles.lst' | ForEach-Object { $f = Get-Item -LiteralPath (Join-Path $d $_) -ErrorAction SilentlyContinue; if ($f) { $f.LastWriteTimeUtc.Ticks } }) -join ','
}
function Get-KitMainSkip([string]$Dir, [string]$Cmd, [switch]$Force) {
  $script:KitMainSkip = $null
  if ($Cmd -notmatch '\b(mvn|mvnw|mvnd)(\.cmd)?\b' -or -not (Test-Path -LiteralPath (Join-Path $Dir 'pom.xml'))) { return '' }
  if ($Cmd -notmatch '(^|\s)(compile|test-compile|test|package|integration-test|verify|install|deploy|clean)(\s|$)') { return '' }   # validate, a plugin goal: compiles nothing, records nothing
  $file = Join-Path $Dir 'target/kit-main.key'; $drop = { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; '' }   # this run may rewrite target/classes
  if ($Cmd -match '(^|\s)(-pl|--projects|-f|--file|clean)(\s|=|$)|maven\.main\.skip') { return (& $drop) }
  $key = "$(Get-CheckSourceKey $Dir $script:KitMainTestRx)"; if (-not $key) { return (& $drop) }
  $key = "$key $(@([regex]::Matches($Cmd, '(?<=\s)-(P|Dmaven\.compiler|Djava\.version)\S*').Value | Sort-Object) -join ',') $env:JAVA_HOME".Trim()
  $script:KitMainSkip = @{ dir = $Dir; file = $file; key = $key; skipped = $false }
  $was = @(if (-not $Force -and (Test-Path -LiteralPath (Join-Path $Dir 'target/classes') -PathType Container)) { Get-Content -LiteralPath $file -TotalCount 2 -ErrorAction SilentlyContinue })
  if ("$($was[0])".Trim() -ne $key -or "$($was[1])".Trim() -ne (Get-KitMainMark $Dir)) { return (& $drop) }
  $script:KitMainSkip.skipped = $true; '-Dmaven.main.skip=true'
}
# after the step: a run that compiled main (exit 0, or its tests ran) records key + mark; main sources edited during it: no record;
# edited while a skipped step ran (the gate queue): its result is of the old classes, said so, the key dropped
function Save-KitMainKey([int]$Rc = 0, [string]$Log = '') {
  $m = $script:KitMainSkip; $script:KitMainSkip = $null; if (-not $m) { return }
  $now = "$(Get-CheckSourceKey $m.dir $script:KitMainTestRx)"; $same = $now -and $m.key.StartsWith($now)
  if ($m.skipped) { if (-not $same) { Remove-Item -LiteralPath $m.file -Force -ErrorAction SilentlyContinue; Write-Host '[check] main sources changed while this step ran without a main compile: its result is of the old classes; rerun' }; return }
  if ($Rc -and -not ($Log -and (Select-String -LiteralPath $Log -Pattern 'Tests run: \d' -Quiet -ErrorAction SilentlyContinue))) { return }
  if (-not $same -or -not (Test-Path -LiteralPath (Join-Path $m.dir 'target/classes') -PathType Container)) { return }
  Set-Content -LiteralPath $m.file @($m.key, (Get-KitMainMark $m.dir)) -Encoding ascii
}
# a skipped step keeps the stamp slot of its command without the flag (crafty.ps1 hashes the command it runs: Invoke-Check's $cmd),
# so an unchanged rerun is still refused / skipped by its last result
function Get-KitMainSlot([string]$Slot) {
  $c = "$(Get-Variable cmd -ValueOnly -ErrorAction SilentlyContinue)"; $fl = ' -Dmaven.main.skip=true'
  if ($Slot -and $c.Contains($fl) -and (Get-Command Hash12 -ErrorAction SilentlyContinue)) { "$(($Slot -split '\|')[0])|$(Hash12 $c.Replace($fl, ''))" } else { $Slot }
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
  # matched on whole lines, printed cut to 200 chars like the first failures (60 long stack / bundle lines pasted 3-4k tokens, 2026-11-25)
  $ls = @(try { Get-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop } catch { }); $cut = { param($x) if ("$x".Length -gt 200) { "$x".Substring(0, 200) + ' …' } else { "$x" } }
  $cap = [int](Get-KitParam 'check.printLines')
  if ($ls.Count -le $cap) { foreach ($l in $ls) { Write-Host (& $cut $l) }; if ($Code) { foreach ($l in @(Get-KitRunFailures $ls)) { Write-Host $l } }; return }
  $tail = 10; $keep = [Collections.Generic.SortedSet[int]]::new()
  if ($Code) {
    $rx = '(?i)\b(error|errors|fail(ed|ure|ures|ing)?|exception|assert\w*|traceback|panic|fatal|expected|not ok)\b|^\s*[✗×✖]|(?-i:^E\s)'
    for ($i = 0; $i -lt $ls.Count - $tail -and $keep.Count -lt $cap - $tail; $i++) { if ($ls[$i] -match $rx -and $ls[$i] -notmatch $script:KitDigestNoise) { for ($j = $i; $j -le [math]::Min($i + 2, $ls.Count - $tail - 1); $j++) { $null = $keep.Add($j) } } }
  }
  $prev = -1; foreach ($i in $keep) { if ($prev -ge 0 -and $i -gt $prev + 1) { Write-Host '  ...' }; Write-Host (& $cut $ls[$i]); $prev = $i }
  if ($keep.Count) { Write-Host '  ...' }
  foreach ($l in @($ls | Select-Object -Last $tail)) { Write-Host (& $cut $l) }
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
