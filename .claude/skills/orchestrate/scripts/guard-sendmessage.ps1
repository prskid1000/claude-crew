<#
PreToolUse hook for SendMessage: blocks a message to an agent that belongs to a workflow run (dev-wave, test-and-close ...).
Such a send does not reach the running agent: it RESUMES a second copy from its transcript, and both copies then write the same
worktree (duplicate edits, broken tests). Relay to workflow agents through <brief>.contracts.md instead (they read it before pushing).
Exit 2 = block (stderr goes back to the model); exit 0 = allow.
#>
$ErrorActionPreference = 'SilentlyContinue'
$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$to = "$($in.tool_input.to)".Trim()
if ($to -notmatch '^(?<id>a[0-9a-f]{12,})$') { exit 0 }
$id = $Matches.id
$meta = Get-ChildItem "$env:USERPROFILE\.claude\projects\*\*\subagents\workflows\*\agent-$id.meta.json" | Select-Object -First 1
if (-not $meta) { exit 0 }
$label = (Get-Content $meta.FullName -Raw | ConvertFrom-Json).description
[Console]::Error.WriteLine("Blocked: '$to' ($label) is an agent inside workflow $($meta.Directory.Name). SendMessage would resume a SECOND copy of it that writes the same worktree. Relay through the wave's <brief>.contracts.md (agents re-read it before every push) and, if needed, let the running agent's report come back to you.")
exit 2
