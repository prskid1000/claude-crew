#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (crafty.ps1 check exits).
# Sections: L4 check builds · L11 check stamps
# ---- check builds: a clean tree's build, keyed by its tree: envy deploys of the same code stage its artifact (envy Find-CheckBuild)
function Save-CheckBuild([string]$Dir, [string]$Cmd, [datetime]$Start) {
  $top = "$(git -C $Dir rev-parse --show-toplevel 2>$null)".Trim(); if (-not $top -or @(git -C $top status --porcelain 2>$null).Count) { return }
  $tree = "$(git -C $top rev-parse 'HEAD^{tree}' 2>$null)".Trim(); if (-not $tree) { return }
  Write-KitAtomic (Join-Path (Get-KitPath check-builds -Create) "$tree.json") ([ordered]@{ tree = $tree; dir = $Dir; rel = [IO.Path]::GetRelativePath($top, $Dir).Replace('\', '/'); cmd = $Cmd; start = $Start.ToString('o'); at = (Get-Date).ToString('o') } | ConvertTo-Json)
}

# ---- check stamps: per module dir, step + command -> the source key of its last pass; Invoke-Check skips an unchanged rerun
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
# the sources' key once per check run, before it runs ($script:CheckSrcKey, reset by Invoke-Check); a pass of $Slot on it -> say so, $true
function Test-CheckStamp([string]$Dir, [string]$Slot, [switch]$Force) {
  if ($null -eq $script:CheckSrcKey) { $script:CheckSrcKey = "$(Get-CheckSourceKey $Dir)" }
  $was = if ($script:CheckSrcKey -and -not $Force) { (Read-CheckStamps $Dir)[$Slot] }
  if (-not $was -or "$($was.key)" -ne $script:CheckSrcKey) { return $false }
  Write-Host "[check] $(($Slot -split '\|')[0]) ok: passed on these sources at $(([datetime]$was.at).ToString('HH:mm')), not rerun (-Force reruns)"; $true
}
function Save-CheckStamp([string]$Dir, [string]$Slot) {   # the newest 30 slots per dir
  if ($null -eq $script:CheckSrcKey) { $script:CheckSrcKey = "$(Get-CheckSourceKey $Dir)" }
  if (-not $script:CheckSrcKey) { return }
  $h = Read-CheckStamps $Dir; $h[$Slot] = @{ key = $script:CheckSrcKey; at = (Get-Date).ToString('o') }
  $keep = [ordered]@{}; foreach ($kv in @($h.GetEnumerator() | Sort-Object { "$($_.Value.at)" } -Descending | Select-Object -First 30)) { $keep[$kv.Key] = $kv.Value }
  Write-KitAtomic (Get-CheckStampFile $Dir) ($keep | ConvertTo-Json -Depth 4)
}
