<#
Call any HTTP API as any configured test user, and optionally save {request, response} JSON as evidence.
Targets (base URLs, auth style, users) come from ..\targets.local.json (copy targets.example.json).

  $Q = '<workspace>\.claude\skills\qa-kit\scripts'
  & $Q\api.ps1 -Path '/api/projects?size=5'                                   # default target, user 'admin'
  & $Q\api.ps1 -Target my-staging -As tester2 -Tenant acme -Method POST -Path '/api/projects' -Body '{"x":1}'
  & $Q\api.ps1 -Path '/api/projects/42' -Save T3_project_after_edit -OutDir <run>\T3\evidence

Prints "HTTP <status>" then the response body. Logs in once per target+tenant+user and caches the token
(re-login on 401). Auth types: login (json or form body, token from tokenField), token (static), basic, none.
-Save never stores passwords: only method, URL, request body, status and response body.
#>
param(
  [string]$Method = 'GET',
  [Parameter(Mandatory)][string]$Path,
  [string]$Body = $null,
  [string]$Target = $null,
  [string]$As = 'admin',
  [string]$Tenant = $null,
  [string]$Save = $null,            # evidence file name, without .json
  [string]$OutDir = $null,          # default: <.claude-runtime>\evidence
  [hashtable]$Headers = @{},
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
# Git Bash (MSYS) rewrites a '/api/x' argument to 'C:/Program Files/Git/api/x' before pwsh sees it: undo that
if ($Path -match '^[A-Za-z]:[\\/].*?[\\/]Git[\\/](?<rest>.*)$') { $Path = '/' + ($Matches.rest -replace '\\', '/') }
$here = Split-Path $MyInvocation.MyCommand.Path
$rt = if ($env:CLAUDE_RUNTIME) { $env:CLAUDE_RUNTIME } else { ($MyInvocation.MyCommand.Path -replace '\\\.claude\\.*$', '') + '\.claude-runtime' }   # runtime output lives outside .claude
$cfgFile = Join-Path (Split-Path $here) 'targets.local.json'
if (-not (Test-Path $cfgFile)) { throw "Missing $cfgFile - copy targets.example.json and fill it in" }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
if (-not $Target) { $Target = $cfg.default }
$t = $cfg.targets.$Target
if (-not $t) { throw "Unknown target '$Target'. Known: $($cfg.targets.PSObject.Properties.Name -join ', ')" }
if (-not $Tenant) { $Tenant = [string]$t.defaultTenant }
$u = @($t.users.$As)
if (-not $u.Count -and $t.auth.type -ne 'none') { throw "No user '$As' in target $Target. Known: $($t.users.PSObject.Properties.Name -join ', ')" }
$base = $t.api.TrimEnd('/')
$uri = if ($Path -match '^https?://') { $Path } else { $base + $Path }

function Fill($s) { ([string]$s).Replace('{user}', [string]$u[0]).Replace('{pass}', [string]$u[1]).Replace('{tenant}', $Tenant) }
function Get-Field($o, $path) { foreach ($k in $path.Split('.')) { $o = $o.$k }; $o }

$tokDir = Join-Path $rt 'tokens'; New-Item -ItemType Directory -Force $tokDir | Out-Null
$cache = Join-Path $tokDir ("$Target-$Tenant-$As.txt" -replace '[^\w.\-]', '_')
function Login {
  $a = $t.auth
  $b = [ordered]@{}; foreach ($p in $a.body.PSObject.Properties) { $b[$p.Name] = if ($p.Value -is [string]) { Fill $p.Value } else { $p.Value } }
  $loginUri = if ($a.path -match '^https?://') { $a.path } else { $base + $a.path }
  $r = if ($a.contentType -eq 'form') { Invoke-RestMethod -Method Post $loginUri -ContentType 'application/x-www-form-urlencoded' -Body $b -TimeoutSec 60 }
       else { Invoke-RestMethod -Method Post $loginUri -ContentType 'application/json' -Body ($b | ConvertTo-Json -Depth 5) -TimeoutSec 60 }
  $tok = Get-Field $r $(if ($a.tokenField) { $a.tokenField } else { 'access_token' })
  if (-not $tok) { throw "login to $Target as $As returned no token" }
  $tok | Set-Content $cache -NoNewline
  $tok
}
function AuthHeaders($tok) {
  $h = @{}
  switch ($t.auth.type) {
    'basic' { $h.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($u[0]):$($u[1])")) }
    'none' { }
    default {
      $tpl = if ($t.auth.header) { $t.auth.header } else { 'Authorization: Bearer {token}' }
      $n, $v = $tpl.Split(':', 2); $h[$n.Trim()] = $v.Trim().Replace('{token}', $tok)
    }
  }
  $h
}
$tok = $null
switch ($t.auth.type) {
  'login' { $tok = if (Test-Path $cache) { (Get-Content $cache -Raw).Trim() } else { Login } }
  'token' { $tok = if ($t.auth.token) { $t.auth.token } else { [string]$u[1] } }
}

function Call($tk) {
  $h = AuthHeaders $tk; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  if ($Tenant -and $t.tenantHeader) { $h[$t.tenantHeader] = $Tenant }
  $p = @{ Uri = $uri; Method = $Method; Headers = $h; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ContentType = 'application/json' }
  if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body) }
  $script:sentHeaders = $h
  try { $r = Invoke-WebRequest @p; return @([int]$r.StatusCode, $r.Content, $r.Headers['Content-Type']) }
  catch {
    $resp = $_.Exception.Response
    if ($resp) { return @([int]$resp.StatusCode, $_.ErrorDetails.Message, [string]$resp.Content.Headers.ContentType) } else { return @(0, "ERR $($_.Exception.Message)", '') }
  }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Call $tok
if ($res[0] -eq 401 -and $t.auth.type -eq 'login') { $tok = Login; $sw.Restart(); $res = Call $tok }
$sw.Stop()
$status, $content, $ctype = $res
# binary responses (image/PDF/file downloads) come back as byte[]: keep the bytes as a file, put a text stub in the evidence/output
if ($content -is [byte[]]) {
  $bytes = $content; $content = "[binary $($bytes.Length) bytes, $ctype]"
  if ($Save) {
    $bdir = if ($OutDir) { $OutDir } else { Join-Path $rt 'evidence' }; New-Item -ItemType Directory -Force $bdir | Out-Null
    $ext = switch -Regex ([string]$ctype) { 'png' { '.png' } 'jpe?g' { '.jpg' } 'pdf' { '.pdf' } 'zip' { '.zip' } 'csv' { '.csv' } 'sheet|excel' { '.xlsx' } default { '.bin' } }
    $bf = Join-Path $bdir "$Save.body$ext"; [IO.File]::WriteAllBytes($bf, $bytes); $content += " saved to $bf"
  }
}


if ($Save) {
  # Evidence envelope per reference\evidence-standard.md: meta + request (secrets redacted) + response
  if (-not $OutDir) { $OutDir = Join-Path $rt 'evidence' }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  function Parse($s) { if (-not $s) { return $null }; if ($s.Length -gt 200KB) { return [ordered]@{ _truncated = $true; text = $s.Substring(0, 200KB) } }; try { $s | ConvertFrom-Json } catch { $s } }
  $red = [ordered]@{}; foreach ($k in $script:sentHeaders.Keys) { $red[$k] = if ($k -match '(?i)authorization|cookie|token|key|secret|password') { '[redacted]' } else { $script:sentHeaders[$k] } }
  $code, $check = if ($Save -match '^([A-Za-z0-9]+)-([A-Za-z]*\d+)') { $Matches[1], $Matches[2] } else { '', '' }
  [ordered]@{
    meta     = [ordered]@{ code = $code; check = $check; target = $Target; tenant = $Tenant; user = [string]$u[0]; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); durationMs = $sw.ElapsedMilliseconds; tool = 'api.ps1' }
    request  = [ordered]@{ method = $Method.ToUpper(); url = $uri; headers = $red; body = (Parse $Body) }
    response = [ordered]@{ status = $status; headers = [ordered]@{ 'content-type' = [string]$ctype }; body = (Parse $content) }
  } | ConvertTo-Json -Depth 30 | Out-File (Join-Path $OutDir "$Save.json") -Encoding utf8
}
"HTTP $status"
$content
