<#
kit_admin.ps1: kitty's tools in bossy.ps1, dot-sourced by bossy.ps1 (adapters/):
  prepush · precommit                       the kit's git hooks (.githooks)
  learn -Stats | -History [-Grep] [-Last]   signals since the last retro, retired lessons
  learn -Skill <s> -When <w> -Do <d> -Why <y> (or -Lesson "<when> -> <do> (<why>)") [-Project <p>] | -Bump <words> [-Append] | -Fixed <words> | -Trim [-Max 40]
  health: the weekly kitty audit nudge (Get-KitHealthLinesAudit)
Learn record, -Read and -Show stay in core.
Sections: L12 learn · L102 health · L111 prepush · L194 nightly tests · L212 precommit
Exit codes: 0 ok · 1 blocked (prepush, precommit) / -Bump or -Fixed matched not exactly one lesson · 2 usage.
#>
#Requires -Version 7
# ---- learn: lesson tools, -Stats, -History
function Invoke-LearnAdmin {
  param(
    [string]$Skill, [string]$Kind, [string]$Text, [string]$Ref, [string]$Source,
    [switch]$Show, [int]$Last = 30, [switch]$Stats, [switch]$Read, [switch]$History, [string]$Grep,
    [string]$Lesson, [string]$When, [string]$Do, [string]$Why, [string]$Project, [string]$Fixed, [string]$Bump, [string]$Append, [switch]$Trim, [int]$Max = 40
  )
  $file = Get-KitPath signals -Create
  if ($When -or $Do -or $Why) { if (-not ($When -and $Do -and $Why)) { 'learn: -When, -Do and -Why together'; exit 2 }; $Lesson = "$($When.Trim()) -> $($Do.Trim().TrimEnd('.')) ($($Why.Trim().Trim('()')))" }   # LESSONS.md shape
  if ($Lesson -and ("- $($Lesson.Trim() -replace '^-\s*')" -notmatch '^- \S.*? -> \S.*\((?!\d+[x×]\)).+?\)')) { 'learn: a lesson is "<when> -> <do> (<why>)": -When -Do -Why render it'; exit 2 }
  if ($Lesson -and @(Test-KitProse lesson "- $($Lesson.Trim() -replace '^-\s*')" -WarnSkip).Count) { 'learn: lesson refused: over the templates.md "Writing standards" lesson cap (warning above); shorten it'; exit 2 }   # lint would flag it after the write
  $pub = Join-Path $KitConf.Kit 'LESSONS.md'; $loc = Join-Path $KitConf.Kit 'LESSONS.local.md'
  if ($Stats) {
    $since = Get-KitRetroSince
    $all = if (Test-Path $file) { @(Get-Content $file | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [datetime]$_.at -gt $since -and $_.kind -ne 'retired' }) } else { @() }
    "signals since last retro ($(if ($since -eq [datetime]::MinValue) { 'never' } else { $since.ToString('yyyy-MM-dd HH:mm') })): $($all.Count)"
    $all | Group-Object skill, kind | Sort-Object Count -Descending | ForEach-Object { '  {0,3}  {1}' -f $_.Count, $_.Name }
    return
  }
  if ($History) {
    $now = (@($pub, $loc) | Where-Object { Test-Path $_ } | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n"
    $key = { param($s) ($s -replace '^-\s*', '' -replace '\(fixed in kit\)\s*', '' -replace '\s*\(\d+×\)', '').Trim() }
    $seen = @{}; $rows = [Collections.Generic.List[string]]::new(); $meta = ''
    foreach ($gl in @(git -C $KitConf.Kit log --no-merges --date=short '--format=KITLOG %ad %h' -p --unified=0 -- LESSONS.md 2>$null)) {
      if ($gl -like 'KITLOG *') { $meta = $gl.Substring(7); continue }
      if ($gl -notmatch '^-- ') { continue }
      $s = $gl.Substring(1); $k0 = & $key $s
      if (-not $k0 -or $seen[$k0] -or $now.Contains($k0)) { continue }
      $seen[$k0] = 1; $rows.Add("$meta $s")
    }
    if (Test-Path $file) { foreach ($j in @(Get-Content $file | Where-Object { $_ -match '"kind":"retired"' } | ForEach-Object { $_ | ConvertFrom-Json })) { $k0 = & $key $j.text; if (-not $seen[$k0]) { $seen[$k0] = 1; $rows.Insert(0, "$(([datetime]$j.at).ToString('yyyy-MM-dd')) $($j.skill) $($j.text)") } } }
    $h = @(if (Test-Path $loc) { $L = Read-KitLessonLines $loc; $r = Find-KitLessonSection $L 'History'; if ($r) { $L[$r[0]..($r[1] - 1)] | Where-Object { $_ -match '^- ' } } })
    $all = @(@($rows) + $h | Where-Object { -not $Grep -or $_ -match [regex]::Escape($Grep) } | Select-Object -First $Last)
    if ($all.Count) { $all } else { 'no retired lessons' }
    return
  }
  if (-not $Skill) { 'need -Skill <skill> with -Lesson / -Bump / -Fixed / -Trim'; exit 2 }
  $terms = @(Get-KitValue 'orgTerms' @()) | Where-Object { $_ -and $_ -notmatch '^<' }
  $key = if ($Bump) { $Bump } elseif ($Fixed) { $Fixed } else { $null }
  $orgWord = $Lesson -and @($terms | Where-Object { $Lesson -match [regex]::Escape($_) }).Count
  $inLocal = $key -and (Test-Path $loc) -and ([IO.File]::ReadAllText($loc)).Contains($key) -and -not ([IO.File]::ReadAllText($pub)).Contains($key)
  $f = if ($Project -or $orgWord -or $inLocal) { $loc } else { $pub }
  if ($f -eq $loc -and -not (Test-Path $loc)) { [IO.File]::WriteAllText($loc, "# Kit lessons - org / project (LOCAL ONLY, never published)`nShape of LESSONS.md; learn -Read prints both.`n") }
  if ($orgWord -and -not $Project) { "org term: written to LESSONS.local.md" }
  # concurrent learners lost lines
  $script:learnRc = 0
  $sigF = $file   # $file inside would be Invoke-KitLocked's -File (case-insensitive)
  Invoke-KitLocked $f {
    $L = Read-KitLessonLines $f; while ($L.Count -and $L[$L.Count - 1] -eq '') { $L.RemoveAt($L.Count - 1) }
    $r = Find-KitLessonSection $L $Skill
    if (-not $r) { $h = $L.IndexOf('## History'); $at = if ($h -ge 0) { $h } else { $L.Count }; $L.Insert($at, ''); $L.Insert($at, "## $Skill"); $r = Find-KitLessonSection $L $Skill }
    $moved = [Collections.Generic.List[string]]::new()
    $idx = { @($r[0]..($r[1] - 1) | Where-Object { $L[$_] -match '^- ' }) }
    if ($Lesson) {
      $line = '- ' + ($Lesson.Trim() -replace '^-\s*', '')
      if ($Project) {
        $ph = "### Project: $Project"; $p = -1; for ($i = $r[0]; $i -lt $r[1]; $i++) { if ($L[$i] -eq $ph) { $p = $i } }
        if ($p -lt 0) { $L.Insert($r[1], $line); $L.Insert($r[1], $ph) } else { $L.Insert($p + 1, $line) }
      } else { $L.Insert($r[0] + 1, $line) }
      $r = Find-KitLessonSection $L $Skill
      "lesson added to $(Split-Path $f -Leaf) ## $Skill"
    }
    if ($Bump) {
      $hit = @(& $idx | Where-Object { $L[$_].Contains($Bump) })
      if ($hit.Count -ne 1) { "-Bump must match exactly one lesson line of ## $Skill (matched $($hit.Count))"; $script:learnRc = 1; return }
      $s = $L[$hit[0]]
      if ($Append) { $c = $Append.Trim().TrimEnd('.'); $s = if ($s -match '^(.*?)\.?(\s*\(\d+[x×]\))$') { "$($Matches[1]). $c.$($Matches[2])" } else { "$($s.TrimEnd('.')). $c." } }
      $m = [regex]::Match($s, '\((\d+)[x×]\)')   # lessons are written with an ASCII x too: "(1x)" became "(1x) (2×)"
      $L[$hit[0]] = if ($m.Success) { $s.Remove($m.Index, $m.Length).Insert($m.Index, "($([int]$m.Groups[1].Value + 1)×)") } else { "$s (2×)" }
      "lesson bumped in ## $Skill"
    }
    if ($Fixed) {
      $hit = @(& $idx | Where-Object { $L[$_].Contains($Fixed) })
      if ($hit.Count -ne 1) { "-Fixed must match exactly one lesson line of ## $Skill (matched $($hit.Count))"; $script:learnRc = 1; return }
      $moved.Add(($L[$hit[0]] -replace '^- (\(fixed in kit\) )?', '- (fixed in kit) ')); $L.RemoveAt($hit[0]); $r = Find-KitLessonSection $L $Skill
    }
    # "### Project:" lines stay
    while (@(& $idx).Count -gt $Max) {
      $gen = @(& $idx | Where-Object { $i = $_; -not @($r[0]..$i | Where-Object { $L[$_] -like '### *' }).Count })
      $i = if ($gen.Count) { $gen[-1] } else { @(& $idx)[-1] }
      $moved.Add($L[$i]); $L.RemoveAt($i); $r = Find-KitLessonSection $L $Skill
    }
    [IO.File]::WriteAllText($f, (($L -join "`n") + "`n"))
    if ($moved.Count) {
      $at = (Get-Date).ToString('s'); foreach ($x in $moved) { Write-KitLog signals '' ([ordered]@{ at = $at; skill = $Skill; kind = 'retired'; text = $x; ref = $(if ($Fixed) { 'fixed' } else { 'trim' }); source = 'learn' }) }
    }
    "$(Split-Path $f -Leaf) ## ${Skill}: $(@(& $idx).Count) lines (max $Max)$(if ($moved.Count) { "; retired $($moved.Count) (learn -History lists them)" })"
  }
  if ($script:learnRc) { exit $script:learnRc }
}
# ---- health: the weekly audit nudge
# health: the weekly kitty audit nudge (kitAudit.everyDays, default 7; 0 = off), quiet while a kitty works
function Get-KitHealthLinesAudit {
  $every = [double](Get-KitSetting 'kitAudit.everyDays' 7); if ($every -le 0) { return }
  $am = Get-KitPath last-kitty-audit; $last = $null; if (Test-Path $am) { try { $last = [datetime]((Get-Content $am -Raw).Trim()) } catch {} }
  if ($last -and ((Get-Date) - $last).TotalDays -lt $every) { return }
  $busy = @(Read-KitJsonFiles (Get-KitPath board) | Where-Object { $_.agent -eq 'kitty' -and $_.status -ne 'left' -and ((Get-Date) - [datetime]$_.beat).TotalMinutes -lt 60 }).Count
  if (-not $busy) { "Kit audit due (last $(if ($last) { $last.ToString('yyyy-MM-dd') } else { 'never' }), every $every days): spawn one kitty agent (bossy E13)." }
}
# ---- prepush: local files, org terms, ports, full tests to main
# the kit's git pre-push hook (.githooks/pre-push): blocks local files, org terms, a failing full test run to main; warns on stale ports
function Invoke-PrePush {
$ErrorActionPreference = 'Stop'
$root = $KitConf.Kit
$zero = '0' * 40
$updates = @($(if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { '' }) -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $p = $_ -split '\s+'; [pscustomobject]@{ lsha = $p[1]; rref = $p[2]; rsha = $p[3] } } | Where-Object { $_.lsha -ne $zero })
$hits = @()

