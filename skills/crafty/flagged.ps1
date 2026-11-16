<#
flagged.ps1: the few .NET calls whose names make pwsh 7 log a script's full text (event 4104) each time it loads; kit
scripts run this file for them, never dot-source it, so the hot path (guard hook, every verb) logs nothing (kitbag lint SBLOG).
pwsh 7: & <kit>/skills/crafty/flagged.ps1 <verb> ...
 hash -Text <text> [-Algorithm MD5|SHA1|SHA256]  upper-case hex digest of the UTF-8 bytes (lib.ps1 Get-KitHash)
 ipv4  IPv4 addresses of the up, non-loopback, non-tunnel interfaces, in interface order (envy.ps1 LanIp)
Exit codes: 0 ok · 2 usage
#>
#Requires -Version 7
param([string]$Verb, [string]$Text, [ValidateSet('MD5', 'SHA1', 'SHA256')][string]$Algorithm = 'SHA256')
switch ($Verb) {
  'hash' {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $digest = switch ($Algorithm) { 'MD5' { [Security.Cryptography.MD5]::HashData($bytes) } 'SHA1' { [Security.Cryptography.SHA1]::HashData($bytes) } default { [Security.Cryptography.SHA256]::HashData($bytes) } }
    [Convert]::ToHexString($digest)
  }
  'ipv4' {
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
      Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -notin 'Loopback', 'Tunnel' } |
      ForEach-Object { $_.GetIPProperties().UnicastAddresses } | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { "$($_.Address)" }
  }
  default { 'usage: flagged.ps1 hash -Text <text> [-Algorithm MD5|SHA1|SHA256] | ipv4'; exit 2 }
}
