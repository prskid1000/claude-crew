#Requires -Version 7
<#
guard-sendmessage.ps1: the PreToolUse SendMessage hook (bossy.ps1 guard-sendmessage): crew -> crew messages go through board msg;
a send to a workflow agent is denied (it would resume a second copy on the same worktree).
Usage: dot-sourced by bossy.ps1 from skills/bossy/adapters/; the verb calls Invoke-GuardSendMessage (hook JSON on stdin).
Exit codes: 0 (allow, or a deny printed as hook JSON).
Sections: L9 guard-sendmessage
#>
# ---- guard-sendmessage: a send RESUMES a second copy on the same worktree
function Invoke-GuardSendMessage {
$ErrorActionPreference = 'SilentlyContinue'
$in = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() | ConvertFrom-Json }  # by hand: no stdin wait
$to = "$($in.tool_input.to)".Trim()
# crew -> crew goes through the board so supervise and the dashboard see it; agent_id is set only inside a subagent
if ("$($in.agent_id)".Trim()) {
  $why = "Blocked: crew agents never SendMessage ('$to'). Use: bossy.ps1 board msg -Agent <you> -To <agent> -Kind <kind> -Text '<message>' (supervise and the dashboard see every board message); only the coordinator (main session) may SendMessage."
  [Console]::Error.WriteLine($why)
  @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
  exit 0
}
if ($to -notmatch '^(?<id>a[0-9a-f]{12,})$') { exit 0 }
$id = $Matches.id
$meta = Invoke-KitAdapter transcript claude agent-meta @{ id = $id }   # SendMessage: a Claude Code tool
if (-not $meta) { exit 0 }
$label = (Get-Content $meta.FullName -Raw | ConvertFrom-Json).description
$why = "Blocked: '$to' ($label) is an agent inside workflow $($meta.Directory.Name). SendMessage would resume a SECOND copy of it that writes the same worktree. Relay through the wave's <brief>.contracts.md (agents re-read it before every push) and, if needed, let the running agent's report come back to you."
[Console]::Error.WriteLine($why)
@{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $why } } | ConvertTo-Json -Compress -Depth 4
exit 0
}
