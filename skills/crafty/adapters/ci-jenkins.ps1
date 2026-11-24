#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# ci-jenkins: Jenkins CI (ci jenkins).
# Dot-sourced by lib.ps1 from skills/crafty/adapters/ when config selects jenkins; helpers come from lib.ps1.
# adapter:ci/jenkins: Jenkins REST (ci.url, ci.job = the multibranch job path, default "job/{repo}"; env ci.tokenEnv = JENKINS_TOKEN "user:api-token"); run id = <branch>#<build>
function __Jk([string]$Repo, [string]$Ref, [string]$Tail) {
  $job = ([string](Get-KitSetting 'ci.job' 'job/{repo}')) -replace '\{repo\}', (("$Repo" -split '/')[-1])
  Invoke-KitHttp 'GET' "$(([string](Get-KitSetting 'ci.url' '')).TrimEnd('/'))/$job/job/$(__Enc (__Enc $Ref))/$Tail" $null (Get-KitAuth ([string](Get-KitSetting 'ci.tokenEnv' 'JENKINS_TOKEN')) 'basic')
}
function __JkRun($b, [string]$Ref) { __CiRun "$Ref#$($b.number)" @($b.actions.lastBuiltRevision.SHA1 | Where-Object { $_ })[0] $(if ($b.building) { 'running' } else { __CiWord $b.result }) ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.timestamp).UtcDateTime.ToString('o')) ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$b.timestamp + [long]$b.duration).UtcDateTime.ToString('o')) }
Register-KitAdapter 'ci' 'jenkins' @{
  'runs' = { param($a) @(@((__Jk $a.repo $a.ref "api/json?tree=builds[number,result,building,timestamp,duration,actions[lastBuiltRevision[SHA1]]]{0,$($a.per_page ?? 20)}").builds) | Where-Object { $_ } | ForEach-Object { __JkRun $_ $a.ref } | Where-Object { -not $a.sha -or $_.sha -eq $a.sha }) }
  'jobs' = { param($a) $r, $n = "$($a.id)" -split '#', 2; @(@((__Jk $a.repo $r "$n/wfapi/describe").stages) | Where-Object { $_ } | ForEach-Object { __CiJob "$($a.id)/$($_.id)" $_.name (__CiWord $_.status) ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.startTimeMillis + [long]$_.durationMillis).UtcDateTime.ToString('o')) }) }
  'log' = { param($a) $r, $n = "$($a.id)" -split '#', 2; __Jk $a.repo $r "$(($n -split '/')[0])/consoleText" }   # a stage id (<run>/<stage>): the build's log
  # the FAILED stage and its error (Pipeline REST API wfapi/describe: stages[].error.message, .type); no stages (freestyle) + build FAILURE: the build itself
  'failure' = { param($a) $r, $n = "$($a.id)" -split '#', 2; $d = __Jk $a.repo $r "$n/wfapi/describe"; $s = @(@($d.stages) | Where-Object { "$($_.status)" -eq 'FAILED' })[0]
    if (-not $s -and (-not @($d.stages | Where-Object { $_ }).Count -and "$((__Jk $a.repo $r "$n/api/json?tree=result").result)" -eq 'FAILURE')) { $s = [pscustomobject]@{ id = ''; name = $r; error = $null } }
    if (-not $s) { return $null }; $em = "$($s.error.message)"
    $f = Get-KitCiFailure $a -Job ([pscustomobject]@{ id = "$($a.id)$(if ($s.id) { "/$($s.id)" })"; name = $s.name; failure_reason = "$($s.error.type)"; reason = $(if ("$em $($s.error.type)" -match '(?i)timeout') { 'timeout' } else { 'script' }) })
    if ($em) { $f.excerpt = "$em`n$($f.excerpt)".Trim() }; $f }
  # .../job/<branch>/<n>[/execution/node/<stage>] or Blue Ocean .../detail/<branch>/<n>[/pipeline/<stage>] in a text -> @{ url; run = <branch>#<n>; job = <run>/<stage> }
  'parseUrl' = { param($a) $m = [regex]::Match("$($a.text)", '(?<url>https?://[^\s)\]]+?/(?:job|detail)/(?<b>[^/\s]+)/(?<n>\d+)(?:/(?:execution/node|pipeline)/(?<s>\d+))?)'); if (-not $m.Success) { return @{} }
    $run = "$([uri]::UnescapeDataString([uri]::UnescapeDataString($m.Groups['b'].Value)))#$($m.Groups['n'].Value)"
    @{ url = $m.Groups['url'].Value; run = $run; job = $(if ($m.Groups['s'].Success) { "$run/$($m.Groups['s'].Value)" } else { '' }) } }
  'status' = { param($a) if (-not $a.ref -or -not $a.sha) { return $null }; $b = @(Invoke-KitAdapter 'ci' 'jenkins' 'runs' $a)[0]; if ($b) { __CiStat $b.id $b.status } }
  'config' = { param($a) [bool](Get-KitSetting 'ci.url' '') }
}
