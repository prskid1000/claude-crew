<#
Shared kit configuration. Dot-source it from any kit script:

  . (Join-Path <path to skills\dev-kit\scripts> 'kitconfig.ps1')      # sets $KitConf

Everything is derived from where the kit lives, so the kit works in any workspace:
  Kit        = the .claude folder (this file is <Kit>\skills\dev-kit\scripts\kitconfig.ps1)
  Workspace  = the parent of .claude (the folder you open Claude Code in)
  Runtime    = $env:CLAUDE_RUNTIME, else <Workspace>\.claude-runtime (tokens, evidence, QA runs, logs - never inside .claude)
Org-specific values come from <Kit>\skills\dev-kit\kit.local.json (copy kit.example.json; git-ignored). Every key is optional.
#>
$__devkit = Split-Path $PSScriptRoot
$__kit = Split-Path (Split-Path $__devkit)
$__ws = Split-Path $__kit
$__cfg = $null
$__cfgFile = Join-Path $__devkit 'kit.local.json'
if (Test-Path $__cfgFile) { try { $__cfg = Get-Content $__cfgFile -Raw | ConvertFrom-Json } catch { Write-Warning "ignoring $__cfgFile (invalid JSON): $_" } }
function Get-KitValue([string]$Name, $Default) {
  if ($__cfg -and ($__cfg.PSObject.Properties.Name -contains $Name) -and $null -ne $__cfg.$Name -and "$($__cfg.$Name)" -ne '') { return $__cfg.$Name }
  $Default
}
# Nested keys: Get-KitSetting 'tracker.type' 'clickup'
function Get-KitSetting([string]$Path, $Default) {
  $cur = $__cfg
  foreach ($part in $Path -split '\.') {
    if ($null -eq $cur -or -not ($cur.PSObject.Properties.Name -contains $part)) { return $Default }
    $cur = $cur.$part
  }
  if ($null -eq $cur -or "$cur" -eq '') { return $Default }
  $cur
}
# reports: "gdocs" (Google Docs via the gws CLI) or "markdown" (files in the run folder); default gdocs only when gws is installed
$__reportType = [string](Get-KitSetting 'reports.type' $(if (Get-Command gws -ErrorAction SilentlyContinue) { 'gdocs' } else { 'markdown' }))
$__repos = Get-KitValue 'reposRoot' $__ws
$__wtRoots = @(@($env:CLAUDE_WT_ROOT) + @(Get-KitValue 'worktreeRoots' @("$__repos-wt")) | Where-Object { $_ } | Select-Object -Unique)
$KitConf = [pscustomobject]@{
  Kit               = $__kit
  Workspace         = $__ws
  Runtime           = $(if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { Join-Path $__ws '.claude-runtime' })
  ConfigFile        = $__cfgFile
  ReposRoot         = $__repos                                    # where the main checkouts live (<ReposRoot>\<repo>)
  WorktreeRoots     = $__wtRoots                                  # where wt.ps1 puts worktrees (default <ReposRoot>-wt)
  GitHost           = [string](Get-KitValue 'gitHost' 'gitlab.com')   # GitLab host (self-hosted: gitlab.example.com)
  GitlabGroup       = [string](Get-KitValue 'gitlabGroup' '')     # group for short MR refs <repo>!<iid>
  TrackerRepos      = @(Get-KitValue 'trackerRepos' @())          # repos track.ps1 -Discover searches for CU-<task> MRs
  RepoAliases       = (Get-KitValue 'repoAliases' $null)          # e.g. { "api": "backend", "web": "frontend" }
  ProtectedBranches = @(Get-KitValue 'protectedBranches' @())     # extra shared branches besides main/master/develop/release/*
  TrackerType       = ([string](Get-KitSetting 'tracker.type' 'clickup')).ToLower()   # clickup | github | gitlab | jira | none (skills\dev-kit\scripts\tracker.ps1)
  ReportType        = $__reportType.ToLower()                     # gdocs | markdown (qa-kit finalize.ps1, devtools.py doc)
  MaxBrowserProfiles = [int](Get-KitSetting 'cleanup.maxBrowserProfiles' 4)   # cleanup.ps1 keeps this many QA browser profiles when no QA seat is active
  # Claude Code keeps this workspace's sessions (workflow journals) in ~/.claude/projects/<workspace path with non-alphanumerics as '-'>
  ClaudeProjectDir  = (Join-Path $env:USERPROFILE ('.claude\projects\' + ($__ws -replace '[^A-Za-z0-9]', '-')))
}
