# posix
- What: lib.ps1's OS helpers on Linux and macOS: memory (/proc/meminfo, vm_stat), processes (ps), directory links (symlinks),
  python3, detached starts (setsid / nohup). The core keeps the Windows versions.
Needed when: `linux` OS, `macos` OS
- Wiring: `skills/dev-kit/adapters/os_posix.ps1` (lib.ps1 loads adapters/*.ps1 after its own helpers; on Windows it returns at once);
  without it lib.ps1 warns `Linux / macOS support is an extra: run kittool.py extra add posix`. Tests: `tests.ps1` here.

