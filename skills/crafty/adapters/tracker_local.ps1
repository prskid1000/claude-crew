#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# tracker-local: the built-in trackers command (tracker.commands CLI lines) and none (a local store); always loaded.
# Sections: L5 tracker
# ---- tracker: command and none
# a tracker capability of the configured type (README "Adapters" caps); callers take the fallback when it is off
function __TrCan([string]$Cap) { Test-KitCap 'tracker' $__trType $Cap }
# adapter:tracker/command: tracker.commands.<verb> = a CLI line, {placeholders} = $a keys; prints the kit's JSON
Register-KitAdapter 'tracker' 'command' @{ 'caps' = { $c = Get-KitSetting 'tracker.commands' $null; $h = @{}
    foreach ($p in @(@('checklist', 'checklist'), @('statuses', 'statuses'), @('commentEdit', 'comment-edit'), @('commentDelete', 'comment-delete'), @('move', 'move'), @('attach', 'attach'))) { $h[$p[0]] = [bool](Get-KitMember $c $p[1]) }
    $h }
  '*' = { param($a, $v)
    $c = Get-KitSetting 'tracker.commands' $null; if ($v -in 'url', 'owner' -and -not (Get-KitMember $c $v)) { return $(if ($v -eq 'url') { $a.id } else { $a.name }) }
    if ($__trDry) { Write-Host "DRYRUN: tracker command $v $(__TrShort ($a | ConvertTo-Json -Compress))"; return }
    Invoke-KitCommand 'tracker' $c $v $a } }
# adapter:tracker/none: local store (.state/tracker-none) + log
Register-KitAdapter 'tracker' 'none' @{
  'url' = { param($a) Join-Path $__trNoneDir "$($a.id -replace '[^\w.-]', '_').json" }
  'view' = { param($a)
    $o = __TrNone $a.id 'view' $null; if (-not $o) { return }
    __TrTask $o.id $o.name $o.status (Get-TrackerUrl $o.id) $o.parent @($o.assignees) $o.list @(__TrNoneAll | Where-Object { $_.parent -eq $a.id } | ForEach-Object { __TrSub $_.id $_.name $_.status (Get-TrackerUrl $_.id) }) $o.description
  }
  'status' = { param($a) $null = __TrNone $a.id "status $($a.status)" { param($o) $o.status = $a.status }; "status of $($a.id): $($a.status) (tracker none)" }
  'comment' = { param($a) $null = __TrNone $a.id "comment $($a.text)" { param($o) __TrNoneNote $o $a.text }; "commented on $($a.id) (tracker none)" }
  'comments' = { param($a) @((__TrNone $a.id 'comments' $null).comments) }
  'comment-edit' = { param($a) $null = __TrNone $a.id "comment-edit $($a.comment)" { param($o) foreach ($c in @($o.comments)) { if ($c.id -eq $a.comment) { $c.text = $a.text } } }; "edited comment $($a.comment) on $($a.id) (tracker none)" }
  'comment-delete' = { param($a) $null = __TrNone $a.id "comment-delete $($a.comment)" { param($o) $o.comments = @($o.comments | Where-Object { $_.id -ne $a.comment }) }; "deleted comment $($a.comment) on $($a.id) (tracker none)" }
  'create' = { param($a)
    $d = Get-KitPath tracker-none -Create; $n = 1 + @(Get-ChildItem $d -Filter 'LOCAL-*.json' -ErrorAction SilentlyContinue).Count
    while (Test-Path (Join-Path $d "LOCAL-$n.json")) { $n++ }
    $null = __TrNone "LOCAL-$n" "create $($a.name)" { param($o) $o.name = $a.name; $o.status = @($__trStatus.open)[0]; $o.parent = $a.parent; $o.list = $a.list; $o.assignees = @($a.assignee | Where-Object { $_ }); $o.description = $a.description }
    [pscustomobject]@{ id = "LOCAL-$n"; url = Get-TrackerUrl "LOCAL-$n" }
  }
  'describe' = { param($a) $null = __TrNone $a.id 'describe' { param($o) $o.description = $a.text }; "described $($a.id) (tracker none)" }
  'rename' = { param($a) $null = __TrNone $a.id "rename $($a.name)" { param($o) $o.name = $a.name }; "renamed $($a.id) (tracker none)" }
  'move' = { param($a) $null = __TrNone $a.id "move $($a.parent)$($a.list)" { param($o) if ($a.top) { $o.parent = $null } elseif ($a.parent) { $o.parent = $a.parent }; if ($a.list) { $o.list = $a.list } }; "moved $($a.id) (tracker none)" }
  'attach' = { param($a) $null = __TrNone $a.id "attach $($a.file)" { param($o) __TrNoneNote $o "$($a.text) [attachment: $($a.file)]" }; "attached $($a.leaf) to $($a.id) (tracker none)" }
  'list' = { param($a) @(__TrNoneAll | Where-Object { (-not $a.list -or "$($_.list)" -eq $a.list) -and ((Test-TrackerStatus "$($_.status)" $a.logical) -or "$($_.status)" -ieq $a.status) } | ForEach-Object { __TrRow $_.id $_.name $_.status @($_.assignees | ForEach-Object { __TrWho $_ $_ }) }) }
  'owner' = { param($a) $a.name }
  'statuses' = { param($a) }   # no live names: every role uses its default names
}
