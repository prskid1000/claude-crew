#Requires -Version 7
<#
tests/context-2.tests.ps1: what an agent loads at its start, kept small (context.tests.ps1 is at its cap): learn -Read with a
skill list (a shared org section once), board join (its own run in rows, other runs one line).
Usage: pwsh -NoProfile -File tests/context-2.tests.ps1 (or tests/kit-tests.ps1 -Area context-2).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/bossy/adapters/kit-admin.ps1'); $k = New-TestKit ctx2; $O = Join-Path $k 'skills/bossy/bossy.ps1'
# learn -Read -Skill a,b: one call, a section both share once (it printed twice: 2.7k tokens per reviewer)
[IO.File]::WriteAllText((Join-Path $k 'LESSONS.md'), "# Kit lessons`n`n## crafty`n- pub when -> do it (pub why)`n`n## opsy`n- ops when -> do it (ops why)`n")
[IO.File]::WriteAllText((Join-Path $k 'ROLES.local.md'), "## opsy , crafty `n- role one`n### pk (pokey)`n- role pk`n## pokey`n- role two`n## crafty`n- role three`n")
$pairOut = pwsh @np $O learn -Read -Skill opsy,crafty | Out-String; $oneOut = pwsh @np $O learn -Read -Skill crafty | Out-String
Expect "learn -Read -Skill a,b: both skills' lessons and rules, a shared org section once ($(([regex]::Matches($pairOut, 'role one')).Count))" (([regex]::Matches($pairOut, 'role one')).Count -eq 1 -and $pairOut -match 'pub when' -and $pairOut -match 'ops when' -and $pairOut -match 'role three' -and $pairOut -notmatch 'role two|role pk')
Expect 'learn -Read -Skill a: unchanged (its lessons, its org sections)' ($oneOut -match 'pub when' -and $oneOut -match 'role one' -and $oneOut -match 'role three' -and $oneOut -notmatch 'ops when|role two')
$capLines = @(1..25 | ForEach-Object { "- cap $_ -> a (b)" }) -join "`n"; [IO.File]::WriteAllText((Join-Path $k 'LESSONS.md'), "# Kit lessons`n`n## zc`n$capLines`n")
$capOut = pwsh @np $O learn -Read -Skill zc | Out-String
Expect "learn -Read: learn.readCap 20 lessons by default, the rest counted ($(([regex]::Matches($capOut, '(?m)^- cap')).Count))" (([regex]::Matches($capOut, '(?m)^- cap')).Count -eq 20 -and $capOut -match '\(5 more, fewest hits')
# board join prints its own run's rows; another run is one count line (the whole board: 1-2.6k tokens per join), board show keeps every row
$null = pwsh @np $O board join -Agent BY -Run rb
$farOut = pwsh @np $O board join -Agent FAR -Run rfar | Out-String; $nearOut = pwsh @np $O board join -Agent NEAR -Run rb | Out-String; $showOut = pwsh @np $O board show | Out-String
Expect "board join: other runs as one line, the own run in rows; show = all ($farOut)" ($farOut -match 'nobody else in your run' -and $farOut -match 'other runs: rb 1 \(rows: board show' -and $farOut -notmatch '(?m)^\s+BY' -and $nearOut -match '(?m)^\s+BY' -and $nearOut -match 'other runs: rfar 1' -and $showOut -match '(?m)^\s+BY' -and $showOut -match '(?m)^\s+FAR')
Remove-TestKit $k
Complete-Tests
