#Requires -Version 7
<#
tracker.tests.ps1: task texts rendered from a spec (crafty.ps1 "task spec": description, Items / Decisions checklists, the
parent's subtask items), the prose check of tracker kinds (no local paths).
Usage: pwsh -NoProfile -File <kit>/tests/tracker.tests.ps1 (or tests/kit-tests.ps1 -Area tracker).
Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$k = New-TestKit tracker; $KT = Join-Path $k 'skills/bossy/kitbag.py'
function KtPy($code) { python -X utf8 -c "import sys; sys.path.insert(0, r'$(Split-Path $KT)'); import kitbag as k; $code" }
$lp = KtPy "s = {'limits': '', 'format': '', 'required': []}; print([len(k.prose_check(kd, t, s, [])) for kd, t in (('comment-status', 'see ~/notes/a.md'), ('task-description', 'D:\\x\\y.md'), ('decisions', 'https://h/a/b.md ``common/agent-core``'), ('mr-body', '~/x.md'), ('task-description', 'GET /users/5 and /home/dashboard'))])"
Expect "prose: a local path in a tracker text (task-*, comment-*, decisions) is a finding; a URL, repo path or route is not, other kinds unchecked ($lp)" ("$lp".Trim() -eq '[1, 1, 0, 0, 0]')
# task spec (crafty.ps1 "task spec"): one renderer; a checklist adapter and the description fallback get the same items
$ts = Invoke-PsTest taskspec @'
$env:KIT_TRACKER_TYPE = 'none'; . $args[0]; $ErrorActionPreference = 'Stop'; Copy-Item $args[1] (Join-Path $script:KitRoot 'skills/crafty')   # templates.md: the prose check
$sp = @{ kind = 'Feature'; title = 'HM — Agents P1'; list = 'L1'; code = 'P1'; problem = 'HM has no agents.'; goal = 'Editors build agents.'; acceptance = @('flag off by default')
  items = @(@{ code = 'S01'; desc = 'Agent tables `agent` (ports X-01)'; mrs = @('https://git/r/-/merge_requests/5') }, @{ code = 'C01'; desc = 'Chat with an agent' })
  links = @(@{ text = 'parent'; url = 'https://t/1' }); decisions = @(@{ id = 'd-20261113-x-ab12'; question = 'Caps?'; answer = '40 turns'; by = 'owner'; at = '2026-11-13T10:00:00Z' }) }
$gold = "**Problem:** HM has no agents.`n`n**Goal:** Editors build agents.`n`n**Items:**`n- S01 · Agent tables agent (ports X-01)`n- C01 · Chat with an agent`n`n**Acceptance:**`n- flag off by default`n`n**Links:** [parent](https://t/1)"
$r = Publish-KitTaskSpec $sp -DryRun
$got = [Collections.Generic.List[string]]::new(); $KitAdapters['tracker']['none']['checklist'] = { param($a) foreach ($i in $a.items) { $got.Add("$($a.name)|$(if ($i.done) { 'x' } else { ' ' })|$($i.text)") } }
$c = Publish-KitTaskSpec $sp; $KitAdapters['tracker']['none'].Remove('checklist')
$sp.title = 'HM — Agents P1 copy'; $sp.newTask = 'fixture'; $f = Publish-KitTaskSpec $sp; $fd = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
$fb = @(foreach ($sn in 'Items', 'Decisions') { if ($fd -match "(?s)<!-- kit:$($sn.ToLower()) -->(.*?)<!-- /kit:") { [regex]::Matches($Matches[1], '(?m)^- \[(.)\] (.+)$') | ForEach-Object { "$sn|$($_.Groups[1].Value)|$($_.Groups[2].Value)" } } })
$bad = try { $sb = $sp.Clone(); $sb.links = @('../brief/x.md'); $null = Publish-KitTaskSpec $sb -DryRun; 'passed' } catch { "$_" }
$bad2 = try { $null = Publish-KitTaskSpec @{ title = 'x'; problem = 'p'; links = @('https://t/2'); goal = 'g'; acceptance = @('a'); items = @(@{ code = 'A'; desc = 'see `D:/Codebase/x.md`' }) } -DryRun; 'passed' } catch { "$_" }
$null = Set-TrackerDescription $f.id ("**Testing doc (human):** [open](https://h)`n`n" + $fd.Replace('**Problem:**', "<!-- kit:delivery -->`nD`n<!-- /kit:delivery -->`n`n<!-- kit:triage -->`nT`n<!-- /kit:triage -->`n`n**Problem:**"))
$u = Publish-KitTaskSpec @{ items = @(@{ code = 'C01'; desc = 'Chat, renamed'; done = $true }, @{ code = 'W01'; desc = 'Web tab' }) } -Task $f.id; $ud = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
$sub = Publish-KitTaskSpec @{ kind = 'Feature'; title = 'Sub one'; code = 'SUB1'; parent = $f.id; newTask = 'x'; problem = 'p.'; goal = 'g.'; items = @(@{ code = 'Z1'; desc = 'z' }); acceptance = @('a'); links = @('https://t/3') }
$pl = (__TrA 'create' @{ name = '[Bug] Plain one'; parent = $f.id }).id; $null = Publish-KitTaskSpec @{ subtasks = @(@{ id = $pl; code = 'PL1'; desc = 'Plain one' }) } -Task $f.id
$pd = (Get-TrackerTask $f.id).description -replace "`r`n", "`n"
[pscustomobject]@{ gold = ($r.description -eq $gold); name = $r.name; items = (@($got) -join "`n"); fb = ($fb -join "`n"); bad = $bad; bad2 = $bad2; ud = $ud; pd = $pd; sub = $sub.parent } | ConvertTo-Json -Compress
'@ @((Join-Path $k 'skills/crafty/crafty.ps1'), (Join-Path $src 'skills/crafty/templates.md'))
$ts = ("$($ts | Select-Object -Last 1)" | ConvertFrom-Json)
Expect "task spec: the description renders to the golden text (no testing-doc lines before the docs exist), [Kind] name" ($ts.gold -and $ts.name -eq '[Feature] HM — Agents P1')
Expect "task spec: a checklist adapter and the description fallback get the same Items and Decisions ($($ts.items) || $($ts.fb))" ($ts.items -and $ts.items -eq $ts.fb -and $ts.items -match '(?m)^Items\| \|S01 · Agent tables agent \(ports X-01\) · https://git/r/-/merge_requests/5$' -and $ts.items -match '(?m)^Decisions\|x\|ab12 · Caps\? → 40 turns · owner 11-13$')
Expect "task spec: a local path (links or any text) is refused, a link must be a full URL ($($ts.bad) | $($ts.bad2))" ($ts.bad -match "full URL instead of '\.\./brief" -and $ts.bad2 -match 'local path')
Expect 'task spec update: merged by item code (renamed in place, ticked, added), testing-doc links and kit sections kept' ($ts.ud -match '(?s)^\*\*Testing doc \(human\):\*\* \[open\]\(https://h\)\n\n.*<!-- kit:delivery -->\nD\n<!-- /kit:delivery -->\n\n<!-- kit:triage -->\nT\n<!-- /kit:triage -->.*- S01 ·[^\n]+\n- C01 · Chat, renamed\n- W01 · Web tab\n' -and $ts.ud -match '- \[x\] C01 · Chat, renamed' -and $ts.ud -match '- \[ \] W01 · Web tab')
Expect "task spec: a subtask goes on its parent's Items checklist '<code> · <name> · <URL>' ($($ts.sub))" ($ts.pd -match '- \[ \] SUB1 · Sub one · \S+' -and $ts.pd -match '- \[ \] PL1 · Plain one · \S+' -and $ts.pd -match '(?m)^- PL1 · Plain one$' -and $ts.pd -match '- \[ \] S01 · ' -and $ts.sub -match '1/4 done')
# non-ASCII end to end, long text never cut: a command-adapter tracker, crafty.ps1 run with no console (stdout in the OEM code page before the fix)
$fakeTr = Join-Path (Kd) 'fake-tracker.ps1'; Set-Content $fakeTr -Encoding utf8 @'
param($Verb, $Id, $Text)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $db = Join-Path $PSScriptRoot 'fake-tracker.json'
$st = if (Test-Path $db) { Get-Content $db -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } else { @{} }
switch ($Verb) { 'create' { $st['F-1'] = @{ id = 'F-1'; name = $Id; description = $Text }; '{"id":"F-1"}' } 'view' { $st[$Id] | ConvertTo-Json -Compress } 'describe' { $st[$Id].description = $Text; 'ok' } }
[IO.File]::WriteAllText($db, ($st | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
'@
$fakeCmd = "pwsh -NoProfile -File `"$fakeTr`""
Set-JsonFile "$k/skills/crafty/kit.local.json" @{ tracker = @{ type = 'command'; commands = @{ create = "$fakeCmd create {name} {description}"; view = "$fakeCmd view {id}"; describe = "$fakeCmd describe {id} {text}" } } }
$longDesc = 'Add sample-setup → plan gate for £5 café orders with a step-wording rule (set up sample data, then confirm each step in order, never skip one)'
Set-JsonFile "$(Kd)/u8spec.json" @{ kind = 'Feature'; title = 'Café · £ → é'; newTask = 'fixture'; problem = 'Prices show £ wrong → café.'; goal = 'Fix é · £.'; acceptance = @('£ → ok'); links = @('https://t/9'); items = @(@{ code = 'SG-1'; desc = $longDesc })
  decisions = @(@{ id = 'd-20261113-x-cd34'; question = 'Does the £5 café plan gate also hold for bulk orders that skip the sample-setup step entirely?'; answer = 'yes'; by = 'owner'; at = '2026-11-13T10:00:00Z' }) }
function Invoke-NoConsole([string[]]$Argv) { $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path); foreach ($x in $Argv) { $psi.ArgumentList.Add($x) }
  $psi.RedirectStandardOutput = $psi.RedirectStandardError = $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false; $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $pr = [Diagnostics.Process]::Start($psi); $so = $pr.StandardOutput.ReadToEndAsync(); $null = $pr.StandardError.ReadToEnd(); $pr.WaitForExit(); $so.Result }
$u8c = Invoke-NoConsole @('-NoProfile', '-File', "$k/skills/crafty/crafty.ps1", 'tracker', 'create', '-Spec', "$(Kd)/u8spec.json")
$u8v = Invoke-NoConsole @('-NoProfile', '-File', "$k/skills/crafty/crafty.ps1", 'tracker', 'view', 'F-1')
$u8db = (Get-Content -Raw -Encoding utf8 "$(Kd)/fake-tracker.json" | ConvertFrom-Json).'F-1'
Expect "task spec, non-ASCII: the adapter gets · → £ é intact, the long item uncut in Items and its checklist; kit stdout is UTF-8 with no console ($($u8c.Trim() -replace '\s+', ' '))" (
  $u8db.name -eq '[Feature] Café · £ → é' -and $u8db.description.Contains("- SG-1 · $longDesc") -and $u8db.description.Contains("- [ ] SG-1 · $longDesc") -and $u8db.description.Contains('bulk orders that skip the sample-setup step entirely? → yes') -and $u8db.description -notmatch '…|�' -and
  $u8c -match '"name": "\[Feature\] Café · £ → é"' -and $u8v.Contains("SG-1 · $longDesc"))
Remove-TestKit $k
Complete-Tests
