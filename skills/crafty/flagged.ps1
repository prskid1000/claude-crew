<#
flagged.ps1: the few .NET calls whose names make pwsh 7 log a script's full text (event 4104) each time it loads; kit
scripts run this file for them, never dot-source it, so the hot path (guard hook, every verb) logs nothing (kitbag lint SBLOG).
pwsh 7: & <kit>/skills/crafty/flagged.ps1 <verb> ...
 hash -Text <text> [-Algorithm MD5|SHA1|SHA256]  upper-case hex digest of the UTF-8 bytes (lib.ps1 Get-KitHash)
 linkfiles -Text <from> -To <to> [-Release] [-Move]  <from>'s files into <to> as hard links, no copies (envy.ps1 releases;
   SHA1 of every file): to <from>'s own files (-Release: a staged release, never rewritten; no app.aot) or to one copy per
   content hash in <to>/../_lib (-Move: taken from <from>), listed in <to>/.libs.json; no hard links there: copies
 ipv4  IPv4 addresses of the up, non-loopback, non-tunnel interfaces, in interface order (envy.ps1 LanIp)
 credread -Text <target>  a Windows generic credential's secret, to the caller only (a tracker CLI's stored token)
 credwrite | creddelete -Text <target>  write (value: env KIT_SECRET_VALUE, never argv) or delete one (secret-store keychain); True | False
 credlist  the names of the generic credentials the kit wrote (user kit), never values
Exit codes: 0 ok · 2 usage
#>
#Requires -Version 7
param([string]$Verb, [string]$Text, [ValidateSet('MD5', 'SHA1', 'SHA256')][string]$Algorithm = 'SHA256', [string]$To, [switch]$Release, [switch]$Move)
switch ($Verb) {
  'hash' {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $digest = switch ($Algorithm) { 'MD5' { [Security.Cryptography.MD5]::HashData($bytes) } 'SHA1' { [Security.Cryptography.SHA1]::HashData($bytes) } default { [Security.Cryptography.SHA256]::HashData($bytes) } }
    [Convert]::ToHexString($digest)
  }
  'linkfiles' {   # one process per release: Get-FileHash costs 1 ms a file
    $store = Join-Path (Split-Path $To) '_lib'; $map = [ordered]@{}
    foreach ($f in Get-ChildItem -LiteralPath $Text -File -Recurse -Force) {
      $rel = [IO.Path]::GetRelativePath($Text, $f.FullName); $src = $f.FullName; if ($Release -and $rel -eq 'app.aot') { continue }
      $dst = Join-Path $To $rel; [void][IO.Directory]::CreateDirectory((Split-Path $dst))
      if (-not $Release) {
        $fs = [IO.File]::OpenRead($src); try { $h = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($fs)) } finally { $fs.Dispose() }
        $src = Join-Path $store "$h$($f.Extension)"; $map[$rel] = $h
        if (-not (Test-Path -LiteralPath $src)) { [void][IO.Directory]::CreateDirectory($store); if ($Move) { Move-Item -LiteralPath $f.FullName $src } else { Copy-Item -LiteralPath $f.FullName $src } }
      }
      try { $null = New-Item -ItemType HardLink -Path $dst -Target $src -ErrorAction Stop } catch { Copy-Item -LiteralPath $src $dst -Force }
    }
    if ($map.Count) { ConvertTo-Json -InputObject $map | Set-Content -LiteralPath (Join-Path $To '.libs.json') -Encoding utf8 }
  }
  'ipv4' {
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
      Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -notin 'Loopback', 'Tunnel' } |
      ForEach-Object { $_.GetIPProperties().UnicastAddresses } | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { "$($_.Address)" }
  }
  { $_ -in 'credread', 'credwrite', 'creddelete', 'credlist' } {   # a generic Windows credential (UTF-8 blob, as go-keyring stores it); a read returns it to the caller, never printed by it; a write takes env KIT_SECRET_VALUE
    if (-not ('KitCred2' -as [type])) {
      Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class KitCred2 {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct C { public int F; public int T; public string N; public string Cm; public long W; public int S; public IntPtr B; public int P; public int A; public IntPtr At; public string Ta; public string U; }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredReadW(string n, int t, int f, out IntPtr c);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWriteW(ref C c, int f);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDeleteW(string n, int t, int f);
        [DllImport("advapi32.dll")] static extern void CredFree(IntPtr c);
        public static string Read(string n) { IntPtr p; if (!CredReadW(n, 1, 0, out p)) return null; try { var c = (C)Marshal.PtrToStructure(p, typeof(C)); var b = new byte[c.S]; Marshal.Copy(c.B, b, 0, c.S); return System.Text.Encoding.UTF8.GetString(b); } finally { CredFree(p); } }
        public static bool Write(string n, string v) { var b = System.Text.Encoding.UTF8.GetBytes(v); var c = new C(); c.T = 1; c.N = n; c.S = b.Length; c.P = 2; c.U = "kit"; c.B = Marshal.AllocHGlobal(Math.Max(1, b.Length)); try { Marshal.Copy(b, 0, c.B, b.Length); return CredWriteW(ref c, 0); } finally { Marshal.FreeHGlobal(c.B); } }
        public static bool Delete(string n) { return CredDeleteW(n, 1, 0); }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredEnumerateW(string f, int fl, out int n, out IntPtr c);
        public static string[] List() { int n; IntPtr p; var r = new System.Collections.Generic.List<string>(); if (!CredEnumerateW(null, 0, out n, out p)) return r.ToArray();
          try { for (int i = 0; i < n; i++) { var c = (C)Marshal.PtrToStructure(Marshal.ReadIntPtr(p, i * IntPtr.Size), typeof(C)); if (c.T == 1 && c.U == "kit") r.Add(c.N); } } finally { CredFree(p); } return r.ToArray(); } }' }
    switch ($Verb) { 'credread' { [KitCred2]::Read($Text) } 'credwrite' { [KitCred2]::Write($Text, "$env:KIT_SECRET_VALUE") } 'credlist' { [KitCred2]::List() } default { [KitCred2]::Delete($Text) } }
  }
  default { 'usage: flagged.ps1 hash -Text <text> [-Algorithm MD5|SHA1|SHA256] | linkfiles -Text <from> -To <to> [-Release] [-Move] | ipv4 | credlist | credread | credwrite | creddelete -Text <target>'; exit 2 }
}
