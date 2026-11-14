#Requires -Version 7
# Usage: dot-sourced by pokey.ps1 from adapters/. Exit codes: none here (its verbs exit through pokey.ps1).
# api-auth: request headers for pokey.ps1 api auth kinds basic, cookie (+ CSRF) and command (HMAC / SigV4 signer). The one
# Invoke-Api (pokey.ps1) does targets, users, login, refresh, query keys, client certs, tokens and evidence for every kind.
# Sections: L6 shell · L8 headers
# ---- shell: one shell line per OS
function Invoke-Sh([string]$c) { if ($KitIsWindows) { cmd.exe /d /c $c 2>$null } else { /bin/sh -c $c 2>$null } }
# ---- headers: per auth kind; $Fill fills {user} {pass} {tenant}
function Get-ApiAuthHeaders($Auth, $User, [string]$Token, [string]$Method, [string]$Uri, [string]$Body, [scriptblock]$Fill) {
  $h = @{}
  switch ([string]$Auth.type) {
    'basic' { $h.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($User[0]):$($User[1])")) }
    'cookie' { $h.Cookie = $Token; if ($Auth.csrfCookie -and $Token -match "(?:^|; )$([regex]::Escape($Auth.csrfCookie))=([^;]+)") { $h[$(if ($Auth.csrfHeader) { $Auth.csrfHeader } else { 'X-XSRF-TOKEN' })] = [uri]::UnescapeDataString($Matches[1]) } }
    'command' { $env:KIT_API_BODY = $Body; foreach ($l in @(Invoke-Sh ((& $Fill $Auth.cmd).Replace('{method}', $Method.ToUpper()).Replace('{url}', $Uri)))) { if ($l -match '^\s*([\w-]+)\s*:\s*(.*)$') { $h[$Matches[1]] = $Matches[2] } } }
  }
  $h
}
