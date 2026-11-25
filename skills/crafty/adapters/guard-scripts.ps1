#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# guard rule script-faults (owner 2026-11-25; the classes of kitbag.py faults): agents' own commands and scripts that fail the same way
# again and again: python -c through a .bat shim, a Bash command bash -n cannot parse, a PowerShell payload that does not parse, a Git
# Bash "/x" argument to a Windows program (MSYS path conversion), ./mvnw or ./gradlew from a folder without it, a work/agents .ps1 whose
# variables differ only by case; .state/tracking.json (moved), decide wait under a shell timeout, Git Bash /tmp to a Windows python
# or node, python -c inside pwsh -Command, sed -i with backslashes on a .py. Test-KitScriptEdit (crafty.ps1 guard, file edits): the .ps1 case check and illegal Java string escapes.
# Each deny names the fix and its class (script-fault <class>).
# Sections: L10 helpers · L91 edits · L112 commands
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
function Find-KitJavaBadEscape([string]$Text) {   # illegal backslash escapes inside Java string, char and text-block literals: 'line <n>: \x'
  $state = 'code'; $line = 1; $i = 0
  while ($i -lt $Text.Length) {
    $ch = $Text[$i]; $nx = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
    if ($ch -eq "`n") { $line++; if ($state -eq 'line') { $state = 'code' } }
    switch ($state) {
      'code' { if ($ch -eq '/' -and $nx -eq '/') { $state = 'line'; $i++ } elseif ($ch -eq '/' -and $nx -eq '*') { $state = 'block'; $i++ } elseif ($ch -eq '"' -and [string]::CompareOrdinal($Text, $i, '"""', 0, 3) -eq 0) { $state = 'text'; $i += 2 } elseif ($ch -eq '"') { $state = 'str' } elseif ($ch -eq "'") { $state = 'chr' } }
      'block' { if ($ch -eq '*' -and $nx -eq '/') { $state = 'code'; $i++ } }
      { $_ -in 'str', 'chr', 'text' } {
        if ($ch -eq '\') { if ('btnfrs"''\u01234567'.IndexOf($nx) -lt 0 -and -not ($state -eq 'text' -and "`r`n".IndexOf($nx) -ge 0)) { "line ${line}: \$nx" }; $i++ }
        elseif ($state -eq 'text' -and $ch -eq '"' -and [string]::CompareOrdinal($Text, $i, '"""', 0, 3) -eq 0) { $state = 'code'; $i += 2 }
        elseif (($state -eq 'str' -and $ch -eq '"') -or ($state -eq 'chr' -and $ch -eq "'") -or ($state -ne 'text' -and $ch -eq "`n")) { $state = 'code' } }
    }
    $i++
  }
}
# ---- edits: Write / Edit / MultiEdit content of a work/agents .ps1 (case clash) or a .java file (illegal escapes); only new problems count
$script:KitStateMoved = '[\\/]\.state[\\/]+tracking\.json(?![.\w])'
$script:KitStateMovedWhy = '.state/tracking.json is gone: each task is .state/tasks/<id>.json (+ automerge.json); read them with bossy.ps1 track show [-Task <id>] (script-fault state-moved)'
function Test-KitScriptEdit([string]$Path, $ToolInput) {
  if ($Path -and ($Path -replace '\\', '/') -match '/work/agents/.*\.(py|ps1|mjs|js|sh)$' -and "$($ToolInput.content)$($ToolInput.new_string)$(@($ToolInput.edits.new_string) -join '')" -match $script:KitStateMoved) { return "kit guard: $Path`: $script:KitStateMovedWhy." }
  if (-not $Path -or $Path -notmatch '\.(ps1|java)$') { return }
  $old = if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { '' }
  $new = if ($null -ne $ToolInput.content) { [string]$ToolInput.content } else { $old }
  foreach ($ed in @($(if ($null -ne $ToolInput.old_string) { $ToolInput } else { @($ToolInput.edits) })) | Where-Object { $_ -and $null -ne $_.old_string }) {
    $at = $new.IndexOf([string]$ed.old_string); if ($at -lt 0) { return }   # the tool itself refuses a missing old_string
    $new = if ($ed.replace_all) { $new.Replace([string]$ed.old_string, [string]$ed.new_string) } else { $new.Substring(0, $at) + $ed.new_string + $new.Substring($at + ([string]$ed.old_string).Length) }
  }
  if ($Path -match '\.ps1$' -and ($Path -replace '\\', '/') -match '/work/agents/') {
    $was = @(Find-KitPsCaseClash $old); $hit = @(Find-KitPsCaseClash $new | Where-Object { $_ -notin $was })
    if ($hit) { return "kit guard: $Path`: $($hit[0]) are ONE variable (PowerShell names are case-insensitive: the second overwrites the first): rename one to a full word (`$appPath, `$argList) (script-fault ps-case-clash)" }
  }
  if ($Path -match '\.java$' -and $new -match '\\[^btnfrs"''\\u0-7\r\n]') {   # no suspect escape: no scan
    $was = @(Find-KitJavaBadEscape $old).Count; $hit = @(Find-KitJavaBadEscape $new)
    if ($hit.Count -gt $was) { return "kit guard: $Path $($hit[0]) is an illegal escape in a Java string (javac: illegal escape character): double every backslash of a regex in Java source (\\d, \\s, \\.) (script-fault java-escape)" }
  }
}
# ---- commands: shim quotes, bash -n, PowerShell payloads, MSYS path conversion, wrapper folders, case-clashing agent scripts
Register-KitAdapter 'guard' 'script-faults' @{ check = { param($a)
    $raw = "$($a.raw)"; $hook = $a.hook; $tool = "$($hook.tool_name)"; $cwd = if ($hook.cwd) { "$($hook.cwd)" } else { (Get-Location).Path }; $cwd0 = $cwd   # $cwd follows cd; $null after a cd to an unknown place
    $isBash = $tool -eq 'Bash' -and "$($hook.transcript_path)" -notmatch '[\\/]\.codex[\\/]'   # Codex names its shell Bash: PowerShell on Windows
    $fix = "& $($KitCmd.dev) dir -Agent <id> -Name"
    $body = [regex]::Replace($raw, '(?ms)<<-?\s*([''"]?)(\w+)\1([^\n]*)\n.*?^\s*\2\s*$', '<<doc$3')   # heredoc bodies are data
    $segs = if ($isBash -or -not $tool) { @(Split-CommandSegments $body 'Bash') } else { @() }
    # python -c through a .bat shim: cmd.exe re-parses quotes, | & < > ^ % and cuts at a newline ('|| goto :error')
    if (($shim = Get-KitPyShim)) {
      # a bare python / python3 / py only: an explicit python.exe path skips the shim
      $codes = if ($tool -eq 'PowerShell') { @(@(CmdAsts $raw) | ForEach-Object { Get-KitPyCode @($_.CommandElements | ForEach-Object { if ($null -ne $_.Value) { "$($_.Value)" } else { "$($_.Extent.Text)" } }) }) }
        else { @(foreach ($seg in @(Split-CommandSegments $body 'Bash')) { Get-KitPyCode @(Get-KitBashWords $seg) }) }
      # cmd.exe ends the call at a newline, toggles on \" and splits an unquoted (space-free) argument at & | < > ^
      if (@($codes | Where-Object { $_ -match '[\r\n"]' -or ($_ -notmatch '\s' -and $_ -match '[&|<>^]') }).Count) { return "kit guard: python here is $shim (a .bat shim: cmd.exe re-reads python -c code, so quotes, | & < > ^ % and newlines break it: '|| goto :error'). Write the program to a .py file (Write tool; $fix x.py) and run python -X utf8 <file> (script-fault py-shim-quote)." }
    }
    # a command that does not parse fails the same way at run time, with a worse message
    if ($tool -eq 'PowerShell' -and ($pe = Get-KitPsParseError $raw)) { return "kit guard: this PowerShell does not parse ($pe): write it to a .ps1 (Write tool; $fix x.ps1) and run pwsh -NoProfile -File <file> (script-fault ps-parse)." }
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
      # Git Bash turns a /x argument into C:/Program Files/Git/x for a Windows program (/d/x: the Git Bash path rule; /tmp, /dev: mounts)
      if ($isBash -and $raw -notmatch 'MSYS_NO_PATHCONV=1|MSYS2_ARG_CONV_EXCL' -and $leaf -match '^(node|python[\d.]*|py|pwsh|powershell|java|javac|mvnw?|mvnd|gradlew?|npx|npm|yarn|pnpm|adb|dotnet|glab|gh|aws|docker|kubectl|curl|ffmpeg)$' -and $raw -notmatch 'pokey\.ps1') {   # pokey.ps1 api turns C:/Program Files/Git/x back into /x
        $bad = @($words | Select-Object -Skip ($wi + 1) | Where-Object { $_ -match '^(--?[\w-]+=)?/(?![/\s]|(tmp|dev|proc|usr|bin|etc|[A-Za-z])(/|$))[\w.@~+-]' -and $_ -notmatch '\s|\*' })
        if ($bad) { return "kit guard: Git Bash rewrites the argument $($bad[0]) for $leaf (a Windows program) into C:/Program Files/Git$($bad[0] -replace '^--?[\w-]+=', '') (MSYS path conversion). Prefix the command with MSYS_NO_PATHCONV=1 (or export MSYS_NO_PATHCONV=1 first), or run it from the PowerShell tool (script-fault msys-path)." }
      }
      if ($leaf -match '^(cd|pushd)$' -and $words.Count -gt $wi + 1) { $to = $words[$wi + 1] -replace '^/([A-Za-z])(?=/|$)', '$1:'; if (-not $cwd -or (Get-KitBashExpansion @(Get-KitBashWords $seg -Source)[$wi + 1]) -or $to -match '^[~-]') { $cwd = $null; continue }; $cwd = if ([IO.Path]::IsPathRooted($to)) { $to } else { Join-Path $cwd $to }; continue }
      if ($cwd -and $leaf -match '^(mvnw|gradlew)$' -and $words[$wi] -match '[\\/]') {
        $wrapper = $words[$wi] -replace '^/([A-Za-z])(?=/)', '$1:'; $full = if ([IO.Path]::IsPathRooted($wrapper)) { $wrapper } else { Join-Path $cwd $wrapper }
        if (-not (Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath "$full.cmd") -and -not (Test-Path -LiteralPath "$full.bat")) { return "kit guard: $(Split-Path $full) has no $leaf (the wrapper sits in the module root): cd to the folder that holds it, or run & $($KitCmd.dev) check -Dir <module> (script-fault wrapper-path)." }
      }
    }
    # crafty.ps1 gate -Dir <d> -Cmd './mvnw ...': the wrapper must sit in <d> (the gate runs the command there)
    if ($raw -match '\bgate\b.*?\s-Dir\s+(?<d>"[^"]+"|''[^'']+''|\S+).*?\s-Cmd\s+["'']?(?<w>(\.[\\/])?(mvnw|gradlew))(\.cmd|\.bat)?\b') {
      $gd = $Matches.d.Trim('''"') -replace '^/([A-Za-z])(?=/)', '$1:'; $gd = if ([IO.Path]::IsPathRooted($gd)) { $gd } else { Join-Path $cwd0 $gd }; $gw = $Matches.w -replace '^\.[\\/]', ''
      if ((Test-Path -LiteralPath $gd -PathType Container) -and -not @(Get-ChildItem -LiteralPath $gd -Filter "$gw*" -File -ErrorAction SilentlyContinue).Count) { return "kit guard: $gd has no $gw (the gate runs -Cmd in -Dir): pass the module root that holds it as -Dir, or run & $($KitCmd.dev) check -Dir <module> (script-fault wrapper-path)." }
    }
    # moved state, killed waits, Git Bash /tmp (faults: tracking.json, decide wait under timeout, /tmp read by a Windows python)
    if ($raw -match $script:KitStateMoved -and $raw -notmatch '\b(git|learn|grep|rg|Select-String)\b') { return "kit guard: $script:KitStateMovedWhy." }
    if ($isBash -and $raw -match '\bdecide\s+wait\b' -and $raw -match '(^|[;&|(]\s*)timeout\s+\S+\s' -and $raw -notmatch '-MaxMinutes') { return "kit guard: a shell timeout kills decide wait mid-poll and drops its answer: run decide wait -Id <id> -MaxMinutes <m> (PENDING + exit 1 at the limit; default 8, under the 10 min tool cap) (script-fault decide-wait-timeout)." }
    if ($isBash -and $raw -match '(^|[\s;&|(])(python[\d.]*|py|node)(\.exe)?\s' -and $raw -match '[(=,\[]\s*r?[''"]/tmp/') { return "kit guard: a /tmp path inside python or node code opens <drive>:\tmp, not Git Bash's /tmp (only a bare argument is converted): put the file under $fix <file> (script-fault posix-path)." }   # arch-ok: matches agents' /tmp, writes none
    # a work/agents .ps1 about to run with $a / $A in one scope (the second spelling overwrites the first)
    foreach ($m in [regex]::Matches($raw, '(?:-File\s+|(?:^|[;|&(\n]\s*)(?:[&.]\s+)?)[''"]?(?<p>[^\s''"`;|&(){}]+[\\/]work[\\/]agents[\\/][^\s''"`;|&(){}]+\.ps1)\b')) {
      $sp = $m.Groups['p'].Value -replace '^/([A-Za-z])(?=/)', '$1:'; $sp = if ([IO.Path]::IsPathRooted($sp)) { $sp } else { Join-Path $cwd0 $sp }
      if ((Test-Path -LiteralPath $sp -PathType Leaf) -and ($cc = @(Find-KitPsCaseClash ([IO.File]::ReadAllText($sp))))) { return "kit guard: $($m.Groups['p'].Value): $($cc[0]) are ONE variable (PowerShell names are case-insensitive: the second overwrites the first): rename one to a full word, then run it (script-fault ps-case-clash)." }
    }
  } }