$revs = foreach ($u in $updates) { if ($u.rsha -eq $zero) { git -C $root rev-list $u.lsha --not --remotes } else { git -C $root rev-list "$($u.rsha)..$($u.lsha)" } }
$revs = @($revs | Where-Object { $_ } | Select-Object -Unique)

if ($revs.Count) {
  $files = @($revs | ForEach-Object { git -C $root diff-tree --no-commit-id --name-only --diff-filter=ACMR -r $_ } | Where-Object { $_ } | Select-Object -Unique)
  if ($files.Count) {
    # pwsh piping appends CR
    $ign = @(for ($i = 0; $i -lt $files.Count; $i += 100) { git -C $root check-ignore --no-index -- @($files[$i..([math]::Min($i + 99, $files.Count - 1))]) 2>$null })
    # old `# kitbag <kind> <name>` exclude blocks list files the kit now tracks (kitbag.py migrate drops them after the pull)
    $xb = @(); $xn = ''; foreach ($l in @(Get-Content -LiteralPath (git -C $root rev-parse --path-format=absolute --git-path info/exclude) -ErrorAction SilentlyContinue)) {
      if ($l -match '^# kitbag \S+ (.+)$') { $xn = $Matches[1].Trim(); if ($xn -eq 'end') { $xn = '' } } elseif (-not $l.Trim()) { $xn = '' }
      elseif ($xn) { $xb += $l.Trim().TrimStart('/') } }
    $ign = @($ign | Where-Object { $_ -notin $xb })
    foreach ($f in $ign) { $hits += "LOCAL FILE  $f is git-ignored or local-only (.gitignore / .git/info/exclude) but a pushed commit carries it: git rm --cached it and amend" }
  }
}

