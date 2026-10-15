<#
Call any HTTP API as any configured test user, and optionally save {request, response} JSON as evidence.
Targets (base URLs, auth style, users) come from ..\targets.local.json (copy targets.example.json).

  $Q = '<workspace>/.claude/skills/qa-kit/scripts'
  & $Q/api.ps1 -Path '/api/projects?size=5'                                   # default target, user 'admin'
  & $Q/api.ps1 -Target my-staging -As tester2 -Tenant acme -Method POST -Path '/api/projects' -Body '{"x":1}'
  & $Q/api.ps1 -Path '/api/projects/42' -Save T3_project_after_edit -OutDir <run>/T3/evidence

Prints "HTTP <status>" then the response body. Logs in once per target+tenant+user and caches the token
(re-login on 401). Auth types: login (json or form body, token from tokenField), token (static), basic, none.
-Save never stores passwords: only method, URL, request body, status, response headers and body; secret-named headers and
JSON fields (password, token, secret, api key, cookie, authorization) at any depth become '[redacted]'. -OutDir: absolute path.
#>
param(
  [string]$Method = 'GET',
  [Parameter(Mandatory)][string]$Path,
  [string]$Body = $null,
  [string]$Target = $null,
  [string]$As = 'admin',
  [string]$Tenant = $null,
  [string]$Save = $null,            # evidence file name, without .json
  [string]$OutDir = $null,          # default: <runtime>/work/evidence
  [hashtable]$Headers = @{},
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
# an object bound to -OutDir arrives as its type name ('System.Collections.Hashtable', '@{meta=; ...}': a $o/$O clash in the
# caller) and became a folder under the current directory: only an absolute path is accepted
if ($OutDir -and -not [IO.Path]::IsPathRooted($OutDir)) { throw "-OutDir must be an absolute folder path, got '$OutDir' (a variable holding an object? PowerShell names are case-insensitive: `$o is `$O)" }
# Git Bash (MSYS) rewrites a '/api/x' argument to 'C:/Program Files/Git/api/x' before pwsh sees it: undo that
if ($Path -match '^[A-Za-z]:[\\/].*?[\\/]Git[\\/](?<rest>.*)$') { $Path = '/' + ($Matches.rest -replace '\\', '/') }
$here = Split-Path $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path (Split-Path $here)) 'dev-kit/scripts/kitpaths.ps1')   # Get-KitPath
$cfgFile = Join-Path (Split-Path $here) 'targets.local.json'
if (-not (Test-Path $cfgFile)) { throw "Missing $cfgFile - copy targets.example.json and fill it in" }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
if (-not $Target) { $Target = $cfg.default }
$t = $cfg.targets.$Target
if (-not $t) { throw "Unknown target '$Target'. Known: $($cfg.targets.PSObject.Properties.Name -join ', ')" }
if (-not $Tenant) { $Tenant = [string]$t.defaultTenant }
$u = @($t.users.$As)
if (-not $t.users.$As -and $t.auth.type -ne 'none') { throw "No user '$As' in target $Target. Known: $($t.users.PSObject.Properties.Name -join ', ')" }   # not @(...).Count: @($null).Count is 1
$base = $t.api.TrimEnd('/')
$uri = if ($Path -match '^https?://') { $Path } else { $base + $Path }

function Fill($s) { ([string]$s).Replace('{user}', [string]$u[0]).Replace('{pass}', [string]$u[1]).Replace('{tenant}', $Tenant) }
function Get-Field($o, $path) { foreach ($k in $path.Split('.')) { $o = $o.$k }; $o }

$tokDir = Get-KitPath tokens -Create
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
  'login' { $tok = if (Test-Path $cache) { ([string](Get-Content $cache -Raw)).Trim() }; if (-not $tok) { $tok = Login } }   # an empty cache file (cut write) logs in again
  'token' { $tok = if ($t.auth.token) { $t.auth.token } else { [string]$u[1] } }
}

