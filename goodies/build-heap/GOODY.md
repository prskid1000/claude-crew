# build-heap
- What: heap caps for the JVM (Maven, Gradle) and Node builds `crafty.ps1 gate` starts: the learned peak x 1.25 (no history:
  `gate.startHeapGB.<maven|gradle|node>`, default 8 / 12 / 4), at least `gate.heapMinGB` (4); the gate shrinks a cap to its floor
  when memory is tight or builds queue. Without it builds start with their own heap settings.
Needed when: `pom.xml` in a repo, `build.gradle` in a repo, `build.gradle.kts` in a repo, `package.json` in a repo
- Wiring: `skills/crafty/adapters/build_heap.ps1` defines `Get-GateHeap` and `Set-GateHeap` (lib.ps1 loads adapters/*.ps1);
  Invoke-Gate calls them. Tests: `tests.ps1` here.