$terms = @()
$cfg = $KitConf.ConfigFile
if ($env:KIT_ORG_TERMS) { $terms = @($env:KIT_ORG_TERMS -split ',' | Where-Object { $_.Trim() }) }
elseif (Test-Path $cfg) { try { $terms = @((Get-Content $cfg -Raw | ConvertFrom-Json).orgTerms | Where-Object { $_ }) } catch { $hits += "CONFIG      $cfg is not valid JSON: $_" } }
if (-not $terms.Count) { Write-Host 'pre-push: no orgTerms in skills/crafty/kit.local.json - org-term scan skipped' }
else {
  $py = if (Get-Command (Get-Python) -ErrorAction SilentlyContinue) { Get-Python }
  if (-not $py) { $hits += 'PYTHON      python is not installed: the org-term scan (kitbag.py lint) cannot run' }
  else {
    $out = Join-Path (Get-KitTemp) "kit-prepush-$PID.json"
    & $py -X utf8 $KitCmd.kitbag lint $root --warn --no-flow --org-terms ($terms -join ',') --json $out | Out-Null
    if (-not (Test-Path $out)) { $hits += "LINT        kitbag.py lint failed (exit $LASTEXITCODE, no JSON): the org-term scan of the working tree did not run" }
    $probs = @(if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json }); Remove-Item $out -Force -ErrorAction SilentlyContinue
    foreach ($p in $probs | Where-Object code -eq 'ORG-TERM') { $hits += "ORG TERM    $($p.where): $($p.problem)" }
    $other = @($probs | Where-Object code -ne 'ORG-TERM')
    if ($other.Count) { Write-Host "pre-push: warning: kit-lint reports $($other.Count) other problem(s) (python skills/bossy/kitbag.py lint)" }
  }
  $rx = @($terms | ForEach-Object { $t = $_.Trim(); $stem = $t.TrimEnd('*'); [pscustomobject]@{ term = $t; rx = [regex]::new('(?<![\w-])' + [regex]::Escape($stem) + $(if ($t.EndsWith('*')) { '' } else { '(?![\w-])' }), $(if ($stem -cne $stem.ToLower()) { 'None' } else { 'IgnoreCase' })) } })
  foreach ($r in $revs) {
    foreach ($line in @(git -C $root show --format= --unified=0 --no-color $r)) {
      if (-not $line.StartsWith('+') -or $line.StartsWith('+++')) { continue }
      foreach ($x in $rx) { if ($x.rx.IsMatch($line)) { $hits += "ORG TERM    commit $($r.Substring(0, 8)) adds ""$($x.term)"": $($line.Substring(0, [math]::Min(120, $line.Length)))"; break } }
    }
  }
}

