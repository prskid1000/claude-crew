# shim: remove after 2026-11-23 (the #7 rename: localenv.ps1 -> skills/envy/envy.ps1, for callers outside the kit)
#Requires -Version 7
& pwsh -NoProfile -File (Join-Path (Split-Path $PSScriptRoot) 'envy/envy.ps1') @args   # a child: its own exit code, stdin passed on
exit $LASTEXITCODE
