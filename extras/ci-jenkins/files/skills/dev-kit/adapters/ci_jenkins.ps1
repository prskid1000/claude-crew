# Extra ci-jenkins: Jenkins CI (ci jenkins).
# Dot-sourced by lib.ps1 from skills/dev-kit/adapters/ (kittool.py extra add ci-jenkins); helpers come from lib.ps1.
# adapter:ci/jenkins: Jenkins REST (ci.url, ci.job = the multibranch job path, default "job/{repo}"; env ci.tokenEnv = JENKINS_TOKEN "user:api-token"); run id = <branch>#<build>
function __Jk([string]$Repo, [string]$Ref, [string]$Tail) {
  $job = ([string](Get-KitSetting 'ci.job' 'job/{repo}')) -replace '\{repo\}', (("$Repo" -split '/')[-1])
  Invoke-KitHttp 'GET' "$(([string](Get-KitSetting 'ci.url' '')).TrimEnd('/'))/$job/job/$(__Enc (__Enc $Ref))/$Tail" $null (Get-KitAuth ([string](Get-KitSetting 'ci.tokenEnv' 'JENKINS_TOKEN')) 'basic')
}
function __JkRun($b, [string]$Ref) { __CiRun "$Ref#$($b.number)" @($b.actions.lastBuiltRevision.SHA1 | Where-Object { $_ })[0] $(if ($b.building) { 'running' } else { __CiWord $b.result }) ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.timestamp).UtcDateTime.ToString('o')) ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.timestamp + [long]$b.duration).UtcDateTime.ToString('o')) }
Register-KitAdapter 'ci' 'jenkins' @{
  'runs' = { param($a) @(@((__Jk $a.repo $a.ref "api/json?tree=builds[number,result,building,timestamp,duration,actions[lastBuiltRevision[SHA1]]]{0,$($a.per_page ?? 20)}").builds) | Where-Object { $_ } | ForEach-Object { __JkRun $_ $a.ref } | Where-Object { -not $a.sha -or $_.sha -eq $a.sha }) }
  'jobs' = { param($a) $r, $n = "$($a.id)" -split '#', 2; @(@((__Jk $a.repo $r "$n/wfapi/describe").stages) | Where-Object { $_ } | ForEach-Object { __CiJob $a.id $_.name (__CiWord $_.status) ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.startTimeMillis + [long]$_.durationMillis).UtcDateTime.ToString('o')) }) }
  'log' = { param($a) $r, $n = "$($a.id)" -split '#', 2; __Jk $a.repo $r "$n/consoleText" }
  'status' = { param($a) if (-not $a.ref -or -not $a.sha) { return $null }; $b = @(Invoke-KitAdapter 'ci' 'jenkins' 'runs' $a)[0]; if ($b) { __CiStat $b.id $b.status } }
  'config' = { param($a) [bool](Get-KitSetting 'ci.url' '') }
}
