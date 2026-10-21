# stack-presets
- What: `dev.ps1 stack` / `check` presets for .NET (SDK, legacy MSBuild via vswhere), Go, Rust, CMake and Make.
Needed when: a repo has `*.sln` / `*.csproj`, `go.mod`, `Cargo.toml`, `CMakeLists.txt` or `Makefile` and no core stack (dev.ps1 stack says so).
- Wiring: `skills/dev-kit/adapters/stack_presets.ps1` registers the `stack/presets` adapter; Get-Stack calls its `detect` after the core stacks.
- Tests: `tests.ps1` here.