$py = Get-Python
if (Get-Command $py -ErrorAction SilentlyContinue) { $pc = & $py -X utf8 $KitCmd.kitbag port --check 2>&1; if ($LASTEXITCODE -eq 1) { Write-Host "pre-push: warning: ports differ (optional; run kitbag.py port if deploying to codex/gemini)" } }   # 2: kitbag.py port is unavailable

# a push to main: the full kit tests on the pushed tree (a tree a green full run stamped: skipped; inside a test run: never)
$kt = Join-Path $root 'tests/kit-tests.ps1'; $toMain = @($updates | Where-Object { $_.rref -eq 'refs/heads/main' })
if ($toMain.Count -and (Test-Path $kt) -and -not $env:KIT_TESTS_SNAPSHOT) {
  $tree = "$(git -C $root rev-parse "$($toMain[-1].lsha)^{tree}" 2>$null)".Trim()
  $pm = (Get-Content -LiteralPath (Join-Path $root 'skills/crafty/kit.example.json') -Raw | ConvertFrom-Json)._paths   # where kit-tests.ps1 stamps (this checkout's runtime, never CLAUDE_RUNTIME)
  $green = @(Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $root $pm.runtimeDir) $pm.runtime.cache) 'kit-tests-green.txt') -ErrorAction SilentlyContinue)
  if ($tree -in $green) { Write-Host "pre-push: kit tests: tree $($tree.Substring(0, 8)) already green in a full run" }
  elseif ($tree -ne "$(git -C $root rev-parse 'HEAD^{tree}' 2>$null)".Trim() -or (git -C $root status --porcelain 2>$null)) { $hits += "TESTS       the pushed commit is not this clean checkout: commit everything, run tests/kit-tests.ps1 -Full, push again" }
  else {
    $tl = Join-Path (Get-KitPath logs -Create) 'kit-tests-prepush.txt'; Write-Host "pre-push: kit tests -Full on tree $($tree.Substring(0, 8)) (a few minutes; log $tl)"
    Remove-Item Env:GIT_DIR, Env:GIT_INDEX_FILE, Env:GIT_WORK_TREE -ErrorAction SilentlyContinue   # the hook's git env would point every test repo at this one
    $tp = Start-Process (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source -ArgumentList '-NoProfile', '-NonInteractive', '-File', "`"$kt`"", '-Full' -RedirectStandardOutput $tl -RedirectStandardError "$tl.err" -NoNewWindow -PassThru; $null = $tp.Handle   # the handle kept: ExitCode stays readable
    if (-not $tp.WaitForExit(1800000)) { Stop-KitProcessTree $tp; $hits += "TESTS       the full kit run passed 30 min: stopped (log $tl)" }
    else {
      $sum = @(Get-Content -LiteralPath $tl | Select-String -Pattern '^(Failed checks:|  \[|TEST-DUP|TEST-WRITE|\d+ failure\(s\) in)' | ForEach-Object Line)
      $sum | ForEach-Object { Write-Host "  $_" }; if ($tp.ExitCode) { $hits += "TESTS       the full kit run failed (exit $($tp.ExitCode)): $tl" } }
  }
}

if ($hits.Count) {
  Write-Host "pre-push: BLOCKED - $($hits.Count) problem(s):" -ForegroundColor Red
  $hits | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
  Write-Host 'Fix them (the kit is public and generic: org values belong in *.local.* files or localOnly paths), then push again.'
  exit 1
}
exit 0
}

# ---- nightly tests: one full kit test run a day while nothing runs (supervise -AutoFix); its FAILs returned once
function Invoke-KitNightlyTests([bool]$Idle) {
  $kt = Join-Path $KitConf.Kit 'tests/kit-tests.ps1'; if ($env:KIT_TESTS_SNAPSHOT -or -not (Test-Path -LiteralPath $kt)) { return }   # inside a test run: never
  $sf = Join-Path (Get-KitPath cache -Create) 'kit-tests-nightly.json'; $lf = Join-Path (Get-KitPath logs -Create) 'kit-tests-nightly.txt'
  $s = try { Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json } catch { $null }
  if ($s -and -not $s.read -and -not (Test-KitPid $s.pid $s.start)) {   # finished since the last beat: read once
    $s | Add-Member -Force NoteProperty read $true; Write-KitAtomic $sf ($s | ConvertTo-Json -Compress)
    $tail = @(Get-Content -LiteralPath $lf -ErrorAction SilentlyContinue | Select-String -Pattern '^(\d+) failure\(s\) in' | ForEach-Object Line)[-1]
    if (-not $tail -or $tail -notmatch '^0 failure') { "kit tests nightly: $(if ($tail) { $tail } else { 'no total (crashed)' }), $(@(Get-Content -LiteralPath $lf | Select-String -Pattern '^  \[').Count) failed check(s): $lf" }
  }
  if (-not $Idle -or ($s -and ((Get-Date) - [datetime]$s.at).TotalHours -lt 20) -or ($s -and (Test-KitPid $s.pid $s.start))) { return }
  $exe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source; $cmd = "& '$($kt.Replace("'", "''"))' -Full *> '$($lf.Replace("'", "''"))'"
  $st = @{ at = (Get-Date).ToString('o'); read = $false }
  try { $p = if ($KitIsWindows) { Start-Process $exe -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $cmd -WindowStyle Hidden -PassThru } else { Start-Process $exe -ArgumentList '-NoProfile', '-NonInteractive', '-Command', $cmd -PassThru }; $st.pid = $p.Id; $st.start = $p.StartTime.ToString('o') }
  catch { $st.read = $true; "kit tests nightly: the run did not start ($($_.Exception.Message)); next try in 20 h" }   # stamped: no retry every beat
  Write-KitAtomic $sf ($st | ConvertTo-Json -Compress)
}

# ---- precommit: graph, ports, section maps, lint
# the kit's git pre-commit hook (.githooks/pre-commit): regenerates + stages the README graph, section maps and ports, runs lint
# never stage the user's changes
function Test-UnstagedEdits([string]$Root, [string]$Path) { [bool]@(git -C $Root status --porcelain -- $Path | Where-Object { $_.Length -gt 1 -and $_[1] -ne ' ' }).Count }
function Invoke-PreCommit {
  $root = $KitConf.Kit
  $py = Get-Python
  if (-not $py -or -not (Get-Command $py -ErrorAction SilentlyContinue)) { Write-Host 'pre-commit: BLOCKED - python is not installed (kitbag lint / flow cannot run)' -ForegroundColor Red; exit 1 }
  $userEdits = Test-UnstagedEdits $root 'README.md'
  & $py -X utf8 $KitCmd.kitbag flow --readme $root | Out-Null
  if ($LASTEXITCODE) { Write-Host "pre-commit: kitbag flow failed (exit $LASTEXITCODE)"; exit 1 }
  if ($userEdits) { Write-Host 'pre-commit: README.md has unstaged edits: graph sections regenerated but NOT staged (git add README.md yourself if they belong)' }
  elseif (@(git -C $root status --porcelain -- README.md).Count) { git -C $root add -- README.md; Write-Host 'pre-commit: README graph sections regenerated and staged' }
  # staged scripts' Sections: maps (kitbag.py sections --fix); a file with unstaged edits is left to lint
  $sec = @(git -C $root diff --cached --name-only --diff-filter=ACMR -- '*.ps1' '*.py' '*.js' '*.mjs' | Where-Object { -not (Test-UnstagedEdits $root $_) })
  if ($sec.Count) {
    & $py -X utf8 $KitCmd.kitbag sections --fix @($sec | ForEach-Object { Join-Path $root $_ }) | Out-Null
    foreach ($f in $sec) { if (Test-UnstagedEdits $root $f) { git -C $root add -- $f; Write-Host "pre-commit: Sections: map of $f regenerated and staged" } }
  }
  & $py -X utf8 $KitCmd.kitbag port 2>$null | Out-Null   # silent: ports are optional
  if (@(git -C $root status --porcelain -- .codex .agents GEMINI.md).Count) {
    git -C $root add -- .codex .agents GEMINI.md
    Write-Host 'pre-commit: ports (.codex, .agents, GEMINI.md) regenerated and deployed to workspace'
  }
  $out = Join-Path (Get-KitTemp) "kit-precommit-$PID.json"
  & $py -X utf8 $KitCmd.kitbag lint $root --no-flow --json $out | Out-Null
  if ($LASTEXITCODE -gt 1 -or -not (Test-Path $out)) { Write-Host "pre-commit: BLOCKED - kitbag lint did not run (exit $LASTEXITCODE, no JSON)" -ForegroundColor Red; exit 1 }
  $probs = @(if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json }); Remove-Item $out -Force -ErrorAction SilentlyContinue
  if ($probs.Count) { Write-Host "pre-commit: BLOCKED - kit-lint: $($probs.Count) problem(s):" -ForegroundColor Red; $probs | Select-Object -First 25 | ForEach-Object { Write-Host "  $($_.code) $($_.where): $($_.problem)" }; exit 1 }
  exit 0
}
