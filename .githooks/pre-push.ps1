#Requires -Version 7
<#
Kit pre-push gate, run by .githooks/pre-push (git passes: <remote name> <url>; stdin: <local ref> <local sha> <remote ref> <remote sha>).
Blocks the push (exit 1) on any hit:
  1. LOCAL FILE  a pushed commit adds or changes a file that matches .gitignore or .git/info/exclude (force-added *.local.*,
                 settings.local.json, targets/swarm configs, kit.local.json "localOnly" paths, runtime output, ...)
  2. ORG TERM    kit-lint.py --org-terms finds an org term in a published file of the working tree, or a pushed commit adds a
                 line with one. Terms: "orgTerms" in skills/dev-kit/kit.local.json (or $env:KIT_ORG_TERMS, comma list).
The kit's other lint problems are printed as a warning only.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$zero = '0' * 40
$updates = @([Console]::In.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $p = $_ -split '\s+'; [pscustomobject]@{ lsha = $p[1]; rsha = $p[3] } } | Where-Object { $_.lsha -ne $zero })
$hits = @()

# commits being pushed: new ones only (for a new branch: those on no remote yet)
$revs = foreach ($u in $updates) { if ($u.rsha -eq $zero) { git -C $root rev-list $u.lsha --not --remotes } else { git -C $root rev-list "$($u.rsha)..$($u.lsha)" } }
$revs = @($revs | Where-Object { $_ } | Select-Object -Unique)

# 1. ignored / local-only files in the pushed commits
if ($revs.Count) {
  $files = @($revs | ForEach-Object { git -C $root diff-tree --no-commit-id --name-only --diff-filter=ACMR -r $_ } | Where-Object { $_ } | Select-Object -Unique)
  if ($files.Count) {
    # paths as arguments, in batches (piping from pwsh on Windows would append CR to every path)
    $ign = @(for ($i = 0; $i -lt $files.Count; $i += 100) { git -C $root check-ignore --no-index -- @($files[$i..([math]::Min($i + 99, $files.Count - 1))]) 2>$null })
    foreach ($f in $ign) { $hits += "LOCAL FILE  $f is git-ignored or local-only (.gitignore / .git/info/exclude) but a pushed commit carries it: git rm --cached it and amend" }
  }
}

# 2. org terms
$terms = @()
$cfg = Join-Path $root 'skills/dev-kit/kit.local.json'
if ($env:KIT_ORG_TERMS) { $terms = @($env:KIT_ORG_TERMS -split ',' | Where-Object { $_.Trim() }) }
elseif (Test-Path $cfg) { try { $terms = @((Get-Content $cfg -Raw | ConvertFrom-Json).orgTerms | Where-Object { $_ }) } catch { $hits += "CONFIG      $cfg is not valid JSON: $_" } }
if (-not $terms.Count) { Write-Host 'pre-push: no orgTerms in skills/dev-kit/kit.local.json - org-term scan skipped' }
else {
  $py = @('python3', 'python') | ForEach-Object { (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } | Where-Object { $_ } | Select-Object -First 1
  if (-not $py) { $hits += 'PYTHON      python is not installed: the org-term scan (kit-lint.py) cannot run' }
  else {
    $out = Join-Path ([IO.Path]::GetTempPath()) "kit-prepush-$PID.json"
    & $py (Join-Path $root 'skills/orchestrate/scripts/kit-lint.py') $root --warn --no-flow --org-terms ($terms -join ',') --json $out | Out-Null
    $probs = @(if (Test-Path $out) { Get-Content $out -Raw | ConvertFrom-Json }); Remove-Item $out -Force -ErrorAction SilentlyContinue
    foreach ($p in $probs | Where-Object code -eq 'ORG-TERM') { $hits += "ORG TERM    $($p.where): $($p.problem)" }
    $other = @($probs | Where-Object code -ne 'ORG-TERM')
    if ($other.Count) { Write-Host "pre-push: warning: kit-lint reports $($other.Count) other problem(s) (python skills/orchestrate/scripts/kit-lint.py)" }
  }
  # lines added by the pushed commits (catches a term that was committed and later removed from the working tree)
  # whole words; a term with a capital letter matches case-sensitively (the same rule as kit-lint ORG-TERM)
  # a term ending in * is a prefix (same rule as kit-lint)
  $rx = @($terms | ForEach-Object { $t = $_.Trim(); $stem = $t.TrimEnd('*'); [pscustomobject]@{ term = $t; rx = [regex]::new('(?<![\w-])' + [regex]::Escape($stem) + $(if ($t.EndsWith('*')) { '' } else { '(?![\w-])' }), $(if ($stem -cne $stem.ToLower()) { 'None' } else { 'IgnoreCase' })) } })
  foreach ($r in $revs) {
    foreach ($line in @(git -C $root show --format= --unified=0 --no-color $r)) {
      if (-not $line.StartsWith('+') -or $line.StartsWith('+++')) { continue }
      foreach ($x in $rx) { if ($x.rx.IsMatch($line)) { $hits += "ORG TERM    commit $($r.Substring(0, 8)) adds ""$($x.term)"": $($line.Substring(0, [math]::Min(120, $line.Length)))"; break } }
    }
  }
}

if ($hits.Count) {
  Write-Host "pre-push: BLOCKED - $($hits.Count) problem(s):" -ForegroundColor Red
  $hits | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
  Write-Host 'Fix them (the kit is public and generic: org values belong in *.local.* files or localOnly paths), then push again.'
  exit 1
}
exit 0
