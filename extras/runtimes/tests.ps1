#Requires -Version 7
# Tests of the extra runtimes (fake isUp / up / down lines on a flag file): lease, start, stop, an owner-started runtime stays,
# the guard's auto lease, supervise -AutoFix on a dead holder. Run: kittool.py extra test runtimes
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit rt; $D = Join-Path $k 'skills/dev-kit/dev.ps1'; $O = Join-Path $k 'skills/orchestrate/orch.ps1'
$flag = Join-Path (Kd) 'fake.up'; $log = Join-Path (Kd) 'fake.log'
$fake = @{ isUp = "if (Test-Path '$flag') { 'up' }"; up = "New-Item -Force '$flag' | Out-Null; Add-Content '$log' up"
  down = "Remove-Item -Force '$flag'; Add-Content '$log' down"; match = '^fakectl\b' }
& $J @{ runtimes = @{ fake = $fake } } (Join-Path $k 'skills/dev-kit/kit.local.json')
function Log { if (Test-Path $log) { @(Get-Content $log) -join ',' } else { '' } }
function Reset { Remove-Item $flag, $log -Force -ErrorAction SilentlyContinue; Remove-Item (TkPath $k runtimes) -Recurse -Force -ErrorAction SilentlyContinue }

$u = pwsh @np $D runtime use -Name fake -Agent a1 2>&1 | Out-String; $s = pwsh @np $D runtime status -Name fake -Json | Out-String | ConvertFrom-Json
Expect "runtimes: use starts a stopped runtime and marks it kit-started ($u)" ((Log) -eq 'up' -and $s[0].startedByKit -and $s[0].running -and $s[0].leases[0].agent -eq 'a1')
$null = pwsh @np $D runtime use -Name fake -Agent a2; $r1 = pwsh @np $D runtime release -Name fake -Agent a1 | Out-String
Expect "runtimes: a release with a lease left keeps it running ($r1)" ((Log) -eq 'up' -and (Test-Path $flag) -and $r1 -match '1 left')
$r2 = pwsh @np $D runtime release -Agent a2 | Out-String
Expect "runtimes: the last release stops what the kit started ($r2)" ((Log) -eq 'up,down' -and -not (Test-Path $flag) -and $r2 -match 'stopped')

Reset; New-Item $flag | Out-Null
$null = pwsh @np $D runtime use -Name fake -Agent a1; $r3 = pwsh @np $D runtime release -Name fake -Agent a1 | Out-String
Expect "runtimes: an owner-started runtime is never started or stopped ($r3)" ((Log) -eq '' -and (Test-Path $flag) -and $r3 -match 'not started by the kit')
$bad = Invoke-TestScript $D runtime use -Name nope
Expect "runtimes: an unknown runtime exits 1 ($($bad.code))" ($bad.code -eq 1 -and $bad.out -match 'no kit.local.json runtimes.nope')

Reset
$g = { param($c) pwsh @np $D guard -Json (@{ tool_name = 'PowerShell'; tool_input = @{ command = $c }; agent_type = 'devy'; agent_id = 'abcdef123456' } | ConvertTo-Json -Compress) | Out-String }
$o1 = & $g "`$env:CLAUDE_AGENT='g1'; fakectl run x"
for ($i = 0; $i -lt 50 -and -not (Test-Path $flag); $i++) { Start-Sleep -Milliseconds 200 }
$st = Get-Content (Join-Path (TkPath $k runtimes) 'fake.json') -Raw | ConvertFrom-Json
Expect "runtimes: the guard leases for an agent that forgot, starts the runtime, tells it to release ($o1)" ($o1 -match '"additionalContext"' -and $o1 -match 'release -Name fake -Agent g1' -and $o1 -notmatch 'permissionDecision' -and $st.leases[0].auto -and $st.startedByKit -and (Test-Path $flag))
$o2 = & $g "`$env:CLAUDE_AGENT='g1'; fakectl ps"; $o3 = (& $g 'git commit -m "fakectl notes"') + (& $g 'cat fakectl/README.md'); $o4 = & $g "dev.ps1 gate -Dir . -Cmd 'fakectl test'"
Expect "runtimes: no second note for a held lease, none for quoted text or a path ($o2|$o3)" (-not $o2.Trim() -and -not $o3.Trim())
Expect "runtimes: a gate -Cmd counts, the hook's agent names the lease ($o4)" ($o4 -match 'Agent devy-abcdef12')

# supervise -AutoFix: a lease whose holder died 1 h ago is released and the kit-started runtime stopped
Reset; New-Item $flag | Out-Null
$old = (Get-Date).AddHours(-1).ToString('o')
& $J @{ name = 'fake'; startedByKit = $true; leases = @(@{ agent = 'ghost'; session = ''; at = $old; holderPid = 999999; holderStart = $old; seen = $old }) } (Join-Path (TkPath $k runtimes -Create) 'fake.json')
$sv = pwsh @np $O supervise 2>&1 | Out-String
Expect "runtimes: supervise flags a dead lease without -AutoFix" ($sv -match 'lease of ghost has no live holder' -and (Test-Path $flag))
$sv = pwsh @np $O supervise -AutoFix 2>&1 | Out-String
Expect "runtimes: supervise -AutoFix releases a dead lease and stops the kit-started runtime" ($sv -match 'released the lease of ghost' -and $sv -match 'stopped' -and -not (Test-Path $flag) -and (Log) -eq 'down')

Remove-TestKit $k
foreach ($t in Get-ChildItem $PSScriptRoot -Filter 'tests-*.ps1') { & $pwshExe -NoProfile -File $t.FullName -Kit $src }   # the tests of the extras merged into this one
Complete-Tests