function Call($tk) {
  $h = AuthHeaders $tk; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  if ($Tenant -and $t.tenantHeader) { $h[$t.tenantHeader] = $Tenant }
  $p = @{ Uri = $uri; Method = $Method; Headers = $h; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ContentType = 'application/json' }
  if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body) }
  $script:sentHeaders = $h
  # response headers go into the evidence too (Content-Disposition, Location, caching ...); cookies redacted
  function HeaderMap($pairs) { $m = [ordered]@{}; foreach ($kv in $pairs) { $m[([string]$kv.Key).ToLower()] = if ($kv.Key -match '(?i)cookie|authorization|token|key|secret|password') { '[redacted]' } else { @($kv.Value) -join ', ' } }; $m }
  try { $r = Invoke-WebRequest @p; $hm = HeaderMap $r.Headers.GetEnumerator(); return @([int]$r.StatusCode, $r.Content, [string]$hm['content-type'], $hm) }
  catch {
    $resp = $_.Exception.Response
    if ($resp) { $hm = HeaderMap (@($resp.Headers) + @($resp.Content.Headers)); return @([int]$resp.StatusCode, $_.ErrorDetails.Message, [string]$resp.Content.Headers.ContentType, $hm) } else { return @(0, "ERR $($_.Exception.Message)", '', [ordered]@{}) }
  }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Call $tok
if ($res[0] -eq 401 -and $t.auth.type -eq 'login') { $tok = Login; $sw.Restart(); $res = Call $tok }
$sw.Stop()
$status, $content, $ctype, $rhead = $res
# binary responses (image/PDF/file downloads) come back as byte[]: keep the bytes as a file, put a text stub in the evidence/output
if ($content -is [byte[]]) {
  $bytes = $content; $content = "[binary $($bytes.Length) bytes, $ctype]"
  if ($Save) {
    $bdir = if ($OutDir) { $OutDir } else { Get-KitPath evidence }; New-Item -ItemType Directory -Force $bdir | Out-Null
    $ext = if ([string]$rhead['content-disposition'] -match 'filename\*?=(?:UTF-8'''')?"?([^";]+)') { [IO.Path]::GetExtension($Matches[1]) } else { '' }
    if (-not $ext) { $ext = switch -Regex ([string]$ctype) { 'png' { '.png' } 'jpe?g' { '.jpg' } 'pdf' { '.pdf' } 'zip' { '.zip' } 'csv' { '.csv' } 'sheet|excel' { '.xlsx' } default { '.bin' } } }
    $bf = Join-Path $bdir "$Save.body$ext"; [IO.File]::WriteAllBytes($bf, $bytes); $content += " saved to $bf"
  }
}


if ($Save) {
  # Evidence envelope per reference/evidence-standard.md: meta + request (secrets redacted) + response
  if (-not $OutDir) { $OutDir = Get-KitPath evidence }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  # secrets in JSON bodies (a login's password, a response's access_token) are redacted at any depth: evidence is published
  function Redact($o) {
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in @($o.Keys)) { $o[$k] = if ("$k" -match $script:secretKey) { '[redacted]' } else { Redact $o[$k] } }; return , $o }
    if ($o -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $o.PSObject.Properties) { $p.Value = if ($p.Name -match $script:secretKey) { '[redacted]' } else { Redact $p.Value } }; return $o }
    if ($o -is [array]) { return , @($o | ForEach-Object { Redact $_ }) }
    $o
  }
  $script:secretKey = '(?i)passw|^pass$|^pwd$|secret|token|api_?key|authorization|cookie'
  function Parse($s) { if (-not $s) { return $null }; if ($s.Length -gt 200KB) { return [ordered]@{ _truncated = $true; text = $s.Substring(0, 200KB) } }; try { Redact ($s | ConvertFrom-Json) } catch { $s } }
  $red = [ordered]@{}; foreach ($k in $script:sentHeaders.Keys) { $red[$k] = if ($k -match '(?i)authorization|cookie|token|key|secret|password') { '[redacted]' } else { $script:sentHeaders[$k] } }
  $code, $check = if ($Save -match '^([A-Za-z0-9]+)-([A-Za-z]*\d+)') { $Matches[1], $Matches[2] } else { '', '' }
  [ordered]@{
    meta     = [ordered]@{ code = $code; check = $check; target = $Target; tenant = $Tenant; user = [string]$u[0]; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); durationMs = $sw.ElapsedMilliseconds; tool = 'api.ps1' }
    request  = [ordered]@{ method = $Method.ToUpper(); url = $uri; headers = $red; body = (Parse $Body) }
    response = [ordered]@{ status = $status; headers = $(if ($rhead) { $rhead } else { [ordered]@{ 'content-type' = [string]$ctype } }); body = (Parse $content) }
  } | ConvertTo-Json -Depth 30 | Out-File (Join-Path $OutDir "$Save.json") -Encoding utf8
}
"HTTP $status"
$content
