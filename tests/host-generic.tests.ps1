#Requires -Version 7
<#
tests/host-generic.tests.ps1: the kit on a non-GitLab stack: a Gitea host on its own hostname, a kubectl-like `command` deploy kind,
an ssh deploy managed by docker, an unregistered kind, and no host configured at all. Offline (Invoke-KitHttp, ssh, glab, gh mocked).
Usage: pwsh -NoProfile -File tests/host-generic.tests.ps1 (tests/kit-tests.ps1 runs it). Exit codes: 0 pass · 1 a check failed.
#>
. (Join-Path $PSScriptRoot 'harness.ps1')
$TestKitFiles = @('skills/pokey/adapters/deployed_checks.ps1', 'skills/crafty/adapters/gitea.ps1', 'skills/crafty/adapters/gitlab.ps1', 'skills/crafty/adapters/github.ps1')
$k = New-TestKit host-generic; $Q = Join-Path $k 'skills/pokey/pokey.ps1'; $kl = Join-Path $k 'skills/crafty/kit.local.json'
foreach ($f in $TestKitFiles) { $d = Join-Path $k (Split-Path $f); New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item (Join-Path (Split-Path $PSScriptRoot) $f) $d }
$env:HG_HTTP = Join-Path (Kd) 'http.log'; $env:HG_SSH = Join-Path (Kd) 'ssh.log'; $env:HG_CLI = Join-Path (Kd) 'cli.log'

# 1. Gitea on code.acme.internal: deployed check over a command kind, an ssh/docker row and an unknown kind
& $J @{ gitHost = 'code.acme.internal'; gitHostType = 'gitea'; repos = @(@{ name = 'shop'; deploys = @(
      @{ target = 'k8s-stg'; command = @{ isDeployed = "`"$pwshExe`" -NoProfile -Command Write-Output DEPLOYED-{sha}" } },
      @{ target = 'box-stg'; ssh = @{ host = 'u@box'; manager = 'docker'; service = 'shop-web'; repoDir = '/srv/shop'; appDir = '/srv/shop/app' } },
      @{ target = 'helm-stg'; kind = 'helm' }) }) } $kl
$s1 = @'
. $args[0]
function glab { Add-Content $env:HG_CLI "glab $args" }; function gh { Add-Content $env:HG_CLI "gh $args" }
function Invoke-KitHttp([string]$Method, [string]$Uri, $Body, [hashtable]$Headers = @{}) {
  Add-Content $env:HG_HTTP "$Method $Uri"
  if ($Uri -match '/repos/shop/pulls/3$') { return ('{"number":3,"title":"t","state":"closed","merged":true,"merged_at":"2026-10-15T12:00:00Z","merge_commit_sha":"' + ('a' * 40) + '","head":{"ref":"f/x","sha":"' + ('b' * 40) + '"},"base":{"ref":"main"}}' | ConvertFrom-Json) }
  if ($Uri -match '/pulls/3/files') { return , @() }
  $null
}
function ssh { Add-Content $env:HG_SSH ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(("$($args[-1])" -split ' ')[1]))); 'HEAD=abc1234 2026-01-02'; 'ANC=yes'; 'RC=0'; 'FILES=1' }
$p = Invoke-HostVerb 'mr.parseRef' @{ ref = 'shop!3' }; "parse:$($p.repo -eq 'shop' -and $p.n -eq '3')"
"unknownverb:$($null -eq (Invoke-HostVerb 'mr.rebase' @{ repo = 'shop'; n = 3 } 3>$null))"
"lacks:$($null -eq (Invoke-KitDeployKind ([pscustomobject]@{ target = 'm'; manual = $true }) 'lastDeploy'))"
Invoke-Deployed -Mrs 'shop!3' -Json
'@
$o1 = Invoke-PsTest 'hg-gitea' $s1 @($Q) | Out-String
$rows = @(($o1 -replace '(?s)^.*?(\[.*\]).*$', '$1') | ConvertFrom-Json)
$http = @(Get-Content $env:HG_HTTP -ErrorAction SilentlyContinue); $sh = Get-Content $env:HG_SSH -Raw -ErrorAction SilentlyContinue
Expect "generic host: every call goes to the configured Gitea host, no GitLab path, no glab / gh ($($http -join ' | '))" ($http.Count -ge 1 -and -not @($http | Where-Object { $_ -notmatch '^\w+ https://code\.acme\.internal/api/v1/' }).Count -and -not @($http -match 'merge_requests|/api/v4|projects/|pipelines').Count -and -not (Test-Path $env:HG_CLI))
Expect "generic host: mr.parseRef from the kit's ref rules; an unknown verb = null; a kind's missing verb = null ($($o1 -replace '(?s)\[.*', '' -replace '\s+', ' '))" ($o1 -match 'parse:True' -and $o1 -match 'unknownverb:True' -and $o1 -match 'lacks:True')
Expect "deploy kind command: its isDeployed line answers ($(($rows | Where-Object target -eq 'k8s-stg').detail))" (($rows | Where-Object target -eq 'k8s-stg').state -eq 'DEPLOYED')
Expect "deploy kind ssh, manager docker: docker inspect, no systemctl, no sudo ($(($rows | Where-Object target -eq 'box-stg').state))" (($rows | Where-Object target -eq 'box-stg').state -eq 'DEPLOYED' -and $sh -match 'docker inspect' -and $sh -notmatch 'systemctl|sudo -n')
Expect "deploy kind unregistered (helm): UNKNOWN naming the registry ($(($rows | Where-Object target -eq 'helm-stg').detail))" (($rows | Where-Object target -eq 'helm-stg').state -eq 'UNKNOWN' -and ($rows | Where-Object target -eq 'helm-stg').detail -match 'helm has no isDeployed')

# 2. no host configured (no gitHost, gitHostType or checkout): verbs UNKNOWN, no vendor CLI, no gitlab.com default
& $J @{ repos = @(@{ name = 'shop' }) } $kl
Remove-Item $env:HG_CLI -ErrorAction SilentlyContinue
$s2 = @'
. $args[0]
function glab { Add-Content $env:HG_CLI "glab $args" }; function gh { Add-Content $env:HG_CLI "gh $args" }
$script:KitHostWarned = $false; $m = Invoke-HostVerb 'mr.get' @{ repo = 'shop'; n = 1 } 3>&1; $w = @($m | Where-Object { $_ -is [Management.Automation.WarningRecord] })
"none:$(-not @($m | Where-Object { $_ -and $_ -isnot [Management.Automation.WarningRecord] }).Count -and "$w" -match 'unknown git host: set gitHostType')"
"user:$((Get-KitHostUser 3>$null) -eq '')"
"nodefault:$($KitConf.GitHost -eq '')"
'@
$o2 = Invoke-PsTest 'hg-none' $s2 @($Q) | Out-String
Expect "no git host: verbs return nothing with one hint, whoami '', no vendor CLI, no gitlab.com default ($($o2 -replace '\s+', ' '))" ($o2 -match 'none:True' -and $o2 -match 'user:True' -and $o2 -match 'nodefault:True' -and -not (Test-Path $env:HG_CLI))

Remove-Item Env:HG_HTTP, Env:HG_SSH, Env:HG_CLI
Remove-TestKit $k
Complete-Tests
