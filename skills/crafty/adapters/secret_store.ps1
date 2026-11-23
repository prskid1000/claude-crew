#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (a missing secret throws).
# secret-store (README "Adapters"): test logins and keys by name `<scope>/<target>/<user>/<field>`; a value stays in memory:
# never printed, logged or written to a run dir. secrets.store: file (default: skills/pokey/targets.local.json, name
# targets/<t>/<user>/login|password), env (KIT_SECRET_<NAME>), keychain (the OS store, read-only), command
# (secrets.command.<verb> CLI lines: a vault, password manager or cloud secret manager). caps: write, list, rotate.
# A config value `secret:<name>` resolves through the store (Resolve-KitSecretRef). Guard: Get-KitSecretPaths.
# Sections: L9 store · L30 backends
# ---- store: the configured backend, the verbs callers use
function Get-KitSecretStore { "$(Get-KitSetting 'secrets.store' 'file')".ToLower() }
function Get-KitSecret([string]$Name) {
  $s = Get-KitSecretStore; $v = Invoke-KitAdapter 'secret-store' $s 'get' @{ name = $Name }
  if ($null -eq $v -or "$v" -eq '') { throw "secret ${Name}: not in store $s (names: pokey.ps1 user list)" }; "$v"
}
function Set-KitSecret([string]$Name, [string]$Value) {
  $s = Get-KitSecretStore; if (-not (Test-KitCap 'secret-store' $s 'write')) { throw "UNSUPPORTED secret-store/$s/set: store $Name in $s by hand" }
  $null = Invoke-KitAdapter 'secret-store' $s 'set' @{ name = $Name; value = $Value }; "stored $Name (store $s, value not shown)"
}
function Remove-KitSecret([string]$Name) { $s = Get-KitSecretStore; if (Test-KitCap 'secret-store' $s 'write') { $null = Invoke-KitAdapter 'secret-store' $s 'delete' @{ name = $Name } } }
# names only, never values
function Get-KitSecretNames([string]$Prefix = '') { $s = Get-KitSecretStore; if (Test-KitCap 'secret-store' $s 'list') { @(Invoke-KitAdapter 'secret-store' $s 'list' @{ prefix = $Prefix } | Where-Object { "$_".StartsWith($Prefix) }) } }
function Resolve-KitSecretRef($Value) { if ("$Value" -match '^secret:(.+)$') { Get-KitSecret $Matches[1] } else { $Value } }
# files whose reads the guard denies: secrets.<store>.paths, plus the file store's own file
function Get-KitSecretPaths {
  $s = Get-KitSecretStore
  @(@(if ($s -eq 'file') { 'skills/pokey/targets.local.json' }) + @(Get-KitSetting "secrets.$s.paths" @()) | Where-Object { $_ } | Select-Object -Unique)
}
function Get-KitSecretFile { $f = Join-Path (Split-Path $KitLibDir) 'pokey/targets.local.json'; if (Test-Path -LiteralPath $f) { return $f }; Join-Path (Split-Path (Split-Path (Split-Path $KitConf.ConfigFile))) 'skills/pokey/targets.local.json' }

# ---- backends: $a = name, value, prefix
# adapter:secret-store/file: targets/<t>/<user>/login|password in targets.local.json (users.<user> = [login, password])
function __SecFileName([string]$Name) { if ($Name -notmatch '^targets/(?<t>[^/]+)/(?<u>[^/]+)/(?<f>login|password)$') { throw "secret-store file: name $Name is not targets/<target>/<user>/login|password" }; $Matches }
Register-KitAdapter 'secret-store' 'file' @{ caps = @{ write = $true; list = $true; rotate = $true }
  get = { param($a) $m = __SecFileName $a.name; $f = Get-KitSecretFile; if (-not (Test-Path -LiteralPath $f)) { return $null }
    $us = Get-KitMember (Get-KitMember (Get-KitMember (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) 'targets') $m.t) 'users'
    $u = @(Get-KitMember $us $m.u | ForEach-Object { $_ }); if ($u.Count -lt 2) { return $null }; $u[[int]($m.f -eq 'password')] }
  set = { param($a) $m = __SecFileName $a.name; $f = Get-KitSecretFile
    Invoke-KitLocked $f { $d = if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
      if (-not $d.targets) { $d.targets = @{} }; if (-not $d.targets[$m.t]) { $d.targets[$m.t] = @{} }; $tt = $d.targets[$m.t]; if (-not $tt.users) { $tt.users = @{} }
      $u = @($tt.users[$m.u]); if ($u.Count -lt 2) { $u = @($m.u, '') }; $u[[int]($m.f -eq 'password')] = $a.value; $tt.users[$m.u] = $u
      [IO.File]::WriteAllText($f, ($d | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false)) } }
  delete = { param($a) $m = __SecFileName $a.name; $f = Get-KitSecretFile; if (-not (Test-Path -LiteralPath $f)) { return }
    Invoke-KitLocked $f { $d = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable; $d.targets[$m.t].users.Remove($m.u); [IO.File]::WriteAllText($f, ($d | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false)) } }
  list = { param($a) $f = Get-KitSecretFile; if (-not (Test-Path -LiteralPath $f)) { return @() }
    $d = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    foreach ($t in @(Get-KitProps $d.targets)) { foreach ($u in @(Get-KitProps $t.Value.users)) { foreach ($fl in 'login', 'password') { "targets/$($t.Name)/$($u.Name)/$fl" } } } }
}
# adapter:secret-store/env: KIT_SECRET_<NAME> (non-alphanumerics -> _, upper case); read-only
function __SecEnvName([string]$Name) { 'KIT_SECRET_' + ($Name -replace '[^A-Za-z0-9]', '_').ToUpper() }
Register-KitAdapter 'secret-store' 'env' @{ caps = @{ write = $false; list = $true; rotate = $false }
  get = { param($a) [Environment]::GetEnvironmentVariable((__SecEnvName $a.name)) }
  list = { param($a) @(Get-ChildItem Env: | Where-Object Name -like 'KIT_SECRET_*' | ForEach-Object { $_.Name.Substring(11).ToLower() -replace '_', '/' }) }
}
# adapter:secret-store/keychain: the OS store, service = the name (Windows Credential Manager, macOS Keychain, libsecret)
Register-KitAdapter 'secret-store' 'keychain' @{ caps = @{ write = $false; list = $false; rotate = $false }
  get = { param($a)
    if ($KitIsWindows) { return & (Join-Path $KitLibDir 'flagged.ps1') credread -Text $a.name }
    $r = if (Get-Command security -ErrorAction SilentlyContinue) { Invoke-KitNetExe 'security' @('find-generic-password', '-s', $a.name, '-w') } else { Invoke-KitNetExe 'secret-tool' @('lookup', 'service', $a.name) }
    if (-not $r.code) { "$($r.out)".Trim() } }
}
# adapter:secret-store/command: secrets.command.get|set|list|delete = CLI lines ({name}, {value}, {prefix}); list prints names
Register-KitAdapter 'secret-store' 'command' @{ caps = { $c = Get-KitSetting 'secrets.command' $null; @{ write = [bool](Get-KitMember $c 'set'); list = [bool](Get-KitMember $c 'list'); rotate = [bool](Get-KitMember $c 'set') } }
  '*' = { param($a, $v) Invoke-KitCommand 'secret-store' (Get-KitSetting 'secrets.command' $null) $v $a }
}
# adapter-end:secret-store
