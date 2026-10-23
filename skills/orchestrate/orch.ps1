# shim: remove after 2026-11-23 (the #7 rename: orch.ps1 -> skills/bossy/bossy.ps1, for callers outside the kit)
#Requires -Version 7
& pwsh -NoProfile -File (Join-Path (Split-Path $PSScriptRoot) 'bossy/bossy.ps1') @args   # a child: its own exit code, stdin passed on
exit $LASTEXITCODE
