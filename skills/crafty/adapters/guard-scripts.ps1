#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# guard rule script-faults (owner 2026-11-25; the classes of kitbag.py faults): agents' own commands and scripts that fail the same way
# again and again: python -c through a .bat shim, a Bash command bash -n cannot parse, a PowerShell payload (pwsh -Command from Bash)
# that does not parse, a Git Bash "/x" argument to a Windows program (rewritten with MSYS_NO_PATHCONV=1), a work/agents .ps1 whose
# variables differ only by case; decide wait under a shell timeout, Git Bash /tmp to a Windows python or node, python -c inside
# pwsh -Command, sed -i with backslashes on a .py. Test-KitScriptEdit (crafty.ps1 guard, file edits): the .ps1 case check.
# Retired 2026-11-27 (0 hits in 30 d, the tool says it): a PowerShell tool command that does not parse, a missing mvnw / gradlew,
# .state/tracking.json, illegal Java escapes. Each deny names the fix and its class (script-fault <class>). Rule file-dumps: a
# whole-file cat / type / Get-Content over the Read caps.
# Sections: L12 helpers · L77 edits · L89 commands · L139 reads
# ---- helpers: bash words, the python shim, Git Bash, parsers
function Get-KitBashWord([string]$Text, [int]$At) {   # the bash word at $At, quotes removed ($vars kept): @(value, next index); $null = an open quote
  $sb = [Text.StringBuilder]::new(); $i = $At
  while ($i -lt $Text.Length -and -not [char]::IsWhiteSpace($Text[$i]) -and ';|&<>()'.IndexOf($Text[$i]) -lt 0) {
    $ch = $Text[$i]
    if ($ch -eq "'") { $j = $Text.IndexOf("'", $i + 1); if ($j -lt 0) { return @($null, $Text.Length) }; [void]$sb.Append($Text.Substring($i + 1, $j - $i - 1)); $i = $j + 1 }
    elseif ($ch -eq '"') {
      $i++; while ($i -lt $Text.Length -and $Text[$i] -ne '"') { if ($Text[$i] -eq '\' -and $i + 1 -lt $Text.Length -and '"\$`'.IndexOf($Text[$i + 1]) -ge 0) { $i++ }; [void]$sb.Append($Text[$i]); $i++ }
      if ($i -ge $Text.Length) { return @($null, $Text.Length) }; $i++ }
    elseif ($ch -eq '\' -and $i + 1 -lt $Text.Length) { [void]$sb.Append($Text[$i + 1]); $i += 2 }
    else { [void]$sb.Append($ch); $i++ }
  }
  @($sb.ToString(), $i)
}
function Get-KitBashWords([string]$Text, [switch]$Source) {   # every bash word of one command segment; -Source: as written (quotes kept)
  $i = 0; while ($i -lt $Text.Length) { while ($i -lt $Text.Length -and [char]::IsWhiteSpace($Text[$i])) { $i++ }; if ($i -ge $Text.Length) { break }
    $w = Get-KitBashWord $Text $i; if ($w[1] -le $i) { $i++; continue }; if ($null -ne $w[0]) { , $(if ($Source) { $Text.Substring($i, $w[1] - $i) } else { $w[0] }) }; $i = $w[1] }
}
function Get-KitBashExpansion([string]$Word) {   # what Bash expands in a word as written: '`' (command substitution), '$', or ''
  $live = $Word -replace "'[^']*'", '' -replace '\\[$`"\\]', ''
  if ($live.Contains('`')) { '`' } elseif ($live -match '\$[\w{(?@*#!-]') { '$' } else { '' }
}
function Get-KitPyCode([string[]]$Words) {   # the -c code of a bare python / python3 / py call (its options first), else $null
  $pyAt = [array]::FindIndex($Words, [Predicate[string]] { param($w) $w -match '^py(thon[\d.]*)?(\.exe)?$' }); if ($pyAt -lt 0) { return $null }
  for ($j = $pyAt + 1; $j -lt $Words.Count; $j++) { if ($Words[$j] -ceq '-c') { return $(if ($j + 1 -lt $Words.Count) { $Words[$j + 1] }) }; if ($Words[$j] -ceq '-m') { return $null }; if ($Words[$j] -cmatch '^-[XW]$') { $j++ } elseif ($Words[$j] -notmatch '^-') { return $null } }
}
function Get-KitPyShim {   # the python on PATH when it is a .bat / .cmd shim (pyenv-win): cmd.exe re-reads its arguments; KIT_PY_SHIM: tests ('0' = none)
  if ($null -eq $script:KitPyShimFound) {
    $script:KitPyShimFound = if ($env:KIT_PY_SHIM) { if ($env:KIT_PY_SHIM -eq '0') { '' } else { $env:KIT_PY_SHIM } } else { [string](@(Get-Command python -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source | Where-Object { $_ -match '\.(bat|cmd)$' })[0]) } }
  $script:KitPyShimFound
}
function Get-KitGitBash {   # Git for Windows' bash.exe (never WSL's System32 bash); elsewhere /bin/bash
  if ($null -eq $script:KitGitBashFound) {
    $gitExe = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)[0].Source
    $script:KitGitBashFound = [string]$(if (-not $IsWindows) { '/bin/bash' } elseif ($gitExe) { @((Join-Path (Split-Path (Split-Path $gitExe)) 'bin/bash.exe'), (Join-Path (Split-Path (Split-Path (Split-Path $gitExe))) 'bin/bash.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1 }) }
  $script:KitGitBashFound
}
function Test-KitBashParse([string]$Text) {   # bash -n's first error line ('' = parses, no bash, or no answer within 3 s)
  $bashExe = Get-KitGitBash; if (-not $bashExe) { return '' }
  $psi = [Diagnostics.ProcessStartInfo]::new($bashExe, '-n'); $psi.RedirectStandardInput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  try { $proc = [Diagnostics.Process]::Start($psi); $errTask = $proc.StandardError.ReadToEndAsync(); $proc.StandardInput.Write($Text.Replace("`r`n", "`n")); $proc.StandardInput.Close()
    if (-not $proc.WaitForExit(3000)) { try { $proc.Kill() } catch {}; return '' }
    if ($proc.ExitCode -eq 0) { return '' }; "$(@("$($errTask.Result)" -split "`r?`n" | Where-Object { $_.Trim() })[0])" -replace '^.*?bash(\.exe)?: ', '' } catch { '' }
}
function Get-KitPsParseError([string]$Text) {   # the first PowerShell parse error: 'line <n>: <message>' ('' = parses)
  $tokens = $null; $errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
  if (@($errs).Count) { "line $($errs[0].Extent.StartLineNumber): $($errs[0].Message)" } else { '' }
}
$script:KitPsAutoVars = @('_', 'psitem', 'true', 'false', 'null', 'args', 'input', 'this', 'matches', 'error', 'lastexitcode', 'home', 'host', 'pid', 'pwd', 'psscriptroot', 'pscommandpath', 'myinvocation', 'psboundparameters', 'executioncontext', 'foreach', 'switch', 'ofs', 'sender', 'event', 'eventargs', 'profile', 'psversiontable', 'psitem', 'stacktrace', 'iswindows', 'islinux', 'ismacos', 'erroractionpreference', 'verbosepreference', 'progresspreference', 'warningpreference', 'informationpreference', 'confirmpreference', 'whatifpreference', 'pshome', 'shellid', 'nestedpromptlevel')
function Find-KitPsCaseClash([string]$Text) {   # one variable assigned under two spellings in one function or the script body (the second overwrites the first): '$a (line 3) / $A (line 9)'
  $tokens = $null; $errs = $null; $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
  $byScope = @{}
  foreach ($v in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) {
    $path = $v.VariablePath; if ($path.IsDriveQualified -and -not ($path.IsScript -or $path.IsGlobal -or $path.IsLocal -or $path.IsPrivate)) { continue }
    $name = $path.UserPath -replace '^(script|global|local|private|using):', ''; if ($name.ToLower() -in $script:KitPsAutoVars) { continue }
    $scope = $v.Parent; while ($scope -and $scope -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope = $scope.Parent }
    $key = if ($scope) { $scope.Extent.StartOffset } else { -1 }
    $set = ($v.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and [object]::ReferenceEquals($v.Parent.Left, $v)) -or ($v.Parent -is [System.Management.Automation.Language.ForEachStatementAst] -and [object]::ReferenceEquals($v.Parent.Variable, $v))   # -and / -or: one precedence; a param reassigned ($Path -> $path) is no clash
    if (-not $byScope[$key]) { $byScope[$key] = @{} }; $low = $name.ToLower(); if (-not $byScope[$key][$low]) { $byScope[$key][$low] = [Collections.Generic.List[object]]::new() }
    $forms = $byScope[$key][$low]; $seen = @($forms | Where-Object { $_.name -ceq $name })[0]   # case-sensitive: a hashtable key would fold $P into $p
    if (-not $seen) { $forms.Add(@{ name = $name; line = $v.Extent.StartLineNumber; set = $set }) } elseif ($set) { $seen.set = $true }
  }
  foreach ($scopeVars in $byScope.Values) { foreach ($forms in $scopeVars.Values) {
      $sets = @($forms | Where-Object { $_.set }); if ($sets.Count -gt 1) { "`$$($sets[0].name) (line $($sets[0].line)) / `$$($sets[1].name) (line $($sets[1].line))" } } }
}
# ---- edits: Write / Edit / MultiEdit content of a work/agents .ps1 (case clash); only new problems count
function Test-KitScriptEdit([string]$Path, $ToolInput) {
  if (-not $Path -or $Path -notmatch '\.ps1$' -or ($Path -replace '\\', '/') -notmatch '/work/agents/') { return }
  $old = if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { '' }
  $new = if ($null -ne $ToolInput.content) { [string]$ToolInput.content } else { $old }
  foreach ($ed in @($(if ($null -ne $ToolInput.old_string) { $ToolInput } else { @($ToolInput.edits) })) | Where-Object { $_ -and $null -ne $_.old_string }) {
    $at = $new.IndexOf([string]$ed.old_string); if ($at -lt 0) { return }   # the tool itself refuses a missing old_string
    $new = if ($ed.replace_all) { $new.Replace([string]$ed.old_string, [string]$ed.new_string) } else { $new.Substring(0, $at) + $ed.new_string + $new.Substring($at + ([string]$ed.old_string).Length) }
  }
  $was = @(Find-KitPsCaseClash $old); $hit = @(Find-KitPsCaseClash $new | Where-Object { $_ -notin $was })
  if ($hit) { return "kit guard: $Path`: $($hit[0]) are ONE variable (PowerShell names are case-insensitive: the second overwrites the first): rename one to a full word (`$appPath, `$argList) (script-fault ps-case-clash)" }
}
# ---- commands: shim quotes, bash -n, PowerShell payloads, MSYS path conversion, case-clashing agent scripts
Register-KitAdapter 'guard' 'script-faults' @{ check = { param($a)
    $raw = "$($a.raw)"; $hook = $a.hook; $tool = "$($hook.tool_name)"; $cwd = if ($hook.cwd) { "$($hook.cwd)" } else { (Get-Location).Path }; $cwd0 = $cwd   # $cwd follows cd; $null after a cd to an unknown place
    $isBash = $tool -eq 'Bash'
    $fix = "& $($KitCmd.dev) dir -Agent <id> -Name"
    $body = [regex]::Replace($raw, '(?ms)<<-?\s*([''"]?)(\w+)\1([^\n]*)\n.*?^\s*\2\s*$', '<<doc$3')   # heredoc bodies are data
    $segs = if ($isBash -or -not $tool) { @(Split-CommandSegments $body 'Bash') } else { @() }
    # python -c through a .bat shim: cmd.exe re-parses quotes, | & < > ^ % and cuts at a newline ('|| goto :error')
    if (($shim = Get-KitPyShim)) {
      # a bare python / python3 / py only: an explicit python.exe path skips the shim
      $codes = if ($tool -eq 'PowerShell') { @(@(CmdAsts $raw) | ForEach-Object { Get-KitPyCode @($_.CommandElements | ForEach-Object { if ($null -ne $_.Value) { "$($_.Value)" } else { "$($_.Extent.Text)" } }) }) }
        else { @(foreach ($seg in @(Split-CommandSegments $body 'Bash')) { Get-KitPyCode @(Get-KitBashWords $seg) }) }
      # cmd.exe ends the call at a newline, toggles on \" and splits an unquoted (space-free) argument at & | < > ^
      if (@($codes | Where-Object { $_ -match '[\r\n"]' -or ($_ -notmatch '\s' -and $_ -match '[&|<>^()%]') }).Count) { return "kit guard: python here is $shim (a .bat shim: cmd.exe re-reads python -c code, so quotes, | & < > ^ ( ) % and newlines break it: '|| goto :error'). Write the program to a .py file (Write tool; $fix x.py) and run python -X utf8 <file> (script-fault py-shim-quote)." }
    }
    if ($isBash -and $raw -match '[''"`(]|<<' -and ($be = Test-KitBashParse $raw)) { return "kit guard: Bash cannot parse this command (bash -n: $be): an unbalanced quote or heredoc marker. Put the program in a file (Write tool; $fix x.sh / x.py / x.ps1) and run it; keep shell quoting one level deep (script-fault sh-quote)." }
    foreach ($seg in $segs) {
      $words = @(Get-KitBashWords $seg); if (-not $words.Count) { continue }
      $wi = 0; while ($wi -lt $words.Count -and $words[$wi] -match '^\w+=|^(env|command|exec|nohup|timeout|sudo|time|\d+[smh]?)$') { $wi++ }; if ($wi -ge $words.Count) { continue }
      $leaf = ($words[$wi] -replace '^.*[\\/]', '').ToLower() -replace '\.(exe|cmd|bat)$', ''
      if ($leaf -match '^(pwsh|powershell)$') {   # the payload PowerShell gets after Bash removed the quotes ('' is no escape in Bash)
        $ci = [array]::FindIndex([string[]]$words, [Predicate[string]] { param($w) $w -match '^-(c|command)$' }); $src = @(Get-KitBashWords $seg -Source)
        $exp = if ($ci -gt 0 -and $ci + 1 -lt $src.Count) { Get-KitBashExpansion $src[$ci + 1] }
        if ($exp -eq '`') { return "kit guard: Bash runs the backticks inside this double-quoted pwsh -Command as a command substitution (PowerShell's escape character is Bash's): single-quote the code, or write it to a .ps1 (Write tool; $fix x.ps1) and run pwsh -NoProfile -File <file> (script-fault ps-parse)." }
        # -Command -: the code comes on stdin
        if (-not $exp -and $ci -gt 0 -and $ci + 1 -lt $words.Count -and $words[$ci + 1] -ne '-' -and ($pe = Get-KitPsParseError $words[$ci + 1])) { return "kit guard: the -Command code PowerShell gets after Bash quoting does not parse ($pe; '' inside '...' ends the Bash quote). Write it to a .ps1 (Write tool; $fix x.ps1) and run pwsh -NoProfile -File <file> (script-fault ps-parse)." }
        if ($ci -gt 0 -and $ci + 1 -lt $words.Count -and $words[$ci + 1] -match '(^|[\s;&(])python[\d.]*(\.exe)?\s(-\w+\s+\S+\s+)*-c\s') { return "kit guard: python -c inside pwsh -Command passes three quoting layers (Bash, PowerShell, the python shim): its strings end early (SyntaxError: unterminated string literal). Write the program to a .py (Write tool; $fix x.py) and run python -X utf8 <file> (script-fault py-shell-source)." }
      }
      # sed -i with an escaped backslash on a .py: Bash and sed each eat one level of the escapes (SyntaxError at the next run)
      if ($leaf -eq 'sed' -and @($words | Where-Object { $_ -cmatch '^-[a-zA-Z]*i' }).Count -and @($words | Where-Object { $_ -match '\.py$' }).Count -and $seg -match '\\\\') { return "kit guard: sed -i with escaped backslashes on a .py file loses a level of escaping (SyntaxError: unexpected character after line continuation character): change it with the Edit tool (script-fault py-shell-source)." }
      # Git Bash turns a /x argument into C:/Program Files/Git/x for a Windows program (/d/x: the Git Bash path rule; /tmp, /dev: mounts):
      # the segment runs with MSYS_NO_PATHCONV=1 (rewrite), unless it also passes a mount path that needs the conversion
      if ($isBash -and $raw -notmatch 'MSYS_NO_PATHCONV=1|MSYS2_ARG_CONV_EXCL' -and $leaf -match '^(node|python[\d.]*|py|pwsh|powershell|java|javac|mvnw?|mvnd|gradlew?|npx|npm|yarn|pnpm|adb|dotnet|glab|gh|aws|docker|kubectl|curl|ffmpeg)$' -and $raw -notmatch 'pokey\.ps1') {   # pokey.ps1 api turns C:/Program Files/Git/x back into /x
        $argsAfter = @($words | Select-Object -Skip ($wi + 1))
        $bad = @($argsAfter | Where-Object { $_ -match '^(--?[\w-]+=)?/(?![/\s]|(tmp|dev|proc|usr|bin|etc|[A-Za-z])(/|$))[\w.@~+-]' -and $_ -notmatch '\s|\*' })
        if ($bad) {
          $segAt = "$($a.rw)".IndexOf($seg.Trim()); $mount = @($argsAfter | Where-Object { $_ -match '^(--?[\w-]+=)?/(tmp|dev|proc|usr|bin|etc)(/|$)' }).Count
          if ($seg.Trim() -and $segAt -ge 0 -and -not $mount) { return @{ rewrite = $a.rw.Substring(0, $segAt) + 'MSYS_NO_PATHCONV=1 ' + $a.rw.Substring($segAt); why = "Git Bash would turn $($bad[0]) for $leaf into C:/Program Files/Git$($bad[0] -replace '^--?[\w-]+=', ''): MSYS_NO_PATHCONV=1 keeps it (rule msys-path)" } }
          return "kit guard: Git Bash rewrites the argument $($bad[0]) for $leaf (a Windows program) into C:/Program Files/Git$($bad[0] -replace '^--?[\w-]+=', '') (MSYS path conversion). Prefix the command with MSYS_NO_PATHCONV=1 (or export MSYS_NO_PATHCONV=1 first), or run it from the PowerShell tool (rule msys-path)." }
      }
    }
    # killed waits, Git Bash /tmp (faults: decide wait under timeout, /tmp read by a Windows python)
    if ($isBash -and $raw -match '\bdecide\s+wait\b' -and $raw -match '(^|[;&|(]\s*)timeout\s+\S+\s' -and $raw -notmatch '-MaxMinutes') { return "kit guard: a shell timeout kills decide wait mid-poll and drops its answer: run decide wait -Id <id> -MaxMinutes <m> (PENDING + exit 1 at the limit; default 4, inside the 5 min prompt cache) (script-fault decide-wait-timeout)." }
    if ($isBash -and $raw -match '(^|[\s;&|(])(python[\d.]*|py|node)(\.exe)?\s' -and $raw -match '[(=,\[]\s*r?[''"]/tmp/') { return "kit guard: a /tmp path inside python or node code opens <drive>:\tmp, not Git Bash's /tmp (only a bare argument is converted): put the file under $fix <file> (script-fault posix-path)." }   # arch-ok: matches agents' /tmp, writes none
    # a work/agents .ps1 about to run with $a / $A in one scope (the second spelling overwrites the first)
    foreach ($m in [regex]::Matches($raw, '(?:-File\s+|(?:^|[;|&(\n]\s*)(?:[&.]\s+)?)[''"]?(?<p>[^\s''"`;|&(){}]+[\\/]work[\\/]agents[\\/][^\s''"`;|&(){}]+\.ps1)\b')) {
      $sp = $m.Groups['p'].Value -replace '^/([A-Za-z])(?=/)', '$1:'; $sp = if ([IO.Path]::IsPathRooted($sp)) { $sp } else { Join-Path $cwd0 $sp }
      if ((Test-Path -LiteralPath $sp -PathType Leaf) -and ($cc = @(Find-KitPsCaseClash ([IO.File]::ReadAllText($sp))))) { return "kit guard: $($m.Groups['p'].Value): $($cc[0]) are ONE variable (PowerShell names are case-insensitive: the second overwrites the first): rename one to a full word, then run it (script-fault ps-case-clash)." }
    }
  } }
# ---- reads: cat / type / Get-Content of a whole file skips the Read caps (owner 2026-11-27: SKILL.md, lead notes, briefs, results
# and product files dumped whole); a pipe to a limiter, a redirect or a ranged Get-Content passes
Register-KitAdapter 'guard' 'file-dumps' @{ check = { param($a)
    $hook = $a.hook; $cwd = if ($hook.cwd) { "$($hook.cwd)" } else { (Get-Location).Path }
    $body = [regex]::Replace([regex]::Replace("$($a.raw)", '(?ms)<<-?\s*([''"]?)(\w+)\1([^\n]*)\n.*?^\s*\2\s*$', '<<doc$3'), '\s\d?>&\d|\s\d>\s*\S+', ' ')   # 2>&1, 2>/dev/null: stderr only
    $kit = "$script:KitRoot" -replace '\\', '/'; $kitCap = [int](Get-KitParam 'guard.kitReadLines'); $anyCap = [int](Get-KitParam 'guard.readMaxLines')
    $printer = '^(more|less|cat|Out-Host|Out-String|Write-Output|echo)$'   # a pipe into anything else consumes the text; $(...) / (...) feed a command
    foreach ($m in [regex]::Matches($body, '(?im)(?:^|[;&\n]|\|\|)\s*(?:cat|type|Get-Content|gc)\s+(?<a>[^;&|\n<>()]+?)\s*(?<n>$|[;&\n)]|\|\s*(?<p>[\w-]+)|>)')) {
      if ($m.Groups['n'].Value -eq '>' -or ($m.Groups['p'].Success -and $m.Groups['p'].Value -notmatch $printer) -or $m.Groups['a'].Value -match '(^|\s)-(TotalCount|Head|Tail|First|Last)\b') { continue }
      $dir = $cwd; $cds = [regex]::Matches($body.Substring(0, $m.Index), '(?:^|[;&\n])\s*cd\s+(?<d>"[^"]+"|''[^'']+''|[^\s;&|]+)'); if ($cds.Count) { $dir = $cds[$cds.Count - 1].Groups['d'].Value.Trim('''"') -replace '^/([A-Za-z])(?=/|$)', '$1:' }
      foreach ($f in @($m.Groups['a'].Value -split '\s+' | Where-Object { $_ -and $_ -notmatch '^-' })) {
        $f = $f.Trim('''"') -replace '^/([A-Za-z])(?=/)', '$1:'; if ($f -match '[$*?`{]' -or $f -match '\.(png|jpe?g|gif|webp|pdf|zip|exe|dll|class|jar)$') { continue }
        $full = try { [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $dir $f })) } catch { continue }
        $fi = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue; if (-not $fi -or $fi.PSIsContainer) { continue }
        $isKit = ($full -replace '\\', '/').StartsWith("$kit/", [StringComparison]::OrdinalIgnoreCase) -and $full -match '\.(md|json|jsonl|log|txt|ya?ml|csv)$'
        $cap = if ($isKit) { $kitCap } else { $anyCap }; $n = 0; $sr = $null   # stops at cap + 1; an undisposed ReadLines kept the file locked in guard_server
        try { $sr = [IO.StreamReader]::new($full); while ($null -ne $sr.ReadLine() -and ++$n -le $cap) { } } catch { continue } finally { if ($sr) { $sr.Dispose() } }
        if ($cap -and $n -gt $cap) { return "kit guard: $f is over $cap lines: a whole-file cat / type / Get-Content puts all of it in your context (cap $cap lines: guard.$(if ($isKit) { 'kitReadLines (kit docs, run files)' } else { 'readMaxLines' })). Read tool: the top 40 lines (its map; a .md: Grep '^#'), then the range you need (offset / limit); a run's lead notes: pokey.ps1 lead-notes show -RunDir <run> [-Code <code>] [-Last 5]; or pipe to head / grep." }
      }
    } } }
