# shim: remove after 2026-11-23 (the #7 rename: swarm.ps1 -> skills/phoney/phoney.ps1, for callers outside the kit)
#Requires -Version 7
& pwsh -NoProfile -File (Join-Path (Split-Path $PSScriptRoot) 'phoney/phoney.ps1') @args   # a child: its own exit code, stdin passed on
exit $LASTEXITCODE
