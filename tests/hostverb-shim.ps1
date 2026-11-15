#Requires -Version 7
# Usage: in a test script, after lib.ps1 and its Invoke-HostApi mock: . $env:KIT_TEST_SHIM. Exit codes: none (dot-sourced).
# Test-only: dot-source AFTER a test's GitLab-path Invoke-HostApi mock; core calls host verbs (Invoke-HostVerb), this maps each verb
# back to the GitLab path the canned answers are keyed by, and adds the normalised .state like lib.ps1 Invoke-HostVerb.
function Invoke-HostVerb([string]$Verb, [hashtable]$A = @{}, [switch]$NoMemo) {
  $p = "projects/$([uri]::EscapeDataString("$($A.repo)"))"; $e = { param($s) [uri]::EscapeDataString("$s") }
  $q = { param([string[]]$skip) $ks = @($A.Keys | Where-Object { $_ -notin @('repo', 'type', 'n', 'id', 'searchIn') + $skip } | Sort-Object); $kv = @($ks | ForEach-Object { "$_=$(& $e $A[$_])" }); if ($A.searchIn) { $kv += "in=$($A.searchIn)" }; if ($kv.Count) { '?' + ($kv -join '&') } else { '' } }
  $v = switch ($Verb) {
    'mr.get' { Invoke-HostApi "$p/merge_requests/$($A.n)" }
    'mr.changes' { Invoke-HostApi "$p/merge_requests/$($A.n)/changes?access_raw_diffs=true" }
    'mr.list' { Invoke-HostApi "$p/merge_requests$(& $q)" }
    'mr.unauto' { Invoke-HostApi "$p/merge_requests/$($A.n)/cancel_merge_when_pipeline_succeeds" -Method POST }
    'mr.merge' { $f = @{}; if ($A.auto) { $f.merge_when_pipeline_succeeds = 'true' }; Invoke-HostApi "$p/merge_requests/$($A.n)/merge" -Method PUT -Fields $f }
    'repo.base' { Invoke-HostApi "$p/repository/merge_base?refs[]=$($A.a)&refs[]=$(& $e $A.b)" }
    'repo.commit' { Invoke-HostApi "$p/repository/commits/$(& $e $A.ref)" }
    'repo.compare' { Invoke-HostApi "$p/repository/compare?from=$(& $e $A.from)&to=$(& $e $A.to)&straight=true" }
    'ci.runs' { Invoke-HostApi "$p/pipelines?ref=$(& $e $A.ref)&per_page=$(if ($A.per_page) { $A.per_page } else { 20 })" }
    'ci.jobs' { Invoke-HostApi "$p/pipelines/$($A.id)/jobs?per_page=100" }
    'ci.log' { Invoke-HostApi "$p/jobs/$($A.id)/trace" }
    'mr.url' { "https://git.example/$($A.repo)/-/merge_requests/$($A.n)" }   # as adapters/gitlab.ps1
    default { $null }
  }
  if ($Verb -like 'ci.*') { foreach ($x in @($v | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['status'] })) { $x | Add-Member -Force NoteProperty state (ConvertTo-KitCiState "$($x.status)") } }
  $v
}
