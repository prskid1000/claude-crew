#Requires -Version 7
# api-auth (extra): qa.ps1 api with auth types basic, query, cookie (+ CSRF), token, command (HMAC / SigV4 signer), client cert,
# refresh tokens. qa.ps1 api hands every call to Invoke-ApiExtra when this file is present (dot-sourced from adapters/).
# Sections: L5 shell · L7 request · L47 helpers · L51 login · L82 call
# ---- shell: one shell line per OS
function Invoke-Sh([string]$c) { if ($KitIsWindows) { cmd.exe /d /c $c 2>$null } else { /bin/sh -c $c 2>$null } }
# ---- request: target, user, URL, client cert
function Invoke-ApiExtra {
param(
  [string]$Method = 'GET',
  [Parameter(Mandatory)][string]$Path,
  [string]$Body = $null,
  [string]$Target = $null,
  [string]$As = 'admin',
  [string]$Tenant = $null,
  [string]$Save = $null,            # without .json
  [string]$OutDir = $null,          # default: <runtime>/work/evidence
  [hashtable]$Headers = @{},
  [string]$ContentType = 'application/json',
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
# absolute only: a bound hashtable became a relative folder
if ($OutDir -and -not [IO.Path]::IsPathRooted($OutDir)) { throw "-OutDir must be an absolute folder path, got '$OutDir' (a variable holding an object? PowerShell names are case-insensitive: `$o is `$O)" }
# Git Bash rewrites '/api/x' into a Git path: undo
if ($Path -match '^[A-Za-z]:[\\/].*?[\\/]Git[\\/](?<rest>.*)$') { $Path = '/' + ($Matches.rest -replace '\\', '/') }
$here = Split-Path $PSScriptRoot   # adapters/ -> qa-kit/
$cfgFile = Join-Path $here 'targets.local.json'
if (-not (Test-Path $cfgFile)) { throw "Missing $cfgFile - run orch.ps1 setup -WriteLocal, then fill it in" }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
if (-not $Target) { $Target = $cfg.default }
# a QA run pins its targets (KIT_QA_TARGETS)
$pin = @("$env:KIT_QA_TARGETS" -split '[,\s]+' | Where-Object { $_ })
if ($pin.Count -and $Target -notin $pin) { throw "target '$Target' is not this QA run's target ($($pin -join ', ')): a run tests only its own env (run.json target / alsoTargets)" }
$t = $cfg.targets.$Target
if (-not $t) { throw "Unknown target '$Target'. Known: $($cfg.targets.PSObject.Properties.Name -join ', ')" }
if (-not $Tenant) { $Tenant = [string]$t.defaultTenant }
$u = @($t.users.$As)
if (-not $t.users.$As -and $t.auth.type -ne 'none') { throw "No user '$As' in target $Target. Known: $($t.users.PSObject.Properties.Name -join ', ')" }   # not @(...).Count: @($null).Count is 1
if (-not $t.api -and $Path -notmatch '^https?://') { throw "target '$Target' has no api URL (web-only: use browser.mjs)" }
$base = ([string]$t.api).Replace('{tenant}', $Tenant).TrimEnd('/')
$uri = if ($Path -match '^https?://') { $Path } else { $base + $Path }
$a = $t.auth
if ($a.type -eq 'query') { $uri += "$(if ($uri -match '\?') { '&' } else { '?' })$($a.param)=$([uri]::EscapeDataString([string]$u[1]))" }
$tls = if ($a.cert) { @{ Certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([string]$a.cert, [string]$a.certPass) } } else { @{} }

# ---- helpers: placeholders and JSON paths
function Fill($s) { ([string]$s).Replace('{user}', [string]$u[0]).Replace('{pass}', [string]$u[1]).Replace('{tenant}', $Tenant) }
function Get-Field($o, $path) { foreach ($k in $path.Split('.')) { $o = $o.$k }; $o }

# ---- login: token cache, login and refresh
$tokDir = Get-KitPath tokens -Create
$cache = Join-Path $tokDir ("$Target-$Tenant-$As.txt" -replace '[^\w.\-]', '_')
# cache: token (cookie type: Cookie header) + refresh token
function Login([switch]$Refresh) {
  $b = [ordered]@{}; foreach ($p in $a.body.PSObject.Properties) { $b[$p.Name] = if ($p.Value -is [string]) { Fill $p.Value } else { $p.Value } }
  if ($Refresh) { $cid = $b.client_id; $b = [ordered]@{ grant_type = 'refresh_token'; refresh_token = $script:rt }; if ($cid) { $b.client_id = $cid } }   # ordered + hashtable throws: the refresh never ran
  $lu = Fill $(if ($a.path -match '^https?://') { $a.path } else { $base + $a.path })
  $form = $a.contentType -eq 'form' -or $Refresh
  $r = Invoke-WebRequest -Method Post $lu -ContentType $(if ($form) { 'application/x-www-form-urlencoded' } else { 'application/json' }) -Body $(if ($form) { $b } else { $b | ConvertTo-Json -Depth 5 }) -ConnectionTimeoutSeconds 60 -SessionVariable ws @tls
  if ($a.type -eq 'cookie') { $tok = (@($ws.Cookies.GetAllCookies()) | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ' }
  else { $j = $r.Content | ConvertFrom-Json; $tok = Get-Field $j $(if ($a.tokenField) { $a.tokenField } else { 'access_token' }); if ($a.refreshField) { $nrt = Get-Field $j $a.refreshField; if ($nrt) { $script:rt = $nrt } } }   # a refresh answer may omit it: keep the old one
  if (-not $tok) { throw "login to $Target as $As returned no token" }
  "$tok`n$script:rt" | Set-Content $cache -NoNewline
  $tok
}
function AuthHeaders($tok) {
  $h = @{}
  switch ($a.type) {
    'basic' { $h.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($u[0]):$($u[1])")) }
    { $_ -in 'none', 'query' } { }
    'cookie' { $h.Cookie = $tok; if ($a.csrfCookie -and $tok -match "(?:^|; )$([regex]::Escape($a.csrfCookie))=([^;]+)") { $h[$(if ($a.csrfHeader) { $a.csrfHeader } else { 'X-XSRF-TOKEN' })] = [uri]::UnescapeDataString($Matches[1]) } }
    'command' { $env:KIT_API_BODY = $Body; foreach ($l in @(Invoke-Sh ((Fill $a.cmd).Replace('{method}', $Method.ToUpper()).Replace('{url}', $uri)))) { if ($l -match '^\s*([\w-]+)\s*:\s*(.*)$') { $h[$Matches[1]] = $Matches[2] } } }   # HMAC / SigV4 signer
    default { $n, $v = "$(if ($a.header) { $a.header } else { 'Authorization: Bearer {token}' })".Split(':', 2); $h[$n.Trim()] = $v.Trim().Replace('{token}', $tok) }
  }
  $h
}
$tok = $null; $login = $a.type -in 'login', 'cookie'
if ($login) { $tok, $script:rt = if (Test-Path $cache) { @(Get-Content $cache) + '' }; if (-not "$tok".Trim()) { $tok = Login } }   # empty cache file: log in again
elseif ($a.type -eq 'token') { $tok = if ($a.token) { $a.token } else { [string]$u[1] } }

# ---- call: the request with auth headers
function Call($tk) {
  $h = AuthHeaders $tk; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
  if ($Tenant -and $t.tenantHeader) { $h[$t.tenantHeader] = $Tenant }
  $p = @{ Uri = $uri; Method = $Method; Headers = $h; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ContentType = $ContentType } + $tls
  if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body) }
  $script:sentHeaders = $h
  # cookies redacted
  function HeaderMap($pairs) { $m = [ordered]@{}; foreach ($kv in $pairs) { $m[([string]$kv.Key).ToLower()] = if ($kv.Key -match '(?i)cookie|authorization|token|key|secret|password') { '[redacted]' } else { @($kv.Value) -join ', ' } }; $m }
  try { $r = Invoke-WebRequest @p; $hm = HeaderMap $r.Headers.GetEnumerator(); return @([int]$r.StatusCode, $r.Content, [string]$hm['content-type'], $hm) }
  catch {
    $resp = $_.Exception.Response
    if ($resp) { $hm = HeaderMap (@($resp.Headers) + @($resp.Content.Headers)); return @([int]$resp.StatusCode, $_.ErrorDetails.Message, [string]$resp.Content.Headers.ContentType, $hm) } else { return @(0, "ERR $($_.Exception.Message)", '', [ordered]@{}) }
  }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$res = Call $tok
if ($res[0] -eq 401 -and $login) { $tok = if ($script:rt) { try { Login -Refresh } catch { Login } } else { Login }; $sw.Restart(); $res = Call $tok }
$sw.Stop()
$status, $content, $ctype, $rhead = $res
# binary response: saved as a file
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
  # evidence envelope (SKILL.md "Evidence")
  if (-not $OutDir) { $OutDir = Get-KitPath evidence }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  # secrets redacted at any depth
  function Redact($o) {
    if ($o -is [System.Collections.IDictionary]) { foreach ($k in @($o.Keys)) { $o[$k] = if ("$k" -match $script:secretKey) { '[redacted]' } else { Redact $o[$k] } }; return , $o }
    if ($o -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $o.PSObject.Properties) { $p.Value = if ($p.Name -match $script:secretKey) { '[redacted]' } else { Redact $p.Value } }; return $o }
    if ($o -is [array]) { return , @($o | ForEach-Object { Redact $_ }) }
    $o
  }
  $script:secretKey = '(?i)passw|^pass$|^pwd$|secret|token|api_?key|authorization|cookie'
  function Parse($s) { if (-not $s) { return $null }; if ($s.Length -gt 200KB) { return [ordered]@{ _truncated = $true; text = $s.Substring(0, 200KB) } }; try { Redact (ConvertFrom-Json $s -NoEnumerate) } catch { $s } }
  $red = [ordered]@{}; foreach ($k in $script:sentHeaders.Keys) { $red[$k] = if ($k -match '(?i)authorization|cookie|token|key|secret|password') { '[redacted]' } else { $script:sentHeaders[$k] } }
  $code, $check = if ($Save -match '^([A-Za-z0-9]+)-([A-Za-z]*\d+)') { $Matches[1], $Matches[2] } else { '', '' }
  [ordered]@{
    meta     = [ordered]@{ code = $code; check = $check; target = $Target; tenant = $Tenant; user = [string]$u[0]; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); durationMs = $sw.ElapsedMilliseconds; tool = 'qa.ps1 api' }
    request  = [ordered]@{ method = $Method.ToUpper(); url = ($uri -replace '(?i)([?&][^=&]*(key|token|secret|sig|pass)[^=&]*=)[^&]*', '$1[redacted]'); headers = $red; body = (Parse $Body) }
    response = [ordered]@{ status = $status; headers = $(if ($rhead) { $rhead } else { [ordered]@{ 'content-type' = [string]$ctype } }); body = (Parse $content) }
  } | ConvertTo-Json -Depth 30 | Out-File (Join-Path $OutDir "$Save.json") -Encoding utf8
}
"HTTP $status"
$content
if (-not $status -or [int]$status -ge 400) { exit 1 }   # else a 500 looked like success
}
