#Requires -Version 7
# Usage: dot-sourced by lib.ps1 from adapters/. Exit codes: none here (its verbs exit through lib.ps1).
# build-heap: heap caps for the JVM (Maven, Gradle) and Node builds crafty.ps1 gate starts: the learned peak x 1.25 (no
# history: gate.startHeapGB.<maven|gradle|node>), at least gate.heapMinGB; an inherited -Xmx / --max-old-space-size is replaced.
# Dot-sourced from skills/crafty/adapters/; Invoke-Gate calls each function.
# built-in GB defaults (heaps, gate.kindGB.*) are sized for 64 GB of RAM: a smaller machine scales them down (RAM rounded up to 8 GB)
function Get-GateRamScale {
  if ($null -eq $script:GateRamScale) { $script:GateRamScale = [math]::Min(1.0, [math]::Ceiling([double](Get-SysMem).TotalGB / 8) * 8 / 64) }
  $script:GateRamScale
}
# a kind's starting GB until learned: the registry default scaled to this RAM (a kit.local.json pin or a learned value as is)
function Get-GateKindGB([string]$Kind) { $kk = "gate.kindGB.$Kind"; [double](Get-KitParam $kk ([double](Get-KitParamSpec $kk).default * (Get-GateRamScale))) }
function Get-GateHeap([string]$Kind, [double[]]$Peaks, [double]$NeedGB, [double]$Need) {
  $tool = if ($Kind -in 'android-build', 'android-test', 'gradle') { 'gradle' } elseif ($Kind -like 'maven*') { 'maven' }
          elseif ($Kind -in 'ng-test', 'web-build', 'js-test', 'tsc-lint', 'typecheck', 'rn-bundle', 'e2e') { 'node' }
  # Cypress's Electron reads no browser policy: the shared quiet flags (vocab.json chromeQuietArgs)
  if ($Kind -eq 'cypress' -and -not $env:ELECTRON_EXTRA_LAUNCH_ARGS) { $env:ELECTRON_EXTRA_LAUNCH_ARGS = $script:KitVocab.chromeQuietArgs -join ' ' }
  if (-not $tool) { return $null }
  if (-not $env:GRADLE_OPTS) { $env:GRADLE_OPTS = "-Dorg.gradle.workers.max=$([int](Get-KitParam 'gate.gradleWorkers'))" }
  $minGB = [double](Get-KitParam 'gate.heapMinGB')
  $sc = Get-GateRamScale; $start = [double](Get-KitSetting "gate.startHeapGB.$tool" ([math]::Max(1.0, @{ gradle = 12; maven = 8; node = 4 }[$tool] * $sc)))
  $peakMax = ($Peaks | Select-Object -Last 5 | Measure-Object -Maximum).Maximum
  # G1 free-ratios let the learned peak fall
  $heap = if ($Peaks.Count -ge 2) { [int][math]::Ceiling($peakMax * 1.25) } else { $start }
  $heap = [math]::Min([math]::Max($start, 8 * $sc), [math]::Max($minGB, $heap))
  if ($NeedGB -le 0 -and $Peaks.Count -lt 2) { $Need = [math]::Max($Need, $heap + 0.5) }   # no history: the heap can fill up
  # a smaller heap thrashes in GC
  $floor = if ($Peaks.Count -ge 2) { [math]::Min($heap, [math]::Max($minGB, [int][math]::Ceiling($peakMax * 1.1))) } else { $minGB }
  [pscustomobject]@{ tool = $tool; heap = $heap; floor = $floor; need = $Need }
}
# the build's temp files (java.io.tmpdir, tests) per checkout (<parent>-<folder>) in <runtime>/tmp (cleanup ages them out); gradle keeps the OS
# temp: another tmpdir starts another daemon
function Set-GateTemp([string]$Cmd, [string]$Dir) {
  if ($Dir -and $Cmd -notmatch '\bgradlew?\b') { $env:TMP = $env:TEMP = $env:TMPDIR = (New-Item -ItemType Directory -Force (Join-Path (Get-KitTemp) "build/$(ConvertTo-KitSlug "$(Split-Path (Split-Path $Dir) -Leaf)-$(Split-Path $Dir -Leaf)")")).FullName }   # arch-ok: kit temp
}
# sets the env a cap of $GB needs; returns the command (Gradle takes it as a -D: it overrides org.gradle.jvmargs)
function Set-GateHeap([string]$Tool, [int]$GB, [string]$Cmd) {
  $g1 = '-XX:+UseG1GC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 -XX:G1PeriodicGCInterval=30000'
  if ($Tool -eq 'maven') { $env:MAVEN_OPTS = "$(([string]$env:MAVEN_OPTS -replace '-Xm[xs]\S+|-XX:\+Use\w+GC|-XX:MaxMetaspaceSize=\S+', '' -replace '\s+', ' ').Trim()) -Xmx${GB}g -XX:MaxMetaspaceSize=512m $g1".Trim() }
  if ($Tool -eq 'node') { $env:NODE_OPTIONS = "$(([string]$env:NODE_OPTIONS -replace '--max-old-space-size=\d+', '' -replace '\s+', ' ').Trim()) --max-old-space-size=$($GB * 1024)".Trim() }
  if ($Tool -eq 'gradle' -and $Cmd -notmatch 'org\.gradle\.jvmargs') {
    $Cmd = ([regex]'(gradlew(\.bat)?|\bgradle)(?=\s|$)').Replace($Cmd, "`$1 `"-Dorg.gradle.jvmargs=-Xmx${GB}g -XX:MaxMetaspaceSize=1g $g1 -Dfile.encoding=UTF-8`"", 1)
  }
  $Cmd
}
