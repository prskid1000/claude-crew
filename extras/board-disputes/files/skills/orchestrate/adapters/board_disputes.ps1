# Extra board-disputes (kittool.py extra add board-disputes): orch.ps1 board dispute | disputes, dot-sourced by orch.ps1.
# An agent disagrees with another's result: the other answers once with evidence; still split after 2 rounds or silent 2 h ->
# the owner judges through decide ask (orchestrate E4).
function Invoke-BoardDispute {
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('dispute', 'disputes')][string]$Action,
  [string]$Agent, [string]$With, [string]$Item, [string]$Claim, [string]$Evidence, [string]$Propose, [string]$Id, [string]$Run = '', [string]$Contracts = '',
  [ValidateSet('', 'agree', 'disagree')][string]$Answer = '', [switch]$Open, [switch]$Json
)
switch ($Action) {
  'dispute' {
    $dd = Get-KitPath disputes -Create
    if (-not $Id) {
      if (-not ($Agent -and $With -and $Claim -and $Evidence)) { 'usage: board dispute -Agent <me> -With <id> -Item <item> -Claim ".." -Evidence ".." -Propose ".." [-Run <run>] [-Contracts <file>]'; exit 2 }
      $did = "p-$(Get-Date -Format yyyyMMddHHmmss)-$([guid]::NewGuid().ToString('N').Substring(0, 4))"
      $o = [ordered]@{ id = $did; run = $Run; item = $Item; from = $Agent; with = $With; propose = $Propose; contracts = $Contracts; status = 'open'; at = (Get-Date).ToString('s')
        rounds = @([ordered]@{ claim = $Claim; evidence = $Evidence; by = $Agent; answer = ''; answerEvidence = '' }) }
      $df = Join-Path $dd "$did.json"; Invoke-KitLocked $df { $o | ConvertTo-Json -Depth 6 | Set-Content $df -Encoding utf8 }
      Send-BoardMsg $Agent $With "DISPUTE $did (item $Item): $Claim | evidence: $Evidence | proposed: $Propose. Answer once: orch.ps1 board dispute -Id $did -Agent $With -Answer agree|disagree -Evidence '<yours>'"
      if ($Contracts -and (Test-Path (Split-Path $Contracts))) { Add-Content -LiteralPath $Contracts "`n## DISPUTE $did ($Agent vs $With, item $Item)`nClaim: $Claim · Evidence: $Evidence · Proposed: $Propose" -Encoding utf8 }
      "DISPUTE $did open: $With answers once (board msg sent); still split after 2 rounds -> the owner judges (decide ask)"; return
    }
    $df = Join-Path $dd "$Id.json"; if (-not (Test-Path $df)) { "no dispute $Id"; exit 1 }
    $script:dispOut = @()
    Invoke-KitLocked $df {
      $o = Get-Content $df -Raw | ConvertFrom-Json
      if ($o.status -ne 'open') { $script:dispOut = @("dispute $Id is $($o.status)$(if ($o.decision) { " ($($o.decision))" })"); return }
      $last = @($o.rounds)[-1]
      if ($Answer) {
        if ($last.answer) { $script:dispOut = @("round $(@($o.rounds).Count) is answered: the opener posts round 2 (-Claim -Evidence) or agrees"); return }
        $last.answer = $Answer; $last.answerEvidence = $Evidence
        if ($Answer -eq 'agree') { $o.status = 'agreed'; $o | Add-Member -Force verdict "agreed by $Agent in round $(@($o.rounds).Count)" }
        elseif (@($o.rounds).Count -ge 2) {
          $o.status = 'escalated'; $o | Add-Member -Force decision (Request-DisputeDecision $o "$($o.from): $($last.claim) [$($last.evidence)]; $($o.with): $($Evidence)")
        }
        Send-BoardMsg $Agent $o.from "DISPUTE ${Id}: $Answer - $Evidence"
      }
      elseif ($Claim) {
        if (-not $last.answer) { $script:dispOut = @('wait for the answer to the current round first'); return }
        if (@($o.rounds).Count -ge 2) { $script:dispOut = @('2 rounds done: the dispute escalates on the second disagree'); return }
        $o.rounds = @(@($o.rounds) + [pscustomobject]@{ claim = $Claim; evidence = $Evidence; by = $Agent; answer = ''; answerEvidence = '' })
        Send-BoardMsg $Agent $o.with "DISPUTE $Id round 2: $Claim | evidence: $Evidence. Answer once: board dispute -Id $Id -Agent $($o.with) -Answer agree|disagree -Evidence '<yours>'"
      }
      else { $script:dispOut = @('usage: board dispute -Id <id> -Agent <me> -Answer agree|disagree -Evidence ".." | -Claim ".." -Evidence ".."'); return }
      $o | ConvertTo-Json -Depth 6 | Set-Content $df -Encoding utf8
      $script:dispOut = @("DISPUTE $Id $($o.status)$(if ($o.decision) { ": DECISION $($o.decision) (the owner judges)" })")
      if ($o.status -ne 'open') { $sig = [ordered]@{ at = (Get-Date).ToString('s'); skill = 'orchestrate'; kind = 'friction'; text = "dispute $Id ($($o.from) vs $($o.with), item $($o.item)) $($o.status): $(@($o.rounds)[0].claim)"; ref = $Id; source = 'board' } | ConvertTo-Json -Compress; $sf = Get-KitPath signals -Create; Invoke-KitLocked $sf { Add-Content -LiteralPath $sf $sig -Encoding utf8 } }
    }
    $script:dispOut | ForEach-Object { $_ }
  }
  'disputes' {
    $dd = Get-KitPath disputes
    $dl = @(Get-ChildItem $dd -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { -not $Open -or $_.status -eq 'open' })
    if ($Json) { ConvertTo-Json @($dl) -Depth 6; return }
    foreach ($d in $dl) { "$($d.status.ToUpper()) $($d.id) $($d.from) vs $($d.with) item $($d.item): $(@($d.rounds)[0].claim) | rounds $(@($d.rounds).Count)$(if ($d.decision) { " | decision $($d.decision)" })$(if ($d.verdict) { " | $($d.verdict)" })" }
    if (-not $dl.Count) { 'no disputes' }
  }
}
}

