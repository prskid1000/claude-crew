# deployed.ps1 OnRef offline: canned git-host answers (the memoised Api cache) for a squash-merged deploy MR, whose landing commit's
# parent is the old deploy head, while the source branch has moved on (a later commit touched the MR's file).
#   pwsh -NoProfile -File <kit>/skills/qa-kit/tests/test-deployed.ps1      exit 0 = all pass
$ErrorActionPreference = 'SilentlyContinue'
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot) 'scripts/deployed.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($fn.Extent.Text)) }
$fails = 0
function Expect($what, $cond) { if ($cond) { "PASS $what" } else { "FAIL $what"; $script:fails++ } }
function Canned($deployMrs) {
  $script:memo = @{}; $p = 'g%2Fweb'
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=stg"] = [pscustomobject]@{ id = 'OLD' }   # F is no ancestor of the deploy head
  $memo["projects/$p/repository/commits/stg"] = [pscustomobject]@{ committed_date = '2026-01-02T08:00:00Z' }
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=main"] = [pscustomobject]@{ id = 'F' }
  $memo["projects/$p/merge_requests/5/changes?access_raw_diffs=true"] = [pscustomobject]@{ changes = @([pscustomobject]@{ new_path = 'a.ts'; old_path = 'a.ts' }) }
  $memo["projects/$p/repository/compare?from=stg&to=main&straight=true"] = [pscustomobject]@{ diffs = @([pscustomobject]@{ new_path = 'a.ts'; old_path = 'a.ts' }) }
  $memo["projects/$p/merge_requests?state=merged&target_branch=stg&updated_after=2026-01-02T07:00:00Z&per_page=50"] = $deployMrs
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=S"] = [pscustomobject]@{ id = 'F' }        # the deploy MR's source head holds F
  $memo["projects/$p/repository/merge_base?refs[]=L&refs[]=stg"] = [pscustomobject]@{ id = 'L' }      # its landing commit is on the branch
  $memo["projects/$p/repository/merge_base?refs[]=F&refs[]=S0"] = [pscustomobject]@{ id = 'X' }       # an older deploy: F not in it
  $p
}
$mr = [pscustomobject]@{ iid = 5; merged_at = '2026-01-02T07:00:00Z'; target_branch = 'main' }
$p = Canned @([pscustomobject]@{ iid = 9; sha = 'S'; squash_commit_sha = 'L'; merge_commit_sha = $null })
Expect 'squash-merged deploy MR counts as deployed' (OnRef $p $mr 'F' 'stg')
$p = Canned @([pscustomobject]@{ iid = 8; sha = 'S0'; squash_commit_sha = 'L'; merge_commit_sha = $null })
Expect 'a deploy MR without the commit does not' (-not (OnRef $p $mr 'F' 'stg'))
"$fails failure(s)"; exit [int]($fails -gt 0)
