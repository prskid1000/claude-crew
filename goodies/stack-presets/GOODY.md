# stack-presets
- What: `crafty.ps1 stack` / `check` presets for Android Gradle modules (variant: `.claude-stack.json` `androidVariant`, else the
  first product flavor + Debug), .NET (SDK, legacy MSBuild via vswhere; `{sln}` = the folder's one solution or project), Go, Rust,
  CMake and Make.
Needed when: `AndroidManifest.xml` in a repo, `*.sln` in a repo, `*.csproj` in a repo, `go.mod` in a repo, `Cargo.toml` in a repo, `CMakeLists.txt` in a repo
- Wiring: `skills/crafty/adapters/stack_presets.ps1` registers the `stack/presets` adapter; Get-Stack calls its `detect` after the
  core stacks (without it such a folder stops with the goody line). Tests: `tests.ps1` here.