function Request-DisputeDecision($o, [string]$detail) {
  $ask = & $KitCmd.orch decide ask -Run "$($o.run)" -Agent $o.from -Item "$($o.item)" -Question "Dispute $($o.id) ($($o.from) vs $($o.with), item $($o.item)): who is right? $detail" -Options "A: $($o.from): $($o.propose)", "B: $($o.with): keep its result" -Contracts "$($o.contracts)" 2>&1 | Out-String
  if ($ask -match '\b(d-\d{14}-[\w-]+)') { $Matches[1] } else { 'not raised' }
}
# silent 2 h: escalate to the owner
function Invoke-DisputeExpiry([double]$Hours = 2) {
  foreach ($f in @(Get-ChildItem (Get-KitPath disputes) -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalHours -ge $Hours })) {
    $r = @{}   # re-read + raise under the lock: a reply in between wins, never a second decision
    Invoke-KitLocked $f.FullName { $o = Get-Content $f.FullName -Raw | ConvertFrom-Json; if ($o.status -ne 'open') { return }
      $last = @($o.rounds)[-1]
      $o.status = 'escalated'; $o | Add-Member -Force decision (Request-DisputeDecision $o "no reply for $Hours h; $($o.from): $($last.claim) [$($last.evidence)]")
      $o | ConvertTo-Json -Depth 6 | Set-Content $f.FullName -Encoding utf8; $r.o = $o }
    if ($r.o) { "dispute $($r.o.id) ($($r.o.from) vs $($r.o.with)) silent $Hours h: escalated, DECISION $($r.o.decision)" }
  }
}
# supervise -AutoFix: escalate silent disputes (orch.ps1 calls every Get-KitSuperviseFlags* function)
function Get-KitSuperviseFlagsDisputes([switch]$AutoFix) {
  if ($AutoFix) { foreach ($l in @(Invoke-DisputeExpiry)) { [pscustomobject]@{ level = 'INFO'; what = "auto-fixed: $l"; action = 'The owner judges it (orchestrate E4).' } } }
}
